// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IMatchAttestation } from "./IMatchAttestation.sol";

/// @title MatchAttestation
/// @notice EigenLayer AVS attestation contract for STRATUM match and rebalance gating (FR-24).
///
/// @dev Multi-sig threshold gating (hackathon stub for BLS aggregation). Each registered AVS operator submits
///      an ECDSA signature over a DOMAIN-SEPARATED commitment of `matchHash`. Once `quorumThreshold` unique
///      current-set operators have attested, `isAttested` returns true.
///
///      Security hardening (audit round 5):
///      - EI2 (operator-set versioning): attestations are stored per `operatorSetVersion`. Registering or
///        deregistering an operator bumps the version, so a deregistered/compromised operator's prior
///        attestations no longer count. `isAttested` only reads the CURRENT version's count.
///      - EI4 (domain separation): the signed digest binds `block.chainid`, `address(this)`, and
///        `operatorSetVersion`, so a signature cannot be replayed across chains, deployments, or operator-set
///        epochs. Use `attestationDigest(matchHash)` to obtain the exact bytes32 to sign.
///      - EI3 (signature malleability): the lower-half-order `s` bound is enforced.
///      - EI8 (admin): `admin` is rotatable (`transferAdmin`) so a leaked key can be replaced; `deregisterOperator`
///        cannot drop the operator count below the quorum threshold (keeps quorum reachable).
///
///      Invariant interaction: INV-03/INV-05 untouched (no token movement; attestation is state-tracking only).
contract MatchAttestation is IMatchAttestation {
    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    /// @notice Upper bound on a valid signature `s` value (EIP-2: lower half of the curve order).
    uint256 private constant SECP256K1_HALF_ORDER = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    /// @notice Address that manages the operator set and quorum threshold (rotatable, EI8).
    address public admin;

    /// @notice Required number of unique current-set operator attestations for quorum.
    uint256 public quorumThreshold;

    /// @notice Registered operator set (must match AVS registry in production).
    mapping(address => bool) public isOperator;
    uint256 public operatorCount;

    /// @notice Monotonic version of the operator set; bumped on every register/deregister (EI2).
    uint256 public operatorSetVersion;

    /// @notice version => matchHash => operator => attested.
    mapping(uint256 => mapping(bytes32 => mapping(address => bool))) private _attestations;

    /// @notice version => matchHash => count.
    mapping(uint256 => mapping(bytes32 => uint256)) private _count;

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error NotAdmin();
    error NotRegisteredOperator();
    error AlreadyAttested(bytes32 matchHash, address operator);
    error InvalidSignature();
    error QuorumThresholdZero();
    error QuorumExceedsOperatorCount(uint256 threshold, uint256 operators);
    error OperatorAlreadyRegistered(address operator);
    error OperatorNotRegistered(address operator);
    error DeregisterBelowQuorum(uint256 remaining, uint256 threshold);
    error ZeroAddress();

    // -------------------------------------------------------------------------
    // Events (additional to IMatchAttestation)
    // -------------------------------------------------------------------------

    event OperatorRegistered(address indexed operator, uint256 newTotal, uint256 version);
    event OperatorDeregistered(address indexed operator, uint256 newTotal, uint256 version);
    event QuorumThresholdUpdated(uint256 newThreshold);
    event AdminTransferred(address indexed previousAdmin, address indexed newAdmin);

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /// @param admin_           Address that can manage the operator set and quorum threshold.
    /// @param quorumThreshold_ Initial quorum (k in k-of-N). Typically 2 for hackathon (2-of-3).
    constructor(address admin_, uint256 quorumThreshold_) {
        if (admin_ == address(0)) revert ZeroAddress();
        if (quorumThreshold_ == 0) revert QuorumThresholdZero();
        admin = admin_;
        quorumThreshold = quorumThreshold_;
        operatorSetVersion = 1;
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    // -------------------------------------------------------------------------
    // Admin management (EI8)
    // -------------------------------------------------------------------------

    /// @notice Rotate the admin (e.g. after a key compromise). Production should point this at a multisig.
    function transferAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert ZeroAddress();
        emit AdminTransferred(admin, newAdmin);
        admin = newAdmin;
    }

    // -------------------------------------------------------------------------
    // Operator set management (admin-gated; bumps version per EI2)
    // -------------------------------------------------------------------------

    /// @notice Register an AVS operator. Bumps `operatorSetVersion`, invalidating prior-version attestations.
    function registerOperator(address op) external onlyAdmin {
        if (op == address(0)) revert ZeroAddress();
        if (isOperator[op]) revert OperatorAlreadyRegistered(op);
        isOperator[op] = true;
        unchecked {
            operatorCount += 1;
            operatorSetVersion += 1;
        }
        emit OperatorRegistered(op, operatorCount, operatorSetVersion);
    }

    /// @notice Remove an operator. Reverts if it would make quorum unreachable. Bumps the version so the
    ///         removed operator's outstanding attestations no longer count (EI2).
    function deregisterOperator(address op) external onlyAdmin {
        if (!isOperator[op]) revert OperatorNotRegistered(op);
        uint256 remaining = operatorCount - 1;
        if (remaining < quorumThreshold) revert DeregisterBelowQuorum(remaining, quorumThreshold);
        isOperator[op] = false;
        operatorCount = remaining;
        unchecked {
            operatorSetVersion += 1;
        }
        emit OperatorDeregistered(op, operatorCount, operatorSetVersion);
    }

    /// @notice Update the quorum threshold. Must not exceed the current operator count.
    function setQuorumThreshold(uint256 threshold) external onlyAdmin {
        if (threshold == 0) revert QuorumThresholdZero();
        if (threshold > operatorCount) revert QuorumExceedsOperatorCount(threshold, operatorCount);
        quorumThreshold = threshold;
        emit QuorumThresholdUpdated(threshold);
    }

    // -------------------------------------------------------------------------
    // IMatchAttestation
    // -------------------------------------------------------------------------

    /// @notice The exact EIP-191 digest an operator must sign for `matchHash` under the current domain/version.
    /// @dev Domain-separated by chainId + this contract + operator-set version (EI4/EI2). Signing tooling
    ///      should call this view and sign the returned bytes32 with the operator key.
    function attestationDigest(bytes32 matchHash) public view returns (bytes32) {
        bytes32 commitment = keccak256(abi.encode(block.chainid, address(this), operatorSetVersion, matchHash));
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", commitment));
    }

    /// @inheritdoc IMatchAttestation
    /// @dev Recovers the signer from the domain-separated digest and requires it to equal the calling
    ///      operator's address, binding the signature to the operator's own key.
    function submit(bytes32 matchHash, bytes calldata sig) external override {
        if (!isOperator[msg.sender]) revert NotRegisteredOperator();

        address recovered = _recoverSigner(attestationDigest(matchHash), sig);
        if (recovered != msg.sender) revert InvalidSignature();

        uint256 version = operatorSetVersion;
        if (_attestations[version][matchHash][msg.sender]) revert AlreadyAttested(matchHash, msg.sender);
        _attestations[version][matchHash][msg.sender] = true;

        uint256 newCount;
        unchecked {
            newCount = _count[version][matchHash] + 1;
        }
        _count[version][matchHash] = newCount;

        emit AttestationSubmitted(matchHash, msg.sender, newCount);
        if (newCount == quorumThreshold) {
            emit QuorumReached(matchHash, newCount);
        }
    }

    /// @inheritdoc IMatchAttestation
    function isAttested(bytes32 matchHash) external view override returns (bool) {
        return _count[operatorSetVersion][matchHash] >= quorumThreshold;
    }

    /// @inheritdoc IMatchAttestation
    function attestationCount(bytes32 matchHash) external view override returns (uint256) {
        return _count[operatorSetVersion][matchHash];
    }

    // -------------------------------------------------------------------------
    // Internal ECDSA helpers
    // -------------------------------------------------------------------------

    /// @notice Recover the signer address from a 65-byte (r, s, v) signature, rejecting malleable `s` (EI3).
    function _recoverSigner(bytes32 digest, bytes calldata sig) internal pure returns (address) {
        if (sig.length != 65) revert InvalidSignature();

        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset, 32))
            v := byte(0, calldataload(add(sig.offset, 64)))
        }
        // EIP-2: reject the upper-half-order `s` to prevent signature malleability.
        if (uint256(s) > SECP256K1_HALF_ORDER) revert InvalidSignature();
        if (v < 27) v += 27;
        if (v != 27 && v != 28) revert InvalidSignature();

        address recovered = ecrecover(digest, v, r, s);
        if (recovered == address(0)) revert InvalidSignature();
        return recovered;
    }
}
