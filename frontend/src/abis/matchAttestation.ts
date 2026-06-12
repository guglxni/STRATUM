/**
 * Minimal read ABI for MatchAttestation (EigenLayer-style ECDSA quorum, Unichain Sepolia).
 * Read-only: judges verify an attested matchHash; the write path submit(matchHash, sig) is
 * operator-only and intentionally never surfaced as a judge button (spec §9.3 / §15.2).
 */
export const MATCH_ATTESTATION_ABI = [
  {
    name: "isAttested",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "matchHash", type: "bytes32" }],
    outputs: [{ name: "attested", type: "bool" }],
  },
  {
    name: "attestationCount",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "matchHash", type: "bytes32" }],
    outputs: [{ name: "count", type: "uint256" }],
  },
  {
    name: "attestationDigest",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "matchHash", type: "bytes32" }],
    outputs: [{ name: "", type: "bytes32" }],
  },
  {
    name: "quorumThreshold",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    name: "operatorCount",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    name: "operatorSetVersion",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
] as const;
