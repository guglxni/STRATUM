# STRATUM Build Plan

Phased execution plan. Phases are ordered by dependency, not by calendar. Each phase has an exit criterion that must be green before the next phase is considered done. The core comes first and must stand alone. Peripherals layer on without ever becoming load-bearing for the core.

## Phase 0: Foundation

- Initialize Foundry project, add `v4-core` and `v4-periphery` submodules, solmate, forge-std.
- Set up `.env.example`, CI with a `core-only` profile and a `full` profile.
- Stub `IStratumHook`, `IPeripheral`, `PoolTrancheState`, `TranchePosition`.
- Exit criterion: `forge build` green, empty test suite runs, CI passes both profiles.

## Phase 1: Core hook standalone (the thing that must work)

This is 60 percent of the value. Do it properly before anything else.

- Implement `ILMath`, `Waterfall`, `CoverageRatio`, `EpochAccounting` as pure libraries with unit tests.
- Implement `StratumHook` callbacks: beforeInitialize, afterAddLiquidity, beforeSwap, afterSwap, beforeRemoveLiquidity, afterRemoveLiquidity.
- Implement `TrancheToken` (stLP, jtLP).
- Wire settlement with senior protection and conservation checks.
- Tests: all unit tests, the integration lifecycle on a mock PoolManager, and invariants INV-01 through INV-06.
- Exit criterion: full deposit, swap, epoch, settle cycle passes for both tranches with zero peripherals; all invariants green; conservation holds.

## Phase 2: Deploy and prove on Unichain

- Deployment script for the core hook with correct hook-address flags.
- Fork tests against Unichain Sepolia.
- Live testnet deploy; manual deposit-swap-settle cycle verified on-chain.
- Exit criterion: PRD C1 met (core deploys and cycles on Unichain Sepolia).

## Phase 3: Reactive autonomic layer (the sponsor centerpiece)

- Implement EpochSettler, CoverageMonitor, ReserveBalancer as Reactive Smart Contracts.
- Wire the hook's events to Reactive subscriptions; remove any temporary off-chain triggering used in Phase 1 testing.
- Demonstrate epoch settlement and coverage monitoring firing with no keeper.
- Exit criterion: PRD C3 met; epoch close/open and stress response are driven by Reactive on testnet.

## Phase 4: Cross-Pool Hedging Router (Across) and the fifth category

- Implement `CorrelationRegistry` and `CrossPoolHedgingRouter`.
- Same-chain reserve aggregation (FR-18) first; then cross-chain reserve sharing via Across (FR-19).
- ReserveBalancer (Phase 3) drives rebalances.
- Exit criterion: PRD C4 met; a cross-pool or cross-chain reserve rebalance is demonstrated.

## Phase 5: Verifiable distribution (Brevis)

- Implement the `TimeWeightedContribution` circuit and its Solidity verifier shim.
- Wire `beforeRemoveLiquidity` to request proofs and `afterRemoveLiquidity` to verify them.
- Confirm the on-chain fallback path still settles correctly when Brevis is disabled (FR-22, NFR-01).
- Exit criterion: PRD C5 met; at least one proof path verifies a time-weighted distribution; core-only profile still green.

## Phase 6: Compute layer (Stylus) and supplementary yield (EigenLayer)

- Stylus matching engine in Rust: correlation scan, netting, rebalance-path selection. Solidity shim applies outputs after attestation.
- Stylus ML volatility model feeding the dynamic fee when enabled.
- EigenLayer: `LVRAuctionReceiver` and `MatchAttestation` on-chain; Rust operator node from the Hello World / Incredible Squaring templates.
- Reactive coordinates Unichain to Arbitrum calls so no off-chain polling is needed.
- Exit criterion: matcher produces a netting/rebalance recommendation that the CPHR applies; LVR proceeds route to senior; attestation gates a match.

## Phase 7: Demo, stress scenario, and pitch

- Implement `test/scenario/Stress.t.sol`: crash the underlying price, assert senior made whole and junior absorbing (PRD C2).
- Build the frontend: real-time senior APY (realized vs target), junior reserve health, coverage ratio, cross-chain reserve flow, and a live run of the stress scenario.
- One master architecture diagram showing Reactive at the center coordinating the six peripherals.
- README per `PROPOSAL.md` framing; record a backup demo video.
- Exit criterion: stress scenario passes on-chain in the demo; visualization runs; submission framing leads with "structured credit primitive" (PRD C6).

## Sequencing rules

- Never start a later phase while an earlier phase's exit criterion is red.
- If time compresses, the priority order to preserve is: Phase 1, Phase 2, Phase 3, Phase 7 stress scenario, then Phase 4, then Phases 5 and 6. The core, the Unichain deploy, the Reactive layer, and the stress demo are the non-negotiable spine.
- Every peripheral must keep the core-only CI profile green. A peripheral that cannot is reworked, not merged.

## Definition of done for the submission

- Core deploys and cycles on Unichain Sepolia.
- Reactive drives epoch settlement and coverage live.
- CPHR demonstrates a reserve rebalance.
- At least one Brevis proof path verifies.
- Stress scenario shows senior protection and junior absorption on-chain.
- Architecture diagram, README, and backup video complete.
- Targets the Uniswap, Reactive, and Unichain prizes with Across, Brevis, and EigenLayer as load-bearing supporting integrations.
