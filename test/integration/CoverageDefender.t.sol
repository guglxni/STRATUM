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
import { PoolInitParams, PoolTrancheState, TrancheType } from "../../src/StratumTypes.sol";
import { CoverageDefender } from "../../src/peripherals/reactive/CoverageDefender.sol";
import { IReserveRebalanceTarget } from "../../src/peripherals/reactive/IReserveRebalanceTarget.sol";
import { IReactive } from "../../src/peripherals/reactive/IReactive.sol";
import { AbstractReactive } from "../../src/peripherals/reactive/AbstractReactive.sol";
import { CoverageRatio } from "../../src/libraries/CoverageRatio.sol";
import { HookMiner } from "../utils/HookMiner.sol";
import { StratumFlags } from "../utils/StratumFlags.sol";

/// @notice Records requestRebalance calls from the CoverageDefender.
contract MockRebalanceTarget is IReserveRebalanceTarget {
    uint256 public calls;
    int256 public lastDivergence;

    function requestRebalance(PoolId, int256 divergence) external {
        calls += 1;
        lastDivergence = divergence;
    }
}

contract CoverageDefenderTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    StratumHook hook;
    CoverageDefender defender;
    MockRebalanceTarget target;

    // Active band parameters: wide spread so a normal deposit (ratio~10000) lands well below trigger (60000),
    // causing remediationScaleBps > 0 when we call _defend.
    //   minCoverageRatioBps=100, coverageTriggerBps=60000, coverageTargetBps=65000
    // With equal junior and senior deposits ratio = juniorTVL * 10000 / seniorTVL ~ 10000 < 60000 -> scale>0.
    uint16 constant FLOOR_BPS = 100;
    uint16 constant TRIGGER_BPS = 60_000;
    uint16 constant TARGET_BPS = 65_000;

    PoolKey keyA; // active band, defender wired as peripheralRegistry
    PoolId idA;

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _buildParams(address registry, uint16 floor, uint16 trigger, uint16 target_)
        internal
        pure
        returns (PoolInitParams memory)
    {
        return PoolInitParams({
            targetAPYBps: 500,
            minCoverageRatioBps: floor,
            maxSeniorILExposureBps: 500,
            smoothingEpochSeconds: 1 days,
            baseFeeBps: 30,
            minFeeBps: 5,
            maxFeeBps: 200,
            protocolFeeBps: 100,
            peripheralRegistry: registry,
            coverageTriggerBps: trigger,
            coverageTargetBps: target_
        });
    }

    /// @dev Mine + deploy the hook once. No per-test re-deployment needed for most tests.
    function _deployHook() internal {
        (address hookAddr, bytes32 salt) = HookMiner.find(
            address(this), StratumFlags.STRATUM_HOOK_FLAGS, type(StratumHook).creationCode, abi.encode(address(manager))
        );
        hook = new StratumHook{ salt: salt }(IPoolManager(address(manager)));
        assertEq(address(hook), hookAddr);
    }

    /// @dev Initialize pool `k` using the supplied params and do a junior + senior deposit so both TVLs > 0.
    ///      Uses different salts so positions never collide.
    function _initPoolAndDeposit(PoolKey memory k, PoolInitParams memory p, bytes32 jSalt, bytes32 sSalt) internal {
        hook.preparePool(k, p);
        manager.initialize(k, SQRT_PRICE_1_1);
        // Junior deposit first so senior intake check passes (juniorTVL > 0 when senior arrives).
        modifyLiquidityRouter.modifyLiquidity(k, LIQUIDITY_PARAMS, abi.encode(TrancheType.JUNIOR, jSalt));
        modifyLiquidityRouter.modifyLiquidity(k, LIQUIDITY_PARAMS, abi.encode(TrancheType.SENIOR, sSalt));
    }

    // -------------------------------------------------------------------------
    // setUp
    // -------------------------------------------------------------------------

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        _deployHook();

        // Deploy the defender (operator = address(this)).
        defender = new CoverageDefender(IStratumHook(address(hook)), address(this), block.chainid);

        // Deploy the mock rebalance target and configure the defender.
        target = new MockRebalanceTarget();
        defender.configure(IReserveRebalanceTarget(address(target)), address(0));

        // Build pool A: active band, defender wired as peripheralRegistry.
        keyA = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        idA = keyA.toId();

        PoolInitParams memory paramsA = _buildParams(address(defender), FLOOR_BPS, TRIGGER_BPS, TARGET_BPS);
        _initPoolAndDeposit(keyA, paramsA, bytes32("j"), bytes32("s"));
    }

    // -------------------------------------------------------------------------
    // Test 1: defend fires graduated request when ratio < triggerBps
    // -------------------------------------------------------------------------

    function test_defend_firesGraduatedRequestInBand() public {
        PoolTrancheState memory pool = hook.poolState(idA);
        uint16 ratio = CoverageRatio.ratioBps(pool.juniorTVL, pool.seniorTVL);

        // Sanity: ratio must be below the trigger for remediation scale > 0.
        assertLt(ratio, TRIGGER_BPS, "ratio should be below trigger for this test");

        uint256 callsBefore = target.calls();
        defender.defend(idA);

        assertEq(target.calls(), callsBefore + 1, "requestRebalance must be called once");
        assertLt(target.lastDivergence(), int256(0), "inflow ask must be negative (local deficit)");
    }

    // -------------------------------------------------------------------------
    // Test 2: degenerate band -> scale == 0 -> no request
    // -------------------------------------------------------------------------

    function test_defend_healthyBandNoRequest() public {
        // Build a second pool with a degenerate band (trigger == floor == 100).
        // After junior + senior deposits ratio ~ 10000 >> floor=100 -> scale == 0.
        PoolKey memory keyB = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 120,
            hooks: IHooks(address(hook))
        });
        PoolId idB = keyB.toId();

        // Degenerate band: floor == trigger == target == FLOOR_BPS (100).
        // Validation requires floor <= trigger <= target, so all equal is valid.
        PoolInitParams memory paramsB = _buildParams(address(0), FLOOR_BPS, FLOOR_BPS, FLOOR_BPS);
        _initPoolAndDeposit(keyB, paramsB, bytes32("jB"), bytes32("sB"));

        uint256 callsBefore = target.calls();
        defender.defend(idB);
        assertEq(target.calls(), callsBefore, "no request when scale == 0 (degenerate band)");
    }

    // -------------------------------------------------------------------------
    // Test 3: onCoverageStress in-band push drives _defend
    // -------------------------------------------------------------------------

    function test_onCoverageStress_inbandDrivesDefense() public {
        uint256 callsBefore = target.calls();
        // Simulate the hook pushing a coverage-stress notification.
        defender.onCoverageStress(idA, 5000);
        assertEq(target.calls(), callsBefore + 1, "onCoverageStress must drive a remediation request");
    }

    // -------------------------------------------------------------------------
    // Test 4: onEpochClose re-assesses and calls requestRebalance
    // -------------------------------------------------------------------------

    function test_onEpochClose_reassesses() public {
        uint256 callsBefore = target.calls();
        bytes memory result = defender.onEpochClose(idA, 1, "");
        assertEq(result.length, 0, "onEpochClose must return empty bytes");
        assertEq(target.calls(), callsBefore + 1, "onEpochClose must drive a remediation request");
    }

    // -------------------------------------------------------------------------
    // Test 5: setEnabled(false) disables requests; re-enabling fires again
    // -------------------------------------------------------------------------

    function test_setEnabled_disablesRequests() public {
        // Disable: assess-only, no requestRebalance.
        defender.setEnabled(false);
        uint256 callsBefore = target.calls();
        defender.defend(idA);
        assertEq(target.calls(), callsBefore, "requests must be suppressed when disabled");

        // Re-enable: should fire again.
        defender.setEnabled(true);
        defender.defend(idA);
        assertEq(target.calls(), callsBefore + 1, "requests must resume after re-enabling");
    }

    // -------------------------------------------------------------------------
    // Test 6: defend is operator-gated
    // -------------------------------------------------------------------------

    function test_defend_onlyOperator() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(CoverageDefender.OnlyOperator.selector);
        defender.defend(idA);
    }

    // -------------------------------------------------------------------------
    // Test 7: react schedules a reactiveCallback via the Callback event
    // -------------------------------------------------------------------------

    function test_react_schedulesCallback() public {
        IReactive.LogRecord memory log;
        log.chainId = block.chainid;
        log._contract = address(hook);
        log.topic_1 = uint256(PoolId.unwrap(idA));

        bytes memory expected = abi.encodeWithSelector(CoverageDefender.reactiveCallback.selector, idA);
        vm.expectEmit(true, true, true, true);
        emit AbstractReactive.Callback(block.chainid, address(defender), 350_000, expected);
        // On a plain EVM (no system contract) react() requires msg.sender == operator.
        defender.react(log);
    }
}
