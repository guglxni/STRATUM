/**
 * On-chain history reader: epoch / swap / coverage-stress history pulled straight from the hook's
 * event logs via viem `getLogs`. This is the zero-setup fallback for the dashboard history tabs when
 * no subgraph is published - no Graph account, no indexer, no backend.
 *
 * The public RPC caps `getLogs` at 10k blocks, so the scan walks backward from the chain tip in
 * sub-10k windows, bounded to a recent span (and to the hook's deploy block), then resolves block
 * timestamps only for the rows actually shown.
 */

import type { PublicClient } from "viem";
import { EVENT_EPOCH_CLOSED, EVENT_SWAP_ACCOUNTED, EVENT_COVERAGE_STRESS } from "../abis/stratumEvents";
import { STRATUM_ADDRESSES } from "../config/addresses";
import type { EpochRow, SwapRow, CoverageEventRow } from "../graphql/queries";

const WINDOW = 9_000n; // under the RPC's 10k-block getLogs cap
const MAX_WINDOWS = 16n; // bound total lookback (~144k blocks) so the scan stays cheap

export interface OnchainHistory {
  epochs: EpochRow[];
  swaps: SwapRow[];
  coverage: CoverageEventRow[];
}

type AnyLog = {
  args: Record<string, unknown>;
  blockNumber: bigint | null;
  transactionHash: string | null;
  logIndex: number | null;
};

async function scan(
  client: PublicClient,
  event: typeof EVENT_EPOCH_CLOSED | typeof EVENT_SWAP_ACCOUNTED | typeof EVENT_COVERAGE_STRESS,
  poolId: `0x${string}`,
  from: bigint,
  to: bigint
): Promise<AnyLog[]> {
  const out: AnyLog[] = [];
  let cursor = to;
  while (cursor >= from) {
    const lo = cursor - WINDOW + 1n > from ? cursor - WINDOW + 1n : from;
    const logs = (await client.getLogs({
      address: STRATUM_ADDRESSES.hook as `0x${string}`,
      event,
      args: { poolId },
      fromBlock: lo,
      toBlock: cursor,
    })) as unknown as AnyLog[];
    out.push(...logs);
    if (lo <= from) break;
    cursor = lo - 1n;
  }
  return out;
}

/** Resolve unix-second timestamps for a set of block numbers (deduped). */
async function timestamps(client: PublicClient, blocks: bigint[]): Promise<Map<string, string>> {
  const uniq = Array.from(new Set(blocks.map((b) => b.toString())));
  const map = new Map<string, string>();
  await Promise.all(
    uniq.map(async (bn) => {
      try {
        const block = await client.getBlock({ blockNumber: BigInt(bn) });
        map.set(bn, block.timestamp.toString());
      } catch {
        map.set(bn, "0");
      }
    })
  );
  return map;
}

export async function fetchOnchainHistory(
  client: PublicClient,
  poolId: string,
  fromBlock: number,
  first = 20
): Promise<OnchainHistory> {
  const pid = poolId.toLowerCase() as `0x${string}`;
  const latest = await client.getBlockNumber();
  const lowerBound = latest > MAX_WINDOWS * WINDOW ? latest - MAX_WINDOWS * WINDOW : 0n;
  const start = BigInt(fromBlock) > lowerBound ? BigInt(fromBlock) : lowerBound;

  const [epochLogs, swapLogs, covLogs] = await Promise.all([
    scan(client, EVENT_EPOCH_CLOSED, pid, start, latest),
    scan(client, EVENT_SWAP_ACCOUNTED, pid, start, latest),
    scan(client, EVENT_COVERAGE_STRESS, pid, start, latest),
  ]);

  // newest first, then cap
  const byBlockDesc = (a: AnyLog, b: AnyLog) => Number((b.blockNumber ?? 0n) - (a.blockNumber ?? 0n));
  const epochTop = epochLogs.sort(byBlockDesc).slice(0, first);
  const swapTop = swapLogs.sort(byBlockDesc).slice(0, first);
  const covTop = covLogs.sort(byBlockDesc).slice(0, first);

  const tsMap = await timestamps(client, [
    ...epochTop.map((l) => l.blockNumber ?? 0n),
    ...swapTop.map((l) => l.blockNumber ?? 0n),
    ...covTop.map((l) => l.blockNumber ?? 0n),
  ]);
  const at = (bn: bigint | null) => tsMap.get((bn ?? 0n).toString()) ?? "0";
  const key = (l: AnyLog, i: number) => `${l.transactionHash ?? "tx"}-${l.logIndex ?? i}`;

  const epochs: EpochRow[] = epochTop.map((l, i) => ({
    id: key(l, i),
    epoch: String(l.args.epoch ?? "0"),
    seniorFunded: String(l.args.seniorFunded ?? "0"),
    juniorSurplus: String(l.args.juniorSurplus ?? "0"),
    juniorReserve: "0", // not carried on the event; per-epoch reserve lives only in the subgraph
    closedAt: at(l.blockNumber),
  }));

  const swaps: SwapRow[] = swapTop.map((l, i) => ({
    id: key(l, i),
    epoch: String(l.args.epoch ?? "0"),
    feeAmount: String(l.args.feeAmount ?? "0"),
    volatilityEWMA: String(l.args.volatilityEWMA ?? "0"),
    coverageRatioBps: Number(l.args.coverageRatioBps ?? 0),
    timestamp: at(l.blockNumber),
    txHash: (l.transactionHash ?? "0x") as string,
  }));

  const coverage: CoverageEventRow[] = covTop.map((l, i) => ({
    id: key(l, i),
    ratioBps: Number(l.args.ratioBps ?? 0),
    stressLevel: Number(l.args.stressLevel ?? 0),
    timestamp: at(l.blockNumber),
  }));

  return { epochs, swaps, coverage };
}
