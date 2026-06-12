/**
 * STRATUM deployment addresses on Unichain Sepolia.
 *
 * After running `forge script script/DeployStratum.s.sol --broadcast`, copy the
 * addresses from the console output here. The frontend reads these at startup.
 *
 * If a contract has not yet been deployed, leave its value as an empty string;
 * the UI will display "not set" for that field.
 */

// `process.env` is statically replaced at build time by the `define` block in vite.config.ts;
// this declaration just gives TypeScript a type for it (no Node runtime is involved).
declare const process: { env: Record<string, string | undefined> };

// Live Unichain Sepolia (1301) full-stack deployment. D-1 redeploy 2026-06-11 (afterSwapReturnDelta
// enabled -> new mined hook address), against the canonical Uniswap v4 PoolManager and the real Across
// V3 SpokePool. Env vars override these defaults. Legacy (pre-D-1) addresses kept under *_LEGACY below.
export const STRATUM_ADDRESSES = {
  /** Canonical Uniswap v4 PoolManager the hook is attached to. */
  poolManager: process.env.NEXT_PUBLIC_POOL_MANAGER ?? "0x00B036B58a818B1BC34d502D3fE730Db729e62AC",

  /** StratumHook contract address (D-1 redeploy, mined CREATE2 salt 0x547c). */
  hook: process.env.NEXT_PUBLIC_HOOK_ADDRESS ?? "0xe932923a5008721564021513838509211CF267c5",

  /** EpochSettler RSC twin on Unichain Sepolia (callback target of the Lasna RSC). */
  epochSettler: process.env.NEXT_PUBLIC_EPOCH_SETTLER ?? "0x57E9Ba9714473F89418b47Ec0F235Ec6956aC2b8",

  /** CoverageMonitor RSC twin on Unichain Sepolia. */
  coverageMonitor: process.env.NEXT_PUBLIC_COVERAGE_MONITOR ?? "0x32bD92BdDB604b3BbFEE9B3042d38CF2B6e7e49f",

  /** ReserveBalancer RSC twin on Unichain Sepolia. */
  reserveBalancer: process.env.NEXT_PUBLIC_RESERVE_BALANCER ?? "0xdD7FdbC6Cc137D73b6F884BA4CeA5611958f9F79",

  /** CrossPoolHedgingRouter (CPHR / Across integration) address. */
  cphr: process.env.NEXT_PUBLIC_CPHR_ADDRESS ?? "0x9bcbE702215763e2D90BE8f3a374a41a32a0b791",

  /** BrevisVerifierShim address. */
  brevisShim: process.env.NEXT_PUBLIC_BREVIS_SHIM ?? "0x614ab1B307948CF8aB478a04FB9675F676e057F0",

  /** StylusShim address. */
  stylusShim: process.env.NEXT_PUBLIC_STYLUS_SHIM ?? "0xf3042e120f2C87827A7bE81512A6BFE425b0fC10",

  /**
   * MatchAttestation (EigenLayer AVS) address. This is the contract that actually holds the live
   * operator attestations (LIVE_SYSTEM.md §4: `0xB7D3…E2ba`). An earlier twin (`0x1306…5633`) was
   * deployed with the same quorum but never received attestations, so the AttestationChecker lab
   * pointed there returned "not attested" for every hash. Verified on-chain 2026-06-12: this address
   * has 4 AttestationSubmitted logs / 2 attested matchHashes at quorum.
   */
  matchAttestation: process.env.NEXT_PUBLIC_MATCH_ATTESTATION ?? "0xB7D3ca825C2E1D7340d0E849f18B002494A8E2ba",

  /** LVRAuctionReceiver address. */
  lvrReceiver: process.env.NEXT_PUBLIC_LVR_RECEIVER ?? "0x0bAAcccD5E433af479B2ce7aa0956f2583C601Ae",

  /** Demo pool currencies (faucet ERC-20s deployed by DemoLifecycle.s.sol on the D-1 redeploy). */
  demoToken0: process.env.NEXT_PUBLIC_DEMO_TOKEN0 ?? "0x769FCf62C917f33C1A8b48fd3c71173eDf45167D",
  demoToken1: process.env.NEXT_PUBLIC_DEMO_TOKEN1 ?? "0xb51872d10b16C2f5ce3f58007198546Fe0cDE08f",

  /** Default pool ID (bytes32 hex) shown when the app loads: the live, fully-seeded demo pool. */
  defaultPoolId: process.env.NEXT_PUBLIC_DEFAULT_POOL_ID ?? "0x45c7eceb6d8b65476779297e5470586e5594f55790d5aac72f26c6194175b8f9",

  // --- Uniswap enhancements round (docs/FRONTEND_UPGRADE_INSTRUCTIONS.md) -------------------
  // Lens/zap are committed in src/ but not yet broadcast; leave empty until deployed (honesty
  // contract: no placeholder addresses). The UI degrades gracefully when these are unset.

  /** StratumLens read aggregator (D-1 redeploy). One call returns full pool + position overviews. */
  lens: process.env.NEXT_PUBLIC_LENS_ADDRESS ?? "0xCfeB5FcD5a71336676F53d7E802422F39955F46A",

  /** StratumZap position router (deposit/withdraw UI). D-6 redeploy 2026-06-11. */
  zap: process.env.NEXT_PUBLIC_ZAP_ADDRESS ?? "0x26ffa695874Cc297F6360ab32604207E2e664918",

  /** Canonical Permit2 (same address on every chain via the deterministic deployer). */
  permit2: process.env.NEXT_PUBLIC_PERMIT2_ADDRESS ?? "0x000000000022D473030F116dDEE9F6B43aC78BA3",

  /** The Graph Studio HTTP endpoint for the STRATUM subgraph (D-7). Empty hides history panels. */
  subgraphUrl: process.env.NEXT_PUBLIC_SUBGRAPH_URL ?? "",

  /**
   * When true, UI assumes hook v2 with afterSwapReturnDelta fee surcharge semantics (D-1).
   * Default true on the 2026-06-11 redeploy: the live hook has the AFTER_SWAP_RETURNS_DELTA flag.
   * Protocol-fee realization is still opt-in PER POOL (creator calls setProtocolFeeRealization);
   * the demo pool ships with it OFF (accounting-only), so the surcharge UI stays hidden until enabled.
   */
  hookV2ProtocolFeeRealization: (process.env.NEXT_PUBLIC_HOOK_V2 ?? "true") === "true",

  /** Admin treasury allowed to collect realized protocol fees (D-1 collect UI gate). */
  protocolFeeCollector: process.env.NEXT_PUBLIC_PROTOCOL_FEE_COLLECTOR ?? "",

  /**
   * Legacy (pre-D-1) hook address. The D-1 permission-flag change re-mined the CREATE2 salt, so the
   * 2026-06-11 redeploy got a NEW address (see `hook` above); this one remains immutable on-chain and
   * historical subgraph data may still reference it.
   */
  hookLegacy: process.env.NEXT_PUBLIC_HOOK_LEGACY ?? "0x19446179F835E968353AE3d232397305F12167C1",

  /** Demo pool key parameters (InitStratumPool.s.sol: dynamic-fee flag + tickSpacing 60). */
  demoPoolFee: Number(process.env.NEXT_PUBLIC_DEMO_POOL_FEE ?? 0x800000),
  demoPoolTickSpacing: Number(process.env.NEXT_PUBLIC_DEMO_POOL_TICK_SPACING ?? 60),

  /**
   * Block the hook was deployed at (D-1 redeploy). Used to bound the on-chain `getLogs` history scan
   * so the Epochs/Swaps/Stress tabs work with no subgraph published. The scan is also capped to a
   * recent window so it stays within the RPC's 10k-block getLogs limit.
   */
  historyFromBlock: Number(process.env.NEXT_PUBLIC_HISTORY_FROM_BLOCK ?? 54294529),

  /**
   * A real attested matchHash for the EigenLayer AttestationChecker lab (§9.1), recovered from the
   * on-chain AttestationSubmitted logs of `matchAttestation` (block 53774240, 2-of-2 quorum). The lab
   * pre-fills this so the "Check" button returns ATTESTED in one click; it also lets a judge load any
   * attested hash live from the chain. Override with NEXT_PUBLIC_DEMO_MATCH_HASH if it ever rotates.
   */
  demoMatchHash:
    process.env.NEXT_PUBLIC_DEMO_MATCH_HASH ??
    "0xe5c3bf7a68c9f8c21ce29e96fb2d0da95a85c8276eb23a46881f174c00847568",
};

