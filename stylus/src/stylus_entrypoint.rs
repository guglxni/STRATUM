// SPDX-License-Identifier: MIT
//! Stylus contract entrypoint (thin wrapper).
//!
//! THIS FILE COMPILES ONLY UNDER `--features stylus`. The pure-Rust core ([`crate::matching`] and
//! [`crate::ml_volatility`]) is what `cargo test` exercises; this module is the on-chain shell that
//! decodes Solidity calldata, runs that core, and ABI-encodes the result back. It needs the
//! `cargo stylus` toolchain (`cargo stylus check` / `cargo stylus deploy`), which is not part of a
//! stock cargo install, hence the feature gate.
//!
//! ## On-chain ABI surface (what `StylusShim` / the relay call)
//!
//! Two functions, both with simple, router-friendly signatures:
//!
//! - `forecastVolatility(uint256 prevEwma, uint256 instant) -> uint256`
//!   A pure volatility-forecast view. Feeds one instantaneous sqrt-price return (WAD) into the
//!   GARCH(1,1)-lite + EWMA model warm-started from `prevEwma` (the hook's current on-chain
//!   `volatilityEWMA`) and returns the predicted next-step EWMA (WAD). This is exactly the value
//!   `StylusShim.getVolatilityOverride` hands the hook. Cheap enough to call per-pool from a relay.
//!
//! - `runMatch(bytes submission, uint32 nowTs) -> bytes`
//!   The matching/netting view. `submission` is ABI-encoded [`AbiSubmission`] (pools, correlation
//!   edges, per-pool instant + warm-start EWMA). The contract runs the full CPHR matching pass plus
//!   the per-pool forecast and returns `abi.encode(MatchResult)` - byte-for-byte what
//!   `IStylusMatchingEngine.MatchResult` decodes to, so `StylusShim.deliverMatchResult` /
//!   `applyMatchResult` consume the returned bytes unchanged.
//!
//! Both keep the heavy pure-Rust logic in [`crate::matching`] / [`crate::ml_volatility`]; this module
//! only marshals bytes. `predictedVolatilityEWMA` entries are WAD; `validUntil = nowTs + ttl`.
//!
//! ## Why `runMatch` takes/returns `bytes` rather than typed struct arrays
//!
//! Stylus routes a function by a fixed 4-byte selector over its declared ABI. Passing the pool/edge
//! arrays as a single `bytes` blob (decoded internally with alloy `SolValue`) keeps the exported
//! selector surface tiny (good for the 24KB compressed activation limit) and lets the off-chain
//! relay pre-encode the submission with the same alloy types, avoiding a second nested-struct router.

#![cfg(feature = "stylus")]

extern crate alloc;

use alloc::vec::Vec;

use alloy_primitives::{FixedBytes, U256};
use alloy_sol_types::{sol, SolValue};
use stylus_sdk::prelude::*;

use crate::matching::{match_pools, CorrelationEdge, MatchConfig, PoolState};
use crate::ml_volatility::VolModel;

// Solidity-mirroring ABI types. The result types match IStylusMatchingEngine.sol field-for-field so
// the shim's `abi.decode(..., (MatchResult))` succeeds unchanged. The submission types are the engine's
// private input encoding (the relay encodes them with these same alloy definitions).
sol! {
    // ----- result side (mirrors IStylusMatchingEngine.MatchResult) -----
    struct AbiNettingPair {
        bytes32 poolA;
        bytes32 poolB;
        uint256 netValue;
        uint16 correlationWeightBps;
    }

    struct AbiRebalance {
        bytes32 sourcePool;
        bytes32 targetPool;
        uint256 amount;
        bool crossChain;
        uint256 targetChainId;
    }

    struct AbiMatchResult {
        AbiNettingPair[] nettingPairs;
        AbiRebalance[] rebalances;
        uint256[] predictedVolatilityEWMA;
        uint32 validUntil;
    }

    // ----- submission side (engine input, decoded inside runMatch) -----
    struct AbiPool {
        bytes32 id;
        uint256 juniorReserve;
        uint256 cumulativeIL;
        // latest instantaneous volatility (WAD) and the hook's current EWMA (WAD), warm-start.
        uint256 instant;
        uint256 prevEwma;
    }

    struct AbiEdge {
        uint64 fromIndex;
        uint64 toIndex;
        uint16 weightBps;
    }

    struct AbiSubmission {
        AbiPool[] pools;
        AbiEdge[] edges;
    }
}

/// The Stylus storage-backed contract.
///
/// Storage is intentionally minimal: a single configurable TTL used to stamp `validUntil` on a match
/// result. One [`VolModel`] per pool would normally live in a storage map keyed by PoolId; this
/// wrapper instead recomputes each forecast from the per-pool instant + warm-start EWMA carried in the
/// submission, which keeps the contract stateless across calls and well under the activation size
/// limit. (Persisting per-pool model state is a deployment optimization, not a correctness need: the
/// forecast is a deterministic function of (prevEwma, instant).)
#[storage]
#[entrypoint]
pub struct StratumMatchingEngine {
    /// Volatility-override TTL in seconds, used to fill `validUntil`. Settable once by `setTtl`.
    ttl_seconds: stylus_sdk::storage::StorageU32,
}

