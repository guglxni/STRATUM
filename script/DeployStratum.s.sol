// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {EnvConfig} from "./EnvConfig.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";

import {StratumHook} from "../src/StratumHook.sol";
import {EpochSettler} from "../src/peripherals/reactive/EpochSettler.sol";
import {CoverageMonitor} from "../src/peripherals/reactive/CoverageMonitor.sol";
import {HookMiner} from "../test/utils/HookMiner.sol";
import {StratumFlags} from "../test/utils/StratumFlags.sol";

/// @title DeployStratum
/// @notice Deploy STRATUM core + Reactive stubs to Unichain Sepolia (testnet only).
/// @dev Broadcast: forge script script/DeployStratum.s.sol --rpc-url $UNICHAIN_SEPOLIA_RPC --broadcast --slow
///      Verify (rate-limited): ./script/verify.sh after setting addresses in .env
contract DeployStratum is EnvConfig {
    /// @dev Foundry broadcast uses the canonical CREATE2 deployer for `new Contract{salt:}`.
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        uint256 deployerKey = privateKeyFromEnv();
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        IPoolManager manager = IPoolManager(address(new PoolManager(deployer)));

        (address hookAddr, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            StratumFlags.STRATUM_HOOK_FLAGS,
            type(StratumHook).creationCode,
            abi.encode(address(manager))
        );

        StratumHook hook = new StratumHook{salt: salt}(manager);
        require(address(hook) == hookAddr, "hook address mismatch");

        EpochSettler settler = new EpochSettler(hook, deployer);
        CoverageMonitor monitor = new CoverageMonitor(hook, deployer);

        console2.log("Deployer", deployer);
        console2.log("PoolManager", address(manager));
        console2.log("StratumHook", address(hook));
        console2.log("EpochSettler", address(settler));
        console2.log("CoverageMonitor", address(monitor));
        console2.log("hookSalt", vm.toString(salt));
        console2.log("chainId", block.chainid);

        vm.stopBroadcast();
    }
}
