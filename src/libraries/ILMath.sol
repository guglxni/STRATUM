// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";
import { FixedPoint96 } from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { SafeCast } from "@uniswap/v4-core/src/libraries/SafeCast.sol";

/// @title ILMath
/// @notice Impermanent loss from sqrt price movement only (FR-08, no oracle).
library ILMath {
    using SafeCast for uint256;

    /// @notice IL in token0 numeraire for a concentrated position.
    /// @dev held(P) - lpValue(P) at exit price; zero if price unchanged.
    function ilForRange(uint160 entrySqrtP, uint160 exitSqrtP, int24 tickLower, int24 tickUpper, uint128 liquidity)
        internal
        pure
        returns (uint256 ilToken0)
    {
        if (entrySqrtP == exitSqrtP || liquidity == 0) return 0;

        (uint256 amount0Entry, uint256 amount1Entry) =
            _amountsForLiquidity(entrySqrtP, _sqrtAtTick(tickLower), _sqrtAtTick(tickUpper), liquidity);
        (uint256 amount0Exit, uint256 amount1Exit) =
            _amountsForLiquidity(exitSqrtP, _sqrtAtTick(tickLower), _sqrtAtTick(tickUpper), liquidity);

        uint256 held = valueInToken0(amount0Entry, amount1Entry, exitSqrtP);
        uint256 lpValue = valueInToken0(amount0Exit, amount1Exit, exitSqrtP);

        if (held > lpValue) return held - lpValue;
        return 0;
    }

    /// @notice Pool-level IL increment from a sqrt price move (cheap accumulator).
    function incrementalIL(uint160 prevSqrtP, uint160 newSqrtP, uint128 liquidity) internal pure returns (uint256) {
        if (prevSqrtP == 0 || newSqrtP == prevSqrtP || liquidity == 0) return 0;
        uint256 delta = newSqrtP > prevSqrtP ? newSqrtP - prevSqrtP : prevSqrtP - newSqrtP;
        return FullMath.mulDiv(uint256(liquidity), delta, prevSqrtP);
    }

    /// @notice Update EWMA volatility estimate from sqrt price change.
    function updateVolatilityEWMA(uint256 prevEWMA, uint160 prevSqrtP, uint160 newSqrtP)
        internal
        pure
        returns (uint256)
    {
        if (prevSqrtP == 0) return 0;
        uint256 delta = newSqrtP > prevSqrtP ? newSqrtP - prevSqrtP : prevSqrtP - newSqrtP;
        uint256 instant = FullMath.mulDiv(delta, 1e18, prevSqrtP);
        if (prevEWMA == 0) return instant;
        return (prevEWMA * 9 + instant) / 10;
    }

    function valueInToken0(uint256 amount0, uint256 amount1, uint160 sqrtPriceX96) public pure returns (uint256) {
        if (sqrtPriceX96 == 0) return amount0;
        uint256 priceX96 = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), FixedPoint96.Q96);
        uint256 amount1As0;
        if (priceX96 == 0) {
            // M-10: for sqrtPriceX96 < 2^48 the squared price truncates to 0 (a valid range above
            // MIN_SQRT_PRICE), which would divide-by-zero below. Use the precision-preserving two-step
            // conversion (amount1 * Q96 / sqrtP) * Q96 / sqrtP, which never forms the truncated priceX96.
            amount1As0 = FullMath.mulDiv(
                FullMath.mulDiv(amount1, FixedPoint96.Q96, sqrtPriceX96), FixedPoint96.Q96, sqrtPriceX96
            );
        } else {
            amount1As0 = FullMath.mulDiv(amount1, FixedPoint96.Q96, priceX96);
        }
        return amount0 + amount1As0;
    }

    /// @notice Inverse of the token1 leg of `valueInToken0`: how many token1 units equal `value0` token0 of value.
    /// @dev Used to express a token0-denominated clawback in actual token1 units when settling per-currency.
    ///      Returns 0 at zero price (no token1 leg to value).
    /// @param value0 A value denominated in token0.
    /// @param sqrtPriceX96 Current pool sqrt price (Q64.96).
    /// @return amount1 The token1 amount whose token0 value equals `value0`.
    function token1FromValueInToken0(uint256 value0, uint160 sqrtPriceX96) internal pure returns (uint256 amount1) {
        if (sqrtPriceX96 == 0 || value0 == 0) return 0;
        uint256 priceX96 = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), FixedPoint96.Q96);
        return FullMath.mulDiv(value0, priceX96, FixedPoint96.Q96);
    }

    function _sqrtAtTick(int24 tick) internal pure returns (uint160) {
        return TickMath.getSqrtPriceAtTick(tick);
    }

    function _amountsForLiquidity(uint160 sqrtPriceX96, uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint128 liquidity)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        if (sqrtPriceAX96 > sqrtPriceBX96) (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);

        if (sqrtPriceX96 <= sqrtPriceAX96) {
            amount0 = _amount0ForLiquidity(sqrtPriceAX96, sqrtPriceBX96, liquidity);
        } else if (sqrtPriceX96 < sqrtPriceBX96) {
            amount0 = _amount0ForLiquidity(sqrtPriceX96, sqrtPriceBX96, liquidity);
            amount1 = _amount1ForLiquidity(sqrtPriceAX96, sqrtPriceX96, liquidity);
        } else {
            amount1 = _amount1ForLiquidity(sqrtPriceAX96, sqrtPriceBX96, liquidity);
        }
    }

    function _amount0ForLiquidity(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint128 liquidity)
        internal
        pure
        returns (uint256 amount0)
    {
        if (sqrtPriceAX96 > sqrtPriceBX96) (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        return FullMath.mulDiv(
            uint256(liquidity) << FixedPoint96.RESOLUTION, sqrtPriceBX96 - sqrtPriceAX96, sqrtPriceBX96
        ) / sqrtPriceAX96;
    }

    function _amount1ForLiquidity(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint128 liquidity)
        internal
        pure
        returns (uint256 amount1)
    {
        if (sqrtPriceAX96 > sqrtPriceBX96) (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        return FullMath.mulDiv(liquidity, sqrtPriceBX96 - sqrtPriceAX96, FixedPoint96.Q96);
    }
}
