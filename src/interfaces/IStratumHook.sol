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

    /// @notice Pool a position belongs to (PoolId(0) if the position does not exist).
    function positionPool(bytes32 positionId) external view returns (PoolId);

    function claimVested(bytes32 positionId) external returns (uint256 claimed);

    function closeEpoch(PoolId id) external;

    /// @notice Refresh a pool's senior target APY from its configured benchmark feed (FR-25). Permissionless.
    function refreshSeniorRate(PoolId id) external;

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

    /// @notice Emitted in beforeRemoveLiquidity when Brevis is enabled, signalling the off-chain
    ///         Brevis prover to prepare a ZK proof for this position (FR-21).
    /// @param positionId  Position being withdrawn.
    /// @param fromEpoch   Position entry epoch.
    /// @param toEpoch     Current epoch at withdrawal time.
    event BrevisProofRequested(bytes32 indexed positionId, uint64 fromEpoch, uint64 toEpoch);

    /// @notice Emitted when reserve is moved from a donor pool to a recipient pool (FR-18 aggregation).
    event ReserveRebalanced(PoolId indexed fromPool, PoolId indexed toPool, uint256 amount0, uint256 amount1);

    /// @notice Emitted when an LP authorizes/revokes an address to migrate a position's tranche (FR-30).
    /// @param positionId Position whose migration rights changed.
    /// @param owner Position owner granting the right.
    /// @param migrator Newly approved migrator, or address(0) on revocation.
    event MigratorApproved(bytes32 indexed positionId, address indexed owner, address indexed migrator);

    /// @notice Emitted when a position is reclassified between tranches in place (FR-31).
    /// @param poolId Pool the position belongs to.
    /// @param positionId Position migrated.
    /// @param owner Position owner.
    /// @param fromTranche Tranche before migration.
    /// @param toTranche Tranche after migration.
    /// @param carriedPrincipal Principal re-registered in the destination tranche after IL realization.
    /// @param realizedIL IL realized under the source tranche during migration.
    event PositionMigrated(
        PoolId indexed poolId,
        bytes32 indexed positionId,
        address indexed owner,
        TrancheType fromTranche,
        TrancheType toTranche,
        uint256 carriedPrincipal,
        uint256 realizedIL
    );

    /// @notice Authorize or revoke an address to migrate a position's tranche on the owner's behalf (FR-30).
    function approveMigrator(bytes32 positionId, address migrator) external;

    /// @notice Reclassify a position between the senior and junior tranches in place (FR-31).
    function migrateTranchePosition(bytes32 positionId, TrancheType newTranche)
        external
        returns (uint256 carriedPrincipal);
}
