// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { IStratumHook } from "../../interfaces/IStratumHook.sol";
import { IPeripheral } from "../../interfaces/IPeripheral.sol";
import { AbstractReactive } from "./AbstractReactive.sol";
import { IReactive } from "./IReactive.sol";

/// @title EpochSettler
/// @notice Reactive Smart Contract that triggers epoch settlement on STRATUM (FR-15) with no off-chain keeper.
/// @dev Four drive paths, all converging on `stratumHook.closeEpoch`:
///      (1) `react` (IReactive) - the canonical Reactive path: the Reactive Network system contract delivers
///          a subscribed hook log to this RSC (running on the Reactive Network chain), and `react` emits a
///          `Callback` scheduling `reactiveCallback(poolId)` on the origin chain. Since the Omni fork
///          (2026-05-25) this is ONE contract in ONE environment - no ReactVM split. The hook's
///          `EpochNotElapsed` guard is now belt-and-suspenders (CometBFT instant finality eliminates reorg-
///          driven duplicate callbacks), but it remains in place.
///      (2) `reactiveCallback` - executed on the origin chain by the Reactive callback proxy (no keeper).
///      (3) `settleEpoch` - operator fallback for deterministic Foundry/demo runs.
///      (4) `onEpochClose` (IPeripheral) - in-band push when `peripheralRegistry` points here.
contract EpochSettler is IPeripheral, AbstractReactive {
    /// @dev Gas budget the Reactive Network forwards when executing the scheduled callback.
    uint64 internal constant CALLBACK_GAS_LIMIT = 400_000;

    IStratumHook public immutable stratumHook;
    address public immutable operator;

    /// @notice topic_0 of `EpochClosed(bytes32,uint64,uint256,uint256)` on the hook.
    /// @dev The Reactive system contract rejects a fully catch-all subscription (topic_0 = REACTIVE_IGNORE)
    ///      when the subscriber is a reactive contract: at least one of chainId/contract/topic must be
    ///      concrete and an all-events-on-a-contract subscription is disallowed. We pin topic_0 to the
    ///      specific event this RSC reacts to. Verified on Lasna: a constructor subscribe with this concrete
    ///      topic_0 succeeds, whereas topic_0 = REACTIVE_IGNORE reverts with "Failure".
    uint256 internal constant TOPIC_EPOCH_CLOSED = 0x79e8f1a36b0a8a77d86cb19fc7f513840a167b8ff98eeed6ebd8fe9a03b474b2;

    /// @notice Chain id where the hook lives (callbacks target this chain).
    uint256 public immutable originChainId;

    /// @notice Reactive system contract permitted to drive `reactiveCallback`; address(0) on Foundry.
    address public reactiveCallbackSender;
    bool public enabled = true;

    error OnlyOperator();
    error OnlyReactiveOrOperator();

    event EpochSettleRequested(PoolId indexed poolId, uint64 epoch);
    event EpochClosePushed(PoolId indexed poolId, uint64 epoch);

    constructor(IStratumHook hook_, address operator_, uint256 originChainId_) AbstractReactive() {
        stratumHook = hook_;
        operator = operator_;
        originChainId = originChainId_;
        // Subscribe to the hook's EpochClosed event (poolId is topic_1). topic_0 must be concrete: the
        // Reactive system contract rejects a catch-all topic_0 from a reactive contract. No-op on a plain
        // EVM (NFR-01).
        _subscribe(originChainId_, address(hook_), TOPIC_EPOCH_CLOSED);
    }

    /// @inheritdoc IReactive
    /// @dev Reactive Network entrypoint: schedule a closeEpoch attempt for the pool that triggered the log.
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
