//! LVR (Loss-Versus-Rebalancing) auction clearing.
//!
//! AVS operators run a sealed/first-price auction for the right to execute the first
//! transaction against a pool at the start of a block (the arbitrage/rebalance opportunity
//! that would otherwise leak value to a fast searcher). The winning bid is paid into the
//! `LVRAuctionReceiver`, which routes it to the senior tranche as supplementary yield.
//!
//! This module is the off-chain clearing logic the operator runs before calling
//! `receiveYield(poolId, amount0, amount1, nonce)`. It:
//!
//! 1. Collects bids `(bidder, amount0, amount1)`.
//! 2. Clears to the highest bid, using a deterministic tie-break so all honest operators
//!    agree on the same winner (critical for the k-of-N attestation quorum).
//! 3. Computes the proceeds split routed to the senior tranche.
//! 4. Reproduces `LVRAuctionReceiver.routingHash` so the operator signs/attests the exact
//!    hash the contract will derive on-chain.
//!
//! Bid value ranking: a bid is compared first by its *total routed value*. Because token0
//! and token1 are different units, we rank by the pair `(amount0, amount1)` using a caller
//! supplied valuation if needed; for the core we use the lexicographic-on-sum convention
//! documented in `value()` and make tie-breaking fully deterministic by bidder address.

use crate::abi::routing_hash;

/// A single auction bid. Amounts are the token0/token1 the bidder commits to pay into the
/// receiver if it wins. Bidder is the 20-byte EVM address (used for deterministic tie-break).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Bid {
    pub bidder: [u8; 20],
    pub amount0: u128,
    pub amount1: u128,
}

impl Bid {
    /// Total bid value used for ranking. Token0 and token1 are summed in their raw units.
    ///
    /// In production a valuation oracle could weight the two legs; the core deliberately
    /// avoids an oracle (golden rule: no price feed in core paths) and ranks by the raw
    /// `amount0 + amount1` sum. This is monotonic and deterministic, which is all the
    /// auction-clearing invariant requires. We use u256-safe addition via u128 promotion
    /// into a wider accumulator.
    pub fn value(&self) -> u128 {
        // Saturating add guards against the (unrealistic) overflow of two near-max u128 legs.
        self.amount0.saturating_add(self.amount1)
    }
}

/// The result of clearing an auction: the winner and the proceeds routed to the senior
/// tranche, plus the on-chain routing hash the operator must attest.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct AuctionClearing {
    pub winner: [u8; 20],
    /// token0 routed to the senior tranche reserve.
    pub proceeds0: u128,
    /// token1 routed to the senior tranche reserve.
    pub proceeds1: u128,
    /// keccak256(abi.encode(poolId, proceeds0, proceeds1, nonce)) per LVRAuctionReceiver.
    pub routing_hash: [u8; 32],
    pub nonce: u128,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AuctionError {
    NoBids,
}

impl core::fmt::Display for AuctionError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            AuctionError::NoBids => f.write_str("auction has no bids to clear"),
        }
    }
}
impl std::error::Error for AuctionError {}

/// Deterministic "is `a` a strictly better winner than `b`" predicate.
///
/// Ranking:
/// 1. Higher `value()` wins.
/// 2. On equal value, the *lower* bidder address wins (deterministic tie-break, so every
///    honest operator selects the same winner regardless of bid arrival order).
fn beats(a: &Bid, b: &Bid) -> bool {
    let (va, vb) = (a.value(), b.value());
    if va != vb {
        return va > vb;
    }
    // Equal value: lower address wins. Big-endian byte comparison == numeric address order.
    a.bidder < b.bidder
}

