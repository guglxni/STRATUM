// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { ILMath } from "../../src/libraries/ILMath.sol";

contract ILMathTest is Test {
    function test_ilForRange_zeroOnNoMove() public pure {
        uint160 p = TickMath.getSqrtPriceAtTick(0);
        uint256 il = ILMath.ilForRange(p, p, -120, 120, 1e18);
        assertEq(il, 0);
    }

    function test_ilForRange_positiveOnDivergence() public pure {
        uint160 entry = TickMath.getSqrtPriceAtTick(0);
        uint160 exit = TickMath.getSqrtPriceAtTick(600);
        uint256 il = ILMath.ilForRange(entry, exit, -120, 120, 1e18);
        assertGt(il, 0);
    }

    function test_updateVolatilityEWMA_increasesOnMove() public pure {
        uint160 a = TickMath.getSqrtPriceAtTick(0);
        uint160 b = TickMath.getSqrtPriceAtTick(100);
        uint256 ewma = ILMath.updateVolatilityEWMA(0, a, b);
        assertGt(ewma, 0);
    }

    /// @notice token1FromValueInToken0 is the inverse of the token1 leg of valueInToken0 (R-C1 helper).
    /// @dev Round-trip: convert a token1 amount to its token0 value, back to token1; expect near-equality.
    function test_token1FromValueInToken0_roundTrips() public pure {
        uint160 p = TickMath.getSqrtPriceAtTick(1500); // non-unity price so the conversion is exercised
        uint256 amount1 = 1_000_000e18;
        uint256 value0 = ILMath.valueInToken0(0, amount1, p);
        uint256 back1 = ILMath.token1FromValueInToken0(value0, p);
        // Allow tiny rounding drift from two mulDiv truncations.
        assertApproxEqRel(back1, amount1, 1e12); // within 1e-6
    }

    function test_token1FromValueInToken0_zeroInputs() public pure {
        uint160 p = TickMath.getSqrtPriceAtTick(0);
        assertEq(ILMath.token1FromValueInToken0(0, p), 0, "zero value -> zero token1");
        assertEq(ILMath.token1FromValueInToken0(1e18, 0), 0, "zero price -> zero token1");
    }
}
