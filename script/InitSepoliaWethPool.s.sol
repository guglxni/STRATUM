// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { LPFeeLibrary } from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

import { StratumHook } from "../src/StratumHook.sol";
import { PoolInitParams } from "../src/StratumTypes.sol";
import { DemoToken } from "./tokens/DemoToken.sol";

/// @notice Open a STRATUM pool on Sepolia whose currency0/1 includes the Across destination WETH (FR-19 dest).
/// @dev Deploys a fresh DemoToken as the counter-asset, orders currencies (currency0 < currency1), calls
///      preparePool + manager.initialize, then registers the Sepolia CPHR as the pool's reserveRebalancer so
///      handleV3AcrossMessage can credit the reserve. Prints the PoolId and which leg WETH occupies.
contract InitSepoliaWethPool is Script {
    using PoolIdLibrary for PoolKey;

    // sqrt(1) in Q64.96
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address managerAddr = vm.envAddress("SEPOLIA_POOL_MANAGER");
        address hookAddr = vm.envAddress("SEPOLIA_HOOK");
        address cphr = vm.envAddress("SEPOLIA_CPHR");
        address weth = vm.envAddress("ACROSS_DEST_WETH");

        StratumHook hook = StratumHook(payable(hookAddr));
        IPoolManager manager = IPoolManager(managerAddr);

        vm.startBroadcast(pk);

        DemoToken counter = new DemoToken("Stratum Demo USD", "sdUSD");
        address counterAddr = address(counter);

        // v4 ordering: currency0 < currency1.
        (Currency c0, Currency c1, bool wethIsCurrency0) = weth < counterAddr
            ? (Currency.wrap(weth), Currency.wrap(counterAddr), true)
            : (Currency.wrap(counterAddr), Currency.wrap(weth), false);

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
            currency0: c0, currency1: c1, fee: LPFeeLibrary.DYNAMIC_FEE_FLAG, tickSpacing: 60, hooks: IHooks(hookAddr)
        });

        hook.preparePool(key, params);
        manager.initialize(key, SQRT_PRICE_1_1);

        PoolId id = key.toId();
        hook.setReserveRebalancer(id, cphr);

        vm.stopBroadcast();

        console2.log("counter token:", counterAddr);
        console2.log("WETH is currency0:", wethIsCurrency0);
        console2.log("currency0:", Currency.unwrap(c0));
        console2.log("currency1:", Currency.unwrap(c1));
        console2.logBytes32(PoolId.unwrap(id));
    }
}
