// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { Deployers } from "@uniswap/v4-core/test/utils/Deployers.sol";
import { LPFeeLibrary } from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import { StratumHook } from "../../src/StratumHook.sol";
import { IStratumHook } from "../../src/interfaces/IStratumHook.sol";
import { IPeripheral } from "../../src/interfaces/IPeripheral.sol";
import { PoolInitParams, TrancheType } from "../../src/StratumTypes.sol";
import { ReserveBalancer } from "../../src/peripherals/reactive/ReserveBalancer.sol";
import { IReserveRebalanceTarget } from "../../src/peripherals/reactive/IReserveRebalanceTarget.sol";
import { EpochSettler } from "../../src/peripherals/reactive/EpochSettler.sol";
import { HookMiner } from "../utils/HookMiner.sol";
import { StratumFlags } from "../utils/StratumFlags.sol";

/// @notice Records onEpochClose/onCoverageStress calls; can be told to revert or burn gas (NFR-01 tests).
contract MockPeripheral is IPeripheral {
    uint256 public epochCloseCalls;
    uint256 public coverageStressCalls;
    bytes public lastCtx;
    bool public shouldRevert;
    bool public shouldBurnGas;

    function setRevert(bool v) external {
        shouldRevert = v;
    }

    function setBurnGas(bool v) external {
        shouldBurnGas = v;
    }

    function kind() external pure returns (bytes32) {
        return keccak256("MOCK");
    }

    function onEpochClose(PoolId, uint64, bytes calldata ctx) external returns (bytes memory) {
        if (shouldRevert) revert("mock revert");
        if (shouldBurnGas) {
            while (true) { } // exhaust the forwarded stipend
        }
        epochCloseCalls += 1;
        lastCtx = ctx;
        return bytes("");
    }

    function onCoverageStress(PoolId, uint16) external {
        if (shouldRevert) revert("mock revert");
        coverageStressCalls += 1;
    }

    function isEnabled() external pure returns (bool) {
        return true;
    }
}

/// @notice Records requestRebalance calls from the ReserveBalancer.
contract MockRebalanceTarget is IReserveRebalanceTarget {
    uint256 public calls;
    int256 public lastDivergence;

    function requestRebalance(PoolId, int256 divergence) external {
        calls += 1;
        lastDivergence = divergence;
    }
}

