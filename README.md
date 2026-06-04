# STRATUM

[![CI](https://github.com/guglxni/STRATUM/actions/workflows/ci.yml/badge.svg)](https://github.com/guglxni/STRATUM/actions/workflows/ci.yml)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.26-blue)](https://soliditylang.org/)
[![Foundry](https://img.shields.io/badge/Built%20with-Foundry-FFDB1C.svg)](https://book.getfoundry.sh/)
[![Uniswap v4](https://img.shields.io/badge/Uniswap-v4%20Hook-pink)](https://github.com/Uniswap/v4-core)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

The first **Uniswap v4 hook** that applies **credit subordination** to AMM liquidity. LPs choose a **senior** tranche (fixed yield, IL-protected) or a **junior** tranche (leveraged fees, absorbs IL first) via an on-chain **priority waterfall**. The core needs no oracle, no external underwriter, and no borrowed capital.

Built for the **UHI9 Hookathon** — theme: *Impermanent Loss and Yield Systems*.

<p align="center">
  <img src="docs/diagrams/svg/system-layers.svg" alt="STRATUM system layers" width="720"/>
</p>

## Why it matters

| Problem | STRATUM approach |
|---------|------------------|
| Single blended LP risk (fees − IL) | Two tranches: bond-like senior, equity-like junior |
| IL hits all LPs equally | Junior buffer + waterfall pay senior first |
| Yield volatility | Epoch accumulator + linear vesting |
| Keeper-heavy ops | Reactive Network coordinates epochs and stress (optional) |

## Documentation map

| Doc | Audience | Content |
|-----|----------|---------|
| [docs/PROPOSAL.md](docs/PROPOSAL.md) | Judges, investors | Pitch and differentiation |
| [docs/PRD.md](docs/PRD.md) | Product | Goals, users, success metrics |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Engineers | Layers, integrations, **diagrams** |
| [docs/DESIGN.md](docs/DESIGN.md) | Solidity devs | Contracts, structs, hook callbacks |
| [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md) | QA | FR, NFR, INV IDs |
| [docs/PLAN.md](docs/PLAN.md) | Build | Phased delivery |
| [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) | DevOps | Unichain Sepolia, verify, `.env` |
| [docs/CODEBASE_GRAPH.md](docs/CODEBASE_GRAPH.md) | Onboarding | graphify map of `src/` |
| [SECURITY.md](SECURITY.md) | Security | Public posture & secret policy (no internal audit in git) |
| [docs/diagrams/README.md](docs/diagrams/README.md) | Contributors | Mermaid + draw.io tooling |

**Agents:** read [CLAUDE.md](CLAUDE.md) and [AGENTS.md](AGENTS.md) first.

## UHI9 categories (one system)

| Category | STRATUM mechanism |
|----------|-----------------|
| IL Insurance | Junior subordination + priority waterfall |
| Fixed Income | Senior fixed APY, funded first each epoch |
| Delta-Neutral | Senior delta offset by junior IL absorption |
| Fee-Smoothing | Epoch accumulator + vesting |
| Cross-Pool Hedging | CPHR (Across + Stylus; planned) |

## Repository layout

```
src/
  StratumHook.sol          # Core v4 hook
  TrancheToken.sol         # stLP / jtLP receipts
  libraries/               # ILMath, Waterfall, CoverageRatio, EpochAccounting
  peripherals/reactive/    # EpochSettler, CoverageMonitor (stubs)
test/                      # unit, integration, invariant, scenario, fork
docs/                      # Product + architecture + diagrams
scripts/                   # Deploy, verify, render-diagrams, env-setup
```

## Quick start

```bash
git clone https://github.com/guglxni/STRATUM.git && cd STRATUM
git submodule update --init --recursive
forge install foundry-rs/forge-std --no-commit  # if forge-std missing locally
cp .env.example .env   # never commit .env
forge build
forge test
```

### Diagrams

**13 Mermaid** + **4 draw.io** sources → **17 PNG** + **17 SVG** (committed under `docs/diagrams/`).

```bash
brew install --cask drawio    # desktop app + headless export CLI
./scripts/render-diagrams.sh  # uses: npx -y @mermaid-js/mermaid-cli mmdc
```

Single-file example:

```bash
npx -p @mermaid-js/mermaid-cli mmdc \
  -i docs/diagrams/mermaid/system-layers.mmd \
  -o docs/diagrams/png/system-layers.png -b white --scale 2
```

See [docs/diagrams/README.md](docs/diagrams/README.md) for the full catalog (coverage, epochs, settlement, invariants, deploy).

## Status

| Phase | State |
|-------|--------|
| 0–1 Core hook + libraries | Done — 30 Foundry tests |
| 2 Testnet deploy | Script ready — Unichain Sepolia (see [DEPLOYMENT](docs/DEPLOYMENT.md)) |
| 3+ Reactive, CPHR, Brevis, Stylus | Specified in architecture; stubs only |

Post-audit remediations are merged in `src/StratumHook.sol` (payout delta, fee-per-share, epoch guards). **Redeploy** required after hook flag changes.

## Security

See [SECURITY.md](SECURITY.md). Internal audit reports (`docs/AUDIT*.md`, `security/private/`) are **gitignored** — keep them local only. Before any commit: `./scripts/check-secrets.sh`. Testnet only — not production-ready.

## License

MIT — see [LICENSE](LICENSE).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).
