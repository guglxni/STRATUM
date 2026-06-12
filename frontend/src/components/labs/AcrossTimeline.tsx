/**
 * Across / CPHR bridge journey replay (spec §6.2). A read-only timeline of the real closed loop
 * documented in LIVE_SYSTEM.md §5: origin bridgeReserve → Across FundsDeposited → Sepolia relayer
 * fill → destination ReserveFunded. Each step links to the relevant contract. Evidence-only: the
 * bridgeReserve write is attestation-gated and never a judge button (§6.3).
 *
 * Interactivity (no on-chain write): a "Replay" control walks the four steps in sequence with an
 * active highlight and completed-checks, so judges can watch the cross-chain loop play out rather
 * than reading a static list. The data is the proven historical bridge; the animation is purely
 * presentational.
 */

import { useCallback, useEffect, useRef, useState } from "react";
import LabCard from "./LabCard";
import { STRATUM_ADDRESSES, STRATUM_LIVE_MULTICHAIN } from "../../config/addresses";
import { explorerAddress, explorerName, CHAIN_IDS } from "../../config/explorers";

interface Step {
  n: number;
  title: string;
  caption: string;
  addr: string;
  chainId: number;
  /** Short chain badge shown on the step. */
  net: string;
}

const STEPS: Step[] = [
  {
    n: 1,
    title: "Origin: CPHR bridgeReserve",
    caption: "Junior reserve leaves Unichain when the local buffer is stressed (depositId 6099, 0.001 WETH).",
    addr: STRATUM_ADDRESSES.cphr,
    chainId: CHAIN_IDS.UNICHAIN_SEPOLIA,
    net: "Unichain",
  },
  {
    n: 2,
    title: "Across SpokePool: FundsDeposited",
    caption: "The canonical Across V3 SpokePool on Unichain Sepolia records the deposit.",
    addr: STRATUM_LIVE_MULTICHAIN.acrossSpokePoolUnichain,
    chainId: CHAIN_IDS.UNICHAIN_SEPOLIA,
    net: "Across",
  },
  {
    n: 3,
    title: "Relayer fill on Sepolia",
    caption: "An Across relayer fills on Ethereum Sepolia (API: filled, actionsSucceeded).",
    addr: STRATUM_LIVE_MULTICHAIN.sepolia.acrossSpokePool,
    chainId: CHAIN_IDS.ETHEREUM_SEPOLIA,
    net: "Sepolia",
  },
  {
    n: 4,
    title: "Destination: ReserveFunded",
    caption: "Destination CPHR credits the reserve (reserve1 = 0.9995 WETH) — FR-19 loop closed.",
    addr: STRATUM_LIVE_MULTICHAIN.sepolia.cphr,
    chainId: CHAIN_IDS.ETHEREUM_SEPOLIA,
    net: "Sepolia",
  },
];

const STEP_MS = 1500;

export default function AcrossTimeline() {
  // active = index of the step currently lit. -1 before playback, STEPS.length when the loop closes.
  const [active, setActive] = useState(-1);
  const [playing, setPlaying] = useState(false);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);

  const clear = () => {
    if (timer.current) {
      clearTimeout(timer.current);
      timer.current = null;
    }
  };

  // Drive the walk-through. Each tick advances one step until the loop closes.
  useEffect(() => {
    if (!playing) return;
    if (active >= STEPS.length) {
      setPlaying(false);
      return;
    }
    timer.current = setTimeout(() => setActive((a) => a + 1), STEP_MS);
    return clear;
  }, [playing, active]);

  const replay = useCallback(() => {
    clear();
    setActive(0);
    setPlaying(true);
  }, []);

  const closed = active >= STEPS.length;

  return (
    <LabCard
      protocol="Across · CPHR"
      enables="Cross-chain junior-reserve top-up so the senior buffer can be defended from another chain (FR-18/FR-19)."
      trigger="Coverage-stress handler / bridgeReserve (attestation-gated)."
      klass="W2"
      status="evidence"
      chainHint="Unichain Sepolia → Ethereum Sepolia"
    >
      <div className="across-controls">
        <button className="btn-pill btn-pill-sm" onClick={replay}>
          {active < 0 ? "▶ Replay bridge loop" : playing ? "Replaying…" : "↻ Replay again"}
        </button>
        <span className={`across-status ${closed ? "across-status-done" : ""}`}>
          {closed ? "Loop closed · reserve funded" : active < 0 ? "Proven historical loop" : `Step ${active + 1} of ${STEPS.length}`}
        </span>
      </div>

      <ol className="stepper">
        {STEPS.map((s, i) => {
          const state = active < 0 ? "idle" : i < active ? "done" : i === active ? "active" : "idle";
          return (
            <li key={s.n} className={`stepper-step stepper-${state}`}>
              <span className="stepper-n">{state === "done" ? "✓" : s.n}</span>
              <div className="stepper-body">
                <div className="stepper-title">
                  {s.title}
                  <span className="stepper-net">{s.net}</span>
                </div>
                <div className="stepper-note">{s.caption}</div>
                <a
                  className="stepper-link mono"
                  href={explorerAddress(s.addr, s.chainId)}
                  target="_blank"
                  rel="noreferrer"
                >
                  {s.addr.slice(0, 14)}… · {explorerName(s.chainId)} ↗
                </a>
              </div>
            </li>
          );
        })}
      </ol>
      <p className="fine-print">
        bridgeReserve requires an operator attestation — shown here as a proven historical loop, not a judge
        button (honesty contract). Replay animates the recorded steps; it sends no transaction.
      </p>
    </LabCard>
  );
}
