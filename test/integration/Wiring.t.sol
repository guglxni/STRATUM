// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { Deployers } from "@uniswap/v4-core/test/utils/Deployers.sol";
import { LPFeeLibrary } from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";

import { StratumHook } from "../../src/StratumHook.sol";
import { IStratumHook } from "../../src/interfaces/IStratumHook.sol";
import { StratumErrors } from "../../src/StratumErrors.sol";
import { PoolInitParams, TrancheType } from "../../src/StratumTypes.sol";
import { HookMiner } from "../utils/HookMiner.sol";
import { StratumFlags } from "../utils/StratumFlags.sol";

/// @notice Minimal Chainlink AggregatorV3 mock for FR-25.
contract MockFeed {
    int256 internal answer;
    uint8 internal dec;

    constructor(int256 answer_, uint8 dec_) {
        answer = answer_;
        dec = dec_;
    }

    function decimals() external view returns (uint8) {
        return dec;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, block.timestamp, block.timestamp, 1);
    }
}

/// @notice Volatility source mock returning a fixed override (view, matching the real shim's signature, BS3).
contract MockVolSource {
    uint256 public immutable value;

    constructor(uint256 v) {
        value = v;
    }

    function getVolatilityOverride(PoolId) external view returns (uint256) {
        return value;
    }
}

/// @notice FR-25 (Chainlink rate), FR-18 (same-chain reserve aggregation), and BS3 (Stylus volatility) wiring.
contract WiringTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

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
        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        hook.preparePool(key, params);
        manager.initialize(key, SQRT_PRICE_1_1);
    }

    // --- FR-25: Chainlink benchmark rate ---

    function test_FR25_refreshRaisesTargetAPYFromBenchmark() public {
        PoolId id = key.toId();
        assertEq(hook.poolState(id).targetAPYBps, 500, "starts at configured floor");

        // 8% benchmark (8e6 at 8 decimals -> 800 bps) + 100 bps spread = 900 bps > 500 floor.
        MockFeed feed = new MockFeed(8_000_000, 8);
        // 0/0 bounds => library defaults (MAX_BENCHMARK_BPS ceiling, 25h staleness).
        hook.setSeniorRateFeed(id, address(feed), 100, 0, 0);
        hook.refreshSeniorRate(id);

        assertEq(hook.poolState(id).targetAPYBps, 900, "rate raised to benchmark + spread (FR-25)");
        // Obligation = seniorTVL * rate * epoch / year; with no senior deposit here seniorTVL == 0, so the
        // obligation is 0 regardless of rate. The rate change above is the FR-25 assertion.
    }

    function test_FR25_staleOrNoFeed_keepsFloor_goldenRule2() public {
        PoolId id = key.toId();
        // No feed configured: refresh is a no-op, rate stays at the floor (golden rule 2 - IL never affected).
        hook.refreshSeniorRate(id);
        assertEq(hook.poolState(id).targetAPYBps, 500, "no feed -> floor unchanged");
    }

    function test_FR25_setFeed_onlyPoolCreator() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(StratumErrors.Unauthorized.selector);
        hook.setSeniorRateFeed(key.toId(), address(0xFEED), 100, 0, 0);
    }

    // --- FR-18: same-chain reserve aggregation (real ledger move) ---

    function test_FR18_rebalanceReserve_movesLedgerBetweenPools_gated() public {
        // Second pool B on the same hook (same creator = this).
        PoolKey memory keyB = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 120,
            hooks: IHooks(address(hook))
        });
        hook.preparePool(keyB, params);
        manager.initialize(keyB, SQRT_PRICE_1_1);
        PoolId a = key.toId();
        PoolId b = keyB.toId();

        // Fund pool A's reserve: register this contract as A's yield source, send tokens, credit.
        hook.setReserveYieldSource(a, address(this));
        MockERC20(Currency.unwrap(currency0)).transfer(address(hook), 100e18);
        MockERC20(Currency.unwrap(currency1)).transfer(address(hook), 40e18);
        hook.creditReserve(a, 100e18, 40e18);

        // Register this contract as A's rebalancer, then move part of A's reserve into B.
        hook.setReserveRebalancer(a, address(this));
        hook.rebalanceReserve(a, b, 30e18, 10e18);

        (uint256 a0, uint256 a1) = hook.reserveBalances(a);
        (uint256 b0, uint256 b1) = hook.reserveBalances(b);
        assertEq(a0, 70e18, "donor reserve0 debited");
        assertEq(a1, 30e18, "donor reserve1 debited");
        assertEq(b0, 30e18, "recipient reserve0 credited");
        assertEq(b1, 10e18, "recipient reserve1 credited");
        // INV-03: total reserve conserved across the move.
        assertEq(a0 + b0, 100e18, "total reserve0 conserved");
        assertEq(a1 + b1, 40e18, "total reserve1 conserved");
    }

    function test_FR18_rebalanceReserve_onlyRegisteredRebalancer() public {
        PoolId a = key.toId();
        vm.prank(address(0xBAD));
        vm.expectRevert(StratumErrors.Unauthorized.selector);
        hook.rebalanceReserve(a, a, 1, 0);
    }

    function test_FR18_rebalanceReserve_cannotOverdraw() public {
        PoolId a = key.toId();
        hook.setReserveRebalancer(a, address(this));
        // Donor reserve is empty; drawing reverts (no negative reserves, INV-03).
        vm.expectRevert(StratumErrors.ConservationViolation.selector);
        hook.rebalanceReserve(a, a, 1e18, 0);
    }

    // --- BS3: Stylus volatility override consumed in beforeSwap ---

    function test_BS3_volatilityOverrideRaisesFeeToMax() public {
        PoolId id = key.toId();
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, abi.encode(TrancheType.JUNIOR, bytes32("v")));
        IPoolManager.SwapParams memory s = IPoolManager.SwapParams({
            zeroForOne: true, amountSpecified: -10_000, sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(-120)
        });

        // A huge forward-vol override (1e18) drives the dynamic fee to maxFeeBps (200). With swapAmount 10_000
        // the raw fee is 10_000 * 200 / 10_000 == 200; the protocol share (A-15: protocolFeeBps = 100 -> 2)
        // is carved out before the epoch accumulator, leaving 198 (vs ~30 at the base fee with no override).
        MockVolSource vs = new MockVolSource(1e18);
        hook.setVolatilitySource(id, address(vs));
        swapRouterNoChecks.swap(key, s);
        assertEq(hook.poolState(id).epochAccumulatedFees, 198, "override raised fee to maxFeeBps (BS3)");
        assertEq(hook.protocolFeesAccrued(id), 2, "protocol share carved out of the accumulator (A-15)");
    }

    function test_BS3_setVolatilitySource_onlyPoolCreator() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(StratumErrors.Unauthorized.selector);
        hook.setVolatilitySource(key.toId(), address(0xBEEF));
    }
}
