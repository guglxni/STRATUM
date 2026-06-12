# STRATUM Requirements

Testable requirements with stable IDs. Every functional requirement (FR) should map to at least one test. Non-functional requirements (NFR) and invariants (INV) constrain how the system behaves under all conditions. Cross-references: `PRD.md` for the why, `TECHNICAL_DESIGN.md` for the how.

## Functional requirements

### Tranche lifecycle

- FR-01 Tranche selection. On add-liquidity, an LP specifies SENIOR or JUNIOR. The hook records the choice, the entry `sqrtPriceX96`, the tick range, and the liquidity amount in a `TranchePosition`.
- FR-02 Receipt minting. A SENIOR deposit mints `stLP`; a JUNIOR deposit mints `jtLP`, in proportion to deposited value.
- FR-03 Receipt burning. On withdrawal, the corresponding receipt is burned before settlement transfers occur.

### Fees and waterfall

- FR-04 Dynamic fee. `beforeSwap` returns a fee that increases with trailing volatility and with junior-buffer stress, and decreases when volatility is low and the buffer is healthy. Bounds are configurable (floor and cap in bps).
- FR-05 Fee split. `afterSwap` divides each fee into three parts: senior obligation, junior surplus, protocol fee. Split ratios are dynamic functions of volatility and buffer health, within configured bounds.
- FR-06 Senior-first waterfall. Within an epoch, the senior obligation is funded before any surplus accrues to junior. If epoch fees are insufficient to meet the senior obligation, the shortfall is drawn from the junior buffer.
- FR-07 Epoch accumulation. Fees accrue into a per-pool epoch accumulator. Distribution is smoothed across the epoch on a linear schedule, not paid instantly.

### Impermanent loss

- FR-08 IL tracking. `afterSwap` updates cumulative IL per active position from the tick delta of that swap. No external price source is used.
- FR-09 Senior protection at settlement. On SENIOR withdrawal, if cumulative IL has been absorbed by the junior buffer, the senior LP receives principal plus accrued fixed yield in full. Senior takes residual IL only if the junior buffer is fully depleted, and then only up to the configured `maxSeniorILExposureBps` cap.
- FR-10 Junior absorption at settlement. On JUNIOR withdrawal, the LP receives excess fees earned minus IL absorbed over their holding period. The net may be positive or negative within the bounds of their deposited capital.

### Coverage and solvency

- FR-11 Coverage floor enforcement. A new SENIOR deposit that would push the junior/senior ratio below `minCoverageRatioBps` is rejected, unless a CPHR rebalance can restore the ratio first.
- FR-12 Self-balancing response. When coverage approaches the floor, the hook tightens senior intake and raises the dynamic fee to rebuild the buffer. No governance action is required.

### Epoch and smoothing

- FR-13 Epoch settlement. At each epoch boundary, accrued senior obligations are released to senior holders and surplus to junior holders, according to the smoothing schedule.
- FR-14 Early-exit forfeiture. A SENIOR or JUNIOR LP may exit before vesting completes, forfeiting unvested fees, which return to the junior buffer.

### Autonomic coordination (Reactive)

- FR-15 Reactive epoch trigger. The EpochSettler RSC triggers FR-13 at epoch boundaries with no off-chain keeper.
- FR-16 Reactive coverage monitor. The CoverageMonitor RSC observes liquidity events and broadcasts a stress signal the hook consumes for FR-12.
- FR-17 Reactive reserve balancer. The ReserveBalancer RSC observes cross-chain junior reserves and triggers CPHR rebalances when divergence exceeds threshold.

### Cross-Pool Hedging Router (Across)

- FR-18 Reserve aggregation. A depleted junior reserve is topped up from a correlated pool's healthy reserve on the same chain.
- FR-19 Cross-chain reserve sharing. A breached reserve on one chain is replenished from the same pair's healthy reserve on another chain via Across.
- FR-20 Correlation registry. Correlated pools and their correlation weights are recorded and used to decide aggregation and netting eligibility.

### Verifiable distribution (Brevis)

- FR-21 Time-weighted proof. For an LP entering or exiting mid-epoch, a Brevis proof attests the time-weighted fee contribution and IL attribution for the exact holding period.
- FR-22 On-chain fallback. If Brevis is disabled, settlement uses on-chain approximate accounting so the core still functions (supports INV-05).

