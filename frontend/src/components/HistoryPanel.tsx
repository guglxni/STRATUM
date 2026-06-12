/**
 * Phase D (D-7): historical panels backed by the STRATUM subgraph.
 * Tabs: epoch closes, swap fee snapshots, coverage stress timeline.
 * Hidden behind a "not configured" notice when no subgraph URL is set.
 */

import { useState } from "react";
import { formatUnits } from "viem";
import { subgraphConfigured } from "../lib/subgraphClient";
import { explorerTx } from "../config/explorers";
import { useSubgraphEpochs } from "../hooks/useSubgraphEpochs";
import { useSubgraphSwaps } from "../hooks/useSubgraphSwaps";
import { useSubgraphCoverageEvents } from "../hooks/useSubgraphPoolHistory";

type Tab = "epochs" | "swaps" | "stress";

function fmt(v: string): string {
  const f = parseFloat(formatUnits(BigInt(v), 18));
  if (f === 0) return "0";
  if (f < 0.001) return "<0.001";
  if (f < 1) return f.toFixed(4);
  if (f < 1_000) return f.toFixed(2);
  return (f / 1_000).toFixed(2) + "K";
}

function ts(unix: string): string {
  return new Date(Number(unix) * 1000).toLocaleString();
}

export default function HistoryPanel({ poolId }: { poolId: string }) {
  const [tab, setTab] = useState<Tab>("epochs");
  const onSub = subgraphConfigured();

  return (
    <section className="metric-card" style={{ marginTop: 28 }}>
      <div className="metric-head">
        <div>
          <div className="metric-title">
            History
            <span className="src-tag">{onSub ? "The Graph" : "on-chain events"}</span>
          </div>
          <div className="metric-sub">
            {onSub
              ? "Indexed by The Graph (D-7), refreshes every 30s"
              : "Read directly from hook event logs (no indexer needed), refreshes every 30s"}
          </div>
        </div>
        <div className="seg" role="tablist" aria-label="History tabs">
          <button
            role="tab"
            aria-selected={tab === "epochs"}
            className={`chip ${tab === "epochs" ? "chip-selected" : ""}`}
            onClick={() => setTab("epochs")}
          >
            Epochs
          </button>
          <button
            role="tab"
            aria-selected={tab === "swaps"}
            className={`chip ${tab === "swaps" ? "chip-selected" : ""}`}
            onClick={() => setTab("swaps")}
          >
            Swap fees
          </button>
          <button
            role="tab"
            aria-selected={tab === "stress"}
            className={`chip ${tab === "stress" ? "chip-selected" : ""}`}
            onClick={() => setTab("stress")}
          >
            Coverage stress
          </button>
        </div>
      </div>

      {tab === "epochs" && <EpochTable poolId={poolId} />}
      {tab === "swaps" && <SwapTable poolId={poolId} />}
      {tab === "stress" && <StressTable poolId={poolId} />}
    </section>
  );
}

function EpochTable({ poolId }: { poolId: string }) {
  const { data, isLoading, isError } = useSubgraphEpochs(poolId);
  if (isLoading) return <p className="caption muted">Loading epochs…</p>;
  if (isError) return <p className="caption muted">Could not load history.</p>;
  if (!data?.length) return <p className="caption muted">No closed epochs indexed yet.</p>;
  return (
    <div className="table-wrap">
      <table className="flat">
        <thead>
          <tr>
            <th>Epoch</th>
            <th>Senior funded</th>
            <th>Junior surplus</th>
            <th>Junior reserve</th>
            <th>Closed at</th>
          </tr>
        </thead>
        <tbody>
          {data.map((e) => (
            <tr key={e.id}>
              <td className="mono">#{e.epoch}</td>
              <td>{fmt(e.seniorFunded)}</td>
              <td>{fmt(e.juniorSurplus)}</td>
              <td>{fmt(e.juniorReserve)}</td>
              <td className="mono">{ts(e.closedAt)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function SwapTable({ poolId }: { poolId: string }) {
  const { data, isLoading, isError } = useSubgraphSwaps(poolId);
  if (isLoading) return <p className="caption muted">Loading swaps…</p>;
  if (isError) return <p className="caption muted">Could not load history.</p>;
  if (!data?.length) return <p className="caption muted">No swaps indexed yet.</p>;
  return (
    <div className="table-wrap">
      <table className="flat">
        <thead>
          <tr>
            <th>Epoch</th>
            <th>Fee booked</th>
            <th>Vol EWMA</th>
            <th>Coverage</th>
            <th>Tx</th>
          </tr>
        </thead>
        <tbody>
          {data.map((s) => (
            <tr key={s.id}>
              <td className="mono">#{s.epoch}</td>
              <td>{fmt(s.feeAmount)}</td>
              <td className="mono">{s.volatilityEWMA}</td>
              <td>{(s.coverageRatioBps / 100).toFixed(2)}%</td>
              <td className="mono">
                <a
                  href={explorerTx(s.txHash)}
                  target="_blank"
                  rel="noreferrer"
                >
                  {s.txHash.slice(0, 10)}…
                </a>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function StressTable({ poolId }: { poolId: string }) {
  const { data, isLoading, isError } = useSubgraphCoverageEvents(poolId);
  if (isLoading) return <p className="caption muted">Loading stress events…</p>;
  if (isError) return <p className="caption muted">Could not load history.</p>;
  if (!data?.length) return <p className="caption muted">No coverage-stress events indexed. That is a good sign.</p>;
  return (
    <div className="table-wrap">
      <table className="flat">
        <thead>
          <tr>
            <th>Coverage ratio</th>
            <th>Stress level</th>
            <th>When</th>
          </tr>
        </thead>
        <tbody>
          {data.map((c) => (
            <tr key={c.id}>
              <td>{(c.ratioBps / 100).toFixed(2)}%</td>
              <td className="mono">{c.stressLevel}</td>
              <td className="mono">{ts(c.timestamp)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
