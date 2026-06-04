# STRATUM Proposal

UHI9 Hookathon submission. Theme: Impermanent Loss and Yield Systems. This document is the pitch narrative and the source for the README and submission text.

## One sentence

STRATUM is the first Uniswap v4 hook to apply credit subordination to AMM liquidity, splitting a liquidity position into a fixed-yield, IL-protected senior tranche and a leveraged-fee, IL-absorbing junior tranche through an on-chain priority waterfall.

## The problem

Every Uniswap LP holds a position that fuses two opposing forces: swap-fee income and impermanent loss. These cannot be separated today. A conservative provider who wants steady income is forced to carry full IL risk. A risk-tolerant provider who would happily bear IL has no way to get leveraged exposure to fees. So volatile-pair liquidity stays shallow and mercenary, priced for an average risk appetite that no actual participant holds.

## The idea

Borrow the structure that fixed-income markets use for exactly this problem: subordination. Split the position into two classes and let them trade risk with each other inside the pool.

- Senior LPs receive a fixed, smoothed yield and are protected from impermanent loss. Bond-like.
- Junior LPs absorb impermanent loss first and in return capture leveraged fee income. Equity-like.

Fees flow through a priority waterfall: the senior obligation is funded first, junior takes the surplus. Impermanent loss is charged to the junior buffer before it can ever reach senior principal. The risk transfer is internal, voluntary, and priced by the market through a coverage ratio that the hook enforces automatically. No external underwriter, no oracle, no borrowed capital is needed for the core to work.

## Why it is novel

Across the full public history of the Uniswap Hook Incubator, no submission has applied credit tranching, senior/junior subordination, or a priority waterfall to AMM liquidity. Prior impermanent-loss work uses dynamic fees, external hedging, perpetual futures, encrypted insurance, or reserve hedges. STRATUM does something none of them do: it makes the two LP populations underwrite each other. The junior tranche is the underwriter. The fee split is the leverage. The structure is endogenous.

## Coverage of the theme

STRATUM addresses all five UHI9 categories with a single coherent system rather than five separate features:

- IL Insurance: junior subordination and the priority waterfall.
- Fixed Income: the senior tranche pays a configurable fixed APY first from fee income.
- Delta-Neutral: senior delta exposure is structurally offset by junior IL absorption.
- Fee-Smoothing: fees accrue into epochs and vest on a linear schedule.
- Cross-Pool Hedging Routers: the CPHR shares junior reserves across correlated pools and chains.

## Architecture in brief

A core Uniswap v4 hook on Unichain holds the tranche logic. Reactive Network sits at the center as the autonomic coordination layer, driving epoch settlement, coverage monitoring, and reserve balancing, and orchestrating every peripheral with no off-chain keeper. Across powers the Cross-Pool Hedging Router. Brevis provides ZK proofs for time-weighted fee distribution and IL attribution. EigenLayer adds an uncorrelated senior yield source through LVR auctions and attests to cross-chain matches. Arbitrum Stylus runs the gas-heavy matching engine and an ML volatility model in Rust. Each peripheral is optional and reachable only through a common interface; the core compiles and passes its full test suite with every peripheral disabled.

See `ARCHITECTURE.md` for the diagram and `DESIGN.md` for exact behavior.

## Why Reactive is the centerpiece

Most projects use Reactive for a single automation task. STRATUM uses it as the connective tissue of an entire multi-environment architecture: it triggers Stylus compute on Arbitrum from Unichain events, requests Brevis proofs at epoch boundaries, requests EigenLayer attestations when auctions clear, and initiates Across bridges when reserves cross thresholds. This is the canonical demonstration of what Reactive's event-driven model enables, and it removes off-chain keeper infrastructure from the system entirely.

## Sustainability

Senior yield is paid from real fee income (and optional LVR proceeds), never from token emissions. If fees cannot support the target, the hook tightens senior intake rather than going insolvent. The coverage ratio is the control variable: when senior demand outruns junior coverage, intake is blocked and the dynamic fee rises to rebuild the buffer, which lifts junior yield and draws junior capital back. Equilibrium is found by the market, not by governance.

## What we will demonstrate

- The core deployed on Unichain Sepolia with a full deposit, swap, settle cycle for both tranches.
- A live stress scenario: a sharp price move, with senior made whole and junior absorbing the loss, on-chain.
- Reactive Smart Contracts driving epoch settlement and coverage monitoring with no keeper.
- A cross-pool or cross-chain reserve rebalance through the CPHR.
- A Brevis proof verifying a time-weighted distribution.

## Honest scope

The build ships the core primitive, the Reactive coordination layer, the CPHR, and verifiable distribution, with EigenLayer and Stylus as the compute and yield layers. Longer-range capabilities that the architecture naturally enables (an on-chain yield curve across maturities, a volatility index derived from junior pricing, on-chain credit ratings from pool history, recursive tranching, and permissionless securitization of arbitrary cash flows) are presented as the roadmap, not claimed as built. STRATUM today is a structured credit primitive with a credible path to becoming capital-markets infrastructure.

## Prize targets

Primary: Uniswap Prize (novel primitive, full theme coverage), Reactive Network Prize (Reactive as central coordinator), Unichain Prize (tokenized yield-bearing tranches on Unichain). Supporting integrations that are load-bearing rather than ornamental: Across (CPHR), Brevis (verifiable distribution), EigenLayer (supplementary yield and attestation).

## Team

Solo build by Aaryan, UHI8 graduate. Background spans Solidity, Rust, ZK proof systems, and distributed systems, which maps directly onto STRATUM's polyglot architecture (Solidity core, Rust on Stylus, ZK circuits for Brevis, event-driven coordination for Reactive).
