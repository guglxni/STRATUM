// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { Waterfall } from "../../src/libraries/Waterfall.sol";

contract WaterfallTest is Test {
    function test_dynamicFeeBps_clamped() public pure {
        uint16 fee = Waterfall.dynamicFeeBps(30, 10, 100, 0, 0);
        assertGe(fee, 10);
        assertLe(fee, 100);
    }

    function test_splitFee_sumsToTotal() public pure {
        Waterfall.Split memory s = Waterfall.splitFee(1e18, 100, 0, 0);
        assertEq(s.seniorPortion + s.juniorPortion + s.protocolPortion, 1e18);
    }

    function test_splitFee_moreSeniorUnderStress() public pure {
        Waterfall.Split memory calm = Waterfall.splitFee(1e18, 100, 0, 0);
        Waterfall.Split memory stress = Waterfall.splitFee(1e18, 100, 0, 9000);
        assertGt(stress.seniorPortion, calm.seniorPortion);
    }

    function test_splitFee_highProtocolFee_noUnderflow() public pure {
        Waterfall.Split memory s = Waterfall.splitFee(1e18, 3000, 0, 10_000);
        assertEq(s.seniorPortion + s.juniorPortion + s.protocolPortion, 1e18);
    }
}
