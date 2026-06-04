# STRATUM Technical Design

Authoritative for contract behavior, data structures, interfaces, and the math. Read this before writing or changing core code. Requirement IDs (FR/INV) refer to `REQUIREMENTS.md`.

## 1. Data structures

```solidity
enum TrancheType { SENIOR, JUNIOR }

struct TranchePosition {
    TrancheType tranche;
    address owner;
    uint160 entrySqrtPriceX96;     // price at deposit, for IL math
    int24 tickLower;
    int24 tickUpper;
    uint128 liquidity;
    uint256 cumulativeILAbsorbed;  // junior: IL charged to this position
    uint256 accruedFixedYield;     // senior: yield accrued, pre-vesting
    uint256 excessFeesEarned;      // junior: surplus fees earned, pre-vesting
    uint64  entryEpoch;
    uint64  lastSettledEpoch;
    uint256 vestedClaimable;       // amount released by smoothing, paid at withdrawal
    uint256 principalValue;        // deposit value in token0 numeraire
    uint256 entryTimestamp;        // holding period for senior fixed yield
    uint256 feePerShareCheckpointX128; // cumulative fee-per-share at deposit
}

struct PoolTrancheState {
    uint256 seniorTVL;
    uint256 juniorTVL;
    uint256 juniorReserve;         // buffer that absorbs IL and senior shortfall
    uint256 targetAPYBps;          // senior fixed APY target (or benchmark+spread)
    uint16  minCoverageRatioBps;   // junior/senior floor, e.g. 3000 = 30%
    uint16  maxSeniorILExposureBps;// cap on senior IL after buffer depletion
    uint32  smoothingEpochSeconds; // epoch length
    uint64  currentEpoch;
    uint256 epochAccumulatedFees;
    uint256 epochSeniorObligation; // computed at epoch open
    uint256 epochSeniorFunded;     // senior obligation funded this epoch
    uint256 volatilityEWMA;        // trailing volatility estimate
    uint256 epochStartTimestamp;   // epoch boundary for closeEpoch / vesting
    uint256 seniorFeePerShareX128; // cumulative senior yield per unit TVL
    uint256 juniorFeePerShareX128; // cumulative junior surplus per unit TVL
    uint16  baseFeeBps;
    uint16  minFeeBps;
    uint16  maxFeeBps;
    address peripheralRegistry;    // 0 if running core-only
}
```

Storage keying: positions keyed by `bytes32 positionId = keccak256(owner, tickLower, tickUpper, salt)`. Pool state keyed by `PoolId`.

## 2. Core interfaces

```solidity
interface IStratumHook {
    function depositTranche(PoolKey calldata key, TrancheType t, uint128 liquidity, int24 lo, int24 hi)
        external returns (bytes32 positionId);
    function withdrawTranche(PoolKey calldata key, bytes32 positionId)
        external returns (uint256 amount0, uint256 amount1);
    function claimVested(bytes32 positionId) external returns (uint256 claimed);
    function poolState(PoolId id) external view returns (PoolTrancheState memory);
    function position(bytes32 positionId) external view returns (TranchePosition memory);
}

// Common interface every optional module implements. Core only knows this type.
interface IPeripheral {
    function kind() external view returns (bytes32);   // "BREVIS","ACROSS","EIGEN","STYLUS","REACTIVE"
    function onEpochClose(PoolId id, uint64 epoch, bytes calldata ctx) external returns (bytes memory);
    function onCoverageStress(PoolId id, uint16 ratioBps) external;
    function isEnabled() external view returns (bool);
}
```

The core calls peripherals only through `IPeripheral`. If `peripheralRegistry == address(0)`, the core skips all peripheral calls and uses on-chain fallbacks (FR-22, NFR-01).

## 3. Hook callback behavior

### beforeInitialize
Validate and store `PoolTrancheState` from init params. Require `minFeeBps <= baseFeeBps <= maxFeeBps`, `minCoverageRatioBps > 0`, `maxSeniorILExposureBps <= 10000`. Open epoch 0 and compute its senior obligation.

### afterAddLiquidity (FR-01, FR-02, FR-11, INV-01)
1. Compute deposit value at current price.
2. If SENIOR: compute the prospective coverage ratio = juniorTVL / (seniorTVL + depositValue). If below floor, attempt a CPHR top-up (if Across enabled); if still below floor, revert `CoverageRatioBelowFloor`.
3. Write `TranchePosition`, snapshot `entrySqrtPriceX96`, set `entryEpoch` and `lastSettledEpoch` to current epoch.
4. Update `seniorTVL` or `juniorTVL`.
5. Mint `stLP` or `jtLP`.
6. Emit `TrancheDeposited`.

