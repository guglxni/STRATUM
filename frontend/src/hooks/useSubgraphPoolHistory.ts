/**
 * Coverage-stress timeline. Prefers the subgraph when configured; otherwise reads the hook's
 * CoverageStress events directly from the chain.
 */

import { useQuery } from "@tanstack/react-query";
import { subgraphConfigured, subgraphQuery } from "../lib/subgraphClient";
import { COVERAGE_EVENTS, type CoverageEventRow } from "../graphql/queries";
import { useOnchainHistory } from "./useOnchainHistory";

export function useSubgraphCoverageEvents(poolId: string, first = 25) {
  const onSub = subgraphConfigured();
  const sub = useQuery({
    queryKey: ["subgraph", "coverage", poolId, first],
    enabled: onSub && !!poolId,
    refetchInterval: 30_000,
    queryFn: async () => {
      const data = await subgraphQuery<{ coverageStressEvents: CoverageEventRow[] }>(COVERAGE_EVENTS, {
        poolId: poolId.toLowerCase(),
        first,
      });
      return data.coverageStressEvents;
    },
  });
  const chain = useOnchainHistory(poolId, !onSub);
  if (onSub) return sub;
  return { data: chain.data?.coverage, isLoading: chain.isLoading, isError: chain.isError };
}
