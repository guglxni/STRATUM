// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test, Vm } from "forge-std/Test.sol";
import { Deployers } from "@uniswap/v4-core/test/utils/Deployers.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { LPFeeLibrary } from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";

import { CustomRevert } from "@uniswap/v4-core/src/libraries/CustomRevert.sol";

import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";

import { StratumHook } from "../../src/StratumHook.sol";
import { StratumErrors } from "../../src/StratumErrors.sol";
import { PoolInitParams, TrancheType } from "../../src/StratumTypes.sol";
import { CoverageRatio } from "../../src/libraries/CoverageRatio.sol";
import { HookMiner } from "../utils/HookMiner.sol";
import { StratumFlags } from "../utils/StratumFlags.sol";
import { IStratumHook } from "../../src/interfaces/IStratumHook.sol";

/// @title StratumHookIntegrationTest
/// @notice Full deposit lifecycle on mock PoolManager (FR-01, FR-02, C1 prep).
contract StratumHookIntegrationTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;

    StratumHook hook;
    PoolInitParams defaultParams;

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
    }

    function test_juniorDeposit_mintsJtLP() public {
        bytes memory hookData = abi.encode(TrancheType.JUNIOR, bytes32("junior1"));
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, hookData);
        assertGt(hook.poolState(key.toId()).juniorTVL, 0);
    }

    function test_seniorDeposit_afterJunior_coverageOk() public {
        bytes memory juniorData = abi.encode(TrancheType.JUNIOR, bytes32("j1"));
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, juniorData);

        bytes memory seniorData = abi.encode(TrancheType.SENIOR, bytes32("s1"));
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, seniorData);
        assertGt(hook.poolState(key.toId()).seniorTVL, 0);
    }

    function test_swap_updatesEpochFees() public {
        bytes memory hookData = abi.encode(TrancheType.JUNIOR, bytes32("jswap"));
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, hookData);
        IPoolManager.SwapParams memory largeSwap = IPoolManager.SwapParams({
            zeroForOne: true, amountSpecified: -50_000, sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(-120)
        });
        swapRouterNoChecks.swap(key, largeSwap);
        assertGt(hook.poolState(key.toId()).epochAccumulatedFees, 0);
    }

    function test_closeEpoch_advancesCounter() public {
        PoolId id = key.toId();
        uint64 epoch0 = hook.poolState(id).currentEpoch;
        vm.warp(block.timestamp + defaultParams.smoothingEpochSeconds);
        hook.closeEpoch(id);
        assertEq(hook.poolState(id).currentEpoch, epoch0 + 1);
    }

    function test_closeEpoch_beforeTimeElapsed_reverts() public {
        PoolId id = key.toId();
        vm.expectRevert(StratumErrors.EpochNotElapsed.selector);
        hook.closeEpoch(id);
    }

    function test_positionOverwrite_reverts() public {
        bytes memory hookData = abi.encode(TrancheType.JUNIOR, bytes32("dup"));
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, hookData);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.afterAddLiquidity.selector,
                abi.encodeWithSelector(StratumErrors.PositionAlreadyExists.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, hookData);
    }

    function test_seniorDeposit_belowCoverageFloor_reverts() public {
        bytes memory seniorData = abi.encode(TrancheType.SENIOR, bytes32("solo-s"));
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.afterAddLiquidity.selector,
                abi.encodeWithSelector(CoverageRatio.CoverageRatioBelowFloor.selector, uint16(0), uint16(3000)),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, seniorData);
    }

    /// @notice R-H5 / INV-04 / INV-05: the junior buffer is NOT credited per swap. Surplus is credited
    ///         once, at closeEpoch, against the fully-funded obligation. Pre-fix the buffer was credited
    ///         both per swap and at close (~2x double-count).
    function test_RH5_noPerSwapBufferCredit() public {
        PoolId id = key.toId();
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, abi.encode(TrancheType.JUNIOR, bytes32("jr")));
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, abi.encode(TrancheType.SENIOR, bytes32("sr")));
        swapRouterNoChecks.swap(key, SWAP_PARAMS);

        assertGt(hook.poolState(id).epochSeniorObligation, 0);
        // The decisive R-H5 assertion: the swap accrued fees but did NOT pre-credit the buffer.
        assertEq(hook.poolState(id).juniorReserve, 0, "no per-swap buffer credit (R-H5)");
        assertGt(hook.poolState(id).epochAccumulatedFees, 0, "fees still accrue to the epoch accumulator");

        vm.warp(block.timestamp + defaultParams.smoothingEpochSeconds);
        hook.closeEpoch(id);
        assertEq(hook.poolState(id).currentEpoch, 1);
    }

    function test_claimVested_returnsZeroWhenNothingVested() public {
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, abi.encode(TrancheType.JUNIOR, bytes32("claim")));
        bytes32 positionId = keccak256(
            abi.encode(
                address(modifyLiquidityRouter), LIQUIDITY_PARAMS.tickLower, LIQUIDITY_PARAMS.tickUpper, bytes32("claim")
            )
        );
        vm.prank(address(modifyLiquidityRouter));
        assertEq(hook.claimVested(positionId), 0);
    }

    /// @notice FR-02, FR-13: junior deposit -> swap -> epochClose -> removal settles to zero TVL.
    /// @dev Hook calls poolManager.take() for any positive adj0 (IL clawback); ZERO_DELTA for
    ///      negative adj0 (senior yield, deferred to Phase 3 reserve contract).
    function test_fullCycle_junior_deposit_swap_epochClose_remove() public {
        PoolId id = key.toId();

        // 1. Junior deposit with salt "fc-j".
        bytes memory jHookData = abi.encode(TrancheType.JUNIOR, bytes32("fc-j"));
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, jHookData);
        assertGt(hook.poolState(id).juniorTVL, 0, "juniorTVL should be > 0 after deposit");

        // 2. Swap to generate epoch fees (exact-input 50_000 token0).
        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: true, amountSpecified: -50_000, sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(-120)
        });
        swapRouterNoChecks.swap(key, swapParams);
        assertGt(hook.poolState(id).epochAccumulatedFees, 0, "fees should be > 0 after swap");

        // 3. Advance time past one epoch and close it.
        vm.warp(block.timestamp + defaultParams.smoothingEpochSeconds);
        hook.closeEpoch(id);
        assertEq(hook.poolState(id).currentEpoch, 1, "epoch counter should be 1");

        // 4. Compute the positionId that was registered at deposit time.
        //    sender in callbacks = address(modifyLiquidityRouter).
        bytes32 posId = keccak256(
            abi.encode(
                address(modifyLiquidityRouter), LIQUIDITY_PARAMS.tickLower, LIQUIDITY_PARAMS.tickUpper, bytes32("fc-j")
            )
        );

        // 5. Expect TrancheSettled: check poolId (topic1) and owner (topic3); skip positionId and amounts.
        vm.expectEmit(true, false, true, false);
        emit IStratumHook.TrancheSettled(id, posId, address(modifyLiquidityRouter), TrancheType.JUNIOR, 0, 0);

        // 6. Remove junior liquidity with matching hookData and negated liquidityDelta.
        IPoolManager.ModifyLiquidityParams memory removeParams = IPoolManager.ModifyLiquidityParams({
            tickLower: LIQUIDITY_PARAMS.tickLower,
            tickUpper: LIQUIDITY_PARAMS.tickUpper,
            liquidityDelta: -LIQUIDITY_PARAMS.liquidityDelta,
            salt: LIQUIDITY_PARAMS.salt
        });
        modifyLiquidityRouter.modifyLiquidity(key, removeParams, jHookData);

        // 7. Assertions: TVL zeroed, position deleted, juniorReserve is non-negative (uint so always true).
        assertEq(hook.poolState(id).juniorTVL, 0, "juniorTVL must be 0 after full removal");
        assertEq(hook.position(posId).owner, address(0), "position must be deleted after settlement");
        // juniorReserve is a uint256 -- any value >= 0 is valid (silence is a pass).
    }

    /// @notice FR-01, FR-02, FR-13: senior + junior deposit -> swap -> epochClose -> senior removal.
    /// @dev Verifies seniorFeePerShareX128 attribution and full TVL accounting through a complete lifecycle.
    function test_fullCycle_senior_deposit_swap_epochClose_remove() public {
        PoolId id = key.toId();

        // 1. Junior deposit first to satisfy coverage floor for senior intake.
        bytes memory j2HookData = abi.encode(TrancheType.JUNIOR, bytes32("fc-j2"));
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, j2HookData);

        // 2. Senior deposit.
        bytes memory s2HookData = abi.encode(TrancheType.SENIOR, bytes32("fc-s2"));
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, s2HookData);
        assertGt(hook.poolState(id).seniorTVL, 0, "seniorTVL should be > 0 after senior deposit");

        // 3. Swap to generate fees.
        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: true, amountSpecified: -50_000, sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(-120)
        });
        swapRouterNoChecks.swap(key, swapParams);
        assertGt(hook.poolState(id).epochAccumulatedFees, 0, "fees should be > 0 after swap");

        // 4. Advance time and close epoch; verify senior fee accumulator is updated.
        vm.warp(block.timestamp + defaultParams.smoothingEpochSeconds);
        hook.closeEpoch(id);
        assertEq(hook.poolState(id).currentEpoch, 1, "epoch counter should be 1");
        assertGt(hook.poolState(id).seniorFeePerShareX128, 0, "seniorFeePerShareX128 must be > 0 after epoch with fees");

        // 5. Compute the senior positionId.
        bytes32 seniorPosId = keccak256(
            abi.encode(
                address(modifyLiquidityRouter), LIQUIDITY_PARAMS.tickLower, LIQUIDITY_PARAMS.tickUpper, bytes32("fc-s2")
            )
        );

        // 6. Expect TrancheSettled for the senior position: check poolId (topic1) and owner (topic3).
        vm.expectEmit(true, false, true, false);
        emit IStratumHook.TrancheSettled(id, seniorPosId, address(modifyLiquidityRouter), TrancheType.SENIOR, 0, 0);

        // 7. Remove senior liquidity.
        IPoolManager.ModifyLiquidityParams memory removeSeniorParams = IPoolManager.ModifyLiquidityParams({
            tickLower: LIQUIDITY_PARAMS.tickLower,
            tickUpper: LIQUIDITY_PARAMS.tickUpper,
            liquidityDelta: -LIQUIDITY_PARAMS.liquidityDelta,
            salt: LIQUIDITY_PARAMS.salt
        });
        modifyLiquidityRouter.modifyLiquidity(key, removeSeniorParams, s2HookData);

        // 8. Assertions: seniorTVL zeroed, senior position deleted.
        assertEq(hook.poolState(id).seniorTVL, 0, "seniorTVL must be 0 after full senior removal");
        assertEq(hook.position(seniorPosId).owner, address(0), "senior position must be deleted after settlement");
    }

    /// @notice R-H2 / FR-07 / R-L1: claimVested is live and returns a linearly-increasing vested amount across
    ///         the smoothing window (it used to revert / always return 0).
    function test_RH2_claimVested_linearAndLive() public {
        PoolId id = key.toId();
        // Junior-only pool: with no senior, the obligation is 0, so all epoch fees become surplus and
        // closeEpoch bumps juniorFeePerShareX128 (the earnings the position then smooths).
        bytes memory jData = abi.encode(TrancheType.JUNIOR, bytes32("rh2"));
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, jData);

        IPoolManager.SwapParams memory s = IPoolManager.SwapParams({
            zeroForOne: true, amountSpecified: -1_000_000, sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(-120)
        });
        swapRouterNoChecks.swap(key, s);

        // Close epoch 0: surplus -> juniorFeePerShareX128 bumped; epoch 1 opens (its window starts now).
        vm.warp(block.timestamp + defaultParams.smoothingEpochSeconds);
        hook.closeEpoch(id);

        bytes32 posId = keccak256(
            abi.encode(
                address(modifyLiquidityRouter), LIQUIDITY_PARAMS.tickLower, LIQUIDITY_PARAMS.tickUpper, bytes32("rh2")
            )
        );

        // Halfway into epoch 1: a partial amount has vested (and claimVested does NOT revert -> R-L1 fixed).
        vm.warp(block.timestamp + defaultParams.smoothingEpochSeconds / 2);
        vm.prank(address(modifyLiquidityRouter));
        uint256 vestedHalf = hook.claimVested(posId);
        assertGt(vestedHalf, 0, "partial vest mid-window (R-L1: claimVested can pay)");

        // Past the window end: the full earned amount has vested.
        vm.warp(block.timestamp + defaultParams.smoothingEpochSeconds);
        vm.prank(address(modifyLiquidityRouter));
        uint256 vestedFull = hook.claimVested(posId);
        assertGt(vestedFull, vestedHalf, "vesting is linear: more vests over time (FR-07)");
    }

    /// @notice R-H2 / FR-14 / INV-05: an early junior exit forfeits its unvested earnings to the junior buffer.
    function test_RH2_earlyExit_forfeitsUnvestedToBuffer() public {
        PoolId id = key.toId();
        bytes memory jData = abi.encode(TrancheType.JUNIOR, bytes32("rh2f"));
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, jData);

        IPoolManager.SwapParams memory s = IPoolManager.SwapParams({
            zeroForOne: true, amountSpecified: -1_000_000, sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(-120)
        });
        swapRouterNoChecks.swap(key, s);
        vm.warp(block.timestamp + defaultParams.smoothingEpochSeconds);
        hook.closeEpoch(id);

        bytes32 posId = keccak256(
            abi.encode(
                address(modifyLiquidityRouter), LIQUIDITY_PARAMS.tickLower, LIQUIDITY_PARAMS.tickUpper, bytes32("rh2f")
            )
        );

        // Halfway into epoch 1: harvest into the bucket (via claimVested) and read the partial vested amount.
        vm.warp(block.timestamp + defaultParams.smoothingEpochSeconds / 2);
        vm.prank(address(modifyLiquidityRouter));
        uint256 vested = hook.claimVested(posId);
        uint256 bucket = hook.position(posId).accruedFixedYield + hook.position(posId).excessFeesEarned;
        assertGt(bucket, vested, "bucket has an unvested remainder at 50% of the window");

        uint256 bufferBefore = hook.poolState(id).juniorReserve;

        // Exit at the same instant. A junior exit does not debit the buffer for its own IL (C5), so the only
        // buffer change is the FR-14 forfeiture credit of the unvested remainder.
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: LIQUIDITY_PARAMS.tickLower,
                tickUpper: LIQUIDITY_PARAMS.tickUpper,
                liquidityDelta: -LIQUIDITY_PARAMS.liquidityDelta,
                salt: LIQUIDITY_PARAMS.salt
            }),
            jData
        );

        uint256 forfeited = hook.poolState(id).juniorReserve - bufferBefore;
        assertEq(forfeited, bucket - vested, "buffer credited exactly the unvested remainder (FR-14)");
    }

    /// @notice R-H1 / FR-09 / INV-02: a senior LP is made whole in REAL tokens from the reserve, which is
    ///         funded by a junior LP's IL clawback. This is the credit-subordination thesis delivered
    ///         on-chain (not just in accounting): junior IL absorption pays senior protection.
    function test_RH1_seniorMakeWhole_paysRealTokensFromReserve() public {
        PoolId id = key.toId();

        // Two wide-range junior positions (so one can exit to fund the reserve while the other keeps the
        // coverage ratio above the floor), plus a senior position to be protected.
        IPoolManager.ModifyLiquidityParams memory wideA = IPoolManager.ModifyLiquidityParams({
            tickLower: -6000, tickUpper: 6000, liquidityDelta: 1e21, salt: bytes32("rh1-jA")
        });
        IPoolManager.ModifyLiquidityParams memory wideB = IPoolManager.ModifyLiquidityParams({
            tickLower: -6000, tickUpper: 6000, liquidityDelta: 1e21, salt: bytes32("rh1-jB")
        });
        // Senior is also wide-range (smaller liquidity) so a large crash creates large IL on it: the pool's
        // natural return falls well below the protected payout, which is what triggers the make-whole.
        IPoolManager.ModifyLiquidityParams memory seniorWide = IPoolManager.ModifyLiquidityParams({
            tickLower: -6000, tickUpper: 6000, liquidityDelta: 2e20, salt: bytes32("rh1-s")
        });
        modifyLiquidityRouter.modifyLiquidity(key, wideA, abi.encode(TrancheType.JUNIOR, bytes32("rh1-jA")));
        modifyLiquidityRouter.modifyLiquidity(key, wideB, abi.encode(TrancheType.JUNIOR, bytes32("rh1-jB")));
        modifyLiquidityRouter.modifyLiquidity(key, seniorWide, abi.encode(TrancheType.SENIOR, bytes32("rh1-s")));

        // Phase 1 - crash DOWN: junior A becomes currency0-heavy with IL above its payout, so its exit
        // CLAWS BACK currency0 into the reserve (junior IL absorption funds the buffer).
        swapRouterNoChecks.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -int256(1e25), sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(-5940)
            })
        );
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -6000, tickUpper: 6000, liquidityDelta: -1e21, salt: bytes32("rh1-jA")
            }),
            abi.encode(TrancheType.JUNIOR, bytes32("rh1-jA"))
        );
        (uint256 r0, uint256 r1) = hook.reserveBalances(id);
        assertTrue(r0 > 0 || r1 > 0, "reserve funded by junior A's IL clawback");

        // Phase 2 - pump UP past entry: the senior position now holds far less token0-value than its
        // entry-price principal, so the pool returns LESS than the protected payout -> make-whole fires.
        swapRouterNoChecks.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: false, amountSpecified: -int256(1e25), sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(5940)
            })
        );

        // A-06: the senior exit must happen in a LATER block than the price move. The block-start anchor
        // guard intentionally neutralizes same-block (sandwich-shaped) make-whole draws; a genuine market
        // move persists across blocks, which this roll models.
        vm.roll(block.number + 1);

        // The senior LP (test contract receives the router's settled tokens) exits and is topped up.
        uint256 bal0Before = MockERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        uint256 bal1Before = MockERC20(Currency.unwrap(currency1)).balanceOf(address(this));

        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -6000, tickUpper: 6000, liquidityDelta: -2e20, salt: bytes32("rh1-s")
            }),
            abi.encode(TrancheType.SENIOR, bytes32("rh1-s"))
        );

        // The reserve was drawn down to deliver the make-whole.
        (uint256 r0After, uint256 r1After) = hook.reserveBalances(id);
        assertTrue(r0After < r0 || r1After < r1, "reserve decreased to fund the make-whole");

        // The senior LP received MORE than the pool's natural payout: their wallet gained the top-up too.
        uint256 received0 = MockERC20(Currency.unwrap(currency0)).balanceOf(address(this)) - bal0Before;
        uint256 received1 = MockERC20(Currency.unwrap(currency1)).balanceOf(address(this)) - bal1Before;
        assertTrue(received0 > 0 || received1 > 0, "senior received real tokens (pool payout + reserve top-up)");

        assertEq(hook.poolState(id).seniorTVL, 0, "senior position fully settled");
    }

    /// @notice R-C1 regression: a large IL clawback on a wide-range, currency1-bearing position must settle
    ///         PER CURRENCY and clamp each take to the LP's actual per-currency credit.
    /// @dev Reachability note: with the current single-position value model, a junior position is in the
    ///      clawback branch (received > payout) only on price-DOWN moves, which leave it currency0-heavy, so
    ///      the clawback is satisfied entirely by currency0 (the currency1 spillover is defensive and not
    ///      reachable here - see docs/AUDIT.md R-C1). This test pins the REACHABLE path: a deep clawback on a
    ///      wide-range position settles cleanly (no CurrencyNotSettled) and the hook reclaims exactly the
    ///      excess in currency0, clamped to delta.amount0(). The per-currency machinery makes this correct
    ///      and keeps it correct if the payout model later decouples from the withdrawn currency mix.
    function test_RC1_clawback_settlesPerCurrencyAndClamps() public {
        PoolId id = key.toId();

        // Wide range so the withdrawn position holds meaningful amounts of BOTH currencies pre-move.
        IPoolManager.ModifyLiquidityParams memory wide = IPoolManager.ModifyLiquidityParams({
            tickLower: -6000, tickUpper: 6000, liquidityDelta: 1e21, salt: bytes32("rc1")
        });
        bytes memory jHookData = abi.encode(TrancheType.JUNIOR, bytes32("rc1"));
        modifyLiquidityRouter.modifyLiquidity(key, wide, jHookData);
        assertGt(hook.poolState(id).juniorTVL, 0, "juniorTVL > 0 after deposit");

        // Large price-DOWN move (stops at -5940, inside the range): big IL -> sizeable clawback excess.
        IPoolManager.SwapParams memory crash = IPoolManager.SwapParams({
            zeroForOne: true, amountSpecified: -int256(1e27), sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(-5940)
        });
        swapRouterNoChecks.swap(key, crash);

        bytes32 posId = keccak256(abi.encode(address(modifyLiquidityRouter), int24(-6000), int24(6000), bytes32("rc1")));
        uint256 hookBal0Before = MockERC20(Currency.unwrap(currency0)).balanceOf(address(hook));

        // The core regression: this removal must NOT revert (a blended single-currency take could over-draw).
        IPoolManager.ModifyLiquidityParams memory remove = IPoolManager.ModifyLiquidityParams({
            tickLower: -6000, tickUpper: 6000, liquidityDelta: -1e21, salt: bytes32("rc1")
        });
        modifyLiquidityRouter.modifyLiquidity(key, remove, jHookData);

        // Clean settlement: TVL zeroed, position deleted.
        assertEq(hook.poolState(id).juniorTVL, 0, "juniorTVL must be 0 after removal");
        assertEq(hook.position(posId).owner, address(0), "position must be deleted");

        // The per-currency clawback executed and was clamped to the currency0 leg.
        uint256 hookBal0After = MockERC20(Currency.unwrap(currency0)).balanceOf(address(hook));
        assertGt(hookBal0After, hookBal0Before, "hook must reclaim the IL clawback in currency0");
    }

    /// @notice A-05: only the pool creator (preparePool caller) may consume the prepared parameters at
    ///         PoolManager.initialize. A third party must not be able to choose the initial sqrtPrice.
    function test_A05_initialize_onlyPoolCreator() public {
        PoolKey memory keyB = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 120,
            hooks: IHooks(address(hook))
        });
        hook.preparePool(keyB, defaultParams);

        // A stranger front-running initialize with a skewed price must revert inside beforeInitialize.
        vm.prank(address(0xBAD));
        vm.expectRevert(); // Unauthorized, wrapped by the PoolManager's hook-revert bubbling
        manager.initialize(keyB, TickMath.getSqrtPriceAtTick(5000));

        // The creator initializes normally.
        manager.initialize(keyB, SQRT_PRICE_1_1);
        assertTrue(hook.poolState(keyB.toId()).initialized, "creator-initialized pool is live");
    }

    /// @notice A-04: a token1-specified swap books its fee converted into the token0 numeraire, so opposite
    ///         swap directions of equal value book (approximately) equal fees at a 1:1 price.
    function test_A04_feeBookedInToken0Numeraire_bothDirections() public {
        PoolId id = key.toId();
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -6000, tickUpper: 6000, liquidityDelta: 1e21, salt: bytes32("a04")
            }),
            abi.encode(TrancheType.JUNIOR, bytes32("a04"))
        );

        // exactIn token0 (zeroForOne): specified currency IS token0.
        swapRouterNoChecks.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -100_000, sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(-120)
            })
        );
        uint256 feesAfterDir0 = hook.poolState(id).epochAccumulatedFees;
        assertGt(feesAfterDir0, 0, "token0-specified swap booked a fee");

        // exactIn token1 (oneForZero): specified currency is token1; the booked fee must be converted.
        swapRouterNoChecks.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: false, amountSpecified: -100_000, sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(120)
            })
        );
        uint256 feeDir1 = hook.poolState(id).epochAccumulatedFees - feesAfterDir0;
        assertGt(feeDir1, 0, "token1-specified swap booked a fee");

        // At ~1:1 price the converted token1 fee must be within 2% of the token0 fee, not drift with price.
        assertApproxEqRel(feeDir1, feesAfterDir0, 0.02e18, "A-04: token1 fee converted to token0 numeraire");
    }

    /// @notice A-06: an atomic (same-block) crash + senior exit must NOT draw the make-whole reserve, because
    ///         settlement re-values the withdrawal against the block-start price anchor. This is the sandwich
    ///         shape: swap down -> senior withdraws (reserve pays gap) -> swap back. The cross-block legit
    ///         path is pinned by test_RH1_seniorMakeWhole_paysRealTokensFromReserve.
    function test_A06_sameBlockSandwich_cannotDrainMakeWholeReserve() public {
        PoolId id = key.toId();

        // Same shape as RH1: two juniors fund coverage, one exits after a crash to fund the reserve.
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -6000, tickUpper: 6000, liquidityDelta: 1e21, salt: bytes32("a06-jA")
            }),
            abi.encode(TrancheType.JUNIOR, bytes32("a06-jA"))
        );
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -6000, tickUpper: 6000, liquidityDelta: 1e21, salt: bytes32("a06-jB")
            }),
            abi.encode(TrancheType.JUNIOR, bytes32("a06-jB"))
        );
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -6000, tickUpper: 6000, liquidityDelta: 2e20, salt: bytes32("a06-s")
            }),
            abi.encode(TrancheType.SENIOR, bytes32("a06-s"))
        );

        // Fund the reserve in an EARLIER block (crash + junior clawback), then roll.
        swapRouterNoChecks.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -int256(1e25), sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(-5940)
            })
        );
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -6000, tickUpper: 6000, liquidityDelta: -1e21, salt: bytes32("a06-jA")
            }),
            abi.encode(TrancheType.JUNIOR, bytes32("a06-jA"))
        );
        (uint256 r0, uint256 r1) = hook.reserveBalances(id);
        assertTrue(r0 > 0 || r1 > 0, "reserve funded by junior clawback");
        vm.roll(block.number + 1);

        // SAME BLOCK now: pump the price (sandwich front-leg; this records the pre-pump anchor), then the
        // senior exits. The anchor-guarded settlement must not pay a make-whole from the reserve.
        swapRouterNoChecks.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: false, amountSpecified: -int256(1e25), sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(5940)
            })
        );
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -6000, tickUpper: 6000, liquidityDelta: -2e20, salt: bytes32("a06-s")
            }),
            abi.encode(TrancheType.SENIOR, bytes32("a06-s"))
        );

        (uint256 r0After, uint256 r1After) = hook.reserveBalances(id);
        assertGe(r0After, r0, "A-06: same-block sandwich must not draw reserve0");
        assertGe(r1After, r1, "A-06: same-block sandwich must not draw reserve1");
    }

    /// @notice R2-01 (mirror of A-06): a junior cannot self-sandwich its exit - crash happens in an earlier
    ///         block (real IL), then the junior pumps the price back toward entry and exits in the same
    ///         block. The anchor-guarded settlement charges max(IL at exit, IL at anchor), so the clawback
    ///         still fires even though the spot price at exit shows (almost) no IL.
    function test_R201_juniorSelfSandwich_cannotSuppressILClawback() public {
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -6000, tickUpper: 6000, liquidityDelta: 1e21, salt: bytes32("r201-j")
            }),
            abi.encode(TrancheType.JUNIOR, bytes32("r201-j"))
        );

        // Block N: genuine crash. The junior position now carries real IL.
        swapRouterNoChecks.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -int256(1e25), sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(-5940)
            })
        );
        vm.roll(block.number + 1);

        // Block N+1: self-sandwich front-leg pumps the price back toward entry (the swap records the
        // crashed price as this block's anchor first), then the junior exits at the manipulated spot.
        swapRouterNoChecks.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: false, amountSpecified: -int256(1e25), sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(0)
            })
        );

        vm.recordLogs();
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -6000, tickUpper: 6000, liquidityDelta: -1e21, salt: bytes32("r201-j")
            }),
            abi.encode(TrancheType.JUNIOR, bytes32("r201-j"))
        );

        // The anchor-guarded IL must be charged despite the spot price sitting back near entry.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("TrancheSettled(bytes32,bytes32,address,uint8,uint256,uint256)");
        uint256 ilCharged = 0;
        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) {
                (,, ilCharged) = abi.decode(logs[i].data, (uint8, uint256, uint256));
                found = true;
                break;
            }
        }
        assertTrue(found, "TrancheSettled emitted");
        assertGt(ilCharged, 0, "R2-01: junior self-sandwich must not suppress the IL charge");
    }
}
