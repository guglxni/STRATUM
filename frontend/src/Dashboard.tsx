/**
 * STRATUM live dashboard.
 *
 * Reads strategy (Phase C): when a StratumLens address is configured, derived metrics
 * (coverage, stress, next swap fee, reserves, protocol-fee state) come from ONE
 * lens.poolOverview call computed by the same Solidity libraries the hook uses. Direct
 * hook reads remain as the fallback so the dashboard still works against the legacy
 * deployment with no lens. Historical panels (Phase D) come from the subgraph when
 * configured. Protocol-fee copy follows the D-1 semantics gate (Phase F).
 */

import { useState } from "react";
import { useAccount, useConnect, useDisconnect, useReadContract } from "wagmi";
import { formatUnits } from "viem";
import { STRATUM_HOOK_ABI } from "./abis/stratumHook";
import { STRATUM_ADDRESSES, STRATUM_LIVE_MULTICHAIN, UNICHAIN_SEPOLIA } from "./config/addresses";
import { explorerAddress, CHAIN_IDS } from "./config/explorers";
import { usePoolOverview } from "./hooks/usePoolOverview";
import HistoryPanel from "./components/HistoryPanel";
import PoolCharts from "./components/PoolCharts";
import IntegrationStatusStrip from "./components/IntegrationStatusStrip";
import JudgeQuickStartPanel from "./components/JudgeQuickStartPanel";
import DepositSuccessBanner from "./components/DepositSuccessBanner";
import EpochCountdown from "./components/EpochCountdown";
import PoolInspectPanel from "./components/PoolInspectPanel";
import LiveEventFeed from "./components/LiveEventFeed";
import CoverageSimulator from "./components/CoverageSimulator";
import ArchitectureMap from "./components/ArchitectureMap";
import { useMetricDelta } from "./hooks/useMetricDelta";

// ---------------------------------------------------------------------------
// Types matching StratumHook PoolTrancheState struct
// ---------------------------------------------------------------------------

interface PoolTrancheState {
  seniorTVL: bigint;
  juniorTVL: bigint;
  juniorReserve: bigint;
  targetAPYBps: bigint;
  minCoverageRatioBps: number;
  maxSeniorILExposureBps: number;
  smoothingEpochSeconds: number;
  currentEpoch: bigint;
  epochAccumulatedFees: bigint;
  epochSeniorObligation: bigint;
  epochSeniorFunded: bigint;
  volatilityEWMA: bigint;
  baseFeeBps: number;
  minFeeBps: number;
  maxFeeBps: number;
  protocolFeeBps: number;
  poolCumulativeIL: bigint;
  peripheralRegistry: string;
  seniorToken: string;
  juniorToken: string;
  initialized: boolean;
  epochStartTimestamp: bigint;
  seniorFeePerShareX128: bigint;
  juniorFeePerShareX128: bigint;
}

// ---------------------------------------------------------------------------
// Formatting helpers
// ---------------------------------------------------------------------------

function bpsToPercent(bps: bigint | number): string {
  const n = typeof bps === "bigint" ? Number(bps) : bps;
  return (n / 100).toFixed(2) + "%";
}

function fmtToken0(v: bigint): string {
  const f = parseFloat(formatUnits(v, 18));
  if (f === 0) return "0";
  if (f < 0.001) return "<0.001";
  if (f < 1) return f.toFixed(4);
  if (f < 1_000) return f.toFixed(2);
  if (f < 1_000_000) return (f / 1_000).toFixed(2) + "K";
  return (f / 1_000_000).toFixed(2) + "M";
}

/**
 * Compute realized APY from seniorFeePerShareX128 growth.
 * Display approximation; the real earned yield is settled at position exit.
 */
