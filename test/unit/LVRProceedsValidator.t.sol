// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { LVRProceedsValidator } from "../../src/peripherals/eigenlayer/LVRProceedsValidator.sol";

/// @title LVRProceedsValidatorTest
/// @notice FR-28: the LVR proceeds sanity bound. Symmetric with the operator's off-chain `max_rational_bid`.
contract LVRProceedsValidatorTest is Test {
    function test_maxRationalProceeds_basic() public pure {
        // WETH at $3000 (3000e8), 10 tokens (10e18 units), 50bps max LVR factor.
        // notional = 3000 * 10e18 = 3.0e22 USD-units; bound = 0.5% = 1.5e20.
        uint256 bound = LVRProceedsValidator.maxRationalProceeds(3000e8, 10e18, 50);
        assertEq(bound, 30_000e18 * 50 / 10_000);
    }

    function test_isWithinBound_acceptsRationalClaim() public pure {
        uint256 bound = LVRProceedsValidator.maxRationalProceeds(3000e8, 10e18, 50);
        assertTrue(LVRProceedsValidator.isWithinBound(3000e8, 10e18, bound, 50), "claim at the bound is allowed");
        assertTrue(LVRProceedsValidator.isWithinBound(3000e8, 10e18, bound - 1, 50), "below the bound is allowed");
    }

    function test_isWithinBound_rejectsInflatedClaim() public pure {
        uint256 bound = LVRProceedsValidator.maxRationalProceeds(3000e8, 10e18, 50);
        assertFalse(LVRProceedsValidator.isWithinBound(3000e8, 10e18, bound + 1, 50), "above the bound is rejected");
    }

    function test_zeroPrice_failsSafe() public pure {
        // Unavailable/stale price -> zero bound -> any positive claim is out-of-bound (caller must fall back).
        assertFalse(LVRProceedsValidator.isWithinBound(0, 10e18, 1, 50), "no price cannot validate a positive claim");
        assertTrue(LVRProceedsValidator.isWithinBound(0, 10e18, 0, 50), "a zero claim is trivially within a zero bound");
    }

    function testFuzz_isWithinBound_consistentWithMax(uint128 price, uint128 amount, uint16 factor, uint256 claim)
        public
        pure
    {
        factor = uint16(bound(factor, 0, 10_000));
        uint256 max = LVRProceedsValidator.maxRationalProceeds(price, amount, factor);
        assertEq(LVRProceedsValidator.isWithinBound(price, amount, claim, factor), claim <= max);
    }
}
