// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { TrancheIntentRegistry } from "./TrancheIntentRegistry.sol";
import { AbstractReactive } from "./AbstractReactive.sol";
import { IReactive } from "./IReactive.sol";

/// @title IntentSettlerRSC
/// @notice Reactive Smart Contract that fires LP conditional-intent execution with no off-chain keeper (FR-30).
///         It subscribes to the three hook events that can change an intent's condition - coverage stress,
///         epoch close, and junior-reserve update - and, on each, schedules a callback that sweeps the affected
///         pool's armed intents through the `TrancheIntentRegistry`.
/// @dev Mirrors the other STRATUM RSCs (EpochSettler, CoverageMonitor): `react` schedules `reactiveCallback`,
///      which calls `registry.sweep(poolId, MAX_INTENTS_PER_CALLBACK)`. Non-custodial and non-blocking: the
///      registry re-validates every condition and the hook re-checks coverage/conservation/authorization, so a
///      spurious trigger only wastes gas. All three subscribed events carry `poolId` as topic_1.
contract IntentSettlerRSC is AbstractReactive {
    /// @dev Gas budget the Reactive Network forwards when executing the scheduled callback. Higher than the
    ///      single-action RSCs because a sweep may execute several migrations in one callback.
    uint64 internal constant CALLBACK_GAS_LIMIT = 1_200_000;

    /// @dev Per-callback cap so a pool with many intents cannot exceed the Reactive gas budget. Intents beyond
    ///      the cap are picked up by the next triggering event's sweep. A constant safety bound, not a per-pool
    ///      parameter, so it lives here.
    uint256 public constant MAX_INTENTS_PER_CALLBACK = 5;

    TrancheIntentRegistry public immutable registry;
    address public immutable operator;
    uint256 public immutable originChainId;

    /// @notice topic_0 of `CoverageStress(bytes32,uint16,uint16)` on the hook (poolId is topic_1).
    uint256 internal constant TOPIC_COVERAGE_STRESS =
        0xb5bddf1d3f05cf57e7ed2c18267a1e2ee4b5656d7ad99545fae6e4205b3750f3;
    /// @notice topic_0 of `EpochClosed(bytes32,uint64,uint256,uint256)` on the hook (poolId is topic_1).
    uint256 internal constant TOPIC_EPOCH_CLOSED = 0x79e8f1a36b0a8a77d86cb19fc7f513840a167b8ff98eeed6ebd8fe9a03b474b2;
    /// @notice topic_0 of `JuniorReserveUpdated(bytes32,uint64,uint256)` on the hook (poolId is topic_1).
    uint256 internal constant TOPIC_JUNIOR_RESERVE_UPDATED =
        0x7f71b58a6742fa09795604087bac95364f6acaa17ce0fe9c92ab646095e94725;

    /// @notice Reactive system contract permitted to drive `reactiveCallback`; address(0) on Foundry.
    address public reactiveCallbackSender;

    error OnlyOperator();
    error OnlyReactiveOrOperator();

    event IntentSweepRequested(PoolId indexed poolId);
    event IntentSweepExecuted(PoolId indexed poolId, uint256 executed);

    constructor(TrancheIntentRegistry registry_, address hook_, address operator_, uint256 originChainId_)
        AbstractReactive()
    {
        registry = registry_;
        operator = operator_;
        originChainId = originChainId_;
        // Subscribe to every hook event that can flip an intent's condition. topic_0 must be concrete (the
        // Reactive system contract rejects a catch-all from a reactive contract). No-op on a plain EVM (NFR-01).
        _subscribe(originChainId_, hook_, TOPIC_COVERAGE_STRESS);
        _subscribe(originChainId_, hook_, TOPIC_EPOCH_CLOSED);
        _subscribe(originChainId_, hook_, TOPIC_JUNIOR_RESERVE_UPDATED);
    }

    /// @inheritdoc IReactive
    /// @dev Reactive entrypoint: schedule an intent sweep for the pool that triggered the log.
    function react(LogRecord calldata log) external override {
        if (reactiveMode) {
            if (msg.sender != address(systemContract)) revert OnlyReactiveOrOperator();
        } else if (msg.sender != operator) {
            revert OnlyReactiveOrOperator();
        }
        PoolId poolId = PoolId.wrap(bytes32(log.topic_1));
        emit IntentSweepRequested(poolId);
        (uint256 destChainId, address destContract) = _callbackRoute(originChainId);
        _emitCallback(
            destChainId,
            destContract,
            CALLBACK_GAS_LIMIT,
            abi.encodeWithSelector(this.reactiveCallback.selector, poolId)
        );
    }

    /// @notice Reactive path: the Reactive system contract drives the sweep on a subscribed event.
    function reactiveCallback(PoolId poolId) external {
        if (msg.sender != reactiveCallbackSender && msg.sender != operator) revert OnlyReactiveOrOperator();
        _sweep(poolId);
    }

    /// @notice Testnet/demo fallback: operator drives a sweep deterministically (no live subscription).
    function sweepIntents(PoolId poolId) external {
        if (msg.sender != operator) revert OnlyOperator();
        _sweep(poolId);
    }

    /// @notice Wire the Reactive system sender (operator-gated).
    function setReactiveCallbackSender(address sender_) external {
        if (msg.sender != operator) revert OnlyOperator();
        reactiveCallbackSender = sender_;
    }

    /// @notice Route scheduled callbacks to this RSC's twin on the destination chain (operator-gated).
    /// @dev Set `destCallback == address(0)` to revert to the same-chain (`address(this)`) fallback.
    function setReactiveDestination(uint256 destChainId, address destCallback) external {
        if (msg.sender != operator) revert OnlyOperator();
        destinationChainId = destChainId;
        destinationCallback = destCallback;
        emit ReactiveDestinationSet(destChainId, destCallback);
    }

    function _sweep(PoolId poolId) internal {
        uint256 executed = registry.sweep(poolId, MAX_INTENTS_PER_CALLBACK);
        emit IntentSweepExecuted(poolId, executed);
    }
}
