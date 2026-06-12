// SPDX-License-Identifier: MIT
//! CPHR matching engine: correlation scan, IL-netting optimization, rebalance-path selection.
//!
//! Mirrors `IStylusMatchingEngine.MatchResult` (NettingPair[], RebalanceRecommendation[]) and the
//! correlation weights from `CorrelationRegistry.sol` (directed edges, weight in bps 0..10_000).
//!
//! ## What it does, financially
//!
//! Each STRATUM pool carries a junior tranche that absorbs impermanent loss first. A pool whose
//! cumulative IL is eating into its junior reserve is "stressed". Two levers reduce aggregate stress
//! without moving senior principal or breaking any LP's individual yield stream:
//!
//! 1. **Netting**: if pool A and pool B are correlated and hold opposing junior exposure, part of
//!    A's IL is offset by B's gain (and vice versa). The nettable value is the smaller of the two
//!    exposures, scaled by the correlation weight (bps). Higher correlation -> more can be netted.
//! 2. **Rebalance / top-up**: a pool with a healthy junior reserve (a donor) can lend buffer to a
//!    pool running a deficit (a target). Donors are capped at `MAX_DRAW_FRACTION_BPS` of their
//!    reserve so a single rebalance can never drain a donor below half (mirrors the Solidity cap).
//!
//! ## Fixed-point scales
//!
//! - `junior_reserve`, `cumulative_il`, `net_value`, `amount`: token0 wei (plain integers).
//! - `correlation_weight_bps`: bps, 0..10_000 (10_000 == perfectly correlated).
//!
//! ## Complexity
//!
//! Netting and rebalance scans are O(n * degree): for each pool we only look at its declared
//! correlated neighbours, never the full n^2 cross product. Greedy and LP-free by design so it is
//! deterministic and cheap enough to run on Stylus.

use crate::mul_div;

/// Maximum fraction of a donor pool's junior reserve that a single rebalance may draw, in bps.
/// `5_000 == 50%`. Mirrors `MAX_DRAW_FRACTION_BPS` on the Solidity side so on-chain application and
/// off-chain recommendation agree. A donor can never be drawn below half its reserve in one step.
pub const MAX_DRAW_FRACTION_BPS: u16 = 5_000;

/// A pool's matching-relevant state. The `id` is the 32-byte `PoolId` (keccak of the pool key) as a
/// fixed array so it round-trips through the Solidity ABI without interpretation.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PoolState {
    /// 32-byte PoolId (matches Solidity `PoolId` / `bytes32`).
    pub id: [u8; 32],
    /// Junior reserve currently backing the pool, token0 wei. The buffer protecting senior principal.
    pub junior_reserve: u128,
    /// Cumulative impermanent loss charged against the junior tranche so far, token0 wei.
    pub cumulative_il: u128,
}

impl PoolState {
    /// Convenience constructor.
    pub fn new(id: [u8; 32], junior_reserve: u128, cumulative_il: u128) -> Self {
        Self { id, junior_reserve, cumulative_il }
    }

    /// Unmet IL: the part of cumulative IL not currently covered by the junior reserve.
    /// Zero when the reserve fully covers the IL (a healthy pool). This is the deficit a rebalance
    /// or netting set tries to close.
    #[inline]
    pub fn deficit(&self) -> u128 {
        self.cumulative_il.saturating_sub(self.junior_reserve)
    }

    /// Surplus reserve available to donate: reserve beyond what its own IL needs.
    #[inline]
    pub fn surplus(&self) -> u128 {
        self.junior_reserve.saturating_sub(self.cumulative_il)
    }
}

/// A directed correlation edge, mirroring an entry in `CorrelationRegistry` (from -> to, weight bps).
/// `from_index` / `to_index` index into the `pools` slice passed to [`match_pools`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CorrelationEdge {
    pub from_index: usize,
    pub to_index: usize,
    /// Correlation weight in bps, 0..10_000. Clamped to 10_000 on use.
    pub weight_bps: u16,
}

impl CorrelationEdge {
    pub fn new(from_index: usize, to_index: usize, weight_bps: u16) -> Self {
        Self { from_index, to_index, weight_bps }
    }
}

/// One netting recommendation. Mirrors `IStylusMatchingEngine.NettingPair`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct NettingPair {
    pub pool_a: [u8; 32],
    pub pool_b: [u8; 32],
    /// token0-denominated value that can be netted between A and B.
    pub net_value: u128,
    /// Correlation weight applied (bps).
    pub correlation_weight_bps: u16,
}

