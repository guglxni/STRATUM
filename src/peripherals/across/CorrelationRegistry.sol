// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title CorrelationRegistry
/// @notice Directed weighted graph of correlated STRATUM pools (FR-20, DESIGN section 10).
/// @dev Maps ordered pool-pair hashes to correlation weights in basis points (0..10000). Supports:
///      - O(1) weight lookup via `mapping(bytes32 => uint16) _weight`.
///      - O(k) enumeration of a pool's out-neighbours via per-pool arrays.
///      The key for a pair is `keccak256(abi.encode(from, to))` (ordered: direction matters because
///      correlations may be asymmetric in a future extension). The owner-gated write surface prevents
///      griefing by external callers and keeps responsibility with the pool creator / governance.
///
///      Weight arithmetic uses basis-point fractions (bps / 10000). No FullMath is required here
///      because weights are uint16 (max 10000 < 2^14) and are only multiplied by reserve values
///      inside the CPHR, which applies FullMath at that call site.
contract CorrelationRegistry {
    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    /// @dev Maximum correlation weight (100 % == full correlation).
    uint16 public constant MAX_WEIGHT_BPS = 10_000;

    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------

    /// @notice Address authorised to add/remove pairs and transfer ownership.
    address public owner;

    /// @notice Pending owner for two-step ownership transfer.
    address public pendingOwner;

    /// @dev O(1) weight lookup. Key: keccak256(abi.encode(fromId, toId)).
    mapping(bytes32 => uint16) private _weight;

    /// @dev Out-neighbour list per pool. Maintained in parallel with `_weight`.
    mapping(bytes32 => PoolId[]) private _neighbours;

    /// @dev Index of `toId` inside `_neighbours[fromKey]`. 1-indexed (0 = absent) so absence is
    ///      distinguishable from index 0 without a separate boolean.
    mapping(bytes32 => mapping(bytes32 => uint256)) private _neighbourIndex;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted when a pair correlation weight is set (add or update).
    event PairSet(PoolId indexed fromId, PoolId indexed toId, uint16 weightBps);

    /// @notice Emitted when a pair is removed.
    event PairRemoved(PoolId indexed fromId, PoolId indexed toId);

    /// @notice Emitted when ownership transfer is initiated.
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);

    /// @notice Emitted when ownership transfer is completed.
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @notice Caller is not the current owner.
    error OnlyOwner();

    /// @notice Caller is not the pending owner.
    error OnlyPendingOwner();

    /// @notice The supplied weight exceeds MAX_WEIGHT_BPS.
    error WeightExceedsMax(uint16 weight, uint16 maxBps);

    /// @notice A pool cannot be correlated with itself.
    error SelfCorrelation();

    /// @notice Pair not registered; nothing to remove.
    error PairNotFound();

    /// @notice Constructor was given the zero address as owner (CP8).
    error ZeroOwner();

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor(address owner_) {
        if (owner_ == address(0)) revert ZeroOwner(); // CP8
        owner = owner_;
        emit OwnershipTransferred(address(0), owner_);
    }

    // -------------------------------------------------------------------------
    // Ownership
    // -------------------------------------------------------------------------

    /// @notice Initiate a two-step ownership transfer to `newOwner`.
    /// @param newOwner Address of the proposed new owner.
    function transferOwnership(address newOwner) external onlyOwner {
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    /// @notice Complete the pending ownership transfer (must be called by `pendingOwner`).
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert OnlyPendingOwner();
        emit OwnershipTransferred(owner, pendingOwner);
        owner = pendingOwner;
        pendingOwner = address(0);
    }

    // -------------------------------------------------------------------------
    // Write surface (owner-gated)
    // -------------------------------------------------------------------------

    /// @notice Add or update the directed correlation weight from `fromId` to `toId`.
    /// @dev An update replaces the existing weight without touching the adjacency list.
    ///      Adding a new pair appends `toId` to `_neighbours[fromKey]` and writes the
    ///      1-indexed position into `_neighbourIndex` for O(1) swap-delete later.
    /// @param fromId    Source pool identifier.
    /// @param toId      Target pool identifier.
    /// @param weightBps Correlation weight in basis points (0 < w <= 10000).
    function addPair(PoolId fromId, PoolId toId, uint16 weightBps) external onlyOwner {
        if (PoolId.unwrap(fromId) == PoolId.unwrap(toId)) revert SelfCorrelation();
        if (weightBps > MAX_WEIGHT_BPS) revert WeightExceedsMax(weightBps, MAX_WEIGHT_BPS);

        bytes32 pairKey = _pairKey(fromId, toId);
        bytes32 fromKey = PoolId.unwrap(fromId);

        if (_weight[pairKey] == 0) {
            // New pair: append to adjacency list and record 1-indexed position.
            _neighbours[fromKey].push(toId);
            _neighbourIndex[fromKey][PoolId.unwrap(toId)] = _neighbours[fromKey].length; // 1-indexed
        }
        _weight[pairKey] = weightBps;
        emit PairSet(fromId, toId, weightBps);
    }

    /// @notice Remove the directed edge from `fromId` to `toId`.
    /// @dev Uses swap-and-pop on the adjacency list to keep removal O(1) with respect to the
    ///      list length (no shifting). Updates the swapped element's index record accordingly.
    /// @param fromId Source pool identifier.
    /// @param toId   Target pool identifier.
    function removePair(PoolId fromId, PoolId toId) external onlyOwner {
        bytes32 pairKey = _pairKey(fromId, toId);
        if (_weight[pairKey] == 0) revert PairNotFound();

        bytes32 fromKey = PoolId.unwrap(fromId);
        bytes32 toKey = PoolId.unwrap(toId);

        // Swap-and-pop: replace the removed element with the last one.
        uint256 idx = _neighbourIndex[fromKey][toKey]; // 1-indexed
        uint256 lastIdx = _neighbours[fromKey].length; // also 1-indexed position of last

        if (idx != lastIdx) {
            // Move last element to position of the removed element.
            PoolId last = _neighbours[fromKey][lastIdx - 1];
            _neighbours[fromKey][idx - 1] = last;
            _neighbourIndex[fromKey][PoolId.unwrap(last)] = idx;
        }
        _neighbours[fromKey].pop();
        delete _neighbourIndex[fromKey][toKey];
        delete _weight[pairKey];

        emit PairRemoved(fromId, toId);
    }

    // -------------------------------------------------------------------------
    // Read surface
    // -------------------------------------------------------------------------

    /// @notice Correlation weight from `fromId` to `toId` in basis points.
    /// @dev Returns 0 if the pair is not registered (uncorrelated).
    /// @param fromId Source pool identifier.
    /// @param toId   Target pool identifier.
    /// @return weightBps Correlation weight (0..10000).
    function getWeight(PoolId fromId, PoolId toId) external view returns (uint16 weightBps) {
        return _weight[_pairKey(fromId, toId)];
    }

    /// @notice Enumerate all out-neighbours of `fromId` with their correlation weights.
    /// @dev O(k) where k is the out-degree of `fromId`. Callers should not assume any ordering.
    /// @param fromId Source pool identifier.
    /// @return ids     Array of neighbour pool identifiers.
    /// @return weights Parallel array of correlation weights in bps.
    function getCorrelatedPools(PoolId fromId) external view returns (PoolId[] memory ids, uint16[] memory weights) {
        bytes32 fromKey = PoolId.unwrap(fromId);
        PoolId[] storage neighbours = _neighbours[fromKey];
        uint256 len = neighbours.length;
        ids = new PoolId[](len);
        weights = new uint16[](len);
        for (uint256 i = 0; i < len; ++i) {
            ids[i] = neighbours[i];
            weights[i] = _weight[_pairKey(fromId, neighbours[i])];
        }
    }

    /// @notice Number of out-neighbours registered for `fromId`.
    /// @param fromId Source pool identifier.
    /// @return count Out-degree.
    function neighbourCount(PoolId fromId) external view returns (uint256 count) {
        return _neighbours[PoolId.unwrap(fromId)].length;
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    /// @dev Directed pair key: order matters (A->B != B->A).
    function _pairKey(PoolId fromId, PoolId toId) internal pure returns (bytes32) {
        return keccak256(abi.encode(fromId, toId));
    }
}
