/**
 * Live event feed (spec §5.4): a chronological feed of hook events with a second column teaching
 * WHO listens — the event → integration map (§2.2). The point is honesty: RSCs react to specific
 * events (EpochClosed, CoverageStress), not to every deposit. Data comes from the same dual-source
 * hooks as HistoryPanel (subgraph when configured, RPC getLogs fallback otherwise).
 */

import { useMemo, useState } from "react";
import { formatUnits } from "viem";
import { useSubgraphEpochs } from "../hooks/useSubgraphEpochs";
import { useSubgraphSwaps } from "../hooks/useSubgraphSwaps";
import { useSubgraphCoverageEvents } from "../hooks/useSubgraphPoolHistory";
import { STRATUM_LIVE_MULTICHAIN } from "../config/addresses";
import { explorerAddress, explorerTx, CHAIN_IDS } from "../config/explorers";

type Filter = "all" | "epochs" | "swaps" | "stress";

interface FeedItem {
  key: string;
  kind: "epoch" | "swap" | "stress";
  time: number;
  title: string;
  detail: string;
  listener: string;
  listenerHref?: string;
  txHash?: string;
}

function fmt(v: string): string {
  const n = parseFloat(formatUnits(BigInt(v), 18));
  if (n === 0) return "0";
  if (n < 0.001) return "<0.001";
  return n.toFixed(3);
}

const RSC_EPOCH = explorerAddress(STRATUM_LIVE_MULTICHAIN.reactiveLasna.epochSettler, CHAIN_IDS.REACTIVE_LASNA);
const RSC_COVERAGE = explorerAddress(STRATUM_LIVE_MULTICHAIN.reactiveLasna.coverageMonitor, CHAIN_IDS.REACTIVE_LASNA);

export default function LiveEventFeed({ poolId }: { poolId: string }) {
  const epochs = useSubgraphEpochs(poolId);
  const swaps = useSubgraphSwaps(poolId);
  const coverage = useSubgraphCoverageEvents(poolId);
  const [filter, setFilter] = useState<Filter>("all");

  const items = useMemo<FeedItem[]>(() => {
    const out: FeedItem[] = [];
    for (const e of epochs.data ?? []) {
      out.push({
        key: `e-${e.id}`,
        kind: "epoch",
        time: Number(e.closedAt) || 0,
        title: `Epoch #${e.epoch} closed`,
        detail: `senior funded ${fmt(e.seniorFunded)} · junior surplus ${fmt(e.juniorSurplus)}`,
        listener: "Reactive EpochSettler RSC",
        listenerHref: RSC_EPOCH,
      });
    }
    for (const s of swaps.data ?? []) {
      out.push({
        key: `s-${s.id}`,
        kind: "swap",
        time: Number(s.timestamp) || 0,
        title: `Swap fee accrued (epoch #${s.epoch})`,
        detail: `fee ${fmt(s.feeAmount)} · volEWMA ${s.volatilityEWMA} · coverage ${(s.coverageRatioBps / 100).toFixed(1)}%`,
        listener: "Dynamic fee + epoch waterfall",
        txHash: s.txHash,
      });
    }
    for (const c of coverage.data ?? []) {
      out.push({
        key: `c-${c.id}`,
        kind: "stress",
        time: Number(c.timestamp) || 0,
        title: `Coverage stress (level ${c.stressLevel})`,
        detail: `ratio ${(c.ratioBps / 100).toFixed(1)}%`,
        listener: "Reactive CoverageMonitor RSC + CPHR",
        listenerHref: RSC_COVERAGE,
      });
    }
    return out.sort((a, b) => b.time - a.time);
  }, [epochs.data, swaps.data, coverage.data]);

  const kindForFilter: Record<Exclude<Filter, "all">, FeedItem["kind"]> = {
    epochs: "epoch",
    swaps: "swap",
    stress: "stress",
  };
  const filtered = items.filter((i) => filter === "all" || i.kind === kindForFilter[filter]);
  const loading = epochs.isLoading || swaps.isLoading || coverage.isLoading;

  return (
    <div className="metric-card" style={{ marginBottom: 20 }}>
      <div className="metric-title" style={{ marginBottom: 4 }}>
        Live event feed
      </div>
      <p className="caption muted" style={{ marginBottom: 12 }}>
        Hook events and who reacts to them. RSC callbacks fire on specific events (epoch close, coverage
        stress) — not on every wallet action.
      </p>
      <div className="seg" role="tablist" aria-label="Event filter" style={{ marginBottom: 12 }}>
        {(["all", "epochs", "swaps", "stress"] as Filter[]).map((f) => (
          <button
            key={f}
            role="tab"
            aria-selected={filter === f}
            className={`chip ${filter === f ? "chip-selected" : ""}`}
            onClick={() => setFilter(f)}
          >
            {f[0].toUpperCase() + f.slice(1)}
          </button>
        ))}
      </div>

      {loading ? (
        <p className="caption muted">Loading events…</p>
      ) : filtered.length === 0 ? (
        <p className="caption muted">
          No {filter === "all" ? "" : filter + " "}events yet. The seeded pool's history appears here once
          indexed (subgraph) or scanned (on-chain).
        </p>
      ) : (
        <div className="feed-list">
          {filtered.map((i) => (
            <div key={i.key} className={`feed-row feed-${i.kind}`}>
              <div className="feed-main">
                <span className="feed-title">{i.title}</span>
                <span className="feed-detail mono">{i.detail}</span>
              </div>
              <div className="feed-side">
                {i.listenerHref ? (
                  <a className="feed-tag" href={i.listenerHref} target="_blank" rel="noreferrer">
                    {i.listener} ↗
                  </a>
                ) : (
                  <span className="feed-tag feed-tag-static">{i.listener}</span>
                )}
                {i.txHash && (
                  <a className="feed-tx mono" href={explorerTx(i.txHash)} target="_blank" rel="noreferrer">
                    tx ↗
                  </a>
                )}
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
