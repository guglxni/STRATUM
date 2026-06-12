// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolTrancheState } from "../../StratumTypes.sol";

/// @title IStylusMatchingEngine
/// @notice Interface for the Rust-based Stylus matching and ML volatility engine running on Arbitrum.
/// @dev The Solidity shim in StylusShim.sol calls these functions as a cross-contract call to the Stylus
///      program address. The Stylus program is responsible for: (1) scanning correlations across pool states,
///      (2) computing optimal IL-netting sets, (3) selecting rebalance paths, and (4) forecasting volatility
///      regimes several blocks ahead. All computations are gas-prohibitive in pure Solidity.
///      ARCHITECTURE: The shim submits state; the Stylus program writes a result back via `deliverMatchResult`,
///      which the shim then applies after EigenLayer attestation. This is a request-response pattern.
interface IStylusMatchingEngine {
    /// @notice A single netting recommendation: match `poolA`'s junior long exposure against `poolB`'s junior
    ///         short exposure. The `netValue` is the token0-denominated value that can be netted.
    struct NettingPair {
        PoolId poolA;
        PoolId poolB;
        uint256 netValue;
        uint16 correlationWeightBps;
    }

    /// @notice A rebalance recommendation: move `amount` (token0-denominated) from `sourcePool` to
    ///         `targetPool` to equalise junior reserve levels. May be same-chain or cross-chain.
    struct RebalanceRecommendation {
        PoolId sourcePool;
        PoolId targetPool;
        uint256 amount;
        bool crossChain;
        uint256 targetChainId;
    }

    /// @notice The full result bundle returned by a matching run.
    struct MatchResult {
        NettingPair[] nettingPairs;
        RebalanceRecommendation[] rebalances;
        /// @notice ML-predicted volatility EWMA for each submitted pool (parallel to input pools array).
        uint256[] predictedVolatilityEWMA;
        /// @notice Unix timestamp after which this result is considered stale and must not be applied.
        uint32 validUntil;
    }

    /// @notice Submit a snapshot of pool states to the matching engine for processing.
    /// @dev Called by the StylusShim peripheral on every epoch close (or when Reactive signals a meaningful
    ///      pool-state change). The Stylus program processes inputs asynchronously and calls back via
    ///      `deliverMatchResult` on the shim.
    /// @param pools    Array of pool IDs whose state is being submitted.
    /// @param states   Parallel array of pool tranche states; must have the same length as `pools`.
    /// @param nonce    Monotone nonce assigned by the shim; the Stylus program echoes it in the callback to
    ///                 prevent replay. Incremented for every new submission.
    function submitPoolState(PoolId[] calldata pools, PoolTrancheState[] calldata states, uint64 nonce) external;

    /// @notice Deliver a computed match result back to a registered result receiver (the StylusShim).
    /// @dev Called by the Stylus program (or its Reactive relay) after computing a match result. The shim
    ///      records the result pending EigenLayer attestation before it is applied.
    /// @param nonce         The nonce from the corresponding `submitPoolState` call.
    /// @param encodedResult ABI-encoded `MatchResult`.
    function deliverMatchResult(uint64 nonce, bytes calldata encodedResult) external;

    /// @notice Emitted by the Stylus program when a new submission is accepted for processing.
    event MatchSubmitted(uint64 indexed nonce, uint256 poolCount);

    /// @notice Emitted when the Stylus program delivers a result.
    event MatchResultDelivered(uint64 indexed nonce, uint256 nettingPairCount, uint256 rebalanceCount);
}
