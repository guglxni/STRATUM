//! Minimal 256-bit unsigned integer with the exact operations the STRATUM
//! Brevis witness math needs, implemented in pure Rust with no dependencies.
//!
//! Why this exists: the witness must reproduce Solidity's `FullMath.mulDiv`
//! (a 512-bit-intermediate `floor(a*b/d)`) and `TickMath.getSqrtPriceAtTick`
//! (256-bit multiplies of Q128.128 magic constants) EXACTLY, bit for bit.
//! `u128` is not wide enough for the intermediate products, so we carry a
//! `U256` represented as four little-endian `u64` limbs and give it:
//!   - `mul` (wrapping mod 2^256, matching the EVM word),
//!   - `shr` / `shl`,
//!   - `mul_div_floor` with a full 512-bit intermediate (no phantom overflow),
//!   - comparison and the small set of arithmetic used by the tick formula.
//!
//! This is deliberately not a general bignum library; it is the smallest
//! surface that lets the IL witness match `ILMath.sol` to the last wei.

/// 256-bit unsigned integer, four little-endian 64-bit limbs.
/// `limbs[0]` is the least significant.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub struct U256 {
    pub limbs: [u64; 4],
}

impl U256 {
    pub const ZERO: U256 = U256 { limbs: [0, 0, 0, 0] };
    pub const ONE: U256 = U256 { limbs: [1, 0, 0, 0] };

    #[inline]
    pub const fn from_u128(v: u128) -> U256 {
        U256 {
            limbs: [v as u64, (v >> 64) as u64, 0, 0],
        }
    }

    #[inline]
    pub const fn from_u64(v: u64) -> U256 {
        U256 {
            limbs: [v, 0, 0, 0],
        }
    }

    #[inline]
    pub fn is_zero(&self) -> bool {
        self.limbs == [0, 0, 0, 0]
    }

    /// Fits in a u128 (top two limbs zero); used to surface results back to
    /// the public-input encoding, which is uint256 on-chain but always fits
    /// in 128 bits for the magnitudes STRATUM works with (token amounts).
    #[inline]
    pub fn to_u128(&self) -> Option<u128> {
        if self.limbs[2] == 0 && self.limbs[3] == 0 {
            Some((self.limbs[0] as u128) | ((self.limbs[1] as u128) << 64))
        } else {
            None
        }
    }

    /// Lossy low-128-bit view. Used only where the caller has already proven
    /// the value fits (e.g. amounts-for-liquidity results in the test vectors).
    #[inline]
    pub fn low_u128(&self) -> u128 {
        (self.limbs[0] as u128) | ((self.limbs[1] as u128) << 64)
    }

    /// Wrapping addition mod 2^256 (matches EVM `add`).
    pub fn wrapping_add(&self, other: &U256) -> U256 {
        let mut out = [0u64; 4];
        let mut carry = 0u128;
        for i in 0..4 {
            let s = self.limbs[i] as u128 + other.limbs[i] as u128 + carry;
            out[i] = s as u64;
            carry = s >> 64;
        }
        U256 { limbs: out }
    }

    /// Wrapping subtraction mod 2^256 (matches EVM `sub`).
    pub fn wrapping_sub(&self, other: &U256) -> U256 {
        let mut out = [0u64; 4];
        let mut borrow = 0i128;
        for i in 0..4 {
            let d = self.limbs[i] as i128 - other.limbs[i] as i128 - borrow;
            if d < 0 {
                out[i] = (d + (1i128 << 64)) as u64;
                borrow = 1;
            } else {
                out[i] = d as u64;
                borrow = 0;
            }
        }
        U256 { limbs: out }
    }

    /// Full 512-bit product of two U256 values, returned as (low, high).
    pub fn full_mul(&self, other: &U256) -> (U256, U256) {
        let mut res = [0u128; 8]; // 8 partial 64-bit columns with carries
        for i in 0..4 {
            let mut carry = 0u128;
            for j in 0..4 {
                let idx = i + j;
                let cur = res[idx] + (self.limbs[i] as u128) * (other.limbs[j] as u128) + carry;
                res[idx] = cur & 0xFFFF_FFFF_FFFF_FFFF;
                carry = cur >> 64;
            }
            res[i + 4] += carry;
        }
        let low = U256 {
            limbs: [res[0] as u64, res[1] as u64, res[2] as u64, res[3] as u64],
        };
        let high = U256 {
            limbs: [res[4] as u64, res[5] as u64, res[6] as u64, res[7] as u64],
        };
        (low, high)
    }

    /// Wrapping multiply mod 2^256 (matches EVM `mul`).
    pub fn wrapping_mul(&self, other: &U256) -> U256 {
        self.full_mul(other).0
    }

    /// Logical right shift by `n` bits.
    pub fn shr(&self, n: u32) -> U256 {
        if n == 0 {
            return *self;
        }
        if n >= 256 {
            return U256::ZERO;
        }
        let word = (n / 64) as usize;
        let bit = n % 64;
        let mut out = [0u64; 4];
        for i in 0..4 {
            let src = i + word;
            if src >= 4 {
                continue;
            }
            let mut v = self.limbs[src] >> bit;
            if bit != 0 && src + 1 < 4 {
                v |= self.limbs[src + 1] << (64 - bit);
            }
            out[i] = v;
        }
        U256 { limbs: out }
    }