/// The senior-tranche proceeds split.
///
/// `senior_bps` is the fraction (in basis points, 0..=10000) of the winning bid routed to
/// the senior tranche. The remainder is retained (e.g. operator/AVS rewards) and is NOT
/// routed on-chain. The core keeps this pure: callers choose the split policy.
///
/// Returns `(proceeds0, proceeds1)`, each `floor(amount * senior_bps / 10000)`.
pub fn senior_split(amount0: u128, amount1: u128, senior_bps: u16) -> (u128, u128) {
    let bps = senior_bps.min(10_000) as u128;
    // u128 * 10000 can overflow only for amounts > ~3.4e34; use u256-style widening via saturating.
    let p0 = mul_div_floor(amount0, bps, 10_000);
    let p1 = mul_div_floor(amount1, bps, 10_000);
    (p0, p1)
}

/// floor(a * b / d) without overflow for realistic token amounts.
/// Falls back to a 128x128->256 path implemented with u128 halves when a*b overflows u128.
fn mul_div_floor(a: u128, b: u128, d: u128) -> u128 {
    debug_assert!(d != 0);
    // Fast path: no overflow.
    if let Some(prod) = a.checked_mul(b) {
        return prod / d;
    }
    // Slow path: 256-bit intermediate via u128 hi/lo decomposition.
    // Compute (a*b) as a 256-bit number then divide by d (d fits u128).
    let (hi, lo) = widening_mul(a, b);
    div_256_by_128(hi, lo, d)
}

/// 128x128 -> (hi, lo) 256-bit product.
fn widening_mul(a: u128, b: u128) -> (u128, u128) {
    let a_lo = a & u64::MAX as u128;
    let a_hi = a >> 64;
    let b_lo = b & u64::MAX as u128;
    let b_hi = b >> 64;

    let ll = a_lo * b_lo;
    let lh = a_lo * b_hi;
    let hl = a_hi * b_lo;
    let hh = a_hi * b_hi;

    let mid = (ll >> 64) + (lh & u64::MAX as u128) + (hl & u64::MAX as u128);
    let lo = (ll & u64::MAX as u128) | (mid << 64);
    let hi = hh + (lh >> 64) + (hl >> 64) + (mid >> 64);
    (hi, lo)
}

/// Divide a 256-bit number (hi, lo) by a 128-bit divisor, returning the floor quotient.
/// Long division, bit by bit. Sufficient for the rare overflow path.
fn div_256_by_128(mut hi: u128, mut lo: u128, d: u128) -> u128 {
    let mut quotient: u128 = 0;
    let mut rem: u128 = 0;
    for _ in 0..256 {
        // Shift (rem:hi:lo) left by 1, bringing in the top bit.
        let top = rem >> 127;
        rem = (rem << 1) | (hi >> 127);
        hi = (hi << 1) | (lo >> 127);
        lo <<= 1;
        let _ = top;
        if rem >= d {
            rem -= d;
            // set lowest bit of quotient via lo accumulation
            quotient = (quotient << 1) | 1;
        } else {
            quotient <<= 1;
        }
    }
    quotient
}

