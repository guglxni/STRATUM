# STRATUM Product Requirements Document

Status: baseline for UHI9. Owner: Aaryan. Audience: build agents, judges, future contributors.

## 1. Problem

A Uniswap LP holds one position that bundles two opposite economic forces: swap-fee income (positive) and impermanent loss (negative, driven by price divergence). Today these cannot be separated. A conservative LP who wants steady income must accept full IL risk. An aggressive LP who is happy to bear IL cannot get leveraged exposure to fees without leaving the pool. The result is that volatile-pair liquidity is shallow, mercenary, and priced for the median risk appetite rather than for the two distinct populations that actually exist.

Existing IL solutions either depend on external underwriters, external leverage, oracles, or AVS hedging. Each adds a counterparty or a trust assumption. None lets the two LP populations simply trade risk with each other inside the pool.

## 2. What we are building

STRATUM, a Uniswap v4 hook that splits an LP position into a senior tranche and a junior tranche and enforces a priority waterfall between them. Senior gets fixed, smoothed, IL-protected yield. Junior gets leveraged fee exposure and absorbs IL first. The risk transfer is internal, voluntary, and market-priced. No external underwriter, oracle, or borrowed capital is needed for the core.

## 3. Goals

- G1: Let an LP choose a senior or junior tranche at deposit and receive a corresponding receipt token (`stLP` or `jtLP`).
- G2: Pay senior a configurable fixed APY, smoothed over an epoch, before any fees reach junior.
- G3: Charge impermanent loss to the junior buffer first, protecting senior principal up to a configured cap.
- G4: Keep the system solvent without governance through coverage-ratio enforcement.
- G5: Cover all five UHI9 categories with one coherent system.
- G6: Demonstrate Reactive Network as the autonomic coordinator of the whole architecture.
- G7: Extend risk-sharing across correlated pools and chains via the Cross-Pool Hedging Router.

## 4. Non-goals

- Not building a general lending protocol. Borrowing against positions is out of scope.
- Not building a perpetuals or options venue. Senior delta protection is structural, not derivative-based.
- Not targeting mainnet. Testnet only for UHI9.
- Not relying on token emissions for yield. Yield is real fee income plus optional LVR proceeds.

## 5. Users

- Conservative LP / treasury (senior): wants predictable yield and capital protection, will accept capped upside. Holds `stLP`. May be an individual, a DAO treasury, or an institution.
- Aggressive LP / yield seeker (junior): believes fees will exceed IL for a given pair, wants leveraged fee exposure, accepts first-loss IL. Holds `jtLP`.
- Swapper: trades against the pool, pays the dynamic fee, otherwise interacts with STRATUM exactly as a normal v4 pool.
- Integrator: another protocol that uses `stLP` as a fixed-income building block or references STRATUM-derived signals.

## 6. User stories

- US1: As a senior LP, I deposit into an ETH/USDC STRATUM pool, choose senior, and receive `stLP`. Over the epoch I accrue a fixed APY. When I withdraw, I get my principal plus accrued yield, and I am protected from IL because the junior buffer absorbed it.
- US2: As a junior LP, I deposit and choose junior, receiving `jtLP`. I earn the surplus fees above senior obligations, which is leveraged relative to a vanilla LP. If the pair moves sharply, my buffer absorbs the IL, which is the risk I accepted.
- US3: As a senior LP in a pool whose junior buffer is depleting, my new senior deposit is blocked until coverage recovers, so I am never let into a pool that cannot protect me.
- US4: As a junior LP, when my pool's buffer is breached but a correlated pool on another chain has a healthy buffer, the system bridges reserves to stabilize my pool without my intervention.
- US5: As a junior LP who entered and exited mid-epoch, my fee share and IL charge are computed for my exact holding period and proven correct, not approximated.

## 7. Functional summary

Detailed, testable requirements with IDs live in `REQUIREMENTS.md`. At a high level the product must: register tranche choice and mint receipts; split fees through a senior-first waterfall; track IL per position from tick deltas; smooth distributions over epochs; enforce the coverage ratio floor; settle exactly on withdrawal with senior protection; and expose events for autonomic coordination and the demo UI.

## 8. Success criteria for UHI9

- C1: Core hook deploys to Unichain Sepolia and a full deposit-swap-settle cycle works for both tranches.
- C2: A scripted stress scenario shows senior made whole and junior absorbing the loss, on-chain, in the demo.
- C3: Reactive Smart Contracts drive epoch settlement and coverage monitoring live, with no off-chain keeper.
- C4: The CPHR demonstrates a cross-pool or cross-chain reserve rebalance.
- C5: At least one Brevis proof path verifies a time-weighted distribution.
- C6: The submission reads as a structured-credit primitive, not as another IL-insurance hook, in its first sentence.

## 9. Risks and honest position

- Complexity across seven environments is the main risk. Mitigation: the core is independent and each peripheral is optional behind an interface, so a failing peripheral never blocks the demo.
- The IL-protection space is crowded, so framing matters. Mitigation: lead with credit subordination, never with "IL insurance".
- Economic edge cases (junior flight in a black swan) must be stress-tested, not assumed. Mitigation: the coverage floor, dynamic fee response, and cross-pool reserves are the documented defenses, and the stress scenario is a first-class deliverable (C2).
- Some long-range capabilities (yield curve, credit ratings, securitization) are roadmap, not V1. They are presented as natural extensions, never claimed as built.

## 10. Out-of-scope ideas kept for roadmap

On-chain yield curve across maturities, synthetic volatility index from junior pricing, on-chain credit ratings from pool history, recursive tranching, junior default swaps, permissionless securitization of arbitrary cash flows. Documented here so they are not mistaken for V1 scope.
