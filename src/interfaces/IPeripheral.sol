// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title IPeripheral
/// @notice Common interface for optional STRATUM modules (Brevis, Across, Reactive, etc.).
interface IPeripheral {
    /// @notice Identifier for the peripheral module.
    function kind() external view returns (bytes32);

    /// @notice Called when an epoch closes.
    function onEpochClose(PoolId id, uint64 epoch, bytes calldata ctx) external returns (bytes memory);

    /// @notice Called when coverage stress is detected.
    function onCoverageStress(PoolId id, uint16 ratioBps) external;

    /// @notice Whether this peripheral is active for the pool.
    function isEnabled() external view returns (bool);
}
