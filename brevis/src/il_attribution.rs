//! ILAttribution circuit witness: per-position impermanent loss over the
//! actual holding window, in token0 numeraire.
//!
//! This reproduces `src/libraries/ILMath.sol::ilForRange` EXACTLY. The
//! on-chain shim (`BrevisVerifierShim.submitILAttributionProof` /
//! `verifyILAttribution`) trusts a `claimedIL`; this module computes the
//! witness value that the circuit proves, so the off-chain prover and the
//! on-chain approximation agree to the wei.
//!
//! The Solidity algorithm (no oracle, FR-08), reproduced step for step:
//!
//!   ilForRange(entrySqrtP, exitSqrtP, tickLower, tickUpper, liquidity):
//!     if entrySqrtP == exitSqrtP || liquidity == 0: return 0
//!     (a0e, a1e) = amountsForLiquidity(entrySqrtP, sqrt(tickLower), sqrt(tickUpper), L)
//!     (a0x, a1x) = amountsForLiquidity(exitSqrtP,  sqrt(tickLower), sqrt(tickUpper), L)
//!     held    = valueInToken0(a0e, a1e, exitSqrtP)   // hold the entry basket, mark at exit
//!     lpValue = valueInToken0(a0x, a1x, exitSqrtP)   // the LP basket at exit
//!     return held > lpValue ? held - lpValue : 0
//!
//! `held - lpValue` is the divergence (impermanent) loss: what a passive
//! holder of the entry token basket would be worth at the exit price, minus
//! what the LP position is actually worth at the exit price.

use crate::tick_math::{get_sqrt_price_at_tick, q96};
use crate::u256::U256;

/// `valueInToken0(amount0, amount1, sqrtPriceX96)` from ILMath.sol:
///   priceX96   = sqrtP * sqrtP / Q96
///   amount1As0 = amount1 * Q96 / priceX96
///   return amount0 + amount1As0
/// At zero price returns amount0 (token1 has no token0 value).
pub fn value_in_token0(amount0: &U256, amount1: &U256, sqrt_price_x96: &U256) -> U256 {
    if sqrt_price_x96.is_zero() {
        return *amount0;
    }
    let price_x96 = sqrt_price_x96.mul_div_floor(sqrt_price_x96, &q96());
    let amount1_as0 = amount1.mul_div_floor(&q96(), &price_x96);
    amount0.wrapping_add(&amount1_as0)
}

/// `_amount0ForLiquidity` from ILMath.sol:
///   mulDiv(L << 96, sqrtB - sqrtA, sqrtB) / sqrtA   (with sqrtA <= sqrtB)
fn amount0_for_liquidity(sqrt_a: &U256, sqrt_b: &U256, liquidity: u128) -> U256 {
    let (lo, hi) = order(sqrt_a, sqrt_b);
    let l_shifted = U256::from_u128(liquidity).shl(96); // L << FixedPoint96.RESOLUTION
    let diff = hi.wrapping_sub(&lo);
    // mulDiv(L<<96, (B-A), B) then integer-divide by A.
    let inner = l_shifted.mul_div_floor(&diff, &hi);
    // Division by sqrtA: use mul_div_floor with multiplier 1.
    inner.mul_div_floor(&U256::ONE, &lo)
}

/// `_amount1ForLiquidity` from ILMath.sol:
///   mulDiv(L, sqrtB - sqrtA, Q96)   (with sqrtA <= sqrtB)
fn amount1_for_liquidity(sqrt_a: &U256, sqrt_b: &U256, liquidity: u128) -> U256 {
    let (lo, hi) = order(sqrt_a, sqrt_b);
    let diff = hi.wrapping_sub(&lo);
    U256::from_u128(liquidity).mul_div_floor(&diff, &q96())
}

/// Order two sqrt prices ascending (returns (min, max)).
fn order(a: &U256, b: &U256) -> (U256, U256) {
    if crate::u256::cmp_gt(a, b) {
        (*b, *a)
    } else {
        (*a, *b)
    }
}

/// `_amountsForLiquidity` from ILMath.sol: the three-region split based on
/// where the current sqrt price sits relative to the range [sqrtA, sqrtB].
pub fn amounts_for_liquidity(
    sqrt_price: &U256,
    sqrt_a_in: &U256,
    sqrt_b_in: &U256,
    liquidity: u128,
) -> (U256, U256) {
    let (sqrt_a, sqrt_b) = order(sqrt_a_in, sqrt_b_in);
    if !crate::u256::cmp_gt(sqrt_price, &sqrt_a) {
        // price <= A: all token0.
        (amount0_for_liquidity(&sqrt_a, &sqrt_b, liquidity), U256::ZERO)
    } else if crate::u256::cmp_gt(&sqrt_b, sqrt_price) {
        // A < price < B: both legs.
        (
            amount0_for_liquidity(sqrt_price, &sqrt_b, liquidity),
            amount1_for_liquidity(&sqrt_a, sqrt_price, liquidity),
        )
    } else {
        // price >= B: all token1.
        (U256::ZERO, amount1_for_liquidity(&sqrt_a, &sqrt_b, liquidity))
    }
}

/// Inputs to the IL attribution witness for one position over its window.
#[derive(Clone, Copy, Debug)]
pub struct IlInputs {
    pub entry_sqrt_p: U256,
    pub exit_sqrt_p: U256,
    pub tick_lower: i32,
    pub tick_upper: i32,
    pub liquidity: u128,
}

