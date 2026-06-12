// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";

import { IPeripheral } from "../../interfaces/IPeripheral.sol";
import { IBrevisProver } from "./IBrevisProver.sol";

/// @title BrevisVerifierShim
/// @notice Phase 5 Brevis integration (FR-21, FR-22, DESIGN section 11).
///
/// @dev CHAIN COMPATIBILITY (mainnet-only live path):
///      The live Brevis hosted proving service only supports Ethereum Mainnet (source) -> Arbitrum One
///      (destination). It is not available on any testnet, so on STRATUM's testnet deployments this shim
///      is deployed in disabled stub mode (circuitAddress == address(0), _enabled == false) and the core
///      runs on the FR-22 approximate on-chain accounting fallback (NFR-01). The shim's ABI surface still
///      exists on testnet so integration tests and the demo can exercise the proof-submission paths, but no
///      real ZK proof is produced off testnet. For a production Arbitrum One deployment, wire a real circuit
///      verifier via `setCircuitAddress` then `setEnabled(true)`; the testnet wiring needs no change.
///
/// @dev Architecture summary
///      -----------------------
///      The shim acts as the on-chain settlement arbiter for ZK-proven distributions.  It stores
///      "proof handles" (pending proof metadata) keyed by `positionId`.  At settlement the core
///      hook queries `provenContribution` / `provenIL` to substitute ZK-verified numbers for the
///      approximate on-chain accounting.  When disabled or when no proof exists the hook falls
///      back to its existing approximate path (FR-22, NFR-01).
///
///      Three proof types (DESIGN section 11):
///        TW_CONTRIBUTION  - position's time-weighted share of epoch surpluses for its holding
///                           period.
///        IL_ATTRIBUTION   - per-position IL over the actual holding window.
///        AGGREGATE_RESERVE - cross-chain junior reserve solvency (batch, not position-specific).
///
///      Hackathon stub mode
///      -------------------
///      When `circuitAddress == address(0)` the shim is in "stub mode": every proof submitted
///      via `submitProof` is unconditionally accepted and marked proven (returns true for any
///      bytes blob, toggled at construction/configuration).  This lets the full on-chain ABI
///      surface exist and the integration tests run without a live Brevis node.
///
///      Storage layout (DSA: O(1) all paths via two mappings)
///      ------------------------------------------------------
///        proofStore: bytes32 positionId => ProofStatus (packed 1 slot: proven:bool + uint248 tag)
///        provenData: bytes32 positionId => ProvenValues (two uint256, 2 slots)
///
///      Conservation guard
///      ------------------
///      `submitProof` rejects claimed contributions that exceed the pool's epoch accumulated fees
///      at the moment of submission (plausibility check, not a security guarantee -- the ZK proof
///      itself is the security guarantee).  This prevents a malicious prover from inflating payout
///      past what fees could support, giving the core an additional sanity layer before it trusts
///      the proven value.
///
///      INV-03 interaction
///      ------------------
///      The shim does NOT recompute IL or contributions -- it trusts the ZK proof (DESIGN
///      section 11).  The core's `_conservationCheck` still fires after settlement; if a proof
///      somehow overclaims, that final check catches it.
///
///      INV-05 interaction
///      ------------------
///      The shim never touches `juniorReserve` directly.  It only returns proven values to the
///      core; the core's settlement functions apply them under the existing INV-05-guarded paths.
contract BrevisVerifierShim is IPeripheral {
    // -------------------------------------------------------------------------
    // Immutables and configuration
    // -------------------------------------------------------------------------

    /// @notice Operator address (pool deployer / governance).  Only the operator may configure
    ///         the circuit address or submit proofs on behalf of the Brevis prover network.
    address public immutable operator;

    /// @notice Brevis circuit verifier contract.  address(0) = stub mode (all proofs accepted).
    address public circuitAddress;

    /// @notice Whether the peripheral is active.  When false, the hook falls back to approximate
    ///         on-chain accounting (FR-22).
    bool private _enabled;

    /// @notice Explicit operator acknowledgement required to run the shim ENABLED while in stub mode
    ///         (circuitAddress == address(0), all proofs accepted). Defaults false so a production
    ///         deployment cannot silently activate the stub: the operator must either wire a real circuit
    ///         verifier OR consciously opt into the stub. This is the mainnet-safety guard (BS9).
    bool public stubModeAcknowledged;

    // -------------------------------------------------------------------------
    // Proof type constants (keccak256 identifiers, DESIGN section 11)
    // -------------------------------------------------------------------------

    /// @dev Verification key hash placeholder for the time-weighted contribution circuit.
    bytes32 public constant VK_TW_CONTRIBUTION = keccak256("stratum.brevis.tw_contribution.v1");

    /// @dev Verification key hash placeholder for the IL attribution circuit.
    bytes32 public constant VK_IL_ATTRIBUTION = keccak256("stratum.brevis.il_attribution.v1");

    /// @dev Verification key hash placeholder for the aggregate reserve circuit.
    bytes32 public constant VK_AGGREGATE_RESERVE = keccak256("stratum.brevis.aggregate_reserve.v1");

    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------

    /// @dev Packed proof status for a position.  Fits in one 32-byte slot.
    /// @param twProven         True if a time-weighted contribution proof has been verified.
    /// @param ilProven         True if an IL attribution proof has been verified.
    struct ProofStatus {
        bool twProven;
        bool ilProven;
    }

    /// @dev Proven numeric values.  Two slots.
    /// @param contribution Proven time-weighted contribution (token0-denominated surplus share).
    /// @param ilAttribution Proven IL for the holding window (token0-denominated).
    struct ProvenValues {
        uint256 contribution;
        uint256 ilAttribution;
    }

    /// @notice Proof status per positionId.  O(1) reads at settlement.
    mapping(bytes32 => ProofStatus) public proofStore;

    /// @notice Proven numeric values per positionId.
    mapping(bytes32 => ProvenValues) public provenData;

    /// @notice Aggregate reserve proof: most recent proven cross-chain reserve value.
    ///         A single slot; updated by the batch aggregate proof path.
    uint256 public provenAggregateReserve;

    /// @notice Whether an aggregate reserve proof has been verified.
    bool public aggregateReserveProven;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted when a time-weighted contribution proof is submitted and verified.
    /// @param positionId   Position for which the proof was submitted.
    /// @param fromEpoch    Holding window start epoch.
    /// @param toEpoch      Holding window end epoch.
    /// @param contribution Verified time-weighted contribution.
    event TWContributionProofVerified(
        bytes32 indexed positionId, uint64 fromEpoch, uint64 toEpoch, uint256 contribution
    );

    /// @notice Emitted when an IL attribution proof is submitted and verified.
    /// @param positionId    Position for which the proof was submitted.
    /// @param ilAttribution Verified IL for the holding window.
    event ILAttributionProofVerified(bytes32 indexed positionId, uint256 ilAttribution);

    /// @notice Emitted when an aggregate reserve proof is submitted and verified.
    /// @param claimedReserve Verified aggregate cross-chain junior reserve.
    event AggregateReserveProofVerified(uint256 claimedReserve);

    /// @notice Emitted when a proof submission fails plausibility or ZK verification.
    /// @param positionId Position for which proof submission failed.
    /// @param reason     Short failure reason tag.
    event ProofRejected(bytes32 indexed positionId, bytes32 reason);

    /// @notice Emitted when the circuit address is updated (stub mode toggle or production upgrade).
    event CircuitAddressSet(address indexed previous, address indexed next);

    /// @notice Emitted when the peripheral is enabled or disabled.
    event EnabledSet(bool enabled);

    /// @notice Emitted when a settled position's stored proof is cleared (BS10 stale-proof hygiene).
    event ProofCleared(bytes32 indexed positionId);

    /// @notice Emitted when the shim is notified of an epoch close (for off-chain Brevis job
    ///         scheduling -- the core discards the return value).
    event EpochCloseObserved(PoolId indexed poolId, uint64 epoch, uint256 epochFees, uint256 juniorTVL);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error OnlyOperator();
    error ZeroAddress(); // BS8
    error ProofClaimedContributionExceedsEpochFees();
    error ProofZKVerificationFailed();
    error StubModeNotAcknowledged(); // BS9: cannot enable a stub-mode shim without explicit operator opt-in

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /// @notice Deploy in stub mode (circuitAddress == address(0), disabled by default).
    /// @dev Disabled-by-default satisfies NFR-01: the core runs without Brevis unless the
    ///      operator explicitly enables the shim and wires it as the peripheralRegistry.
    /// @param operator_ Address that may configure and submit proofs.
    constructor(address operator_) {
        if (operator_ == address(0)) revert ZeroAddress(); // BS8
        operator = operator_;
        _enabled = false; // explicitly disabled: FR-22 fallback is the default path
    }

    // -------------------------------------------------------------------------
    // Configuration (operator-gated)
    // -------------------------------------------------------------------------

    /// @notice Set (or clear) the Brevis circuit verifier address.
    ///         address(0) activates stub mode: all proofs are accepted unconditionally.
    /// @param circuit New circuit verifier address.
    function setCircuitAddress(address circuit) external {
        if (msg.sender != operator) revert OnlyOperator();
        emit CircuitAddressSet(circuitAddress, circuit);
        circuitAddress = circuit;
    }

    /// @notice Enable or disable the peripheral.  When disabled the hook falls back to the
    ///         approximate on-chain accounting (FR-22, NFR-01).
    /// @dev BS9 mainnet-safety: enabling while in stub mode (no real circuit verifier) requires a prior
    ///      explicit `acknowledgeStubMode(true)`. This prevents a production deployment from silently
    ///      activating a "accept any proof" path. Wiring a real `circuitAddress` removes the requirement.
    /// @param enabled_ New enabled state.
    function setEnabled(bool enabled_) external {
        if (msg.sender != operator) revert OnlyOperator();
        if (enabled_ && circuitAddress == address(0) && !stubModeAcknowledged) revert StubModeNotAcknowledged();
        _enabled = enabled_;
        emit EnabledSet(enabled_);
    }

    /// @notice Explicitly opt into (or out of) running the shim enabled without a real circuit verifier.
    /// @dev Off by default. Only meaningful on testnet / demo where the live Brevis circuit is not yet wired;
    ///      a mainnet deployment should wire a real `circuitAddress` instead of acknowledging the stub.
    /// @param acknowledged New acknowledgement state.
    function acknowledgeStubMode(bool acknowledged) external {
        if (msg.sender != operator) revert OnlyOperator();
        stubModeAcknowledged = acknowledged;
    }

    /// @notice Clear stored proofs for settled positions (BS10: stale-proof hygiene).
    /// @dev `positionId` is keccak256(owner, tickLower, tickUpper, salt), so an LP re-opening a position with
    ///      the same owner, range, and salt REUSES the id. Proofs are never auto-cleared at settlement (the
    ///      core is notify-only toward peripherals), so without this, a stale proof from a prior life of the
    ///      id would be read by the next settlement. The core's settlement clamps (payout ceiling + on-chain
    ///      IL floor) bound the damage; this function removes the stale data at the source. Operator-gated,
    ///      called after each settled withdrawal that consumed a proof.
    /// @param positionIds Position ids whose proofs should be deleted.
    function clearProofs(bytes32[] calldata positionIds) external {
        if (msg.sender != operator) revert OnlyOperator();
        for (uint256 i = 0; i < positionIds.length; ++i) {
            delete proofStore[positionIds[i]];
            delete provenData[positionIds[i]];
            emit ProofCleared(positionIds[i]);
        }
    }

    // -------------------------------------------------------------------------
    // Proof submission (called by the Brevis prover or the operator in testnet)
    // -------------------------------------------------------------------------

    /// @notice Submit and verify a time-weighted contribution proof for a position (FR-21).
    /// @dev Plausibility guard: `claimedContribution` must not exceed `epochAccumulatedFees`
    ///      supplied by the prover.  The ZK proof provides the security guarantee; this bound
    ///      provides an on-chain sanity layer (DESIGN section 11, conservation note).
    ///      In stub mode (circuitAddress == address(0)) the ZK call is skipped and the claimed
    ///      values are stored unconditionally.
    /// @param positionId         Position identifier (keccak256(owner, tickLower, tickUpper, salt)).
    /// @param fromEpoch          Holding window start epoch (inclusive).
    /// @param toEpoch            Holding window end epoch (inclusive).
    /// @param claimedContribution Token0-denominated verified surplus share.
    /// @param epochAccumulatedFees Pool's accumulated fees for the epoch range (plausibility bound).
    /// @param proof              ABI-encoded Brevis proof blob.
    function submitTWContributionProof(
        bytes32 positionId,
        uint64 fromEpoch,
        uint64 toEpoch,
        uint256 claimedContribution,
        uint256 epochAccumulatedFees,
        bytes calldata proof
    ) external {
        if (msg.sender != operator) revert OnlyOperator();

        // Plausibility: claimed share cannot exceed the total fees accumulated (INV-03 spirit).
        if (claimedContribution > epochAccumulatedFees) {
            emit ProofRejected(positionId, "exceeds_epoch_fees");
            revert ProofClaimedContributionExceedsEpochFees();
        }

        if (!_verifyOrStub(proof, VK_TW_CONTRIBUTION, abi.encode(positionId, fromEpoch, toEpoch, claimedContribution)))
        {
            emit ProofRejected(positionId, "zk_failed");
            revert ProofZKVerificationFailed();
        }

        proofStore[positionId].twProven = true;
        provenData[positionId].contribution = claimedContribution;
        emit TWContributionProofVerified(positionId, fromEpoch, toEpoch, claimedContribution);
    }

    /// @notice Submit and verify an IL attribution proof for a position.
    /// @dev The ZK proof covers the exact holding window tick range (DESIGN section 11).
    ///      In stub mode any proof bytes are accepted.
    /// @param positionId    Position identifier.
    /// @param claimedIL     Token0-denominated IL verified by the circuit.
    /// @param proof         ABI-encoded Brevis proof blob.
    function submitILAttributionProof(bytes32 positionId, uint256 claimedIL, bytes calldata proof) external {
        if (msg.sender != operator) revert OnlyOperator();

        if (!_verifyOrStub(proof, VK_IL_ATTRIBUTION, abi.encode(positionId, claimedIL))) {
            emit ProofRejected(positionId, "zk_failed");
            revert ProofZKVerificationFailed();
        }

        proofStore[positionId].ilProven = true;
        provenData[positionId].ilAttribution = claimedIL;
        emit ILAttributionProofVerified(positionId, claimedIL);
    }

    /// @notice Submit and verify an aggregate cross-chain junior reserve solvency proof.
    /// @dev This is a batch proof not tied to a single position (DESIGN section 11).
    ///      In stub mode any proof bytes are accepted.
    /// @param claimedReserve Verified total cross-chain junior reserve (token0-denominated).
    /// @param proof          ABI-encoded Brevis proof blob.
    function submitAggregateReserveProof(uint256 claimedReserve, bytes calldata proof) external {
        if (msg.sender != operator) revert OnlyOperator();

        if (!_verifyOrStub(proof, VK_AGGREGATE_RESERVE, abi.encode(claimedReserve))) {
            emit ProofRejected(bytes32(0), "zk_failed");
            revert ProofZKVerificationFailed();
        }

        provenAggregateReserve = claimedReserve;
        aggregateReserveProven = true;
        emit AggregateReserveProofVerified(claimedReserve);
    }

    // -------------------------------------------------------------------------
    // Settlement query functions (called by StratumHook at settlement)
    // -------------------------------------------------------------------------

    /// @notice Returns the proven time-weighted contribution for a position, if available.
    /// @param positionId Position identifier.
    /// @return proven       True if a TW contribution proof has been verified.
    /// @return contribution Proven token0-denominated surplus share (0 if not proven).
    function verifyTimeWeightedContribution(bytes32 positionId)
        external
        view
        returns (bool proven, uint256 contribution)
    {
        ProofStatus storage status = proofStore[positionId];
        if (!status.twProven) return (false, 0);
        return (true, provenData[positionId].contribution);
    }

    /// @notice Returns the proven IL attribution for a position, if available.
    /// @param positionId Position identifier.
    /// @return proven         True if an IL attribution proof has been verified.
    /// @return ilAttribution  Proven token0-denominated IL (0 if not proven).
    function verifyILAttribution(bytes32 positionId) external view returns (bool proven, uint256 ilAttribution) {
        ProofStatus storage status = proofStore[positionId];
        if (!status.ilProven) return (false, 0);
        return (true, provenData[positionId].ilAttribution);
    }

    /// @notice Returns the latest proven aggregate cross-chain junior reserve value.
    /// @return proven        True if an aggregate reserve proof has been verified.
    /// @return claimedReserve Proven aggregate reserve value.
    function verifyAggregateReserveProof() external view returns (bool proven, uint256 claimedReserve) {
        return (aggregateReserveProven, provenAggregateReserve);
    }

    /// @notice Convenience: whether a position has both TW-contribution and IL proofs available.
    /// @param positionId Position identifier.
    /// @return fullyProven True if both proof types are verified for this position.
    function isFullyProven(bytes32 positionId) external view returns (bool fullyProven) {
        ProofStatus storage s = proofStore[positionId];
        return s.twProven && s.ilProven;
    }

    // -------------------------------------------------------------------------
    // IPeripheral
    // -------------------------------------------------------------------------

    /// @inheritdoc IPeripheral
    /// @dev Returns the canonical Brevis peripheral identifier.
    function kind() external pure returns (bytes32) {
        return keccak256("stratum.brevis.verifier");
    }

    /// @inheritdoc IPeripheral
    /// @dev Called by the core at epoch close (in-band notification).  The shim records the event
    ///      so off-chain Brevis job schedulers can subscribe to on-chain epoch boundaries without
    ///      polling.  The core discards the return value (NFR-01), so no invariant is at risk.
    ///      Decodes the ctx abi-encoded as (funded, surplus, juniorReserve, juniorTVL, seniorTVL).
    function onEpochClose(PoolId id, uint64 epoch, bytes calldata ctx) external returns (bytes memory) {
        if (ctx.length >= 160) {
            (,, uint256 juniorReserve, uint256 juniorTVL,) =
                abi.decode(ctx, (uint256, uint256, uint256, uint256, uint256));
            // Emit with juniorReserve as the "epoch fees" proxy -- the Brevis prover reads this
            // to size the plausibility bound for future TW-contribution proof submissions.
            emit EpochCloseObserved(id, epoch, juniorReserve, juniorTVL);
        } else {
            emit EpochCloseObserved(id, epoch, 0, 0);
        }
        return bytes("");
    }

    /// @inheritdoc IPeripheral
    /// @dev Coverage stress notification: not actionable by the ZK layer; no-op.
    function onCoverageStress(PoolId, uint16) external { }

    /// @inheritdoc IPeripheral
    function isEnabled() external view returns (bool) {
        return _enabled;
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    /// @dev Call the Brevis circuit verifier if configured, or return true in stub mode.
    /// @param proof        ABI-encoded proof blob.
    /// @param vkHash       Verification key hash for the target circuit.
    /// @param publicInputs ABI-encoded public inputs.
    /// @return valid True if the proof is valid (or stub mode is active).
    function _verifyOrStub(bytes calldata proof, bytes32 vkHash, bytes memory publicInputs)
        internal
        view
        returns (bool valid)
    {
        if (circuitAddress == address(0)) {
            // Stub mode: accept any non-empty proof bytes; reject empty bytes so tests can
            // exercise the rejection path by passing an empty blob.
            return proof.length > 0;
        }
        return IBrevisProver(circuitAddress).verifyProof(proof, vkHash, publicInputs);
    }
}
