//! STRATUM Brevis prover-side witness computation.
//!
//! This crate computes the WITNESS values that STRATUM's three Brevis circuits
//! prove. The witness math is real, pure Rust, deterministic, and tested. The
//! SNARK proving backend (Brevis SDK / gnark) is the integration step and lives
//! behind the optional `snark` feature as a documented stub (see
//! [`circuit_io::snark`]).
//!
//! The three circuits (DESIGN section 11, ARCHITECTURE section 7):
//!
//! 1. [`il_attribution`] - ILAttribution. Per-position impermanent loss over a
//!    holding window, in token0 numeraire. Reproduces `ILMath.ilForRange`
//!    EXACTLY (same `getSqrtPriceAtTick`, `_amountsForLiquidity`,
//!    `valueInToken0` integer pipeline). Pairs with the shim's
//!    `verifyILAttribution(positionId) -> (proven, ilAttribution)`.
//!
//! 2. [`tw_contribution`] - TimeWeightedContribution. A position's
//!    time-weighted share of each epoch's junior surplus, summed over its
//!    window, with a conservation bound (sum across positions <= surplus).
//!    Pairs with `verifyTimeWeightedContribution(positionId) -> (proven,
//!    contribution)`.
//!
//! 3. [`aggregate_reserve`] - AggregateReserveProof. Cross-chain junior reserve
//!    solvency (sum of per-chain reserves >= claimed) with an order-independent
//!    reserve commitment, without revealing individual positions. Pairs with
//!    `verifyAggregateReserveProof() -> (proven, claimedReserve)`.
//!
//! Supporting modules:
//! - [`u256`] - minimal dependency-free 256-bit integer with a faithful
//!   `FullMath.mulDiv` (512-bit intermediate, no phantom overflow).
//! - [`tick_math`] - faithful port of `TickMath.getSqrtPriceAtTick`.
//! - [`circuit_io`] - public-input encoding mirroring the Solidity shim, and
//!   the `snark`-gated proving-backend stub.

pub mod aggregate_reserve;
pub mod circuit_io;
pub mod il_attribution;
pub mod tick_math;
pub mod tw_contribution;
pub mod u256;

// Convenience re-exports of the three witness entry points.
pub use aggregate_reserve::{aggregate_reserve_witness, ChainReserve, ReserveWitness};
pub use il_attribution::{il_for_range, IlInputs};
pub use tw_contribution::{time_weighted_contribution, EpochWindow, PositionWindow};
pub use u256::U256;

#[cfg(test)]
mod integration_tests {
    //! End-to-end: compute each witness and pack it into the public inputs the
    //! `BrevisVerifierShim` would verify.
    use crate::aggregate_reserve::{aggregate_reserve_witness, ChainReserve};
    use crate::circuit_io::{
        AggregateReservePublic, IlAttributionPublic, TwContributionPublic,
    };
    use crate::il_attribution::{il_for_range, IlInputs};
    use crate::tick_math::get_sqrt_price_at_tick;
    use crate::tw_contribution::{time_weighted_contribution, EpochWindow, PositionWindow};
    use crate::u256::U256;

    #[test]
    fn il_witness_into_public_inputs() {
        let il = il_for_range(&IlInputs {
            entry_sqrt_p: get_sqrt_price_at_tick(0),
            exit_sqrt_p: get_sqrt_price_at_tick(2000),
            tick_lower: -6000,
            tick_upper: 6000,
            liquidity: 1_000_000_000_000_000_000,
        });
        assert!(!il.is_zero());
        let public = IlAttributionPublic {
            position_id: [0x11; 32],
            claimed_il: il,
        };
        // The shim verifies abi.encode(positionId, claimedIL): 64 bytes.
        assert_eq!(public.encode().len(), 64);
    }

    #[test]
    fn tw_witness_into_public_inputs() {
        let ep = EpochWindow {
            epoch: 1,
            start_ts: 0,
            epoch_seconds: 1000,
            epoch_surplus: 1_000_000,
            junior_tvl: 2_000_000,
        };
        let pos = PositionWindow {
            entry_ts: 0,
            exit_ts: 1000,
            principal: 1_000_000,
        };
        let contribution = time_weighted_contribution(&pos, &[ep]);
        assert_eq!(contribution.to_u128().unwrap(), 500_000);
        let public = TwContributionPublic {
            position_id: [0x22; 32],
            from_epoch: 1,
            to_epoch: 1,
            claimed_contribution: contribution,
        };
        assert_eq!(public.encode().len(), 128);
    }

    #[test]
    fn aggregate_witness_into_public_inputs() {
        let reserves = [
            ChainReserve {
                chain_id: 1,
                reserve: 600_000,
            },
            ChainReserve {
                chain_id: 130,
                reserve: 400_000,
            },
        ];
        let w = aggregate_reserve_witness(&reserves, 1_000_000);
        assert!(w.solvent);
        let public = AggregateReservePublic {
            claimed_reserve: U256::from_u128(1_000_000),
        };
        assert_eq!(public.encode().len(), 32);
    }
}

#[cfg(test)]
mod reference_cross_check {
    use crate::tick_math::get_sqrt_price_at_tick;
    #[test]
    fn matches_python_reference() {
        // Expected values produced by an independent Python port of the exact
        // Uniswap getSqrtRatioAtTick algorithm (same magic constants, same
        // round-up shift). These pin the Rust port to the canonical output.
        let cases: [(i32, u128); 5] = [
            (0, 79228162514264337593543950336),
            (60, 79466191966197645195421774833),
            (-60, 78990846045029531151608375686),
            (2000, 87560223330309670419052669889),
            (-2000, 71688964425171947676218820835),
        ];
        for (t, v) in cases {
            assert_eq!(get_sqrt_price_at_tick(t).to_u128().unwrap(), v, "tick {}", t);
        }
    }
}
