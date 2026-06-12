/**
 * Epoch countdown widget (spec §5.5): "Epoch #N · closes in M:SS · Reactive EpochSettler subscribed".
 * Read-only; teaches the Reactive automation narrative. Links to the EpochSettler RSC on Lasna.
 */

import { useEpochProgress } from "../hooks/useEpochProgress";
import { STRATUM_LIVE_MULTICHAIN } from "../config/addresses";
import { explorerAddress, CHAIN_IDS } from "../config/explorers";

function mmss(total: number): string {
  const m = Math.floor(total / 60);
  const s = total % 60;
  return `${m}:${s.toString().padStart(2, "0")}`;
}

export default function EpochCountdown({ poolId }: { poolId: string }) {
  const ep = useEpochProgress(poolId);
  if (!ep.configured || ep.currentEpoch === undefined) return null;

  const rscUrl = explorerAddress(STRATUM_LIVE_MULTICHAIN.reactiveLasna.epochSettler, CHAIN_IDS.REACTIVE_LASNA);

  return (
    <div className="epoch-countdown" role="group" aria-label="Epoch countdown">
      <div className="epoch-countdown-row">
        <span className="epoch-countdown-epoch">Epoch #{ep.currentEpoch.toString()}</span>
        {ep.remainingSeconds !== undefined && (
          <span className="epoch-countdown-time mono">
            {ep.elapsed ? "closeable now" : `closes in ${mmss(ep.remainingSeconds)}`}
          </span>
        )}
      </div>
      {ep.progress !== undefined && (
        <div className="epoch-countdown-bar" aria-hidden>
          <div className="epoch-countdown-fill" style={{ width: `${Math.round(ep.progress * 100)}%` }} />
        </div>
      )}
      <div className="epoch-countdown-note">
        Anyone can call <span className="mono">closeEpoch</span> once elapsed —{" "}
        <a href={rscUrl} target="_blank" rel="noreferrer">
          Reactive EpochSettler
        </a>{" "}
        automates it.
      </div>
    </div>
  );
}
