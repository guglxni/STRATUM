# STRATUM Subgraph (D-7)

A [The Graph](https://thegraph.com) subgraph that indexes the STRATUM Uniswap v4 hook's on-chain event
stream into a queryable GraphQL API. Every STRATUM state transition is already emitted as an indexed event
(AGENTS.md convention), so this is a pure downstream observer: **it changes no contract behavior and requires
no contract change** — it is the deferred D-7 item from `docs/UNISWAP_ENHANCEMENTS.md`, now delivered.

## What it indexes

From `StratumHook`:

- **Pool** — running tranche balances, current epoch, junior reserve, swap count, accumulated fees, latest
  coverage ratio / stress level, and the D-1 protocol-fee realization flag + cumulative realized value.
- **Position** — every tranche position (by the hook's `keccak(sender, ticks, salt)` id): tranche, liquidity,
  open/closed, entry epoch, settlement payout + IL charged, migration count.
- **Epoch** — each closed epoch's senior funding, junior surplus, and junior reserve.
- **Swap** — per-swap fee accounting (fee, EWMA volatility, coverage ratio).
- **CoverageStressEvent** — coverage-stress signals crossing the notification threshold.
- **Migration** — in-place tranche migrations (FR-31).
- **ProtocolFeeRealizedEvent / ProtocolFeeCollection** — D-1 real-token protocol-fee realization and payouts.

From `TrancheIntentRegistry`:

- **Intent** — LP conditional tranche-migration intents (FR-30) with their ACTIVE / EXECUTED / CANCELLED status.

## Setup

ABIs are checked in under `abis/` (extracted from the Foundry build). Before deploying, set the deployed
addresses + deployment blocks for your target network in `networks.json` (or directly in `subgraph.yaml`).

```bash
cd subgraph
npm install
npm run codegen          # generate AssemblyScript types from schema + ABIs
npm run build            # compile the wasm mappings and validate the manifest
# deploy to a Graph node / Studio:
graph deploy --network unichain-sepolia <slug>
```

`graph codegen` writes the `generated/` directory (typed event + entity classes) that `src/*.ts` import;
it is intentionally not committed.

## Example queries

Pools with the most fee flow, and whether they realize protocol fees as real tokens:

```graphql
{
  pools(orderBy: feeAccumulated, orderDirection: desc, first: 10) {
    id
    currentEpoch
    seniorDeposited
    juniorDeposited
    juniorReserve
    lastCoverageRatioBps
    lastStressLevel
    protocolFeeRealization
    protocolFeeValueRealized
    swapCount
  }
}
```

Open senior positions in a pool, with live settlement outcomes once closed:

```graphql
{
  positions(where: { pool: "0x..", tranche: SENIOR, open: true }) {
    id
    owner
    liquidity
    entryEpoch
  }
}
```

Pending LP intents waiting on a coverage condition:

```graphql
{
  intents(where: { status: ACTIVE }) {
    id
    lp
    toTranche
    condition
    threshold
  }
}
```

## Refreshing the ABIs

If the hook's events change, re-extract the ABIs from the Foundry build:

```bash
forge build
jq '.abi' out/StratumHook.sol/StratumHook.json > subgraph/abis/StratumHook.json
jq '.abi' out/TrancheIntentRegistry.sol/TrancheIntentRegistry.json > subgraph/abis/TrancheIntentRegistry.json
```