function computeRealizedAPYBps(
  seniorFeePerShareX128: bigint,
  targetAPYBps: bigint,
  epochSeconds: number,
  currentEpoch: bigint
): string {
  if (currentEpoch === 0n || epochSeconds === 0) return "0.00%";
  const YEAR_SECONDS = 365 * 24 * 3600;
  const totalElapsed = Number(currentEpoch) * epochSeconds;
  if (totalElapsed === 0) return "0.00%";
  const earnedFrac = Number(seniorFeePerShareX128) / 2 ** 128;
  const annualizedBps = Math.round((earnedFrac / totalElapsed) * YEAR_SECONDS * 10_000);
  return `${bpsToPercent(annualizedBps)} (target: ${bpsToPercent(targetAPYBps)})`;
}

function coverageRatioStr(junior: bigint, senior: bigint): string {
  if (senior === 0n) return "infinity (no senior)";
  const bps = (junior * 10_000n) / senior;
  return bpsToPercent(bps);
}

/** Coverage ratio in bps as a number (for charts/gauges). Caps the no-senior case. */
function ratioBpsFrom(junior: bigint, senior: bigint): number {
  if (senior === 0n) return 100_000; // effectively infinite; gauge clamps it
  return Number((junior * 10_000n) / senior);
}

function reserveHealthStr(reserve: bigint, juniorTVL: bigint): string {
  if (juniorTVL === 0n) return "N/A";
  const pct = (reserve * 10_000n) / juniorTVL;
  return bpsToPercent(pct) + " of junior TVL";
}

function stressFromTVLs(junior: bigint, senior: bigint, minCovBps: number): { label: string; cls: string } {
  if (senior === 0n) return { label: "No stress", cls: "badge-ok" };
  const ratioBps = Number((junior * 10_000n) / senior);
  return stressFromRatio(ratioBps, minCovBps);
}

function stressFromRatio(ratioBps: number, minCovBps: number): { label: string; cls: string } {
  if (ratioBps >= minCovBps * 2) return { label: "Healthy", cls: "badge-ok" };
  if (ratioBps >= minCovBps * 1.5) return { label: "Watch", cls: "badge-watch" };
  if (ratioBps >= minCovBps) return { label: "Stress", cls: "badge-bad" };
  return { label: "Critical", cls: "badge-bad" };
}

// ---------------------------------------------------------------------------
// Dashboard
// ---------------------------------------------------------------------------

interface DashboardProps {
  onBack: () => void;
  onDeposit: () => void;
}

