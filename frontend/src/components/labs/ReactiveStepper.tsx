/**
 * Reactive Network stepper (spec §5.2): a visual map of how a hook event becomes an automated
 * callback — Unichain hook emits → Lasna RSC (subscribed topic) → Reactive callback proxy →
 * Unichain twin. Not a fake trigger: it documents the real wiring and links each hop to its
 * explorer. The live event feed (#app) shows when a real event actually arrives.
 */

import LabCard from "./LabCard";
import { STRATUM_ADDRESSES, STRATUM_LIVE_MULTICHAIN } from "../../config/addresses";
import { explorerAddress, CHAIN_IDS } from "../../config/explorers";

const STEPS = [
  {
    n: 1,
    title: "Unichain hook emits EpochClosed",
    addr: STRATUM_ADDRESSES.hook,
    chainId: CHAIN_IDS.UNICHAIN_SEPOLIA,
    note: "A normal pool lifecycle event — no keeper, no cron.",
  },
  {
    n: 2,
    title: "Lasna RSC reacts (subscribed topic)",
    addr: STRATUM_LIVE_MULTICHAIN.reactiveLasna.epochSettler,
    chainId: CHAIN_IDS.REACTIVE_LASNA,
    note: "EpochSettler RSC is subscribed to EpochClosed on the live hook.",
  },
  {
    n: 3,
    title: "Reactive callback proxy executes",
    addr: STRATUM_LIVE_MULTICHAIN.reactiveLasna.callbackProxyUnichain,
    chainId: CHAIN_IDS.UNICHAIN_SEPOLIA,
    note: "Set as each twin's reactiveCallbackSender.",
  },
  {
    n: 4,
    title: "Unichain twin settles",
    addr: STRATUM_ADDRESSES.epochSettler,
    chainId: CHAIN_IDS.UNICHAIN_SEPOLIA,
    note: "The twin runs the automated settlement action.",
  },
];

export default function ReactiveStepper() {
  return (
    <LabCard
      protocol="Reactive Network"
      enables="Autonomic epoch settlement, coverage response, and reserve balancing — no off-chain keeper."
      trigger="Each hook event (EpochClosed / CoverageStress / JuniorReserveUpdated)."
      klass="R0"
      status="live"
      chainHint="Lasna ↔ Unichain Sepolia"
    >
      <ol className="stepper">
        {STEPS.map((s) => (
          <li key={s.n} className="stepper-step">
            <span className="stepper-n">{s.n}</span>
            <div className="stepper-body">
              <div className="stepper-title">{s.title}</div>
              <div className="stepper-note">{s.note}</div>
              <a className="stepper-link mono" href={explorerAddress(s.addr, s.chainId)} target="_blank" rel="noreferrer">
                {s.addr.slice(0, 14)}… ↗
              </a>
            </div>
          </li>
        ))}
      </ol>
      <p className="fine-print">
        The feed on the dashboard highlights the matching row when a real event arrives — RSC callbacks fire
        on these events, not on every deposit.
      </p>
    </LabCard>
  );
}
