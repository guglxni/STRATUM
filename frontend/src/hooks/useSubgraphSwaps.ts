/**
 * Swap fee-accounting history. Prefers the subgraph when configured; otherwise reads the hook's
 * SwapAccounted events directly from the chain.
 */

import { useQuery } from "@tanstack/react-query";
import { subgraphConfigured, subgraphQuery } from "../lib/subgraphClient";
import { POOL_SWAPS, type SwapRow } from "../graphql/queries";
import { useOnchainHistory } from "./useOnchainHistory";

export function useSubgraphSwaps(poolId: string, first = 25) {
  const onSub = subgraphConfigured();
  const sub = useQuery({
    queryKey: ["subgraph", "swaps", poolId, first],
    enabled: onSub && !!poolId,
    refetchInterval: 30_000,
    queryFn: async () => {
      const data = await subgraphQuery<{ swaps: SwapRow[] }>(POOL_SWAPS, { poolId: poolId.toLowerCase(), first });
      return data.swaps;
    },
  });
  const chain = useOnchainHistory(poolId, !onSub);
  if (onSub) return sub;
  return { data: chain.data?.swaps, isLoading: chain.isLoading, isError: chain.isError };
}
