<p align="center">
  <img src="docs/assets/stratum-thumbnail.svg" alt="STRATUM - Structured credit on Uniswap v4" width="900"/>
</p>

<p align="center">
  <a href="https://github.com/guglxni/STRATUM/actions/workflows/ci.yml"><img src="https://github.com/guglxni/STRATUM/actions/workflows/ci.yml/badge.svg" alt="CI"/></a>
  <a href="https://soliditylang.org/"><img src="https://img.shields.io/badge/Solidity-0.8.26-blue" alt="Solidity"/></a>
  <a href="https://book.getfoundry.sh/"><img src="https://img.shields.io/badge/Built%20with-Foundry-FFDB1C.svg" alt="Foundry"/></a>
  <img src="https://img.shields.io/badge/Network-Unichain%20Sepolia-7c3aed" alt="Unichain Sepolia"/>
  <img src="https://img.shields.io/badge/Hook-Uniswap%20v4-ff007a" alt="Uniswap v4"/>
  <img src="https://img.shields.io/badge/Reactive%20Network-Live-22c55e" alt="Reactive Network Live"/>
</p>

<p align="center">
  <strong>Structured credit subordination for Uniswap v4 liquidity.</strong><br/>
  Senior LPs earn a fixed smoothed yield, protected from impermanent loss.<br/>
  Junior LPs absorb IL first in exchange for leveraged fee exposure.<br/>
  No oracle. No underwriter. No borrowed capital.
</p>

