/**
 * Discover a connected wallet's open zap positions (spec §5.1).
 *
 * Source of truth: ZapDeposited / ZapWithdrawn events filtered by indexed `user`, scanned from
 * historyFromBlock through chain tip (windowed for the RPC 10k cap, no silent truncation). A
 * recent session deposit stash is merged when the zap owner mapping confirms the position is still
 * open. Each row is enriched via lens.positionOverview when available.
 */

import { useQuery } from "@tanstack/react-query";
import { usePublicClient } from "wagmi";
import { STRATUM_ADDRESSES, UNICHAIN_SEPOLIA } from "../config/addresses";
import { readDepositStash } from "../lib/depositStash";
import {
  enrichPositionsWithLens,
  mergeDepositStash,
  scanUserZapEvents,
  type UserPosition,
} from "../lib/zapPositionDiscovery";

export type { UserPosition };

export function userPositionsQueryKey(address?: `0x${string}`, zap?: string) {
  return ["user-positions", address, zap] as const;
}

export function useUserPositions(address?: `0x${string}`) {
  const client = usePublicClient({ chainId: UNICHAIN_SEPOLIA.id });
  const zap = STRATUM_ADDRESSES.zap as `0x${string}`;
  const lens = STRATUM_ADDRESSES.lens as `0x${string}`;
  const enabled = !!client && !!address && !!STRATUM_ADDRESSES.zap;

  return useQuery({
    queryKey: userPositionsQueryKey(address, zap),
    enabled,
    refetchInterval: 20_000,
    staleTime: 10_000,
    queryFn: async (): Promise<UserPosition[]> => {
      if (!client || !address) return [];
      const tip = await client.getBlockNumber();
      const fromBlock = BigInt(STRATUM_ADDRESSES.historyFromBlock);

      const { deposits, withdrawn } = await scanUserZapEvents(client, zap, address, fromBlock, tip);

      const stash = readDepositStash();
      if (stash && stash.ts > Date.now() - 15 * 60_000) {
        await mergeDepositStash(client, zap, address, deposits, stash);
      }

      const open = [...deposits.values()].filter((p) => !withdrawn.has(p.positionId));
      await enrichPositionsWithLens(client, STRATUM_ADDRESSES.lens ? lens : undefined, open);
      return open;
    },
  });
}
