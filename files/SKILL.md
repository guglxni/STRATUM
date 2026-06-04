---
name: uniswap-v4-hook-dev
description: Build, review, and test Uniswap v4 hooks for the STRATUM repo. Use whenever writing or changing hook contracts, hook callbacks (beforeInitialize, before/afterAddLiquidity, before/afterSwap, before/afterRemoveLiquidity), hook permission flags and CREATE2 address mining, dynamic fees, return-delta logic, PoolManager unlock/settle flows, or Foundry tests for hooks. Encodes v4-specific gotchas that are easy to get wrong and that generic Solidity knowledge does not cover.
---

# Uniswap v4 Hook Development (STRATUM)

Reference for building hooks correctly in this repo. Pair with `docs/DESIGN.md` for STRATUM-specific behavior. This skill covers v4 mechanics that are non-obvious and frequently gotten wrong.

## Hook permission flags and address mining

A v4 hook's permissions are encoded in its address. The low bits of the deployed address declare which callbacks the PoolManager will invoke. Getting this wrong means callbacks silently never fire.

- Declare permissions in `getHookPermissions()` returning a `Hooks.Permissions` struct.
- The deployed address must have the matching flag bits set. Mine a CREATE2 salt so the address carries the right bits. Use `HookMiner.find(...)` from v4-periphery in the deploy script.
- STRATUM needs: beforeInitialize, afterAddLiquidity, beforeSwap (with dynamic fee), afterSwap, beforeRemoveLiquidity, afterRemoveLiquidity. It also needs the `beforeSwapReturnDelta` flag only if it modifies swap amounts (STRATUM does not by default; confirm before enabling).
- Mismatch between declared permissions and address bits reverts on `initialize`. If a callback is not firing, check the address bits first.

## Dynamic fees

- To set fees per swap, initialize the pool with the dynamic-fee sentinel (`LPFeeLibrary.DYNAMIC_FEE_FLAG`) as the fee, and enable the beforeSwap flag.
- Return the fee from `beforeSwap` via the override mechanism (the returned fee with the override bit set), not by trying to mutate pool state directly.
- Clamp every dynamic fee to the configured min and max bps. Never return an unbounded value derived from volatility.

## unlock / settle / take accounting

- All token movement in v4 goes through the PoolManager's unlock callback and the settle/take pattern. Balances are tracked as deltas that must net to zero by the end of the unlock.
- When the hook moves tokens (minting tranche value, paying settlement, topping up reserves), account every delta. A non-zero net delta at unlock end reverts with `CurrencyNotSettled`.
- Use `currency.settle(...)` and `currency.take(...)` helpers consistently. Do not mix raw transfers with the delta accounting.

## Return deltas (BeforeSwapDelta / hook deltas)

- If a callback returns a delta, the corresponding return-delta permission flag must be set in the address, or the return is ignored.
- STRATUM's fee splitting operates on fees already accrued, not by returning swap deltas, so keep return-delta flags off unless a feature genuinely needs them. Adding a return-delta path changes the accounting surface and the invariants; review against INV-03 (conservation) before doing it.

## afterAddLiquidity / afterRemoveLiquidity specifics

- These receive the `BalanceDelta` of the liquidity change. Use it for value accounting; do not recompute amounts from scratch if the delta already gives them.
- Liquidity callbacks run inside the modifyLiquidity flow, which is itself inside an unlock. Any token movement the hook does here participates in the same delta accounting.
- STRATUM enforces the coverage ratio in afterAddLiquidity and reverts if a senior deposit would breach the floor. Reverting here cleanly rolls back the liquidity add.

## Tick and price math

- Prices are `sqrtPriceX96` (Q64.96). Convert carefully; never use floating point.
- For IL and position value, derive token amounts from liquidity and the tick range using LiquidityAmounts-style helpers, bounded to [tickLower, tickUpper].
- STRATUM computes IL from entry and exit `sqrtPriceX96` only. No external price. See `ILMath` in `docs/DESIGN.md` section 4.

## Common mistakes to check in review

1. Address bits do not match declared permissions (callbacks never fire).
2. Forgetting the dynamic-fee sentinel at initialize, so the dynamic fee override is ignored.
3. Net non-zero delta at unlock end (CurrencyNotSettled).
4. Returning a delta without the matching return-delta flag set.
5. Reading an external price into core IL math (forbidden by STRATUM's golden rules).
6. Mutating storage during a view-style callback path.
7. Using revert strings instead of custom errors.
8. Math in percentages or raw integers instead of bps with the Bps suffix.

## Testing hooks with Foundry

- Use the v4 test helpers (Deployers) to spin up a PoolManager, deploy the hook at a mined address, and create a pool.
- For the hook address, either mine a salt in the test or use the test deployer's `deployCodeTo` to place the hook at an address with the correct flag bits.
- Test each callback in isolation, then the full lifecycle, then invariants.
- Fork tests: run against Unichain Sepolia with `--fork-url`. See `AGENTS.md` for commands.
- For STRATUM, the required test set is in `docs/DESIGN.md` section 14 and `docs/REQUIREMENTS.md` traceability.

## Review checklist before merging a hook change

- getHookPermissions matches the intended callbacks, and the deploy script mines an address with those bits.
- Dynamic fee path returns a clamped, override-flagged fee.
- All token movement nets to zero within unlock; settle/take used consistently.
- No external price in core IL math.
- Custom errors, full NatSpec with `@dev` invariants, no em dashes.
- New or changed behavior has tests, and the relevant invariants still pass.
- Core-only CI profile still green if the change touches anything outside `peripherals/`.