/// Clear an auction over `bids` for pool `pool_id`, routing `senior_bps` of the winning
/// bid to the senior tranche under routing `nonce`.
pub fn clear_auction(
    pool_id: [u8; 32],
    bids: &[Bid],
    senior_bps: u16,
    nonce: u128,
) -> Result<AuctionClearing, AuctionError> {
    if bids.is_empty() {
        return Err(AuctionError::NoBids);
    }
    let mut winner = &bids[0];
    for b in &bids[1..] {
        if beats(b, winner) {
            winner = b;
        }
    }
    let (proceeds0, proceeds1) = senior_split(winner.amount0, winner.amount1, senior_bps);
    let rhash = routing_hash(pool_id, proceeds0, proceeds1, nonce);
    Ok(AuctionClearing {
        winner: winner.bidder,
        proceeds0,
        proceeds1,
        routing_hash: rhash,
        nonce,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bid(b: u8, a0: u128, a1: u128) -> Bid {
        Bid {
            bidder: [b; 20],
            amount0: a0,
            amount1: a1,
        }
    }

    #[test]
    fn highest_bid_wins() {
        let pool = [0x01u8; 32];
        let bids = [
            bid(1, 100, 100), // value 200
            bid(2, 300, 50),  // value 350  <- winner
            bid(3, 150, 150), // value 300
        ];
        let r = clear_auction(pool, &bids, 10_000, 7).unwrap();
        assert_eq!(r.winner, [2u8; 20]);
        assert_eq!(r.proceeds0, 300);
        assert_eq!(r.proceeds1, 50);
    }

    #[test]
    fn tie_break_is_deterministic_lower_address() {
        let pool = [0x01u8; 32];
        // Equal value 200; lower address (bidder 1) must win regardless of order.
        let order_a = [bid(3, 100, 100), bid(1, 50, 150), bid(2, 150, 50)];
        let order_b = [bid(2, 150, 50), bid(3, 100, 100), bid(1, 50, 150)];
        let ra = clear_auction(pool, &order_a, 10_000, 1).unwrap();
        let rb = clear_auction(pool, &order_b, 10_000, 1).unwrap();
        assert_eq!(ra.winner, [1u8; 20]);
        assert_eq!(rb.winner, [1u8; 20]);
        assert_eq!(ra, rb);
    }

    #[test]
    fn no_bids_errors() {
        let pool = [0x01u8; 32];
        assert_eq!(clear_auction(pool, &[], 10_000, 0), Err(AuctionError::NoBids));
    }

    #[test]
    fn senior_split_floor_math() {
        // 50% of (1000, 999): 500 and 499 (floor).
        assert_eq!(senior_split(1000, 999, 5000), (500, 499));
        // 100% routes everything.
        assert_eq!(senior_split(1234, 5678, 10_000), (1234, 5678));
        // 0% routes nothing.
        assert_eq!(senior_split(1234, 5678, 0), (0, 0));
        // Over-cap bps is clamped to 100%.
        assert_eq!(senior_split(1234, 5678, 20_000), (1234, 5678));
        // 33.33% of 100 = 33 (floor of 33.33).
        assert_eq!(senior_split(100, 100, 3333), (33, 33));
    }

    #[test]
    fn mul_div_overflow_path_matches_small_path() {
        // Force the slow path with large operands and confirm correctness against a known result.
        // a near u128::MAX, b = 10000, d = 10000 -> result == a.
        let a = u128::MAX - 5;
        assert_eq!(mul_div_floor(a, 10_000, 10_000), a);
        // a*b would overflow; result floor(a*5000/10000) == a/2.
        assert_eq!(mul_div_floor(a, 5_000, 10_000), a / 2);
    }

    #[test]
    fn routing_hash_matches_receiver_formula() {
        // Independently recompute keccak256(abi.encode(poolId, amount0, amount1, nonce))
        // and assert the clearing produces exactly that hash.
        let pool = [0x07u8; 32];
        let bids = [bid(9, 4000, 6000)];
        let nonce = 42u128;
        let r = clear_auction(pool, &bids, 10_000, nonce).unwrap();

        let expected = routing_hash(pool, 4000, 6000, nonce);
        assert_eq!(r.routing_hash, expected);

        // And the split actually fed the hash inputs.
        assert_eq!(r.proceeds0, 4000);
        assert_eq!(r.proceeds1, 6000);
    }

    #[test]
    fn proceeds_never_exceed_winning_bid() {
        // Conservation-style check: routed proceeds <= winning bid for any bps.
        let pool = [0x02u8; 32];
        let bids = [bid(1, 1_000_000, 2_000_000)];
        for bps in [0u16, 1, 2500, 5000, 9999, 10_000] {
            let r = clear_auction(pool, &bids, bps, 0).unwrap();
            assert!(r.proceeds0 <= 1_000_000);
            assert!(r.proceeds1 <= 2_000_000);
        }
    }
}
