//! Public-input / proof-output encoding that pairs with `BrevisVerifierShim`.
//!
//! The shim's submit functions take ABI-encoded public inputs:
//!
//!   submitTWContributionProof(positionId, fromEpoch, toEpoch,
//!                             claimedContribution, epochAccumulatedFees, proof)
//!       public inputs verified: abi.encode(positionId, fromEpoch, toEpoch,
//!                                          claimedContribution)
//!   submitILAttributionProof(positionId, claimedIL, proof)
//!       public inputs verified: abi.encode(positionId, claimedIL)
//!   submitAggregateReserveProof(claimedReserve, proof)
//!       public inputs verified: abi.encode(claimedReserve)
//!
//! This module defines the Rust mirror of those public-input tuples plus a
//! deterministic byte encoding so the prover-side witness and the on-chain
//! `_verifyOrStub(proof, vkHash, publicInputs)` agree on exactly what is being
//! proven. The encoding here is a documented canonical layout; the production
//! path uses Solidity ABI encoding via the Brevis SDK, bound under the `snark`
//! feature (stubbed below).
//!
//! Verification-key tags mirror the shim constants (keccak256 of the same
//! strings) so a public input set can be routed to the right circuit.

use crate::u256::U256;

/// Canonical circuit identifiers. These are the preimages of the shim's
/// `VK_TW_CONTRIBUTION` / `VK_IL_ATTRIBUTION` / `VK_AGGREGATE_RESERVE`
/// (`keccak256(<string>)` on-chain).
pub const VK_TW_CONTRIBUTION: &str = "stratum.brevis.tw_contribution.v1";
pub const VK_IL_ATTRIBUTION: &str = "stratum.brevis.il_attribution.v1";
pub const VK_AGGREGATE_RESERVE: &str = "stratum.brevis.aggregate_reserve.v1";

/// Public inputs for the TimeWeightedContribution proof.
/// Mirrors `abi.encode(positionId, fromEpoch, toEpoch, claimedContribution)`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TwContributionPublic {
    /// keccak256(owner, tickLower, tickUpper, salt) computed by the hook.
    pub position_id: [u8; 32],
    pub from_epoch: u64,
    pub to_epoch: u64,
    /// Token0-denominated proven surplus share (what the circuit outputs).
    pub claimed_contribution: U256,
}

/// Public inputs for the ILAttribution proof.
/// Mirrors `abi.encode(positionId, claimedIL)`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct IlAttributionPublic {
    pub position_id: [u8; 32],
    /// Token0-denominated IL the circuit proves (from `il_for_range`).
    pub claimed_il: U256,
}

/// Public inputs for the AggregateReserveProof.
/// Mirrors `abi.encode(claimedReserve)`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct AggregateReservePublic {
    /// Token0-denominated solvency floor the hook trusts.
    pub claimed_reserve: U256,
}

/// Big-endian 32-byte word, matching how `uint256` lands in Solidity ABI.
fn u256_be(v: &U256) -> [u8; 32] {
    let mut out = [0u8; 32];
    // limbs are little-endian u64; write most-significant limb first.
    for (i, limb) in v.limbs.iter().enumerate() {
        let be = limb.to_be_bytes();
        let off = (3 - i) * 8;
        out[off..off + 8].copy_from_slice(&be);
    }
    out
}

fn u64_be32(v: u64) -> [u8; 32] {
    let mut out = [0u8; 32];
    out[24..32].copy_from_slice(&v.to_be_bytes());
    out
}

impl TwContributionPublic {
    /// Canonical encoding: 32-byte-word-per-field, matching Solidity ABI of
    /// `abi.encode(bytes32, uint64, uint64, uint256)` (static types, left-padded).
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(128);
        out.extend_from_slice(&self.position_id);
        out.extend_from_slice(&u64_be32(self.from_epoch));
        out.extend_from_slice(&u64_be32(self.to_epoch));
        out.extend_from_slice(&u256_be(&self.claimed_contribution));
        out
    }
}

