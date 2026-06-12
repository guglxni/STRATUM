/**
 * Minimal read ABI for StylusShim (Unichain Sepolia): the on-chain shim that pulls an optional ML
 * volatility override from the Arbitrum Stylus engine into the hook's dynamic-fee path.
 *
 * Note (spec §1.1): on the current demo deploy the shim is `enabled` but `stylusEngine == address(0)`,
 * so getVolatilityOverride returns 0 until `configure` wires the engine. The UI reflects this honestly.
 */
export const STYLUS_SHIM_ABI = [
  {
    name: "getVolatilityOverride",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "id", type: "bytes32" }],
    outputs: [{ name: "ewma", type: "uint256" }],
  },
  {
    name: "isEnabled",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "bool" }],
  },
  {
    name: "stylusEngine",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
  },
] as const;
