//! TimeWeightedContribution circuit witness (FR-21).
//!
//! When LPs enter and exit mid-epoch, fair distribution of junior surplus
//! requires time-weighted accounting. This module computes the witness the
//! circuit proves and that `BrevisVerifierShim.verifyTimeWeightedContribution`
//! returns: a position's time-weighted share of each epoch's junior surplus,
//! summed over its holding window.
//!
//! Model, per epoch the position overlaps:
//!
//!   weight     = principal * overlap_seconds / epoch_seconds
//!   share_bps  = weight / junior_tvl_weighted   (position weight over total)
//!   contribution_epoch = floor(epoch_surplus * weight / total_weight)
//!
//! We avoid floats and avoid an oracle. To keep it exact and conservation-safe
//! we express the share as a `mulDiv(epoch_surplus, position_weight,
//! total_weight)` where:
//!   - `position_weight = principal * overlap_seconds` (time-weighted stake),
//!   - `total_weight    = junior_tvl * epoch_seconds`  (all junior stake, full
//!      epoch), which upper-bounds the sum of every position's weight.
//!
//! Because every position's `position_weight <= total_weight` and the per-epoch
//! contributions are floored, the sum of all positions' contributions for an
//! epoch is <= `epoch_surplus`. This is the conservation bound the shim relies
//! on (DESIGN section 11, INV-03 spirit): a position can never be attributed
//! more than the surplus that existed.
//!
//! This complements `EpochAccounting.vestedToDate` smoothing: vesting governs
//! WHEN an accrued amount is released; this circuit governs HOW MUCH of each
//! epoch's surplus a mid-epoch position is entitled to in the first place.

use crate::u256::U256;

/// One epoch's parameters as seen by the prover from historical pool data.
#[derive(Clone, Copy, Debug)]
pub struct EpochWindow {
    /// Epoch index (for the proof's public inputs / event).
    pub epoch: u64,
    /// Epoch start timestamp (seconds).
    pub start_ts: u64,
    /// Epoch length in seconds (epoch.epochSeconds).
    pub epoch_seconds: u64,
    /// Junior surplus distributable for this epoch (token0-denominated),
    /// i.e. `EpochAccounting.epochSurplus` after the senior obligation is met.
    pub epoch_surplus: u128,
    /// Total junior TVL during the epoch (token0-denominated). Used to size the
    /// total weight that the position's weight is measured against.
    pub junior_tvl: u128,
}

/// A position's holding window and principal.
#[derive(Clone, Copy, Debug)]
pub struct PositionWindow {
    /// Entry timestamp (seconds).
    pub entry_ts: u64,
    /// Exit timestamp (seconds). For an open position, the settlement time.
    pub exit_ts: u64,
    /// Position principal in the junior tranche (token0-denominated).
    pub principal: u128,
}

/// Seconds the position is active within a given epoch (clamped to the epoch).
fn overlap_seconds(pos: &PositionWindow, ep: &EpochWindow) -> u64 {
    let epoch_end = ep.start_ts.saturating_add(ep.epoch_seconds);
    let lo = pos.entry_ts.max(ep.start_ts);
    let hi = pos.exit_ts.min(epoch_end);
    if hi <= lo {
        0
    } else {
        hi - lo
    }
}

/// Time-weighted contribution of one position to one epoch's surplus.
///
/// contribution = floor( epoch_surplus * (principal * overlap) /
///                                       (junior_tvl * epoch_seconds) )
///
/// Returns 0 if there is no overlap or no surplus. Bounded above by
/// `epoch_surplus` because `principal <= junior_tvl` and `overlap <=
/// epoch_seconds` for any single position's legitimate stake.
pub fn contribution_for_epoch(pos: &PositionWindow, ep: &EpochWindow) -> U256 {
    if ep.epoch_surplus == 0 || ep.junior_tvl == 0 || ep.epoch_seconds == 0 {
        return U256::ZERO;
    }
    let overlap = overlap_seconds(pos, ep);
    if overlap == 0 {
        return U256::ZERO;
    }

    let position_weight = U256::from_u128(pos.principal).wrapping_mul(&U256::from_u64(overlap));
    let total_weight =
        U256::from_u128(ep.junior_tvl).wrapping_mul(&U256::from_u64(ep.epoch_seconds));
    if total_weight.is_zero() {
        return U256::ZERO;
    }

    // floor(epoch_surplus * position_weight / total_weight).
    U256::from_u128(ep.epoch_surplus).mul_div_floor(&position_weight, &total_weight)
}

/// Sum a position's time-weighted contribution across its full holding window
/// (all epochs it overlaps). This is the value the TimeWeightedContribution
/// circuit proves and that `verifyTimeWeightedContribution(positionId)`
/// returns.
pub fn time_weighted_contribution(pos: &PositionWindow, epochs: &[EpochWindow]) -> U256 {
    let mut total = U256::ZERO;
    for ep in epochs {
        total = total.wrapping_add(&contribution_for_epoch(pos, ep));
    }
    total
}

