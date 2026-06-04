// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title StratumTypes
/// @notice Shared enums and structs for STRATUM tranche accounting.
enum TrancheType {
    SENIOR,
    JUNIOR
}

struct TranchePosition {
    TrancheType tranche;
    address owner;
    uint160 entrySqrtPriceX96;
    int24 tickLower;
    int24 tickUpper;
    uint128 liquidity;
    uint256 cumulativeILAbsorbed;
    uint256 accruedFixedYield;
    uint256 excessFeesEarned;
    uint64 entryEpoch;
    uint64 lastSettledEpoch;
    uint256 vestedClaimable;
    uint256 principalValue;
    uint256 entryTimestamp;
    uint256 feePerShareCheckpointX128;
}

struct PoolTrancheState {
    uint256 seniorTVL;
    uint256 juniorTVL;
    uint256 juniorReserve;
    uint256 targetAPYBps;
    uint16 minCoverageRatioBps;
    uint16 maxSeniorILExposureBps;
    uint32 smoothingEpochSeconds;
    uint64 currentEpoch;
    uint256 epochAccumulatedFees;
    uint256 epochSeniorObligation;
    uint256 epochSeniorFunded;
    uint256 volatilityEWMA;
    uint16 baseFeeBps;
    uint16 minFeeBps;
    uint16 maxFeeBps;
    uint16 protocolFeeBps;
    uint256 poolCumulativeIL;
    address peripheralRegistry;
    address seniorToken;
    address juniorToken;
    bool initialized;
    uint256 epochStartTimestamp;
    uint256 seniorFeePerShareX128;
    uint256 juniorFeePerShareX128;
}

struct PoolInitParams {
    uint256 targetAPYBps;
    uint16 minCoverageRatioBps;
    uint16 maxSeniorILExposureBps;
    uint32 smoothingEpochSeconds;
    uint16 baseFeeBps;
    uint16 minFeeBps;
    uint16 maxFeeBps;
    uint16 protocolFeeBps;
    address peripheralRegistry;
}
