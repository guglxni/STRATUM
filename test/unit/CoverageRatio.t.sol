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
}
