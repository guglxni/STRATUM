# AGENTS.md

Machine-facing contract for any coding agent working in this repo. `CLAUDE.md` holds workflow and reasoning guidance; this file holds the concrete commands, conventions, and guardrails. When the two appear to conflict, the golden rules in `CLAUDE.md` win.

## Project

STRATUM: a Uniswap v4 hook implementing senior/junior credit tranching for AMM liquidity. Core is Solidity on the EVM (deployed to Unichain). Optional peripheral modules in Solidity and Rust, coordinated by Reactive Network. See `docs/ARCHITECTURE.md`.

## Toolchain

- Solidity: `^0.8.26`, Foundry (forge, cast, anvil).
- Uniswap v4: `v4-core` and `v4-periphery` as git submodules under `lib/`.
- Rust: stable toolchain, `cargo`, plus the Stylus SDK for the matching engine and the EigenLayer operator node.
- Node: `>=20` for the TypeScript frontend and scripts.

## Setup

```bash
forge install                      # pull v4-core, v4-periphery, solmate, forge-std
cp .env.example .env               # fill RPC URLs and keys (never commit .env)
forge build                        # compile all Solidity
```

Rust components are built per directory:

```bash
cd stylus && cargo build --release        # matching engine + ML model (WASM target for deploy)
cd operator && cargo build --release      # EigenLayer AVS operator node
```

## Commands

| Task | Command |
|------|---------|
| Compile | `forge build` |
| Full test suite | `forge test` |
| Verbose failing test | `forge test -vvvv --match-test <name>` |
| Single file | `forge test --match-path test/<File>.t.sol` |
| Invariant tests only | `forge test --match-path "test/invariant/*"` |
| Fork test (Unichain Sepolia) | `forge test --fork-url $UNICHAIN_SEPOLIA_RPC --match-path "test/fork/*"` |
| Gas report | `forge test --gas-report` |
| Coverage | `forge coverage` |
| Format | `forge fmt` |
| Static lint | `slither .` (if installed) |
| Deploy core to testnet | `forge script script/DeployStratum.s.sol --rpc-url $UNICHAIN_SEPOLIA_RPC --broadcast` |
| Stylus build | `cd stylus && cargo stylus check` |
| Frontend dev | `cd frontend && npm install && npm run dev` |

Do not leave `forge test` red on any commit. Run `forge fmt` before committing.

## Conventions

- File names match the primary contract or library they contain.
- One core concern per library: IL math, waterfall, coverage ratio, epoch accounting are separate and individually tested.
- External and public functions carry full NatSpec including a `@dev` line stating any invariant the function preserves.
- Custom errors, not revert strings. Name them after the violated condition (`CoverageRatioBelowFloor`, `EpochNotElapsed`).
- Events for every state transition that a Reactive Smart Contract or the frontend needs to observe. Index the fields that listeners filter on (poolId, positionId, epoch).
- Basis points (`uint16` or `uint256` as `Bps`) for all rates and ratios. Never floats, never percentages as raw integers without the `Bps` suffix.
- No em dashes in comments or docs. Hyphens, colons, or parentheses instead.

## Hard guardrails

1. The core hook (`src/StratumHook.sol` plus `src/libraries/*`) must build and pass tests with every peripheral disabled. CI runs a `core-only` profile that compiles without the `peripherals/` directory.
2. No oracle or external price source in core IL math. IL is derived from pool ticks only.
3. Any code path that debits the junior buffer must be covered by an invariant test asserting the coverage ratio floor and the senior-protection guarantee.
4. Every settlement path has a conservation test: tokens out <= tokens in + accrued fees, no dust leakage beyond a defined rounding tolerance.
5. Peripheral modules implement `IPeripheral` and are reachable from the core only through that interface. The core never imports a concrete peripheral.

## Test expectations

- Unit tests for each library in isolation.
- Integration tests for the hook against a mock PoolManager and against forked Unichain Sepolia.
- Invariant tests for: coverage ratio floor, senior protection, conservation, monotonic epoch accounting.
- A scenario test that simulates a sharp price move and asserts senior is made whole while junior absorbs the loss. This scenario doubles as the demo script. See `docs/REQUIREMENTS.md` FR-09 and the stress scenario in `docs/PLAN.md`.

## Secrets and safety

- Never commit `.env`, private keys, or RPC URLs with embedded keys.
- Testnet only for all scripts in this repo. No mainnet deploy targets.
- If a tool call needs network access that is blocked, report it rather than working around it.
