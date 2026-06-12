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
import { StratumErrors } from "../../src/StratumErrors.sol";
import { PoolInitParams, TrancheType } from "../../src/StratumTypes.sol";
import { IStratumHook } from "../../src/interfaces/IStratumHook.sol";
import { TrancheIntentRegistry } from "../../src/peripherals/reactive/TrancheIntentRegistry.sol";
import { IntentSettlerRSC } from "../../src/peripherals/reactive/IntentSettlerRSC.sol";
import { HookMiner } from "../utils/HookMiner.sol";
import { StratumFlags } from "../utils/StratumFlags.sol";

/// @title TrancheIntentTest
/// @notice FR-30: LP conditional intents. Proves registration auth, condition evaluation against on-chain hook
///         state (no oracle), execution through the hook's checked migration, the approval requirement, and the
///         RSC-driven keeper-free sweep.
contract TrancheIntentTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    StratumHook hook;
    TrancheIntentRegistry registry;
    IntentSettlerRSC settler;
    PoolInitParams params;
    PoolId id;
    address internal owner; // v4 callback sender == modify-liquidity router
    address internal constant OPERATOR = address(0x09E7A704);

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
        id = key.toId();
        owner = address(modifyLiquidityRouter);

        registry = new TrancheIntentRegistry(IStratumHook(address(hook)));
        settler = new IntentSettlerRSC(registry, address(hook), OPERATOR, block.chainid);
    }

    function _deposit(TrancheType tranche, bytes32 tag) internal returns (bytes32 positionId) {
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, abi.encode(tranche, tag));
        positionId = keccak256(abi.encode(owner, LIQUIDITY_PARAMS.tickLower, LIQUIDITY_PARAMS.tickUpper, tag));
    }

    function _arm(bytes32 positionId, TrancheType to, TrancheIntentRegistry.ConditionType ct, uint256 threshold)
        internal
        returns (uint256 intentId)
    {
        vm.prank(owner);
        hook.approveMigrator(positionId, address(registry));
        vm.prank(owner);
        intentId = registry.registerIntent(positionId, id, to, ct, threshold);
    }

    // --- registration ---------------------------------------------------------------------------------

    function test_register_onlyPositionOwner() public {
        bytes32 jA = _deposit(TrancheType.JUNIOR, bytes32("jA"));
        vm.prank(address(0xBEEF));
        vm.expectRevert(TrancheIntentRegistry.NotIntentOwner.selector);
        registry.registerIntent(jA, id, TrancheType.SENIOR, TrancheIntentRegistry.ConditionType.COVERAGE_ABOVE, 5000);
    }

    function test_register_sameTrancheReverts() public {
        bytes32 jA = _deposit(TrancheType.JUNIOR, bytes32("jA"));
        vm.prank(owner);
        vm.expectRevert(TrancheIntentRegistry.SameTranche.selector);
        registry.registerIntent(jA, id, TrancheType.JUNIOR, TrancheIntentRegistry.ConditionType.COVERAGE_ABOVE, 5000);
    }

    /// @notice Audit L-02: the intent must bind to the position's real pool, not a caller-supplied mismatch.
    function test_register_poolIdMismatchReverts() public {
        bytes32 jA = _deposit(TrancheType.JUNIOR, bytes32("jA"));
        PoolId wrongPool = PoolId.wrap(bytes32("wrong-pool"));
        vm.prank(owner);
        vm.expectRevert(TrancheIntentRegistry.PoolIdMismatch.selector);
        registry.registerIntent(
            jA, wrongPool, TrancheType.SENIOR, TrancheIntentRegistry.ConditionType.COVERAGE_ABOVE, 5000
        );
    }

    // --- condition evaluation + execution -------------------------------------------------------------

    /// @notice COVERAGE_ABOVE: with no senior yet, coverage is "infinite" so the condition holds; executing the
    ///         intent flips a junior to senior through the hook's checked migration.
    function test_execute_coverageAbove_migratesJuniorToSenior() public {
        bytes32 jA = _deposit(TrancheType.JUNIOR, bytes32("jA"));
        _deposit(TrancheType.JUNIOR, bytes32("jB"));

        uint256 intentId = _arm(jA, TrancheType.SENIOR, TrancheIntentRegistry.ConditionType.COVERAGE_ABOVE, 5000);
        assertTrue(registry.conditionMet(intentId), "coverage above threshold");

        registry.executeIntent(intentId); // permissionless
        assertEq(uint8(hook.position(jA).tranche), uint8(TrancheType.SENIOR), "migrated to senior");
        assertFalse(registry.conditionMet(intentId), "intent consumed (inactive)");
    }

    /// @notice SENIOR_APY_BELOW reads the senior target APY (internal accounting, no oracle) to flip a senior
    ///         back to junior when its fixed yield thins.
    function test_execute_seniorApyBelow_migratesSeniorToJunior() public {
        _deposit(TrancheType.JUNIOR, bytes32("jA"));
        _deposit(TrancheType.JUNIOR, bytes32("jB"));
        bytes32 sA = _deposit(TrancheType.SENIOR, bytes32("sA"));

        // targetAPYBps == 500; threshold 1000 -> 500 < 1000 -> armed.
        uint256 intentId = _arm(sA, TrancheType.JUNIOR, TrancheIntentRegistry.ConditionType.SENIOR_APY_BELOW, 1000);
        assertTrue(registry.conditionMet(intentId));

        registry.executeIntent(intentId);
        assertEq(uint8(hook.position(sA).tranche), uint8(TrancheType.JUNIOR), "migrated to junior");
    }

    function test_execute_conditionNotMet_reverts() public {
        bytes32 jA = _deposit(TrancheType.JUNIOR, bytes32("jA"));
        _deposit(TrancheType.JUNIOR, bytes32("jB"));
        // COVERAGE_BELOW 3000 with no senior -> coverage is max -> NOT below -> condition false.
        uint256 intentId = _arm(jA, TrancheType.SENIOR, TrancheIntentRegistry.ConditionType.COVERAGE_BELOW, 3000);
        vm.expectRevert(TrancheIntentRegistry.ConditionNotMet.selector);
        registry.executeIntent(intentId);
    }

    /// @notice Without the LP's `approveMigrator`, the hook rejects the registry's migration and the intent
    ///         stays armed (the one-shot effect is rolled back with the revert).
    function test_execute_withoutApproval_revertsAndStaysArmed() public {
        bytes32 jA = _deposit(TrancheType.JUNIOR, bytes32("jA"));
        _deposit(TrancheType.JUNIOR, bytes32("jB"));
        vm.prank(owner);
        uint256 intentId = registry.registerIntent(
            jA, id, TrancheType.SENIOR, TrancheIntentRegistry.ConditionType.COVERAGE_ABOVE, 5000
        );

        vm.expectRevert(StratumErrors.Unauthorized.selector);
        registry.executeIntent(intentId);
        assertTrue(registry.conditionMet(intentId), "intent still armed after failed execution");
    }

    function test_cancel_disarmsIntent() public {
        bytes32 jA = _deposit(TrancheType.JUNIOR, bytes32("jA"));
        _deposit(TrancheType.JUNIOR, bytes32("jB"));
        uint256 intentId = _arm(jA, TrancheType.SENIOR, TrancheIntentRegistry.ConditionType.COVERAGE_ABOVE, 5000);

        vm.prank(owner);
        registry.cancelIntent(intentId);
        assertFalse(registry.conditionMet(intentId), "cancelled");
        vm.expectRevert(TrancheIntentRegistry.IntentInactive.selector);
        registry.executeIntent(intentId);
    }

    // --- RSC-driven sweep (keeper-free) ---------------------------------------------------------------

    function test_settlerSweep_executesReadyIntents() public {
        bytes32 jA = _deposit(TrancheType.JUNIOR, bytes32("jA"));
        _deposit(TrancheType.JUNIOR, bytes32("jB"));
        _arm(jA, TrancheType.SENIOR, TrancheIntentRegistry.ConditionType.COVERAGE_ABOVE, 5000);

        vm.prank(OPERATOR);
        settler.sweepIntents(id);
        assertEq(uint8(hook.position(jA).tranche), uint8(TrancheType.SENIOR), "RSC sweep migrated the position");
    }

    function test_settlerSweep_onlyOperator() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(IntentSettlerRSC.OnlyOperator.selector);
        settler.sweepIntents(id);
    }

    /// @notice A sweep isolates a failing intent (no approval) and reports zero executed, leaving it armed.
    function test_settlerSweep_isolatesFailingIntent() public {
        bytes32 jA = _deposit(TrancheType.JUNIOR, bytes32("jA"));
        _deposit(TrancheType.JUNIOR, bytes32("jB"));
        vm.prank(owner);
        uint256 intentId = registry.registerIntent(
            jA, id, TrancheType.SENIOR, TrancheIntentRegistry.ConditionType.COVERAGE_ABOVE, 5000
        );

        vm.prank(OPERATOR);
        settler.sweepIntents(id); // intent has no migrator approval -> caught, not reverted
        assertTrue(registry.conditionMet(intentId), "failing intent left armed by the sweep");
    }
}
