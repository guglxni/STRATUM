// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { LPFeeLibrary } from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import { PoolModifyLiquidityTest } from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import { PoolSwapTest } from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import { StratumHook } from "../src/StratumHook.sol";
import { PoolInitParams, TrancheType, PoolTrancheState } from "../src/StratumTypes.sol";
import { EnvConfig } from "./EnvConfig.sol";
import { DemoToken } from "./tokens/DemoToken.sol";

/// @title DemoLifecycle
/// @notice Drives a complete, real on-chain STRATUM lifecycle against a live deployment, end to end:
///         deploy two test assets, open a tranche pool, fund the junior buffer, add protected senior
///         liquidity, run a swap that accrues fees and induces impermanent loss, then close the epoch and
///         report the resulting tranche state. Nothing here is simulated: every step is a real PoolManager
///         interaction through the canonical unlock/settle pattern, exercising the hook's waterfall, IL and
///         coverage logic exactly as a production pool would.
///
/// @dev Two entrypoints so the epoch boundary can elapse between them on a live chain:
///        forge script script/DemoLifecycle.s.sol --sig "run()"    --rpc-url $RPC --broadcast
///        (wait DEMO_EPOCH_SECONDS, default 60s)
///        forge script script/DemoLifecycle.s.sol --sig "settle()" --rpc-url $RPC --broadcast
///
///      Required env: POOL_MANAGER_ADDRESS, STRATUM_HOOK_ADDRESS, PRIVATE_KEY.
///      `run()` writes the two demo token addresses to the console; export them as CURRENCY0/CURRENCY1
///      before calling `settle()`.
contract DemoLifecycle is EnvConfig {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;

    uint160 internal constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;
    uint160 internal constant SQRT_PRICE_1_2 = 56_022_770_974_786_139_918_731_938_227;
    int24 internal constant TICK_LOWER = -600;
    int24 internal constant TICK_UPPER = 600;
    int24 internal constant TICK_SPACING = 60;

    /// @notice Deploy assets, open the pool, seed both tranches, and run a fee/IL-accruing swap.
    function run() external {
        uint256 pk = privateKeyFromEnv();
        address deployer = vm.addr(pk);
        StratumHook hook = StratumHook(payable(vm.envAddress("STRATUM_HOOK_ADDRESS")));
        IPoolManager manager = IPoolManager(vm.envAddress("POOL_MANAGER_ADDRESS"));
        uint32 epochSeconds = uint32(vm.envOr("DEMO_EPOCH_SECONDS", uint256(60)));

        vm.startBroadcast(pk);

        // 1. Real test assets for the pool (faucet ERC-20s; the hook math is asset-agnostic).
        DemoToken tA = new DemoToken("STRATUM Demo Token A", "sdA");
        DemoToken tB = new DemoToken("STRATUM Demo Token B", "sdB");
        // v4 requires currency0 < currency1 by address.
        (DemoToken t0, DemoToken t1) = address(tA) < address(tB) ? (tA, tB) : (tB, tA);
        t0.faucet(deployer, 10_000_000 ether);
        t1.faucet(deployer, 10_000_000 ether);

        // 2. Canonical-pattern routers that perform the PoolManager unlock/settle for liquidity and swaps.
        PoolModifyLiquidityTest lpRouter = new PoolModifyLiquidityTest(manager);
        PoolSwapTest swapRouter = new PoolSwapTest(manager);
        t0.approve(address(lpRouter), type(uint256).max);
        t1.approve(address(lpRouter), type(uint256).max);
        t0.approve(address(swapRouter), type(uint256).max);
        t1.approve(address(swapRouter), type(uint256).max);

        // 3. Open a STRATUM tranche pool with a short demo epoch so the boundary elapses within the session.
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(t0)),
            currency1: Currency.wrap(address(t1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        PoolInitParams memory params = PoolInitParams({
            targetAPYBps: 500, // 5% senior target
            minCoverageRatioBps: 3000, // junior buffer >= 30% of senior
            maxSeniorILExposureBps: 500,
            smoothingEpochSeconds: epochSeconds,
            baseFeeBps: 30,
            minFeeBps: 5,
            maxFeeBps: 200,
            protocolFeeBps: 100,
            peripheralRegistry: address(0), // core demo; Reactive/Brevis wired separately (NFR-01)
            coverageTriggerBps: 3000,
            coverageTargetBps: 3000
        });
        hook.preparePool(key, params);
        manager.initialize(key, SQRT_PRICE_1_1);

        // 4. Junior buffer FIRST (it absorbs IL and backs the coverage ratio), then protected senior.
        IPoolManager.ModifyLiquidityParams memory addLiq = IPoolManager.ModifyLiquidityParams({
            tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: 1e21, salt: 0
        });
        lpRouter.modifyLiquidity(key, addLiq, abi.encode(TrancheType.JUNIOR, bytes32("demo-junior")));
        lpRouter.modifyLiquidity(key, addLiq, abi.encode(TrancheType.SENIOR, bytes32("demo-senior")));

        // 5. Swap that crosses ticks: accrues dynamic fees (senior obligation funding) and induces IL.
        IPoolManager.SwapParams memory swap =
            IPoolManager.SwapParams({ zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: SQRT_PRICE_1_2 });
        swapRouter.swap(key, swap, PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }), bytes(""));

        vm.stopBroadcast();

        PoolId id = key.toId();
        console2.log("======= STRATUM Demo: pool opened + seeded + swapped =======");
        console2.log("CURRENCY0 (export this):", address(t0));
        console2.log("CURRENCY1 (export this):", address(t1));
        console2.log("PoolId                 :", vm.toString(PoolId.unwrap(id)));
        console2.log("LP router              :", address(lpRouter));
        console2.log("Swap router            :", address(swapRouter));
        console2.log("Epoch length (seconds) :", epochSeconds);
        _report(hook, id, "after swap (epoch open)");
        console2.log("");
        console2.log("Next: export CURRENCY0/CURRENCY1 above, wait", epochSeconds, "s, then --sig settle()");
    }

    /// @notice Close the elapsed epoch and report the final tranche state (run after DEMO_EPOCH_SECONDS).
    function settle() external {
        uint256 pk = privateKeyFromEnv();
        StratumHook hook = StratumHook(payable(vm.envAddress("STRATUM_HOOK_ADDRESS")));
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(vm.envAddress("CURRENCY0")),
            currency1: Currency.wrap(vm.envAddress("CURRENCY1")),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        PoolId id = key.toId();

        vm.startBroadcast(pk);
        hook.closeEpoch(id);
        vm.stopBroadcast();

        console2.log("======= STRATUM Demo: epoch closed (waterfall applied) =======");
        _report(hook, id, "after epoch close");
    }

    /// @dev Read and print the on-chain tranche state so the demo result is verifiable on the explorer.
    function _report(StratumHook hook, PoolId id, string memory phase) internal view {
        PoolTrancheState memory s = hook.poolState(id);
        (uint256 r0, uint256 r1) = (hook.reserve0(id), hook.reserve1(id));
        console2.log("--- tranche state:", phase, "---");
        console2.log("  seniorTVL            :", s.seniorTVL);
        console2.log("  juniorTVL            :", s.juniorTVL);
        console2.log("  juniorReserve (buf)  :", s.juniorReserve);
        console2.log("  currentEpoch         :", s.currentEpoch);
        console2.log("  epochAccumulatedFees :", s.epochAccumulatedFees);
        console2.log("  epochSeniorObligation:", s.epochSeniorObligation);
        console2.log("  poolCumulativeIL     :", s.poolCumulativeIL);
        console2.log("  token-backed reserve0:", r0);
        console2.log("  token-backed reserve1:", r1);
    }
}
