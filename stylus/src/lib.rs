// SPDX-License-Identifier: MIT
//! STRATUM Stylus compute layer (pure-Rust core).
//!
//! This crate is the off-chain-equivalent, on-chain-deployable compute layer described in
//! ARCHITECTURE.md section 8 and TECHNICAL_DESIGN.md section 10. It does the two compute-heavy jobs that
//! are gas-prohibitive in Solidity:
//!
//! 1. [`matching`] - the CPHR (Cross-Pool Hedging Router) matching engine: correlation scan,
//!    IL-netting optimization, and rebalance-path selection across correlated STRATUM pools.
//! 2. [`ml_volatility`] - the forward-volatility model: an online EWMA baseline plus a lightweight
//!    online predictor (GARCH(1,1)-lite) that forecasts next-step volatility so the hook can set
//!    dynamic fees proactively instead of reactively.
//!
//! The outputs mirror the Solidity `IStylusMatchingEngine.MatchResult` struct so the
//! `peripherals/stylus/StylusShim.sol` consumer can ABI-decode them unchanged:
//! - netting pairs (poolA, poolB, netValue, correlationWeightBps)
//! - rebalance recommendations (sourcePool, targetPool, amount)
//! - `predictedVolatilityEWMA[]` parallel to the submitted pools
//! - `validUntil` staleness bound
//!
//! ## Fixed-point scales (read this before touching the math)
//!
//! - Basis points (`bps`): integer fraction out of `10_000`. `10_000 == 100%`.
//! - Volatility EWMA: WAD fixed point, `1e18 == 1.0`. This matches the hook's on-chain
//!   `PoolTrancheState.volatilityEWMA`, which is `delta(sqrtPrice) / prevSqrtPrice` scaled by
//!   `1e18` (see `src/libraries/ILMath.sol::updateVolatilityEWMA`). A value of `1e16` therefore
//!   means a 1% instantaneous sqrt-price move.
//! - Reserves / IL / netValue / amounts: token0-denominated integers (wei). No implicit scaling.
//!
//! All bps math uses u128 intermediates (mulDiv-style) so reserve-by-bps products cannot overflow.

#![cfg_attr(not(feature = "stylus"), allow(dead_code))]
// The Stylus WASM artifact has no Rust `main`; the entrypoint is the SDK-generated user_entrypoint.
// `no_main` applies only when building the on-chain contract (feature = "stylus"), and never for
// `cargo test` or `cargo stylus export-abi`, both of which need a real main.
#![cfg_attr(
    all(feature = "stylus", not(any(test, feature = "export-abi"))),
    no_main
)]

pub mod matching;
pub mod ml_volatility;

// The Stylus contract entrypoint is feature-gated so the stock `cargo test` build never needs the
// stylus-sdk. It is documented and ABI-faithful, but only compiles under `--features stylus`.
#[cfg(feature = "stylus")]
pub mod stylus_entrypoint;

pub use matching::{
    match_pools, MatchConfig, MatchResult, NettingPair, PoolState, RebalanceRecommendation,
    MAX_DRAW_FRACTION_BPS,
};
pub use ml_volatility::{VolForecast, VolModel, VOL_EWMA_WAD};

/// WAD scale: `1e18` represents `1.0`. Shared by the volatility EWMA and any ratio math.
pub const WAD: u128 = 1_000_000_000_000_000_000;

/// Basis-point denominator: `10_000 == 100%`.
pub const BPS_DENOMINATOR: u128 = 10_000;

/// Overflow-safe `floor(a * b / denom)` using a u128 intermediate widened to u256-equivalent via
/// the split-multiply trick is not required here because all callers keep `a` within token-reserve
/// range and `b <= 10_000`; a plain u128 product is sufficient and checked. Returns 0 on a zero
/// denominator (treated as "no fraction") rather than panicking, so a misconfigured weight can never
/// halt a matching run on-chain.
#[inline]
pub fn mul_div(a: u128, b: u128, denom: u128) -> u128 {
    if denom == 0 {
        return 0;
    }
    // u128 * u128 can overflow; widen to u256 via the high/low split to stay safe for full-range
    // reserves multiplied by bps. Because b <= 10_000 in every caller this is belt-and-suspenders.
    mul_div_u256(a, b, denom)
}

