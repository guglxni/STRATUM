/**
 * Epoch-close history. Prefers the subgraph when configured; otherwise reads the hook's EpochClosed
 * events directly from the chain (no indexer required).
 */

import { useQuery } from "@tanstack/react-query";
import { subgraphConfigured, subgraphQuery } from "../lib/subgraphClient";
import { POOL_EPOCHS, type EpochRow } from "../graphql/queries";
import { useOnchainHistory } from "./useOnchainHistory";

export function useSubgraphEpochs(poolId: string, first = 20) {
  const onSub = subgraphConfigured();
  const sub = useQuery({
    queryKey: ["subgraph", "epochs", poolId, first],
    enabled: onSub && !!poolId,
    refetchInterval: 30_000,
    queryFn: async () => {
      const data = await subgraphQuery<{ epoches: EpochRow[] }>(POOL_EPOCHS, { poolId: poolId.toLowerCase(), first });
      return data.epoches;
    },
  });
  const chain = useOnchainHistory(poolId, !onSub);
  if (onSub) return sub;
  return { data: chain.data?.epochs, isLoading: chain.isLoading, isError: chain.isError };
}
