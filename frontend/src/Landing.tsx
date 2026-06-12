/**
 * STRATUM landing page, set in the DESIGN.md (apple) system: full-bleed tiles that alternate
 * white / parchment / near-black (the color change is the divider), one interactive accent
 * (Action Blue), SF Pro-style typography with negative display tracking, pill CTAs, hairline
 * cards, and no decorative gradients or chrome shadows.
 */

import { STRATUM_ADDRESSES, STRATUM_LIVE_MULTICHAIN } from "./config/addresses";
import { explorerAddress, CHAIN_IDS } from "./config/explorers";

// Data-driven deployment table: each row links to the correct per-chain explorer (STRATUM spans
// four testnets, so a single hardcoded base produced dead links for the non-Unichain contracts).
const DEPLOY_ROWS: { label: string; addr: string; chainId: number; chip: string }[] = [
  { label: "StratumHook", addr: STRATUM_ADDRESSES.hook, chainId: CHAIN_IDS.UNICHAIN_SEPOLIA, chip: "Unichain" },
  { label: "Uniswap v4 PoolManager", addr: STRATUM_ADDRESSES.poolManager, chainId: CHAIN_IDS.UNICHAIN_SEPOLIA, chip: "Unichain" },
  { label: "StratumLens (reads)", addr: STRATUM_ADDRESSES.lens, chainId: CHAIN_IDS.UNICHAIN_SEPOLIA, chip: "Unichain" },
  { label: "StratumZap (deposits)", addr: STRATUM_ADDRESSES.zap, chainId: CHAIN_IDS.UNICHAIN_SEPOLIA, chip: "Unichain" },
  { label: "CrossPoolHedgingRouter", addr: STRATUM_ADDRESSES.cphr, chainId: CHAIN_IDS.UNICHAIN_SEPOLIA, chip: "Unichain" },
  { label: "Stylus ML engine", addr: STRATUM_LIVE_MULTICHAIN.stylusEngineArbitrum, chainId: CHAIN_IDS.ARBITRUM_SEPOLIA, chip: "Arbitrum" },
  { label: "EpochSettler RSC", addr: STRATUM_LIVE_MULTICHAIN.reactiveLasna.epochSettler, chainId: CHAIN_IDS.REACTIVE_LASNA, chip: "Lasna" },
  { label: "CoverageMonitor RSC", addr: STRATUM_LIVE_MULTICHAIN.reactiveLasna.coverageMonitor, chainId: CHAIN_IDS.REACTIVE_LASNA, chip: "Lasna" },
  { label: "Across destination + Chainlink", addr: STRATUM_LIVE_MULTICHAIN.sepolia.cphr, chainId: CHAIN_IDS.ETHEREUM_SEPOLIA, chip: "Sepolia" },
].filter((r) => r.addr);