#[public]
impl StratumMatchingEngine {
    /// Set the result TTL (seconds) used to stamp `validUntil = nowTs + ttl`. Idempotent; callable by
    /// the deployer/operator off-chain before wiring. Kept permissionless here because the value only
    /// affects staleness stamping of an advisory result the shim already re-validates against
    /// `block.timestamp`; access control lives in the Solidity shim, not the compute engine.
    pub fn set_ttl(&mut self, ttl_seconds: u32) {
        self.ttl_seconds.set(U256::from(ttl_seconds).to());
    }

    /// Current configured TTL (seconds).
    pub fn ttl(&self) -> u32 {
        self.ttl_seconds.get().to::<u32>()
    }

    /// Volatility-forecast view. Warm-start the model from `prev_ewma` (the hook's current on-chain
    /// `volatilityEWMA`, WAD), feed one instantaneous sqrt-price return `instant` (WAD), and return the
    /// predicted next-step EWMA (WAD). Pure: no storage writes, deterministic.
    pub fn forecast_volatility(&self, prev_ewma: U256, instant: U256) -> U256 {
        let warm = u256_to_u128_sat(prev_ewma);
        let inst = u256_to_u128_sat(instant);
        let mut model = VolModel::from_ewma(warm);
        let f = model.update(inst);
        U256::from(f.predicted_ewma)
    }

    /// Run a full matching + forecasting pass over an ABI-encoded [`AbiSubmission`] and return
    /// `abi.encode(IStylusMatchingEngine.MatchResult)`. `now_ts` is the current block timestamp the
    /// caller supplies (the relay passes `block.timestamp`); `validUntil = now_ts + ttl`.
    ///
    /// On a malformed `submission` that fails to decode, returns an empty `MatchResult` (no pairs, no
    /// rebalances, empty forecast array, `validUntil = now_ts + ttl`) rather than reverting, so a bad
    /// relay payload can never brick the engine.
    pub fn run_match(&self, submission: Vec<u8>, now_ts: u32) -> Vec<u8> {
        let ttl = self.ttl_seconds.get().to::<u32>();
        let valid_until = now_ts.saturating_add(ttl);

        let sub = match AbiSubmission::abi_decode(&submission, true) {
            Ok(s) => s,
            Err(_) => return empty_result(valid_until),
        };

        // Marshal pools + per-pool model inputs.
        let pools: Vec<PoolState> = sub
            .pools
            .iter()
            .map(|p| {
                PoolState::new(
                    p.id.0,
                    u256_to_u128_sat(p.juniorReserve),
                    u256_to_u128_sat(p.cumulativeIL),
                )
            })
            .collect();

        let edges: Vec<CorrelationEdge> = sub
            .edges
            .iter()
            .map(|e| {
                CorrelationEdge::new(e.fromIndex as usize, e.toIndex as usize, e.weightBps)
            })
            .collect();

        let result = match_pools(&pools, &edges, MatchConfig::default());

        // Per-pool forward-volatility forecast, parallel to the submitted pools.
        let predicted: Vec<U256> = sub
            .pools
            .iter()
            .map(|p| {
                let mut model = VolModel::from_ewma(u256_to_u128_sat(p.prevEwma));
                let f = model.update(u256_to_u128_sat(p.instant));
                U256::from(f.predicted_ewma)
            })
            .collect();

        let netting: Vec<AbiNettingPair> = result
            .netting_pairs
            .iter()
            .map(|p| AbiNettingPair {
                poolA: FixedBytes::from(p.pool_a),
                poolB: FixedBytes::from(p.pool_b),
                netValue: U256::from(p.net_value),
                correlationWeightBps: p.correlation_weight_bps,
            })
            .collect();

        let rebalances: Vec<AbiRebalance> = result
            .rebalances
            .iter()
            .map(|r| AbiRebalance {
                sourcePool: FixedBytes::from(r.source_pool),
                targetPool: FixedBytes::from(r.target_pool),
                amount: U256::from(r.amount),
                crossChain: false,
                targetChainId: U256::ZERO,
            })
            .collect();

        let bundle = AbiMatchResult {
            nettingPairs: netting,
            rebalances,
            predictedVolatilityEWMA: predicted,
            validUntil: valid_until,
        };

        bundle.abi_encode()
    }
}

/// Empty (well-formed) `MatchResult` encoding used as the safe fallback for a bad submission.
fn empty_result(valid_until: u32) -> Vec<u8> {
    AbiMatchResult {
        nettingPairs: Vec::new(),
        rebalances: Vec::new(),
        predictedVolatilityEWMA: Vec::new(),
        validUntil: valid_until,
    }
    .abi_encode()
}

/// Saturating `U256 -> u128`. The core math operates on token0-wei `u128`; anything above `u128::MAX`
/// (not reachable for real reserves) saturates rather than wrapping or panicking.
#[inline]
fn u256_to_u128_sat(v: U256) -> u128 {
    if v > U256::from(u128::MAX) {
        u128::MAX
    } else {
        v.to::<u128>()
    }
}
