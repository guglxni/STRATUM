/**
 * Epoch progress for the EpochCountdown widget (spec §5.5 / §4.4).
 *
 * Reads the hook's poolState (currentEpoch, epochStartTimestamp, smoothingEpochSeconds) and derives
 * the time remaining until the current epoch is eligible for closeEpoch. A 1s client ticker drives
 * the countdown without re-reading the chain. closeEpoch is permissionless once elapsed and is what
 * Reactive's EpochSettler twin automates — the widget teaches that, it does not require manual close.
 */

import { useEffect, useState } from "react";
import { useReadContract } from "wagmi";
import { STRATUM_HOOK_ABI } from "../abis/stratumHook";
import { STRATUM_ADDRESSES, UNICHAIN_SEPOLIA } from "../config/addresses";

export interface EpochProgress {
  configured: boolean;
  currentEpoch?: bigint;
  /** Seconds remaining until the epoch can be closed (0 = elapsed, eligible now). */
  remainingSeconds?: number;
  /** Total epoch length in seconds. */
  epochSeconds?: number;
  /** Fraction elapsed 0..1 for a progress bar. */
  progress?: number;
  /** True once the epoch has elapsed (closeEpoch eligible). */
  elapsed: boolean;
}

export function useEpochProgress(poolId: string): EpochProgress {
  const enabled = !!poolId && !!STRATUM_ADDRESSES.hook;
  const { data } = useReadContract({
    address: STRATUM_ADDRESSES.hook as `0x${string}`,
    abi: STRATUM_HOOK_ABI,
    functionName: "poolState",
    chainId: UNICHAIN_SEPOLIA.id,
    args: [poolId as `0x${string}`],
    query: { enabled, refetchInterval: 10_000 },
  });

  // 1s ticker so the countdown updates smoothly between 10s chain reads.
  const [now, setNow] = useState(() => Math.floor(Date.now() / 1000));
  useEffect(() => {
    const t = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 1000);
    return () => clearInterval(t);
  }, []);

  if (!data) return { configured: enabled, elapsed: false };

  const s = data as { currentEpoch: bigint; epochStartTimestamp: bigint; smoothingEpochSeconds: number };
  const epochSeconds = Number(s.smoothingEpochSeconds);
  if (!epochSeconds) return { configured: enabled, currentEpoch: s.currentEpoch, elapsed: false };

  const start = Number(s.epochStartTimestamp);
  const elapsedSec = Math.max(0, now - start);
  const remainingSeconds = Math.max(0, epochSeconds - elapsedSec);
  const progress = Math.min(1, elapsedSec / epochSeconds);

  return {
    configured: enabled,
    currentEpoch: s.currentEpoch,
    remainingSeconds,
    epochSeconds,
    progress,
    elapsed: remainingSeconds === 0,
  };
}
