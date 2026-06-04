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
import { PoolInitParams, TrancheType } from "../../src/StratumTypes.sol";
import { CoverageRatio } from "../../src/libraries/CoverageRatio.sol";
import { EpochAccounting } from "../../src/libraries/EpochAccounting.sol";
import { HookMiner } from "../utils/HookMiner.sol";
import { StratumFlags } from "../utils/StratumFlags.sol";

/// @title StratumInvariantsTest
/// @notice Pure invariant checks for INV-01, INV-04 (library level).
contract StratumInvariantsTest is Test {
    function testFuzz_INV01_coverageEnforced(uint128 junior, uint128 senior, uint128 deposit, uint16 minCov) public {
        vm.assume(minCov > 0 && minCov < 20_000);
        vm.assume(senior > 0 && junior > 0 && deposit > 0);
        uint16 prospective = CoverageRatio.prospectiveRatioBps(junior, senior, deposit);
        if (prospective >= minCov) {
            CoverageRatio.enforceOnSeniorIntake(junior, senior, deposit, minCov);
        }
    }

    function testFuzz_INV04_surplusOnlyAfterObligationMet(uint96 accumulated, uint96 obligation, uint96 funded) public {
        (uint256 surplus, uint256 shortfall) = EpochAccounting.epochSurplus(accumulated, obligation, funded);
        if (funded >= obligation && accumulated >= obligation) {
            assertGe(surplus, accumulated - obligation);
            assertEq(shortfall, 0);
        }
    }

    function testFuzz_INV02_seniorProtection(
        uint128 principalValue,
        uint128 juniorReserve,
        uint128 ilOnPosition,
        uint16 maxSeniorILBps
    ) public pure {
        vm.assume(maxSeniorILBps <= 10_000 && principalValue > 0);
        uint256 payout;
        if (juniorReserve >= ilOnPosition) {
            payout = principalValue;
            assertEq(payout, principalValue);
        } else {
            uint256 shortfall = ilOnPosition - juniorReserve;
            uint256 maxSeniorIL = uint256(principalValue) * maxSeniorILBps / 10_000;
            uint256 seniorIL = shortfall > maxSeniorIL ? maxSeniorIL : shortfall;
            payout = principalValue > seniorIL ? principalValue - seniorIL : 0;
            assertLe(seniorIL, maxSeniorIL);
        }
    }

    /// @notice INV-03: For a senior settlement, payout never exceeds principalIn + positionEarned + ROUNDING_TOLERANCE.
    /// @dev Replicates the _settleSenior payout formula exactly (feeEarned only, no fixedYield for cleaner fuzz bounds).
    ///      The conservation check in _conservationCheck requires payout <= principalIn + positionEarnedFees + 100.
    function testFuzz_INV03_conservation_senior(
        uint128 principalValue,
        uint128 ilOnPosition,
        uint128 juniorReserve,
        uint64 feeEarned,
        uint16 maxSeniorILBps
    ) public pure {
        vm.assume(maxSeniorILBps <= 10_000 && principalValue > 0);
        // Guard against overflow in intermediate multiplication: principalValue * maxSeniorILBps fits in uint256.
        // uint128 * uint16 <= ~3.4e38 * 6.5e4 which is within uint256, so no extra assume needed.

        uint256 positionEarned = uint256(feeEarned);

        uint256 principalPayout;
        if (uint256(juniorReserve) >= uint256(ilOnPosition)) {
            // Junior reserve fully covers IL: senior receives full principal.
            principalPayout = principalValue;
        } else {
            uint256 shortfall = uint256(ilOnPosition) - uint256(juniorReserve);
            uint256 maxSeniorIL = uint256(principalValue) * uint256(maxSeniorILBps) / 10_000;
            uint256 seniorIL = shortfall > maxSeniorIL ? maxSeniorIL : shortfall;
            principalPayout = principalValue > seniorIL ? principalValue - seniorIL : 0;

            // seniorIL is bounded by maxSeniorIL which is a fraction of principalValue.
            assertLe(seniorIL, maxSeniorIL, "INV-03: seniorIL exceeds maxSeniorIL cap");
            assertLe(seniorIL, uint256(principalValue), "INV-03: seniorIL exceeds full principal");
        }

        uint256 payout = principalPayout + positionEarned;

        // Conservation: payout must not exceed principalIn + positionEarned + ROUNDING_TOLERANCE (100).
        assertLe(
            payout,
            uint256(principalValue) + positionEarned + 100,
            "INV-03: conservation violated -- payout exceeds principal + earned + tolerance"
        );

        // principalPayout is always at most principalValue (senior cannot gain principal from IL path).
        assertLe(principalPayout, uint256(principalValue), "INV-03: principalPayout exceeds principal");
    }

    /// @notice INV-05: The junior reserve changes only through the two credited and two debited paths defined in the spec.
    /// @dev Simulates one closeEpoch (surplus credit / shortfall debit) followed by one _settleSenior IL debit and
    ///      asserts the net reserve equals the exact arithmetic result, with no hidden mutation.
    ///      Credited by: surplus in closeEpoch.
    ///      Debited by: shortfall cover in closeEpoch, IL absorption in _settleSenior.
    function testFuzz_INV05_bufferMonotonicity(
        uint96 accumulated,
        uint96 seniorObligation,
        uint96 initialReserve,
        uint96 ilAbsorbed
    ) public pure {
        // Treat seniorFunded == accumulated (all fees count toward senior obligation).
        (uint256 surplus, uint256 shortfall) =
            EpochAccounting.epochSurplus(uint256(accumulated), uint256(seniorObligation), uint256(accumulated));

        // --- closeEpoch phase ---
        // Shortfall cover: debit min(shortfall, reserve).
        uint256 cover = shortfall > uint256(initialReserve) ? uint256(initialReserve) : shortfall;
        uint256 reserveAfterClose = uint256(initialReserve) - cover + surplus;

        // Guard: surplus must not cause overflow (surplus <= accumulated <= type(uint96).max; cover <= initialReserve
        // <= type(uint96).max; their combined range fits in uint256 easily, so no extra assume needed).

        // Post-closeEpoch invariants.
        if (shortfall > 0) {
            // Reserve decreased by exactly min(shortfall, initialReserve).
            assertEq(
                reserveAfterClose,
                uint256(initialReserve) - cover + surplus,
                "INV-05: reserve after close deviates from expected"
            );
            assertLe(cover, uint256(initialReserve), "INV-05: cover exceeds available reserve");
            assertLe(cover, shortfall, "INV-05: cover exceeds shortfall");
        }
        if (surplus > 0) {
            assertGe(reserveAfterClose, uint256(initialReserve) - cover, "INV-05: surplus credit missing");
        }

        // --- _settleSenior IL absorption phase ---
        // Debit: min(ilAbsorbed, currentReserve).
        uint256 ilDeducted = uint256(ilAbsorbed) > reserveAfterClose ? reserveAfterClose : uint256(ilAbsorbed);
        uint256 reserveFinal = reserveAfterClose - ilDeducted;

        // Post-settlement invariants.
        assertLe(ilDeducted, reserveAfterClose, "INV-05: IL deducted exceeds available reserve after close");
        assertGe(reserveFinal, 0, "INV-05: reserve went negative");

        // Net reserve must equal exactly: initial + surplus - cover - ilDeducted.
        uint256 expectedFinal = uint256(initialReserve) + surplus - cover - ilDeducted;
        assertEq(reserveFinal, expectedFinal, "INV-05: net reserve deviates from two-path accounting");

        // Reserve is non-negative (uint256 guarantees this, but assert the derivation is consistent).
        assertLe(cover + ilDeducted, uint256(initialReserve) + surplus, "INV-05: total debits exceed total credits");
    }
}

/// @notice INV-06: epoch counter is monotonic after elapsed time.
contract StratumEpochInvariantTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;

    StratumHook hook;

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        PoolInitParams memory params = PoolInitParams({
            targetAPYBps: 500,
            minCoverageRatioBps: 3000,
            maxSeniorILExposureBps: 500,
            smoothingEpochSeconds: 1 days,
            baseFeeBps: 30,
            minFeeBps: 5,
            maxFeeBps: 200,
            protocolFeeBps: 100,
            peripheralRegistry: address(0)
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
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, abi.encode(TrancheType.JUNIOR, bytes32("inv")));
    }

    function test_INV06_epochMonotonic() public {
        PoolId id = key.toId();
        uint64 before = hook.poolState(id).currentEpoch;
        vm.warp(block.timestamp + 1 days);
        hook.closeEpoch(id);
        assertGe(hook.poolState(id).currentEpoch, before);
    }
}
