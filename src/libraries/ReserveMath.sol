// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { ILMath } from "./ILMath.sol";

/// @title ReserveMath
/// @notice Pure per-currency split/clamp math for the token-backed junior buffer (R-H1).
/// @dev Splits a token0-denominated senior make-whole obligation across the two real reserve legs, draining
///      token0 first (native units) then token1 (converted via the pool price), clamping each leg to what is
///      actually held. No state, no oracle: price comes from the pool exit sqrt only (golden rule 2).
library ReserveMath {
    /// @notice Decide how much of each currency to settle for a token0-denominated obligation.
    /// @param owedValue0 The make-whole/yield gap, denominated in token0 value.
    /// @param reserve0 Real token0 held in reserve for this pool.
    /// @param reserve1 Real token1 held in reserve for this pool.
    /// @param exitSqrtPriceX96 Pool sqrt price at exit, used for the token0<->token1 conversion only.
    /// @return pay0 token0 to settle to the senior LP (clamped to reserve0).
    /// @return pay1 token1 to settle to the senior LP (clamped to reserve1).
    /// @return paidValue0 token0-denominated value actually covered by pay0 + pay1.
    /// @return shortfallValue0 token0-denominated value that could NOT be covered (for the shortfall event).
    /// @dev INV-03: pay0 and pay1 are each <= the held reserve, so the hook can always settle the exact
    ///      magnitude it returns as a negative delta; it never promises tokens it cannot move.
    function splitOwed(uint256 owedValue0, uint256 reserve0, uint256 reserve1, uint160 exitSqrtPriceX96)
        internal
        pure
        returns (uint256 pay0, uint256 pay1, uint256 paidValue0, uint256 shortfallValue0)
    {
        // Drain token0 first: it is already token0-value units, so value == amount.
        pay0 = owedValue0 > reserve0 ? reserve0 : owedValue0;
        uint256 remainingValue0 = owedValue0 - pay0;

        // Cover the remainder from token1, converting the residual token0-value into a token1 amount.
        if (remainingValue0 > 0 && reserve1 > 0) {
            uint256 want1 = ILMath.token1FromValueInToken0(remainingValue0, exitSqrtPriceX96);
            pay1 = want1 > reserve1 ? reserve1 : want1;
        }

        // Value actually covered = token0 leg (1:1) + token1 leg re-valued back into token0.
        uint256 pay1AsValue0 = pay1 == 0 ? 0 : ILMath.valueInToken0(0, pay1, exitSqrtPriceX96);
        paidValue0 = pay0 + pay1AsValue0;
        // Defensive: rounding between the two conversions can make paidValue0 marginally exceed owedValue0.
        shortfallValue0 = owedValue0 > paidValue0 ? owedValue0 - paidValue0 : 0;
    }
}
