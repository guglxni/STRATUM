// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { IStratumHook } from "../../interfaces/IStratumHook.sol";
import { PoolTrancheState } from "../../StratumTypes.sol";
import { CoverageRatio } from "../../libraries/CoverageRatio.sol";

/// @title CoverageMonitor
/// @notice Reactive Smart Contract that reads pool coverage and broadcasts a stress signal (FR-16).
/// @dev Operator fallback (`reportCoverage`) for deterministic demo runs, plus a `reactiveCallback` driven by
///      the Reactive system contract (subscribed to the hook's `TrancheDeposited`/`TrancheSettled`/
///      `CoverageStress` events) for the autonomous testnet path. Read-only: it never mutates hook state.
contract CoverageMonitor {
    IStratumHook public immutable stratumHook;
    address public immutable operator;

    /// @notice Reactive system contract permitted to drive `reactiveCallback`; address(0) on Foundry.
    address public reactiveCallbackSender;

    error OnlyOperator();
    error OnlyReactiveOrOperator();

    event CoverageStressSignal(PoolId indexed poolId, uint16 ratioBps, uint16 stressLevel);

    constructor(IStratumHook hook_, address operator_) {
        stratumHook = hook_;
        operator = operator_;
    }

    /// @notice Wire the Reactive system sender (operator-gated).
    function setReactiveCallbackSender(address sender_) external {
        if (msg.sender != operator) revert OnlyOperator();
        reactiveCallbackSender = sender_;
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
