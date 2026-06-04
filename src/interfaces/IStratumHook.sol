// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { TrancheType, PoolTrancheState, TranchePosition } from "../StratumTypes.sol";

/// @title IStratumHook
/// @notice External API for STRATUM tranche positions (in addition to v4 liquidity callbacks).
interface IStratumHook {
    function poolState(PoolId id) external view returns (PoolTrancheState memory);

    function position(bytes32 positionId) external view returns (TranchePosition memory);

    function claimVested(bytes32 positionId) external returns (uint256 claimed);

    function closeEpoch(PoolId id) external;

    /// @notice Real token0/token1 held as the token-backed junior buffer for a pool (R-H1).
    function reserveBalances(PoolId id) external view returns (uint256 r0, uint256 r1);

    event TrancheDeposited(
        PoolId indexed poolId,
        bytes32 indexed positionId,
        address indexed owner,
        TrancheType tranche,
        uint128 liquidity,
        uint64 epoch
    );

    event TrancheSettled(
        PoolId indexed poolId,
        bytes32 indexed positionId,
        address indexed owner,
        TrancheType tranche,
        uint256 payout,
        uint256 ilCharged
    );

    event SwapAccounted(
        PoolId indexed poolId, uint64 indexed epoch, uint256 feeAmount, uint256 volatilityEWMA, uint16 coverageRatioBps
    );

    event EpochClosed(PoolId indexed poolId, uint64 indexed epoch, uint256 seniorFunded, uint256 juniorSurplus);

    event CoverageStress(PoolId indexed poolId, uint16 ratioBps, uint16 stressLevel);

    /// @notice Emitted when junior IL clawback funds the token-backed reserve (R-H1).
    event ReserveFunded(PoolId indexed poolId, uint256 amount0, uint256 amount1);

    /// @notice Emitted when a senior LP is made whole in real tokens from the reserve (R-H1).
    event SeniorMakeWhole(PoolId indexed poolId, uint256 paid0, uint256 paid1);

    /// @notice Emitted when the reserve could not fully cover a senior make-whole (honest partial delivery).
    event SeniorMakeWholeShortfall(PoolId indexed poolId, uint256 shortfallValue0);

    /// @notice Emitted at epoch close with the post-close junior reserve, for Reactive subscriptions (FR-17).
    event JuniorReserveUpdated(PoolId indexed poolId, uint64 indexed epoch, uint256 juniorReserve);

    /// @notice Emitted when a peripheral dispatch failed and was swallowed (NFR-01 observability).
    event PeripheralCallFailed(PoolId indexed poolId, address indexed peripheral, bytes4 selector);
}
