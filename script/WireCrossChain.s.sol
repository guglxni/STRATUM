// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";

import { CrossPoolHedgingRouter } from "../src/peripherals/across/CrossPoolHedgingRouter.sol";
import { StratumHook } from "../src/StratumHook.sol";
import { EnvConfig } from "./EnvConfig.sol";

/// @title WireCrossChain
/// @notice Wires the live FR-19 cross-chain reserve loop across two STRATUM deployments. The origin CPHR
///         deposits into the real Across SpokePool (bound at deploy time); the destination CPHR receives the
///         fill via handleV3AcrossMessage and credits the destination pool. This script performs the two
///         remaining links: registering the peer CPHR on the origin, and authorising the destination CPHR to
///         credit the destination pool's reserve.
///
/// @dev Run on the ORIGIN chain to register the destination peer:
///        CPHR_ADDRESS=<origin cphr> DEST_CHAIN_ID=<id> DEST_CPHR_ADDRESS=<dest cphr> \
///          forge script script/WireCrossChain.s.sol --sig "setDestination()" --rpc-url $ORIGIN_RPC --broadcast
///
///      Run on the DESTINATION chain to authorise reserve credits (pool creator only):
///        STRATUM_HOOK_ADDRESS=<dest hook> TARGET_POOL_ID=<bytes32> CPHR_ADDRESS=<dest cphr> \
///          forge script script/WireCrossChain.s.sol --sig "registerRebalancer()" --rpc-url $DEST_RPC --broadcast
contract WireCrossChain is EnvConfig {
    /// @notice Origin side: tell this chain's CPHR which CPHR receives bridged funds on the destination chain.
    function setDestination() external {
        uint256 pk = privateKeyFromEnv();
        CrossPoolHedgingRouter cphr = CrossPoolHedgingRouter(vm.envAddress("CPHR_ADDRESS"));
        uint256 destChainId = vm.envUint("DEST_CHAIN_ID");
        address destCphr = vm.envAddress("DEST_CPHR_ADDRESS");

        vm.startBroadcast(pk);
        cphr.setDestinationCPHR(destChainId, destCphr);
        vm.stopBroadcast();

        console2.log("Origin CPHR", address(cphr), "-> dest chain", destChainId);
        console2.log("  destination CPHR registered:", destCphr);
    }

    /// @notice Destination side: authorise the local CPHR to credit a pool's reserve from bridged fills.
    /// @dev Creator-gated and one-time on the hook. Without it, handleV3AcrossMessage's creditReserve reverts.
    function registerRebalancer() external {
        uint256 pk = privateKeyFromEnv();
        StratumHook hook = StratumHook(payable(vm.envAddress("STRATUM_HOOK_ADDRESS")));
        PoolId targetPool = PoolId.wrap(vm.envBytes32("TARGET_POOL_ID"));
        address cphr = vm.envAddress("CPHR_ADDRESS");

        vm.startBroadcast(pk);
        hook.setReserveRebalancer(targetPool, cphr);
        vm.stopBroadcast();

        console2.log("Destination hook", address(hook));
        console2.log("  reserveRebalancer set to CPHR:", cphr);
    }
}
