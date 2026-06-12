# STRATUM - Judge Guide

A single page to evaluate STRATUM end to end: what it is, where it lives on-chain, and three ways to
interact with the **live** system (zero setup, CLI, or web UI). Every address below is a real,
verifiable deployment on public testnets. Nothing in this guide is simulated.

> **Deployment generation:** D-1 redeploy, 2026-06-11. The `afterSwapReturnDelta` permission flag was
> enabled (protocol-fee realization), which re-mines the hook's CREATE2 address. All addresses here are
> the **current** generation. The previous hook (`0x1944…67C1`) remains immutable on-chain as the legacy
> address; this guide points only at the live one.

---

## 1. What STRATUM is (60 seconds)

STRATUM is a **Uniswap v4 hook that applies credit subordination to AMM liquidity.** LPs pick one of two
tranches:

- **Senior (`stLP`)** - a fixed, smoothed yield, protected from impermanent loss.
- **Junior (`jtLP`)** - absorbs impermanent loss first, in exchange for leveraged swap-fee upside.

Swap fees flow through a **priority waterfall**: the senior coupon is funded first, the junior takes the
surplus. On withdrawal, impermanent loss is charged to the **junior buffer** before it can ever touch
senior principal. The core needs **no oracle, no external underwriter, and no borrowed capital** -
impermanent loss is computed purely from pool tick deltas.

The novel claim is simple: **a v4 hook can turn one liquidity position into two risk/return profiles,
on-chain, with conservation-checked settlement and no price feed in the loss path.**

---

## 2. The fastest path to "it works" (no wallet, no setup)

Open the **live, fully-seeded demo pool** in the block explorer and read its tranche state. The pool has
already had both tranches funded, a real fee-and-IL-inducing swap, and a closed epoch (the waterfall ran).