impl IlAttributionPublic {
    /// Canonical encoding of `abi.encode(bytes32, uint256)`.
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(64);
        out.extend_from_slice(&self.position_id);
        out.extend_from_slice(&u256_be(&self.claimed_il));
        out
    }
}

impl AggregateReservePublic {
    /// Canonical encoding of `abi.encode(uint256)`.
    pub fn encode(&self) -> Vec<u8> {
        u256_be(&self.claimed_reserve).to_vec()
    }
}

/// The SNARK proving backend (Brevis SDK / gnark gadget). This is the
/// integration step: it consumes the witness computed by the other modules and
/// the public inputs encoded here, and produces a proof blob the shim verifies.
///
/// It is a DOCUMENTED STUB behind the `snark` feature so the witness math above
/// compiles and tests with zero proving-backend or network dependencies. The
/// witness functions (`il_for_range`, `time_weighted_contribution`,
/// `aggregate_reserve_witness`) are the real, tested deliverable; wiring them
/// into a real prover is the remaining integration work.
#[cfg(feature = "snark")]
pub mod snark {
    /// Placeholder proof blob produced by the real Brevis/gnark prover.
    pub struct Proof(pub Vec<u8>);

    /// Generate a proof for the given verification-key tag, public inputs, and
    /// private witness bytes. UNIMPLEMENTED: this is where the Brevis SDK call
    /// goes. It is intentionally not callable in the default build.
    pub fn prove(_vk_tag: &str, _public_inputs: &[u8], _witness: &[u8]) -> Proof {
        unimplemented!(
            "SNARK backend (Brevis SDK / gnark) is the integration step; \
             witness computation is in the parent modules and is fully tested"
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tw_encoding_length_and_fields() {
        let p = TwContributionPublic {
            position_id: [0xAB; 32],
            from_epoch: 3,
            to_epoch: 7,
            claimed_contribution: U256::from_u64(500_000),
        };
        let enc = p.encode();
        assert_eq!(enc.len(), 128, "four 32-byte words");
        // from_epoch lands in the last byte of the second word.
        assert_eq!(enc[63], 3);
        // to_epoch in the last byte of the third word.
        assert_eq!(enc[95], 7);
        // claimed_contribution big-endian in the fourth word.
        assert_eq!(&enc[96..128], &u256_be(&U256::from_u64(500_000)));
    }

    #[test]
    fn il_encoding_round_trips_value() {
        let p = IlAttributionPublic {
            position_id: [1u8; 32],
            claimed_il: U256::from_u64(42),
        };
        let enc = p.encode();
        assert_eq!(enc.len(), 64);
        assert_eq!(enc[63], 42);
    }

    #[test]
    fn aggregate_encoding_is_one_word() {
        let p = AggregateReservePublic {
            claimed_reserve: U256::from_u64(1_000_000),
        };
        assert_eq!(p.encode().len(), 32);
    }

    #[test]
    fn u256_be_big_endian_order() {
        // 1 should land in the final byte.
        let be = u256_be(&U256::ONE);
        assert_eq!(be[31], 1);
        assert_eq!(be[0], 0);
        // 2^64 lands at byte 23 (start of second-least-significant word).
        let be2 = u256_be(&U256::ONE.shl(64));
        assert_eq!(be2[23], 1);
    }

    #[test]
    fn vk_tags_match_shim_preimages() {
        // These strings are the keccak256 preimages of the shim's VK constants.
        assert_eq!(VK_TW_CONTRIBUTION, "stratum.brevis.tw_contribution.v1");
        assert_eq!(VK_IL_ATTRIBUTION, "stratum.brevis.il_attribution.v1");
        assert_eq!(VK_AGGREGATE_RESERVE, "stratum.brevis.aggregate_reserve.v1");
    }
}
