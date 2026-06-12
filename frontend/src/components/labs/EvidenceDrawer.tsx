/**
 * Integration evidence drawer (spec §6.2): a collapsible, judge-verifiable list of on-chain proof
 * for every integration. Each row opens the real contract on the right chain's explorer and notes
 * the LIVE_SYSTEM.md section with the full write-up. Copy-address for presenter convenience.
 */

import { useState } from "react";
import { INTEGRATION_EVIDENCE } from "../../config/integrationEvidence";
import { explorerAddress, explorerName, shortAddr } from "../../config/explorers";

export default function EvidenceDrawer() {
  const [open, setOpen] = useState(true);
  const [copied, setCopied] = useState<string | null>(null);

  const copy = async (addr: string) => {
    try {
      await navigator.clipboard.writeText(addr);
      setCopied(addr);
      setTimeout(() => setCopied((c) => (c === addr ? null : c)), 1500);
    } catch {
      /* clipboard blocked; no-op */
    }
  };

  return (
    <div className="quickstart" style={{ marginBottom: 24 }}>
      <button className="quickstart-head" onClick={() => setOpen((v) => !v)} aria-expanded={open}>
        <span className="quickstart-badge">Evidence drawer</span>
        <span className="quickstart-sub">Every claim, linked to a real contract on its explorer</span>
        <span className="quickstart-chev" aria-hidden>
          {open ? "▾" : "▸"}
        </span>
      </button>
      {open && (
        <div className="quickstart-body">
          <div className="evidence-list">
            {INTEGRATION_EVIDENCE.map((e) => (
              <div key={e.id} className="evidence-row">
                <div className="evidence-main">
                  <span className="evidence-int">{e.integration}</span>
                  <span className="evidence-label">{e.label}</span>
                  <span className="caption muted">
                    {explorerName(e.chainId)} · LIVE_SYSTEM {e.liveSystemRef}
                  </span>
                </div>
                <div className="evidence-actions">
                  <button className="btn-utility" onClick={() => copy(e.address)}>
                    {copied === e.address ? "Copied" : "Copy"}
                  </button>
                  <a className="btn-pill-ghost btn-pill-ghost-sm" href={explorerAddress(e.address, e.chainId)} target="_blank" rel="noreferrer">
                    {shortAddr(e.address)} ↗
                  </a>
                </div>
              </div>
            ))}
          </div>
        </div>
      )}
    </div>
  );
}