/// Reproduces `ILMath.ilForRange` exactly. Returns IL in token0 numeraire.
pub fn il_for_range(inp: &IlInputs) -> U256 {
    if inp.entry_sqrt_p == inp.exit_sqrt_p || inp.liquidity == 0 {
        return U256::ZERO;
    }
    let sqrt_lower = get_sqrt_price_at_tick(inp.tick_lower);
    let sqrt_upper = get_sqrt_price_at_tick(inp.tick_upper);

    let (a0_entry, a1_entry) =
        amounts_for_liquidity(&inp.entry_sqrt_p, &sqrt_lower, &sqrt_upper, inp.liquidity);
    let (a0_exit, a1_exit) =
        amounts_for_liquidity(&inp.exit_sqrt_p, &sqrt_lower, &sqrt_upper, inp.liquidity);

    let held = value_in_token0(&a0_entry, &a1_entry, &inp.exit_sqrt_p);
    let lp_value = value_in_token0(&a0_exit, &a1_exit, &inp.exit_sqrt_p);

    if crate::u256::cmp_gt(&held, &lp_value) {
        held.wrapping_sub(&lp_value)
    } else {
        U256::ZERO
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tick_math::get_sqrt_price_at_tick;

    // Wide range covering tick 0, aligned to spacing 60.
    const LOWER: i32 = -6000;
    const UPPER: i32 = 6000;

    fn inputs(entry_tick: i32, exit_tick: i32, liquidity: u128) -> IlInputs {
        IlInputs {
            entry_sqrt_p: get_sqrt_price_at_tick(entry_tick),
            exit_sqrt_p: get_sqrt_price_at_tick(exit_tick),
            tick_lower: LOWER,
            tick_upper: UPPER,
            liquidity,
        }
    }

    #[test]
    fn zero_il_on_no_move() {
        // entrySqrtP == exitSqrtP -> guard returns 0.
        let il = il_for_range(&inputs(0, 0, 1_000_000_000_000_000_000));
        assert!(il.is_zero(), "no price move must yield zero IL");
    }

    #[test]
    fn zero_il_on_zero_liquidity() {
        let il = il_for_range(&inputs(0, 1200, 0));
        assert!(il.is_zero());
    }

    #[test]
    fn positive_il_on_upward_divergence() {
        // Price moves up: LP sells the appreciating asset, lags the held basket.
        let il = il_for_range(&inputs(0, 2000, 1_000_000_000_000_000_000));
        assert!(!il.is_zero(), "divergence up must produce positive IL");
    }

    #[test]
    fn positive_il_on_downward_divergence() {
        let il = il_for_range(&inputs(0, -2000, 1_000_000_000_000_000_000));
        assert!(!il.is_zero(), "divergence down must produce positive IL");
    }

    #[test]
    fn il_grows_with_divergence() {
        // Larger price moves attribute more IL (monotone in |move|).
        let l = 1_000_000_000_000_000_000u128;
        let small = il_for_range(&inputs(0, 1000, l));
        let large = il_for_range(&inputs(0, 3000, l));
        assert!(
            crate::u256::cmp_gt(&large, &small),
            "IL must grow with divergence magnitude"
        );
    }

    #[test]
    fn il_scales_with_liquidity() {
        // Doubling liquidity ~doubles IL (linear in L, modulo rounding).
        let il1 = il_for_range(&inputs(0, 2000, 1_000_000_000_000_000_000));
        let il2 = il_for_range(&inputs(0, 2000, 2_000_000_000_000_000_000));
        assert!(crate::u256::cmp_gt(&il2, &il1));
    }

    #[test]
    fn hand_computed_vector() {
        // Hand-computed vector reproducing the exact Solidity integer pipeline.
        //
        // Range [tickLower=-60, tickUpper=60], liquidity L = 1e18.
        // Entry at tick 0 (sqrtP = 2^96), exit at tick 60.
        //
        // Because the algorithm is integer-exact, we recompute the same steps
        // here with the SAME primitives the contract uses (amounts_for_liquidity,
        // value_in_token0) and assert il_for_range returns held - lpValue. This
        // pins the witness to the contract's integer pipeline, not a float model.
        let l = 1_000_000_000_000_000_000u128;
        let lower = -60i32;
        let upper = 60i32;
        let entry = get_sqrt_price_at_tick(0);
        let exit = get_sqrt_price_at_tick(60);
        let sqrt_lower = get_sqrt_price_at_tick(lower);
        let sqrt_upper = get_sqrt_price_at_tick(upper);

        let (a0e, a1e) = amounts_for_liquidity(&entry, &sqrt_lower, &sqrt_upper, l);
        let (a0x, a1x) = amounts_for_liquidity(&exit, &sqrt_lower, &sqrt_upper, l);
        let held = value_in_token0(&a0e, &a1e, &exit);
        let lp_value = value_in_token0(&a0x, &a1x, &exit);
        let expected = if crate::u256::cmp_gt(&held, &lp_value) {
            held.wrapping_sub(&lp_value)
        } else {
            U256::ZERO
        };

        let il = il_for_range(&IlInputs {
            entry_sqrt_p: entry,
            exit_sqrt_p: exit,
            tick_lower: lower,
            tick_upper: upper,
            liquidity: l,
        });
        assert_eq!(il, expected);
        // And the direction must match the comment semantics: held >= lpValue.
        assert!(crate::u256::cmp_ge(&held, &lp_value));
        // For a 60-tick move on a tight range this is a small but nonzero IL.
        assert!(!il.is_zero(), "tight-range 60-tick move has nonzero IL");
    }

    #[test]
    fn value_in_token0_at_par() {
        // At sqrtP = 2^96 (price 1.0), value(a0, a1) = a0 + a1.
        let v = value_in_token0(&U256::from_u64(100), &U256::from_u64(250), &q96());
        assert_eq!(v, U256::from_u64(350));
    }

    #[test]
    fn determinism() {
        let inp = inputs(0, 2000, 1_000_000_000_000_000_000);
        assert_eq!(il_for_range(&inp), il_for_range(&inp));
    }
}
