// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IMatchAttestation
/// @notice Interface for the EigenLayer AVS attestation contract that gates cross-chain match and reserve
///         rebalance execution (FR-24, ARCHITECTURE section 9).
/// @dev Operators in the STRATUM AVS attest that a given cross-chain match or reserve rebalance is legitimate
///      before the CPHR or StylusShim applies it. This prevents griefing of the ReserveBalancer by malicious
///      actors submitting fabricated match results. For the hackathon, BLS multi-sig is stubbed as a k-of-N
///      ECDSA threshold; the full BLS aggregation path is noted in dev-note comments.
interface IMatchAttestation {
    /// @notice An individual operator attestation record.
    struct Attestation {
        address operator;
        bytes32 matchHash;
        bytes signature;
        uint256 timestamp;
    }

    /// @notice Submit an attestation for a match hash.
    /// @dev The operator must be registered in the AVS operator set. `sig` is an ECDSA signature over
    ///      `keccak256(abi.encodePacked("STRATUM:attest:", matchHash))` by the operator's registered key.
    ///      In a production BLS deployment this would be a G1 point; for the hackathon, ECDSA is used.
    /// @param matchHash  The hash of the encoded match result (computed by the StylusShim or CPHR).
    /// @param sig        Operator signature over the match hash commitment.
    function submit(bytes32 matchHash, bytes calldata sig) external;

    /// @notice Returns true once the required quorum of operator attestations exists for `matchHash`.
    /// @param matchHash The match hash to query.
    /// @return attested Whether the quorum threshold has been met.
    function isAttested(bytes32 matchHash) external view returns (bool attested);

    /// @notice Number of attestations received so far for `matchHash`.
    /// @param matchHash The match hash to query.
    /// @return count Attestation count.
    function attestationCount(bytes32 matchHash) external view returns (uint256 count);

    /// @notice Emitted when an operator submits an attestation.
    event AttestationSubmitted(bytes32 indexed matchHash, address indexed operator, uint256 count);

    /// @notice Emitted when a match hash reaches quorum.
    event QuorumReached(bytes32 indexed matchHash, uint256 operatorCount);
}