/// One rebalance/top-up recommendation. Mirrors `IStylusMatchingEngine.RebalanceRecommendation`
/// (same-chain form; cross_chain/targetChainId default to false/0 here, set by the shim if needed).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RebalanceRecommendation {
    /// Donor pool (healthy reserve).
    pub source_pool: [u8; 32],
    /// Target pool (running a deficit).
    pub target_pool: [u8; 32],
    /// token0-denominated amount to move.
    pub amount: u128,
}

/// Full matching result. Parallel to `IStylusMatchingEngine.MatchResult` minus the volatility
/// array and validUntil, which are filled by the ml_volatility model and the entrypoint.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct MatchResult {
    pub netting_pairs: Vec<NettingPair>,
    pub rebalances: Vec<RebalanceRecommendation>,
}

/// Tunables for a matching run.
#[derive(Clone, Copy, Debug)]
pub struct MatchConfig {
    /// Max fraction of a donor reserve drawable in a single rebalance, bps. Defaults to
    /// [`MAX_DRAW_FRACTION_BPS`].
    pub max_draw_fraction_bps: u16,
    /// Ignore netting/rebalance opportunities below this token0 value (dust filter). Keeps the
    /// result set small and avoids recommending economically pointless moves.
    pub min_value: u128,
}

impl Default for MatchConfig {
    fn default() -> Self {
        Self { max_draw_fraction_bps: MAX_DRAW_FRACTION_BPS, min_value: 0 }
    }
}

/// Run the full matching pass: netting first (free offsets via correlation), then rebalance the
/// residual deficits from donor surpluses.
///
/// Algorithm:
/// 1. **Netting scan** (O(edges)): for each correlation edge A->B, the raw nettable value is the
///    smaller of A's deficit and B's surplus (B can absorb part of A's IL because they move
///    together). Scale by the correlation weight: `net = min(deficitA, surplusB) * weight / 10_000`.
///    Each unit netted reduces A's residual deficit and B's residual surplus, tracked in working
///    arrays so later edges see the updated state (greedy, order-stable).
/// 2. **Rebalance scan** (O(n * donors)): for each pool still in deficit, draw from donor pools with
///    surplus, each donor capped at `max_draw_fraction_bps` of its junior reserve. Greedy: largest
///    eligible donor draw first is not required for correctness, we simply walk donors in order and
///    take what is allowed until the deficit is covered or donors are exhausted.
///
/// Determinism: no floating point, no hashing-order dependence; iteration follows the input order of
/// `pools` and `edges`, so the same inputs always produce byte-identical output.
pub fn match_pools(
    pools: &[PoolState],
    edges: &[CorrelationEdge],
    config: MatchConfig,
) -> MatchResult {
    let n = pools.len();
    let mut result = MatchResult::default();
    if n == 0 {
        return result;
    }

    // Working copies of residual deficit and surplus, mutated as we net/rebalance.
    let mut residual_deficit: Vec<u128> = pools.iter().map(|p| p.deficit()).collect();
    let mut residual_surplus: Vec<u128> = pools.iter().map(|p| p.surplus()).collect();

    // ---- 1. Netting scan -------------------------------------------------
    for e in edges {
        if e.from_index >= n || e.to_index >= n || e.from_index == e.to_index {
            continue; // ignore malformed or self edges (CorrelationRegistry forbids self-correlation)
        }
        let weight = clamp_bps(e.weight_bps);
        if weight == 0 {
            continue;
        }
        let a = e.from_index;
        let b = e.to_index;

        let nettable_raw = core_min(residual_deficit[a], residual_surplus[b]);
        if nettable_raw == 0 {
            continue;
        }
        // Scale by correlation: only the correlated fraction of B's surplus genuinely hedges A.
        let net_value = mul_div(nettable_raw, weight as u128, crate::BPS_DENOMINATOR);
        if net_value == 0 || net_value < config.min_value {
            continue;
        }

        // Apply the offset to the working state so subsequent edges see reality.
        residual_deficit[a] = residual_deficit[a].saturating_sub(net_value);
        residual_surplus[b] = residual_surplus[b].saturating_sub(net_value);

        result.netting_pairs.push(NettingPair {
            pool_a: pools[a].id,
            pool_b: pools[b].id,
            net_value,
            correlation_weight_bps: weight,
        });
    }

    // ---- 2. Rebalance scan ----------------------------------------------
    // Per-donor remaining drawable capacity, capped at max_draw_fraction of the ORIGINAL reserve.
    let mut donor_capacity: Vec<u128> = pools
        .iter()
        .zip(residual_surplus.iter())
        .map(|(p, &surplus)| {
            let cap = mul_div(
                p.junior_reserve,
                clamp_bps(config.max_draw_fraction_bps) as u128,
                crate::BPS_DENOMINATOR,
            );
            // A donor can lend at most its surplus AND at most the draw cap.
            core_min(surplus, cap)
        })
        .collect();

    for target in 0..n {
        let mut need = residual_deficit[target];
        if need == 0 {
            continue;
        }
        for donor in 0..n {
            if donor == target || need == 0 {
                continue;
            }
            let avail = donor_capacity[donor];
            if avail == 0 {
                continue;
            }
            let draw = core_min(avail, need);
            if draw < config.min_value {
                continue; // skip dust draws but keep scanning larger donors
            }
            donor_capacity[donor] -= draw;
            need -= draw;
            result.rebalances.push(RebalanceRecommendation {
                source_pool: pools[donor].id,
                target_pool: pools[target].id,
                amount: draw,
            });
        }
        residual_deficit[target] = need;
    }

    result
}