### beforeSwap (FR-04)
Return dynamic fee = clamp(baseFeeBps adjusted by volatilityEWMA and coverage stress, minFeeBps, maxFeeBps). When Stylus is enabled, the ML model may supply a forward volatility estimate that replaces the EWMA term; otherwise use the on-chain EWMA.

### afterSwap (FR-05, FR-07, FR-08, FR-26)
1. Read fee amount for this swap.
2. Split into seniorPortion, juniorPortion, protocolPortion using current dynamic ratios (see section 5).
3. Add to `epochAccumulatedFees`; record seniorPortion toward `epochSeniorObligation` funding.
4. Update `volatilityEWMA` from the price move.
5. Update `cumulativeILAbsorbed` accounting at the pool level from the tick delta (see section 4); per-position attribution finalizes at settlement.
6. Emit `SwapAccounted(poolId, epoch, feeAmount, volatilityEWMA)`.

### beforeRemoveLiquidity (FR-21)
If `position.lastSettledEpoch < currentEpoch` and Brevis enabled, request a time-weighted proof for the position's holding window; store the proof handle for `afterRemoveLiquidity`. If Brevis disabled, mark for on-chain approximate accounting.

### afterRemoveLiquidity (FR-03, FR-06, FR-09, FR-10, INV-02, INV-03, INV-04)
Settle per section 6. Burn receipt, transfer outputs, update TVL and buffer, emit `TrancheSettled`.

## 4. Impermanent loss math (ILMath library)

IL is computed from price movement only, using the standard concentrated-liquidity value function. For a position with liquidity L over [tickLower, tickUpper], position value at price P is the value of the token amounts the position holds at P. IL is the difference between the value of the LP position at the exit price and the value of simply having held the entry token amounts:

```
held(P)      = amount0_entry * P + amount1_entry          // value if just held
lpValue(P)   = value of (amount0(P), amount1(P)) at price P // value inside the AMM
IL(P)        = held(P) - lpValue(P)                         // >= 0 for divergence
```

Implementation notes:
- Work in Q64.96 fixed point consistent with v4's `sqrtPriceX96`. Derive token amounts from `LiquidityAmounts` style helpers bounded to the position's tick range.
- Accumulate IL incrementally per swap at the pool level (cheap), and finalize exact per-position IL at settlement using entry and exit `sqrtPriceX96` (precise). The incremental accumulator drives the dynamic fee and the buffer; the settlement computation is the source of truth for charging.
- Never read an external price. Tick and `sqrtPriceX96` from the pool are the only inputs (INV: no oracle in core).

Provide pure functions so the same logic can be mirrored in the Stylus matcher:
```solidity
function ilForRange(uint160 entrySqrtP, uint160 exitSqrtP, int24 lo, int24 hi, uint128 L)
    internal pure returns (uint256 ilToken0);
```

## 5. Fee split and dynamic fee (Waterfall library)

Split ratios are functions of volatility and buffer health, bounded:
```
seniorBps + juniorBps + protocolBps = 10000
high volatility or low buffer  -> shift weight toward buffer (raise the portion that funds juniorReserve and the senior obligation coverage)
low volatility and healthy buffer -> shift weight toward juniorSurplus (junior upside) and competitive swap fee
```
The dynamic swap fee and the split are linked: in stress, raise the swap fee (more revenue) and direct more of it to rebuilding the buffer; in calm, lower the swap fee to stay competitive and let junior capture upside. Keep the mapping monotonic and documented as a pure function `splitFor(volatilityEWMA, coverageRatioBps)`.

## 6. Settlement (the heart of the system)

At settlement for a position, compute over its holding window [entryEpoch .. currentEpoch]:

Senior:
```
fixedYield   = seniorPrincipal * targetAPYBps/10000 * holdingTime / year
ilOnPosition = ilForRange(entry, exit, lo, hi, L)
if juniorReserve >= ilOnPosition:
    juniorReserve -= ilOnPosition          // buffer absorbs it (INV-02 satisfied)
    seniorPayout = seniorPrincipal + min(fixedYield, vestedPortion)
else:
    shortfall = ilOnPosition - juniorReserve
    juniorReserve = 0
    seniorILCharge = min(shortfall, seniorPrincipal * maxSeniorILExposureBps/10000)
    seniorPayout = seniorPrincipal - seniorILCharge + min(fixedYield, vestedPortion)
```

Junior:
```
ilShare      = junior position's attributed IL over the window (Brevis-proven or approximated)
feeShare     = junior position's time-weighted share of epoch surpluses (Brevis-proven or approximated)
juniorPayout = juniorPrincipal + feeShare - ilShare      // bounded below by 0 for this position's capital
```

