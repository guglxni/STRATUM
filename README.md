# STRATUM

[![CI](https://github.com/guglxni/STRATUM/actions/workflows/ci.yml/badge.svg)](https://github.com/guglxni/STRATUM/actions/workflows/ci.yml)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.26-blue)](https://soliditylang.org/)
[![Foundry](https://img.shields.io/badge/Built%20with-Foundry-FFDB1C.svg)](https://book.getfoundry.sh/)

STRATUM is a structured credit primitive for Uniswap v4 - the first hook to apply credit subordination to AMM liquidity. It splits a liquidity position into a fixed-yield, IL-protected senior tranche and a leveraged-fee, IL-absorbing junior tranche through an on-chain priority waterfall.

> **Demo video:** _add link_ · **Live testnet addresses:** [docs/LIVE_SYSTEM.md](docs/LIVE_SYSTEM.md) · **Judge guide:** [docs/JUDGE_GUIDE.md](docs/JUDGE_GUIDE.md) · **Architecture:** [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)

The full stack is deployed and verified on **Unichain Sepolia** against the canonical Uniswap v4 `PoolManager`, with live peripherals across **Arbitrum Sepolia** (Stylus), **Reactive Lasna** (RSCs), and **Ethereum Sepolia** (Across, Chainlink, Brevis). See [docs/LIVE_SYSTEM.md](docs/LIVE_SYSTEM.md) for explorer evidence.

---

## The Thesis

Traditional AMM liquidity is homogeneous: every LP bears the same impermanent loss (IL) and earns the same fee yield. STRATUM changes the capital structure. Liquidity providers choose one of two tranches:

- **Senior (stLP):** fixed smoothed yield, principal protected against IL up to the junior buffer.
- **Junior (jtLP):** leveraged fee exposure, absorbs all IL before senior principal is touched.

Fees flow through a priority waterfall: senior obligations funded first, junior takes the surplus. On withdrawal, IL is charged to the junior buffer. If the buffer is fully depleted, a configured cap limits how much IL the senior absorbs.

No oracle. No external underwriter. No borrowed capital. The math runs entirely from pool tick deltas.

---

## Prize Track Coverage

| Prize | Mechanism |
|---|---|
| **Uniswap (Novel Primitive)** | Credit subordination on an AMM -- first structured-credit hook |
| **Uniswap (Full Theme)** | All five UHI9 categories: novel yield, IL management, structured products, risk layering, yield-bearing LP tokens |
| **Reactive Network** | EpochSettler, CoverageMonitor, ReserveBalancer RSCs drive settlement with no off-chain keeper |
| **Unichain** | stLP and jtLP are yield-bearing ERC-20 receipt tokens on Unichain |
| **Across** | CrossPoolHedgingRouter (CPHR) aggregates junior reserves cross-pool and bridges cross-chain |
| **Brevis** | BrevisVerifierShim proves time-weighted contribution per epoch surplus via ZK (FR-21) |
| **EigenLayer** | LVR auction proceeds route uncorrelated yield to senior (FR-23); MatchAttestation gates rebalance execution (FR-24) |

---

## Architecture

<p align="center">
  <img src="docs/diagrams/svg/system-layers.svg" alt="STRATUM system layers: core hook, Reactive coordination, and optional peripherals" width="760"/>
</p>

The **core hook** runs the tranche logic, fee waterfall, and settlement with no external dependency. **Reactive Network** sits at the center, coordinating every peripheral layer with no off-chain keeper. The peripherals (Across, Stylus, Brevis, EigenLayer, Chainlink) are optional modules behind interfaces - the core compiles and passes tests with all of them disabled (NFR-01). Layer-by-layer breakdown and the full diagram index: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

---

## Reactive Network integration (where and how)

STRATUM uses Reactive Smart Contracts (RSCs) to drive settlement and risk response **with no off-chain keeper**. The core hook emits ordinary EVM events; the RSCs subscribe to those events on the Reactive chain and schedule callbacks back onto the origin chain.

<p align="center">
  <img src="docs/diagrams/svg/reactive-flow.svg" alt="Reactive event-to-callback flow: hook event on Unichain to react() on Lasna to scheduled callback on Unichain" width="760"/>
</p>

### Where in the code

All three RSCs live in [`src/peripherals/reactive/`](src/peripherals/reactive/):

| RSC | File | Req | Subscribes to (hook event) | Effect on the origin chain |
|-----|------|-----|----------------------------|----------------------------|
| **EpochSettler** | [`EpochSettler.sol`](src/peripherals/reactive/EpochSettler.sol) | FR-15 | `EpochClosed(bytes32,uint64,uint256,uint256)` | Calls `stratumHook.closeEpoch(poolId)` - settles the epoch waterfall |
| **CoverageMonitor** | [`CoverageMonitor.sol`](src/peripherals/reactive/CoverageMonitor.sol) | FR-16 | `CoverageStress(bytes32,uint16,uint16)` | Broadcasts a coverage-stress signal (read-only; never mutates hook state) |
| **ReserveBalancer** | [`ReserveBalancer.sol`](src/peripherals/reactive/ReserveBalancer.sol) | FR-17 | `JuniorReserveUpdated(bytes32,uint64,uint256)` | Requests a CPHR rebalance when a pool's junior reserve diverges from the cross-pool average |

The Reactive plumbing they share is in [`AbstractReactive.sol`](src/peripherals/reactive/AbstractReactive.sol), [`IReactive.sol`](src/peripherals/reactive/IReactive.sol), and [`ISystemContract.sol`](src/peripherals/reactive/ISystemContract.sol).

### How it works

1. **Subscribe (constructor).** Each RSC subscribes to one concrete `topic_0` on the hook via the Reactive system contract. `topic_0` is pinned to a specific event because the system contract rejects a catch-all subscription from a reactive contract. On a plain EVM the subscribe is a no-op, so the core still builds and tests with Reactive absent (NFR-01).
2. **React (`react(LogRecord)`).** When the hook emits a subscribed event, the Reactive Network delivers the log to the RSC's `react` entrypoint on the Reactive chain. `react` decodes `poolId` from `topic_1` and emits a `Callback` scheduling `reactiveCallback(poolId)` on the origin chain.
3. **Callback (`reactiveCallback`).** The Reactive callback proxy executes the scheduled call on Unichain Sepolia - no keeper, no cron. For deterministic Foundry/demo runs each RSC also exposes an operator-gated fallback (`settleEpoch` / `reportCoverage`).

Since the Reactive **Omni fork** (2026-05-25) this is one contract in one environment - there is no ReactVM split. Subscriptions and callbacks remain backward-compatible.

### Live deployment

RSCs on **Reactive Lasna** (chain 5318007), with their callback twins on **Unichain Sepolia**:

| Contract | Reactive Lasna | Unichain twin |
|----------|----------------|---------------|
| EpochSettler | `0xB675…58E2` | `0x57E9…C2b8` |
| CoverageMonitor | `0x54E0…87B3` | `0x32bD…e49f` |
| ReserveBalancer | `0x43084…4c95` | `0xdD7F…9F79` |
| Callback proxy (Unichain) | - | `0x9299…7FC4` |

Full addresses and explorer evidence: [docs/LIVE_SYSTEM.md](docs/LIVE_SYSTEM.md). In the demo UI the **Reactive lab** (`/#labs`) walks these four steps with the live contract links.

---

## Key Invariants

| ID | Rule |
|---|---|
| INV-01 | Coverage floor: `juniorTVL * 10000 / seniorTVL >= minCoverageRatioBps` on every senior intake |
| INV-02 | Senior IL cap: senior principal reduced only after junior buffer depleted, capped at `maxSeniorILExposureBps` |
| INV-03 | Conservation: `totalOut <= totalIn + fees + ROUNDING_TOLERANCE (100 wei)` for every settlement |
| INV-04 | Waterfall priority: junior surplus non-zero only after senior obligation fully funded |
| INV-05 | Buffer monotonicity: `juniorReserve` credited only by fee surplus and fee forfeiture; debited only by IL absorption |
| INV-06 | Epoch monotonicity: epoch counter never decreases |

---

## Quick Start

### Prerequisites

- [Foundry](https://getfoundry.sh/) (forge, cast, anvil)
- Node.js 18+ (for the frontend)

### Build and test

```bash
# Clone with submodules
git clone --recurse-submodules https://github.com/guglxni/STRATUM.git
cd STRATUM

# Build all Solidity
forge build

# Run the full test suite
forge test --no-match-path "test/fork/*"

# Run the Phase 7 stress scenario only (12 tests, PRD C2)
forge test --match-path "test/scenario/Stress.t.sol" -v

# Run invariant fuzz tests (INV-01..06)
forge test --match-path "test/invariant/*"
```

### Deploy to Unichain Sepolia

```bash
# 1. Copy and fill in the environment file
cp .env.example .env
# Set PRIVATE_KEY, UNICHAIN_SEPOLIA_RPC, and optionally ACROSS_SPOKE_POOL

# 2. Broadcast the deployment
forge script script/DeployStratum.s.sol \
  --rpc-url $UNICHAIN_SEPOLIA_RPC \
  --broadcast \
  --slow \
  --delay 1

# 3. Optionally initialize a pool
forge script script/InitStratumPool.s.sol \
  --rpc-url $UNICHAIN_SEPOLIA_RPC \
  --broadcast
```

### Run the demo frontend

```bash
cd frontend
npm install

# Set your deployed hook address
export NEXT_PUBLIC_HOOK_ADDRESS=0x...
export NEXT_PUBLIC_RPC_URL=https://sepolia.unichain.org

npm run dev
# Open http://localhost:5173
```

---

## Repository Layout

```
src/
  StratumHook.sol               Core hook: tranche logic, waterfall, settlement
  TrancheToken.sol              stLP and jtLP ERC-20 receipt tokens
  StratumTypes.sol              Shared structs and enums
  StratumErrors.sol             Custom errors (no revert strings)
  base/StratumBaseHook.sol      BaseHook wrapper
  libraries/
    ILMath.sol                  IL from tick deltas (no oracle)
    Waterfall.sol               Senior-first fee split and dynamic fee
    CoverageRatio.sol           Coverage floor enforcement and stress scalar
    EpochAccounting.sol         Epoch accumulator, obligation, vesting
    ReserveMath.sol             Per-currency clamped payout math
    StratumRateLibrary.sol      Chainlink-benchmarked senior APY (FR-25)
  interfaces/
    IStratumHook.sol            External API for peripherals and scripts
    IPeripheral.sol             Common peripheral interface
  peripherals/
    reactive/                   EpochSettler, CoverageMonitor, ReserveBalancer
    across/                     CorrelationRegistry, CrossPoolHedgingRouter
    brevis/                     BrevisVerifierShim, IBrevisProver
    eigenlayer/                 LVRAuctionReceiver, MatchAttestation
    stylus/                     StylusShim, IStylusMatchingEngine

test/
  scenario/Stress.t.sol         PRD C2: full stress demo (12 tests)
  integration/StratumHook.t.sol Core lifecycle tests
  integration/Peripheral.t.sol  Reactive peripheral integration
  integration/EigenLayer.t.sol  EigenLayer tests (FR-23, FR-24)
  integration/Brevis.t.sol      Brevis verifier shim tests (FR-21, FR-22)
  invariant/StratumInvariants.t.sol INV-01..06 fuzz tests
  unit/                         Library unit tests

script/
  DeployStratum.s.sol           Full deployment: core + all peripherals
  InitStratumPool.s.sol         Pool initialization script
  EnvConfig.sol                 PRIVATE_KEY helper

frontend/
  src/App.tsx                   React demo UI (wagmi/viem)
  src/components/labs/          Per-integration "feature labs" (live reads)
  src/config/addresses.ts       Deployment address config

operator/                       Rust: EigenLayer AVS operator node (match attestation)
stylus/                         Rust: Arbitrum Stylus matching + ML volatility engine
brevis/, brevis-circuits/       Brevis prover tooling and ZK circuits
subgraph/                       The Graph subgraph (epoch/swap/coverage history)
docs/                           Public design docs, PRD, architecture, diagrams
```

---

## Core Design

### Waterfall

<p align="center">
  <img src="docs/diagrams/svg/fee-waterfall.svg" alt="Swap fee to epoch obligation to fee-per-share waterfall" width="640"/>
</p>

Every swap generates fees. The waterfall runs as follows:

1. Dynamic fee is computed: `clamp(baseFeeBps + volBump + stressBump, min, max)`.
2. Fee is split by `Waterfall.splitFee`: senior portion funds the epoch obligation first; junior takes the surplus after the obligation is fully covered.
3. At `closeEpoch`: accumulated fees are checked against the senior obligation. Shortfall is drawn from `juniorReserve`; surplus is credited to `juniorFeePerShareX128`.

### IL Accounting (no oracle)

IL is computed exclusively from pool `sqrtPriceX96` at entry and exit. For a concentrated position `[tickLower, tickUpper]`:

```
held(P_exit)    = amount0_entry * P_exit + amount1_entry  (value if held as tokens)
lpValue(P_exit) = value of LP position at P_exit
IL              = held - lpValue  (>= 0 for any price divergence)
```

All math is Q64.96 fixed-point via `ILMath.sol`.

### Settlement

On `afterRemoveLiquidity`:

- **Junior:** IL charged to `cumulativeILAbsorbed`. If IL > principal + fees, payout is zero. Otherwise: `payout = principal + fees - IL`.
- **Senior:** Junior buffer absorbs IL first (`juniorReserve -= ilOnPosition`). If buffer is depleted, shortfall is capped at `maxSeniorILExposureBps`. If pool returned less than the protected payout, the token-backed reserve (`reserve0`/`reserve1`) tops up the senior LP in real tokens.

### Epoch Vesting (FR-07 / FR-14)

Earnings vest linearly over `smoothingEpochSeconds`. At exit, only the vested fraction is paid. The unvested remainder is forfeited to `juniorReserve` (FR-14), strengthening the buffer for future senior protection.

---

## PRD Success Criteria

| Criterion | Status |
|---|---|
| C1: Core deploys to Unichain Sepolia, full deposit-swap-settle cycle | Deployed via `DeployStratum.s.sol` |
| C2: Scripted stress scenario shows senior made whole, junior absorbing IL | `test/scenario/Stress.t.sol` - 12 tests, all passing |
| C3: Reactive RSCs drive epoch settlement and coverage monitoring live | `EpochSettler`, `CoverageMonitor`, `ReserveBalancer` deployed |
| C4: CPHR demonstrates cross-pool or cross-chain reserve rebalance | `CrossPoolHedgingRouter` with `CorrelationRegistry` |
| C5: At least one Brevis proof path verifies time-weighted distribution | `BrevisVerifierShim.submitTWContributionProof` (FR-21) |
| C6: Submission reads as structured-credit primitive | Opening sentence of this README |

---

## Security Notes

- No peripherals can revert settlement: gas stipend of 150,000, all peripheral calls wrapped in try/catch.
- No oracle in IL math: `ILMath.ilForRange` uses only pool `sqrtPriceX96` (golden rule 2).
- CPHR holds no token custody; it emits events for Reactive to finalize.
- Conservation checked on every settlement path; reverts `ConservationViolation` if violated (INV-03).
- Solidity 0.8.26 (checked arithmetic by default); `FullMath.mulDiv` for Q64.96 multiplication.
- Core compiles and passes all tests with zero peripheral integrations enabled (NFR-01).