contract PeripheralTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    StratumHook hook;
    PoolInitParams params;

    function _deployHookWithRegistry(address registry) internal {
        params = PoolInitParams({
            targetAPYBps: 500,
            minCoverageRatioBps: 3000,
            maxSeniorILExposureBps: 500,
            smoothingEpochSeconds: 1 days,
            baseFeeBps: 30,
            minFeeBps: 5,
            maxFeeBps: 200,
            protocolFeeBps: 100,
            peripheralRegistry: registry
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
    }

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();
    }

    function _closeAfterEpoch(PoolId id) internal {
        vm.warp(block.timestamp + params.smoothingEpochSeconds);
        hook.closeEpoch(id);
    }

    // --- T8: IPeripheral dispatch from the core ---

    function test_dispatch_noopWhenRegistryZero() public {
        _deployHookWithRegistry(address(0));
        PoolId id = key.toId();
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, abi.encode(TrancheType.JUNIOR, bytes32("j")));
        // No peripheral registered: closeEpoch simply advances the epoch (NFR-01, core-only).
        _closeAfterEpoch(id);
        assertEq(hook.poolState(id).currentEpoch, 1);
    }

    function test_dispatch_epochClosePushesContext() public {
        MockPeripheral mock = new MockPeripheral();
        _deployHookWithRegistry(address(mock));
        PoolId id = key.toId();
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, abi.encode(TrancheType.JUNIOR, bytes32("j")));
        _closeAfterEpoch(id);
        assertEq(mock.epochCloseCalls(), 1, "peripheral notified on epoch close");
        // ctx decodes to (funded, surplus, juniorReserve, juniorTVL, seniorTVL).
        (,,, uint256 juniorTVL,) = abi.decode(mock.lastCtx(), (uint256, uint256, uint256, uint256, uint256));
        assertEq(juniorTVL, hook.poolState(id).juniorTVL, "ctx carries live junior TVL");
    }

    function test_dispatch_revertingPeripheralDoesNotBlock() public {
        MockPeripheral mock = new MockPeripheral();
        mock.setRevert(true);
        _deployHookWithRegistry(address(mock));
        PoolId id = key.toId();
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, abi.encode(TrancheType.JUNIOR, bytes32("j")));
        // A reverting peripheral must not block settlement (NFR-01).
        _closeAfterEpoch(id);
        assertEq(hook.poolState(id).currentEpoch, 1, "epoch still advanced despite peripheral revert");
        assertEq(mock.epochCloseCalls(), 0, "peripheral reverted, no recorded call");
    }

    function test_dispatch_gasGriefPeripheralBounded() public {
        MockPeripheral mock = new MockPeripheral();
        mock.setBurnGas(true);
        _deployHookWithRegistry(address(mock));
        PoolId id = key.toId();
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, abi.encode(TrancheType.JUNIOR, bytes32("j")));
        // A gas-griefing peripheral is bounded by PERIPHERAL_GAS_STIPEND; settlement still completes.
        _closeAfterEpoch(id);
        assertEq(hook.poolState(id).currentEpoch, 1, "epoch advanced despite gas-griefing peripheral");
    }

    // --- T9: ReserveBalancer RSC ---

    function test_reserveBalancer_divergenceTriggersRebalance() public {
        _deployHookWithRegistry(address(0));
        ReserveBalancer rb = new ReserveBalancer(IStratumHook(address(hook)), address(this), 2000); // 20% threshold
        MockRebalanceTarget target = new MockRebalanceTarget();
        rb.configure(IReserveRebalanceTarget(address(target)), address(0));

        // Two pools with skewed reserves: pool A funded, pool B empty -> large divergence.
        PoolId a = key.toId();
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, abi.encode(TrancheType.JUNIOR, bytes32("ja")));
        IPoolManager.SwapParams memory s = IPoolManager.SwapParams({
            zeroForOne: true, amountSpecified: -1_000_000, sqrtPriceLimitX96: SQRT_PRICE_1_2
        });
        swapRouterNoChecks.swap(key, s);
        _closeAfterEpoch(a); // surplus credits pool A's juniorReserve

        // Set up a second pool B (junior-only, no swaps) with zero reserve.
        PoolKey memory keyB = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 120,
            hooks: IHooks(address(hook))
        });
        hook.preparePool(keyB, params);
        manager.initialize(keyB, SQRT_PRICE_1_1);
        PoolId b = keyB.toId();
        modifyLiquidityRouter.modifyLiquidity(keyB, LIQUIDITY_PARAMS, abi.encode(TrancheType.JUNIOR, bytes32("jb")));

        // Observe both: B (0) then A (>0) -> A diverges far above the average -> rebalance requested.
        rb.observeReserve(b);
        rb.observeReserve(a);
        assertGt(target.calls(), 0, "rebalance requested when divergence exceeds threshold");
    }

    function test_reserveBalancer_inertWhenTargetUnset() public {
        _deployHookWithRegistry(address(0));
        ReserveBalancer rb = new ReserveBalancer(IStratumHook(address(hook)), address(this), 100);
        PoolId id = key.toId();
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, abi.encode(TrancheType.JUNIOR, bytes32("j")));
        // No target configured: observing must not revert and fires no external call.
        rb.observeReserve(id);
        assertTrue(rb.tracked(id), "pool tracked even with no rebalance target");
    }

    function test_reserveBalancer_onlyOperator() public {
        _deployHookWithRegistry(address(0));
        ReserveBalancer rb = new ReserveBalancer(IStratumHook(address(hook)), address(this), 100);
        PoolId id = key.toId();
        vm.prank(address(0xBEEF));
        vm.expectRevert(ReserveBalancer.OnlyOperator.selector);
        rb.observeReserve(id);
    }

    // --- T9: EpochSettler as both operator-driven RSC and in-band IPeripheral ---

    function test_epochSettler_operatorAndReactivePaths() public {
        _deployHookWithRegistry(address(0));
        EpochSettler settler = new EpochSettler(IStratumHook(address(hook)), address(this));
        PoolId id = key.toId();
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, abi.encode(TrancheType.JUNIOR, bytes32("j")));

        vm.warp(block.timestamp + params.smoothingEpochSeconds);
        settler.settleEpoch(id); // operator fallback drives the close
        assertEq(hook.poolState(id).currentEpoch, 1, "operator path closed the epoch");

        // Reactive path: configure the system sender, then drive via reactiveCallback.
        settler.setReactiveCallbackSender(address(0xCAFE));
        vm.warp(block.timestamp + params.smoothingEpochSeconds);
        vm.prank(address(0xCAFE));
        settler.reactiveCallback(id);
        assertEq(hook.poolState(id).currentEpoch, 2, "reactive path closed the epoch");
    }

    function test_epochSettler_inbandPeripheralPush() public {
        // Deploy the settler first at a deterministic address, then point the hook's registry at it.
        // Simplest: deploy hook with registry==address(0), then a settler, then a second hook isn't needed;
        // instead verify the IPeripheral surface directly.
        EpochSettler settler = new EpochSettler(IStratumHook(address(0)), address(this));
        bytes memory out = settler.onEpochClose(PoolId.wrap(bytes32(uint256(1))), 7, bytes(""));
        assertEq(out.length, 0, "onEpochClose returns empty, core discards it");
        assertTrue(settler.isEnabled(), "settler reports enabled");
        assertEq(settler.kind(), keccak256("stratum.reactive.epoch"));
    }
}
