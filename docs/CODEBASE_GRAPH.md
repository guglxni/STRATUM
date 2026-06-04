# STRATUM codebase graph (graphify)

Auto-generated structural map of `src/` from [graphify](https://pypi.org/project/graphifyy/). Regenerate locally:

```bash
graphify update src   # after initial /graphify run in repo root
# Interactive HTML: graphify-out/graph.html (gitignored; not required for GitHub)
```

Use this document to onboard quickly: **god nodes** are the concepts to read first; **communities** are feature clusters; **hyperedges** are multi-step flows.

---

# Graph Report - src  (2026-06-04)

## Corpus Check
- 13 files · ~1,707 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 38 nodes · 53 edges · 8 communities detected
- Extraction: 91% EXTRACTED · 9% INFERRED · 0% AMBIGUOUS · INFERRED: 5 edges (avg confidence: 0.69)

## Community Hubs (Navigation)
- **Coverage & Epoch Coordination** — `closeEpoch`, `EpochSettler`, `CoverageMonitor`, fee-per-share
- **Withdrawal Settlement (IL + payout)** — `afterRemoveLiquidity`, `_settleSenior`, `_settleJunior`
- **Hook Lifecycle & Init** — `preparePool`, `beforeInitialize`, `TrancheToken`
- **Deposit & Dynamic Fee** — `afterAddLiquidity`, `beforeSwap`, `CoverageRatio`
- **Vesting & Remove Prep** — `_accrueVesting`, `beforeRemoveLiquidity`
- **Swap Fee Waterfall** — `afterSwap`, `Waterfall.splitFee`

## God Nodes (read these first)
1. `StratumHook` — central hook (14 edges)
2. `TranchePosition` — per-LP state
3. `afterRemoveLiquidity` — settlement + payout delta
4. `PoolTrancheState` — pool-level accounting
5. `closeEpoch` — epoch boundary + fee-per-share

## Hyperedges (multi-step flows)
- **Withdrawal settlement** — `afterRemoveLiquidity` → `_settleSenior` / `_settleJunior` → `_conservationCheck` → `ILMath.ilForRange`
- **Fee waterfall + epoch** — `afterSwap` → `Waterfall.splitFee` → `closeEpoch` → `EpochAccounting.epochSurplus`
- **Core math libraries** — `ILMath`, `Waterfall`, `CoverageRatio`, `EpochAccounting`

## Reading order from the graph
1. `src/StratumTypes.sol` — structs
2. `src/libraries/*.sol` — pure math
3. `src/StratumHook.sol` — callbacks (match `docs/diagrams/mermaid/hook-lifecycle.mmd`)
4. `src/peripherals/reactive/*.sol` — optional stubs

See also `docs/DESIGN.md` for normative behavior and `SECURITY.md` for the public security policy (internal audits are gitignored).
