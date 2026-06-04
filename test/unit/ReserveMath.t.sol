// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { ReserveMath } from "../../src/libraries/ReserveMath.sol";

contract ReserveMathTest is Test {
    uint160 internal constant P1 = 79_228_162_514_264_337_593_543_950_336; // sqrtPrice at tick 0 (price 1)

    function test_token0Only_whenReserve0Covers() public pure {
        (uint256 pay0, uint256 pay1, uint256 paid, uint256 short) = ReserveMath.splitOwed(100e18, 500e18, 500e18, P1);
        assertEq(pay0, 100e18, "drain token0 first");
        assertEq(pay1, 0, "no token1 needed");
        assertEq(paid, 100e18, "fully covered");
        assertEq(short, 0, "no shortfall");
    }

    function test_spillsToToken1_whenReserve0Insufficient() public pure {
        // owed 300, only 100 token0 held -> 200 value spills to token1 (price 1, so ~200 token1).
        (uint256 pay0, uint256 pay1, uint256 paid, uint256 short) = ReserveMath.splitOwed(300e18, 100e18, 500e18, P1);
        assertEq(pay0, 100e18, "token0 leg clamped to reserve0");
        assertApproxEqRel(pay1, 200e18, 1e12, "token1 leg covers the remainder at price 1");
        assertApproxEqRel(paid, 300e18, 1e12, "fully covered across both legs");
        assertLe(short, 1e6, "no material shortfall");
    }

    function test_clampsBothLegs_andReportsShortfall() public pure {
        // owed 1000, but only 100 token0 + 200 token1 held -> ~300 covered, ~700 shortfall.
        (uint256 pay0, uint256 pay1, uint256 paid, uint256 short) = ReserveMath.splitOwed(1000e18, 100e18, 200e18, P1);
        assertEq(pay0, 100e18, "pay0 clamped to reserve0");
        assertEq(pay1, 200e18, "pay1 clamped to reserve1");
        assertApproxEqRel(paid, 300e18, 1e12, "covered == held");
        assertApproxEqRel(short, 700e18, 1e12, "shortfall == owed - held");
    }

    function test_zeroReserve_paysNothing_allShortfall() public pure {
        (uint256 pay0, uint256 pay1, uint256 paid, uint256 short) = ReserveMath.splitOwed(500e18, 0, 0, P1);
        assertEq(pay0, 0);
        assertEq(pay1, 0);
        assertEq(paid, 0);
        assertEq(short, 500e18, "entire obligation is shortfall");
    }

    function testFuzz_paysNeverExceedHeld(uint128 owed, uint128 r0, uint128 r1) public pure {
        (uint256 pay0, uint256 pay1,, uint256 short) = ReserveMath.splitOwed(owed, r0, r1, P1);
        assertLe(pay0, r0, "pay0 <= reserve0 (INV-03: never settle more than held)");
        assertLe(pay1, r1, "pay1 <= reserve1");
        assertLe(short, uint256(owed), "shortfall never exceeds the obligation");
    }
}
