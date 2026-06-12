// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { IPeripheral } from "../../interfaces/IPeripheral.sol";
import { IStratumHook } from "../../interfaces/IStratumHook.sol";
import { IStylusMatchingEngine } from "./IStylusMatchingEngine.sol";
import { IMatchAttestation } from "../eigenlayer/IMatchAttestation.sol";
import { PoolTrancheState } from "../../StratumTypes.sol";

/// @title StylusShim
/// @notice STRATUM peripheral (kind == "STYLUS") that bridges the core hook to the Rust-based Stylus matching
///         and ML volatility engine on Arbitrum.
///
/// @dev Lifecycle per epoch:
///      1. `onEpochClose` is called by the hook after settling the epoch.
///      2. The shim calls `stylusEngine.submitPoolState` with the latest states for all registered pools.
///      3. The Stylus program (via Reactive relay) calls `deliverMatchResult` on this contract.
///      4. `applyMatchResult` is called by the operator (or Reactive) once the result has EigenLayer
///         attestation. It applies volatility overrides to the hook and logs netting/rebalance recommendations
///         for the CPHR to consume.
///
/// Volatility override store (ARCHITECTURE section 8 DSA requirement):
///      `mapping(PoolId => VolatilityOverride)` with O(1) staleness check on `block.timestamp`.
///      Overrides expire after `VOLATILITY_OVERRIDE_TTL` seconds; expired entries are ignored inline without
///      any write, preserving the invariant that the hook always has a usable EWMA.
///
/// Invariant interaction:
///      INV-03: no token movement; this peripheral is signal-only.
///      INV-05: does not touch `juniorReserve` directly.
///      NFR-01: failures in `onEpochClose` are caught by the core's gas-bounded try/catch, never block settlement.
contract StylusShim is IPeripheral {
    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------

    /// @notice Packed volatility override stored per pool.
    /// @dev `ewma` is the ML-predicted volatility EWMA (same scale as `PoolTrancheState.volatilityEWMA`).
    ///      `expiry` is a unix timestamp; once `block.timestamp > expiry` the entry is ignored (O(1) check).
    struct VolatilityOverride {
        uint256 ewma;
        uint256 expiry; // BS6: uint256 (was uint32, which truncated block.timestamp and could wrap)
    }

    /// @notice Pending result bundle awaiting EigenLayer attestation.
    struct PendingResult {
        bytes32 matchHash;
        bytes encodedResult;
        bool exists;
    }

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    /// @notice TTL in seconds for a volatility override before it is considered stale.
    uint32 public constant VOLATILITY_OVERRIDE_TTL = 15 minutes;

    // -------------------------------------------------------------------------
    // Immutables
    // -------------------------------------------------------------------------

    IStratumHook public immutable stratumHook;
    address public immutable operator;

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    /// @notice The Stylus matching engine program address (on Arbitrum).
    IStylusMatchingEngine public stylusEngine;

    /// @notice EigenLayer attestation contract; gates `applyMatchResult`.
    IMatchAttestation public matchAttestation;

    /// @notice Whether this peripheral is active.
    bool public enabled;

    /// @notice Monotone nonce: incremented with each `submitPoolState` call.
    uint64 public submissionNonce;

    /// @notice Pool IDs the shim submits to the engine on epoch close.
    PoolId[] public registeredPools;
    mapping(PoolId => bool) public isRegistered;

    /// @notice Volatility overrides indexed by pool ID (O(1) lookup, O(1) staleness check).
    mapping(PoolId => VolatilityOverride) public volatilityOverrides;

    /// @notice Pending results indexed by submission nonce, awaiting attestation.
    mapping(uint64 => PendingResult) public pendingResults;

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error OnlyOperator();
    error OnlyOperatorOrRelay();
    error EngineNotSet();
    error AttestationNotSet();
    error AttestationFailed(bytes32 matchHash);
    error ResultAlreadyApplied(uint64 nonce);
    error NoPendingResult(uint64 nonce);
    error ArrayLengthMismatch();
    error PoolAlreadyRegistered(PoolId id);
    error PoolNotRegistered(PoolId id);
    error MatchResultExpired(uint64 nonce, uint256 validUntil); // BS5
    error ZeroAddress(); // BS8

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event PoolRegistered(PoolId indexed poolId);
    event PoolUnregistered(PoolId indexed poolId);
    event PoolStateSubmitted(uint64 indexed nonce, uint256 poolCount);
    event MatchResultReceived(uint64 indexed nonce, bytes32 matchHash);
    event MatchResultApplied(uint64 indexed nonce, uint256 nettingPairs, uint256 rebalances);
    event VolatilityOverrideSet(PoolId indexed poolId, uint256 ewma, uint256 expiry);
    event VolatilityOverrideExpiredIgnored(PoolId indexed poolId);
    event StylusEngineSet(address engine);
    event AttestationContractSet(address attestation);

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /// @param hook_     The STRATUM core hook.
    /// @param operator_ Address permitted to configure and drive this shim.
    constructor(IStratumHook hook_, address operator_) {
        if (address(hook_) == address(0) || operator_ == address(0)) revert ZeroAddress(); // BS8
        stratumHook = hook_;
        operator = operator_;
        enabled = true;
    }

    // -------------------------------------------------------------------------
    // Configuration (operator-gated)
    // -------------------------------------------------------------------------

    /// @notice Wire the Stylus engine address and the EigenLayer attestation contract.
    /// @param engine_      Stylus program address (can be updated if redeployed).
    /// @param attestation_ EigenLayer attestation gating result application.
    function configure(IStylusMatchingEngine engine_, IMatchAttestation attestation_) external {
        if (msg.sender != operator) revert OnlyOperator();
        stylusEngine = engine_;
        matchAttestation = attestation_;
        emit StylusEngineSet(address(engine_));
        emit AttestationContractSet(address(attestation_));
    }

    /// @notice Enable or disable this peripheral.
    function setEnabled(bool v) external {
        if (msg.sender != operator) revert OnlyOperator();
        enabled = v;
    }

    /// @notice Register a pool for inclusion in the per-epoch state submission.
    /// @param id Pool to register.
    function registerPool(PoolId id) external {
        if (msg.sender != operator) revert OnlyOperator();
        if (isRegistered[id]) revert PoolAlreadyRegistered(id);
        isRegistered[id] = true;
        registeredPools.push(id);
        emit PoolRegistered(id);
    }

    /// @notice Remove a pool from the submission set.
    /// @dev Linear scan over a small array (registration changes are infrequent; O(n) acceptable).
    function unregisterPool(PoolId id) external {
        if (msg.sender != operator) revert OnlyOperator();
        if (!isRegistered[id]) revert PoolNotRegistered(id);
        isRegistered[id] = false;
        uint256 len = registeredPools.length;
        for (uint256 i = 0; i < len;) {
            if (PoolId.unwrap(registeredPools[i]) == PoolId.unwrap(id)) {
                registeredPools[i] = registeredPools[len - 1];
                registeredPools.pop();
                break;
            }
            unchecked {
                ++i;
            }
        }
        emit PoolUnregistered(id);
    }

    // -------------------------------------------------------------------------
    // IPeripheral
    // -------------------------------------------------------------------------

    /// @inheritdoc IPeripheral
    function kind() external pure returns (bytes32) {
        return keccak256("STYLUS");
    }

    /// @inheritdoc IPeripheral
    function isEnabled() external view returns (bool) {
        return enabled;
    }

    /// @notice Called by the hook after epoch close. Reads latest pool states and submits them to the Stylus
    ///         engine for the next matching run. No-op when disabled or engine not set (NFR-01 independence).
    /// @dev The hook calls this inside `_notifyEpochClose` with a gas stipend of 150,000. Submission may fail
    ///      if the engine is not yet configured; this is caught by the hook's try/catch, so it never blocks
    ///      settlement (golden rule 1).
    /// @param id    Pool that just closed its epoch.
    /// @param epoch The epoch that was closed.
    function onEpochClose(PoolId id, uint64 epoch, bytes calldata) external override returns (bytes memory) {
        if (!enabled || address(stylusEngine) == address(0)) return bytes("");

        // Snapshot all registered pools, including the one that just closed.
        uint256 len = registeredPools.length;
        if (len == 0) return bytes("");

        PoolId[] memory pools = new PoolId[](len);
        PoolTrancheState[] memory states = new PoolTrancheState[](len);
        for (uint256 i = 0; i < len;) {
            pools[i] = registeredPools[i];
            states[i] = stratumHook.poolState(registeredPools[i]);
            unchecked {
                ++i;
            }
        }

        uint64 nonce = ++submissionNonce;
        emit PoolStateSubmitted(nonce, len);

        // External call to Stylus engine: failures are swallowed (non-blocking peripheral).
        try stylusEngine.submitPoolState(pools, states, nonce) {
        // success; result will arrive via deliverMatchResult
        }
            catch {
            // Log is not emitted here to save gas; the hook already logs PeripheralCallFailed.
        }

        // Suppress unused parameter warning for epoch; it is included for IPeripheral compliance.
        epoch;
        id;

        return bytes("");
    }

    /// @inheritdoc IPeripheral
    /// @dev No-op: the shim has no coverage-stress response other than submitting state on epoch close.
    function onCoverageStress(PoolId, uint16) external override { }

    // -------------------------------------------------------------------------
    // Result delivery (called by Stylus program via Reactive relay)
    // -------------------------------------------------------------------------

    /// @notice Called by the Stylus program (or its on-chain relay) to deliver a computed match result.
    /// @dev Stores the result pending EigenLayer attestation. Does NOT apply state changes.
    ///      The `matchHash` is derived deterministically from `(nonce, encodedResult)` so the attestation
    ///      contract can verify against the same hash the operators signed.
    /// @param nonce         The nonce echoed from the corresponding `submitPoolState`.
    /// @param encodedResult ABI-encoded `IStylusMatchingEngine.MatchResult`.
    function deliverMatchResult(uint64 nonce, bytes calldata encodedResult) external {
        // BS7: positive allow-list. Only the operator or the configured engine may deliver. When the engine
        // is unset (address(0)) no real sender can equal it, so this is operator-only - the intended default.
        if (msg.sender != operator && msg.sender != address(stylusEngine)) {
            revert OnlyOperatorOrRelay();
        }
        if (pendingResults[nonce].exists) revert ResultAlreadyApplied(nonce);

        bytes32 matchHash = keccak256(abi.encodePacked(nonce, encodedResult));
        pendingResults[nonce] = PendingResult({ matchHash: matchHash, encodedResult: encodedResult, exists: true });
        emit MatchResultReceived(nonce, matchHash);
    }

    // -------------------------------------------------------------------------
    // Application (operator or Reactive-gated, after EigenLayer attestation)
    // -------------------------------------------------------------------------

    /// @notice Apply a stored match result to the hook state after EigenLayer attestation is confirmed.
    /// @dev Checks `matchAttestation.isAttested(matchHash)` before applying any state mutation.
    ///      Volatility overrides are written to the shim's storage; the hook reads them via
    ///      `getVolatilityOverride`. Netting and rebalance recommendations are emitted as events for the CPHR
    ///      to consume (the CPHR is a separate contract; this shim does not call it directly to preserve
    ///      INV-05 and the peripheral isolation guarantee).
    /// @param nonce The nonce identifying the pending result to apply.
    function applyMatchResult(uint64 nonce) external {
        if (msg.sender != operator) revert OnlyOperator();
        if (!pendingResults[nonce].exists) revert NoPendingResult(nonce);

        PendingResult storage pending = pendingResults[nonce];
        bytes32 matchHash = pending.matchHash;

        // Gate on EigenLayer attestation (FR-24): abort if operators have not reached quorum.
        if (address(matchAttestation) != address(0) && !matchAttestation.isAttested(matchHash)) {
            revert AttestationFailed(matchHash);
        }

        IStylusMatchingEngine.MatchResult memory result =
            abi.decode(pending.encodedResult, (IStylusMatchingEngine.MatchResult));

        // BS5: reject a result past its validity window. A stale match must not write stale volatility
        // predictions. `validUntil == 0` means "no expiry" (the engine opted out).
        if (result.validUntil != 0 && block.timestamp > result.validUntil) {
            revert MatchResultExpired(nonce, result.validUntil);
        }

        // Apply volatility overrides for each pool in the result (parallel to registered pools at
        // submission time). predictedVolatilityEWMA has one entry per pool submitted.
        uint256 poolCount = registeredPools.length;
        uint256 predCount = result.predictedVolatilityEWMA.length;
        uint256 applyCount = poolCount < predCount ? poolCount : predCount;
        uint256 expiry = block.timestamp + VOLATILITY_OVERRIDE_TTL; // BS6: no uint32 truncation
        for (uint256 i = 0; i < applyCount;) {
            PoolId pid = registeredPools[i];
            uint256 ewma = result.predictedVolatilityEWMA[i];
            volatilityOverrides[pid] = VolatilityOverride({ ewma: ewma, expiry: expiry });
            emit VolatilityOverrideSet(pid, ewma, expiry);
            unchecked {
                ++i;
            }
        }

        // Emit netting and rebalance recommendations for CPHR consumption (off-chain relay or
        // Reactive event subscription picks these up and calls the appropriate CPHR methods).
        uint256 nettingLen = result.nettingPairs.length;
        uint256 rebalanceLen = result.rebalances.length;

        for (uint256 i = 0; i < nettingLen;) {
            IStylusMatchingEngine.NettingPair memory p = result.nettingPairs[i];
            emit NettingRecommended(nonce, p.poolA, p.poolB, p.netValue, p.correlationWeightBps);
            unchecked {
                ++i;
            }
        }
        for (uint256 i = 0; i < rebalanceLen;) {
            IStylusMatchingEngine.RebalanceRecommendation memory r = result.rebalances[i];
            emit RebalanceRecommended(nonce, r.sourcePool, r.targetPool, r.amount, r.crossChain, r.targetChainId);
            unchecked {
                ++i;
            }
        }

        // Delete to prevent double-application.
        delete pendingResults[nonce];
        emit MatchResultApplied(nonce, nettingLen, rebalanceLen);
    }

    // -------------------------------------------------------------------------
    // Volatility override read (called by the hook's beforeSwap path)
    // -------------------------------------------------------------------------

    /// @notice Return the ML volatility override for `id`, or 0 if not set or expired.
    /// @dev O(1) mapping lookup plus timestamp comparison. Callers treat 0 as "use on-chain EWMA".
    /// @param id Pool ID to query.
    /// @return ewma The predicted volatility EWMA, or 0 if the override is absent or stale.
    function getVolatilityOverride(PoolId id) external view returns (uint256 ewma) {
        VolatilityOverride memory ov = volatilityOverrides[id];
        if (ov.expiry == 0 || block.timestamp > ov.expiry) {
            return 0;
        }
        return ov.ewma;
    }

    /// @notice Manually set a volatility override for a pool (operator path for demo/testing).
    /// @param id   Pool to override.
    /// @param ewma New EWMA value (same scale as `PoolTrancheState.volatilityEWMA`).
    function setVolatilityOverride(PoolId id, uint256 ewma) external {
        if (msg.sender != operator) revert OnlyOperator();
        uint256 expiry = block.timestamp + VOLATILITY_OVERRIDE_TTL; // BS6: no uint32 truncation
        volatilityOverrides[id] = VolatilityOverride({ ewma: ewma, expiry: expiry });
        emit VolatilityOverrideSet(id, ewma, expiry);
    }

    // -------------------------------------------------------------------------
    // View helpers
    // -------------------------------------------------------------------------

    /// @notice Number of registered pools.
    function registeredPoolCount() external view returns (uint256) {
        return registeredPools.length;
    }

    // -------------------------------------------------------------------------
    // Events for CPHR consumption (emitted from applyMatchResult)
    // -------------------------------------------------------------------------

    /// @notice Emitted for each netting pair recommendation; CPHR subscribes via Reactive.
    event NettingRecommended(
        uint64 indexed nonce, PoolId indexed poolA, PoolId indexed poolB, uint256 netValue, uint16 correlationWeightBps
    );

    /// @notice Emitted for each rebalance recommendation; CPHR subscribes via Reactive.
    event RebalanceRecommended(
        uint64 indexed nonce,
        PoolId indexed sourcePool,
        PoolId indexed targetPool,
        uint256 amount,
        bool crossChain,
        uint256 targetChainId
    );
}
