// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IBrevisProver
/// @notice Interface for the Brevis proof verification endpoint.
/// @dev In testnet/stub mode `circuitAddress` is set to address(0) and every call returns `true`.
///      In production, `circuitAddress` is the deployed Brevis circuit verifier contract that
///      accepts an ABI-encoded proof blob and public inputs and returns a boolean validity flag.
///
///      The three proof types map to DESIGN section 11 circuits:
///        - TimeWeightedContribution: proves a position's time-weighted share of epoch surpluses.
///        - ILAttribution:            proves per-position IL over an exact holding window.
///        - AggregateReserve:         proves cross-chain junior reserve solvency without revealing
///                                    individual positions.
///
///      All three share the same on-chain call surface so the BrevisVerifierShim can delegate to
///      a single contract address (or its stub replacement) without understanding circuit internals.
interface IBrevisProver {
    /// @notice Verify a time-weighted contribution proof.
    /// @param proof  ABI-encoded Brevis proof blob (circuit-specific).
    /// @param vkHash Verification key hash identifying the circuit.
    /// @param publicInputs ABI-encoded public inputs expected by the circuit.
    /// @return valid True if the proof is valid for the supplied inputs.
    function verifyProof(bytes calldata proof, bytes32 vkHash, bytes calldata publicInputs)
        external
        view
        returns (bool valid);
}