Conservation check (INV-03): assert sum of payouts <= sum of principals + accrued fees within rounding tolerance before transferring. Revert `ConservationViolation` otherwise.

Vesting (FR-07, FR-14): only the vested portion of fees is paid on a normal claim; early exit forfeits unvested fees, which are credited to `juniorReserve` (INV-05).

## 7. Coverage ratio control (CoverageRatio library)

```
ratioBps = juniorTVL * 10000 / seniorTVL          // guard seniorTVL == 0
enforceOnSeniorIntake(depositValue):
    prospective = juniorTVL * 10000 / (seniorTVL + depositValue)
    if prospective < minCoverageRatioBps: attempt CPHR top-up, else revert
stressLevel(ratioBps): returns a 0..10000 stress scalar used by splitFor and the dynamic fee
```

## 8. Epoch accounting (EpochAccounting library)

- `openEpoch`: set `epochSeniorObligation = seniorTVL * targetAPYBps/10000 * epochSeconds / year`, reset `epochAccumulatedFees`.
- `accrue(fee)`: add to accumulator, track senior funding progress.
- `closeEpoch`: compute surplus = max(0, accumulated - seniorObligation); senior obligation funded from accumulator first (INV-04); shortfall (if accumulated < obligation) drawn from `juniorReserve`; surplus assigned to junior; advance `currentEpoch` (INV-06); reopen.
- Smoothing: vested fraction = elapsed / epochSeconds, linear. `vestedClaimable` updates on claim.

## 9. Reactive Smart Contracts (peripherals/reactive)

- EpochSettler: subscribes to block timestamps / epoch markers; calls `closeEpoch` then `openEpoch` at boundaries (FR-15).
- CoverageMonitor: subscribes to `TrancheDeposited` and `TrancheSettled`; when aggregate ratio nears floor, calls `onCoverageStress` (FR-16).
- ReserveBalancer: subscribes to junior reserve balance events across chains; triggers CPHR rebalance when divergence > threshold (FR-17).
- Cross-component routing: on `SwapAccounted` of sufficient magnitude, trigger the Stylus matcher; at `closeEpoch`, request Brevis proofs; when an LVR auction is due, request EigenLayer attestation.

## 10. CPHR (peripherals/across) and Stylus matcher

- `CorrelationRegistry`: maps poolId pairs to correlation weight bps (FR-20).
- `CrossPoolHedgingRouter`: exposes `topUp(targetPool, amount)` (same-chain aggregation FR-18), `bridgeReserve(targetChain, targetPool, amount)` via Across (FR-19), and `netExposures(...)` driven by the matcher's output.
- Stylus engine (Rust): inputs are pool states and the correlation registry; outputs are recommended top-ups, bridges, and netting sets. The Solidity shim in `peripherals/stylus` submits inputs (triggered by Reactive) and applies outputs after EigenLayer attestation.

## 11. Brevis (peripherals/brevis)

- Circuit `TimeWeightedContribution`: proves a position's time-weighted share of epoch surpluses (FR-21).
- Circuit `ILAttribution`: proves a position's IL over its window.
- Circuit `AggregateReserveProof`: proves cross-chain junior reserve solvency without revealing positions.
- Solidity verifier shim validates the proof at settlement; on failure or when disabled, fall back to on-chain approximation (FR-22, INV: core independent).

## 12. EigenLayer (peripherals/eigenlayer + operator)

- On-chain: `LVRAuctionReceiver` routes auction proceeds to the senior obligation (FR-23); `MatchAttestation` records operator attestations consumed by the CPHR (FR-24).
- Off-chain: Rust operator node runs the auction and signs attestations. Start from the Hello World / Incredible Squaring AVS templates.

## 13. Errors (custom, named for the violated condition)

`CoverageRatioBelowFloor`, `EpochNotElapsed`, `ConservationViolation`, `NotPositionOwner`, `TrancheMismatch`, `PeripheralDisabled`, `ProofInvalid`, `FeeBoundsInvalid`.

## 14. Testing map

- `test/unit/ILMath.t.sol`: IL function correctness against known cases (FR-08).
- `test/unit/Waterfall.t.sol`: split monotonicity and bounds (FR-05).
- `test/unit/CoverageRatio.t.sol`: floor enforcement edges (FR-11).
- `test/unit/EpochAccounting.t.sol`: accrual, smoothing, surplus (FR-07, FR-13).
- `test/integration/StratumHook.t.sol`: full lifecycle on mock PoolManager.
- `test/fork/Unichain.t.sol`: lifecycle on forked Unichain Sepolia (C1).
- `test/invariant/*`: INV-01 through INV-06.
- `test/scenario/Stress.t.sol`: the demo stress scenario (PRD C2), asserting senior whole and junior absorbing.
