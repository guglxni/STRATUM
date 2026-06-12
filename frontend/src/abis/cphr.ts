/**
 * Minimal read ABI for CrossPoolHedgingRouter (CPHR, Unichain Sepolia). bridgeReserve/topUp are
 * attestation-gated W2 writes shown only as evidence (spec §6.3), never as judge buttons.
 */
export const CPHR_ABI = [
  {
    name: "isEnabled",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "bool" }],
  },
] as const;
