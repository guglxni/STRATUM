// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title IReserveRebalanceTarget
/// @notice Minimal surface the ReserveBalancer RSC calls on the Cross-Pool Hedging Router (CPHR, Phase 4).
/// @dev Keeps the dependency one-way: ReserveBalancer never imports the Across router concretely.
interface IReserveRebalanceTarget {
    /// @notice Signal that `id`'s junior reserve diverged from the cross-pool average.
    /// @param id Pool whose reserve diverged.
    /// @param divergence Signed divergence (positive = local surplus, negative = local deficit).
    function requestRebalance(PoolId id, int256 divergence) external;
}
