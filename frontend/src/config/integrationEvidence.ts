/**
 * Curated, honest manifest of STRATUM's multi-chain integrations for the dashboard status strip
 * (spec §5.3) and, later, the integrations evidence page (§6.2).
 *
 * Each entry links to a REAL deployed contract on its chain's explorer - verifiable without a repo
 * checkout. Status is deliberately conservative: Brevis is "partial" because hosted-gateway proof
 * submission is window-limited on testnet (docs/BREVIS_ROUTE_RESOLUTION.md), never shown as fully
 * live. `triggerEvent` exists to teach the event map: RSCs/peripherals fire on specific hook events,
 * not on every wallet action (spec §2.2).
 */

import { STRATUM_ADDRESSES, STRATUM_LIVE_MULTICHAIN } from "./addresses";
import { CHAIN_IDS } from "./explorers";

export type IntegrationStatus = "live" | "partial" | "unconfigured";

export interface IntegrationEntry {
  id: string;
  name: string;
  status: IntegrationStatus;
  /** Chain whose explorer the address resolves on. */
  chainId: number;
  /** Representative on-chain contract for this integration (may be empty when unconfigured). */
  address: string;
  /** The hook event / call path that actually exercises this integration. */
  triggerEvent: string;
  /** One honest line: what it is and its real limits. */
  blurb: string;
}

const live = (addr: string): IntegrationStatus => (addr ? "live" : "unconfigured");

export const INTEGRATIONS: IntegrationEntry[] = [
  {
    id: "reactive",
    name: "Reactive",
    status: live(STRATUM_LIVE_MULTICHAIN.reactiveLasna.epochSettler),
    chainId: CHAIN_IDS.REACTIVE_LASNA,
    address: STRATUM_LIVE_MULTICHAIN.reactiveLasna.epochSettler,
    triggerEvent: "EpochClosed · CoverageStress · JuniorReserveUpdated",
    blurb: "RSCs on Lasna subscribed to the live hook; callbacks fire on specific events, not every deposit.",
  },
  {
    id: "across",
    name: "Across",
    status: live(STRATUM_ADDRESSES.cphr),
    chainId: CHAIN_IDS.UNICHAIN_SEPOLIA,
    address: STRATUM_ADDRESSES.cphr,
    triggerEvent: "bridgeReserve (coverage-stress handler)",
    blurb: "CrossPoolHedgingRouter bridges junior reserves Unichain → Sepolia over Across V3 (full loop live).",
  },
  {
    id: "stylus",
    name: "Stylus",
    status: live(STRATUM_LIVE_MULTICHAIN.stylusEngineArbitrum),
    chainId: CHAIN_IDS.ARBITRUM_SEPOLIA,
    address: STRATUM_LIVE_MULTICHAIN.stylusEngineArbitrum,
    triggerEvent: "forecastVolatility / runMatch (eth_call)",
    blurb: "Rust ML forward-volatility engine on Arbitrum Stylus (activated WASM), read via StylusShim.",
  },
  {
    id: "eigenlayer",
    name: "EigenLayer",
    status: live(STRATUM_ADDRESSES.matchAttestation),
    chainId: CHAIN_IDS.UNICHAIN_SEPOLIA,
    address: STRATUM_ADDRESSES.matchAttestation,
    triggerEvent: "isAttested(matchHash) gate",
    blurb: "M-of-N ECDSA attestation quorum that authorizes CPHR bridgeReserve (FR-24).",
  },
  {
    id: "brevis",
    name: "Brevis",
    status: "partial",
    chainId: CHAIN_IDS.UNICHAIN_SEPOLIA,
    address: STRATUM_ADDRESSES.brevisShim,
    triggerEvent: "BrevisProofRequested (settlement path)",
    blurb: "Verifier shim deployed on-chain; hosted Sepolia gateway proof window is partial on testnet.",
  },
  {
    id: "chainlink",
    name: "Chainlink",
    status: live(STRATUM_LIVE_MULTICHAIN.sepolia.chainlinkEthUsdFeed),
    chainId: CHAIN_IDS.ETHEREUM_SEPOLIA,
    address: STRATUM_LIVE_MULTICHAIN.sepolia.chainlinkEthUsdFeed,
    triggerEvent: "ETH/USD Data Feed read",
    blurb: "Benchmark for the senior target rate only — never the IL accounting (golden rule 2).",
  },
];