1. **Hook contract** (read storage in the explorer's "Read Contract" tab):
   https://unichain-sepolia.blockscout.com/address/0xe932923a5008721564021513838509211CF267c5

2. Call `poolState` with the demo pool id
   `0x45c7eceb6d8b65476779297e5470586e5594f55790d5aac72f26c6194175b8f9` and you will see:
   - `seniorTVL` ≈ `juniorTVL` ≈ 59.1e18 (both tranches funded)
   - `currentEpoch` = 1 (an epoch has closed - the waterfall executed)
   - `poolCumulativeIL` = 29449 (real impermanent loss was charged, junior-first)
   - `epochSeniorObligation` > 0 (the senior coupon accrued)

That single read proves the whole thesis: two tranches, a real swap, IL charged to junior, an epoch
settled by the waterfall - all on-chain.

If you prefer one command (needs [Foundry](https://getfoundry.sh)):

```bash
cast call 0xe932923a5008721564021513838509211CF267c5 \
  "poolState(bytes32)" \
  0x45c7eceb6d8b65476779297e5470586e5594f55790d5aac72f26c6194175b8f9 \
  --rpc-url https://sepolia.unichain.org
```

---

## 3. Live deployment manifest

### Core (Unichain Sepolia, chain 1301)

| Contract | Address | Explorer |
|----------|---------|----------|
| **StratumHook** | `0xe932923a5008721564021513838509211CF267c5` | [↗](https://unichain-sepolia.blockscout.com/address/0xe932923a5008721564021513838509211CF267c5) |
| Uniswap v4 PoolManager (canonical) | `0x00B036B58a818B1BC34d502D3fE730Db729e62AC` | [↗](https://unichain-sepolia.blockscout.com/address/0x00B036B58a818B1BC34d502D3fE730Db729e62AC) |
| **StratumLens** (read aggregator) | `0xCfeB5FcD5a71336676F53d7E802422F39955F46A` | [↗](https://unichain-sepolia.blockscout.com/address/0xCfeB5FcD5a71336676F53d7E802422F39955F46A) |
| Demo token 0 | `0x769FCf62C917f33C1A8b48fd3c71173eDf45167D` | [↗](https://unichain-sepolia.blockscout.com/address/0x769FCf62C917f33C1A8b48fd3c71173eDf45167D) |
| Demo token 1 | `0xb51872d10b16C2f5ce3f58007198546Fe0cDE08f` | [↗](https://unichain-sepolia.blockscout.com/address/0xb51872d10b16C2f5ce3f58007198546Fe0cDE08f) |
| **Demo pool id** | `0x45c7eceb6d8b65476779297e5470586e5594f55790d5aac72f26c6194175b8f9` | (key, not an address) |

### Peripheral integrations (Unichain Sepolia twins)

| Contract | Address | Integration |
|----------|---------|-------------|
| EpochSettler (twin) | `0x57E9Ba9714473F89418b47Ec0F235Ec6956aC2b8` | Reactive Network |
| CoverageMonitor (twin) | `0x32bD92BdDB604b3BbFEE9B3042d38CF2B6e7e49f` | Reactive Network |
| ReserveBalancer (twin) | `0xdD7FdbC6Cc137D73b6F884BA4CeA5611958f9F79` | Reactive Network |
| CrossPoolHedgingRouter (CPHR) | `0x9bcbE702215763e2D90BE8f3a374a41a32a0b791` | Across V3 |
| BrevisVerifierShim | `0x614ab1B307948CF8aB478a04FB9675F676e057F0` | Brevis ZK |
| StylusShim | `0xf3042e120f2C87827A7bE81512A6BFE425b0fC10` | Arbitrum Stylus |
| MatchAttestation (AVS) | `0x1306488e62ceFc1Ff9946e5473ECAD50905E5633` | EigenLayer |
| LVRAuctionReceiver | `0x0bAAcccD5E433af479B2ce7aa0956f2583C601Ae` | EigenLayer |

### Cross-chain components

| Component | Chain | Address |
|-----------|-------|---------|
| EpochSettler RSC | Reactive Lasna (5318007) | `0xB67500437583656160B9C6Da2139E5D4289458E2` |
| CoverageMonitor RSC | Reactive Lasna | `0x54E0a257F389942FD73148E62D0d8061E4e387B3` |
| ReserveBalancer RSC | Reactive Lasna | `0x43084AdbC370a0764f736d8F29272094294A4c95` |
| Reactive callback proxy | Unichain Sepolia | `0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4` |
| Across SpokePool (origin) | Unichain Sepolia | `0x6999526e507Cc3b03b180BbE05E1Ff938259A874` |
| Stylus ML-volatility engine | Arbitrum Sepolia (421614) | `0xf612c8963ff9ae93cfe3b003f3d77f695b8d3e89` |
| Chainlink ETH/USD feed | Ethereum Sepolia (11155111) | `0x694AA1769357215DE4FAC081bf1f309aDC325306` |

Full multi-chain evidence (tx hashes, the closed Across loop, Stylus activation): `docs/LIVE_SYSTEM.md`.

---

## 4. Three ways to interact

### Track A - Block explorer (no setup)

Everything is verifiable from Blockscout's "Read Contract" tab. Useful reads on the hook
(`0xe932…67c5`), all taking the demo pool id `0x45c7eceb…b8f9`:

| Function | Shows |
|----------|-------|
| `poolState(bytes32)` | full tranche state: senior/junior TVL, junior buffer, epoch, accrued fees, cumulative IL |
| `reserve0(bytes32)` / `reserve1(bytes32)` | token-backed reserves the hook custodies |
| `protocolFeeRealization(bytes32)` | whether D-1 real-token fee realization is ON for this pool (demo = false) |
| `protocolFeeReserveBalances(bytes32)` | realized protocol-fee reserves (0 while realization is off) |

For a one-call rollup, use the **StratumLens** `poolOverview` (live price, coverage ratio, stress level,
the dynamic fee the next swap would pay, epoch progress, reserves, D-1 fields).

### Track B - CLI (read and write)

Read the demo pool's coverage and the next swap's dynamic fee via the lens:

```bash
# Lens poolOverview(PoolKey) - PoolKey is (currency0, currency1, fee, tickSpacing, hooks)
cast call 0xCfeB5FcD5a71336676F53d7E802422F39955F46A \
  "poolOverview((address,address,uint24,int24,address))" \
  "(0x769FCf62C917f33C1A8b48fd3c71173eDf45167D,0xb51872d10b16C2f5ce3f58007198546Fe0cDE08f,8388608,60,0xe932923a5008721564021513838509211CF267c5)" \
  --rpc-url https://sepolia.unichain.org
```

Drive a brand-new lifecycle yourself (deploys fresh tokens, opens a pool, seeds both tranches, swaps,
then closes the epoch) - this is exactly what produced the demo pool:

```bash
cp .env.example .env    # set PRIVATE_KEY to a funded Unichain Sepolia testnet key
# Phase 1: deploy tokens, open pool, seed tranches, swap (accrues fees + IL)
DEMO_EPOCH_SECONDS=60 forge script script/DemoLifecycle.s.sol --sig "run()" \
  --rpc-url https://sepolia.unichain.org --broadcast --slow --delay 1
# export the CURRENCY0/CURRENCY1 it prints, wait 60s, then:
# Phase 2: close the epoch (runs the waterfall)
forge script script/DemoLifecycle.s.sol --sig "settle()" \
  --rpc-url https://sepolia.unichain.org --broadcast --slow --delay 1
```

### Track C - Frontend dashboard

The `frontend/` app reads the live addresses from `frontend/src/config/addresses.ts` (already pointed at
this deployment) and renders the demo pool by default.

```bash
cd frontend && npm install && npm run dev
```

It shows tranche TVLs, the coverage ratio and stress level, live dynamic fee, epoch funding progress, and
(when a pool opts into D-1) realized protocol-fee reserves - all sourced through the StratumLens so the UI
never re-implements the hook's math.

---

## 5. What the demo pool demonstrates (the narrative)

The seeded pool `0x45c7eceb…b8f9` walked through STRATUM's full lifecycle on-chain:

1. **Two tranches funded.** Junior buffer seeded first (it backs the coverage ratio), then protected
   senior liquidity. Result: `seniorTVL` ≈ `juniorTVL` ≈ 59.1e18.
2. **A real swap crossed ticks.** It accrued dynamic fees (`epochAccumulatedFees`) and induced impermanent
   loss (`poolCumulativeIL` = 29449). The senior coupon obligation accrued (`epochSeniorObligation` > 0).
3. **The epoch closed.** `closeEpoch` ran the waterfall: the senior obligation was funded first, the
   junior took the surplus, and `currentEpoch` advanced 0 → 1 while `epochAccumulatedFees` reset to 0.

The key invariant a judge can check directly: **impermanent loss landed on the junior accounting, not on
senior principal**, and **total tokens out never exceeded total tokens in plus accrued fees** (conservation).

---

## 6. The D-1 feature: real-token protocol-fee realization

Before this round, the hook's protocol-fee ledger was accounting-only (a number, no tokens behind it).
D-1 makes it **realizable as real tokens** via the `afterSwapReturnDelta` permission, shipped as a
deliberate redeploy and gated so nothing changes until a pool creator opts in:

- **Opt-in per pool, default OFF.** With realization off, `afterSwap` returns a zero delta and books fees
  exactly as before. The demo pool ships OFF, so it is byte-for-byte the legacy behavior. All 295
  pre-existing tests pass unchanged on the new address (306 total with the new D-1/D-4/D-6 tests).
- **When ON,** the protocol fee becomes an **additive surcharge** on the swap's output leg (junior/senior
  keep the full LP fee), taken in real tokens into `protocolFeeReserve0/1`, collectable by the creator via
  `collectProtocolFees`. The surcharge can never over-take, force extra input on a swapper, or revert a
  swap.

To watch it live on your own pool: create one via `DemoLifecycle`, call
`setProtocolFeeRealization(poolId, true)` (creator-gated), run a swap, then read
`protocolFeeReserveBalances(poolId)` and watch the reserves fill.

See `docs/UNISWAP_ENHANCEMENTS.md` for the full enhancement map (D-1, D-4 router compat, D-6 Permit2 zap,
D-7 subgraph) and the "Is the Uniswap API required?" analysis (short answer: no Uniswap-hosted API is
required by any contract).

---

## 7. Multi-chain integrations (what is genuinely live)

| Integration | Chain | Status | What runs |
|-------------|-------|--------|-----------|
| **Uniswap v4** | Unichain Sepolia | ✅ Live | Hook attached to the canonical PoolManager; real swaps/liquidity |
| **Reactive Network** | Lasna → Unichain | ✅ Live | 3 RSCs subscribed to the live hook, callbacks routed to twins |
| **Across V3** | Unichain → Sepolia | ✅ Live | CPHR bound to the real SpokePool; full bridge loop closed (see LIVE_SYSTEM) |
| **EigenLayer (AVS)** | Unichain | ✅ Live | MatchAttestation: 2 operators registered, quorum threshold 2 (a match `isAttested` once both attest it) |
| **Arbitrum Stylus** | Arbitrum Sepolia | ✅ Live | Rust ML-volatility engine activated; `forecastVolatility` callable |
| **Chainlink** | Sepolia | ✅ Live | ETH/USD feed read on-chain (optional senior-rate benchmark, never in IL path) |
| **Brevis ZK** | Sepolia / Arb One | ⚠️ Partial | Verifier shim wired; live proof generation needs Brevis's hosted mainnet gateway |

The golden rule throughout: **peripherals are optional modules behind interfaces.** The core hook compiles
and passes its full test suite with every peripheral disabled (NFR-01).

---

## 8. Verify the hard claims yourself

- **"No oracle in the loss path."** Grep the core: impermanent loss comes from `ILMath` operating on tick
  deltas only. `forge test --match-path 'test/unit/*'` exercises it with no price feed mocked in.
- **"Settlement conserves."** Every settlement path has a conservation assertion. Run
  `forge test --match-contract Settlement` / the invariant suite under `test/invariant/`.
- **"Senior is protected first."** The coverage-ratio invariant is enforced before the junior buffer can be
  reduced; see `test/invariant/StratumInvariants.t.sol`.
- **Reproduce the whole suite:** `forge test` → **306 passing**. Core-only build (peripherals excluded):
  `forge build --skip 'src/peripherals/**' --skip 'test/**' --skip 'script/**'`.

---

## 9. Where to read more

| Question | Doc |
|----------|-----|
| How does it all fit together? | `docs/ARCHITECTURE.md` |
| Exact contract behavior + invariants | `docs/TECHNICAL_DESIGN.md` |
| Why it exists | `docs/PRD.md` |
| Full live multi-chain evidence (tx hashes) | `docs/LIVE_SYSTEM.md` |
| Uniswap enhancement map (D-1/D-4/D-6/D-7) + API analysis | `docs/UNISWAP_ENHANCEMENTS.md` |
| Deployment manifest + verification | `docs/DEPLOYMENT.md` |
| Security posture and audit rounds | `docs/SECURITY_AUDIT.md` |

---

## 10. Honest caveats

- **Brevis live proofs** require Brevis's hosted prover gateway, which currently serves only Ethereum
  Mainnet → Arbitrum One. The on-chain verifier shim and the approximate fallback accounting are live; a
  gateway-settled testnet proof is not self-servable. (`docs/BREVIS_ROUTE_RESOLUTION.md`.)
- **Cross-chain relay** (the Across destination leg) needs second-chain relayer liquidity; the origin
  deposit path is live and the full loop has been demonstrated once end to end (LIVE_SYSTEM).
- **The demo pool ships with D-1 realization OFF** so it mirrors the audited accounting-only behavior. Turn
  it on per-pool to see real-token surcharges, as described in §6.
- This is a **testnet** deployment. The deploy scripts hard-revert on mainnet chain ids (NFR-05).
