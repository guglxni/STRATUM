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
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";

import { StratumHook } from "../../src/StratumHook.sol";
import { IStratumHook } from "../../src/interfaces/IStratumHook.sol";
import { PoolInitParams, TrancheType } from "../../src/StratumTypes.sol";
import { CoverageRatio } from "../../src/libraries/CoverageRatio.sol";
import { StratumLens } from "../../src/peripherals/lens/StratumLens.sol";
import { StratumZap } from "../../src/peripherals/zap/StratumZap.sol";
import { HookMiner } from "../utils/HookMiner.sol";
import { StratumFlags } from "../utils/StratumFlags.sol";

/// @title EnhancementsTest
/// @notice Integration tests for the dev-portal enhancement peripherals: StratumLens (StateView
///         pattern, E-1) and StratumZap (position-router pattern, E-2). See
///         docs/UNISWAP_ENHANCEMENTS.md for the enhancement map.
contract EnhancementsTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    StratumHook hook;
    StratumLens lens;
    StratumZap zap;
    PoolInitParams defaultParams;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        defaultParams = PoolInitParams({
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
        hook.preparePool(key, defaultParams);
        manager.initialize(key, SQRT_PRICE_1_1);

        lens = new StratumLens(hook, IPoolManager(address(manager)));
        zap = new StratumZap(IPoolManager(address(manager)), IStratumHook(address(hook)));

        // Fund the end users and approve the zap.
        MockERC20 t0 = MockERC20(Currency.unwrap(currency0));
        MockERC20 t1 = MockERC20(Currency.unwrap(currency1));
        t0.mint(alice, 1e24);
        t1.mint(alice, 1e24);
        t0.mint(bob, 1e24);
        t1.mint(bob, 1e24);
        vm.startPrank(alice);
        t0.approve(address(zap), type(uint256).max);
        t1.approve(address(zap), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(bob);
        t0.approve(address(zap), type(uint256).max);
        t1.approve(address(zap), type(uint256).max);
        vm.stopPrank();
    }

    function _seedJunior() internal {
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -6000, tickUpper: 6000, liquidityDelta: 1e21, salt: bytes32("seed-j")
            }),
            abi.encode(TrancheType.JUNIOR, bytes32("seed-j"))
        );
    }

    // -------------------------------------------------------------------------
    // E-1: StratumLens
    // -------------------------------------------------------------------------

    /// @notice The lens aggregation must equal direct hook/manager reads field by field.
    function test_lens_poolOverview_matchesDirectReads() public {
        _seedJunior();
        swapRouterNoChecks.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -50_000, sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(-120)
            })
        );

        PoolId id = key.toId();
        StratumLens.PoolOverview memory o = lens.poolOverview(key);

        (uint160 sqrtP, int24 tick,,) = manager.getSlot0(id);
        assertEq(o.sqrtPriceX96, sqrtP, "sqrtPrice");
        assertEq(o.tick, tick, "tick");
        assertEq(o.seniorTVL, hook.poolState(id).seniorTVL, "seniorTVL");
        assertEq(o.juniorTVL, hook.poolState(id).juniorTVL, "juniorTVL");
        assertEq(o.epochAccumulatedFees, hook.poolState(id).epochAccumulatedFees, "epochFees");
        assertEq(
            o.coverageRatioBps,
            CoverageRatio.ratioBps(hook.poolState(id).juniorTVL, hook.poolState(id).seniorTVL),
            "coverage"
        );
        (uint256 r0, uint256 r1) = hook.reserveBalances(id);
        assertEq(o.reserve0, r0, "reserve0");
        assertEq(o.reserve1, r1, "reserve1");
        assertEq(o.protocolFeesAccrued, hook.protocolFeesAccrued(id), "protocolFees");
        assertTrue(o.initialized, "initialized");
    }

    /// @notice The lens fee preview must equal the fee the next swap actually books.
    function test_lens_dynamicFee_matchesNextSwap() public {
        _seedJunior();
        PoolId id = key.toId();

        uint16 previewBps = lens.poolOverview(key).nextSwapFeeBps;
        uint256 feesBefore = hook.poolState(id).epochAccumulatedFees;
        uint256 protocolBefore = hook.protocolFeesAccrued(id);

        uint256 swapAmount = 100_000;
        swapRouterNoChecks.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(swapAmount),
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(-120)
            })
        );

        // Gross booked fee = epoch accumulator increase + protocol carve-out (A-15).
        uint256 grossBooked =
            (hook.poolState(id).epochAccumulatedFees - feesBefore) + (hook.protocolFeesAccrued(id) - protocolBefore);
        assertEq(grossBooked, swapAmount * previewBps / 10_000, "lens preview == booked fee");
    }

    /// @notice Position overview: live IL responds to price moves, senior coupon accrues with time.
    function test_lens_positionOverview_ilAndCoupon() public {
        _seedJunior();
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -6000, tickUpper: 6000, liquidityDelta: 2e20, salt: bytes32("lens-s")
            }),
            abi.encode(TrancheType.SENIOR, bytes32("lens-s"))
        );
        bytes32 positionId = lens.positionIdFor(address(modifyLiquidityRouter), -6000, 6000, bytes32("lens-s"));

        StratumLens.PositionOverview memory before = lens.positionOverview(positionId);
        assertEq(before.position.owner, address(modifyLiquidityRouter), "position found");
        assertEq(before.ilAtCurrentPrice, 0, "no IL at entry price");
        assertEq(before.accruedCoupon, 0, "no coupon at entry instant");

        // Price move -> IL appears; time passes -> coupon accrues.
        swapRouterNoChecks.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -int256(1e23), sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(-3000)
            })
        );
        vm.warp(block.timestamp + 30 days);

        StratumLens.PositionOverview memory later = lens.positionOverview(positionId);
        assertGt(later.ilAtCurrentPrice, 0, "IL after price move");
        assertGt(later.accruedCoupon, 0, "coupon after time");

        // Unknown position returns a zeroed overview instead of reverting.
        StratumLens.PositionOverview memory missing = lens.positionOverview(bytes32("missing"));
        assertEq(missing.position.owner, address(0), "unknown position is empty");
    }

    // -------------------------------------------------------------------------
    // E-2: StratumZap
    // -------------------------------------------------------------------------

    /// @notice Full deposit -> withdraw round trip: position opens under the zap, proceeds land
    ///         on the end user, and the zap retains nothing.
    function test_zap_depositWithdraw_roundTrip() public {
        _seedJunior();
        PoolId id = key.toId();
        uint256 juniorTVLBefore = hook.poolState(id).juniorTVL;

        vm.prank(alice);
        bytes32 positionId = zap.deposit(key, -6000, 6000, 1e20, TrancheType.JUNIOR, bytes32("a1"), 1e22, 1e22, false);

        assertEq(zap.zapPositionOwner(positionId), alice, "zap records alice");
        assertEq(hook.position(positionId).owner, address(zap), "hook records the zap");
        assertGt(hook.poolState(id).juniorTVL, juniorTVLBefore, "junior TVL grew");

        uint256 aliceBal0 = MockERC20(Currency.unwrap(currency0)).balanceOf(alice);
        uint256 aliceBal1 = MockERC20(Currency.unwrap(currency1)).balanceOf(alice);

        vm.prank(alice);
        zap.withdraw(key, -6000, 6000, bytes32("a1"));

        assertEq(hook.position(positionId).owner, address(0), "position settled and deleted");
        assertEq(zap.zapPositionOwner(positionId), address(0), "zap record cleared");
        assertGt(
            MockERC20(Currency.unwrap(currency0)).balanceOf(alice)
                + MockERC20(Currency.unwrap(currency1)).balanceOf(alice),
            aliceBal0 + aliceBal1,
            "proceeds delivered to alice"
        );
        assertEq(MockERC20(Currency.unwrap(currency0)).balanceOf(address(zap)), 0, "zap holds no token0");
        assertEq(MockERC20(Currency.unwrap(currency1)).balanceOf(address(zap)), 0, "zap holds no token1");
    }

    /// @notice Trading API recipient shape: tokens pre-delivered to the zap are consumed without
    ///         any transferFrom, and the unused remainder is swept to the caller.
    function test_zap_deliveredBalanceMode() public {
        _seedJunior();

        // Simulate a Trading API swap with recipient = zap: tokens just appear on the zap.
        MockERC20(Currency.unwrap(currency0)).mint(address(zap), 1e22);
        MockERC20(Currency.unwrap(currency1)).mint(address(zap), 1e22);

        // Bob never approved nor transferred anything in this flow; revoke to prove no pull happens.
        vm.startPrank(bob);
        MockERC20(Currency.unwrap(currency0)).approve(address(zap), 0);
        MockERC20(Currency.unwrap(currency1)).approve(address(zap), 0);
        bytes32 positionId = zap.deposit(key, -6000, 6000, 1e20, TrancheType.JUNIOR, bytes32("b1"), 0, 0, true);
        vm.stopPrank();

        assertEq(zap.zapPositionOwner(positionId), bob, "bob owns the delivered-balance position");
        assertEq(MockERC20(Currency.unwrap(currency0)).balanceOf(address(zap)), 0, "remainder swept");
        assertEq(MockERC20(Currency.unwrap(currency1)).balanceOf(address(zap)), 0, "remainder swept");
        assertGt(MockERC20(Currency.unwrap(currency0)).balanceOf(bob), 1e24 - 1e22, "sweep went to bob");
    }

    /// @notice Same userSalt from different users yields distinct positions, and a stranger can
    ///         never withdraw someone else's zap position.
    function test_zap_userIsolation() public {
        _seedJunior();

        vm.prank(alice);
        bytes32 posA = zap.deposit(key, -6000, 6000, 1e20, TrancheType.JUNIOR, bytes32("same"), 1e22, 1e22, false);
        vm.prank(bob);
        bytes32 posB = zap.deposit(key, -6000, 6000, 1e20, TrancheType.JUNIOR, bytes32("same"), 1e22, 1e22, false);

        assertTrue(posA != posB, "same salt, different users -> distinct positions");

        // The salt is keyed by msg.sender, so bob structurally CANNOT address alice's position
        // through withdraw: his call resolves to his own posB. The forwarders take a raw position
        // id, so they carry the explicit owner gate.
        vm.prank(bob);
        vm.expectRevert(StratumZap.NotZapPositionOwner.selector);
        zap.claimVested(posA);
        vm.prank(bob);
        vm.expectRevert(StratumZap.NotZapPositionOwner.selector);
        zap.migrateTranchePosition(posA, TrancheType.SENIOR);

        // Each user withdraws their own position; the other's stays intact.
        vm.prank(alice);
        zap.withdraw(key, -6000, 6000, bytes32("same"));
        assertEq(zap.zapPositionOwner(posA), address(0), "alice's position closed");
        assertEq(zap.zapPositionOwner(posB), bob, "bob's position untouched");

        vm.prank(bob);
        zap.withdraw(key, -6000, 6000, bytes32("same"));
        assertEq(zap.zapPositionOwner(posB), address(0), "bob's position closed");
    }

    /// @notice Unused funding (amountMax overshoot) is refunded to the depositor in the same call.
    function test_zap_refundsUnusedFunds() public {
        _seedJunior();
        uint256 bal0Before = MockERC20(Currency.unwrap(currency0)).balanceOf(alice);

        vm.prank(alice);
        zap.deposit(key, -6000, 6000, 1e20, TrancheType.JUNIOR, bytes32("refund"), 1e23, 1e23, false);

        uint256 bal0After = MockERC20(Currency.unwrap(currency0)).balanceOf(alice);
        // The position needs far less than 1e23 at this range/liquidity; most must come back.
        assertGt(bal0After, bal0Before - 1e22, "unused token0 refunded");
        assertEq(MockERC20(Currency.unwrap(currency0)).balanceOf(address(zap)), 0, "no residue on zap");
    }

    /// @notice Owner-surface forwarders work for the recorded user and revert for everyone else.
    function test_zap_forwarders_gated() public {
        _seedJunior();
        vm.prank(alice);
        bytes32 positionId = zap.deposit(key, -6000, 6000, 1e20, TrancheType.JUNIOR, bytes32("fwd"), 1e22, 1e22, false);

        // claimVested: gated, then works for alice.
        vm.prank(bob);
        vm.expectRevert(StratumZap.NotZapPositionOwner.selector);
        zap.claimVested(positionId);
        vm.prank(alice);
        zap.claimVested(positionId); // must not revert

        // approveMigrator: gated, then works.
        vm.prank(bob);
        vm.expectRevert(StratumZap.NotZapPositionOwner.selector);
        zap.approveMigrator(positionId, bob);
        vm.prank(alice);
        zap.approveMigrator(positionId, alice);

        // migrateTranchePosition: junior -> senior through the zap (coverage allows: seed junior is large).
        vm.prank(bob);
        vm.expectRevert(StratumZap.NotZapPositionOwner.selector);
        zap.migrateTranchePosition(positionId, TrancheType.SENIOR);
        vm.prank(alice);
        uint256 carried = zap.migrateTranchePosition(positionId, TrancheType.SENIOR);
        assertGt(carried, 0, "migration carried principal");
        assertEq(uint8(hook.position(positionId).tranche), uint8(TrancheType.SENIOR), "tranche flipped");
    }
}