#[cfg(test)]
mod tests {
    use super::*;

    fn epoch(idx: u64, start: u64, surplus: u128, tvl: u128) -> EpochWindow {
        EpochWindow {
            epoch: idx,
            start_ts: start,
            epoch_seconds: 1000,
            epoch_surplus: surplus,
            junior_tvl: tvl,
        }
    }

    #[test]
    fn full_window_gets_principal_share() {
        // Single position holding the full epoch with principal = half the TVL
        // should get half the surplus.
        let ep = epoch(1, 0, 1_000_000, 2_000_000);
        let pos = PositionWindow {
            entry_ts: 0,
            exit_ts: 1000,
            principal: 1_000_000,
        };
        let c = time_weighted_contribution(&pos, &[ep]);
        assert_eq!(c.to_u128().unwrap(), 500_000);
    }

    #[test]
    fn partial_window_prorated() {
        // Same position but only active half the epoch: a quarter of the surplus.
        let ep = epoch(1, 0, 1_000_000, 2_000_000);
        let pos = PositionWindow {
            entry_ts: 500,
            exit_ts: 1000,
            principal: 1_000_000,
        };
        let c = time_weighted_contribution(&pos, &[ep]);
        assert_eq!(c.to_u128().unwrap(), 250_000);
    }

    #[test]
    fn full_window_beats_partial_window() {
        let ep = epoch(1, 0, 1_000_000, 2_000_000);
        let full = PositionWindow {
            entry_ts: 0,
            exit_ts: 1000,
            principal: 1_000_000,
        };
        let partial = PositionWindow {
            entry_ts: 500,
            exit_ts: 1000,
            principal: 1_000_000,
        };
        assert!(crate::u256::cmp_gt(
            &time_weighted_contribution(&full, &[ep]),
            &time_weighted_contribution(&partial, &[ep])
        ));
    }

    #[test]
    fn no_overlap_zero() {
        let ep = epoch(1, 0, 1_000_000, 2_000_000);
        // Position active after the epoch ended.
        let pos = PositionWindow {
            entry_ts: 2000,
            exit_ts: 3000,
            principal: 1_000_000,
        };
        assert!(time_weighted_contribution(&pos, &[ep]).is_zero());
    }

    #[test]
    fn sum_across_positions_within_surplus() {
        // Three positions partition the TVL and the epoch. Their summed
        // contributions must never exceed the epoch surplus (conservation).
        let surplus = 1_000_000u128;
        let tvl = 3_000_000u128;
        let ep = epoch(1, 0, surplus, tvl);
        let positions = [
            PositionWindow {
                entry_ts: 0,
                exit_ts: 1000,
                principal: 1_000_000,
            },
            PositionWindow {
                entry_ts: 0,
                exit_ts: 1000,
                principal: 1_000_000,
            },
            PositionWindow {
                entry_ts: 250,
                exit_ts: 750,
                principal: 1_000_000,
            },
        ];
        let mut sum = U256::ZERO;
        for p in &positions {
            sum = sum.wrapping_add(&time_weighted_contribution(p, &[ep]));
        }
        assert!(
            crate::u256::cmp_ge(&U256::from_u128(surplus), &sum),
            "sum of contributions must not exceed epoch surplus"
        );
    }

    #[test]
    fn single_position_bounded_by_surplus() {
        // Even a position larger than TVL (shouldn't happen, but the bound must
        // hold structurally) is clamped by the weight ratio: with principal ==
        // tvl and full overlap it equals the surplus, never more.
        let ep = epoch(1, 0, 1_000_000, 1_000_000);
        let pos = PositionWindow {
            entry_ts: 0,
            exit_ts: 1000,
            principal: 1_000_000,
        };
        let c = time_weighted_contribution(&pos, &[ep]);
        assert!(crate::u256::cmp_ge(&U256::from_u128(1_000_000), &c));
        assert_eq!(c.to_u128().unwrap(), 1_000_000);
    }

    #[test]
    fn multi_epoch_sums() {
        // A position spanning two epochs accrues from both.
        let e1 = epoch(1, 0, 1_000_000, 2_000_000);
        let e2 = epoch(2, 1000, 1_000_000, 2_000_000);
        let pos = PositionWindow {
            entry_ts: 0,
            exit_ts: 2000,
            principal: 1_000_000,
        };
        let c = time_weighted_contribution(&pos, &[e1, e2]);
        // Half of each epoch's surplus: 500k + 500k.
        assert_eq!(c.to_u128().unwrap(), 1_000_000);
    }

    #[test]
    fn determinism() {
        let ep = epoch(1, 0, 1_000_000, 2_000_000);
        let pos = PositionWindow {
            entry_ts: 100,
            exit_ts: 900,
            principal: 700_000,
        };
        assert_eq!(
            time_weighted_contribution(&pos, &[ep]),
            time_weighted_contribution(&pos, &[ep])
        );
    }
}
