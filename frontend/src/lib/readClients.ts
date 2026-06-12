/**
 * Read-only viem public clients for STRATUM's secondary chains (spec §15.3). Stylus (Arbitrum
 * Sepolia) and Chainlink (Ethereum Sepolia) reads run over public RPC without requiring the user to
 * switch their wallet network. Memoized per chain so components share one client. RPC URLs are
 * env-overridable (§17): NEXT_PUBLIC_ARBITRUM_SEPOLIA_RPC, NEXT_PUBLIC_SEPOLIA_RPC.
 */

import { createPublicClient, http, type PublicClient } from "viem";
import { CHAIN_IDS } from "../config/explorers";

declare const process: { env: Record<string, string | undefined> };

const ARBITRUM_SEPOLIA_RPC = process.env.NEXT_PUBLIC_ARBITRUM_SEPOLIA_RPC || "https://sepolia-rollup.arbitrum.io/rpc";
const SEPOLIA_RPC = process.env.NEXT_PUBLIC_SEPOLIA_RPC || "https://ethereum-sepolia-rpc.publicnode.com";

const RPC_BY_CHAIN: Record<number, string> = {
  [CHAIN_IDS.ARBITRUM_SEPOLIA]: ARBITRUM_SEPOLIA_RPC,
  [CHAIN_IDS.ETHEREUM_SEPOLIA]: SEPOLIA_RPC,
};

const cache = new Map<number, PublicClient>();

/** Public read client for a secondary chain. Throws for unknown chains (programmer error). */
export function readClient(chainId: number): PublicClient {
  const cached = cache.get(chainId);
  if (cached) return cached;
  const rpc = RPC_BY_CHAIN[chainId];
  if (!rpc) throw new Error(`No read RPC configured for chain ${chainId}`);
  const client = createPublicClient({ transport: http(rpc) }) as PublicClient;
  cache.set(chainId, client);
  return client;
}
