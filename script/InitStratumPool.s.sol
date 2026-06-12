// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { LPFeeLibrary } from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { Constants } from "@uniswap/v4-core/test/utils/Constants.sol";

import { StratumHook } from "../src/StratumHook.sol";
import { PoolInitParams } from "../src/StratumTypes.sol";
import { EnvConfig } from "./EnvConfig.sol";

/// @notice Initialize a STRATUM pool on an existing deployment (C1 pool setup).
/// @dev Set POOL_MANAGER_ADDRESS and STRATUM_HOOK_ADDRESS in .env. Mints test currencies via hook's manager routers separately.
contract InitStratumPool is EnvConfig {
    using LPFeeLibrary for uint24;

    function run() external {
        address managerAddr = vm.envAddress("POOL_MANAGER_ADDRESS");
        address hookAddr = vm.envAddress("STRATUM_HOOK_ADDRESS");
        StratumHook hook = StratumHook(payable(hookAddr));
        IPoolManager manager = IPoolManager(managerAddr);

        PoolInitParams memory params = PoolInitParams({
            targetAPYBps: 500,
            minCoverageRatioBps: 3000,
            maxSeniorILExposureBps: 500,
            smoothingEpochSeconds: 1 days,
            baseFeeBps: 30,
            minFeeBps: 5,
            maxFeeBps: 200,
            protocolFeeBps: 100,
            peripheralRegistry: address(0),
            coverageTriggerBps: 3000,
            coverageTargetBps: 3000
        });

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(vm.envAddress("CURRENCY0")),
            currency1: Currency.wrap(vm.envAddress("CURRENCY1")),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(hookAddr)
        });

        vm.startBroadcast(privateKeyFromEnv());
        hook.preparePool(key, params);
        manager.initialize(key, Constants.SQRT_PRICE_1_1);
        vm.stopBroadcast();

        console2.log("Pool initialized with STRATUM hook", hookAddr);
    }
}
