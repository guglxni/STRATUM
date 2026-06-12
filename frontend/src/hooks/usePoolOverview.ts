/**
 * Phase C: single-call pool reads through StratumLens.poolOverview.
 *
 * When the lens address is configured, one eth_call replaces the dashboard's per-field hook
 * reads and returns the derived values (coverage, stress, next swap fee, protocol-fee state)
 * computed by the same Solidity libraries the hook itself uses. When the lens is unset the
 * hook returns `overview: undefined` and the dashboard falls back to direct hook reads.
 */

import { useReadContract } from "wagmi";
import { STRATUM_LENS_ABI, type PoolOverviewData } from "../abis/stratumLens";
import { STRATUM_ADDRESSES } from "../config/addresses";
import { buildDemoPoolKey, type PoolKeyStruct } from "../lib/poolKey";

export interface UsePoolOverviewResult {
  overview: PoolOverviewData | undefined;
  lensConfigured: boolean;
  poolKey: PoolKeyStruct | null;
  isLoading: boolean;
  isError: boolean;
  refetch: () => void;
}

export function usePoolOverview(): UsePoolOverviewResult {
  const lens = STRATUM_ADDRESSES.lens;
  const poolKey = buildDemoPoolKey();
  const lensConfigured = !!lens && !!poolKey;

  const { data, isLoading, isError, refetch } = useReadContract({
    address: lens as `0x${string}`,
    abi: STRATUM_LENS_ABI,
    functionName: "poolOverview",
    args: poolKey ? [poolKey] : undefined,
    query: {
      enabled: lensConfigured,
      refetchInterval: 10_000,
    },
  });

  return {
    overview: data as PoolOverviewData | undefined,
    lensConfigured,
    poolKey,
    isLoading,
    isError,
    refetch,
  };
}
