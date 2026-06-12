// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title ISystemContract
/// @notice Reactive Network system contract: RSCs register event subscriptions through it.
/// @dev Lives at the well-known address `0x0000000000000000000000000000000000fffFfF` on the Reactive Network.
///      `REACTIVE_IGNORE` (a sentinel) in a topic slot means "match any value" for that slot.
interface ISystemContract {
    /// @notice Subscribe to logs matching (chainId, contract, topic_0..3). Sentinel topics match any value.
    function subscribe(
        uint256 chainId,
        address _contract,
        uint256 topic_0,
        uint256 topic_1,
        uint256 topic_2,
        uint256 topic_3
    ) external;

    /// @notice Remove a previously registered subscription.
    function unsubscribe(
        uint256 chainId,
        address _contract,
        uint256 topic_0,
        uint256 topic_1,
        uint256 topic_2,
        uint256 topic_3
    ) external;
}
