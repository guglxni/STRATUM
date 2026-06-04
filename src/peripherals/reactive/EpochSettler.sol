// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { IStratumHook } from "../../interfaces/IStratumHook.sol";
import { IPeripheral } from "../../interfaces/IPeripheral.sol";

/// @title EpochSettler
/// @notice Reactive Smart Contract that triggers epoch settlement on STRATUM (FR-15) with no off-chain keeper.
/// @dev Three drive paths, all converging on `stratumHook.closeEpoch`:
///      (1) `settleEpoch` - operator fallback for deterministic Foundry/demo runs;
///      (2) `reactiveCallback` - the Reactive Network system contract, subscribed to the hook's `EpochClosed`
///          / block-timestamp markers, calls in on epoch boundaries (the autonomous testnet path);
///      (3) `onEpochClose` (IPeripheral) - the hook itself can push in-band when `peripheralRegistry` points
///          here. The core ignores the return value, so this never affects core invariants (NFR-01).
contract EpochSettler is IPeripheral {
    IStratumHook public immutable stratumHook;
    address public immutable operator;

    /// @notice Reactive system contract permitted to drive `reactiveCallback`; address(0) on Foundry.
    address public reactiveCallbackSender;
    bool public enabled = true;

    error OnlyOperator();
    error OnlyReactiveOrOperator();

    event EpochSettleRequested(PoolId indexed poolId, uint64 epoch);
    event EpochClosePushed(PoolId indexed poolId, uint64 epoch);

    constructor(IStratumHook hook_, address operator_) {
        stratumHook = hook_;
        operator = operator_;
    }

    /// @notice Wire the Reactive system sender (operator-gated).
    function setReactiveCallbackSender(address sender_) external {
        if (msg.sender != operator) revert OnlyOperator();
        reactiveCallbackSender = sender_;
    }

    /// @notice Operator fallback: close the epoch directly (deterministic demo path).
    function settleEpoch(PoolId poolId) external {
        if (msg.sender != operator) revert OnlyOperator();
        _settle(poolId);
    }

    /// @notice Reactive path: the Reactive system contract drives the close at the epoch boundary.
    function reactiveCallback(PoolId poolId) external {
        if (msg.sender != reactiveCallbackSender && msg.sender != operator) revert OnlyReactiveOrOperator();
        _settle(poolId);
    }

    function _settle(PoolId poolId) internal {
        uint64 epoch = stratumHook.poolState(poolId).currentEpoch;
        stratumHook.closeEpoch(poolId);
        emit EpochSettleRequested(poolId, epoch);
    }

    // --- IPeripheral (in-band push from the hook when peripheralRegistry == this) ---

    /// @inheritdoc IPeripheral
    function kind() external pure returns (bytes32) {
        return keccak256("stratum.reactive.epoch");
    }

    /// @inheritdoc IPeripheral
    /// @dev Records the in-band close notification. Returns empty; the core discards the return value.
    function onEpochClose(PoolId id, uint64 epoch, bytes calldata) external returns (bytes memory) {
        // Notify-only: the hook has already finalized the epoch. We surface it for off-chain observers and,
        // in a fuller build, would fan out to ReserveBalancer / Brevis proof requests here.
        emit EpochClosePushed(id, epoch);
        return bytes("");
    }

    /// @inheritdoc IPeripheral
    function onCoverageStress(PoolId, uint16) external { }

    /// @inheritdoc IPeripheral
    function isEnabled() external view returns (bool) {
        return enabled;
    }
}
