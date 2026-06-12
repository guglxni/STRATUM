# STRATUM Stylus compute layer

Rust implementation of the STRATUM Arbitrum Stylus compute layer: the CPHR matching engine and the
ML forward-volatility model. This is the compute-heavy work that is gas-prohibitive in Solidity
(ARCHITECTURE.md section 8, TECHNICAL_DESIGN.md section 10), so it runs in Rust on Arbitrum Stylus.

## What it is

Two pure-Rust modules plus a thin on-chain wrapper:

- `src/matching.rs` - the CPHR (Cross-Pool Hedging Router) matching engine. Correlation scan,
  IL-netting optimization, rebalance-path selection.
- `src/ml_volatility.rs` - the forward-volatility model. Online EWMA baseline plus a GARCH(1,1)-lite
  variance recursion that predicts the next-step volatility regime.
- `src/stylus_entrypoint.rs` - the Stylus contract wrapper. Decodes `submitPoolState` calldata, runs
  the core, and ABI-encodes the `MatchResult` back. Feature-gated behind `--features stylus`.

## Honest status: pure-Rust-tested vs Stylus-deployed

- The **core** (`matching` + `ml_volatility`) is dependency-free pure Rust. It compiles and passes
  `cargo test` with a stock toolchain, offline. This is the part with full unit-test coverage
  (25 tests: netting offset math, donor selection, draw caps, overflow edges, EWMA convergence,
  GARCH shock response, bounded output, determinism).
- The **Stylus entrypoint** (`stylus_entrypoint.rs`) is feature-gated. It is ABI-faithful to
  `IStylusMatchingEngine.sol` and documents exactly how calldata is decoded and the result encoded,
  but it requires the `cargo stylus` toolchain and the `stylus-sdk`, which are **not** installed in
  this environment. It is therefore documented and structured, not deployment-verified here. Building
  it requires `cargo stylus` (see below).

## Build and test

```bash
# Pure-Rust core: compiles and tests offline, no extra toolchain.
cargo test
cargo build

# Stylus contract (requires `cargo stylus` and network access for the sdk):
cargo install --force cargo-stylus
cargo stylus check  --features stylus
cargo stylus deploy --features stylus --private-key $KEY
```

## How it maps to the Solidity side

The outputs mirror `src/peripherals/stylus/IStylusMatchingEngine.sol` field-for-field so the consumer
in `src/peripherals/stylus/StylusShim.sol` can `abi.decode` them unchanged:

| Rust (`matching.rs` / `ml_volatility.rs`)        | Solidity (`IStylusMatchingEngine.MatchResult`)        |
| ------------------------------------------------ | ----------------------------------------------------- |
| `NettingPair { pool_a, pool_b, net_value, ... }` | `NettingPair { poolA, poolB, netValue, ... }`         |
| `RebalanceRecommendation { source, target, amt }`| `RebalanceRecommendation { sourcePool, targetPool, amount }` |
| `VolForecast.predicted_ewma` (per pool)          | `predictedVolatilityEWMA[]` (parallel to pools)       |
| `now + ttl` in the entrypoint                    | `validUntil`                                          |

Request-response flow (from `StylusShim.sol`):

1. `StylusShim.onEpochClose` calls `submitPoolState(pools, states, nonce)`.
2. The Stylus engine runs the matching + forecast pass (this crate) and calls
   `deliverMatchResult(nonce, encodedResult)` back on the shim.
3. After EigenLayer attestation, `StylusShim.applyMatchResult` writes the per-pool volatility
   overrides (read by the hook via `getVolatilityOverride`) and emits netting/rebalance events for the
   CPHR to consume.

## Fixed-point scales

- **Basis points (`bps`)**: integer out of `10_000`. `10_000 == 100%`. Matches
  `CorrelationRegistry` weights.
- **Volatility EWMA**: WAD, `1e18 == 1.0`. Identical to the hook's
  `PoolTrancheState.volatilityEWMA`, which is `delta(sqrtPrice)/prevSqrtPrice * 1e18`
  (`src/libraries/ILMath.sol`). A 1% sqrt-price move is `1e16`.
- **Reserves / IL / netValue / amount**: token0 wei, plain integers.

All bps math goes through `mul_div`, which uses a 256-bit intermediate (no external crates) so
reserve-by-bps products never overflow.

## Algorithm notes

- **Matching** is greedy, LP-free, and O(n * degree): netting runs first (each correlation edge nets
  `min(deficit_A, surplus_B) * weight_bps / 10_000`, applied to working residuals so later edges see
  the updated state), then residual deficits are covered by donor pools whose draw is capped at
  `MAX_DRAW_FRACTION_BPS = 5_000` (50%) of their junior reserve - mirroring the Solidity cap.
- **ML volatility** combines a 0.9/0.1 EWMA baseline (so it degrades to on-chain behaviour when the
  predictor has no signal) with a GARCH(1,1)-lite recursion
  `sigma2 = omega + alpha*r^2 + beta*sigma2` (`alpha+beta = 0.95`, stationary). The forecast is
  `max(ewma_baseline, sqrt(sigma2))` clamped to `MAX_VOL_EWMA = 2e18`, so it leans defensive into a
  predicted spike and can never hand the consumer an unbounded value.
