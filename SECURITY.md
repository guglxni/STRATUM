# Security

STRATUM is **testnet / research software**, not audited for mainnet production. This file is the **public** security posture for the repository. Detailed findings and remediation notes are kept **out of git** (see below).

## Secret handling

| Rule | Implementation |
|------|----------------|
| No keys in repo | `.env` is gitignored; only `.env.example` with empty placeholders is tracked |
| No keys in scripts | `script/env-setup.sh` masks values; `EnvConfig.sol` reads `PRIVATE_KEY` from env at runtime only |
| No broadcast commits | `broadcast/` is gitignored (Foundry deploy artifacts) |
| API keys | `*_API_KEY`, `*_RPC` via environment variables only |

**If you cloned this repo:** copy `.env.example` → `.env` locally. Never commit `.env`. If a key was ever committed elsewhere, **rotate it** (new deployer wallet, revoke Blockscout API key).

## OWASP-aligned review (smart contract / ops)

Mapping [OWASP Top 10 (2021)](https://owasp.org/Top10/) to this codebase:

| OWASP | STRATUM relevance | Status |
|-------|-------------------|--------|
| A01 Broken access control | `preparePool` creator lock; position owner checks; `closeEpoch` time guard; junior exit coverage | Addressed in core (see tests) |
| A02 Cryptographic failures | No custom crypto; Ethereum signatures via Foundry broadcast | N/A / standard tooling |
| A03 Injection | `hookData` ABI decode; no SQL/shell | Bounded to `TrancheType` + `bytes32` salt |
| A04 Insecure design | Tranche waterfall, conservation checks, fee-per-share | Design in `docs/TECHNICAL_DESIGN.md`; testnet only |
| A05 Security misconfiguration | `.env` leakage, verify keys in CI | **Use `.env.example` only**; CI has no secrets |
| A06 Vulnerable components | `lib/v4-core`, `forge-std` (git submodules) | Pin submodules; run `forge build` / CI |
| A07 Identification & auth failures | LP = `msg.sender`; hook = `onlyPoolManager` | v4 callback model |
| A08 Software & data integrity | Settlement conservation check; epoch monotonicity | Invariant + integration tests |
| A09 Logging & monitoring | Events: `TrancheDeposited`, `EpochClosed`, `CoverageStress` | On-chain only |
| A10 SSRF | No HTTP from contracts | N/A |

### Solidity-specific (DeFi hook)

- Reentrancy: v4 `PoolManager` unlock pattern; no external calls in settlement hot path beyond tokens
- Oracle: **none** in core IL math (by design)
- Economic attacks: coverage ratio, junior reserve, senior IL cap — covered in requirements INV-01–INV-06

## What is NOT in this repository

The following are **gitignored** and must not be pushed:

- `docs/AUDIT.md`, `docs/AUDIT_GAPS.md`, `docs/AUDIT_FIXES.md`
- Entire `security/` directory (internal OWASP worksheets, scan exports)
- `.env`, `broadcast/`, agent session folders

Keep internal audits under `security/private/` locally (see `security/README.example`).

## Reporting vulnerabilities

Do **not** open public GitHub issues for exploitable vulnerabilities on testnet deployments. Contact the maintainers privately with: affected contract address, chain ID, reproduction steps, and impact.

## CI

GitHub Actions runs `forge build`, `forge test`, and `forge fmt --check` with **no** repository secrets required for the default workflow.
