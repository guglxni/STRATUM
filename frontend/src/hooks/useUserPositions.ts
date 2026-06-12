/**
 * Discover a connected wallet's open zap positions (spec §5.1).
 *
 * Source of truth: the zap's own ZapDeposited(poolId, positionId, user, ...) / ZapWithdrawn events,
 * filtered by indexed `user` — far cleaner than the TrancheDeposited.owner=zap workaround. For each
 * still-open positionId we read lens.positionOverview for live tranche / IL / coupon detail. RPC
 * getLogs is windowed to respect the 10k-block cap; the scan is bounded to a recent window and logs
 * a console note if it truncates (honesty contract: no silent caps).
 */

import { useQuery } from "@tanstack/react-query";
import { usePublicClient } from "wagmi";
import { parseAbiItem } from "viem";
import { STRATUM_LENS_ABI, type PositionOverviewData } from "../abis/stratumLens";
import { STRATUM_ADDRESSES, UNICHAIN_SEPOLIA } from "../config/addresses";

const EVENT_ZAP_DEPOSITED = parseAbiItem(
  "event ZapDeposited(bytes32 indexed poolId, bytes32 indexed positionId, address indexed user, uint8 tranche, uint128 liquidity)"
);
const EVENT_ZAP_WITHDRAWN = parseAbiItem(
  "event ZapWithdrawn(bytes32 indexed poolId, bytes32 indexed positionId, address indexed user)"
);

const WINDOW = 9_000n;
const MAX_WINDOWS = 24; // ~216k blocks back from tip; bounds latency on public RPC.

export interface UserPosition {
  positionId: `0x${string}`;
  poolId: `0x${string}`;
  tranche: number;
  liquidity: bigint;
  overview?: PositionOverviewData;
}

export function useUserPositions(address?: `0x${string}`) {
  const client = usePublicClient({ chainId: UNICHAIN_SEPOLIA.id });
  const zap = STRATUM_ADDRESSES.zap as `0x${string}`;
  const lens = STRATUM_ADDRESSES.lens as `0x${string}`;
  const enabled = !!client && !!address && !!STRATUM_ADDRESSES.zap;

  return useQuery({
    queryKey: ["user-positions", address, zap],
    enabled,
    refetchInterval: 20_000,
    queryFn: async (): Promise<UserPosition[]> => {
      if (!client || !address) return [];
      const tip = await client.getBlockNumber();
      const floor = BigInt(STRATUM_ADDRESSES.historyFromBlock);
      const lowerBound = tip > WINDOW * BigInt(MAX_WINDOWS) ? tip - WINDOW * BigInt(MAX_WINDOWS) : 0n;
      const start = floor > lowerBound ? floor : lowerBound;
      if (lowerBound > floor) {
        console.info("[useUserPositions] scan window capped; older positions may be omitted.");
      }

      const deposits = new Map<string, UserPosition>();
      const withdrawn = new Set<string>();

      for (let from = tip; from >= start; from -= WINDOW + 1n) {
        const to = from;
        const lo = from > start + WINDOW ? from - WINDOW : start;
        const [dep, wd] = await Promise.all([
          client.getLogs({ address: zap, event: EVENT_ZAP_DEPOSITED, args: { user: address }, fromBlock: lo, toBlock: to }),
          client.getLogs({ address: zap, event: EVENT_ZAP_WITHDRAWN, args: { user: address }, fromBlock: lo, toBlock: to }),
        ]);
        for (const l of wd) if (l.args.positionId) withdrawn.add(l.args.positionId);
        for (const l of dep) {
          const pid = l.args.positionId;
          if (!pid || deposits.has(pid)) continue;
          deposits.set(pid, {
            positionId: pid,
            poolId: (l.args.poolId ?? "0x") as `0x${string}`,
            tranche: Number(l.args.tranche ?? 0),
            liquidity: (l.args.liquidity ?? 0n) as bigint,
          });
        }
        if (lo === start) break;
      }

      const open = [...deposits.values()].filter((p) => !withdrawn.has(p.positionId));

      // Enrich with lens.positionOverview when the lens is configured.
      if (lens && STRATUM_ADDRESSES.lens) {
        await Promise.all(
          open.map(async (p) => {
            try {
              const o = await client.readContract({
                address: lens,
                abi: STRATUM_LENS_ABI,
                functionName: "positionOverview",
                args: [p.positionId],
              });
              p.overview = o as PositionOverviewData;
            } catch {
              /* leave overview undefined; row still shows from event data */
            }
          })
        );
      }

      return open;
    },
  });
}