/** Glyph + screen-reader word for each status. */
export const STATUS_GLYPH: Record<IntegrationStatus, { dot: string; word: string }> = {
  live: { dot: "●", word: "live" },
  partial: { dot: "◐", word: "partial" },
  unconfigured: { dot: "○", word: "not configured" },
};

/**
 * Curated on-chain evidence manifest for the evidence drawer (spec §6.2). Each row points at a real,
 * verifiable contract on the right chain's explorer. LIVE_SYSTEM.md publishes the tx hashes in
 * truncated form, so we link the deployed contracts (full addresses) and name the proven action;
 * judges open the contract's explorer page to inspect its transactions. Update when LIVE_SYSTEM
 * gains full hashes.
 */
export interface EvidenceItem {
  id: string;
  integration: string;
  label: string;
  chainId: number;
  /** Contract address whose explorer page evidences the action. */
  address: string;
  /** docs/LIVE_SYSTEM.md section anchor for the full write-up. */
  liveSystemRef: string;
}

export const INTEGRATION_EVIDENCE: EvidenceItem[] = [
  {
    id: "reactive-epoch",
    integration: "Reactive",
    label: "EpochSettler RSC subscribed to EpochClosed (Lasna)",
    chainId: CHAIN_IDS.REACTIVE_LASNA,
    address: STRATUM_LIVE_MULTICHAIN.reactiveLasna.epochSettler,
    liveSystemRef: "§2",
  },
  {
    id: "reactive-coverage",
    integration: "Reactive",
    label: "CoverageMonitor RSC subscribed to CoverageStress (Lasna)",
    chainId: CHAIN_IDS.REACTIVE_LASNA,
    address: STRATUM_LIVE_MULTICHAIN.reactiveLasna.coverageMonitor,
    liveSystemRef: "§2",
  },
  {
    id: "across-cphr",
    integration: "Across",
    label: "CPHR bridgeReserve → Sepolia (full loop, depositId 6099)",
    chainId: CHAIN_IDS.UNICHAIN_SEPOLIA,
    address: STRATUM_ADDRESSES.cphr,
    liveSystemRef: "§5",
  },
  {
    id: "across-dest",
    integration: "Across",
    label: "Destination CPHR credited reserve on Ethereum Sepolia",
    chainId: CHAIN_IDS.ETHEREUM_SEPOLIA,
    address: STRATUM_LIVE_MULTICHAIN.sepolia.cphr,
    liveSystemRef: "§5",
  },
  {
    id: "stylus-engine",
    integration: "Stylus",
    label: "Stylus ML engine (activated WASM) on Arbitrum Sepolia",
    chainId: CHAIN_IDS.ARBITRUM_SEPOLIA,
    address: STRATUM_LIVE_MULTICHAIN.stylusEngineArbitrum,
    liveSystemRef: "§3",
  },
  {
    id: "eigen-attestation",
    integration: "EigenLayer",
    label: "MatchAttestation quorum (isAttested == true)",
    chainId: CHAIN_IDS.UNICHAIN_SEPOLIA,
    address: STRATUM_ADDRESSES.matchAttestation,
    liveSystemRef: "§4",
  },
  {
    id: "brevis-shim",
    integration: "Brevis",
    label: "Brevis verifier shim deployed (gateway partial)",
    chainId: CHAIN_IDS.UNICHAIN_SEPOLIA,
    address: STRATUM_ADDRESSES.brevisShim,
    liveSystemRef: "§7",
  },
  {
    id: "chainlink-feed",
    integration: "Chainlink",
    label: "ETH/USD Data Feed (senior benchmark) on Ethereum Sepolia",
    chainId: CHAIN_IDS.ETHEREUM_SEPOLIA,
    address: STRATUM_LIVE_MULTICHAIN.sepolia.chainlinkEthUsdFeed,
    liveSystemRef: "§6",
  },
];
