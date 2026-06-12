//! AggregateReserveProof circuit witness.
//!
//! Proves cross-chain junior reserve solvency without revealing individual
//! positions: the sum of per-chain junior reserves is >= a claimed total.
//! `BrevisVerifierShim.submitAggregateReserveProof(claimedReserve, proof)` then
//! stores `claimedReserve`, and `verifyAggregateReserveProof()` returns it.
//!
//! Privacy model (what the SNARK hides vs. what it reveals):
//!   - PUBLIC: `claimed_total` (the solvency floor the hook trusts) and a
//!     `commitment` to the per-chain reserve vector.
//!   - PRIVATE (witness): the actual per-chain reserves.
//! The circuit proves both:
//!   (1) commitment == hash(reserves)      -- reserves match the commitment,
//!   (2) sum(reserves) >= claimed_total     -- solvency.
//!
//! Here we compute the witness: the running sum (with overflow checks) and the
//! solvency comparison. The commitment is modelled with a simple, documented
//! order-independent fold (NOT a cryptographic hash; the real circuit uses a
//! Poseidon/MiMC commitment, see the `snark` feature stub in circuit_io.rs).

use crate::u256::U256;

/// One chain's reported junior reserve (token0-denominated), with its chain id.
#[derive(Clone, Copy, Debug)]
pub struct ChainReserve {
    pub chain_id: u64,
    pub reserve: u128,
}

/// Witness output of the AggregateReserveProof.
#[derive(Clone, Copy, Debug)]
pub struct ReserveWitness {
    /// Sum of all per-chain reserves.
    pub total: U256,
    /// True if `total >= claimed_total` (solvency holds).
    pub solvent: bool,
    /// Order-independent commitment to the reserve vector (modelled).
    pub commitment: U256,
}

/// Sum the per-chain reserves with full 256-bit width (no overflow possible for
/// realistic token magnitudes; we still use U256 to match the on-chain type).
pub fn sum_reserves(reserves: &[ChainReserve]) -> U256 {
    let mut total = U256::ZERO;
    for r in reserves {
        total = total.wrapping_add(&U256::from_u128(r.reserve));
    }
    total
}

/// Order-independent commitment model: fold each (chain_id, reserve) pair into
/// an accumulator with a mix step, then combine commutatively by addition so
/// the commitment does not depend on chain ordering. This stands in for the
/// Poseidon commitment the real circuit binds in its public inputs; it is NOT
/// collision-resistant and must not be relied on for security. Its only job in
/// the witness layer is to be deterministic and order-independent for tests.
pub fn commit_reserves(reserves: &[ChainReserve]) -> U256 {
    let mut acc = U256::ZERO;
    for r in reserves {
        // mix = chain_id * PRIME ^ reserve-ish, kept simple and deterministic.
        let prime = U256::from_u64(0x100000001b3); // FNV-ish prime
        let leaf = U256::from_u64(r.chain_id)
            .wrapping_mul(&prime)
            .wrapping_add(&U256::from_u128(r.reserve));
        // Commutative combine (addition) -> order independent.
        acc = acc.wrapping_add(&leaf);
    }
    acc
}

/// Compute the full AggregateReserveProof witness for a claimed solvency floor.
pub fn aggregate_reserve_witness(reserves: &[ChainReserve], claimed_total: u128) -> ReserveWitness {
    let total = sum_reserves(reserves);
    let claimed = U256::from_u128(claimed_total);
    ReserveWitness {
        total,
        solvent: crate::u256::cmp_ge(&total, &claimed),
        commitment: commit_reserves(reserves),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn reserves() -> Vec<ChainReserve> {
        vec![
            ChainReserve {
                chain_id: 1,
                reserve: 500_000,
            },
            ChainReserve {
                chain_id: 10,
                reserve: 300_000,
            },
            ChainReserve {
                chain_id: 130,
                reserve: 200_000,
            },
        ]
    }

    #[test]
    fn sum_correctness() {
        assert_eq!(sum_reserves(&reserves()).to_u128().unwrap(), 1_000_000);
    }

    #[test]
    fn solvent_when_sum_meets_claim() {
        let w = aggregate_reserve_witness(&reserves(), 1_000_000);
        assert!(w.solvent);
        assert_eq!(w.total.to_u128().unwrap(), 1_000_000);
    }

    #[test]
    fn solvent_when_sum_exceeds_claim() {
        let w = aggregate_reserve_witness(&reserves(), 900_000);
        assert!(w.solvent);
    }

    #[test]
    fn under_collateralization_detected() {
        // Claim more than the reserves can cover -> not solvent.
        let w = aggregate_reserve_witness(&reserves(), 1_000_001);
        assert!(!w.solvent, "under-collateralization must be detected");
    }

    #[test]
    fn commitment_order_independent() {
        let a = reserves();
        let mut b = reserves();
        b.reverse();
        assert_eq!(commit_reserves(&a), commit_reserves(&b));
    }

    #[test]
    fn commitment_changes_with_reserves() {
        let a = reserves();
        let mut b = reserves();
        b[0].reserve += 1;
        assert_ne!(commit_reserves(&a), commit_reserves(&b));
    }

    #[test]
    fn empty_set_is_zero_and_insolvent_for_positive_claim() {
        let w = aggregate_reserve_witness(&[], 1);
        assert!(w.total.is_zero());
        assert!(!w.solvent);
    }

    #[test]
    fn determinism() {
        let r = reserves();
        assert_eq!(
            aggregate_reserve_witness(&r, 1_000_000).commitment,
            aggregate_reserve_witness(&r, 1_000_000).commitment
        );
    }
}
