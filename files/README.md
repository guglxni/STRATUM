# STRATUM

The first Uniswap v4 hook to apply credit subordination to AMM liquidity. A liquidity position is split into a senior tranche (fixed yield, impermanent-loss protected) and a junior tranche (leveraged fees, absorbs impermanent loss first) through an on-chain priority waterfall. No external underwriter, no oracle, no borrowed capital needed for the core.

Built for the UHI9 Hookathon. Theme: Impermanent Loss and Yield Systems.

## Read in this order

1. `docs/PROPOSAL.md` - what STRATUM is and why it wins, in plain language.
2. `docs/PRD.md` - the product: problem, goals, users, success criteria.
3. `docs/ARCHITECTURE.md` - system structure, layers, integrations, the diagram.
4. `docs/DESIGN.md` - exact contract behavior, data structures, interfaces, math. Read before writing core code.
5. `docs/REQUIREMENTS.md` - testable requirements (FR), non-functional (NFR), invariants (INV).
6. `docs/PLAN.md` - phased build plan and sequencing rules.

## For coding agents

- `CLAUDE.md` - operating guide and golden rules. Read first.
- `AGENTS.md` - commands, conventions, hard guardrails.
- `.claude/skills/uniswap-v4-hook-dev/SKILL.md` - v4 hook mechanics and review checklist.

## The five UHI9 categories, one system

| Category | Mechanism |
|----------|-----------|
| IL Insurance | junior subordination and priority waterfall |
| Fixed Income | senior fixed APY, paid first |
| Delta-Neutral | senior delta offset by junior IL absorption |
| Fee-Smoothing | epoch accumulator with linear vesting |
| Cross-Pool Hedging | CPHR sharing junior reserves across pools and chains |

## Stack

Solidity core hook on Unichain. Reactive Network as the autonomic coordinator. Across for the Cross-Pool Hedging Router. Brevis for ZK-verified fee distribution. EigenLayer for supplementary senior yield and attestation. Arbitrum Stylus (Rust) for the gas-heavy matching engine and ML volatility model. Chainlink at the library level for benchmarked senior rates. Every peripheral is optional behind a common interface; the core builds and tests standalone.

## Golden rules

1. The core works with zero peripherals enabled.
2. No oracle in core IL math; IL comes from pool ticks only.
3. Any path that debits the junior buffer is reviewed against the coverage invariant.
4. Settlement is exact and conservation-checked.
5. No magic numbers; all parameters set at initialize.

## Build and test

```bash
forge install
cp .env.example .env
forge build
forge test
```

See `AGENTS.md` for the full command reference.

## Status

Design baseline complete. Build proceeds by the phases in `docs/PLAN.md`. Testnet only.