> **Demo video:** _add link_ &nbsp;·&nbsp; **Product walkthrough:** [watch below](#product-walkthrough) &nbsp;·&nbsp; **Live addresses:** [docs/LIVE_SYSTEM.md](docs/LIVE_SYSTEM.md) &nbsp;·&nbsp; **Judge guide:** [docs/JUDGE_GUIDE.md](docs/JUDGE_GUIDE.md) &nbsp;·&nbsp; **Architecture:** [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)

The full stack is live on **Unichain Sepolia** against the canonical Uniswap v4 `PoolManager`, with Reactive RSCs on **Lasna** (chain 5318007) driving epoch settlement and coverage monitoring with no off-chain keeper, and Chainlink benchmarking the senior APY target on **Ethereum Sepolia**. Explorer evidence for every contract: [docs/LIVE_SYSTEM.md](docs/LIVE_SYSTEM.md).

---

## Product Walkthrough

<a name="product-walkthrough"></a>

<p align="center">
  <video src="docs/assets/stratum-product-video.mp4" controls poster="docs/assets/stratum-project-thumbnail.png" width="760">
    <a href="docs/assets/stratum-product-video.mp4">Watch the product walkthrough (MP4, ~1.5 MB)</a>
  </video>
</p>
<p align="center"><sub>Covers tranche mechanics, epoch settlement, the fee waterfall, and the live demo UI</sub></p>

---

## The Problem

Every LP in a standard Uniswap v4 pool is structurally identical. They bear the same impermanent loss, earn the same fee yield, and have no way to express different risk appetites within the same pool. A protocol that wants to attract yield-seeking capital alongside risk-tolerant capital has no native mechanism to serve both.

This means:
- Risk-averse LPs (treasuries, structured products, institutional) stay out entirely — IL exposure is unacceptable.
- Risk-tolerant LPs (market makers, yield farmers) earn average returns with no leverage.
- Protocols cannot deepen liquidity by bridging the gap between these two LPs.

---

## The Solution: Credit Subordination on an AMM

STRATUM introduces **credit subordination** — a mechanism from structured finance — directly into the v4 hook. The pool's capital stack is split into two tranches with opposite risk/return profiles that together cover the full range of LP risk appetite:

| | **Senior tranche (stLP)** | **Junior tranche (jtLP)** |
|---|---|---|
| **Token** | `stLP` ERC-20 | `jtLP` ERC-20 |
| **Yield** | Fixed, smoothed APY (Chainlink-benchmarked) | Leveraged fee surplus after senior funded |
| **IL exposure** | Protected — junior absorbs first | Full exposure; also absorbs shortfall |
| **Position in waterfall** | First funded, last to lose | Last funded, first to lose |
| **Who it suits** | Treasuries, stable-yield LPs, risk-averse capital | Market makers, yield farmers, IL-tolerant capital |

The two tranches share a single Uniswap v4 pool and its liquidity. No token bridges, no separate vaults, no external collateral.

---

## Prize Track Coverage

| Prize | What STRATUM delivers |
|---|---|
| **Uniswap v4 — Novel Primitive** | Credit subordination on an AMM — the first structured-credit hook. A new LP primitive that did not exist before v4 hooks. |
| **Uniswap v4 — Full Hook Theme** | Hits all five UHI9 categories in one hook: novel yield mechanism, IL management, structured product, risk layering, yield-bearing LP tokens (stLP / jtLP). |
| **Reactive Network** | Three RSCs (EpochSettler, CoverageMonitor, ReserveBalancer) subscribe to hook events on Lasna and schedule callbacks on Unichain — epoch settlement, stress monitoring, and reserve rebalancing with zero off-chain keeper. See the [dedicated section below](#reactive-network-integration-where-and-how). |
| **Unichain** | stLP and jtLP are yield-bearing ERC-20 receipt tokens deployed and live on Unichain Sepolia — exactly the kind of novel DeFi primitive the chain is designed for. |

---

## Architecture

<p align="center">
  <img src="docs/diagrams/svg/system-layers.svg" alt="STRATUM system layers: core hook, Reactive coordination, and optional peripherals" width="760"/>
</p>

STRATUM is designed in concentric layers:

**Layer 1 — Core hook** (`src/StratumHook.sol`): All tranche logic, the fee waterfall, IL accounting, and settlement. Zero external dependencies. Compiles and passes all tests with every peripheral disabled (NFR-01).

**Layer 2 — Reactive coordination** (`src/peripherals/reactive/`): Three RSCs on Reactive Lasna subscribe to hook events and drive settlement callbacks back to Unichain Sepolia. No keeper, no cron job, no off-chain bot.

**Layer 3 — Optional peripherals** (behind `IPeripheral`): Chainlink APY benchmarking, Arbitrum Stylus matching engine, cross-pool hedging router, Brevis ZK proof verifier, EigenLayer LVR auction receiver. Each is an independent module the core never calls directly — it emits events that peripherals react to.

The full layer breakdown: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

---

## How It Works End to End

### 1. Pool initialization

At `beforeInitialize`, the deployer configures the tranche parameters: target senior APY, coverage floor (minimum `juniorTVL / seniorTVL` ratio), epoch length, IL cap, smoothing window, and fee bounds. These are stored in `PoolTrancheState` and never change after initialization — no admin keys on pool parameters.

### 2. Deposit and tranche selection

LPs call `addLiquidity` with a `tranche` flag. STRATUM mints either `stLP` or `jtLP` tokens proportional to the LP's share. The hook records the entry `sqrtPriceX96` for each position — this is the baseline for IL calculation at exit.

Before a senior deposit is accepted, the coverage ratio invariant is checked: `juniorTVL * 10000 / seniorTVL >= minCoverageRatioBps`. If the junior buffer is too thin, the senior deposit reverts. This prevents senior exposure that cannot be backstopped.

### 3. Fee waterfall on every swap

<p align="center">
  <img src="docs/diagrams/svg/fee-waterfall.svg" alt="Swap fee to epoch obligation to fee-per-share waterfall" width="640"/>
</p>

Every swap triggers a dynamic fee calculation:

```
fee = clamp(baseFeeBps + volatilityBump + stressBump, minFeeBps, maxFeeBps)
```

The fee is then split by `Waterfall.splitFee`:
- Senior portion is credited toward the epoch's senior obligation.
- Junior portion accrues to `juniorFeePerShareX128`.

If the coverage ratio is stressed (junior buffer thin), `stressBump` increases the fee, generating more income to restore the buffer.

### 4. Epoch settlement (triggered by Reactive)

At the end of each epoch, `EpochSettler` (Reactive RSC) calls `stratumHook.closeEpoch(poolId)` via callback. The settlement logic:

1. Sum accumulated fees against the senior obligation for the epoch.
2. If fees are short: draw the shortfall from `juniorReserve`.
3. If fees exceed the obligation: credit the surplus to `juniorFeePerShareX128`.
4. Advance the epoch counter (INV-06: epoch counter never decreases).

Earnings vest linearly over `smoothingEpochSeconds`. At exit, only the vested fraction is paid out — the unvested remainder is forfeited to `juniorReserve`, strengthening the buffer (FR-14).

### 5. Withdrawal and IL settlement

On `afterRemoveLiquidity`, IL is computed from the tick delta since entry using only pool state (no oracle):

```
held(P_exit)    = amount0_entry × P_exit + amount1_entry   (hold-to-exit value)
lpValue(P_exit) = value of LP position at P_exit
IL              = max(0, held − lpValue)
```

**Junior exit:** IL is charged directly. `payout = principal + vestedFees − IL`. If IL exceeds the position, payout is zero — junior cannot go negative.

**Senior exit:** `juniorReserve -= ilOnPosition` absorbs IL first. If the buffer is fully depleted, the remaining shortfall is absorbed by senior principal, capped at `maxSeniorILExposureBps`. If the pool returned less than the protected payout, the token-backed reserve (`reserve0`/`reserve1`) tops up the senior LP in real tokens — the protection is paid in-kind, not in a synthetic.

---

## Reactive Network Integration (where and how)

STRATUM uses Reactive Smart Contracts (RSCs) to drive settlement and risk response **with no off-chain keeper**. The core hook emits ordinary EVM events; the RSCs subscribe on the Reactive chain and schedule callbacks back to the origin chain.

<p align="center">
  <img src="docs/diagrams/svg/reactive-flow.svg" alt="Reactive event-to-callback flow: hook event on Unichain to react() on Lasna to scheduled callback on Unichain" width="760"/>
</p>

### Where in the code

All three RSCs live in [`src/peripherals/reactive/`](src/peripherals/reactive/):

| RSC | File | Subscribes to | Effect on origin chain |
|-----|------|---------------|------------------------|
| **EpochSettler** | [`EpochSettler.sol`](src/peripherals/reactive/EpochSettler.sol) | `EpochClosed(bytes32,uint64,uint256,uint256)` | Calls `stratumHook.closeEpoch(poolId)` — runs the fee waterfall and advances the epoch |
| **CoverageMonitor** | [`CoverageMonitor.sol`](src/peripherals/reactive/CoverageMonitor.sol) | `CoverageStress(bytes32,uint16,uint16)` | Broadcasts a coverage-stress signal so off-chain dashboards and Reactive-aware integrations can react |
| **ReserveBalancer** | [`ReserveBalancer.sol`](src/peripherals/reactive/ReserveBalancer.sol) | `JuniorReserveUpdated(bytes32,uint64,uint256)` | Requests a CPHR rebalance when a pool's junior reserve diverges from the cross-pool average |

Shared Reactive plumbing: [`AbstractReactive.sol`](src/peripherals/reactive/AbstractReactive.sol), [`IReactive.sol`](src/peripherals/reactive/IReactive.sol), [`ISystemContract.sol`](src/peripherals/reactive/ISystemContract.sol).

### How it works (three steps)

1. **Subscribe (constructor).** Each RSC subscribes to one concrete `topic_0` via the Reactive system contract at deploy time. On a plain EVM the subscribe call is a no-op — the core still builds and tests with Reactive absent (NFR-01).
2. **React (`react(LogRecord)`).** When the hook emits a subscribed event, the Reactive Network delivers the log to the RSC's `react` entrypoint on Lasna chain. `react` decodes `poolId` from `topic_1` and emits a `Callback` event scheduling `reactiveCallback(poolId)` on the origin chain.
3. **Callback (`reactiveCallback`).** The Reactive callback proxy executes the scheduled call on Unichain Sepolia — no keeper, no cron. Each RSC also exposes an operator-gated fallback (`settleEpoch` / `reportCoverage`) for deterministic Foundry and demo runs.

Since the Reactive **Omni fork** (2026-05-25) there is one unified environment — no ReactVM split. Subscriptions and callbacks are backward-compatible.

### Live deployment

RSCs on **Reactive Lasna** (chain 5318007), callback twins on **Unichain Sepolia**:

| Contract | Reactive Lasna | Unichain twin |
|----------|----------------|---------------|
| EpochSettler | `0xB675…58E2` | `0x57E9…C2b8` |
| CoverageMonitor | `0x54E0…87B3` | `0x32bD…e49f` |
| ReserveBalancer | `0x43084…4c95` | `0xdD7F…9F79` |
| Callback proxy (Unichain) | — | `0x9299…7FC4` |

Full addresses and explorer links: [docs/LIVE_SYSTEM.md](docs/LIVE_SYSTEM.md). The demo UI's **Reactive lab** (`/#labs`) walks these four steps with live contract links.

---

## Key Invariants

These six invariants are enforced in every code path and fuzz-tested in `test/invariant/StratumInvariants.t.sol`:

| ID | Rule | Enforced at |
|---|---|---|
| INV-01 | Coverage floor: `juniorTVL × 10000 / seniorTVL >= minCoverageRatioBps` | Every senior deposit |
| INV-02 | Senior IL cap: senior principal reduced only after junior buffer depleted, capped at `maxSeniorILExposureBps` | Every senior withdrawal |
| INV-03 | Conservation: `totalOut <= totalIn + fees + ROUNDING_TOLERANCE (100 wei)` | Every settlement path |
| INV-04 | Waterfall priority: junior surplus is non-zero only after the senior obligation is fully funded | `closeEpoch` |
| INV-05 | Buffer monotonicity: `juniorReserve` credited only by fee surplus and fee forfeiture; debited only by IL absorption | Every reserve mutation |
| INV-06 | Epoch monotonicity: epoch counter never decreases | `closeEpoch` |

---

## Quick Start

### Prerequisites

- [Foundry](https://getfoundry.sh/) (forge, cast, anvil) — for the contracts
- Node.js 18+ with npm — for the frontend

### Build and test

```bash
# Clone with submodules (v4-periphery, v4-core)
git clone --recurse-submodules https://github.com/guglxni/STRATUM.git
cd STRATUM

# Build all Solidity (core + peripherals + libraries)
forge build

# Run the full test suite (unit + integration + invariant)
forge test --no-match-path "test/fork/*"

# Run the stress scenario (12 tests, verifies INV-01..03 under volatile price path)
forge test --match-path "test/scenario/Stress.t.sol" -v

# Run invariant fuzz tests (INV-01..INV-06 with 1000 runs each)
forge test --match-path "test/invariant/*"

# Run a single suite
forge test --match-path "test/integration/StratumHook.t.sol" -v
```

All 265+ tests pass with `forge test`. No fork tests are required to pass the core suite.

### Deploy to Unichain Sepolia

```bash
# 1. Copy and fill the environment file
cp .env.example .env
# Required: PRIVATE_KEY, UNICHAIN_SEPOLIA_RPC
# Optional: CHAINLINK_ETH_USD_FEED (defaults to Sepolia address in EnvConfig.sol)

# 2. Deploy core hook + all peripherals
forge script script/DeployStratum.s.sol \
  --rpc-url $UNICHAIN_SEPOLIA_RPC \
  --broadcast \
  --slow \
  --delay 1

# 3. Initialize a WETH/USDC tranche pool
forge script script/InitStratumPool.s.sol \
  --rpc-url $UNICHAIN_SEPOLIA_RPC \
  --broadcast

# 4. Wire Reactive RSCs (deploys EpochSettler, CoverageMonitor, ReserveBalancer)
forge script script/DeployReactive.s.sol \
  --rpc-url $REACTIVE_LASNA_RPC \
  --broadcast
```

### Run the demo frontend

```bash
cd frontend
npm install

# Point at your deployed hook (or use the live testnet addresses from docs/LIVE_SYSTEM.md)
export NEXT_PUBLIC_HOOK_ADDRESS=0x...
export NEXT_PUBLIC_RPC_URL=https://sepolia.unichain.org

npm run dev
# Open http://localhost:5173
```

The frontend includes per-integration "feature labs" at `/#labs` — live reads from the hook, Reactive RSCs, Chainlink feeds, and EigenLayer attestation contract on their respective testnets.

---

## Repository Layout

```
src/
  StratumHook.sol               Core hook: tranche logic, waterfall, settlement
  TrancheToken.sol              stLP and jtLP ERC-20 receipt tokens
  StratumTypes.sol              Shared structs (PoolTrancheState, TranchePosition)
  StratumErrors.sol             Custom errors — no revert strings (gas-efficient)
  base/StratumBaseHook.sol      BaseHook wrapper (v4-periphery)
  libraries/
    ILMath.sol                  IL from tick deltas — pure math, no oracle
    Waterfall.sol               Senior-first fee split and dynamic fee computation
    CoverageRatio.sol           Coverage floor enforcement and stress scalar
    EpochAccounting.sol         Epoch accumulator, obligation, linear vesting
    ReserveMath.sol             Per-currency clamped payout math
    StratumRateLibrary.sol      Chainlink-benchmarked senior APY target (FR-25)
    TrancheSettlementLib.sol    Settlement extracted for EIP-170 compliance
    PoolInitLib.sol             Pool init parameter validation
  interfaces/
    IStratumHook.sol            External API surface — called by peripherals and scripts
    IPeripheral.sol             Common interface all optional modules implement
  peripherals/
    reactive/                   EpochSettler, CoverageMonitor, ReserveBalancer RSCs
    across/                     CorrelationRegistry, CrossPoolHedgingRouter (CPHR)
    brevis/                     BrevisVerifierShim — ZK TW-contribution proofs
    eigenlayer/                 LVRAuctionReceiver, MatchAttestation AVS shim
    stylus/                     StylusShim — calls Arbitrum Stylus matching engine

test/
  scenario/Stress.t.sol         12-test stress scenario (PRD C2): price moves, IL, waterfall
  integration/StratumHook.t.sol Core lifecycle: deposit, swap, settle, withdraw
  integration/Peripheral.t.sol  Reactive peripheral wiring and callback simulation
  integration/EigenLayer.t.sol  MatchAttestation quorum, attestation gating (FR-24)
  integration/Brevis.t.sol      BrevisVerifierShim proof submission (FR-21, FR-22)
  invariant/StratumInvariants.t.sol Fuzz: INV-01..INV-06, 1000 runs each
  unit/                         CoverageRatio, ILMath, Waterfall, EpochAccounting
  utils/StratumFlags.sol        Test helpers and flag constants

script/
  DeployStratum.s.sol           Full deployment: core + all peripherals
  DeployReactive.s.sol          Deploy and wire Reactive RSCs to Lasna
  InitStratumPool.s.sol         Initialize a WETH/USDC pool with tranche params
  InitSepoliaWethPool.s.sol     Sepolia-specific pool init
  DemoLifecycle.s.sol           Scripted end-to-end demo (deposit → swap → settle)
  CanonicalAddresses.sol        Uniswap v4 canonical addresses per chain
  EnvConfig.sol                 PRIVATE_KEY and RPC helpers

frontend/
  src/App.tsx                   Root app (wagmi/viem, hash routing)
  src/Landing.tsx               Marketing landing page
  src/components/labs/          Feature labs: Hook, Reactive, Chainlink, EigenLayer, Across, Brevis
  src/config/addresses.ts       Deployment addresses — all testnets
  src/lib/attestedMatches.ts    Blockscout log fetch for EigenLayer matchHashes

operator/                       Rust: EigenLayer AVS operator node (match attestation signing)
stylus/                         Rust: Arbitrum Stylus matching engine + ML volatility model
brevis/                         Go: Brevis proof request tooling
brevis-circuits/                Go + gnark: ZK circuits for TW-contribution proofs
subgraph/                       The Graph subgraph (epoch, swap, coverage event history)
docs/                           Public docs, PRD, architecture, live system, judge guide, diagrams
```

---

## Core Design

### Fee Waterfall

<p align="center">
  <img src="docs/diagrams/svg/fee-waterfall.svg" alt="Swap fee to epoch obligation to fee-per-share waterfall" width="640"/>
</p>

Every swap generates a fee. The waterfall processes it in three stages:

1. **Dynamic fee computation.** `clamp(baseFeeBps + volBump + stressBump, minFeeBps, maxFeeBps)`. The `stressBump` increases fee income when the coverage ratio is under pressure, accelerating buffer restoration.
2. **Senior-first split.** `Waterfall.splitFee` divides the fee: the senior fraction funds the epoch obligation; the junior fraction accrues to `juniorFeePerShareX128`.
3. **Epoch close.** `closeEpoch` reconciles accumulated fees against the obligation. Shortfall drawn from `juniorReserve`; surplus credited to junior fee-per-share. The epoch counter advances (INV-06).

### IL Accounting (oracle-free)

IL is computed from pool `sqrtPriceX96` alone — no price feed, no oracle. For a concentrated position `[tickLower, tickUpper]`:

```
held(P_exit)    = amount0_entry × P_exit + amount1_entry   (value if tokens held to exit)
lpValue(P_exit) = reconstructed LP position value at P_exit
IL              = max(0, held − lpValue)
```

All arithmetic is Q64.96 fixed-point via `FullMath.mulDiv` and `ILMath.sol`. The absence of an oracle is a security property: no price manipulation can affect IL accounting.

### Senior Protection Mechanism

The senior protection has three layers, applied in order on withdrawal:

1. **Junior buffer:** `juniorReserve` absorbs IL up to the buffer balance.
2. **IL cap:** if the buffer is depleted, the remaining IL is applied to senior principal, but capped at `maxSeniorILExposureBps` of the position size.
3. **Token-backed reserve:** if the pool returned fewer tokens than the protected payout, `reserve0`/`reserve1` top up the senior LP in-kind.

This layering means senior protection is both real (backed by actual reserves) and bounded (the cap prevents unlimited senior loss if junior is completely wiped).

### Epoch Vesting and Smoothing (FR-07, FR-14)

Yield is not paid out immediately on close. Earnings vest linearly over `smoothingEpochSeconds`. At withdrawal, only the vested fraction is paid. The unvested remainder is forfeited to `juniorReserve`. This:
- Prevents senior LPs from exit-arbitraging a high-yield epoch.
- Continuously strengthens the junior buffer, improving coverage ratios over time.
- Smooths the effective senior APY across volatile and quiet epochs alike.

---

## Security Notes

- **No oracle in IL math.** `ILMath.ilForRange` uses only pool `sqrtPriceX96`. Chainlink is an optional input to the senior APY *target* only — never to IL accounting or settlement.
- **Peripheral isolation.** No peripheral can revert a settlement: all peripheral calls are wrapped in `try/catch` with a 150,000 gas stipend. A failing RSC cannot block an LP withdrawal.
- **Conservation enforced.** Every settlement path checks `totalOut <= totalIn + fees + 100 wei`. If violated, the transaction reverts with `ConservationViolation` (INV-03). The 100 wei tolerance covers Q64.96 rounding.
- **Checked arithmetic.** Solidity 0.8.26 reverts on overflow by default. `FullMath.mulDiv` handles intermediate Q64.96 multiplication without overflow risk.
- **No admin keys on pool parameters.** All tranche parameters are set at `beforeInitialize` and immutable after. There is no `setTargetAPY` or similar post-init admin function.
- **Core is always self-contained.** `forge test` passes with zero peripherals enabled (NFR-01). The core cannot be bricked by a peripheral being unavailable.

---

## PRD Success Criteria

| ID | Criterion | Evidence |
|---|---|---|
| C1 | Core deploys to Unichain Sepolia; full deposit-swap-settle cycle | `DeployStratum.s.sol` + [LIVE_SYSTEM.md](docs/LIVE_SYSTEM.md) |
| C2 | Stress scenario: senior made whole, junior absorbing IL | `test/scenario/Stress.t.sol` — 12 tests, all passing |
| C3 | Reactive RSCs drive epoch settlement and coverage monitoring live | EpochSettler, CoverageMonitor, ReserveBalancer deployed on Lasna |
| C4 | CPHR demonstrates cross-pool reserve rebalance | `CrossPoolHedgingRouter` + `CorrelationRegistry` |
| C5 | At least one Brevis proof path verifies TW-contribution per epoch | `BrevisVerifierShim.submitTWContributionProof` (FR-21) |
| C6 | Submission reads as a structured-credit primitive | Opening paragraph of this README |

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for contribution guidelines, branch naming, and the PR checklist.

Security issues: see [SECURITY.md](SECURITY.md) for the responsible disclosure process.

---

## License

MIT — see [LICENSE](LICENSE).
