/**
 * Pool inspect panel (protocol-interactivity §4.1): a collapsible read of the raw lens
 * poolOverview, to make the point that the UI never re-implements hook math — the lens computes
 * derived values with the same Solidity libraries the hook uses. R0, no wallet.
 */

import { useState } from "react";
import { formatUnits } from "viem";
import { usePoolOverview } from "../hooks/usePoolOverview";

function f(v: bigint): string {
  return parseFloat(formatUnits(v, 18)).toFixed(4);
}

export default function PoolInspectPanel() {
  const { overview, lensConfigured } = usePoolOverview();
  const [open, setOpen] = useState(false);

  if (!lensConfigured) return null;

  return (
    <div className="quickstart" style={{ marginBottom: 20 }}>
      <button className="quickstart-head" onClick={() => setOpen((v) => !v)} aria-expanded={open}>
        <span className="quickstart-badge">Inspect pool (lens)</span>
        <span className="quickstart-sub">Raw StratumLens.poolOverview — same libraries as the hook</span>
        <span className="quickstart-chev" aria-hidden>
          {open ? "▾" : "▸"}
        </span>
      </button>
      {open && (
        <div className="quickstart-body">
          {!overview ? (
            <p className="caption muted">Reading lens…</p>
          ) : (
            <div className="inspect-grid">
              <Field k="coverageRatioBps" v={`${(overview.coverageRatioBps / 100).toFixed(2)}%`} />
              <Field k="stressLevelBps" v={`${overview.stressLevelBps} bps`} />
              <Field k="nextSwapFeeBps" v={`${(overview.nextSwapFeeBps / 100).toFixed(2)}%`} />
              <Field k="currentEpoch" v={overview.currentEpoch.toString()} />
              <Field k="seniorTVL" v={f(overview.seniorTVL)} />
              <Field k="juniorTVL" v={f(overview.juniorTVL)} />
              <Field k="juniorReserve" v={f(overview.juniorReserve)} />
              <Field k="reserve0 / reserve1" v={`${f(overview.reserve0)} / ${f(overview.reserve1)}`} />
              <Field k="epochSeniorFunded" v={f(overview.epochSeniorFunded)} />
              <Field k="epochSeniorObligation" v={f(overview.epochSeniorObligation)} />
              <Field k="protocolFeeRealization" v={overview.protocolFeeRealization ? "on (v2)" : "off (ledger)"} />
              <Field k="initialized" v={String(overview.initialized)} />
            </div>
          )}
          <p className="fine-print" style={{ marginTop: 12 }}>
            These are the exact values the dashboard cards render; the lens is the single source so the UI
            never diverges from on-chain hook math.
          </p>
        </div>
      )}
    </div>
  );
}

function Field({ k, v }: { k: string; v: string }) {
  return (
    <div className="inspect-field">
      <span className="inspect-k mono">{k}</span>
      <span className="inspect-v mono">{v}</span>
    </div>
  );
}
