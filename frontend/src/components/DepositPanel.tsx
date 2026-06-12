/**
 * Phase E (D-6): tranche deposit / withdraw panel for StratumZap.
 *
 * Funding modes: classic approve+deposit, Permit2 signature (no prior zap approval), and
 * delivered-balance (Trading API custom-recipient flow, demo/batch use). The panel degrades to a
 * configuration notice when the zap address is unset (honesty contract: no placeholder
 * addresses). Liquidity sizing is the caller's responsibility per the zap NatSpec; unused
 * funding is refunded in the same transaction.
 */

import { useEffect, useMemo, useRef, useState } from "react";
import { useAccount, useConnect, useReadContract } from "wagmi";
import { parseUnits } from "viem";
import { buildDemoPoolKey } from "../lib/poolKey";
import { useZapDeposit, type DepositMode } from "../hooks/useZapDeposit";
import { usePoolOverview } from "../hooks/usePoolOverview";
import { STRATUM_ADDRESSES, UNICHAIN_SEPOLIA } from "../config/addresses";
import { DEMO_TOKEN_ABI } from "../abis/demoToken";
import { setDepositStash } from "../lib/depositStash";
import BalancesStrip from "./BalancesStrip";

const EXPLORER = UNICHAIN_SEPOLIA.blockExplorers.default.url;

function toBytes32Salt(s: string): `0x${string}` {
  // Accept either a 0x-prefixed bytes32 or a short label, which is right-padded.
  if (s.startsWith("0x") && s.length === 66) return s as `0x${string}`;
  const bytes = new TextEncoder().encode(s).slice(0, 32);
  let hex = "0x";
  for (const b of bytes) hex += b.toString(16).padStart(2, "0");
  return (hex + "0".repeat(66 - hex.length)) as `0x${string}`;
}

