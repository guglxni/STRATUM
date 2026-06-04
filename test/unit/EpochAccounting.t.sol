// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { EpochAccounting } from "../../src/libraries/EpochAccounting.sol";

contract EpochAccountingTest is Test {
    function test_seniorObligationForEpoch() public pure {
        uint256 ob = EpochAccounting.seniorObligationForEpoch(1_000_000e18, 500, 7 days);
        assertGt(ob, 0);
    }

    function test_epochSurplus_noShortfallWhenFunded() public pure {
        (uint256 surplus, uint256 shortfall) = EpochAccounting.epochSurplus(100, 80, 80);
        assertEq(surplus, 20);
        assertEq(shortfall, 0);
    }

    function test_vestedFraction_linear() public pure {
        assertEq(EpochAccounting.vestedFraction(100, 50), 5e17);
    }

    function test_vestedToDate_boundaries() public pure {
        assertEq(EpochAccounting.vestedToDate(1000e18, 0, 100), 0, "age 0 -> nothing vested");
        assertEq(EpochAccounting.vestedToDate(1000e18, 50, 100), 500e18, "half age -> half vested");
        assertEq(EpochAccounting.vestedToDate(1000e18, 100, 100), 1000e18, "full age -> fully vested");
        assertEq(EpochAccounting.vestedToDate(1000e18, 250, 100), 1000e18, "past window -> capped at total");
        assertEq(EpochAccounting.vestedToDate(1000e18, 50, 0), 1000e18, "zero window -> fully vested");
    }

    function testFuzz_vestedToDate_monotone(uint128 total, uint32 age1, uint32 age2, uint32 smoothing) public {
        vm.assume(age1 <= age2);
        uint256 v1 = EpochAccounting.vestedToDate(total, age1, smoothing);
        uint256 v2 = EpochAccounting.vestedToDate(total, age2, smoothing);
        assertLe(v1, v2, "monotone non-decreasing in age");
        assertLe(v2, total, "never exceeds total");
        if (smoothing != 0 && age1 >= smoothing) assertEq(v1, total, "fully vested past window");
    }
}