/// Full-width `floor(a * b / denom)` computed through a 256-bit intermediate built from two u128
/// halves. Pure integer arithmetic, no external crates. Returns 0 when `denom == 0`.
#[inline]
fn mul_div_u256(a: u128, b: u128, denom: u128) -> u128 {
    if denom == 0 {
        return 0;
    }
    // Fast path: product fits in u128.
    if let Some(prod) = a.checked_mul(b) {
        return prod / denom;
    }
    // Slow path: 256-bit long division. Build the 256-bit product as (hi, lo).
    let (hi, lo) = mul_full(a, b);
    div_256_by_128(hi, lo, denom)
}

/// 128x128 -> 256 multiply, returning (high 128 bits, low 128 bits).
#[inline]
fn mul_full(a: u128, b: u128) -> (u128, u128) {
    let a_lo = a & 0xFFFF_FFFF_FFFF_FFFF;
    let a_hi = a >> 64;
    let b_lo = b & 0xFFFF_FFFF_FFFF_FFFF;
    let b_hi = b >> 64;

    let ll = a_lo * b_lo;
    let lh = a_lo * b_hi;
    let hl = a_hi * b_lo;
    let hh = a_hi * b_hi;

    let mid = (ll >> 64) + (lh & 0xFFFF_FFFF_FFFF_FFFF) + (hl & 0xFFFF_FFFF_FFFF_FFFF);
    let lo = (ll & 0xFFFF_FFFF_FFFF_FFFF) | (mid << 64);
    let hi = hh + (lh >> 64) + (hl >> 64) + (mid >> 64);
    (hi, lo)
}

/// Divide the 256-bit value (hi, lo) by a u128 divisor, returning a u128 quotient.
/// Long division over 256 bits, bit by bit. Saturates if the true quotient exceeds u128::MAX
/// (cannot happen for our callers because denom keeps the result token-sized).
#[inline]
fn div_256_by_128(mut hi: u128, mut lo: u128, denom: u128) -> u128 {
    if denom == 0 {
        return 0;
    }
    let mut quotient: u128 = 0;
    let mut rem: u128 = 0;
    let mut i = 256;
    while i > 0 {
        i -= 1;
        // Shift remainder left by one and bring in the next bit of (hi, lo).
        let next_bit = if i >= 128 {
            (hi >> (i - 128)) & 1
        } else {
            (lo >> i) & 1
        };
        rem = (rem << 1) | next_bit;
        if rem >= denom {
            rem -= denom;
            if i < 128 {
                quotient |= 1u128 << i;
            }
            // bits >= 128 in the quotient would overflow u128: saturate.
            else {
                return u128::MAX;
            }
        }
    }
    let _ = (&mut hi, &mut lo);
    quotient
}

#[cfg(test)]
mod mul_div_tests {
    use super::*;

    #[test]
    fn mul_div_basic() {
        assert_eq!(mul_div(1_000, 5_000, BPS_DENOMINATOR), 500); // 50% of 1000
        assert_eq!(mul_div(0, 5_000, BPS_DENOMINATOR), 0);
        assert_eq!(mul_div(1_000, 0, BPS_DENOMINATOR), 0);
    }

    #[test]
    fn mul_div_zero_denom_safe() {
        assert_eq!(mul_div(1_000, 5_000, 0), 0);
    }

    #[test]
    fn mul_div_no_overflow_full_range() {
        // u128::MAX * 10_000 overflows u128; the 256-bit path must handle it.
        let a = u128::MAX;
        let got = mul_div(a, 5_000, BPS_DENOMINATOR);
        // 50% of u128::MAX, floored.
        assert_eq!(got, a / 2);
    }

    #[test]
    fn mul_div_matches_naive_when_small() {
        for a in [1u128, 7, 100, 999_999] {
            for b in [1u128, 3, 9_999, 10_000] {
                assert_eq!(mul_div(a, b, BPS_DENOMINATOR), a * b / BPS_DENOMINATOR);
            }
        }
    }
}
