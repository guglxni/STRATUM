// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { IStratumHook } from "../../interfaces/IStratumHook.sol";
import { PoolTrancheState, TranchePosition, TrancheType } from "../../StratumTypes.sol";
import { CoverageRatio } from "../../libraries/CoverageRatio.sol";

/// @title TrancheIntentRegistry
/// @notice LP conditional intents (FR-30): an LP records "when condition C holds for my position, migrate it to
///         tranche T", and the registry executes that migration through the hook's conservation- and coverage-
///         checked `migrateTranchePosition` when the condition is met. Keeper-free execution is driven by the
///         `IntentSettlerRSC` (Reactive), but `executeIntent`/`sweep` are permissionless so anyone (or the LP)
///         can also trigger them.
/// @dev Non-custodial: the registry holds no funds and moves none. It can only flip the tranche of a position
///      that has explicitly approved it via `hook.approveMigrator(positionId, address(thisRegistry))` (FR-30).
///      Conditions are evaluated against on-chain hook state only (coverage ratio, senior target APY): no price
///      feed enters the decision (golden rule 2). The hook re-checks authorization, coverage (INV-01) and
///      conservation (INV-03) on every migration, so a forged or stale trigger can never violate an invariant;
///      at worst `executeIntent` reverts and the intent stays armed.
contract TrancheIntentRegistry {
    /// @notice The condition that arms an intent. All are read from internal hook accounting, never a price feed.
    enum ConditionType {
        COVERAGE_BELOW, // coverage ratio (junior/senior, bps) < threshold  -> typically de-risk junior->senior
        COVERAGE_ABOVE, // coverage ratio (junior/senior, bps) >= threshold -> typically senior->junior for upside
        SENIOR_APY_BELOW // pool senior target APY (bps) < threshold        -> senior->junior when fixed yield thins
    }

    struct Intent {
        bytes32 positionId;
        PoolId poolId;
        address lp;
        TrancheType toTranche;
        ConditionType conditionType;
        uint256 threshold; // bps for coverage or APY conditions
        bool active;
    }

    /// @dev Per-pool cap on registered intents so the keeper-free `sweep` can never be gas-griefed into
    ///      uselessness by an adversary spamming never-triggering intents (audit L-01). A bound, not a tunable.
    uint256 public constant MAX_POOL_INTENTS = 256;

    IStratumHook public immutable hook;

    Intent[] public intents;
    /// @notice Intent ids armed for a given pool, so the settler RSC can sweep a pool's intents on one event.
    mapping(PoolId => uint256[]) internal _poolIntents;

    error NotIntentOwner();
    error IntentInactive();
    error ConditionNotMet();
    error SameTranche();
    error PoolIdMismatch();
    error PoolIntentCapReached();

    event IntentRegistered(
        uint256 indexed intentId,
        bytes32 indexed positionId,
        address indexed lp,
        TrancheType toTranche,
        ConditionType conditionType,
        uint256 threshold
    );
    event IntentCancelled(uint256 indexed intentId);
    event IntentExecuted(uint256 indexed intentId, bytes32 indexed positionId, uint256 carriedPrincipal);

    constructor(IStratumHook hook_) {
        hook = hook_;
    }

    /// @notice Register a conditional migration intent for a position the caller owns.
    /// @dev The LP must ALSO call `hook.approveMigrator(positionId, address(this))` for execution to succeed;
    ///      that approval is the on-chain consent the hook checks. Registration here only records the trigger.
    /// @param positionId Position to migrate when the condition holds.
    /// @param poolId Pool the position belongs to (used to index and to read coverage/APY state).
    /// @param toTranche Destination tranche.
    /// @param conditionType Which on-chain metric arms the intent.
    /// @param threshold Comparison threshold (bps).
    /// @return intentId Newly created intent id.
    function registerIntent(
        bytes32 positionId,
        PoolId poolId,
        TrancheType toTranche,
        ConditionType conditionType,
        uint256 threshold
    ) external returns (uint256 intentId) {
        TranchePosition memory pos = hook.position(positionId);
        if (pos.owner != msg.sender) revert NotIntentOwner();
        if (pos.tranche == toTranche) revert SameTranche();
        // Bind the intent to the position's ACTUAL pool rather than trusting the caller's `poolId`: a mismatch
        // would index the intent under the wrong pool and evaluate the condition against unrelated state (L-02).
        if (PoolId.unwrap(hook.positionPool(positionId)) != PoolId.unwrap(poolId)) revert PoolIdMismatch();
        if (_poolIntents[poolId].length >= MAX_POOL_INTENTS) revert PoolIntentCapReached();

        intentId = intents.length;
        intents.push(
            Intent({
                positionId: positionId,
                poolId: poolId,
                lp: msg.sender,
                toTranche: toTranche,
                conditionType: conditionType,
                threshold: threshold,
                active: true
            })
        );
        _poolIntents[poolId].push(intentId);
        emit IntentRegistered(intentId, positionId, msg.sender, toTranche, conditionType, threshold);
    }

    /// @notice Cancel an armed intent. Owner-gated.
    function cancelIntent(uint256 intentId) external {
        Intent storage it = intents[intentId];
        if (it.lp != msg.sender) revert NotIntentOwner();
        it.active = false;
        emit IntentCancelled(intentId);
    }

    /// @notice Execute an intent if its condition currently holds. Permissionless: the gate is the condition
    ///         plus the hook's own authorization/coverage/conservation checks, not the caller's identity.
    /// @dev Marks the intent inactive on success (one-shot). The migration reverts inside the hook if coverage
    ///      would break (INV-01) or the registry is not approved (FR-30); that revert leaves the intent armed.
    function executeIntent(uint256 intentId) public returns (uint256 carriedPrincipal) {
        Intent storage it = intents[intentId];
        if (!it.active) revert IntentInactive();
        if (!_conditionMet(it)) revert ConditionNotMet();

        // Defensive: skip a no-op flip (the hook would revert MigrationToSameTranche otherwise).
        if (hook.position(it.positionId).tranche == it.toTranche) {
            it.active = false;
            return 0;
        }

        it.active = false; // effect before the external migration call (one-shot, no re-entrant double-exec)
        carriedPrincipal = hook.migrateTranchePosition(it.positionId, it.toTranche);
        emit IntentExecuted(intentId, it.positionId, carriedPrincipal);
    }

    /// @notice Execute up to `maxCount` ready intents for a pool. Called by the settler RSC on a pool event.
    /// @dev Gas-bounded by `maxCount`. Each execution is wrapped so one failing intent never blocks the rest.
    /// @param poolId Pool whose intents to sweep.
    /// @param maxCount Maximum number of intents to execute this call.
    /// @return executed Count of intents executed.
    function sweep(PoolId poolId, uint256 maxCount) external returns (uint256 executed) {
        uint256[] storage ids = _poolIntents[poolId];
        uint256 n = ids.length;
        for (uint256 i = 0; i < n && executed < maxCount; ++i) {
            uint256 intentId = ids[i];
            Intent storage it = intents[intentId];
            if (!it.active || !_conditionMet(it)) continue;
            // External self-call so a single revert (e.g. transient coverage breach) is isolated.
            try this.executeIntent(intentId) returns (uint256) {
                executed += 1;
            } catch {
                // leave armed for a later sweep
            }
        }
    }

    /// @notice Whether an intent is active and its condition currently holds.
    function conditionMet(uint256 intentId) external view returns (bool) {
        Intent storage it = intents[intentId];
        return it.active && _conditionMet(it);
    }

    /// @notice Number of intents registered for a pool (active or not).
    function poolIntentCount(PoolId poolId) external view returns (uint256) {
        return _poolIntents[poolId].length;
    }

    /// @notice Intent id at index `i` of a pool's list.
    function poolIntentAt(PoolId poolId, uint256 i) external view returns (uint256) {
        return _poolIntents[poolId][i];
    }

    function intentCount() external view returns (uint256) {
        return intents.length;
    }

    function _conditionMet(Intent storage it) internal view returns (bool) {
        PoolTrancheState memory pool = hook.poolState(it.poolId);
        if (it.conditionType == ConditionType.SENIOR_APY_BELOW) {
            return pool.targetAPYBps < it.threshold;
        }
        uint16 ratio = CoverageRatio.ratioBps(pool.juniorTVL, pool.seniorTVL);
        if (it.conditionType == ConditionType.COVERAGE_BELOW) {
            return ratio < it.threshold;
        }
        // COVERAGE_ABOVE
        return ratio >= it.threshold;
    }
}
