/**
 * Per-chain block explorers for STRATUM's multi-chain deployment.
 *
 * STRATUM spans four testnets, so a single hardcoded explorer base (the old behavior) produced
 * dead links for the Stylus (Arbitrum), Reactive (Lasna), and Across (Sepolia) addresses. This
 * module maps each chain id to its explorer and exposes helpers that build address / tx URLs.
 *
 * The primary chain (UNICHAIN_SEPOLIA) is driven entirely by env vars in addresses.ts — no chain
 * IDs or explorer URLs are repeated here.
 */

import { UNICHAIN_SEPOLIA } from "./addresses";

export interface ChainExplorer {
  /** Human label shown in the UI (e.g. "Arbiscan"). */
  name: string;
  /** Short chain label (e.g. "Arbitrum Sepolia"). */
  chain: string;
  /** Base URL, no trailing slash. */
  base: string;
}

/**
 * Canonical chain IDs used across STRATUM's multi-chain deployment.
 * UNICHAIN_SEPOLIA is intentionally read from the wagmi chain config so it tracks env overrides.
 */
export const CHAIN_IDS = {
  UNICHAIN_SEPOLIA: UNICHAIN_SEPOLIA.id,
  ARBITRUM_SEPOLIA: 421614,
  ETHEREUM_SEPOLIA: 11155111,
  REACTIVE_LASNA: 5318007,
} as const;

export const EXPLORERS: Record<number, ChainExplorer> = {
  [CHAIN_IDS.UNICHAIN_SEPOLIA]: {
    name: UNICHAIN_SEPOLIA.blockExplorers.default.name,
    chain: UNICHAIN_SEPOLIA.name,
    base: UNICHAIN_SEPOLIA.blockExplorers.default.url,
  },
  [CHAIN_IDS.ARBITRUM_SEPOLIA]: {
    name: "Arbiscan",
    chain: "Arbitrum Sepolia",
    base: "https://sepolia.arbiscan.io",
  },
  [CHAIN_IDS.ETHEREUM_SEPOLIA]: {
    name: "Etherscan",
    chain: "Ethereum Sepolia",
    base: "https://sepolia.etherscan.io",
  },
  [CHAIN_IDS.REACTIVE_LASNA]: {
    name: "Reactscan",
    chain: "Reactive Lasna",
    base: "https://lasna.reactscan.net",
  },
};

const DEFAULT_CHAIN = CHAIN_IDS.UNICHAIN_SEPOLIA;

/** Explorer URL for an address on a given chain (defaults to Unichain Sepolia). */
export function explorerAddress(addr: string, chainId: number = DEFAULT_CHAIN): string {
  const e = EXPLORERS[chainId] ?? EXPLORERS[DEFAULT_CHAIN];
  return `${e.base}/address/${addr}`;
}

/** Explorer URL for a transaction hash on a given chain. */
export function explorerTx(hash: string, chainId: number = DEFAULT_CHAIN): string {
  const e = EXPLORERS[chainId] ?? EXPLORERS[DEFAULT_CHAIN];
  return `${e.base}/tx/${hash}`;
}

/** Explorer display name for a chain (for "view on X" labels). */
export function explorerName(chainId: number = DEFAULT_CHAIN): string {
  return (EXPLORERS[chainId] ?? EXPLORERS[DEFAULT_CHAIN]).name;
}

/** Short-form address for compact display: 0x1234…abcd. */
export function shortAddr(addr: string, lead = 6, tail = 4): string {
  if (!addr || addr.length < lead + tail + 2) return addr;
  return `${addr.slice(0, lead)}…${addr.slice(-tail)}`;
}