function Tick() {
  return (
    <svg className="tick" viewBox="0 0 16 16" fill="none" aria-hidden>
      <path d="M3 8.5l3.2 3.2L13 5" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

const FEATURES: { title: string; body: string; ref: string }[] = [
  {
    title: "Priority fee waterfall",
    body: "Every swap fee flows senior-first. The senior coupon is funded before junior sees a single wei; junior keeps the entire surplus above the obligation.",
    ref: "FR-03 / INV-04",
  },
  {
    title: "Oracle-free IL accounting",
    body: "Impermanent loss is computed purely from pool tick deltas. No price feed, no external data source, nothing to manipulate or go stale in the core math.",
    ref: "Golden rule 2",
  },
  {
    title: "Junior first-loss buffer",
    body: "On withdrawal, IL is charged to the junior buffer before it can ever touch senior principal. The coverage-ratio floor is enforced on every deposit and exit.",
    ref: "FR-08 / INV-01",
  },
  {
    title: "Epoch smoothing and vesting",
    body: "Yield accrues per-share in fixed epochs and vests linearly, turning spiky swap-fee income into a smooth, predictable senior coupon stream.",
    ref: "FR-06 / FR-07",
  },
  {
    title: "Sandwich-proof settlement",
    body: "Block-start price anchors neutralize same-block manipulation: senior make-whole and junior IL clawback both settle against the anchored price.",
    ref: "A-06 / R2-01",
  },
  {
    title: "Token-backed make-whole reserve",
    body: "Senior protection pays out in real tokens held by the hook, funded by IL clawbacks and LVR auction proceeds. A conservation-checked ledger, not an IOU.",
    ref: "R-H1 / INV-03",
  },
  {
    title: "Volatility-aware dynamic fees",
    body: "Swap fees adapt inside a creator-set band using an on-chain EWMA of realized volatility, with an optional Rust/Stylus ML model as an override source.",
    ref: "FR-05 / BS3",
  },
  {
    title: "Realized protocol fees",
    body: "Opt-in per pool: the protocol fee becomes a real-token swap surcharge collected via afterSwapReturnDelta, withdrawable by the treasury. Off by default.",
    ref: "D-1",
  },
  {
    title: "Permit2 zap onboarding",
    body: "One signature opens a tranche position: StratumZap pulls funding through canonical Permit2, opens the v4 position, and refunds the unused remainder.",
    ref: "D-6",
  },
  {
    title: "In-place tranche migration",
    body: "Move a position between senior and junior without exiting the pool. IL settles at the anchored price on the way through; migration can never dodge a clawback.",
    ref: "FR-16",
  },
  {
    title: "Single-call reads for UIs and agents",
    body: "StratumLens aggregates pool, tranche, and position state - including live IL and the next swap fee - in one call, computed by the hook's own libraries.",
    ref: "Lens",
  },
  {
    title: "Indexed history",
    body: "A The Graph subgraph indexes every state transition the hook emits: epochs, swaps, stress events, migrations, and protocol-fee flows.",
    ref: "D-7",
  },
];

const PERIPHERALS = [
  {
    name: "Reactive Network",
    pill: "automation",
    body: "EpochSettler, CoverageMonitor, and ReserveBalancer RSCs close epochs and respond to coverage stress autonomously, cross-chain.",
  },
  {
    name: "Across",
    pill: "bridging",
    body: "CrossPoolHedgingRouter bridges reserve liquidity between chains so a stressed pool can be topped up from a remote reserve pool.",
  },
  {
    name: "Brevis ZK",
    pill: "zk proofs",
    body: "Optional ZK-proven fee accounting: settlement can consume a proof, floored at the on-chain IL so a forged proof can never under-charge.",
  },
  {
    name: "EigenLayer AVS",
    pill: "restaking",
    body: "LVR auction proceeds flow back into the token-backed reserve; operator quorums attest matching results.",
  },
  {
    name: "Arbitrum Stylus",
    pill: "rust + ml",
    body: "A Rust matching engine and ML volatility model provide an optional EWMA override for the dynamic fee, behind a narrow shim.",
  },
  {
    name: "Chainlink",
    pill: "benchmark",
    body: "An optional rate feed sets the senior target APY (floor + spread, bounded and staleness-checked). Never used for IL accounting.",
  },
];

interface LandingProps {
  onLaunch: () => void;
  onDeposit: () => void;
}

export default function Landing({ onLaunch, onDeposit }: LandingProps) {
  return (
    <div>
      {/* single global nav: logo, section links, and the persistent CTAs */}
      <nav className="gnav">
        <div className="container-wide gnav-inner">
          <button className="gnav-logo" onClick={() => window.scrollTo({ top: 0, behavior: "smooth" })}>
            <span className="logo-mark" aria-hidden>
              <span />
              <span />
              <span />
            </span>
            STRATUM
          </button>
          <div className="gnav-right">
            <div className="gnav-links">
              <a href="#tranches">Tranches</a>
              <a href="#how">How it works</a>
              <a href="#reactive">Reactive</a>
              <a href="#features">Features</a>
              <a href="#stack">Stack</a>
              <a href="#security">Security</a>
              <a href="#deployments">Deployments</a>
            </div>
            <a
              className="gnav-cta-link"
              href="#deposit"
              onClick={(e) => {
                e.preventDefault();
                onDeposit();
              }}
            >
              Deposit
            </a>
            <button className="btn-pill btn-pill-sm" onClick={onLaunch}>
              Launch App
            </button>
          </div>
        </div>
      </nav>

      {/* hero: white tile, centered stack */}
      <header className="tile center reveal">
        <div className="container">
          <p className="caption-strong" style={{ color: "var(--ink-muted-48)", marginBottom: 14 }}>
            Live on Unichain Sepolia &middot; Uniswap v4 hook
          </p>
          <h1 className="hero-display" style={{ marginBottom: 18 }}>
            Credit tranching for AMM liquidity.
          </h1>
          <p className="lead" style={{ maxWidth: 720, margin: "0 auto 28px", color: "var(--ink-muted-80)" }}>
            One pool, two seats. Senior LPs earn a fixed, smoothed yield with impermanent-loss protection. Junior LPs
            take leveraged exposure to every fee the pool earns above the coupon.
          </p>
          <div className="stack-cta">
            <button className="btn-pill" onClick={onLaunch}>
              Open the Dashboard
            </button>
            <a className="btn-pill-ghost" href="#how">
              See how it works
            </a>
          </div>
        </div>
      </header>

      {/* dark tile: the waterfall, the product shot of this protocol */}
      <section className="tile-dark center">
        <div className="container">
          <h2 className="display-lg" style={{ marginBottom: 10 }}>
            The waterfall is the product.
          </h2>
          <p className="lead" style={{ color: "var(--body-muted-dark)", maxWidth: 640, margin: "0 auto 40px" }}>
            Senior obligation funds first, every epoch. Junior takes everything that remains.
          </p>
          <div className="wf-card" style={{ maxWidth: 640, margin: "0 auto", textAlign: "left" }} aria-hidden>
            <div className="wf-title">Fee waterfall &middot; one epoch</div>
            <div className="wf-row">
              <span className="wf-label">Swap fees in</span>
              <div className="wf-track">
                <div className="wf-fill fees" />
              </div>
            </div>
            <div className="wf-row">
              <span className="wf-label">Senior coupon</span>
              <div className="wf-track">
                <div className="wf-fill senior" />
              </div>
            </div>
            <div className="wf-row">
              <span className="wf-label">Junior surplus</span>
              <div className="wf-track">
                <div className="wf-fill junior" />
              </div>
            </div>
            <div className="wf-note">
              Fees are booked in a single numeraire and flow senior-first. On the way out, impermanent loss is charged
              junior-first - the buffer is the insurance.
            </div>
          </div>
        </div>
      </section>

      {/* parchment stats band */}
      <section className="tile-parchment">
        <div className="container">
          <div className="stats-grid">
            <div className="stat">
              <div className="num">306</div>
              <div className="label">Foundry tests, all green</div>
            </div>
            <div className="stat">
              <div className="num">0</div>
              <div className="label">Oracles in core IL math</div>
            </div>
            <div className="stat">
              <div className="num">6</div>
              <div className="label">Optional peripheral layers</div>
            </div>
            <div className="stat">
              <div className="num">4</div>
              <div className="label">Chains in the live demo</div>
            </div>
          </div>
        </div>
      </section>

      {/* tranches: white tile, two utility cards (light = senior, dark = junior) */}
      <section className="tile" id="tranches">
        <div className="container">
          <h2 className="display-lg center" style={{ marginBottom: 10 }}>
            Pick your seat in the capital structure.
          </h2>
          <p className="lead center" style={{ color: "var(--ink-muted-80)", maxWidth: 640, margin: "0 auto 44px" }}>
            Classic structured credit, applied to AMM liquidity. No borrowed capital, no underwriter - junior capital
            is the insurance.
          </p>

          <div className="ugrid-2">
            <div className="ucard">
              <p className="caption-strong" style={{ color: "var(--primary)", marginBottom: 12 }}>
                stLP &middot; SENIOR
              </p>
              <h3 className="tagline" style={{ marginBottom: 8 }}>
                Fixed yield, protected principal
              </h3>
              <p className="caption muted" style={{ marginBottom: 16 }}>
                For LPs who want AMM yield without AMM risk. A bond-like position on top of a Uniswap pool.
              </p>
              <ul className="checklist">
                <li>
                  <Tick />
                  Fixed target APY, smoothed across epochs and paid before anything else
                </li>
                <li>
                  <Tick />
                  Impermanent loss absorbed by the junior buffer, up to a configured cap
                </li>
                <li>
                  <Tick />
                  Make-whole paid in real tokens from the hook-held reserve
                </li>
                <li>
                  <Tick />
                  Optional benchmark-linked rate (Chainlink floor + spread)
                </li>
              </ul>
            </div>

            <div className="ucard-dark">
              <p className="caption-strong" style={{ color: "var(--primary-on-dark)", marginBottom: 12 }}>
                jtLP &middot; JUNIOR
              </p>
              <h3 className="tagline" style={{ marginBottom: 8 }}>
                Leveraged fees, first-loss risk
              </h3>
              <p className="caption muted-dark" style={{ marginBottom: 16 }}>
                For LPs who want amplified fee income and accept being the buffer that makes senior safe.
              </p>
              <ul className="checklist">
                <li>
                  <Tick />
                  Entire fee surplus above the senior obligation, every epoch
                </li>
                <li>
                  <Tick />
                  Leveraged exposure: junior capital is smaller than the fees it claims
                </li>
                <li>
                  <Tick />
                  Absorbs IL first - clawbacks fund the reserve that protects senior
                </li>
                <li>
                  <Tick />
                  Forfeited unvested fees recycle into the junior buffer
                </li>
              </ul>
            </div>
          </div>

          <div className="center" style={{ marginTop: 32 }}>
            <button className="btn-pill" onClick={onDeposit}>
              Deposit into a tranche
            </button>
          </div>
        </div>
      </section>

      {/* how it works: parchment tile, 4 steps */}
      <section className="tile-parchment" id="how">
        <div className="container">
          <h2 className="display-lg center" style={{ marginBottom: 10 }}>
            How a deposit becomes a coupon.
          </h2>
          <p className="lead center" style={{ color: "var(--ink-muted-80)", maxWidth: 640, margin: "0 auto 44px" }}>
            The entire lifecycle runs inside Uniswap v4 hook callbacks. Anyone can close an epoch; Reactive Network
            automates it in the live demo.
          </p>
          <div className="ugrid-4">
            {[
              {
                n: "01",
                t: "Deposit into a tranche",
                b: "Add liquidity through the hook - or one signature via StratumZap and Permit2 - and choose senior or junior. The coverage-ratio floor is checked on entry.",
              },
              {
                n: "02",
                t: "Fees hit the waterfall",
                b: "Every swap pays a volatility-aware dynamic fee. Fees accumulate per epoch and are booked senior-first: obligation, then junior surplus.",
              },
              {
                n: "03",
                t: "Epochs smooth the yield",
                b: "At each close the senior coupon is funded (topped up from the junior buffer on a shortfall) and per-share accumulators advance. Earnings vest linearly.",
              },
              {
                n: "04",
                t: "Exit with senior protection",
                b: "On withdrawal, IL is measured from tick deltas at a block-start anchored price. Junior absorbs it first; senior is made whole in real tokens.",
              },
            ].map((s) => (
              <div className="ucard" key={s.n}>
                <span className="step-num">{s.n}</span>
                <h4 className="caption-strong" style={{ fontSize: 16, marginBottom: 6 }}>
                  {s.t}
                </h4>
                <p className="caption muted">{s.b}</p>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* reactive network: dark tile, the automation story (sponsor spotlight) */}
      <section className="tile-dark" id="reactive">
        <div className="container">
          <p className="caption-strong center" style={{ color: "var(--primary-on-dark)", marginBottom: 14 }}>
            Powered by Reactive Network
          </p>
          <h2 className="display-lg center" style={{ marginBottom: 10 }}>
            STRATUM runs itself.
          </h2>
          <p className="lead center" style={{ color: "var(--body-muted-dark)", maxWidth: 720, margin: "0 auto 20px" }}>
            A credit-tranching protocol can never sit idle. Epochs have to close on time, coverage stress has to be
            caught the instant it appears, and reserves have to move to wherever they are needed. Most protocols hand
            that job to a centralized keeper bot, or hope a user remembers to poke the contract. STRATUM does not have
            to - and that is entirely thanks to Reactive Network.
          </p>
          <p className="lead center" style={{ color: "var(--body-muted-dark)", maxWidth: 720, margin: "0 auto 40px" }}>
            Reactive Smart Contracts (RSCs) are Reactive Network's signature primitive and STRATUM's automation layer.
            They watch the hook's on-chain activity and act on it autonomously: no off-chain server, no privileged
            operator, no cron job, nothing to trust. The upkeep that keeps senior LPs safe lives entirely on-chain.
          </p>

          <div className="ugrid">
            <div className="ucard-dark" style={{ borderColor: "rgba(41, 151, 255, 0.4)" }}>
              <p className="caption-strong" style={{ color: "var(--primary-on-dark)", marginBottom: 8 }}>
                EpochSettler RSC
              </p>
              <h4 className="tagline" style={{ marginBottom: 6 }}>
                Closes every epoch on schedule
              </h4>
              <p className="caption muted-dark">
                Watches for epoch boundaries and settles the senior coupon automatically, so the smoothed yield never
                depends on someone remembering to trigger it.
              </p>
            </div>
            <div className="ucard-dark" style={{ borderColor: "rgba(41, 151, 255, 0.4)" }}>
              <p className="caption-strong" style={{ color: "var(--primary-on-dark)", marginBottom: 8 }}>
                CoverageMonitor RSC
              </p>
              <h4 className="tagline" style={{ marginBottom: 6 }}>
                Catches stress the moment it starts
              </h4>
              <p className="caption muted-dark">
                Reacts to coverage-stress signals the instant the junior buffer thins, surfacing risk long before senior
                principal could ever be touched.
              </p>
            </div>
            <div className="ucard-dark" style={{ borderColor: "rgba(41, 151, 255, 0.4)" }}>
              <p className="caption-strong" style={{ color: "var(--primary-on-dark)", marginBottom: 8 }}>
                ReserveBalancer RSC
              </p>
              <h4 className="tagline" style={{ marginBottom: 6 }}>
                Moves liquidity to where it is needed
              </h4>
              <p className="caption muted-dark">
                Detects reserve divergence and triggers cross-chain rebalancing, so a stressed pool can be topped up
                from a healthy one without any manual intervention.
              </p>
            </div>
          </div>

          <p className="lead center" style={{ color: "var(--body-muted-dark)", maxWidth: 720, margin: "40px auto 0" }}>
            Reactive Network turns "someone has to run this" into "the protocol maintains itself" - the difference
            between a demo and a system you can safely leave alone. STRATUM's RSCs live on Reactive's Lasna network,
            reacting to live Unichain events and routing their responses back across chains, in the open, for anyone to
            verify.
          </p>
        </div>
      </section>

      {/* features: white tile, 3-col utility grid */}
      <section className="tile" id="features">
        <div className="container-wide">
          <h2 className="display-lg center" style={{ marginBottom: 10 }}>
            Everything the hook does.
          </h2>
          <p className="lead center" style={{ color: "var(--ink-muted-80)", maxWidth: 640, margin: "0 auto 44px" }}>
            Each feature maps to a numbered requirement and at least one Foundry test.
          </p>
          <div className="ugrid">
            {FEATURES.map((f) => (
              <div className="ucard" key={f.title}>
                <h4 className="caption-strong" style={{ fontSize: 16, marginBottom: 6 }}>
                  {f.title}
                </h4>
                <p className="caption muted">{f.body}</p>
                <p className="fine-print mono" style={{ marginTop: 12 }}>
                  {f.ref}
                </p>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* architecture: dark tile */}
      <section className="tile-dark" id="architecture">
        <div className="container-wide">
          <h2 className="display-lg center" style={{ marginBottom: 10 }}>
            A core that needs nothing.
          </h2>
          <p className="lead center" style={{ color: "var(--body-muted-dark)", maxWidth: 680, margin: "0 auto 44px" }}>
            The core hook compiles, deploys, and passes every test with zero peripherals enabled. Integrations are
            notify-only, gas-stipended, and failure-isolated - a peripheral can never block settlement.
          </p>

          <div className="ucard-dark" style={{ marginBottom: 20, borderColor: "rgba(41, 151, 255, 0.4)" }}>
            <h4 className="tagline" style={{ marginBottom: 6 }}>
              Core: StratumHook + math libraries
            </h4>
            <p className="caption muted-dark">
              Tranche accounting, IL math from tick deltas, the senior-first waterfall, coverage-ratio enforcement,
              epoch accounting, and conservation-checked settlement. Solidity on Unichain, attached to the canonical
              Uniswap v4 PoolManager.
            </p>
          </div>

          <div className="ugrid">
            {PERIPHERALS.map((p) => (
              <div className="ucard-dark" key={p.name}>
                <h4 className="caption-strong" style={{ fontSize: 15, marginBottom: 6 }}>
                  {p.name} <span className="fine-print mono">({p.pill})</span>
                </h4>
                <p className="caption muted-dark">{p.body}</p>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* tech stack: parchment tile */}
      <section className="tile-parchment" id="stack">
        <div className="container">
          <h2 className="display-lg center" style={{ marginBottom: 10 }}>
            A modern, verifiable stack.
          </h2>
          <p className="lead center" style={{ color: "var(--ink-muted-80)", maxWidth: 680, margin: "0 auto 44px" }}>
            Every layer is chosen so the system is easy to read, hard to fake, and pleasant to use - from the contracts
            up to the dashboard you are looking at.
          </p>
          <div className="ugrid">
            <div className="ucard">
              <p className="caption-strong" style={{ color: "var(--primary)", marginBottom: 8 }}>
                Frontend
              </p>
              <h4 className="tagline" style={{ marginBottom: 6 }}>
                React, wagmi, viem, Vite
              </h4>
              <p className="caption muted">
                A React and TypeScript app with type-safe contract calls through wagmi and viem. WalletConnect,
                Coinbase Wallet, and browser wallets all connect out of the box. The dashboard reads pool state through a
                single lens call and renders every chart live in the browser - no backend to trust.
              </p>
            </div>
            <div className="ucard">
              <p className="caption-strong" style={{ color: "var(--primary)", marginBottom: 8 }}>
                Contracts
              </p>
              <h4 className="tagline" style={{ marginBottom: 6 }}>
                Solidity, Foundry, Uniswap v4
              </h4>
              <p className="caption muted">
                The hook is Solidity, built and exhaustively tested with Foundry - 306 passing tests across unit,
                integration, fork, invariant, and stress suites - and deployed against the canonical Uniswap v4
                PoolManager on Unichain.
              </p>
            </div>
            <div className="ucard">
              <p className="caption-strong" style={{ color: "var(--primary)", marginBottom: 8 }}>
                Automation and cross-chain
              </p>
              <h4 className="tagline" style={{ marginBottom: 6 }}>
                Reactive, Across, EigenLayer, Stylus
              </h4>
              <p className="caption muted">
                Reactive Network drives the autonomous upkeep, Across moves cross-chain reserves, EigenLayer provides
                restaked attestation, Arbitrum Stylus runs a Rust ML volatility model, and Brevis and Chainlink add
                optional ZK proofs and a benchmark rate. Each one is opt-in and failure-isolated from the core.
              </p>
            </div>
          </div>
        </div>
      </section>

      {/* security: white tile */}
      <section className="tile" id="security">
        <div className="container">
          <h2 className="display-lg center" style={{ marginBottom: 10 }}>
            Audited. Invariant-tested. Conservation-checked.
          </h2>
          <p className="lead center" style={{ color: "var(--ink-muted-80)", maxWidth: 680, margin: "0 auto 44px" }}>
            Multiple audit rounds produced 25 findings - every one fixed with a dedicated regression test. The suite
            enforces the protocol's invariants on every run.
          </p>
          <div className="ugrid-2">
            <div className="ucard">
              <h4 className="caption-strong" style={{ fontSize: 16, marginBottom: 12 }}>
                Protocol invariants
              </h4>
              <ul className="checklist">
                <li>
                  <Tick />
                  Conservation: tokens out never exceed tokens in plus accrued fees, on every settlement path
                </li>
                <li>
                  <Tick />
                  Coverage floor: junior/senior ratio can never be pushed below the configured minimum
                </li>
                <li>
                  <Tick />
                  Senior protection: IL hits the junior buffer before senior principal, always
                </li>
                <li>
                  <Tick />
                  Waterfall order: senior obligation funds before junior surplus, every epoch
                </li>
                <li>
                  <Tick />
                  Monotonic epochs: accounting can only roll forward
                </li>
              </ul>
            </div>
            <div className="ucard">
              <h4 className="caption-strong" style={{ fontSize: 16, marginBottom: 12 }}>
                Hardening highlights
              </h4>
              <ul className="checklist">
                <li>
                  <Tick />
                  Block-start price anchors defeat same-block sandwich attacks on both tranches
                </li>
                <li>
                  <Tick />
                  Creator-gated pool initialization stops front-run parameter hijacks
                </li>
                <li>
                  <Tick />
                  ZK fee proofs floored at on-chain IL - a forged proof cannot under-charge
                </li>
                <li>
                  <Tick />
                  Reserve credits gated to registered, token-validated sources
                </li>
                <li>
                  <Tick />
                  306 tests: unit, integration, fork, invariant, and scenario stress runs
                </li>
              </ul>
            </div>
          </div>
        </div>
      </section>

      {/* deployments: parchment tile */}
      <section className="tile-parchment" id="deployments">
        <div className="container">
          <h2 className="display-lg center" style={{ marginBottom: 10 }}>
            Deployed across four testnets.
          </h2>
          <p className="lead center" style={{ color: "var(--ink-muted-80)", maxWidth: 680, margin: "0 auto 32px" }}>
            The hook on Unichain Sepolia against the canonical v4 PoolManager, Reactive automation on Lasna, the
            Stylus engine on Arbitrum Sepolia, and the Across leg on Ethereum Sepolia.
          </p>

          <div className="center" style={{ marginBottom: 24 }}>
            <span className="chain-chip">
              <span className="cdot" />
              Unichain Sepolia &middot; core hook
            </span>
            <span className="chain-chip">
              <span className="cdot" />
              Arbitrum Sepolia &middot; Stylus ML engine
            </span>
            <span className="chain-chip">
              <span className="cdot" />
              Reactive Lasna &middot; automation RSCs
            </span>
            <span className="chain-chip">
              <span className="cdot" />
              Ethereum Sepolia &middot; Across + Chainlink + Brevis
            </span>
          </div>

          <div className="deploy-table">
            {DEPLOY_ROWS.map((r) => (
              <div className="deploy-row" key={r.label}>
                <span className="k">
                  {r.label}
                  <span className="deploy-chip">{r.chip}</span>
                </span>
                <span className="v">
                  <a href={explorerAddress(r.addr, r.chainId)} target="_blank" rel="noreferrer">
                    {r.addr}
                  </a>
                </span>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* CTA: dark tile, centered */}
      <section className="tile-dark-2 center">
        <div className="container">
          <h2 className="display-lg" style={{ marginBottom: 12 }}>
            Watch the waterfall run, live.
          </h2>
          <p className="lead-airy" style={{ color: "var(--body-muted-dark)", maxWidth: 560, margin: "0 auto 28px" }}>
            Coverage ratio, senior APY, junior buffer health, epoch funding, and the token-backed reserve - read
            straight from the hook.
          </p>
          <div className="stack-cta">
            <button className="btn-pill" onClick={onLaunch}>
              Launch the Dashboard
            </button>
            <button className="btn-pill-ghost" onClick={onDeposit}>
              Deposit
            </button>
          </div>
        </div>
      </section>

      {/* footer: parchment, four-column directory + legal */}
      <footer className="footer-apple">
        <div className="container">
          <div className="footer-grid">
            <div className="footer-brand">
              <span className="footer-brandline">
                <span className="logo-mark on-light" aria-hidden>
                  <span />
                  <span />
                  <span />
                </span>
                <span className="caption-strong">STRATUM</span>
              </span>
              <p className="caption muted footer-tag">
                Structured credit subordination as a Uniswap v4 hook. Senior LPs earn a smoothed,
                IL-protected coupon; junior LPs take first loss for leveraged fee upside.
              </p>
              <span className="footer-live">
                <span className="footer-dot" aria-hidden /> Live on 4 testnets · oracle-free core
              </span>
            </div>

            <nav className="footer-col" aria-label="Protocol">
              <span className="footer-head">Protocol</span>
              <button className="footer-link" onClick={onLaunch}>Dashboard</button>
              <button className="footer-link" onClick={onDeposit}>Deposit</button>
              <button className="footer-link" onClick={onLaunch}>Feature labs</button>
            </nav>

            <nav className="footer-col" aria-label="Live contracts">
              <span className="footer-head">Live contracts</span>
              <a className="footer-link mono" href={explorerAddress(STRATUM_ADDRESSES.hook, CHAIN_IDS.UNICHAIN_SEPOLIA)} target="_blank" rel="noreferrer">StratumHook ↗</a>
              <a className="footer-link mono" href={explorerAddress(STRATUM_ADDRESSES.lens, CHAIN_IDS.UNICHAIN_SEPOLIA)} target="_blank" rel="noreferrer">StratumLens ↗</a>
              <a className="footer-link mono" href={explorerAddress(STRATUM_ADDRESSES.zap, CHAIN_IDS.UNICHAIN_SEPOLIA)} target="_blank" rel="noreferrer">StratumZap ↗</a>
            </nav>

            <nav className="footer-col" aria-label="Cross-chain stack">
              <span className="footer-head">Cross-chain stack</span>
              <a className="footer-link" href={explorerAddress(STRATUM_LIVE_MULTICHAIN.stylusEngineArbitrum, CHAIN_IDS.ARBITRUM_SEPOLIA)} target="_blank" rel="noreferrer">Stylus engine · Arbitrum ↗</a>
              <a className="footer-link" href={explorerAddress(STRATUM_LIVE_MULTICHAIN.reactiveLasna.epochSettler, CHAIN_IDS.REACTIVE_LASNA)} target="_blank" rel="noreferrer">Reactive RSC · Lasna ↗</a>
              <a className="footer-link" href={explorerAddress(STRATUM_LIVE_MULTICHAIN.sepolia.cphr, CHAIN_IDS.ETHEREUM_SEPOLIA)} target="_blank" rel="noreferrer">Across + Chainlink · Sepolia ↗</a>
            </nav>
          </div>

          <div className="legal">
            <span>© 2026 STRATUM · Testnet demo, not an offer of securities.</span>
            <span className="footer-quip">No oracle was harmed in the core IL math.</span>
          </div>
        </div>
      </footer>
    </div>
  );
}
