// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title BrevisAppZkOnly
/// @notice Canonical Brevis app base contract (vendored from brevis-network/brevis-quickstart-ts).
///         A Brevis "app contract" is the on-chain callback target: after a developer submits an
///         app-circuit proof to the Brevis backend, Brevis verifies it and calls `brevisCallback`
///         (or `brevisBatchCallback`) here with the circuit's verifying-key hash and the circuit
///         output. Only the configured BrevisRequest contract may call back.
///
/// @dev This is the REQUIRED integration shape for Brevis ZK-mode. STRATUM previously used a custom
///      verifier shim that did not follow this pattern; `StratumBrevisApp` extends this base so the
///      integration matches Brevis's actual request/callback flow.
abstract contract BrevisAppZkOnly {
    /// @notice The Brevis `BrevisRequest` contract permitted to deliver verified proof results.
    address public brevisRequest;

    modifier onlyBrevisRequest() {
        require(msg.sender == brevisRequest, "invalid caller");
        _;
    }

    constructor(address _brevisRequest) {
        brevisRequest = _brevisRequest;
    }

    /// @notice Override in the app to consume a verified circuit output.
    /// @param _vkHash          The verifying-key hash Brevis used (bind to your circuit's vkHash).
    /// @param _appCircuitOutput The ABI-packed output your circuit emitted via api.Output*.
    function handleProofResult(bytes32 _vkHash, bytes calldata _appCircuitOutput) internal virtual { }

    /// @notice Single-proof callback from Brevis.
    function brevisCallback(bytes32 _appVkHash, bytes calldata _appCircuitOutput) external onlyBrevisRequest {
        handleProofResult(_appVkHash, _appCircuitOutput);
    }

    /// @notice Batch callback from Brevis.
    function brevisBatchCallback(bytes32[] calldata _appVkHashes, bytes[] calldata _appCircuitOutputs)
        external
        onlyBrevisRequest
    {
        for (uint256 i = 0; i < _appVkHashes.length; i++) {
            handleProofResult(_appVkHashes[i], _appCircuitOutputs[i]);
        }
    }
}
