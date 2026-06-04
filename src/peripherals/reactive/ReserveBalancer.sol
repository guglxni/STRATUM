// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { IStratumHook } from "../../interfaces/IStratumHook.sol";
import { IReserveRebalanceTarget } from "./IReserveRebalanceTarget.sol";
import { PoolTrancheState } from "../../StratumTypes.sol";

/// @title ReserveBalancer
/// @notice Third STRATUM Reactive Smart Contract (FR-17). Observes per-pool junior reserve levels and, when a
///         pool diverges from the cross-pool average beyond a threshold, signals the CPHR to rebalance. Holds
///         no custody (signal-only, limits blast radius).
/// @dev The core hook never depends on this contract (NFR-01, golden rule 1). It is operator-gated for the
///      demo; the production model subscribes to the hook's `JuniorReserveUpdated`/`EpochClosed` events on
///      Reactive Network (`reactiveCallback`). On a live deployment each chain runs its own ReserveBalancer
///      and the Reactive contract aggregates sibling-chain reserves into the average.
contract ReserveBalancer {
    IStratumHook public immutable stratumHook;
    address public immutable operator;

    /// @notice Reactive system contract permitted to drive `reactiveCallback`; address(0) on Foundry.
    address public reactiveCallbackSender;
    /// @notice CPHR (Across router, Phase 4). address(0) = inert: divergence is observed but nothing is fired.
    IReserveRebalanceTarget public rebalanceTarget;
    /// @notice Divergence (bps of the average) above which a rebalance is requested.
    uint16 public divergenceThresholdBps;

    // Running cross-pool average state, so an observation never iterates a pool array.
    mapping(PoolId => uint256) public lastObservedReserve;
    mapping(PoolId => bool) public tracked;
    uint256 public reserveSum;
    uint256 public trackedCount;

    error OnlyOperator();
    error OnlyReactiveOrOperator();

    event ReserveObserved(PoolId indexed poolId, uint256 juniorReserve, uint256 crossPoolAverage);
    event RebalanceRequested(PoolId indexed poolId, int256 divergence, uint16 divergenceBps);
    event RebalanceTargetSet(address target);
    event PoolUntracked(PoolId indexed poolId);

    constructor(IStratumHook hook_, address operator_, uint16 divergenceThresholdBps_) {
        stratumHook = hook_;
        operator = operator_;
        divergenceThresholdBps = divergenceThresholdBps_;
    }

    /// @notice One-time wiring of the CPHR target and the Reactive system sender (operator-gated).
    function configure(IReserveRebalanceTarget target_, address reactiveCallbackSender_) external {
        if (msg.sender != operator) revert OnlyOperator();
        rebalanceTarget = target_;
        reactiveCallbackSender = reactiveCallbackSender_;
        emit RebalanceTargetSet(address(target_));
    }

    /// @notice Production path: Reactive callback decoding a JuniorReserveUpdated / EpochClosed event.
    function reactiveCallback(PoolId poolId) external {
        if (msg.sender != reactiveCallbackSender && msg.sender != operator) revert OnlyReactiveOrOperator();
        _observe(poolId);
    }

    /// @notice Testnet/demo fallback: operator feeds an observation deterministically (no live subscription).
    function observeReserve(PoolId poolId) external {
        if (msg.sender != operator) revert OnlyOperator();
        _observe(poolId);
    }

    /// @notice Stop tracking a pool so a drained/closed pool no longer drags the cross-pool average.
    function untrack(PoolId poolId) external {
        if (msg.sender != operator) revert OnlyOperator();
        if (!tracked[poolId]) return;
        reserveSum -= lastObservedReserve[poolId];
        trackedCount -= 1;
        tracked[poolId] = false;
        lastObservedReserve[poolId] = 0;
        emit PoolUntracked(poolId);
    }

    /// @dev Reads the pool's junior reserve from the hook, updates the running average, and requests a
    ///      rebalance if divergence exceeds the threshold and a target is configured.
    function _observe(PoolId poolId) internal {
        PoolTrancheState memory pool = stratumHook.poolState(poolId);
        uint256 reserve = pool.juniorReserve;

        if (tracked[poolId]) {
            reserveSum = reserveSum - lastObservedReserve[poolId] + reserve;
        } else {
            tracked[poolId] = true;
            trackedCount += 1;
            reserveSum += reserve;
        }
        lastObservedReserve[poolId] = reserve;

        uint256 avg = trackedCount == 0 ? 0 : reserveSum / trackedCount;
        emit ReserveObserved(poolId, reserve, avg);
        if (avg == 0) return; // nothing to diverge from yet

        uint256 diffAbs = reserve > avg ? reserve - avg : avg - reserve;
        uint256 divBps = diffAbs * 10_000 / avg;
        if (divBps > divergenceThresholdBps && address(rebalanceTarget) != address(0)) {
            int256 signedDivergence = reserve >= avg ? int256(diffAbs) : -int256(diffAbs);
            uint16 reportedBps = divBps > type(uint16).max ? type(uint16).max : uint16(divBps);
            emit RebalanceRequested(poolId, signedDivergence, reportedBps);
            // signal-only; the CPHR decides aggregation (FR-18) vs cross-chain bridge (FR-19).
            rebalanceTarget.requestRebalance(poolId, signedDivergence);
        }
    }
}
