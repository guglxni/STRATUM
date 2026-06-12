/**
 * Minimal ABI for the Arbitrum Stylus matching/volatility engine (Rust → WASM, chain 421614).
 *
 * The Solidity IStylusMatchingEngine interface covers the operator-driven match path; the deployed
 * Stylus contract additionally exposes a read-only ML forecast that the StratumShim consumes. Per
 * docs/LIVE_SYSTEM.md §3: forecastVolatility(1e18, 1.1e18) → 1.01e18 (next-step EWMA forecast).
 */
export const STYLUS_ENGINE_ABI = [
  {
    name: "forecastVolatility",
    type: "function",
    stateMutability: "view",
    inputs: [
      { name: "currentEwma", type: "uint256" },
      { name: "lastTradeSize", type: "uint256" },
    ],
    outputs: [{ name: "forecast", type: "uint256" }],
  },
] as const;
