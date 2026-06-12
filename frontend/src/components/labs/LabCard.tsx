/**
 * Shared Feature Lab card shell (spec §2.1 template). Header (protocol + what it enables), the
 * interaction class badge (R0/R1/W1/W2), a trigger line (which hook event / user action), the
 * interactive body (children), and an optional on-chain proof link.
 */

import type { ReactNode } from "react";

export type InteractionClass = "R0" | "R1" | "W1" | "W2" | "W3";

const CLASS_LABEL: Record<InteractionClass, string> = {
  R0: "Read · no wallet",
  R1: "Sign · no gas",
  W1: "Write · your wallet",
  W2: "Permissioned",
  W3: "Presenter CLI",
};

export type LabStatus = "live" | "partial" | "evidence";

const STATUS_LABEL: Record<LabStatus, string> = {
  live: "live",
  partial: "partial",
  evidence: "evidence-only",
};

interface Props {
  protocol: string;
  enables: string;
  trigger: string;
  klass: InteractionClass;
  status: LabStatus;
  /** "Reading Arbitrum Sepolia" style chain hint. */
  chainHint?: string;
  proofHref?: string;
  proofLabel?: string;
  children: ReactNode;
}

export default function LabCard({
  protocol,
  enables,
  trigger,
  klass,
  status,
  chainHint,
  proofHref,
  proofLabel,
  children,
}: Props) {
  return (
    <div className="lab-card">
      <div className="lab-head">
        <div className="lab-head-main">
          <span className="lab-protocol">{protocol}</span>
          <span className={`lab-status lab-status-${status}`}>{STATUS_LABEL[status]}</span>
        </div>
        <span className="lab-class" title={CLASS_LABEL[klass]}>
          {klass}
        </span>
      </div>
      <p className="lab-enables">{enables}</p>
      <div className="lab-trigger">
        <span className="lab-trigger-k">Trigger</span>
        <span className="lab-trigger-v">{trigger}</span>
      </div>
      <div className="lab-body">{children}</div>
      <div className="lab-foot">
        {chainHint && <span className="lab-chain">{chainHint}</span>}
        {proofHref && (
          <a className="lab-proof" href={proofHref} target="_blank" rel="noreferrer">
            {proofLabel ?? "On-chain proof"} ↗
          </a>
        )}
      </div>
    </div>
  );
}
