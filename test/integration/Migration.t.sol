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

import { StratumHook } from "../../src/StratumHook.sol";
import { StratumErrors } from "../../src/StratumErrors.sol";
import { PoolInitParams, TrancheType } from "../../src/StratumTypes.sol";
import { CoverageRatio } from "../../src/libraries/CoverageRatio.sol";
import { TrancheToken } from "../../src/TrancheToken.sol";
import { HookMiner } from "../utils/HookMiner.sol";
import { StratumFlags } from "../utils/StratumFlags.sol";

/// @title MigrationTest
/// @notice FR-30/FR-31: in-place tranche migration. Proves the invariants the migration path must preserve:
///         conservation (INV-03), coverage floor on junior->senior (INV-01), IL realized under the source
///         tranche (golden rule 3, no IL-dodging), and owner/approved-migrator authorization (FR-30).
contract MigrationTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    StratumHook hook;
    PoolInitParams params;
    PoolId id;

    // The v4 callback `sender` (and therefore every position's owner) is the modify-liquidity router.
    address internal owner;

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
    }

    // --- helpers ---------------------------------------------------------------------------------------

    function _deposit(TrancheType tranche, bytes32 tag) internal returns (bytes32 positionId) {
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, abi.encode(tranche, tag));
        positionId = keccak256(abi.encode(owner, LIQUIDITY_PARAMS.tickLower, LIQUIDITY_PARAMS.tickUpper, tag));
    }

    function _movePrice() internal {
        IPoolManager.SwapParams memory s = IPoolManager.SwapParams({
            zeroForOne: true, amountSpecified: -200_000, sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(-600)
        });
        swapRouterNoChecks.swap(key, s);
    }

    function _seniorTok() internal view returns (TrancheToken) {
        return TrancheToken(hook.poolState(id).seniorToken);
    }

    function _juniorTok() internal view returns (TrancheToken) {
        return TrancheToken(hook.poolState(id).juniorToken);
    }

    // --- conservation ----------------------------------------------------------------------------------

    /// @notice INV-03: with no price move, a migration carries the principal across 1:1 and the aggregate
    ///         receipt-token supply is conserved (old burned, new minted, no value conjured).
    function test_migrate_conservation_noValueCreated() public {
        bytes32 jA = _deposit(TrancheType.JUNIOR, bytes32("jA"));
        _deposit(TrancheType.JUNIOR, bytes32("jB"));

        uint256 oldPrincipal = hook.position(jA).principalValue;
        uint256 juniorSupplyBefore = _juniorTok().totalSupply();

        vm.prank(owner);
        uint256 carried = hook.migrateTranchePosition(jA, TrancheType.SENIOR);

        assertEq(carried, oldPrincipal, "no IL: carried == old principal exactly");
        assertLe(carried, oldPrincipal, "INV-03: migration never creates value");
        // The migrated principal left the junior token and reappeared 1:1 as senior token.
        assertEq(_seniorTok().totalSupply(), oldPrincipal, "senior receipt minted for carried principal");
        assertEq(
            _juniorTok().totalSupply(), juniorSupplyBefore - oldPrincipal, "junior receipt burned for old principal"
        );
    }

    /// @notice The migrated position keeps its identity (same positionId, owner, liquidity) but flips tranche.
    function test_migrate_reclassifiesInPlace() public {
        bytes32 jA = _deposit(TrancheType.JUNIOR, bytes32("jA"));
        _deposit(TrancheType.JUNIOR, bytes32("jB"));

        uint128 liqBefore = hook.position(jA).liquidity;
        vm.prank(owner);
        hook.migrateTranchePosition(jA, TrancheType.SENIOR);

        assertEq(uint8(hook.position(jA).tranche), uint8(TrancheType.SENIOR), "tranche flipped");
        assertEq(hook.position(jA).owner, owner, "same owner");
        assertEq(hook.position(jA).liquidity, liqBefore, "underlying liquidity untouched");
    }

    // --- coverage floor (INV-01) ----------------------------------------------------------------------

    /// @notice INV-01: a junior->senior flip that would drop coverage below the floor reverts. A lone junior
    ///         migrating to senior takes junior TVL to zero -> ratio 0 < 3000 floor.
    function test_migrate_juniorToSenior_belowFloor_reverts() public {
        bytes32 jSolo = _deposit(TrancheType.JUNIOR, bytes32("solo"));
        vm.prank(owner);
        vm.expectRevert(StratumErrors.CoverageRatioBelowFloor.selector);
        hook.migrateTranchePosition(jSolo, TrancheType.SENIOR);
    }

    /// @notice Two equal juniors: migrating one to senior leaves junior==senior (100% coverage), above floor.
    function test_migrate_juniorToSenior_aboveFloor_succeeds() public {
        bytes32 jA = _deposit(TrancheType.JUNIOR, bytes32("jA"));
        _deposit(TrancheType.JUNIOR, bytes32("jB"));

        uint256 seniorBefore = hook.poolState(id).seniorTVL;
        vm.prank(owner);
        hook.migrateTranchePosition(jA, TrancheType.SENIOR);

        assertGt(hook.poolState(id).seniorTVL, seniorBefore, "senior TVL grew");
        uint16 ratio = CoverageRatio.ratioBps(hook.poolState(id).juniorTVL, hook.poolState(id).seniorTVL);
        assertGe(ratio, params.minCoverageRatioBps, "coverage stays at or above floor");
    }

    /// @notice A senior->junior flip only raises coverage (junior up, senior down): always allowed.
    function test_migrate_seniorToJunior_raisesCoverage() public {
        _deposit(TrancheType.JUNIOR, bytes32("jBig"));
        // A second junior first so the senior intake itself clears the floor, then a senior to migrate back.
        _deposit(TrancheType.JUNIOR, bytes32("jBig2"));
        bytes32 sA = _deposit(TrancheType.SENIOR, bytes32("sA"));

        uint256 seniorBefore = hook.poolState(id).seniorTVL;
        uint256 juniorBefore = hook.poolState(id).juniorTVL;

        vm.prank(owner);
        hook.migrateTranchePosition(sA, TrancheType.JUNIOR);

        assertLt(hook.poolState(id).seniorTVL, seniorBefore, "senior TVL shrank");
        assertGt(hook.poolState(id).juniorTVL, juniorBefore, "junior TVL grew");
    }

    // --- IL realization (golden rule 3: no IL-dodging) -------------------------------------------------

    /// @notice Golden rule 3: IL accrued under the junior tranche is realized at migration (charged to the
    ///         migrant's own principal), and the IL clock resets to the current price so the new senior is only
    ///         protected from here forward. Proven by: carried <= old after an adverse move, and the new entry
    ///         sqrt-price equals the live pool price.
    function test_migrate_realizesIL_clockResets() public {
        bytes32 jA = _deposit(TrancheType.JUNIOR, bytes32("jA"));
        _deposit(TrancheType.JUNIOR, bytes32("jB"));

        uint256 oldPrincipal = hook.position(jA).principalValue;
        _movePrice(); // accrue IL on the in-range position

        vm.prank(owner);
        uint256 carried = hook.migrateTranchePosition(jA, TrancheType.SENIOR);

        assertLe(carried, oldPrincipal, "junior bore its own accrued IL (not dodged onto the buffer)");
        (uint160 live,,,) = manager.getSlot0(id);
        assertEq(hook.position(jA).entrySqrtPriceX96, live, "IL clock reset to current price");
    }

    // --- authorization (FR-30) -------------------------------------------------------------------------

    function test_migrate_strangerReverts() public {
        bytes32 jA = _deposit(TrancheType.JUNIOR, bytes32("jA"));
        _deposit(TrancheType.JUNIOR, bytes32("jB"));

        vm.prank(address(0xBEEF));
        vm.expectRevert(StratumErrors.Unauthorized.selector);
        hook.migrateTranchePosition(jA, TrancheType.SENIOR);
    }

    function test_migrate_approvedMigratorSucceeds() public {
        bytes32 jA = _deposit(TrancheType.JUNIOR, bytes32("jA"));
        _deposit(TrancheType.JUNIOR, bytes32("jB"));

        address registry = address(0xCAFE);
        vm.prank(owner);
        hook.approveMigrator(jA, registry);
        assertEq(hook.migratorApproval(jA), registry, "approval recorded");

        vm.prank(registry);
        hook.migrateTranchePosition(jA, TrancheType.SENIOR);
        assertEq(uint8(hook.position(jA).tranche), uint8(TrancheType.SENIOR), "approved migrator flipped tranche");
    }

    function test_approveMigrator_onlyOwnerReverts() public {
        bytes32 jA = _deposit(TrancheType.JUNIOR, bytes32("jA"));
        vm.prank(address(0xBEEF));
        vm.expectRevert(StratumErrors.NotPositionOwner.selector);
        hook.approveMigrator(jA, address(0xCAFE));
    }

    // --- guards ----------------------------------------------------------------------------------------

    function test_migrate_sameTranche_reverts() public {
        bytes32 jA = _deposit(TrancheType.JUNIOR, bytes32("jA"));
        vm.prank(owner);
        vm.expectRevert(StratumErrors.MigrationToSameTranche.selector);
        hook.migrateTranchePosition(jA, TrancheType.JUNIOR);
    }

    function test_migrate_unknownPosition_reverts() public {
        vm.prank(owner);
        vm.expectRevert(StratumErrors.PositionNotFound.selector);
        hook.migrateTranchePosition(bytes32("nope"), TrancheType.SENIOR);
    }

    /// @notice Audit M-01: migration approval is cleared when the position is withdrawn, so a re-created
    ///         position under the same id cannot inherit a stale, unconsented approval.
    function test_migrate_approvalClearedOnWithdraw() public {
        bytes32 jA = _deposit(TrancheType.JUNIOR, bytes32("jA"));
        vm.prank(owner);
        hook.approveMigrator(jA, address(0xCAFE));
        assertEq(hook.migratorApproval(jA), address(0xCAFE), "approval set");

        IPoolManager.ModifyLiquidityParams memory removeParams = IPoolManager.ModifyLiquidityParams({
            tickLower: LIQUIDITY_PARAMS.tickLower,
            tickUpper: LIQUIDITY_PARAMS.tickUpper,
            liquidityDelta: -LIQUIDITY_PARAMS.liquidityDelta,
            salt: LIQUIDITY_PARAMS.salt
        });
        modifyLiquidityRouter.modifyLiquidity(key, removeParams, abi.encode(TrancheType.JUNIOR, bytes32("jA")));

        assertEq(hook.migratorApproval(jA), address(0), "approval cleared on withdraw (M-01)");
    }
}
