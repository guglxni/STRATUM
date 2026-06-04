# CLAUDE.md

Operating guide for Claude Code (and other agents) working in the STRATUM repo. Read this first, then read `AGENTS.md` for the command and convention contract, then `docs/DESIGN.md` before writing any contract code.

## What STRATUM is, in one paragraph

STRATUM is a Uniswap v4 hook that applies credit subordination to AMM liquidity. Liquidity providers choose one of two tranches. Senior LPs (token `stLP`) receive a fixed, smoothed yield and are protected from impermanent loss. Junior LPs (token `jtLP`) absorb impermanent loss first, in exchange for leveraged exposure to swap fees. Fees flow through a priority waterfall: senior obligations are paid first, junior takes the surplus. On withdrawal, impermanent loss is charged to the junior buffer before it ever touches senior principal. The system needs no oracle, no external underwriter, and no borrowed capital to function at its core. Peripheral modules (cross-chain reserves, ZK fee accounting, supplementary yield, gas-optimized matching) are coordinated by Reactive Network.

For the full picture read `docs/ARCHITECTURE.md`. For why it exists read `docs/PRD.md`. For exact contract behavior read `docs/DESIGN.md`.

## Golden rules for this repo

1. The core hook must compile and pass tests with zero peripheral integrations enabled. Integrations are optional modules behind interfaces, never hard dependencies. If a change to a peripheral breaks the core, the change is wrong.
2. Never introduce an oracle, price feed, or external data source into the core tranche math. Impermanent loss is computed from pool tick deltas only. Benchmarked yield (Chainlink) is an optional input to the senior target rate, never to the IL accounting.
3. The junior buffer is the only thing standing between a volatile market and senior principal. Any code path that can reduce the junior buffer must be reviewed against the coverage ratio invariant before merge.
4. Settlement math must be exact and conservation-checked. Total tokens out never exceed total tokens in plus accrued fees. Write a test that asserts conservation for every settlement path.
5. No magic numbers in contract logic. Every parameter (target APY, coverage floor, epoch length, IL cap) is set at `beforeInitialize` and stored in `PoolTrancheState`.

## Language boundaries (do not fight these)

- Uniswap v4 hooks run on the EVM. The core hook, the Reactive Smart Contracts, and all on-chain integration shims are Solidity. There is no Rust path for the hook itself. Do not attempt it.
- Rust is used only where it is the correct tool: the Arbitrum Stylus matching engine and ML volatility model, the EigenLayer operator software, and Brevis prover-side tooling.
- TypeScript for the demo frontend and scripts.
- Foundry (Solidity tests, Rust-based tooling) for the test suite.

See `docs/ARCHITECTURE.md` "Language and execution boundaries" for the full table.

## Repo layout (target)

```
src/
  StratumHook.sol            core hook, tranche logic, waterfall, settlement
  TrancheToken.sol           stLP and jtLP ERC-20 receipt tokens
  libraries/
    ILMath.sol               impermanent loss from tick deltas
    Waterfall.sol            senior-first fee distribution
    CoverageRatio.sol        junior/senior floor enforcement
    EpochAccounting.sol      epoch accumulator and smoothing
  interfaces/
    IStratumHook.sol
    IPeripheral.sol          common interface for optional modules
  peripherals/
    reactive/                EpochSettler, CoverageMonitor, ReserveBalancer
    across/                  CrossPoolHedgingRouter
    brevis/                  fee-distribution proof verifier shim
    eigenlayer/              LVR auction proceeds receiver, AVS attestation shim
    stylus/                  Solidity shim that calls the Stylus matcher
stylus/                      Rust: matching engine + ML volatility model
operator/                    Rust: EigenLayer AVS operator node
test/                        Foundry tests, fork tests, invariant tests
script/                      deployment and demo scripts
frontend/                    TypeScript demo UI
docs/                        design docs (read these)
```

## Build, test, run

All commands and their exact invocation live in `AGENTS.md`. The short version: `forge build`, `forge test`, `forge test --match-path` for a single suite, `forge test --fork-url $UNICHAIN_SEPOLIA_RPC` for fork tests. Never commit a change that leaves `forge test` red.

## Where to start when given a task

- Touching tranche logic, fees, or settlement? Read `docs/DESIGN.md` sections on the waterfall, IL math, and settlement first. These define exact behavior and the invariants your change must preserve.
- Adding or changing a peripheral? Read the `IPeripheral` interface and the relevant section of `docs/ARCHITECTURE.md`. Keep the core unaware of the peripheral's internals.
- Writing tests? Read `docs/REQUIREMENTS.md`. Every functional requirement has an ID (FR-x) and should map to at least one test.
- Unsure about scope or sequencing? Read `docs/PLAN.md` for the phase you are in.

## House style

- Prose and comments avoid em dashes. Use hyphens, colons, or parentheses.
- Comments explain why, not what. The code already says what.
- NatSpec on every external and public function: `@notice`, `@param`, `@return`, and `@dev` for invariants.
- Name things after their financial meaning (`seniorObligation`, `juniorSurplus`, `coverageRatioBps`), not after implementation detail.
- Prefer small, pure libraries for math so they can be tested in isolation and reused by Stylus where relevant.

## Honesty contract

When something will not work, say so plainly and propose the correct path. Do not paper over a failing test, a broken invariant, or an integration that cannot be demonstrated. A smaller surface executed correctly beats a larger surface that looks impressive and breaks in the demo. If a requested change conflicts with a golden rule above, flag the conflict before implementing.

## Installed agent skills

Local skills from [solidity-agent-kit](https://github.com/0xlayerghost/solidity-agent-kit), [pashov/skills](https://github.com/pashov/skills), and [quillshield_skills](https://github.com/quillai-network/quillshield_skills) live under `.agents/skills/`.

Before changing `.sol` files: apply solidity-coding and solidity-security. Before tests: solidity-testing. Before `--broadcast`: solidity-checklist. After major phases: pashov x-ray and solidity-auditor; quillshield state-invariant-detection and oracle-flashloan-analysis (confirm no oracle in core IL paths).

Phased delivery follows `docs/AIDLC.md` and [aidlc-workflows](https://github.com/awslabs/aidlc-workflows).
