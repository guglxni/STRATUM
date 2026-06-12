# stratum-brevis

Prover-side **witness computation** for STRATUM's Brevis verifiable fee
distribution (DESIGN section 11, ARCHITECTURE section 7).

This crate computes the values that STRATUM's three Brevis circuits prove. The
witness math is real, pure Rust, deterministic, dependency-free, and tested with
`cargo test`. The SNARK proving backend (Brevis SDK / gnark) is the integration
step and is a documented stub behind the optional `snark` feature.

```
cargo test            # 45 tests, witness math, no network/proving backend
cargo build --features snark   # compiles the (unimplemented) backend stub
```

## Why witness computation matters

When LPs enter and exit mid-epoch, fair distribution of junior surplus and
accurate IL attribution require time-weighted, per-position accounting. Doing
this on-chain for every position is expensive and approximate. Brevis generates
a ZK proof over historical pool data; the circuit's job is to prove a claimed
number is correct. That claimed number is the **witness** this crate computes.
The on-chain `BrevisVerifierShim` then trusts the proven value and, when Brevis
is disabled, falls back to the core's on-chain approximation (golden rule: the
core works standalone).

## The three circuits

### 1. ILAttribution (`src/il_attribution.rs`)

Per-position impermanent loss over the actual holding window, in token0
numeraire. **Reproduces `src/libraries/ILMath.sol::ilForRange` exactly**, using
faithful Rust ports of:

- `TickMath.getSqrtPriceAtTick` (`src/tick_math.rs`): the canonical Uniswap
  bit-decomposition of `|tick|` over Q128.128 magic constants, positive-tick
  inversion, and the round-up shift from Q128.128 to Q64.96. Cross-checked
  against an independent reference for ticks `{0, +/-60, +/-2000, 6000,
  +/-887272}` (`reference_cross_check` test) and against the on-chain
  `MIN_SQRT_PRICE` / `MAX_SQRT_PRICE` constants.
- `_amountsForLiquidity`, `_amount0ForLiquidity`, `_amount1ForLiquidity`: the
  three-region (below / inside / above range) split.
- `valueInToken0`: `priceX96 = sqrtP^2 / Q96`, `amount1As0 = amount1 * Q96 /
  priceX96`, value `= amount0 + amount1As0`.
- `FullMath.mulDiv` (`src/u256.rs`): `floor(a*b/d)` with a full 512-bit
  intermediate so there is no phantom overflow, matching Solidity bit for bit.

The witness is `held(P) - lpValue(P)` at exit price P: what a passive holder of
the entry basket is worth at exit, minus what the LP position is worth at exit.
Zero on no price move or zero liquidity, positive on divergence.

Pairs with the shim's
`verifyILAttribution(positionId) -> (proven, ilAttribution)` and
`submitILAttributionProof(positionId, claimedIL, proof)`.

### 2. TimeWeightedContribution (`src/tw_contribution.rs`)

A position's time-weighted share of each epoch's junior surplus, summed across
its holding window:

```
position_weight = principal * overlap_seconds          (time-weighted stake)
total_weight    = junior_tvl * epoch_seconds           (all junior stake, full epoch)
contribution    = floor(epoch_surplus * position_weight / total_weight)
```

Because `principal <= junior_tvl` and `overlap <= epoch_seconds` for any single
position, and the per-epoch contributions are floored, **the sum of all
positions' contributions for an epoch never exceeds the epoch surplus**. This is
the conservation bound the shim relies on (INV-03 spirit), the same bound the
shim re-checks with its `claimedContribution <= epochAccumulatedFees`
plausibility guard. This complements `EpochAccounting.vestedToDate` smoothing:
vesting governs *when* an accrued amount is released; this circuit governs *how
much* of each epoch's surplus a mid-epoch position is entitled to.

Pairs with
`verifyTimeWeightedContribution(positionId) -> (proven, contribution)` and
`submitTWContributionProof(positionId, fromEpoch, toEpoch, claimedContribution,
epochAccumulatedFees, proof)`.

### 3. AggregateReserveProof (`src/aggregate_reserve.rs`)

Cross-chain junior reserve solvency: the sum of per-chain reserves is `>=` a
claimed total, proven without revealing individual positions. The witness
computes the running sum, the solvency comparison, and an order-independent
commitment to the reserve vector (a documented model standing in for the
Poseidon/MiMC commitment the real circuit binds; **not** collision-resistant on
its own).

Pairs with `verifyAggregateReserveProof() -> (proven, claimedReserve)` and
`submitAggregateReserveProof(claimedReserve, proof)`.

## Public-input encoding (`src/circuit_io.rs`)

Mirrors exactly what `BrevisVerifierShim._verifyOrStub` verifies:

| Circuit                  | Public inputs (`abi.encode`)                                   | Bytes |
|--------------------------|----------------------------------------------------------------|-------|
| TimeWeightedContribution | `(positionId, fromEpoch, toEpoch, claimedContribution)`        | 128   |
| ILAttribution            | `(positionId, claimedIL)`                                      | 64    |
| AggregateReserveProof    | `(claimedReserve)`                                             | 32    |

Each field is a left-padded 32-byte big-endian word, matching Solidity static
ABI encoding. The verification-key tags (`VK_*`) are the keccak256 preimages of
the shim's `VK_TW_CONTRIBUTION` / `VK_IL_ATTRIBUTION` / `VK_AGGREGATE_RESERVE`
constants.

## Honest status

- **Real and tested:** all witness computation. The IL witness matches
  `ILMath.sol`'s algorithm (same `getSqrtPriceAtTick`, `_amountsForLiquidity`,
  `valueInToken0`, `FullMath.mulDiv` integer pipeline), verified by a
  hand-computed vector and an independent tick-math reference. The
  time-weighted contribution respects the conservation bound. The aggregate
  reserve detects under-collateralization.
- **Integration step (not done here):** the Groth16 / Brevis-SDK / gnark gadget
  that turns these witnesses into a verifiable proof blob. It is a documented
  `unimplemented!()` stub behind `--features snark` (`circuit_io::snark`). The
  default build neither needs nor touches a proving backend or the network.
- **Hosted gateway (mainnet -> Arbitrum only):** the Go circuits in
  `brevis-circuits/` generate and locally verify a real PLONK proof over the live
  STRATUM `ReserveFunded` event (works today). The hosted-gateway settlement tail
  does NOT work on testnet: Brevis confirmed `appsdkv3.brevis.network` serves only
  source = Ethereum Mainnet (1) -> destination = Arbitrum One (42161). A real
  on-chain Brevis settlement therefore requires STRATUM on mainnet/Arbitrum One,
  out of scope under NFR-05. Full account: `docs/BREVIS_ROUTE_RESOLUTION.md`.

No Solidity in this crate is modified or required to run the tests.
