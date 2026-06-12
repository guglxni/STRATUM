// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IStratumSpokePool
/// @notice Minimal Across V3 SpokePool interface used by the CrossPoolHedgingRouter (FR-19).
/// @dev Only the functions called by CPHR are declared. The full SpokePool ABI is not imported so
///      the core can compile and test with a zero SpokePool address (NFR-01, golden rule 1).
interface IStratumSpokePool {
    /// @notice Deposit tokens into Across V3 to bridge to a destination chain.
    /// @dev The caller must have approved `inputToken` to the SpokePool before calling.
    ///      `fillDeadline` must be greater than the current block timestamp.
    ///      `quoteTimestamp` must be within the SpokePool's `depositQuoteTimeBuffer` window.
    /// @param depositor           Address credited as the depositor on the origin chain.
    /// @param recipient           Address that receives `outputAmount` of `outputToken` on `destinationChainId`.
    /// @param inputToken          ERC-20 token deposited on the origin chain.
    /// @param outputToken         ERC-20 token delivered on the destination chain (may differ).
    /// @param inputAmount         Token units deposited on the origin chain.
    /// @param outputAmount        Token units delivered on the destination chain (inputAmount - relayer fee).
    /// @param destinationChainId  Chain ID of the target network.
    /// @param exclusiveRelayer    Address of the exclusive relayer; address(0) for none.
    /// @param quoteTimestamp      Timestamp at which the relayer fee was quoted.
    /// @param fillDeadline        Unix timestamp after which the fill is invalid on the destination.
    /// @param exclusivityDeadline Unix timestamp after which exclusivity lapses and any relayer may fill.
    /// @param message             Arbitrary data forwarded to `recipient` if it is a contract.
    function depositV3(
        address depositor,
        address recipient,
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 destinationChainId,
        address exclusiveRelayer,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 exclusivityDeadline,
        bytes calldata message
    ) external payable;

    /// @notice Speed up a pending V3 deposit by offering a higher relayer fee.
    /// @dev Can only be called by the original depositor or a permissioned updater.
    /// @param depositor       Original depositor address.
    /// @param depositId       Identifier of the pending deposit returned by the SpokePool on creation.
    /// @param updatedOutputAmount New output amount with a higher implicit fee.
    /// @param updatedRecipient    New recipient address (unchanged if same as original).
    /// @param updatedMessage      Updated calldata forwarded to the recipient.
    /// @param depositorSignature  EIP-712 signature authorising the update.
    function speedUpV3Deposit(
        address depositor,
        uint32 depositId,
        uint256 updatedOutputAmount,
        address updatedRecipient,
        bytes calldata updatedMessage,
        bytes calldata depositorSignature
    ) external;
}
