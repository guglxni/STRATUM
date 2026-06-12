/**
 * Minimal Permit2 SignatureTransfer ABI surface.
 * The zap pins canonical Permit2 as a constant; the frontend only needs the
 * unordered-nonce bitmap read (to sanity-check a nonce before signing).
 * EIP-712 type definitions live in lib/permit2.ts.
 */

export const PERMIT2_ABI = [
  {
    name: "nonceBitmap",
    type: "function",
    stateMutability: "view",
    inputs: [
      { name: "owner", type: "address" },
      { name: "wordPos", type: "uint256" },
    ],
    outputs: [{ name: "", type: "uint256" }],
  },
] as const;
