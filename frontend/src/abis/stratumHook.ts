/**
 * Minimal ABI for StratumHook view functions used by the demo frontend.
 * Only the functions the UI reads are included; the full ABI is generated
 * by `forge inspect StratumHook abi` for production use.
 */

export const STRATUM_HOOK_ABI = [
  {
    name: "poolState",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "id", type: "bytes32" }],
    outputs: [
      {
        name: "",
        type: "tuple",
        components: [
          { name: "seniorTVL", type: "uint256" },
          { name: "juniorTVL", type: "uint256" },
          { name: "juniorReserve", type: "uint256" },
          { name: "targetAPYBps", type: "uint256" },
          { name: "minCoverageRatioBps", type: "uint16" },
          { name: "maxSeniorILExposureBps", type: "uint16" },
          { name: "smoothingEpochSeconds", type: "uint32" },
          { name: "currentEpoch", type: "uint64" },
          { name: "epochAccumulatedFees", type: "uint256" },
          { name: "epochSeniorObligation", type: "uint256" },
          { name: "epochSeniorFunded", type: "uint256" },
          { name: "volatilityEWMA", type: "uint256" },
          { name: "baseFeeBps", type: "uint16" },
          { name: "minFeeBps", type: "uint16" },
          { name: "maxFeeBps", type: "uint16" },
          { name: "protocolFeeBps", type: "uint16" },
          { name: "poolCumulativeIL", type: "uint256" },
          { name: "peripheralRegistry", type: "address" },
          { name: "seniorToken", type: "address" },
          { name: "juniorToken", type: "address" },
          { name: "initialized", type: "bool" },
          { name: "epochStartTimestamp", type: "uint256" },
          { name: "seniorFeePerShareX128", type: "uint256" },
          { name: "juniorFeePerShareX128", type: "uint256" },
        ],
      },
    ],
  },
  {
    name: "reserveBalances",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "id", type: "bytes32" }],
    outputs: [
      { name: "r0", type: "uint256" },
      { name: "r1", type: "uint256" },
    ],
  },
  {
    name: "position",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "positionId", type: "bytes32" }],
    outputs: [
      {
        name: "",
        type: "tuple",
        components: [
          { name: "tranche", type: "uint8" },
          { name: "owner", type: "address" },
          { name: "entrySqrtPriceX96", type: "uint160" },
          { name: "tickLower", type: "int24" },
          { name: "tickUpper", type: "int24" },
          { name: "liquidity", type: "uint128" },
          { name: "cumulativeILAbsorbed", type: "uint256" },
          { name: "accruedFixedYield", type: "uint256" },
          { name: "excessFeesEarned", type: "uint256" },
          { name: "entryEpoch", type: "uint64" },
          { name: "lastSettledEpoch", type: "uint64" },
          { name: "vestedClaimable", type: "uint256" },
          { name: "principalValue", type: "uint256" },
          { name: "entryTimestamp", type: "uint256" },
          { name: "feePerShareCheckpointX128", type: "uint256" },
        ],
      },
    ],
  },
  {
    name: "claimVested",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [{ name: "positionId", type: "bytes32" }],
    outputs: [{ name: "claimed", type: "uint256" }],
  },
] as const;