export default function Dashboard({ onBack, onDeposit }: DashboardProps) {
  // chainId from useAccount() is the wallet's real chain; useChainId() would clamp to a configured
  // chain and never surface a wrong-network state.
  const { address, isConnected, chainId } = useAccount();
  const { connect, connectors } = useConnect();
  const { disconnect } = useDisconnect();

  const [poolId, setPoolId] = useState<string>(STRATUM_ADDRESSES.defaultPoolId);

  // Phase C: lens-first aggregated read (single call); undefined when no lens configured.
  const { overview, lensConfigured, refetch: refetchLens } = usePoolOverview();

  // Fallback / detail reads against the hook (works on the legacy live deployment).
  const { data: poolStateRaw, isError, isLoading, refetch: refetchState } = useReadContract({
    address: STRATUM_ADDRESSES.hook as `0x${string}`,
    abi: STRATUM_HOOK_ABI,
    functionName: "poolState",
    args: [poolId as `0x${string}`],
    query: { enabled: !!poolId && !!STRATUM_ADDRESSES.hook, refetchInterval: 10_000 },
  });

  // Reserve read is dropped when the lens provides reserves (instructions 6.3).
  const { data: reserveRaw } = useReadContract({
    address: STRATUM_ADDRESSES.hook as `0x${string}`,
    abi: STRATUM_HOOK_ABI,
    functionName: "reserveBalances",
    args: [poolId as `0x${string}`],
    query: { enabled: !!poolId && !!STRATUM_ADDRESSES.hook && !lensConfigured, refetchInterval: 10_000 },
  });

  const state = poolStateRaw as PoolTrancheState | undefined;
  const [reserve0, reserve1] = overview
    ? [overview.reserve0, overview.reserve1]
    : ((reserveRaw as [bigint, bigint] | undefined) ?? [0n, 0n]);

  const stress = overview
    ? stressFromRatio(overview.coverageRatioBps, state?.minCoverageRatioBps ?? 10_000)
    : state
      ? stressFromTVLs(state.juniorTVL, state.seniorTVL, state.minCoverageRatioBps)
      : { label: "Unknown", cls: "badge-neutral" };

  const isWrongNetwork = isConnected && chainId !== UNICHAIN_SEPOLIA.id;

  // Metric deltas (§6.6): flash + sublabel when coverage / senior TVL move between 10s polls.
  const coverageNumeric = overview
    ? overview.coverageRatioBps
    : state
      ? ratioBpsFrom(state.juniorTVL, state.seniorTVL)
      : undefined;
  const seniorTVLNumeric = state ? Number(formatUnits(state.seniorTVL, 18)) : undefined;
  const coverageDeltaRaw = useMetricDelta(coverageNumeric, 1); // > 0.01% move
  const seniorDeltaRaw = useMetricDelta(seniorTVLNumeric, 0.001);
  const coverageDelta = coverageDeltaRaw !== null ? `${coverageDeltaRaw > 0 ? "+" : ""}${(coverageDeltaRaw / 100).toFixed(2)}%` : null;
  const seniorDelta = seniorDeltaRaw !== null ? `${seniorDeltaRaw > 0 ? "+" : ""}${seniorDeltaRaw.toFixed(2)}` : null;

  // Phase F: D-1 semantics gate. Lens per-pool truth wins; env flag is the pre-lens override.
  const v2Realization = overview?.protocolFeeRealization ?? STRATUM_ADDRESSES.hookV2ProtocolFeeRealization;

  return (
    <div className="page-parchment">
      <nav className="gnav">
        <div className="container-wide gnav-inner">
          <button className="gnav-logo" onClick={onBack}>
            <span className="logo-mark" aria-hidden>
              <span />
              <span />
              <span />
            </span>
            STRATUM
          </button>
          <div className="gnav-links">
            <a
              href="#"
              onClick={(e) => {
                e.preventDefault();
                onBack();
              }}
            >
              About
            </a>
            <a href="#positions">Positions</a>
            <a href="#labs">Labs</a>
            <a
              href="#deposit"
              onClick={(e) => {
                e.preventDefault();
                onDeposit();
              }}
            >
              Deposit
            </a>
            {isConnected ? (
              <>
                <span className="wallet-chip">
                  {address?.slice(0, 6)}…{address?.slice(-4)}
                </span>
                <button className="btn-utility" onClick={() => disconnect()}>
                  Disconnect
                </button>
              </>
            ) : (
              <div className="wallet-connect-group">
                {connectors.map((c) => (
                  <button key={c.uid} className="btn-utility" onClick={() => connect({ connector: c })}>
                    {c.name}
                  </button>
                ))}
              </div>
            )}
          </div>
        </div>
      </nav>

      <main className="dash-main container-wide">
        <div className="dash-header">
          <div>
            <h2>Pool dashboard</h2>
            <div className="sub">
              Live tranche state on Unichain Sepolia &middot; refreshes every 10s &middot;{" "}
              {lensConfigured ? "single-call lens reads" : "direct hook reads (lens not configured)"}
            </div>
          </div>
          <button
            className="btn-pill-ghost btn-pill-ghost-sm"
            onClick={() => {
              refetchState();
              refetchLens();
            }}
          >
            Refresh now
          </button>
        </div>

        {isWrongNetwork && (
          <div className="notice notice-error" style={{ marginBottom: 20 }}>
            Wrong network. Please switch to {UNICHAIN_SEPOLIA.name} (chain ID {UNICHAIN_SEPOLIA.id}).
          </div>
        )}

        {/* P0 (§5.2): surface the just-completed deposit's impact (coverage / senior-TVL delta). */}
        <DepositSuccessBanner coverageNowBps={overview?.coverageRatioBps} seniorTVLNow={overview?.seniorTVL} />

        {/* P0 (§5.3): full multi-chain stack at a glance, above the fold. */}
        <IntegrationStatusStrip />

        {/* P0 (§5.6): guided judge path without leaving the page. */}
        <JudgeQuickStartPanel onGoDeposit={onDeposit} />

        {/* P1 (§5.5): epoch countdown + Reactive automation narrative. */}
        <EpochCountdown poolId={poolId} />

        {/* P1 (§4.1): raw lens read, collapsible. */}
        <PoolInspectPanel />

        <div style={{ marginBottom: 24, maxWidth: 720 }}>
          <label className="field-label" htmlFor="poolid">
            Pool ID (bytes32 hex)
          </label>
          <input
            id="poolid"
            className="input-pill mono"
            value={poolId}
            onChange={(e) => setPoolId(e.target.value)}
            placeholder="0x…"
          />
        </div>

        {isLoading ? (
          <div className="dash-empty">Loading pool state…</div>
        ) : isError || !state ? (
          <div className="dash-empty">
            {!state ? "No pool data. Check Pool ID and hook address." : "Error reading pool state."}
          </div>
        ) : (
          <div className="metric-grid">
            <MetricCard
              title="Coverage Ratio (INV-01)"
              subtitle="juniorTVL / seniorTVL"
              value={
                overview ? bpsToPercent(overview.coverageRatioBps) : coverageRatioStr(state.juniorTVL, state.seniorTVL)
              }
              detail={`Floor: ${bpsToPercent(state.minCoverageRatioBps)}${overview ? ` | Stress level: ${overview.stressLevelBps} bps` : ""}`}
              badge={stress.label}
              badgeCls={stress.cls}
              delta={coverageDelta}
            />
            <MetricCard
              title="Senior APY (FR-01)"
              subtitle="Realized vs target"
              value={computeRealizedAPYBps(
                state.seniorFeePerShareX128,
                state.targetAPYBps,
                state.smoothingEpochSeconds,
                state.currentEpoch
              )}
              detail={`Max IL exposure: ${bpsToPercent(state.maxSeniorILExposureBps)}`}
            />
            <MetricCard
              title="Junior Reserve Health (INV-05)"
              subtitle="Buffer for senior protection"
              value={reserveHealthStr(state.juniorReserve, state.juniorTVL)}
              detail={`Abstract: ${fmtToken0(state.juniorReserve)} | Token: ${fmtToken0(reserve0 + reserve1)}`}
            />
            <MetricCard
              title="Epoch Summary (INV-06)"
              subtitle={`Epoch #${state.currentEpoch}`}
              value={`${fmtToken0(state.epochSeniorFunded)} / ${fmtToken0(state.epochSeniorObligation)} funded`}
              detail={`Fees: ${fmtToken0(state.epochAccumulatedFees)} | VolEWMA: ${state.volatilityEWMA.toString()}`}
            />
            <MetricCard
              title="TVL Breakdown"
              subtitle="Senior vs Junior liquidity"
              value={`S: ${fmtToken0(state.seniorTVL)} | J: ${fmtToken0(state.juniorTVL)}`}
              detail={`Cumulative pool IL: ${fmtToken0(state.poolCumulativeIL)}`}
              delta={seniorDelta}
            />
            <MetricCard
              title="Dynamic Fee (FR-05)"
              subtitle={overview ? "Next swap (lens preview)" : "Current fee band"}
              value={overview ? `${bpsToPercent(overview.nextSwapFeeBps)} next swap` : `${bpsToPercent(state.baseFeeBps)} base`}
              detail={`Range: ${bpsToPercent(state.minFeeBps)} - ${bpsToPercent(state.maxFeeBps)} | Base: ${bpsToPercent(state.baseFeeBps)}`}
            />
            <MetricCard
              title={v2Realization ? "Protocol Fee (D-1, realized)" : "Protocol Fee (ledger)"}
              subtitle={
                v2Realization
                  ? `${bpsToPercent(state.protocolFeeBps)} swap surcharge paid by traders`
                  : `${bpsToPercent(state.protocolFeeBps)} of LP swap fees (accounting ledger)`
              }
              value={
                overview
                  ? v2Realization
                    ? `${fmtToken0(overview.protocolFeeReserve0)} t0 / ${fmtToken0(overview.protocolFeeReserve1)} t1`
                    : `${fmtToken0(overview.protocolFeesAccrued)} t0 (ledger)`
                  : "Connect lens for accrued value"
              }
              detail={
                v2Realization
                  ? "Real tokens held by the hook, collectable via collectProtocolFees"
                  : "Accounting value only; no tokens are withdrawable in v1 semantics"
              }
              badge={v2Realization ? "v2 realized" : "v1 ledger"}
              badgeCls="badge-neutral"
            />
            <MetricCard
              title="Token-Backed Reserve (R-H1)"
              subtitle="Real tokens for senior make-whole"
              value={`${fmtToken0(reserve0)} t0 / ${fmtToken0(reserve1)} t1`}
              detail={`Peripheral: ${state.peripheralRegistry.slice(0, 10)}…`}
            />
            <MetricCard
              title="Cross-Chain Reserve (CPHR, FR-18)"
              subtitle="Across integration status"
              value={STRATUM_ADDRESSES.cphr ? "CPHR active" : "CPHR not configured"}
              detail={
                STRATUM_ADDRESSES.cphr
                  ? `Router: ${STRATUM_ADDRESSES.cphr.slice(0, 10)}…`
                  : "Set NEXT_PUBLIC_CPHR_ADDRESS"
              }
              badge={STRATUM_ADDRESSES.cphr ? "Live" : "Stub"}
              badgeCls={STRATUM_ADDRESSES.cphr ? "badge-ok" : "badge-neutral"}
            />
          </div>
        )}

        {/* Visual analytics: derived purely from the live snapshot (no subgraph needed), plus a
            session sparkline that accumulates each 10s poll. */}
        {state && (
          <PoolCharts
            seniorTVL={state.seniorTVL}
            juniorTVL={state.juniorTVL}
            juniorReserve={state.juniorReserve}
            reserveTokens={reserve0 + reserve1}
            coverageRatioBps={overview ? overview.coverageRatioBps : ratioBpsFrom(state.juniorTVL, state.seniorTVL)}
            minCoverageRatioBps={state.minCoverageRatioBps}
            nextSwapFeeBps={overview ? overview.nextSwapFeeBps : state.baseFeeBps}
            minFeeBps={state.minFeeBps}
            maxFeeBps={state.maxFeeBps}
            baseFeeBps={state.baseFeeBps}
            epochSeniorFunded={state.epochSeniorFunded}
            epochSeniorObligation={state.epochSeniorObligation}
            epochAccumulatedFees={state.epochAccumulatedFees}
          />
        )}

        {/* P3 (§6.3): coverage inequality the hook enforces, as a no-tx simulator. */}
        <CoverageSimulator poolId={poolId} />

        {/* P3 (§6.5): multi-chain topology map. */}
        <ArchitectureMap />

        {/* P1 (§5.4): event feed with who-listens tags (event → integration map). */}
        <LiveEventFeed poolId={poolId} />

        {/* Phase D: subgraph-backed history (graceful degradation inside the panel). */}
        <HistoryPanel poolId={poolId} />

        <div className="addr-panel">
          <strong>
            Deployment Addresses
            <span className="ver-badge">{v2Realization ? "hook v2 realized" : "hook v1 ledger"}</span>
          </strong>
          <div className="addr-grid">
            <AddrLine label="Hook" addr={STRATUM_ADDRESSES.hook} chip="Unichain" />
            {STRATUM_ADDRESSES.hookLegacy && STRATUM_ADDRESSES.hookLegacy !== STRATUM_ADDRESSES.hook && (
              <AddrLine label="Hook (legacy, pre-D-1)" addr={STRATUM_ADDRESSES.hookLegacy} chip="Unichain" muted />
            )}
            <AddrLine label="Lens" addr={STRATUM_ADDRESSES.lens} chip="Unichain" />
            <AddrLine label="Zap" addr={STRATUM_ADDRESSES.zap} chip="Unichain" />
            <AddrLine label="CPHR" addr={STRATUM_ADDRESSES.cphr} chip="Unichain" />
            <AddrLine label="EpochSettler (twin)" addr={STRATUM_ADDRESSES.epochSettler} chip="Unichain" />
            <AddrLine label="BrevisShim" addr={STRATUM_ADDRESSES.brevisShim} chip="Unichain" />
            <AddrLine label="MatchAttestation" addr={STRATUM_ADDRESSES.matchAttestation} chip="Unichain" />
            <AddrLine
              label="Stylus ML engine"
              addr={STRATUM_LIVE_MULTICHAIN.stylusEngineArbitrum}
              chip="Arbitrum"
              chainId={CHAIN_IDS.ARBITRUM_SEPOLIA}
            />
            <AddrLine
              label="EpochSettler RSC"
              addr={STRATUM_LIVE_MULTICHAIN.reactiveLasna.epochSettler}
              chip="Lasna"
              chainId={CHAIN_IDS.REACTIVE_LASNA}
            />
            <AddrLine
              label="Across destination"
              addr={STRATUM_LIVE_MULTICHAIN.sepolia.cphr}
              chip="Sepolia"
              chainId={CHAIN_IDS.ETHEREUM_SEPOLIA}
            />
          </div>
        </div>
      </main>
    </div>
  );
}

