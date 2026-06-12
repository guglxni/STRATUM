// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { BrevisAppZkOnly } from "./BrevisAppZkOnly.sol";

/// @title StratumBrevisApp
/// @notice Correct Brevis ZK-mode app contract for STRATUM (FR-21). It is the on-chain callback target
///         Brevis invokes after verifying the STRATUM app-circuit proof. It decodes the circuit output
///         (block number, poolId, proven amount) and records it as a ZK-attested value the system can read.
///
/// @dev CHAIN COMPATIBILITY (mainnet-only):
///      The live Brevis hosted proving service (appsdkv3.brevis.network) only serves the route
///      Ethereum Mainnet (source chain, chainid 1) -> Arbitrum One (destination, chainid 42161).
///      The verified production `BrevisRequest` contract that drives `brevisCallback` lives on Arbitrum One.
///      It is NOT compatible with testnet deployments (Unichain/Ethereum/Base/Arbitrum Sepolia): the hosted
///      gateway rejects non-mainnet source chains, so no real proof will ever be delivered to this callback
///      on a testnet. On testnet the core uses the FR-22 approximate on-chain accounting fallback and the
///      Brevis peripheral is left deployed-but-disabled (see BrevisVerifierShim stub mode). When STRATUM
///      deploys to Arbitrum One mainnet this contract wires up to the real BrevisRequest with no code change.
///
/// @dev This replaces the architecturally-incorrect `BrevisVerifierShim.verifyProof` path. The flow is:
///        1. Off-chain: build the STRATUM app circuit (brevis-circuits/), generate a proof, submit it to
///           the Brevis backend with this contract as the callback target.
///        2. Brevis verifies the proof and calls `brevisCallback(vkHash, output)` here (gated to BrevisRequest).
///        3. We require the vkHash equals our registered circuit vkHash, decode the output, and store it.
///
///      Circuit output layout (from the receipt circuit's api.Output* calls):
///        bytes[0:8]   uint64  blockNum   (api.OutputUint(64, ...))
///        bytes[8:40]  bytes32 poolId     (api.OutputBytes32(...))
///        bytes[40:72] bytes32 amount     (api.OutputBytes32(...))  // e.g. ReserveFunded amount1
contract StratumBrevisApp is BrevisAppZkOnly {
    /// @notice Owner permitted to register the circuit vkHash.
    address public immutable owner;

    /// @notice The verifying-key hash of the STRATUM app circuit. Set after compiling the circuit.
    bytes32 public vkHash;

    /// @notice Proven value per pool (ZK-attested), keyed by poolId. For the ReserveFunded circuit this
    ///         is the cross-chain reserve credited; the same pattern serves IL / contribution circuits.
    mapping(bytes32 => uint256) public provenAmount;
    /// @notice Block number the proven value was attested at, per pool.
    mapping(bytes32 => uint64) public provenAtBlock;
    /// @notice Whether a pool has any ZK-attested value yet.
    mapping(bytes32 => bool) public hasProof;

    error OnlyOwner();
    error InvalidVk(bytes32 got, bytes32 expected);
    error MalformedOutput(uint256 length);

    event VkHashSet(bytes32 vkHash);
    event StratumValueAttested(bytes32 indexed poolId, uint64 blockNum, uint256 amount);

    constructor(address brevisRequest_, address owner_) BrevisAppZkOnly(brevisRequest_) {
        owner = owner_;
    }

    /// @notice Register the compiled circuit's vkHash (printed by the Go circuit at compile time).
    function setVkHash(bytes32 vkHash_) external {
        if (msg.sender != owner) revert OnlyOwner();
        vkHash = vkHash_;
        emit VkHashSet(vkHash_);
    }

    /// @inheritdoc BrevisAppZkOnly
    /// @dev Authenticity: `_vkHash` proves Brevis verified a proof from OUR circuit (not an arbitrary one),
    ///      so the decoded output is trustworthy. Gated upstream to the BrevisRequest contract.
    function handleProofResult(bytes32 _vkHash, bytes calldata o) internal override {
        if (_vkHash != vkHash) revert InvalidVk(_vkHash, vkHash);
        if (o.length < 72) revert MalformedOutput(o.length);

        uint64 blockNum = uint64(bytes8(o[0:8]));
        bytes32 poolId = bytes32(o[8:40]);
        uint256 amount = uint256(bytes32(o[40:72]));

        provenAmount[poolId] = amount;
        provenAtBlock[poolId] = blockNum;
        hasProof[poolId] = true;
        emit StratumValueAttested(poolId, blockNum, amount);
    }
}
