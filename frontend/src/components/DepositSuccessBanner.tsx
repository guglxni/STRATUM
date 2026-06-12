/**
 * Post-deposit banner (spec §5.2). After a zap deposit, DepositPanel routes the user here (#app)
 * and stashes the tx + a pre-deposit pool snapshot. This banner reads it back and makes the state
 * change visible: tranche opened, tx link, and the real before → after coverage / senior-TVL delta
 * (the §2.1 gap where rounded cards looked unchanged). Dismissible; clears with the tab session.
 */

import { useEffect, useState } from "react";
import { formatUnits } from "viem";
import { readDepositStash, clearDepositStash, type DepositStash } from "../lib/depositStash";
import { explorerTx } from "../config/explorers";

interface Props {
  /** Live coverage ratio (bps) from the dashboard lens read, for the "after" side of the delta. */
  coverageNowBps?: number;
  /** Live senior TVL (raw 18-dec) from the dashboard lens read. */
  seniorTVLNow?: bigint;
}

function pct(bps: number): string {
  return (bps / 100).toFixed(1) + "%";
}

function tvl(raw: bigint | string): string {
  const v = typeof raw === "string" ? BigInt(raw) : raw;
  return parseFloat(formatUnits(v, 18)).toFixed(2);
}

export default function DepositSuccessBanner({ coverageNowBps, seniorTVLNow }: Props) {
  const [stash, setStash] = useState<DepositStash | null>(null);

  useEffect(() => {
    const s = readDepositStash();
    // Only surface a recent deposit (15 min) so a stale tab doesn't show an old banner.
    if (s && Date.now() - s.ts < 15 * 60_000) setStash(s);
  }, []);

  if (!stash) return null;

  const trancheName = stash.tranche === 0 ? "Senior (stLP)" : "Junior (jtLP)";

  const coverageDelta =
    stash.coverageBeforeBps !== undefined && coverageNowBps !== undefined
      ? `${pct(stash.coverageBeforeBps)} → ${pct(coverageNowBps)}`
      : coverageNowBps !== undefined
        ? `now ${pct(coverageNowBps)}`
        : null;

  const tvlDelta =
    stash.seniorTVLBefore !== undefined && seniorTVLNow !== undefined
      ? `${tvl(stash.seniorTVLBefore)} → ${tvl(seniorTVLNow)}`
      : seniorTVLNow !== undefined
        ? `now ${tvl(seniorTVLNow)}`
        : null;

  const dismiss = () => {
    clearDepositStash();
    setStash(null);
  };

  return (
    <div className="deposit-banner" role="status">
      <div className="deposit-banner-main">
        <span className="deposit-banner-check" aria-hidden>
          ✓
        </span>
        <div>
          <div className="deposit-banner-title">{trancheName} position opened</div>
          <div className="deposit-banner-meta">
            {coverageDelta && (
              <span>
                Coverage <span className="mono">{coverageDelta}</span>
              </span>
            )}
            {tvlDelta && (
              <span>
                Senior TVL <span className="mono">{tvlDelta}</span>
              </span>
            )}
            <a className="mono" href={explorerTx(stash.txHash)} target="_blank" rel="noreferrer">
              view tx ↗
            </a>
          </div>
          {stash.positionId && (
            <div className="deposit-banner-pos mono">position id: {stash.positionId.slice(0, 18)}…</div>
          )}
        </div>
      </div>
      <button className="btn-utility" onClick={dismiss} aria-label="Dismiss deposit confirmation">
        Dismiss
      </button>
    </div>
  );
}