// ---------------------------------------------------------------------------
// MetricCard
// ---------------------------------------------------------------------------

interface MetricCardProps {
  title: string;
  subtitle: string;
  value: string;
  detail?: string;
  badge?: string;
  badgeCls?: string;
  /** Transient "+Δ …" sublabel; presence also flashes the card (spec §6.6). */
  delta?: string | null;
}

function MetricCard({ title, subtitle, value, detail, badge, badgeCls, delta }: MetricCardProps) {
  return (
    <div className={`metric-card${delta ? " metric-card-flash" : ""}`}>
      <div className="metric-head">
        <div>
          <div className="metric-title">{title}</div>
          <div className="metric-sub">{subtitle}</div>
        </div>
        {badge && <span className={`badge ${badgeCls ?? "badge-neutral"}`}>{badge}</span>}
      </div>
      <div className="metric-value">
        {value}
        {delta && <span className="metric-delta">{delta}</span>}
      </div>
      {detail && <div className="metric-detail">{detail}</div>}
    </div>
  );
}

// ---------------------------------------------------------------------------
// AddrLine - a labeled, explorer-linked address row (chain-aware)
// ---------------------------------------------------------------------------

function AddrLine({
  label,
  addr,
  chip,
  chainId = CHAIN_IDS.UNICHAIN_SEPOLIA,
  muted,
}: {
  label: string;
  addr?: string;
  chip: string;
  chainId?: number;
  muted?: boolean;
}) {
  return (
    <div className={`addr-line${muted ? " addr-line-muted" : ""}`}>
      <span className="addr-key">
        {label}
        <span className="addr-chip">{chip}</span>
      </span>
      {addr ? (
        <a className="addr-val mono" href={explorerAddress(addr, chainId)} target="_blank" rel="noreferrer">
          {addr}
        </a>
      ) : (
        <span className="addr-val mono addr-unset">not set</span>
      )}
    </div>
  );
}