export default function DepositPanel() {
  // useAccount().chainId reports the wallet's real chain (incl. unconfigured ones); useChainId()
  // clamps to a configured chain and would never flag a wrong-network state.
  const { isConnected, chainId } = useAccount();
  const { connect, connectors } = useConnect();
  const poolKey = buildDemoPoolKey();
  const { state, deposit, withdraw, reset, zapConfigured } = useZapDeposit();
  // Live lens snapshot of the demo pool, captured the moment the user submits a deposit so the
  // post-deposit banner can show a real before → after coverage / senior-TVL delta (spec §5.2).
  const { overview } = usePoolOverview();
  const snapshotRef = useRef<{ coverageBeforeBps?: number; seniorTVLBefore?: string }>({});
  const handledTxRef = useRef<string | null>(null);

  const configured = !!STRATUM_ADDRESSES.demoToken0 && !!STRATUM_ADDRESSES.demoToken1;
  const { data: sym0 } = useReadContract({
    address: STRATUM_ADDRESSES.demoToken0 as `0x${string}`,
    abi: DEMO_TOKEN_ABI,
    functionName: "symbol",
    query: { enabled: configured },
  });
  const { data: sym1 } = useReadContract({
    address: STRATUM_ADDRESSES.demoToken1 as `0x${string}`,
    abi: DEMO_TOKEN_ABI,
    functionName: "symbol",
    query: { enabled: configured },
  });
  const label0 = (sym0 as string) ?? "token0";
  const label1 = (sym1 as string) ?? "token1";

  const [tranche, setTranche] = useState<0 | 1>(0);
  const [mode, setMode] = useState<DepositMode>("permit2");
  const [liquidity, setLiquidity] = useState("1000000000000000000");
  const [amount0, setAmount0] = useState("2");
  const [amount1, setAmount1] = useState("2");
  const [tickLower, setTickLower] = useState("-887220");
  const [tickUpper, setTickUpper] = useState("887220");
  const [salt, setSalt] = useState("stratum-demo");
  const [withdrawIntent, setWithdrawIntent] = useState(false);

  // Deep link (spec §8.2): #deposit?action=withdraw&salt=..&tickLower=..&tickUpper=.. pre-fills the
  // position key so a judge can withdraw straight from the positions panel without re-typing.
  useEffect(() => {
    const hash = window.location.hash;
    const qIndex = hash.indexOf("?");
    if (qIndex === -1) return;
    const params = new URLSearchParams(hash.slice(qIndex + 1));
    if (params.get("salt")) setSalt(params.get("salt")!);
    if (params.get("tickLower")) setTickLower(params.get("tickLower")!);
    if (params.get("tickUpper")) setTickUpper(params.get("tickUpper")!);
    if (params.get("action") === "withdraw") setWithdrawIntent(true);
  }, []);

  const busy = state.phase === "approving" || state.phase === "signing" || state.phase === "depositing"
    || state.phase === "withdrawing";

  const parsed = useMemo(() => {
    try {
      return {
        liquidity: BigInt(liquidity),
        amount0Max: parseUnits(amount0 || "0", 18),
        amount1Max: parseUnits(amount1 || "0", 18),
        tickLower: Number(tickLower),
        tickUpper: Number(tickUpper),
        userSalt: toBytes32Salt(salt),
        ok: true,
      };
    } catch {
      return { liquidity: 0n, amount0Max: 0n, amount1Max: 0n, tickLower: 0, tickUpper: 0, userSalt: "0x" as `0x${string}`, ok: false };
    }
  }, [liquidity, amount0, amount1, tickLower, tickUpper, salt]);

  // On a successful deposit (phase done + a positionId, which withdraw never sets), stash the tx and
  // the pre-deposit snapshot, then route to #app where DepositSuccessBanner surfaces the impact.
  useEffect(() => {
    if (state.phase !== "done" || !state.txHash || !state.positionId) return;
    if (handledTxRef.current === state.txHash) return;
    handledTxRef.current = state.txHash;
    setDepositStash({
      txHash: state.txHash,
      positionId: state.positionId,
      tranche,
      poolId: STRATUM_ADDRESSES.defaultPoolId,
      ts: Date.now(),
      coverageBeforeBps: snapshotRef.current.coverageBeforeBps,
      seniorTVLBefore: snapshotRef.current.seniorTVLBefore,
      userSalt: parsed.userSalt,
      tickLower: parsed.tickLower,
      tickUpper: parsed.tickUpper,
    });
    window.location.hash = "app";
    window.scrollTo(0, 0);
  }, [state.phase, state.txHash, state.positionId, tranche]);

  if (!zapConfigured || !poolKey) {
    return (
      <div className="notice">
        Deposit routing is not configured yet. Deploy <span className="mono">StratumZap</span> and set{" "}
        <span className="mono">NEXT_PUBLIC_ZAP_ADDRESS</span> (plus the demo pool variables) to enable one-click
        tranche deposits with Permit2.
      </div>
    );
  }

  const wrongNetwork = isConnected && chainId !== UNICHAIN_SEPOLIA.id;

  return (
    <div>
      {wrongNetwork && (
        <div className="notice notice-error" style={{ marginBottom: 20 }}>
          Wrong network. Please switch to {UNICHAIN_SEPOLIA.name} (chain ID {UNICHAIN_SEPOLIA.id}).
        </div>
      )}

      {!isConnected && (
        <div className="notice" style={{ marginBottom: 20, display: "flex", justifyContent: "space-between", alignItems: "center", gap: 12 }}>
          <span>Connect a wallet to open a tranche position.</span>
          <div className="wallet-connect-group">
            {connectors.map((c) => (
              <button key={c.uid} className="btn-pill btn-pill-sm" onClick={() => connect({ connector: c })}>
                {c.name}
              </button>
            ))}
          </div>
        </div>
      )}

      <BalancesStrip />

      <div className="metric-card" style={{ marginBottom: 20 }}>
        <div className="metric-title" style={{ marginBottom: 4 }}>Choose a tranche</div>
        <p className="caption muted" style={{ marginBottom: 14 }}>
          Senior earns the fixed, smoothed coupon with IL protection. Junior takes leveraged fee surplus and absorbs
          losses first.
        </p>
        <div className="seg" role="radiogroup" aria-label="Tranche">
          <button
            role="radio"
            aria-checked={tranche === 0}
            className={`chip ${tranche === 0 ? "chip-selected" : ""}`}
            onClick={() => setTranche(0)}
          >
            stLP &middot; Senior
          </button>
          <button
            role="radio"
            aria-checked={tranche === 1}
            className={`chip ${tranche === 1 ? "chip-selected" : ""}`}
            onClick={() => setTranche(1)}
          >
            jtLP &middot; Junior
          </button>
        </div>
      </div>

      <div className="metric-card" style={{ marginBottom: 20 }}>
        <div className="metric-title" style={{ marginBottom: 4 }}>Funding mode</div>
        <p className="caption muted" style={{ marginBottom: 14 }}>
          Permit2 needs a one-time token approval to Permit2, then every deposit is signature-only. Delivered-balance
          consumes tokens a routed swap already sent to the zap (batched Trading API flow).
        </p>
        <div className="seg" role="radiogroup" aria-label="Funding mode">
          <button
            role="radio"
            aria-checked={mode === "permit2"}
            className={`chip ${mode === "permit2" ? "chip-selected" : ""}`}
            onClick={() => setMode("permit2")}
          >
            Permit2 signature
          </button>
          <button
            role="radio"
            aria-checked={mode === "approve"}
            className={`chip ${mode === "approve" ? "chip-selected" : ""}`}
            onClick={() => setMode("approve")}
          >
            Approve + deposit
          </button>
          <button
            role="radio"
            aria-checked={mode === "delivered"}
            className={`chip ${mode === "delivered" ? "chip-selected" : ""}`}
            onClick={() => setMode("delivered")}
          >
            Delivered balance
          </button>
        </div>
      </div>

      <div className="metric-card" style={{ marginBottom: 20 }}>
        <div className="metric-title" style={{ marginBottom: 14 }}>Position parameters</div>
        <div className="form-grid">
          <div>
            <label className="field-label" htmlFor="liq">Liquidity (raw L)</label>
            <input id="liq" className="input-pill mono" value={liquidity} onChange={(e) => setLiquidity(e.target.value)} />
            <p className="field-hint">
              Uniswap v4 position size in raw units. The "Max to spend" caps below limit how many tokens this actually
              pulls; default 1e18 is a small demo position.
            </p>
          </div>
          <div>
            <label className="field-label" htmlFor="salt">Position label (salt)</label>
            <input id="salt" className="input-pill mono" value={salt} onChange={(e) => setSalt(e.target.value)} />
          </div>
          {mode !== "delivered" && (
            <>
              <div>
                <label className="field-label" htmlFor="a0">
                  Max {label0} to spend
                </label>
                <input id="a0" className="input-pill mono" value={amount0} onChange={(e) => setAmount0(e.target.value)} />
                <p className="field-hint">{amount0 || "0"} {label0} (the unused remainder is refunded)</p>
              </div>
              <div>
                <label className="field-label" htmlFor="a1">
                  Max {label1} to spend
                </label>
                <input id="a1" className="input-pill mono" value={amount1} onChange={(e) => setAmount1(e.target.value)} />
                <p className="field-hint">{amount1 || "0"} {label1} (the unused remainder is refunded)</p>
              </div>
            </>
          )}
          <div>
            <label className="field-label" htmlFor="tl">Tick lower</label>
            <input id="tl" className="input-pill mono" value={tickLower} onChange={(e) => setTickLower(e.target.value)} />
          </div>
          <div>
            <label className="field-label" htmlFor="tu">Tick upper</label>
            <input id="tu" className="input-pill mono" value={tickUpper} onChange={(e) => setTickUpper(e.target.value)} />
          </div>
        </div>
        <p className="fine-print" style={{ marginTop: 14 }}>
          Liquidity sizing is computed off-chain; over-funded amounts are refunded in the same transaction. Yield
          figures shown elsewhere are targets, not guarantees.
        </p>
      </div>

      {withdrawIntent && (
        <div className="notice" style={{ marginBottom: 16 }}>
          Pre-filled from your position (tick {tickLower} / {tickUpper}, salt{" "}
          <span className="mono">{salt}</span>). Click <b>Withdraw this position</b> below to close it.
        </div>
      )}

      <div style={{ display: "flex", gap: 12, flexWrap: "wrap", alignItems: "center" }}>
        <button
          className="btn-pill"
          disabled={busy || !isConnected || wrongNetwork || !parsed.ok}
          onClick={() => {
            // Snapshot the pool before the deposit so the banner can show a true delta.
            snapshotRef.current = {
              coverageBeforeBps: overview?.coverageRatioBps,
              seniorTVLBefore: overview ? overview.seniorTVL.toString() : undefined,
            };
            deposit({
              poolKey,
              tickLower: parsed.tickLower,
              tickUpper: parsed.tickUpper,
              liquidity: parsed.liquidity,
              tranche,
              userSalt: parsed.userSalt,
              amount0Max: parsed.amount0Max,
              amount1Max: parsed.amount1Max,
              mode,
            });
          }}
        >
          {mode === "permit2" ? "Sign and deposit" : mode === "delivered" ? "Deposit delivered balance" : "Approve and deposit"}
        </button>
        <button
          className="btn-pill-ghost"
          disabled={busy || !isConnected || wrongNetwork || !parsed.ok}
          onClick={() =>
            withdraw({
              poolKey,
              tickLower: parsed.tickLower,
              tickUpper: parsed.tickUpper,
              userSalt: parsed.userSalt,
            })
          }
        >
          Withdraw this position
        </button>
        {(state.phase === "done" || state.phase === "error") && (
          <button className="btn-utility" onClick={reset}>
            Reset
          </button>
        )}
      </div>

      {state.phase !== "idle" && (
        <div className={`notice ${state.phase === "error" ? "notice-error" : ""}`} style={{ marginTop: 20 }}>
          <div className="flow-line">
            {busy && <span className="spinner" aria-hidden />}
            <span>{state.message}</span>
          </div>
          {state.txHash && (
            <p className="caption" style={{ marginTop: 8 }}>
              Tx:{" "}
              <a className="mono" href={`${EXPLORER}/tx/${state.txHash}`} target="_blank" rel="noreferrer">
                {state.txHash.slice(0, 18)}…
              </a>
            </p>
          )}
          {state.positionId && (
            <p className="caption mono" style={{ marginTop: 4, wordBreak: "break-all" }}>
              Position id: {state.positionId}
            </p>
          )}
        </div>
      )}
    </div>
  );
}
