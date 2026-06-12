/**
 * Minimal ABI for StratumLens (src/peripherals/lens/StratumLens.sol).
 * Hand-trimmed from `forge inspect StratumLens abi` to the read surface the UI uses;
 * field names and ordering mirror the Solidity structs exactly.
 */

export const POOL_KEY_COMPONENTS = [
  { name: "currency0", type: "address" },
  { name: "currency1", type: "address" },
  { name: "fee", type: "uint24" },
  { name: "tickSpacing", type: "int24" },
  { name: "hooks", type: "address" },
] as const;

export const STRATUM_LENS_ABI = [
  {
    name: "poolOverview",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "key", type: "tuple", components: POOL_KEY_COMPONENTS }],
    outputs: [
      {
        name: "o",
        type: "tuple",
        components: [
          { name: "sqrtPriceX96", type: "uint160" },
          { name: "tick", type: "int24" },
          { name: "seniorTVL", type: "uint256" },
          { name: "juniorTVL", type: "uint256" },
          { name: "juniorReserve", type: "uint256" },
          { name: "coverageRatioBps", type: "uint16" },
          { name: "stressLevelBps", type: "uint16" },
          { name: "nextSwapFeeBps", type: "uint16" },
          { name: "currentEpoch", type: "uint64" },
          { name: "epochAccumulatedFees", type: "uint256" },
          { name: "epochSeniorObligation", type: "uint256" },
          { name: "epochSeniorFunded", type: "uint256" },
          { name: "reserve0", type: "uint256" },
          { name: "reserve1", type: "uint256" },
          { name: "protocolFeesAccrued", type: "uint256" },
          { name: "protocolFeeRealization", type: "bool" },
          { name: "protocolFeeReserve0", type: "uint256" },
          { name: "protocolFeeReserve1", type: "uint256" },
          { name: "seniorToken", type: "address" },
          { name: "juniorToken", type: "address" },
          { name: "initialized", type: "bool" },
        ],
      },
    ],
  },
  {
    name: "positionOverview",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "positionId", type: "bytes32" }],
    outputs: [
      {
        name: "o",
        type: "tuple",
        components: [
          {
            name: "position",
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
          { name: "poolId", type: "bytes32" },
          { name: "ilAtCurrentPrice", type: "uint256" },
          { name: "ilAtAnchor", type: "uint256" },
          { name: "accruedCoupon", type: "uint256" },
        ],
      },
    ],
  },
  {
    name: "positionIdFor",
    type: "function",
    stateMutability: "pure",
    inputs: [
      { name: "sender", type: "address" },
      { name: "tickLower", type: "int24" },
      { name: "tickUpper", type: "int24" },
      { name: "salt", type: "bytes32" },
    ],
    outputs: [{ name: "", type: "bytes32" }],
  },
] as const;

/** TypeScript mirror of StratumLens.PoolOverview for typed consumption. */
export interface PoolOverviewData {
  sqrtPriceX96: bigint;
  tick: number;
  seniorTVL: bigint;
  juniorTVL: bigint;
  juniorReserve: bigint;
  coverageRatioBps: number;
  stressLevelBps: number;
  nextSwapFeeBps: number;
  currentEpoch: bigint;
  epochAccumulatedFees: bigint;
  epochSeniorObligation: bigint;
  epochSeniorFunded: bigint;
  reserve0: bigint;
  reserve1: bigint;
  protocolFeesAccrued: bigint;
  protocolFeeRealization: boolean;
  protocolFeeReserve0: bigint;
  protocolFeeReserve1: bigint;
  seniorToken: string;
  juniorToken: string;
  initialized: boolean;
}

/** TypeScript mirror of StratumLens.PositionOverview (positionOverview return tuple). */
export interface PositionData {
  tranche: number;
  owner: string;
  entrySqrtPriceX96: bigint;
  tickLower: number;
  tickUpper: number;
  liquidity: bigint;
  cumulativeILAbsorbed: bigint;
  accruedFixedYield: bigint;
  excessFeesEarned: bigint;
  entryEpoch: bigint;
  lastSettledEpoch: bigint;
  vestedClaimable: bigint;
  principalValue: bigint;
  entryTimestamp: bigint;
  feePerShareCheckpointX128: bigint;
}

export interface PositionOverviewData {
  position: PositionData;
  poolId: string;
  ilAtCurrentPrice: bigint;
  ilAtAnchor: bigint;
  accruedCoupon: bigint;
}