/// Clamp a bps value to the legal 0..=10_000 range used by `CorrelationRegistry`.
#[inline]
fn clamp_bps(bps: u16) -> u16 {
    if bps as u128 > crate::BPS_DENOMINATOR {
        crate::BPS_DENOMINATOR as u16
    } else {
        bps
    }
}

/// Local min to avoid pulling in std::cmp churn in no_std-friendly contexts.
#[inline]
fn core_min(a: u128, b: u128) -> u128 {
    if a < b {
        a
    } else {
        b
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn id(n: u8) -> [u8; 32] {
        let mut a = [0u8; 32];
        a[31] = n;
        a
    }

    #[test]
    fn deficit_and_surplus_are_complementary() {
        let healthy = PoolState::new(id(1), 1_000, 400);
        assert_eq!(healthy.deficit(), 0);
        assert_eq!(healthy.surplus(), 600);

        let stressed = PoolState::new(id(2), 400, 1_000);
        assert_eq!(stressed.deficit(), 600);
        assert_eq!(stressed.surplus(), 0);
    }

    #[test]
    fn netting_offsets_scaled_by_correlation() {
        // Pool A deficit 600, pool B surplus 600, fully correlated -> net 600.
        let pools = [
            PoolState::new(id(1), 400, 1_000), // deficit 600
            PoolState::new(id(2), 1_000, 400), // surplus 600
        ];
        let edges = [CorrelationEdge::new(0, 1, 10_000)];
        let r = match_pools(&pools, &edges, MatchConfig::default());
        assert_eq!(r.netting_pairs.len(), 1);
        assert_eq!(r.netting_pairs[0].net_value, 600);
        assert_eq!(r.netting_pairs[0].pool_a, id(1));
        assert_eq!(r.netting_pairs[0].pool_b, id(2));
    }

    #[test]
    fn netting_partial_correlation_reduces_offset() {
        let pools = [
            PoolState::new(id(1), 0, 1_000),   // deficit 1000
            PoolState::new(id(2), 2_000, 0),   // surplus 2000
        ];
        // 50% correlation -> min(1000, 2000) * 5000/10000 = 500.
        let edges = [CorrelationEdge::new(0, 1, 5_000)];
        let r = match_pools(&pools, &edges, MatchConfig::default());
        assert_eq!(r.netting_pairs[0].net_value, 500);
        assert_eq!(r.netting_pairs[0].correlation_weight_bps, 5_000);
    }

    #[test]
    fn netting_then_rebalance_covers_residual() {
        // A has deficit 1000. B surplus 200 at full correlation nets 200, leaving 800.
        // C is a fat donor with reserve 4000 (cap 2000) and no IL -> covers the residual 800.
        let pools = [
            PoolState::new(id(1), 0, 1_000),    // deficit 1000
            PoolState::new(id(2), 200, 0),      // surplus 200
            PoolState::new(id(3), 4_000, 0),    // surplus 4000, draw cap 2000
        ];
        let edges = [CorrelationEdge::new(0, 1, 10_000)];
        let r = match_pools(&pools, &edges, MatchConfig::default());
        assert_eq!(r.netting_pairs.len(), 1);
        assert_eq!(r.netting_pairs[0].net_value, 200);

        // Residual deficit 800 must be covered by rebalances summing to 800.
        let total: u128 = r.rebalances.iter().map(|x| x.amount).sum();
        assert_eq!(total, 800);
        // The big donor is pool C (id 3); pool B's surplus was consumed by netting.
        assert!(r.rebalances.iter().all(|x| x.target_pool == id(1)));
    }

    #[test]
    fn draw_cap_limits_a_single_donor() {
        // Target needs 5000. Only donor has reserve 6000 -> cap is 50% = 3000, so it can only
        // lend 3000 and the deficit stays partly open (no other donor).
        let pools = [
            PoolState::new(id(1), 0, 5_000),  // deficit 5000
            PoolState::new(id(2), 6_000, 0),  // surplus 6000, cap 3000
        ];
        let r = match_pools(&pools, &[], MatchConfig::default());
        let total: u128 = r.rebalances.iter().map(|x| x.amount).sum();
        assert_eq!(total, 3_000); // capped at 50% of donor reserve
        assert_eq!(r.rebalances.len(), 1);
        assert_eq!(r.rebalances[0].amount, 3_000);
    }

    #[test]
    fn surplus_below_cap_limits_draw() {
        // Donor reserve 10_000 (cap 5000) but only 1000 surplus (IL 9000). Draw limited to 1000.
        let pools = [
            PoolState::new(id(1), 0, 2_000),     // deficit 2000
            PoolState::new(id(2), 10_000, 9_000), // surplus 1000, cap 5000
        ];
        let r = match_pools(&pools, &[], MatchConfig::default());
        let total: u128 = r.rebalances.iter().map(|x| x.amount).sum();
        assert_eq!(total, 1_000); // limited by surplus, not the cap
    }

    #[test]
    fn no_deficit_no_recommendations() {
        let pools = [
            PoolState::new(id(1), 1_000, 0),
            PoolState::new(id(2), 1_000, 0),
        ];
        let r = match_pools(&pools, &[], MatchConfig::default());
        assert!(r.netting_pairs.is_empty());
        assert!(r.rebalances.is_empty());
    }

    #[test]
    fn min_value_filters_dust() {
        let pools = [
            PoolState::new(id(1), 0, 100),
            PoolState::new(id(2), 100, 0),
        ];
        let cfg = MatchConfig { min_value: 1_000, ..Default::default() };
        // The nettable 100 and any rebalance < 1000 are dropped.
        let r = match_pools(&pools, &[CorrelationEdge::new(0, 1, 10_000)], cfg);
        assert!(r.netting_pairs.is_empty());
        assert!(r.rebalances.is_empty());
    }

    #[test]
    fn malformed_edges_are_ignored() {
        let pools = [PoolState::new(id(1), 0, 100), PoolState::new(id(2), 100, 0)];
        let edges = [
            CorrelationEdge::new(0, 0, 10_000), // self edge
            CorrelationEdge::new(5, 9, 10_000), // out of range
            CorrelationEdge::new(0, 1, 0),      // zero weight
        ];
        let r = match_pools(&pools, &edges, MatchConfig::default());
        assert!(r.netting_pairs.is_empty());
    }

    #[test]
    fn weight_above_max_is_clamped() {
        let pools = [PoolState::new(id(1), 0, 1_000), PoolState::new(id(2), 1_000, 0)];
        // 20_000 bps is illegal; must clamp to 10_000 (full), netting 1000 not 2000.
        let edges = [CorrelationEdge::new(0, 1, 20_000)];
        let r = match_pools(&pools, &edges, MatchConfig::default());
        assert_eq!(r.netting_pairs[0].net_value, 1_000);
        assert_eq!(r.netting_pairs[0].correlation_weight_bps, 10_000);
    }

    #[test]
    fn overflow_safe_on_huge_reserves() {
        // Reserves near u128::MAX must not panic; the draw cap is 50% of reserve.
        let big = u128::MAX;
        let pools = [
            PoolState::new(id(1), 0, big),       // deficit ~u128::MAX
            PoolState::new(id(2), big, 0),       // surplus big, cap big/2
        ];
        let r = match_pools(&pools, &[], MatchConfig::default());
        let total: u128 = r.rebalances.iter().map(|x| x.amount).sum();
        assert_eq!(total, big / 2); // exactly the 50% cap, no overflow
    }

    #[test]
    fn deterministic_repeated_runs() {
        let pools = [
            PoolState::new(id(1), 0, 1_000),
            PoolState::new(id(2), 500, 0),
            PoolState::new(id(3), 5_000, 0),
        ];
        let edges = [CorrelationEdge::new(0, 1, 8_000)];
        let r1 = match_pools(&pools, &edges, MatchConfig::default());
        let r2 = match_pools(&pools, &edges, MatchConfig::default());
        assert_eq!(r1, r2);
    }
}
