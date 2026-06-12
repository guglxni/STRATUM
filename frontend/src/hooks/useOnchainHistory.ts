/**
 * Shared on-chain history query. All three history tables observe the SAME react-query key, so the
 * log scan runs once per pool and is shared (react-query dedupes). Enabled only when no subgraph is
 * configured - the subgraph remains the preferred source when available.
 */

import { useQuery } from "@tanstack/react-query";
import { usePublicClient } from "wagmi";
import { fetchOnchainHistory, type OnchainHistory } from "../lib/onchainHistory";
import { STRATUM_ADDRESSES } from "../config/addresses";

export function useOnchainHistory(poolId: string, enabled: boolean) {
  const client = usePublicClient();
  return useQuery<OnchainHistory>({
    queryKey: ["onchain-history", poolId],
    enabled: enabled && !!poolId && !!client && !!STRATUM_ADDRESSES.hook,
    refetchInterval: 30_000,
    staleTime: 15_000,
    queryFn: () => fetchOnchainHistory(client!, poolId, STRATUM_ADDRESSES.historyFromBlock),
  });
}
