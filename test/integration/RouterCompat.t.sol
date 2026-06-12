// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { Deployers } from "@uniswap/v4-core/test/utils/Deployers.sol";
import { LPFeeLibrary } from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { BeforeSwapDelta } from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import { PoolSwapTest } from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import { StratumHook } from "../../src/StratumHook.sol";
import { PoolInitParams, TrancheType } from "../../src/StratumTypes.sol";
import { HookMiner } from "../utils/HookMiner.sol";
import { StratumFlags } from "../utils/StratumFlags.sol";

/// @title RouterCompatTest
/// @notice D-4: STRATUM pools must accept routed flow (e.g. a UniswapX filler settling through the universal
///         router, or any aggregator). The only on-chain requirement is that `beforeSwap` stays lean and never
///         reverts for an ordinary swap, so a router can quote and execute against a tranched pool exactly like
///         a vanilla pool. This is a property guarantee, not new code: it pins the gas ceiling (the CI gas
///         guard the enhancement doc references) and exercises every routed swap shape, including with the D-1
///         protocol-fee surcharge live (the afterSwap return delta must remain router-compatible).
contract RouterCompatTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    /// @dev Regression ceiling for a warm `beforeSwap` (anchor already set this block). Generous enough not to
    ///      be brittle, tight enough to catch an accidental heavy addition (e.g. an unbounded loop or a new
    ///      external call) sneaking into the swap hot path.
    uint256 constant BEFORE_SWAP_GAS_CEILING = 50_000;

    StratumHook hook;
    PoolInitParams params;

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        params = PoolInitParams({
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

        (address hookAddr, bytes32 salt) = HookMiner.find(
            address(this), StratumFlags.STRATUM_HOOK_FLAGS, type(StratumHook).creationCode, abi.encode(address(manager))
        );
        hook = new StratumHook{ salt: salt }(IPoolManager(address(manager)));
        assertEq(address(hook), hookAddr);

        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        hook.preparePool(key, params);
        manager.initialize(key, SQRT_PRICE_1_1);

        // Seed deep junior liquidity so routed swaps have depth in both directions.
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60_000, tickUpper: 60_000, liquidityDelta: 1e23, salt: bytes32("seed-j")
            }),
            abi.encode(TrancheType.JUNIOR, bytes32("seed-j"))
        );
    }

    /// @notice `beforeSwap` is lean: a warm call (anchor already snapshotted this block) stays under the gas
    ///         ceiling, so a router's quote/execute path is not penalized by the tranche overlay.
    function test_beforeSwap_isLean_warmGasUnderCeiling() public {
        IPoolManager.SwapParams memory sp = IPoolManager.SwapParams({
            zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        // First call snapshots the block-start anchor (a one-time cold SSTORE); measure the warm second call.
        vm.startPrank(address(manager));
        hook.beforeSwap(address(this), key, sp, "");

        uint256 g0 = gasleft();
        hook.beforeSwap(address(this), key, sp, "");
        uint256 used = g0 - gasleft();
        vm.stopPrank();

        emit log_named_uint("beforeSwap warm gas", used);
        assertLt(used, BEFORE_SWAP_GAS_CEILING, "beforeSwap must stay lean for routed flow");
    }

    /// @notice Every routed swap shape settles without reverting: exact-in and exact-out, both directions.
    function test_routedFlow_allShapes_nonReverting() public {
        // exact-in zeroForOne
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            ""
        );
        // exact-in oneForZero
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: false, amountSpecified: -1e18, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            ""
        );
        // exact-out zeroForOne
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: 1e17, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            ""
        );
        // exact-out oneForZero
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: false, amountSpecified: 1e17, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            ""
        );
    }

    /// @notice With the D-1 protocol-fee surcharge live, the afterSwap return delta must remain compatible with
    ///         a standard router that settles the caller delta: routed swaps still succeed in both directions.
    function test_routedFlow_withProtocolSurcharge_nonReverting() public {
        hook.setProtocolFeeRealization(key.toId(), true);

        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            ""
        );
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: false, amountSpecified: 1e17, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            ""
        );

        // The surcharge was realized into the token-backed reserve (proof the delta path executed through the
        // standard router, not just the no-checks one).
        (uint256 p0, uint256 p1) = hook.protocolFeeReserveBalances(key.toId());
        assertGt(p0 + p1, 0, "protocol surcharge realized under routed flow");
    }

    /// @notice `beforeSwap` returns a zero swap delta and the dynamic-fee override flag: it never imposes a
    ///         hook-level swap delta, so routers see vanilla swap economics plus a dynamic fee.
    function test_beforeSwap_returnsZeroDeltaAndDynamicFee() public {
        vm.prank(address(manager));
        (bytes4 selector, BeforeSwapDelta delta, uint24 lpFee) = hook.beforeSwap(
            address(this),
            key,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );
        assertEq(selector, StratumHook.beforeSwap.selector, "selector");
        assertEq(BeforeSwapDelta.unwrap(delta), 0, "no beforeSwap delta imposed on routers");
        assertTrue(lpFee & LPFeeLibrary.OVERRIDE_FEE_FLAG != 0, "dynamic fee override flagged");
    }
}