    /// Logical left shift by `n` bits.
    pub fn shl(&self, n: u32) -> U256 {
        if n == 0 {
            return *self;
        }
        if n >= 256 {
            return U256::ZERO;
        }
        let word = (n / 64) as usize;
        let bit = n % 64;
        let mut out = [0u64; 4];
        for i in (0..4).rev() {
            if i < word {
                continue;
            }
            let src = i - word;
            let mut v = self.limbs[src] << bit;
            if bit != 0 && src >= 1 {
                v |= self.limbs[src - 1] >> (64 - bit);
            }
            out[i] = v;
        }
        U256 { limbs: out }
    }

    /// `floor(self * other / divisor)` with a full 512-bit intermediate so the
    /// product never loses precision to phantom overflow. This is the exact
    /// contract of Solidity's `FullMath.mulDiv`. Panics on divide-by-zero and
    /// on a result that would not fit in 256 bits, mirroring the Solidity
    /// `require(denominator > prod1)` guard.
    pub fn mul_div_floor(&self, other: &U256, divisor: &U256) -> U256 {
        assert!(!divisor.is_zero(), "mul_div: division by zero");
        let (low, high) = self.full_mul(other);
        // Result fits in 256 bits iff high < divisor (same guard FullMath uses).
        assert!(udiv512_lt(&high, divisor), "mul_div: result overflows 256 bits");
        udiv512(low, high, *divisor).0
    }
}

/// True if `a < b` for two U256 values (used as the overflow guard above).
fn udiv512_lt(a: &U256, b: &U256) -> bool {
    for i in (0..4).rev() {
        if a.limbs[i] != b.limbs[i] {
            return a.limbs[i] < b.limbs[i];
        }
    }
    false
}

/// True if a >= b.
fn ge(a: &U256, b: &U256) -> bool {
    !udiv512_lt(a, b)
}

/// Public strictly-greater-than comparison (a > b).
pub fn cmp_gt(a: &U256, b: &U256) -> bool {
    udiv512_lt(b, a)
}

/// Public greater-than-or-equal comparison (a >= b).
pub fn cmp_ge(a: &U256, b: &U256) -> bool {
    ge(a, b)
}

/// Divide a 512-bit numerator [high:low] by a 256-bit divisor using restoring
/// long division (bit by bit). Returns (quotient_low256, remainder). The
/// quotient is assumed to fit in 256 bits, which the caller guarantees via the
/// `high < divisor` guard. This is O(512) limb-ops, ample for witness use.
fn udiv512(low: U256, high: U256, divisor: U256) -> (U256, U256) {
    let mut quotient = U256::ZERO;
    let mut rem = U256::ZERO;
    // Iterate from the most significant bit of the 512-bit numerator down.
    for bit in (0..512).rev() {
        // rem = (rem << 1) | numerator_bit(bit)
        rem = rem.shl(1);
        let nbit = if bit >= 256 {
            (high.limbs[((bit - 256) / 64) as usize] >> ((bit - 256) % 64)) & 1
        } else {
            (low.limbs[(bit / 64) as usize] >> (bit % 64)) & 1
        };
        if nbit == 1 {
            rem.limbs[0] |= 1;
        }
        if ge(&rem, &divisor) {
            rem = rem.wrapping_sub(&divisor);
            if bit < 256 {
                quotient.limbs[(bit / 64) as usize] |= 1u64 << (bit % 64);
            }
        }
    }
    (quotient, rem)
}

/// Parse a hex string (no `0x` prefix) into a U256. Test/const helper for the
/// large Q128.128 tick constants. Big-endian hex.
pub fn from_hex(s: &str) -> U256 {
    let s = s.trim_start_matches("0x");
    let mut out = U256::ZERO;
    for c in s.chars() {
        let d = c.to_digit(16).expect("invalid hex digit") as u64;
        out = out.shl(4);
        out.limbs[0] |= d;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn add_sub_roundtrip() {
        let a = U256::from_u128(u128::MAX);
        let b = U256::from_u128(12345);
        let c = a.wrapping_add(&b);
        assert_eq!(c.wrapping_sub(&b), a);
    }

    #[test]
    fn mul_div_simple() {
        // 6 * 7 / 3 = 14
        let r = U256::from_u64(6).mul_div_floor(&U256::from_u64(7), &U256::from_u64(3));
        assert_eq!(r, U256::from_u64(14));
    }

    #[test]
    fn mul_div_no_phantom_overflow() {
        // (2^200 * 2^60) / 2^240 = 2^20, an intermediate that overflows 256 bits
        // mod 2^256 but is exact with the 512-bit path.
        let a = U256::ONE.shl(200);
        let b = U256::ONE.shl(60);
        let d = U256::ONE.shl(240);
        let r = a.mul_div_floor(&b, &d);
        assert_eq!(r, U256::ONE.shl(20));
    }

    #[test]
    fn mul_div_floor_truncates() {
        // 7 * 1 / 2 = 3 (floor)
        let r = U256::from_u64(7).mul_div_floor(&U256::ONE, &U256::from_u64(2));
        assert_eq!(r, U256::from_u64(3));
    }

    #[test]
    fn shift_consistency() {
        let v = U256::from_u128(0xABCD_1234_5678);
        assert_eq!(v.shl(96).shr(96), v);
    }

    #[test]
    fn hex_parse() {
        assert_eq!(from_hex("0x100000000000000000000000000000000"), U256::ONE.shl(128));
    }

    #[test]
    fn full_mul_high_low() {
        // (2^128) * (2^128) = 2^256 -> low = 0, high = 1
        let a = U256::ONE.shl(128);
        let (low, high) = a.full_mul(&a);
        assert!(low.is_zero());
        assert_eq!(high, U256::ONE);
    }
}
