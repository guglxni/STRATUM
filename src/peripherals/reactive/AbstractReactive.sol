// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IReactive } from "./IReactive.sol";
import { ISystemContract } from "./ISystemContract.sol";

/// @title AbstractReactive
/// @notice Base for STRATUM Reactive Smart Contracts (canonical reactive-lib pattern).
/// @dev Since the Reactive Network Omni fork (2026-05-25) a reactive contract is ONE contract deployed to ONE
///      environment: the Reactive Network chain (Lasna, chain id 5318007). The ReactVM and the split
///      "system-chain + per-deployer ReactVM" deployment model have been removed.
///
///      The contract still works exactly as before at the functional level:
///        (a) The constructor registers subscriptions via the system contract (0x...fffFfF).
///        (b) Matching origin-chain logs are delivered through `react`, which emits `Callback` events to
///            schedule destination-chain execution. Subscriptions and callbacks are unchanged.
///
///      The contract distinguishes reactive mode from a plain EVM by whether the system contract has code
///      (`reactiveMode` flag): on a plain EVM / in tests there is no system contract, so subscriptions are
///      skipped and the contract still works through its operator fallback (NFR-01: the core never depends on
///      Reactive being live).
///
///      CometBFT instant finality on the Reactive chain means the reorg-driven duplicate-callback class is
///      gone; guards like `EpochNotElapsed` on the destination are now belt-and-suspenders, not load-bearing.
abstract contract AbstractReactive is IReactive {
    /// @notice Well-known Reactive Network system contract address.
    address internal constant SYSTEM_CONTRACT_ADDR = 0x0000000000000000000000000000000000fffFfF;

    /// @notice Sentinel topic value meaning "match any" for a subscription slot.
    uint256 internal constant REACTIVE_IGNORE = 0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;

    ISystemContract internal immutable systemContract;

    /// @notice True when deployed on the Reactive Network chain (the system contract has code at the
    ///         well-known address); false on a plain EVM (tests, the origin chain), where subscriptions are
    ///         skipped. On the Omni fork this is a single deployment environment - there is no separate
    ///         ReactVM or system-chain distinction.
    bool internal immutable reactiveMode;

    /// @notice Destination chain id the scheduled callback executes on. Zero until a destination is configured,
    ///         in which case routing falls back to the origin chain / `address(this)` (same-chain operator path).
    uint256 public destinationChainId;

    /// @notice Address of this RSC's twin on the destination chain (the contract that runs `reactiveCallback`
    ///         and reads the hook). Zero = not configured; `react` then targets `address(this)` on the origin
    ///         chain so existing same-chain tests and operator-driven flows keep working unchanged.
    address public destinationCallback;

    /// @notice Emitted to schedule a destination-chain call. The Reactive Network relays and executes
    ///         `payload` against `_contract` on `chainId`, funded by the RSC's gas budget. This is the
    ///         no-keeper execution primitive (the basis of the Reactive prize submission).
    event Callback(uint256 indexed chainId, address indexed _contract, uint64 indexed gasLimit, bytes payload);

    /// @notice Emitted when the operator wires (or rewires) the destination route for scheduled callbacks.
    event ReactiveDestinationSet(uint256 destinationChainId, address destinationCallback);

    constructor() {
        systemContract = ISystemContract(SYSTEM_CONTRACT_ADDR);
        reactiveMode = SYSTEM_CONTRACT_ADDR.code.length > 0;
    }

    /// @dev Resolve where a scheduled callback executes. When a destination twin is configured the callback
    ///      routes to that twin on `destinationChainId`; otherwise it falls back to `address(this)` on the
    ///      supplied origin chain, preserving the same-chain operator path and every existing test.
    function _callbackRoute(uint256 originChainId) internal view returns (uint256 chainId, address _contract) {
        if (destinationCallback != address(0)) {
            return (destinationChainId, destinationCallback);
        }
        return (originChainId, address(this));
    }

    /// @dev Register a subscription if running on the Reactive system chain; no-op on a plain EVM (NFR-01).
    function _subscribe(uint256 chainId, address _contract, uint256 topic_0) internal {
        if (!reactiveMode) return;
        systemContract.subscribe(chainId, _contract, topic_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    /// @dev Schedule a destination-chain call via the Reactive callback mechanism.
    function _emitCallback(uint256 chainId, address _contract, uint64 gasLimit, bytes memory payload) internal {
        emit Callback(chainId, _contract, gasLimit, payload);
    }
}
