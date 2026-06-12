/**
 * Phase E (D-6): Permit2 SignatureTransfer typed-data construction.
 *
 * The zap's `depositWithPermit2` consumes a PermitBatchTransferFrom over exactly
 * [currency0, currency1] with the zap as spender. SignatureTransfer nonces are an unordered
 * bitmap: any never-used uint256 works, so we draw one from crypto randomness instead of
 * tracking sequence. Deadlines are reset on every attempt (30 minutes), and signatures are
 * never persisted (FRONTEND_UPGRADE_INSTRUCTIONS 8.4).
 */

import { STRATUM_ADDRESSES } from "../config/addresses";

export interface TokenPermission {
  token: `0x${string}`;
  amount: bigint;
}

export interface PermitBatchTransferFrom {
  permitted: TokenPermission[];
  nonce: bigint;
  deadline: bigint;
}

/** EIP-712 types for Permit2's PermitBatchTransferFrom (SignatureTransfer). */
export const PERMIT2_BATCH_TYPES = {
  PermitBatchTransferFrom: [
    { name: "permitted", type: "TokenPermissions[]" },
    { name: "spender", type: "address" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
  TokenPermissions: [
    { name: "token", type: "address" },
    { name: "amount", type: "uint256" },
  ],
} as const;

/** Permit2's EIP-712 domain (name only, no version, per the deployed contract). */
export function permit2Domain(chainId: number) {
  return {
    name: "Permit2",
    chainId,
    verifyingContract: STRATUM_ADDRESSES.permit2 as `0x${string}`,
  } as const;
}

/** Draw a random unordered nonce (256 bits) for SignatureTransfer. */
export function randomPermit2Nonce(): bigint {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  let n = 0n;
  for (const b of bytes) n = (n << 8n) | BigInt(b);
  return n;
}

/** Build the batch permit for the zap: [currency0, currency1] caps, fresh nonce, 30-min deadline. */
export function buildZapPermit(
  currency0: `0x${string}`,
  amount0Max: bigint,
  currency1: `0x${string}`,
  amount1Max: bigint
): PermitBatchTransferFrom {
  return {
    permitted: [
      { token: currency0, amount: amount0Max },
      { token: currency1, amount: amount1Max },
    ],
    nonce: randomPermit2Nonce(),
    deadline: BigInt(Math.floor(Date.now() / 1000) + 30 * 60),
  };
}

/** The EIP-712 message object for wagmi's signTypedData. */
export function permitToTypedMessage(permit: PermitBatchTransferFrom, spender: `0x${string}`) {
  return {
    permitted: permit.permitted.map((p) => ({ token: p.token, amount: p.amount })),
    spender,
    nonce: permit.nonce,
    deadline: permit.deadline,
  } as const;
}
