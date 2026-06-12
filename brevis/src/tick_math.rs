//! Faithful Rust port of `TickMath.getSqrtPriceAtTick` and the price helper
//! `FixedPoint96.Q96`, so the IL witness can derive the exact tick-boundary
//! sqrt prices the on-chain `ILMath.ilForRange` uses.
//!
//! The algorithm is the canonical Uniswap one: decompose `|tick|` into bits
//! and multiply the precomputed Q128.128 factors `1/sqrt(1.0001^(2^i))`,
//! invert for positive ticks, then round-up-shift from Q128.128 to Q64.96.
//! Constants are copied verbatim from the v4-core source so the result is
//! bit-identical to `getSqrtPriceAtTick`.

use crate::u256::{from_hex, U256};

/// Q96 = 2^96, the `FixedPoint96.Q96` constant.
pub fn q96() -> U256 {
    U256::ONE.shl(96)
}

/// `TickMath.MIN_TICK` and `MAX_TICK`.
pub const MIN_TICK: i32 = -887272;
pub const MAX_TICK: i32 = 887272;

/// The 19 Q128.128 magic factors, indexed by bit position of `absTick`.
/// `MAGIC[i]` corresponds to the `absTick & (1<<i)` branch in the Solidity.
fn magic(i: usize) -> U256 {
    const HEX: [&str; 20] = [
        "fffcb933bd6fad37aa2d162d1a594001", // 0x1
        "fff97272373d413259a46990580e213a", // 0x2
        "fff2e50f5f656932ef12357cf3c7fdcc", // 0x4
        "ffe5caca7e10e4e61c3624eaa0941cd0", // 0x8
        "ffcb9843d60f6159c9db58835c926644", // 0x10
        "ff973b41fa98c081472e6896dfb254c0", // 0x20
        "ff2ea16466c96a3843ec78b326b52861", // 0x40
        "fe5dee046a99a2a811c461f1969c3053", // 0x80
        "fcbe86c7900a88aedcffc83b479aa3a4", // 0x100
        "f987a7253ac413176f2b074cf7815e54", // 0x200
        "f3392b0822b70005940c7a398e4b70f3", // 0x400
        "e7159475a2c29b7443b29c7fa6e889d9", // 0x800
        "d097f3bdfd2022b8845ad8f792aa5825", // 0x1000
        "a9f746462d870fdf8a65dc1f90e061e5", // 0x2000
        "70d869a156d2a1b890bb3df62baf32f7", // 0x4000
        "31be135f97d08fd981231505542fcfa6", // 0x8000
        "9aa508b5b7a84e1c677de54f3e99bc9",  // 0x10000
        "5d6af8dedb81196699c329225ee604",   // 0x20000
        "2216e584f5fa1ea926041bedfe98",     // 0x40000
        "48a170391f7dc42444e8fa2",          // 0x80000
    ];
    from_hex(HEX[i])
}

/// `2^256 - 1`, used for the positive-tick inversion `not(0) / price`.
fn max_u256() -> U256 {
    U256 {
        limbs: [u64::MAX; 4],
    }
}

/// Reproduces `TickMath.getSqrtPriceAtTick(tick)` exactly, returning the
/// Q64.96 sqrt price. Panics if `|tick| > MAX_TICK` (mirrors `InvalidTick`).
pub fn get_sqrt_price_at_tick(tick: i32) -> U256 {
    let abs_tick = tick.unsigned_abs() as u64;
    assert!(abs_tick <= MAX_TICK as u64, "InvalidTick");

    // price starts as 2^128 (1.0 in Q128.128), then bit 0 swaps in the first
    // magic factor, matching the `xor(shl(128,1), mul(...))` initialiser.
    let one_q128 = U256::ONE.shl(128);
    let mut price = if abs_tick & 0x1 != 0 {
        magic(0)
    } else {
        one_q128
    };

    // Bits 1..=19: multiply and shift right 128 to stay in Q128.128.
    for i in 1..20usize {
        if abs_tick & (1u64 << i) != 0 {
            price = price.wrapping_mul(&magic(i)).shr(128);
        }
    }

    // Positive ticks: price = type(uint256).max / price.
    if tick > 0 {
        price = max_u256().mul_div_floor(&U256::ONE, &price);
    }

    // Q128.128 -> Q128.96, rounding up: (price + (2^32 - 1)) >> 32.
    let round = U256::from_u64((1u64 << 32) - 1);
    price.wrapping_add(&round).shr(32)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tick_zero_is_q96() {
        // sqrt(1.0001^0) * 2^96 == 2^96.
        assert_eq!(get_sqrt_price_at_tick(0), q96());
    }

    #[test]
    fn known_boundary_values() {
        // MIN_SQRT_PRICE and MAX_SQRT_PRICE from TickMath.sol.
        assert_eq!(
            get_sqrt_price_at_tick(MIN_TICK).to_u128().unwrap(),
            4295128739u128
        );
        // MAX_SQRT_PRICE exceeds u128; compare the full U256.
        let max_sqrt = crate::u256::from_hex("fffd8963efd1fc6a506488495d951d5263988d26"); // 1461446703485210103287273052203988822378723970342
        assert_eq!(get_sqrt_price_at_tick(MAX_TICK), max_sqrt);
    }

    #[test]
    fn symmetric_about_zero() {
        // getSqrtPriceAtTick(t) * getSqrtPriceAtTick(-t) ~= 2^192 (since the
        // product of price and 1/price in Q128.128 round-trips). We just check
        // monotonicity and that +/- are on opposite sides of Q96 here.
        let up = get_sqrt_price_at_tick(1000);
        let down = get_sqrt_price_at_tick(-1000);
        assert!(super::super::u256::cmp_gt(&up, &q96()));
        assert!(super::super::u256::cmp_gt(&q96(), &down));
    }

    #[test]
    fn monotonic_increasing() {
        let a = get_sqrt_price_at_tick(100);
        let b = get_sqrt_price_at_tick(200);
        assert!(super::super::u256::cmp_gt(&b, &a));
    }
}
