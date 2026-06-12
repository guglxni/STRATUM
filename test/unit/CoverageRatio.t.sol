// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { CoverageRatio } from "../../src/libraries/CoverageRatio.sol";

contract CoverageRatioHarness {
    function enforce(uint256 j, uint256 s, uint256 d, uint16 minBps) external pure {
        CoverageRatio.enforceOnSeniorIntake(j, s, d, minBps);
    }
}

contract CoverageRatioTest is Test {
    CoverageRatioHarness harness = new CoverageRatioHarness();

    function test_ratioBps_infiniteWhenNoSenior() public pure {
        assertEq(CoverageRatio.ratioBps(100e18, 0), type(uint16).max);
    }

    function test_enforceOnSeniorIntake_revertsBelowFloor() public {
        vm.expectRevert(
            abi.encodeWithSelector(CoverageRatio.CoverageRatioBelowFloor.selector, uint16(666), uint16(3000))
        );
        harness.enforce(100e18, 1000e18, 500e18, 3000);
    }

    function test_enforceOnSeniorIntake_passesAboveFloor() public pure {
        CoverageRatio.enforceOnSeniorIntake(5000e18, 1000e18, 100e18, 3000);
    }

    function test_stressLevel_monotonic() public pure {
        uint16 low = CoverageRatio.stressLevel(10_000, 3000);
        uint16 mid = CoverageRatio.stressLevel(4500, 3000);
        uint16 high = CoverageRatio.stressLevel(3000, 3000);
        assertGt(mid, low);
        assertGt(high, mid);
    }

    // --- P1: graduated remediation scalar (slope, not cliff) ---

    function test_remediationScale_zeroInHealthyBand() public pure {
        // ratio at or above trigger -> no remediation.
        assertEq(CoverageRatio.remediationScaleBps(6000, 6000, 3000), 0);
        assertEq(CoverageRatio.remediationScaleBps(9000, 6000, 3000), 0);
    }

    function test_remediationScale_maxAtOrBelowFloor() public pure {
        assertEq(CoverageRatio.remediationScaleBps(3000, 6000, 3000), 10_000);
        assertEq(CoverageRatio.remediationScaleBps(2500, 6000, 3000), 10_000);
    }

    function test_remediationScale_linearMidpoint() public pure {
        // Midpoint of the [floor=3000, trigger=6000] band -> ~5000 bps.
        assertEq(CoverageRatio.remediationScaleBps(4500, 6000, 3000), 5000);
    }

    function test_remediationScale_monotonicDecreasingWithRatio() public pure {
        uint16 nearFloor = CoverageRatio.remediationScaleBps(3300, 6000, 3000);
        uint16 mid = CoverageRatio.remediationScaleBps(4500, 6000, 3000);
        uint16 nearTrigger = CoverageRatio.remediationScaleBps(5700, 6000, 3000);
        assertGt(nearFloor, mid);
        assertGt(mid, nearTrigger);
    }

    function test_remediationScale_degenerateBandIsBinary() public pure {
        // trigger == floor: no slope, just a binary response at the floor.
        assertEq(CoverageRatio.remediationScaleBps(3001, 3000, 3000), 0);
        assertEq(CoverageRatio.remediationScaleBps(3000, 3000, 3000), 10_000);
    }

    function testFuzz_remediationScale_boundedAndMonotonic(uint16 ratio, uint16 trigger, uint16 floorBps) public pure {
        // Constrain to a valid ascending band: floor <= trigger.
        floorBps = uint16(bound(floorBps, 1, 30_000));
        trigger = uint16(bound(trigger, floorBps, 60_000));
        uint16 scale = CoverageRatio.remediationScaleBps(ratio, trigger, floorBps);
        assertLe(scale, 10_000); // always within [0, 10000]
        if (ratio >= trigger && trigger > floorBps) assertEq(scale, 0);
        if (ratio <= floorBps) assertEq(scale, 10_000);
    }
}