### Supplementary yield (EigenLayer)

- FR-23 LVR auction proceeds. Proceeds from the LVR auction route to the senior tranche as a yield source uncorrelated with swap volume.
- FR-24 Match attestation. AVS operators attest to the legitimacy of a cross-chain match or rebalance before it executes.

### Benchmarked rate (Chainlink, library-level)

- FR-25 Benchmark spread. Senior target APY may be expressed as a benchmark rate (read from a Chainlink Data Feed) plus a configured spread. This input affects only the senior target, never IL accounting.

### LP intents and supplementary-yield bounds (Reactive-native extensions)

- FR-28 LVR proceeds bound. `LVRAuctionReceiver.receiveYield` enforces an optional per-pool bound (`setProceedsBound`): a routing whose USD value (valued with independent Chainlink price feeds) exceeds `LVRProceedsValidator.maxRationalProceeds` of the pool's on-chain TVL is rejected, so even a compromised attestation quorum cannot over-credit the senior reserve. A stale/missing price or zero TVL degrades to attestation-only (cannot-validate, no revert). This is a validation bound on supplementary yield, never an input to IL or coverage math.
- FR-29 Volatility model data. The Stylus volatility model is warm-started off-chain from a historical price series (e.g. successive Chainlink rounds turned into log-returns); the on-chain hook still consumes only the resulting volatility parameter, never a price feed.
- FR-30 LP conditional intents. An LP registers a conditional migration intent (condition type, threshold, destination tranche) in the `TrancheIntentRegistry` and authorizes it per position via `approveMigrator`. The `IntentSettlerRSC` executes ready intents with no keeper when a subscribed hook event flips the condition. Conditions read only on-chain hook state (coverage ratio, senior APY): no oracle.
- FR-31 Tranche migration. `migrateTranchePosition` reclassifies a position between senior and junior in place without moving the underlying Uniswap liquidity or any real tokens. Accrued IL is realized under the source tranche before the IL clock resets (no IL-dodging, golden rule 3); a junior->senior flip is enforced against the coverage floor (INV-01); the carried principal never exceeds the old principal (INV-03).

### Observability

- FR-26 Events. Every state transition that a Reactive contract or the frontend observes emits an indexed event (pool, position, epoch, tranche, amounts).

## Non-functional requirements

- NFR-01 Core independence. The core hook builds and passes tests with all peripherals disabled (CI `core-only` profile).
- NFR-02 Determinism. Given identical inputs and state, settlement produces identical outputs.
- NFR-03 Gas. The CPHR matching is offloaded to Stylus precisely because on-chain matching is gas-prohibitive; core per-swap overhead stays within a budget recorded in the gas report.
- NFR-04 Testability. Each math library is unit-testable in isolation.
- NFR-05 No mainnet. All scripts target testnets only.
- NFR-06 Style. No em dashes in code, comments, or docs. NatSpec on all external/public functions.

## Invariants (must hold under all paths)

- INV-01 Coverage floor. Junior/senior ratio is never allowed to fall below `minCoverageRatioBps` by any senior-intake path.
- INV-02 Senior protection. Senior principal is reduced by IL only after the junior buffer is fully depleted, and never by more than `maxSeniorILExposureBps`.
- INV-03 Conservation. For every settlement, total value out <= total value in plus accrued fees, within a defined rounding tolerance. No value is created.
- INV-04 Waterfall priority. Junior surplus in an epoch is non-zero only after the senior obligation for that epoch is fully funded.
- INV-05 Buffer monotonic sources. The junior buffer can be credited by fee surplus and forfeited unvested fees, and debited by IL absorption and senior shortfall cover. No other path may change it.
- INV-06 Epoch monotonicity. The epoch counter never decreases; accumulated fees for a closed epoch are immutable once settled.

## Traceability

Each FR maps to at least one test in `test/`. Invariants map to tests under `test/invariant/`. The stress scenario (PRD C2) exercises FR-06, FR-08, FR-09, FR-10, FR-12, INV-01, INV-02, INV-03 together and is also the demo script.