/**
 * Live multi-chain integration addresses (2026-06-05). Every entry is a real, on-chain deployment;
 * see docs/LIVE_SYSTEM.md for tx hashes and explorer evidence.
 */
export const STRATUM_LIVE_MULTICHAIN = {
  // Arbitrum Sepolia (421614): Rust Stylus matching + ML-volatility engine (activated WASM).
  stylusEngineArbitrum: "0xf612c8963ff9ae93cfe3b003f3d77f695b8d3e89",
  // Reactive Lasna (5318007): RSCs subscribed to the live Unichain hook (D-1 redeploy 2026-06-11).
  reactiveLasna: {
    epochSettler: "0xB67500437583656160B9C6Da2139E5D4289458E2",
    coverageMonitor: "0x54E0a257F389942FD73148E62D0d8061E4e387B3",
    reserveBalancer: "0x43084AdbC370a0764f736d8F29272094294A4c95",
    callbackProxyUnichain: "0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4",
  },
  // Ethereum Sepolia (11155111): Across destination stack + Chainlink + Brevis.
  sepolia: {
    hook: "0xaf618609340C81c45C201740aF349631bb8ce7c1",
    cphr: "0xB7FdcFfcad7BB4e239A18eB107BC447C42aA32FF",
    chainlinkEthUsdFeed: "0x694AA1769357215DE4FAC081bf1f309aDC325306",
    brevisRequestVerifier: "0xa082F86d9d1660C29cf3f962A31d7D20E367154F",
    acrossSpokePool: "0x5ef6C01E11889d86803e0B23e3cB3F9E9d97B662",
    wethReservePoolId: "0x96c4ccbfd8053a2fffa6b190b77f2ecf1b09e95cdae6c945bb9f6dd9d34ed719",
  },
  // Unichain Sepolia origin Across SpokePool the CPHR bridges through.
  acrossSpokePoolUnichain: "0x6999526e507Cc3b03b180BbE05E1Ff938259A874",
} as const;

