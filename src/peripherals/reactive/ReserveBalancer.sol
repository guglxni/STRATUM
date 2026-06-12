// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { IStratumHook } from "../../interfaces/IStratumHook.sol";
import { IReserveRebalanceTarget } from "./IReserveRebalanceTarget.sol";
import { PoolTrancheState } from "../../StratumTypes.sol";
import { AbstractReactive } from "./AbstractReactive.sol";
import { IReactive } from "./IReactive.sol";

/// @title ReserveBalancer
/// @notice Third STRATUM Reactive Smart Contract (FR-17). Observes per-pool junior reserve levels and, when a
///         pool diverges from the cross-pool average beyond a threshold, signals the CPHR to rebalance. Holds
///         no custody (signal-only, limits blast radius).
/// @dev The core hook never depends on this contract (NFR-01, golden rule 1). Canonical Reactive path:
///      subscribes to the hook's `JuniorReserveUpdated`/`EpochClosed` events; `react` schedules a
///      `reactiveCallback(poolId)` on the origin chain. On a live deployment each chain runs its own
///      ReserveBalancer and the Reactive contract aggregates sibling-chain reserves into the average.
contract ReserveBalancer is AbstractReactive {
    /// @dev Gas budget the Reactive Network forwards when executing the scheduled callback.
    uint64 internal constant CALLBACK_GAS_LIMIT = 350_000;

    IStratumHook public immutable stratumHook;
    address public immutable operator;
    uint256 public immutable originChainId;

    /// @notice topic_0 of `JuniorReserveUpdated(bytes32,uint64,uint256)` on the hook.
    /// @dev Pinned to a concrete event: the Reactive system contract rejects a catch-all topic_0
    ///      (REACTIVE_IGNORE) from a reactive contract. poolId is topic_1 on this event.
    uint256 internal constant TOPIC_JUNIOR_RESERVE_UPDATED =
        0x7f71b58a6742fa09795604087bac95364f6acaa17ce0fe9c92ab646095e94725;

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

    /// @notice P2 idempotency: monotonic per-pool hedge-request nonce, for off-chain CPHR reconciliation.
    mapping(PoolId => uint256) public rebalanceNonce;
    /// @notice P2 idempotency: `epoch + 1` of the last fired request per pool (0 = none yet). Caps the RSC to
    ///         at most one hedge request per (pool, epoch) so repeated same-epoch logs cannot double-hedge.
    mapping(PoolId => uint64) public requestEpochTag;

    error OnlyOperator();
    error OnlyReactiveOrOperator();

    event ReserveObserved(PoolId indexed poolId, uint256 juniorReserve, uint256 crossPoolAverage);
    event RebalanceRequested(PoolId indexed poolId, int256 divergence, uint16 divergenceBps);
    /// @notice (epoch, nonce) tag for a fired request so the CPHR can reconcile/dedup a retried hedge (P2).
    event RebalanceTagged(PoolId indexed poolId, uint64 epoch, uint256 nonce);
    /// @notice A divergence was observed but netted into the request already fired this epoch (P2, no double-hedge).
    event RebalanceNetted(PoolId indexed poolId, uint64 epoch, uint256 pendingNonce);
    event RebalanceTargetSet(address target);
    event PoolUntracked(PoolId indexed poolId);

    constructor(IStratumHook hook_, address operator_, uint16 divergenceThresholdBps_, uint256 originChainId_)
        AbstractReactive()
    {
        stratumHook = hook_;
        operator = operator_;
        divergenceThresholdBps = divergenceThresholdBps_;
        originChainId = originChainId_;
        // Subscribe to the hook's JuniorReserveUpdated event (poolId is topic_1). No-op on a plain EVM (NFR-01).
        _subscribe(originChainId_, address(hook_), TOPIC_JUNIOR_RESERVE_UPDATED);
    }

    /// @inheritdoc IReactive
    /// @dev Reactive Network entrypoint (Omni single-environment): schedule a reserve observation for the pool
    ///      that triggered the log.
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

    /// @notice Route scheduled callbacks to this RSC's twin on the destination chain (operator-gated).
    /// @dev Set `destCallback == address(0)` to revert to the same-chain (`address(this)`) fallback.
    function setReactiveDestination(uint256 destChainId, address destCallback) external {
        if (msg.sender != operator) revert OnlyOperator();
        destinationChainId = destChainId;
        destinationCallback = destCallback;
        emit ReactiveDestinationSet(destChainId, destCallback);
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

        // A drained/closed pool (zero reserve) self-evicts so its stale value cannot bias the cross-pool
        // average for sibling pools. The operator `untrack` remains a manual override for other cases.
        if (reserve == 0 && tracked[poolId]) {
            reserveSum -= lastObservedReserve[poolId];
            trackedCount -= 1;
            tracked[poolId] = false;
            lastObservedReserve[poolId] = 0;
            emit PoolUntracked(poolId);
            return;
        }

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
            // Idempotency (P2): at most one hedge request per (pool, epoch). Repeated JuniorReserveUpdated logs
            // within an epoch net into the first request instead of stacking duplicate hedges; a mid-way Across
            // failure is retried by the NEXT epoch's observation rather than double-sent. The (epoch, nonce)
            // tag lets the CPHR reconcile off-chain. Under Omni instant finality the origin log this reacts to
            // is itself final, so a reorg cannot un-emit a counted request.
            uint64 epoch = pool.currentEpoch;
            if (requestEpochTag[poolId] == epoch + 1) {
                emit RebalanceNetted(poolId, epoch, rebalanceNonce[poolId]);
            } else {
                requestEpochTag[poolId] = epoch + 1;
                uint256 nonce = ++rebalanceNonce[poolId];
                emit RebalanceRequested(poolId, signedDivergence, reportedBps);
                emit RebalanceTagged(poolId, epoch, nonce);
                // signal-only; the CPHR decides aggregation (FR-18) vs cross-chain bridge (FR-19).
                rebalanceTarget.requestRebalance(poolId, signedDivergence);
            }
        }
    }
}
