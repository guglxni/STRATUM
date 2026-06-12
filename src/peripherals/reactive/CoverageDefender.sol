// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { IStratumHook } from "../../interfaces/IStratumHook.sol";
import { IPeripheral } from "../../interfaces/IPeripheral.sol";
import { PoolTrancheState } from "../../StratumTypes.sol";
import { CoverageRatio } from "../../libraries/CoverageRatio.sol";
import { IReserveRebalanceTarget } from "./IReserveRebalanceTarget.sol";
import { AbstractReactive } from "./AbstractReactive.sol";
import { IReactive } from "./IReactive.sol";

/// @title CoverageDefender
/// @notice Reactive Smart Contract that turns STRATUM's hard coverage floor into a graduated, continuous
///         defense of the junior buffer (P1, "slope not cliff"). It is the acting sibling of the signal-only
///         `CoverageMonitor`: where the monitor only reports stress, the defender translates the coverage
///         gradient into a proportional, signal-only rebalance ask routed to the Cross-Pool Hedging Router.
/// @dev Golden-rule posture:
///      - Core independence (NFR-01, golden rule 1): the hook never depends on this contract; it acts only by
///        calling an external `IReserveRebalanceTarget` (the CPHR), never back into the hook. With no
///        peripheral wired, STRATUM's hard coverage floor still holds unchanged.
///      - No oracle (golden rule 2): the trigger reads the coverage ratio (junior/senior TVL), internal
///        accounting state, not a price feed. IL math is untouched.
///      - Junior buffer protection (golden rule 3): this contract exists to protect it, and is non-custodial
///        (holds no funds, moves none itself). Actual fund movement stays behind the CPHR's gated, conservation
///        -checked path (`StratumHook.rebalanceReserve` / `creditReserve`).
///      Two drive paths converge on `_defend`, mirroring the other STRATUM RSCs:
///      (1) the canonical Reactive path: subscribe to the hook's `CoverageStress` log; `react` schedules a
///          `reactiveCallback(poolId)` callback on the origin chain (no keeper);
///      (2) the IPeripheral in-band path: when wired as the pool's `peripheralRegistry`, the hook pushes
///          `onCoverageStress`/`onEpochClose` directly (the latter gives a per-epoch re-assessment cadence).
contract CoverageDefender is IPeripheral, AbstractReactive {
    using CoverageRatio for uint16;

    /// @dev Gas budget the Reactive Network forwards when executing the scheduled callback.
    uint64 internal constant CALLBACK_GAS_LIMIT = 350_000;

    IStratumHook public immutable stratumHook;
    address public immutable operator;
    uint256 public immutable originChainId;

    /// @notice topic_0 of `CoverageStress(bytes32,uint16,uint16)` on the hook (poolId is topic_1).
    /// @dev Pinned to a concrete event: the Reactive system contract rejects a catch-all topic_0
    ///      (REACTIVE_IGNORE) from a reactive contract. Same event `CoverageMonitor` subscribes to.
    uint256 internal constant TOPIC_COVERAGE_STRESS =
        0xb5bddf1d3f05cf57e7ed2c18267a1e2ee4b5656d7ad99545fae6e4205b3750f3;

    /// @notice Reactive system contract permitted to drive `reactiveCallback`; address(0) on Foundry.
    address public reactiveCallbackSender;
    /// @notice CPHR (Across router, FR-18/19). address(0) = inert: stress is assessed but nothing is requested.
    IReserveRebalanceTarget public rebalanceTarget;
    bool public enabled = true;

    /// @dev Reentrancy guard: `_defend` is reachable from a hook in-band push during afterAddLiquidity. The
    ///      action only calls an external rebalance target (never the hook), but the lock is defense-in-depth.
    uint256 private _locked = 1;

    error OnlyOperator();
    error OnlyReactiveOrOperator();
    error Reentrancy();

    event DefenseAssessed(PoolId indexed poolId, uint16 coverageRatioBps, uint16 remediationScaleBps);
    event RemediationRequested(
        PoolId indexed poolId, uint16 coverageRatioBps, uint16 remediationScaleBps, uint256 inflowAsk
    );
    /// @notice The rebalance ask was computed but the CPHR call failed (reverted or ran out of the in-band
    ///         stipend). Surfaced as a targeted alert so the dropped assessment is observable (audit F1).
    event RemediationDispatchFailed(PoolId indexed poolId, uint256 inflowAsk);
    event RebalanceTargetSet(address target);
    event CoverageDefenderEnabled(bool enabled);
    event CoverageStressPushed(PoolId indexed poolId, uint16 ratioBps);

    modifier nonReentrant() {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    constructor(IStratumHook hook_, address operator_, uint256 originChainId_) AbstractReactive() {
        stratumHook = hook_;
        operator = operator_;
        originChainId = originChainId_;
        // Subscribe to the hook's CoverageStress event (poolId is topic_1). No-op on a plain EVM (NFR-01).
        _subscribe(originChainId_, address(hook_), TOPIC_COVERAGE_STRESS);
    }

    // --- Reactive path -----------------------------------------------------------------------------------

    /// @inheritdoc IReactive
    /// @dev Reactive entrypoint: schedule a defense assessment for the pool that triggered the log.
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

    /// @notice Reactive path: the Reactive system contract drives the defense assessment on a coverage event.
    function reactiveCallback(PoolId poolId) external {
        if (msg.sender != reactiveCallbackSender && msg.sender != operator) revert OnlyReactiveOrOperator();
        _defend(poolId);
    }

    /// @notice Testnet/demo fallback: operator drives an assessment deterministically (no live subscription).
    function defend(PoolId poolId) external {
        if (msg.sender != operator) revert OnlyOperator();
        _defend(poolId);
    }

    // --- Operator wiring ---------------------------------------------------------------------------------

    /// @notice Wire the CPHR target and the Reactive system sender (operator-gated).
    /// @dev Re-wirable by the operator: this contract is non-custodial and signal-only, so allowing the
    ///      operator to correct a misconfigured target is safe (no fund custody can be redirected). Matches
    ///      the existing ReserveBalancer.configure trust model (audit F2: not a one-time lock by design).
    function configure(IReserveRebalanceTarget target_, address reactiveCallbackSender_) external {
        if (msg.sender != operator) revert OnlyOperator();
        rebalanceTarget = target_;
        reactiveCallbackSender = reactiveCallbackSender_;
        emit RebalanceTargetSet(address(target_));
    }

    /// @notice Enable or disable graduated remediation (operator-gated). Disabled = assess-only, no request.
    function setEnabled(bool enabled_) external {
        if (msg.sender != operator) revert OnlyOperator();
        enabled = enabled_;
        emit CoverageDefenderEnabled(enabled_);
    }

    /// @notice Route scheduled callbacks to this RSC's twin on the destination chain (operator-gated).
    /// @dev Set `destCallback == address(0)` to revert to the same-chain (`address(this)`) fallback.
    function setReactiveDestination(uint256 destChainId, address destCallback) external {
        if (msg.sender != operator) revert OnlyOperator();
        destinationChainId = destChainId;
        destinationCallback = destCallback;
        emit ReactiveDestinationSet(destChainId, destCallback);
    }

    // --- IPeripheral (in-band push from the hook when peripheralRegistry == this) -------------------------

    /// @inheritdoc IPeripheral
    function kind() external pure returns (bytes32) {
        return keccak256("stratum.reactive.coverage.defender");
    }

    /// @inheritdoc IPeripheral
    /// @dev Re-assess on every epoch close so slow coverage decay is caught even without a triggering deposit
    ///      (the ReacDEFI block-cadence idea). Best-effort; the hook discards the return value.
    function onEpochClose(PoolId id, uint64, bytes calldata) external returns (bytes memory) {
        _defend(id);
        return bytes("");
    }

    /// @inheritdoc IPeripheral
    /// @dev In-band stress push from the hook (afterAddLiquidity). Acts on the same pool. Gas-bounded by the
    ///      hook's stipend and wrapped in the hook's try-catch, so it can never block core settlement (NFR-01).
    function onCoverageStress(PoolId id, uint16 ratioBps) external {
        emit CoverageStressPushed(id, ratioBps);
        _defend(id);
    }

    /// @inheritdoc IPeripheral
    function isEnabled() external view returns (bool) {
        return enabled;
    }

    // --- Core logic --------------------------------------------------------------------------------------

    /// @dev Read the pool's coverage, compute the graduated remediation intensity, and (if remediation is
    ///      warranted and a target is wired) fire a proportional, signal-only inflow request to the CPHR.
    ///      Sizing: the ask is the junior shortfall needed to restore coverage toward `coverageTargetBps`,
    ///      scaled by the remediation intensity. It is an ASK only; the CPHR decides actual sizing and
    ///      executes any movement through the hook's conservation-checked, creator-gated path (INV-03).
    function _defend(PoolId poolId) internal nonReentrant {
        PoolTrancheState memory pool = stratumHook.poolState(poolId);
        uint16 ratio = CoverageRatio.ratioBps(pool.juniorTVL, pool.seniorTVL);
        uint16 scale = CoverageRatio.remediationScaleBps(ratio, pool.coverageTriggerBps, pool.minCoverageRatioBps);

        emit DefenseAssessed(poolId, ratio, scale);
        if (scale == 0) return; // healthy band: nothing to do

        // Junior value needed to restore coverage to the target band, then scaled by remediation intensity.
        uint256 desiredJunior = uint256(pool.seniorTVL) * uint256(pool.coverageTargetBps) / 10_000;
        uint256 deficit = desiredJunior > pool.juniorTVL ? desiredJunior - pool.juniorTVL : 0;
        uint256 inflowAsk = deficit * uint256(scale) / 10_000;
        if (inflowAsk == 0) return;
        // Clamp before the signed cast so a pathological value can never wrap to a positive "surplus" signal.
        if (inflowAsk > uint256(type(int256).max)) inflowAsk = uint256(type(int256).max);

        emit RemediationRequested(poolId, ratio, scale, inflowAsk);
        if (enabled && address(rebalanceTarget) != address(0)) {
            // Negative divergence = local deficit needing inflow (IReserveRebalanceTarget convention). Wrapped
            // in try/catch so a reverting or gas-starved CPHR surfaces a targeted RemediationDispatchFailed
            // alert instead of silently dropping the assessment through the hook's generic catch (audit F1).
            try rebalanceTarget.requestRebalance(poolId, -int256(inflowAsk)) { }
            catch {
                emit RemediationDispatchFailed(poolId, inflowAsk);
            }
        }
    }
}