/**
 * Chainlink Data Feeds on Ethereum Sepolia (chain 11155111). Every address below was verified
 * on-chain 2026-06-12 (description + decimals + a live latestRoundData answer). The senior target
 * rate (FR-25) reads the ETH/USD feed; the rest are surfaced in the Chainlink lab to demonstrate the
 * same AggregatorV3 read path across pairs. All feeds report 8 decimals. NOTE: these are benchmark
 * inputs to the senior coupon only - never the IL accounting (golden rule 2).
 */
export const CHAINLINK_SEPOLIA_FEEDS = [
  { pair: "ETH/USD", address: "0x694AA1769357215DE4FAC081bf1f309aDC325306", quote: "USD" },
  { pair: "BTC/USD", address: "0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43", quote: "USD" },
  { pair: "LINK/USD", address: "0xc59E3633BAAC79493d908e63626716e204A45EdF", quote: "USD" },
  { pair: "USDC/USD", address: "0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E", quote: "USD" },
  { pair: "DAI/USD", address: "0x14866185B1962B63C3Ea9E03Bc1da838bab34C19", quote: "USD" },
  { pair: "EUR/USD", address: "0x1a81afB8146aeFfCFc5E50e8479e826E7D55b910", quote: "USD" },
  { pair: "GBP/USD", address: "0x91FAB41F5f3bE955963a986366edAcff1aaeaa83", quote: "USD" },
  { pair: "JPY/USD", address: "0x8A6af2B75F23831ADc973ce6288e5329F63D86c6", quote: "USD" },
] as const;

/**
 * Primary chain config for wagmi. All fields are env-overridable so the same frontend binary can
 * point at mainnet Unichain (id 130), a local Anvil fork, or any future deployment without code changes.
 *
 * NEXT_PUBLIC_CHAIN_ID      — EVM chain id (default 1301 = Unichain Sepolia)
 * NEXT_PUBLIC_CHAIN_NAME    — Display name shown in "Wrong network" toasts (default "Unichain Sepolia")
 * NEXT_PUBLIC_RPC_URL       — HTTP RPC endpoint (default public Unichain Sepolia node)
 * NEXT_PUBLIC_EXPLORER_NAME — Explorer brand name, e.g. "Blockscout" (default)
 * NEXT_PUBLIC_EXPLORER_URL  — Explorer base URL, no trailing slash (default Blockscout Unichain Sepolia)
 *
 * The id cast keeps wagmi TypeScript inference happy regardless of what value the env var holds.
 */
export const UNICHAIN_SEPOLIA = {
  id: Number(process.env.NEXT_PUBLIC_CHAIN_ID ?? 1301) as 1301,
  name: process.env.NEXT_PUBLIC_CHAIN_NAME ?? "Unichain Sepolia",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: {
    default: {
      http: [process.env.NEXT_PUBLIC_RPC_URL ?? "https://sepolia.unichain.org"],
    },
  },
  blockExplorers: {
    default: {
      name: process.env.NEXT_PUBLIC_EXPLORER_NAME ?? "Blockscout",
      url: process.env.NEXT_PUBLIC_EXPLORER_URL ?? "https://unichain-sepolia.blockscout.com",
    },
  },
  testnet: true,
} as const;
