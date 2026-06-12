// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { IStratumHook } from "../../interfaces/IStratumHook.sol";
import { PoolTrancheState } from "../../StratumTypes.sol";
import { CoverageRatio } from "../../libraries/CoverageRatio.sol";
import { AbstractReactive } from "./AbstractReactive.sol";
import { IReactive } from "./IReactive.sol";

/// @title CoverageMonitor
/// @notice Reactive Smart Contract that reads pool coverage and broadcasts a stress signal (FR-16).
/// @dev Canonical Reactive path: subscribes to the hook's liquidity events; `react` schedules a
///      `reactiveCallback(poolId)` on the origin chain. Operator fallback (`reportCoverage`) for deterministic
///      demo runs. Read-only: it never mutates hook state.
contract CoverageMonitor is AbstractReactive {
    /// @dev Gas budget the Reactive Network forwards when executing the scheduled callback.
    uint64 internal constant CALLBACK_GAS_LIMIT = 300_000;

    IStratumHook public immutable stratumHook;
    address public immutable operator;
    uint256 public immutable originChainId;

    /// @notice topic_0 of `CoverageStress(bytes32,uint16,uint16)` on the hook.
    /// @dev Pinned to a concrete event: the Reactive system contract rejects a catch-all topic_0
    ///      (REACTIVE_IGNORE) from a reactive contract. poolId is topic_1 on this event.
    uint256 internal constant TOPIC_COVERAGE_STRESS =
        0xb5bddf1d3f05cf57e7ed2c18267a1e2ee4b5656d7ad99545fae6e4205b3750f3;

    /// @notice Reactive system contract permitted to drive `reactiveCallback`; address(0) on Foundry.
    address public reactiveCallbackSender;

    error OnlyOperator();
    error OnlyReactiveOrOperator();

    event CoverageStressSignal(PoolId indexed poolId, uint16 ratioBps, uint16 stressLevel);

    constructor(IStratumHook hook_, address operator_, uint256 originChainId_) AbstractReactive() {
        stratumHook = hook_;
        operator = operator_;
        originChainId = originChainId_;
        // Subscribe to the hook's CoverageStress event (poolId is topic_1). No-op on a plain EVM (NFR-01).
        _subscribe(originChainId_, address(hook_), TOPIC_COVERAGE_STRESS);
    }

    /// @inheritdoc IReactive
    /// @dev Reactive Network entrypoint: schedule a coverage report for the pool that triggered the log.
    function react(LogRecord calldata log) external override {
        // In reactive mode only the genuine system contract may drive react(). On a plain EVM (no system
        // contract) gate to the operator so a stranger cannot emit forged Callback events to off-chain indexers.
        if (reactiveMode) {
            if (msg.sender != address(systemContract)) revert OnlyReactiveOrOperator();
        } else if (msg.sender != operator) {
            revert OnlyReactiveOrOperator();
        }
        PoolId poolId = PoolId.wrap(bytes32(log.topic_1));
        (uint256 destChainId, address destContract) = _callbackRoute(originChainId);
        _emitCallback(
            destChainId,
            destContract,
            CALLBACK_GAS_LIMIT,
            abi.encodeWithSelector(this.reactiveCallback.selector, poolId)
        );
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

    /// @notice Operator fallback: read coverage and emit the stress signal (deterministic demo path).
    function reportCoverage(PoolId poolId) external returns (uint16 ratioBps, uint16 stressLevel) {
        if (msg.sender != operator) revert OnlyOperator();
        return _report(poolId);
    }

    /// @notice Reactive path: the Reactive system contract drives the report on a liquidity/coverage event.
    function reactiveCallback(PoolId poolId) external returns (uint16 ratioBps, uint16 stressLevel) {
        if (msg.sender != reactiveCallbackSender && msg.sender != operator) revert OnlyReactiveOrOperator();
        return _report(poolId);
    }

    function _report(PoolId poolId) internal returns (uint16 ratioBps, uint16 stressLevel) {
        PoolTrancheState memory pool = stratumHook.poolState(poolId);
        ratioBps = CoverageRatio.ratioBps(pool.juniorTVL, pool.seniorTVL);
        stressLevel = CoverageRatio.stressLevel(ratioBps, pool.minCoverageRatioBps);
        emit CoverageStressSignal(poolId, ratioBps, stressLevel);
    }
}
