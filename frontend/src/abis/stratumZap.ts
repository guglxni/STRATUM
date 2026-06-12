/**
 * Minimal ABI for StratumZap (src/peripherals/zap/StratumZap.sol).
 * Hand-trimmed from `forge inspect StratumZap abi`; signatures mirror the committed Solidity
 * exactly, including the D-6 `depositWithPermit2` Permit2 batch path.
 */

import { POOL_KEY_COMPONENTS } from "./stratumLens";

const PERMIT_BATCH_COMPONENTS = [
  {
    name: "permitted",
    type: "tuple[]",
    components: [
      { name: "token", type: "address" },
      { name: "amount", type: "uint256" },
    ],
  },
  { name: "nonce", type: "uint256" },
  { name: "deadline", type: "uint256" },
] as const;

export const STRATUM_ZAP_ABI = [
  {
    name: "deposit",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "key", type: "tuple", components: POOL_KEY_COMPONENTS },
      { name: "tickLower", type: "int24" },
      { name: "tickUpper", type: "int24" },
      { name: "liquidity", type: "uint128" },
      { name: "tranche", type: "uint8" },
      { name: "userSalt", type: "bytes32" },
      { name: "amount0Max", type: "uint256" },
      { name: "amount1Max", type: "uint256" },
      { name: "useDeliveredBalance", type: "bool" },
    ],
    outputs: [{ name: "positionId", type: "bytes32" }],
  },
  {
    name: "depositWithPermit2",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "key", type: "tuple", components: POOL_KEY_COMPONENTS },
      { name: "tickLower", type: "int24" },
      { name: "tickUpper", type: "int24" },
      { name: "liquidity", type: "uint128" },
      { name: "tranche", type: "uint8" },
      { name: "userSalt", type: "bytes32" },
      { name: "permit", type: "tuple", components: PERMIT_BATCH_COMPONENTS },
      { name: "signature", type: "bytes" },
    ],
    outputs: [{ name: "positionId", type: "bytes32" }],
  },
  {
    name: "withdraw",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "key", type: "tuple", components: POOL_KEY_COMPONENTS },
      { name: "tickLower", type: "int24" },
      { name: "tickUpper", type: "int24" },
      { name: "userSalt", type: "bytes32" },
    ],
    outputs: [],
  },
  {
    name: "claimVested",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [{ name: "positionId", type: "bytes32" }],
    outputs: [{ name: "claimed", type: "uint256" }],
  },
  {
    name: "zapPositionOwner",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "", type: "bytes32" }],
    outputs: [{ name: "", type: "address" }],
  },
  {
    name: "ZapDeposited",
    type: "event",
    inputs: [
      { name: "poolId", type: "bytes32", indexed: true },
      { name: "positionId", type: "bytes32", indexed: true },
      { name: "user", type: "address", indexed: true },
      { name: "tranche", type: "uint8", indexed: false },
      { name: "liquidity", type: "uint128", indexed: false },
    ],
  },
  {
    name: "ZapWithdrawn",
    type: "event",
    inputs: [
      { name: "poolId", type: "bytes32", indexed: true },
      { name: "positionId", type: "bytes32", indexed: true },
      { name: "user", type: "address", indexed: true },
    ],
  },
] as const;
