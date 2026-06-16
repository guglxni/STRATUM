/**
 * Shared zap position discovery helpers used by useUserPositions and useZapDeposit.
 *
 * Scans windowed getLogs from the hook deploy floor through chain tip (no silent block cap),
 * merges a recent session deposit stash, and can parse ZapDeposited straight from a receipt.
 */

import type { PublicClient, TransactionReceipt } from "viem";
import { decodeEventLog, parseAbiItem, zeroAddress } from "viem";
import { STRATUM_LENS_ABI, type PositionOverviewData } from "../abis/stratumLens";
import { STRATUM_ZAP_ABI } from "../abis/stratumZap";
import type { DepositStash } from "./depositStash";

export const EVENT_ZAP_DEPOSITED = parseAbiItem(
  "event ZapDeposited(bytes32 indexed poolId, bytes32 indexed positionId, address indexed user, uint8 tranche, uint128 liquidity)"
);
export const EVENT_ZAP_WITHDRAWN = parseAbiItem(
  "event ZapWithdrawn(bytes32 indexed poolId, bytes32 indexed positionId, address indexed user)"
);

const WINDOW = 9_000n;

export interface UserPosition {
  positionId: `0x${string}`;
  poolId: `0x${string}`;
  tranche: number;
  liquidity: bigint;
  overview?: PositionOverviewData;
}

export interface ZapDepositedEvent {
  poolId: `0x${string}`;
  positionId: `0x${string}`;
  user: `0x${string}`;
  tranche: number;
  liquidity: bigint;
}

/** Parse the first ZapDeposited log emitted by the zap in a transaction receipt. */
export function parseZapDepositedFromReceipt(
  receipt: TransactionReceipt,
  zap: `0x${string}`
): ZapDepositedEvent | undefined {
  for (const log of receipt.logs) {
    if (log.address.toLowerCase() !== zap.toLowerCase()) continue;
    try {
      const decoded = decodeEventLog({
        abi: [EVENT_ZAP_DEPOSITED],
        data: log.data,
        topics: log.topics,
      });
      if (decoded.eventName !== "ZapDeposited") continue;
      const { poolId, positionId, user, tranche, liquidity } = decoded.args;
      if (!poolId || !positionId || !user) continue;
      return {
        poolId: poolId as `0x${string}`,
        positionId: positionId as `0x${string}`,
        user: user as `0x${string}`,
        tranche: Number(tranche ?? 0),
        liquidity: (liquidity ?? 0n) as bigint,
      };
    } catch {
      /* not a ZapDeposited log */
    }
  }
  return undefined;
}

/** True when the zap still records `user` as owner of `positionId`. */
export async function isZapPositionOpen(
  client: PublicClient,
  zap: `0x${string}`,
  positionId: `0x${string}`,
  user: `0x${string}`
): Promise<boolean> {
  try {
    const owner = (await client.readContract({
      address: zap,
      abi: STRATUM_ZAP_ABI,
      functionName: "zapPositionOwner",
      args: [positionId],
    })) as `0x${string}`;
    return owner.toLowerCase() === user.toLowerCase() && owner !== zeroAddress;
  } catch {
    return false;
  }
}

/** Windowed getLogs scan for a wallet's zap deposit / withdraw events. */
export async function scanUserZapEvents(
  client: PublicClient,
  zap: `0x${string}`,
  user: `0x${string}`,
  fromBlock: bigint,
  toBlock: bigint
): Promise<{ deposits: Map<string, UserPosition>; withdrawn: Set<string> }> {
  const deposits = new Map<string, UserPosition>();
  const withdrawn = new Set<string>();

  for (let cursor = toBlock; cursor >= fromBlock; ) {
    const lo = cursor - WINDOW + 1n > fromBlock ? cursor - WINDOW + 1n : fromBlock;
    const [dep, wd] = await Promise.all([
      client.getLogs({
        address: zap,
        event: EVENT_ZAP_DEPOSITED,
        args: { user },
        fromBlock: lo,
        toBlock: cursor,
      }),
      client.getLogs({
        address: zap,
        event: EVENT_ZAP_WITHDRAWN,
        args: { user },
        fromBlock: lo,
        toBlock: cursor,
      }),
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
    if (lo <= fromBlock) break;
    cursor = lo - 1n;
  }

  return { deposits, withdrawn };
}

/** Include a recent session stash row when the on-chain owner mapping confirms it is still open. */
export async function mergeDepositStash(
  client: PublicClient,
  zap: `0x${string}`,
  user: `0x${string}`,
  deposits: Map<string, UserPosition>,
  stash: DepositStash | null
): Promise<void> {
  if (!stash?.positionId) return;
  if (deposits.has(stash.positionId)) return;
  const open = await isZapPositionOpen(client, zap, stash.positionId, user);
  if (!open) return;
  deposits.set(stash.positionId, {
    positionId: stash.positionId,
    poolId: stash.poolId as `0x${string}`,
    tranche: stash.tranche,
    liquidity: 0n,
  });
}

export async function enrichPositionsWithLens(
  client: PublicClient,
  lens: `0x${string}` | undefined,
  positions: UserPosition[]
): Promise<void> {
  if (!lens) return;
  await Promise.all(
    positions.map(async (p) => {
      try {
        const o = await client.readContract({
          address: lens,
          abi: STRATUM_LENS_ABI,
          functionName: "positionOverview",
          args: [p.positionId],
        });
        p.overview = o as PositionOverviewData;
        if (p.liquidity === 0n && p.overview.position.liquidity > 0n) {
          p.liquidity = p.overview.position.liquidity;
        }
      } catch {
        /* row still renders from event / stash data */
      }
    })
  );
}
