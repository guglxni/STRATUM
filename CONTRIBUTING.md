# Contributing to STRATUM

Thank you for helping improve STRATUM. This project is a UHI9 hackathon build with a strict **core-first** rule: the hook must pass all tests with zero peripherals enabled.

## Before you open a PR

1. Read [docs/DESIGN.md](docs/DESIGN.md) and [CLAUDE.md](CLAUDE.md) golden rules.
2. Run `forge test` and `forge fmt`.
3. Run `./scripts/check-secrets.sh` — must pass before commit or push.
4. If you change architecture visuals, run `./scripts/render-diagrams.sh` and commit updated SVGs under `docs/diagrams/svg/`.
5. Never commit `.env`, `docs/AUDIT*.md`, `security/private/`, `broadcast/`, or agent session folders.

## Branch and commit style

- Branch names: `feat/…`, `fix/…`, `docs/…`
- Commits: imperative mood, one logical change per commit (e.g. `fix: sync senior obligation on TVL change`)

## Code standards

- Solidity **0.8.26**, Foundry, `via_ir` enabled in `foundry.toml`
- No oracle in core IL math
- New settlement paths need conservation tests
- Parameters only via `preparePool` / `beforeInitialize`, not hardcoded magic numbers

## Documentation

- Normative behavior → update `docs/DESIGN.md` and mirror in `files/DESIGN.md` if that tree is still the design baseline
- System structure → `docs/ARCHITECTURE.md` + diagrams in `docs/diagrams/`
- Regenerate codebase map: `graphify update src` (optional) and refresh `docs/CODEBASE_GRAPH.md` summary if structure changes materially

## CI

GitHub Actions runs `forge build`, `forge test`, and `forge fmt --check` on push and PR (see [.github/workflows/ci.yml](.github/workflows/ci.yml)).

## Questions

Open a GitHub issue with the label `question` or reference the relevant FR/INV id from [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md).
