/**
 * Your Positions panel (spec §5.1 + protocol-interactivity §4.2). Lists the connected wallet's open
 * zap positions with live lens health (mark-to-market IL, anchor IL, accrued coupon, vested
 * claimable) and offers the user-owned writes: Claim vested (W1, FR-07) and a pre-filled Withdraw
 * deep link when the position's key inputs are known this session. Degrades to event-only rows if
 * the lens read fails, and to an empty state with a deposit CTA when there are none.
 */

import { useEffect, useState } from "react";
import { useAccount, useWriteContract, useWaitForTransactionReceipt } from "wagmi";
import { formatUnits } from "viem";
import { useUserPositions, type UserPosition } from "../hooks/useUserPositions";
import { STRATUM_ZAP_ABI } from "../abis/stratumZap";
import { STRATUM_ADDRESSES, UNICHAIN_SEPOLIA } from "../config/addresses";
import { explorerAddress } from "../config/explorers";
import { readDepositStash } from "../lib/depositStash";

function f18(v: bigint | undefined): string {
  if (v === undefined) return "—";
  const n = parseFloat(formatUnits(v, 18));
  if (n === 0) return "0";
  if (n < 0.0001) return "<0.0001";
  return n.toFixed(4);
}

/** Build a pre-filled withdraw deep link if we recorded this position's key inputs this session. */
function withdrawHref(positionId: string): string {
  const s = readDepositStash();
  if (s && s.positionId === positionId && s.userSalt && s.tickLower !== undefined && s.tickUpper !== undefined) {
    const q = new URLSearchParams({
      action: "withdraw",
      salt: s.userSalt,
      tickLower: String(s.tickLower),
      tickUpper: String(s.tickUpper),
    });
    return `#deposit?${q.toString()}`;
  }
  return "#deposit";
}

function PositionRow({ p }: { p: UserPosition }) {
  const { writeContract, data: txHash, isPending } = useWriteContract();
  const { isLoading: confirming } = useWaitForTransactionReceipt({ hash: txHash });
  const o = p.overview;
  const vested = o?.position.vestedClaimable ?? 0n;
  const canClaim = vested > 0n;
  const trancheName = p.tranche === 0 ? "stLP · Senior" : "jtLP · Junior";

  return (
    <div className="pos-row">
      <div className="pos-row-head">
        <span className={`chip ${p.tranche === 0 ? "chip-senior" : "chip-junior"}`}>{trancheName}</span>
        <a className="mono pos-id" href={explorerAddress(STRATUM_ADDRESSES.zap)} target="_blank" rel="noreferrer">
          {p.positionId.slice(0, 14)}…
        </a>
      </div>
      {o ? (
        <div className="pos-grid">
          <div>
            <span className="pos-k">Ticks</span>
            <span className="pos-v mono">
              {o.position.tickLower} / {o.position.tickUpper}
            </span>
          </div>
          <div>
            <span className="pos-k">Liquidity</span>
            <span className="pos-v mono">{o.position.liquidity.toString()}</span>
          </div>
          <div>
            <span className="pos-k">IL now (mark-to-market)</span>
            <span className="pos-v mono">{f18(o.ilAtCurrentPrice)}</span>
          </div>
          <div>
            <span className="pos-k">IL at anchor</span>
            <span className="pos-v mono">{f18(o.ilAtAnchor)}</span>
          </div>
          <div>
            <span className="pos-k">Accrued coupon</span>
            <span className="pos-v mono">{f18(o.accruedCoupon)}</span>
          </div>
          <div>
            <span className="pos-k">Vested claimable</span>
            <span className="pos-v mono">{f18(vested)}</span>
          </div>
        </div>
      ) : (
        <div className="pos-grid">
          <div>
            <span className="pos-k">Tranche</span>
            <span className="pos-v mono">{trancheName}</span>
          </div>
          <div>
            <span className="pos-k">Liquidity</span>
            <span className="pos-v mono">{p.liquidity.toString()}</span>
          </div>
          <div className="pos-note">Lens detail unavailable; showing event data only.</div>
        </div>
      )}
      <div className="pos-actions">
        <button
          className="btn-pill btn-pill-sm"
          disabled={!canClaim || isPending || confirming}
          onClick={() =>
            writeContract({
              address: STRATUM_ADDRESSES.zap as `0x${string}`,
              abi: STRATUM_ZAP_ABI,
              functionName: "claimVested",
              args: [p.positionId],
            })
          }
          title={canClaim ? "Claim the senior coupon vested so far (FR-07)" : "Nothing vested to claim yet"}
        >
          {isPending || confirming ? "Claiming…" : "Claim vested"}
        </button>
        <a className="btn-pill-ghost btn-pill-ghost-sm" href={withdrawHref(p.positionId)}>
          Withdraw
        </a>
      </div>
    </div>
  );
}

export default function PositionsPanel() {
  const { address, isConnected, chainId } = useAccount();
  const { data: positions, isLoading, isError, refetch } = useUserPositions(address);
  const [refreshing, setRefreshing] = useState(false);
  const wrongNetwork = isConnected && chainId !== UNICHAIN_SEPOLIA.id;

  // Re-scan when arriving fresh (e.g. right after a deposit) so a new position shows quickly.
  useEffect(() => {
    if (isConnected) refetch();
  }, [isConnected, refetch]);

  if (!STRATUM_ADDRESSES.zap) {
    return <div className="notice">Positions need the zap configured (NEXT_PUBLIC_ZAP_ADDRESS).</div>;
  }
  if (!isConnected) {
    return <div className="notice">Connect a wallet to see your tranche positions.</div>;
  }
  if (wrongNetwork) {
    return (
      <div className="notice notice-error">
        Wrong network. Switch to {UNICHAIN_SEPOLIA.name} to read your positions.
      </div>
    );
  }

  return (
    <div>
      <div className="dash-header" style={{ marginBottom: 16 }}>
        <div>
          <h2 style={{ margin: 0 }}>Your positions</h2>
          <div className="sub">Open zap positions for {address?.slice(0, 6)}…{address?.slice(-4)} · live lens health</div>
        </div>
        <button
          className="btn-pill-ghost btn-pill-ghost-sm"
          onClick={async () => {
            setRefreshing(true);
            await refetch();
            setRefreshing(false);
          }}
        >
          {refreshing ? "Scanning…" : "Rescan"}
        </button>
      </div>

      {isLoading ? (
        <div className="dash-empty">Scanning zap events for your positions…</div>
      ) : isError ? (
        <div className="dash-empty">Could not scan positions. The RPC may be rate-limited; try Rescan.</div>
      ) : !positions || positions.length === 0 ? (
        <div className="dash-empty">
          No open positions yet.{" "}
          <a href="#deposit">Open one on the deposit page →</a> (mint sdA/sdB first).
        </div>
      ) : (
        <div className="pos-list">
          {positions.map((p) => (
            <PositionRow key={p.positionId} p={p} />
          ))}
        </div>
      )}
    </div>
  );
}
