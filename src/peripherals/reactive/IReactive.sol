// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IReactive
/// @notice The Reactive Network reactive-contract interface (canonical reactive-lib shape).
/// @dev A Reactive Smart Contract (RSC) subscribes to origin-chain log events via the system contract, then
///      receives each matching log through `react`. The RSC runs on the Reactive Network chain (ONE contract,
///      ONE environment - the ReactVM and per-deployer split no longer exist after the Omni fork, 2026-05-25).
///      To act on a destination chain the RSC emits a `Callback` event that the Reactive Network relays and
///      executes there. Subscriptions and callbacks are backward compatible: existing RSCs keep working
///      without changes. STRATUM uses this so epoch settlement, coverage response, and reserve rebalancing
///      are driven with no off-chain keeper (FR-15/16/17, ARCHITECTURE section 5).
interface IReactive {
    /// @notice A single origin-chain log delivered to the RSC.
    /// @dev Mirrors the reactive-lib `LogRecord`. `topic_0` is the event signature hash; `topic_1..3` are the
    ///      indexed parameters; `data` is the ABI-encoded non-indexed payload.
    struct LogRecord {
        uint256 chainId;
        address _contract;
        uint256 topic_0;
        uint256 topic_1;
        uint256 topic_2;
        uint256 topic_3;
        bytes data;
        uint256 blockNumber;
        uint256 opCode;
        uint256 blockHash;
        uint256 txHash;
        uint256 logIndex;
    }

    /// @notice Invoked by the Reactive Network (system contract) for each subscribed log.
    /// @param log The origin-chain log that matched a subscription.
    function react(LogRecord calldata log) external;
}
