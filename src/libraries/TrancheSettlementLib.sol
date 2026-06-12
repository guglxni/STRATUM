// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { BalanceDelta, BalanceDeltaLibrary, toBalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { SafeCast } from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";

import { TrancheType, TranchePosition, PoolTrancheState } from "../StratumTypes.sol";
import { IPeripheral } from "../interfaces/IPeripheral.sol";
import { ILMath } from "./ILMath.sol";
import { EpochAccounting } from "./EpochAccounting.sol";
import { ReserveMath } from "./ReserveMath.sol";
import { StratumErrors } from "../StratumErrors.sol";

/// @notice Minimal read-only view of the Brevis settlement shim consumed by the core at settlement.
/// @dev H-06: the core (`StratumHook` + `src/libraries/*`) must compile with the `peripherals/` directory
///      excluded (golden rule 1 / AGENTS.md guardrail 1: the core never imports a concrete peripheral). The
///      library casts the registered peripheral address to this local interface rather than the concrete
///      `BrevisVerifierShim`, so the core-only build profile resolves without any `peripherals/brevis/*` file.
interface IBrevisSettlementReader {
    function verifyTimeWeightedContribution(bytes32 positionId)
        external
        view
        returns (bool proven, uint256 contribution);
    function verifyILAttribution(bytes32 positionId) external view returns (bool proven, uint256 ilAttribution);
}

/// @title TrancheSettlementLib
/// @notice Delegatecall-linked external library holding the heavy STRATUM settlement helpers, extracted from
///         `StratumHook` to keep the hook under the EIP-170 runtime bytecode limit. Behavior is byte-for-byte
///         identical to the in-hook versions: the functions run in the hook's context via DELEGATECALL, so
///         `address(this)` is the hook and storage mutations target the hook's storage through the passed-in
///         storage-pointer parameters. Dependencies the library cannot see (the `poolManager` immutable and the
///         `reserve0`/`reserve1` mappings) are passed in explicitly.
/// @dev Events are re-declared here with identical signatures so their topic hashes match the hook's, keeping
///      the observable event stream unchanged. Constants are re-declared (ROUNDING_TOLERANCE, BREVIS_KIND).
library TrancheSettlementLib {
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;
    using SafeCast for uint256;

    /// @dev Re-declared with identical signatures to `IStratumHook` so emitted topics match (see contract docs).
    event ReserveFunded(PoolId indexed poolId, uint256 amount0, uint256 amount1);
    event SeniorMakeWhole(PoolId indexed poolId, uint256 paid0, uint256 paid1);
    event SeniorMakeWholeShortfall(PoolId indexed poolId, uint256 shortfallValue0);
    /// @dev Mirror of `StratumHook.ProtocolFeeRealized` (D-1). Topic hash must match the hook's declaration.
    event ProtocolFeeRealized(PoolId indexed poolId, uint256 amount0, uint256 amount1, uint256 value0);

    /// @dev Mirror of `StratumHook.ROUNDING_TOLERANCE`. Must stay in sync (INV-03 conservation bound).
    uint256 internal constant ROUNDING_TOLERANCE = 100;

    /// @dev Mirror of `StratumHook.BREVIS_KIND`, the kind() discriminator for the Brevis verifier shim.
    bytes32 internal constant BREVIS_KIND = keccak256("stratum.brevis.verifier");

    /// @notice Top up a withdrawing senior LP by `owedValue0` (token0-denominated) from the token-backed
    ///         reserve, in REAL tokens, settled per currency (R-H1). Never reverts on underfunding.
    /// @dev Pays currency0 first, then converts the remainder to currency1, clamping each leg to the held
    ///      reserve (ReserveMath.splitOwed). Each leg runs the atomic sync->transfer->settle triple; the
    ///      returned NEGATIVE delta magnitude equals the tokens settled per currency, so v4 credits the LP
    ///      exactly that and the hook's PoolManager delta nets to 0 (no CurrencyNotSettled).
    function makeWhole(
        IPoolManager manager,
        mapping(PoolId => uint256) storage reserve0,
        mapping(PoolId => uint256) storage reserve1,
        PoolKey calldata key,
        PoolId id,
        uint256 owedValue0,
        uint160 exitSqrt
    ) external returns (BalanceDelta) {
        (uint256 pay0, uint256 pay1,, uint256 shortfall) =
            ReserveMath.splitOwed(owedValue0, reserve0[id], reserve1[id], exitSqrt);

        if (pay0 > 0) {
            reserve0[id] -= pay0;
            _settleOut(manager, key.currency0, pay0);
        }
        if (pay1 > 0) {
            reserve1[id] -= pay1;
            _settleOut(manager, key.currency1, pay1);
        }

        emit SeniorMakeWhole(id, pay0, pay1);
        if (shortfall > 0) emit SeniorMakeWholeShortfall(id, shortfall);

        // NEGATIVE per currency: v4 computes callerDelta = delta - hookDelta, so -pay credits the LP +pay.
        return toBalanceDelta(-(pay0.toInt128()), -(pay1.toInt128()));
    }

    /// @notice Move `amount` of `currency` from the hook's reserve into the PoolManager to credit an LP.
    /// @dev Canonical v4 sync->transfer->settle. Native (currency0 == address(0)) uses settle{value:} with no
    ///      transfer; in v4 sort order only currency0 can be native, so at most one native settle occurs.
    function _settleOut(IPoolManager manager, Currency currency, uint256 amount) internal {
        manager.sync(currency);
        if (currency.isAddressZero()) {
            manager.settle{ value: amount }();
        } else {
            currency.transfer(address(manager), amount);
            manager.settle();
        }
    }

    /// @notice Reclaim `clawbackValue0` of token0-denominated value from a withdrawing LP, settled per currency.
    /// @dev Takes currency0 first (already in token0 units), then converts any remainder to token1 units and
    ///      takes currency1. Each take is clamped to the LP's withdrawn amount for that currency, so the
    ///      caller's PoolManager delta can never go negative. Returns the hook's positive return delta,
    ///      which v4 subtracts from the caller delta and the hook settles via the take() calls.
    function clawback(
        IPoolManager manager,
        mapping(PoolId => uint256) storage reserve0,
        mapping(PoolId => uint256) storage reserve1,
        PoolKey calldata key,
        BalanceDelta delta,
        uint160 exitSqrt,
        uint256 clawbackValue0
    ) external returns (BalanceDelta) {
        int128 owed0 = delta.amount0();
        int128 owed1 = delta.amount1();
        uint256 avail0 = owed0 > 0 ? uint256(uint128(owed0)) : 0;
        uint256 avail1 = owed1 > 0 ? uint256(uint128(owed1)) : 0;

        uint256 take0 = clawbackValue0 > avail0 ? avail0 : clawbackValue0;
        uint256 remainingValue0 = clawbackValue0 - take0;

        uint256 take1;
        if (remainingValue0 > 0 && avail1 > 0) {
            uint256 want1 = ILMath.token1FromValueInToken0(remainingValue0, exitSqrt);
            take1 = want1 > avail1 ? avail1 : want1;
        }

        if (take0 > 0) manager.take(key.currency0, address(this), take0);
        if (take1 > 0) manager.take(key.currency1, address(this), take1);

        // R-H1: the seized IL value is now real tokens held by the hook. Record it as the token-backed
        // junior buffer that funds senior make-whole. No v4-layer change (same takes, same positive delta).
        if (take0 > 0 || take1 > 0) {
            PoolId id = key.toId();
            reserve0[id] += take0;
            reserve1[id] += take1;
            emit ReserveFunded(id, take0, take1);
        }

        return toBalanceDelta(take0.toInt128(), take1.toInt128());
    }

    /// @notice D-1: realize a pool's protocol fee as REAL tokens via the `afterSwap` return delta (the
    ///         `AFTER_SWAP_RETURNS_DELTA` surcharge model), into the token-backed protocol-fee reserve.
    /// @dev Mirrors `clawback`'s shape: runs in the hook's context (DELEGATECALL, so `address(this)` is the
    ///      hook), takes the surcharge in the swap's UNSPECIFIED currency, and credits the passed-in reserve
    ///      mappings. Conservative by construction:
    ///      - Only realizes from a POSITIVE (output) unspecified leg: that currency is one the swapper is
    ///        receiving, so the surcharge merely reduces their output and v4 nets the hook's delta to zero via
    ///        the `take` below + the returned positive `hookDeltaUnspecified`. A non-positive unspecified leg
    ///        (exact-output input side) returns `(0, 0)` so the protocol simply forgoes that swap; it never
    ///        forces extra input on the swapper and never reverts the swap.
    ///      - The surcharge is clamped to the unspecified leg magnitude, so the take can never exceed what the
    ///        swap actually moved (no CurrencyNotSettled, no draining a counterparty).
    ///      The protocol fee under this model is an ADDITIVE swap surcharge, not a carve-out of the LP fee, so
    ///      the caller must NOT also deduct it from the epoch accumulator (junior keeps the full LP fee).
    /// @param manager              The PoolManager (passed in; the library cannot see the hook's immutable).
    /// @param protocolFeeReserve0  token0 protocol-fee reserve ledger (hook storage, credited here).
    /// @param protocolFeeReserve1  token1 protocol-fee reserve ledger (hook storage, credited here).
    /// @param key                  The pool key (currencies + id).
    /// @param swapDelta            The swapper's balance delta as handed to `afterSwap` (pre hook-delta).
    /// @param specifiedIsToken0    Whether the swap's specified currency is token0 (A-04 convention).
    /// @param protocolPortionValue0 Protocol fee slice in token0-denominated value (from `Waterfall.splitFee`).
    /// @param sqrtPriceX96         Post-swap price, for the token0->token1 value conversion.
    /// @return hookDeltaUnspecified Positive int128 to return from `afterSwap` (the realized surcharge), or 0.
    /// @return realizedValue0      token0-denominated value actually realized (for the observability ledger).
    function realizeProtocolSurcharge(
        IPoolManager manager,
        mapping(PoolId => uint256) storage protocolFeeReserve0,
        mapping(PoolId => uint256) storage protocolFeeReserve1,
        PoolKey calldata key,
        BalanceDelta swapDelta,
        bool specifiedIsToken0,
        uint256 protocolPortionValue0,
        uint160 sqrtPriceX96
    ) external returns (int128 hookDeltaUnspecified, uint256 realizedValue0) {
        if (protocolPortionValue0 == 0) return (0, 0);

        // The unspecified leg is token1 when the specified currency is token0, and vice versa.
        int128 unspecifiedDelta = specifiedIsToken0 ? swapDelta.amount1() : swapDelta.amount0();
        if (unspecifiedDelta <= 0) return (0, 0); // only realize from the output (positive) leg
        uint256 avail = uint256(uint128(unspecifiedDelta));

        uint256 surcharge;
        Currency unspecifiedCurrency;
        if (specifiedIsToken0) {
            // Unspecified currency is token1: convert the token0-denominated portion at the post-swap price.
            surcharge = ILMath.token1FromValueInToken0(protocolPortionValue0, sqrtPriceX96);
            unspecifiedCurrency = key.currency1;
        } else {
            // Unspecified currency is token0: the portion is already in token0 units.
            surcharge = protocolPortionValue0;
            unspecifiedCurrency = key.currency0;
        }
        if (surcharge == 0) return (0, 0);
        if (surcharge > avail) surcharge = avail; // never take more than the swap's output leg

        // Pull the surcharge tokens to the hook (DELEGATECALL: address(this) == hook) and book them to the
        // token-backed reserve. The returned positive delta makes the swapper absorb it (v4 subtracts it).
        manager.take(unspecifiedCurrency, address(this), surcharge);
        PoolId id = key.toId();
        if (specifiedIsToken0) {
            protocolFeeReserve1[id] += surcharge;
            realizedValue0 = ILMath.valueInToken0(0, surcharge, sqrtPriceX96);
        } else {
            protocolFeeReserve0[id] += surcharge;
            realizedValue0 = surcharge;
        }
        emit ProtocolFeeRealized(
            id, specifiedIsToken0 ? 0 : surcharge, specifiedIsToken0 ? surcharge : 0, realizedValue0
        );
        hookDeltaUnspecified = surcharge.toInt128();
    }

    /// @notice Settle a senior position at withdrawal: smoothed earnings, contractual coupon, IL waterfall.
    /// @dev `anchorSqrt` is the pool's block-start price anchor (recorded before any swap in the current
    ///      block). A-06 sandwich guard: the IL charged to the buffer is the MINIMUM of the IL computed at the
    ///      exit spot price and at the anchor price, so an atomic sandwich (swap -> withdraw -> swap back)
    ///      cannot fabricate IL and drain the make-whole reserve. Pass 0 to skip the guard (no anchor known).
    ///      Invariant: payout <= principal + positionEarned (conservation, INV-03).
    function settleSenior(
        TranchePosition storage pos,
        PoolTrancheState storage pool,
        uint160 exitSqrt,
        uint160 anchorSqrt
    ) external returns (uint256 payout, uint256 ilCharged, uint256 positionEarned) {
        // R-H2: roll completed epochs + harvest, then pay the SMOOTHED earnings (carried-forward vested plus
        // the current bucket's vested portion); forfeit the current bucket's unvested remainder to the junior
        // buffer (FR-14). The per-share delta is consumed by the harvest, so there is no separate feeEarned
        // term to add (that would double-count).
        _harvestAndVest(pos, pool);
        (uint256 curVested, uint256 bucket) = _currentBucketVested(pos, pool);
        uint256 unvested = bucket - curVested;
        if (unvested > 0) pool.juniorReserve += unvested; // FR-14, INV-05-sanctioned credit
        uint256 vestedPaid = pos.vestedClaimable + curVested;

        // Senior contractual fixed yield, vested by the same epoch-phase curve. Unvested fixed yield is
        // dropped (not forfeited): it was never funded as tokens, so it is accounting-only until R-H1.
        uint256 holdingSeconds = block.timestamp - pos.entryTimestamp;
        uint256 fixedYield =
            pos.principalValue * pool.targetAPYBps * holdingSeconds / (10_000 * EpochAccounting.YEAR_SECONDS);
        uint256 fixedYieldVested = EpochAccounting.vestedToDate(
            fixedYield, block.timestamp - pool.epochStartTimestamp, pool.smoothingEpochSeconds
        );
        // H-01: do NOT sum these. `vestedPaid` is the senior coupon already FUNDED from swap fees and
        // distributed via `seniorFeePerShareX128` at closeEpoch; `fixedYieldVested` is that SAME contractual
        // coupon recomputed from the target APY. Since per-swap funding is capped at `epochSeniorObligation`
        // (afterSwap), funded <= contractual, so the senior is owed the contractual coupon with the funded
        // per-share amount as its source. Paying the max delivers the guaranteed coupon exactly once; summing
        // them paid ~2x APY and silently drained the make-whole reserve (INV-03 / golden rules 4, 6).
        positionEarned = vestedPaid > fixedYieldVested ? vestedPaid : fixedYieldVested;

        uint256 ilOnPosition =
            ILMath.ilForRange(pos.entrySqrtPriceX96, exitSqrt, pos.tickLower, pos.tickUpper, pos.liquidity);
        // A-06: take the min against the block-start anchor so a same-block sandwich cannot inflate the IL
        // charged to the junior buffer. Cross-block manipulation carries real inventory/arb risk (documented).
        if (anchorSqrt != 0 && anchorSqrt != exitSqrt) {
            uint256 ilAtAnchor =
                ILMath.ilForRange(pos.entrySqrtPriceX96, anchorSqrt, pos.tickLower, pos.tickUpper, pos.liquidity);
            if (ilAtAnchor < ilOnPosition) ilOnPosition = ilAtAnchor;
        }

        uint256 principalPayout = pos.principalValue;
        if (ilOnPosition > 0) {
            if (pool.juniorReserve >= ilOnPosition) {
                pool.juniorReserve -= ilOnPosition;
                ilCharged = ilOnPosition;
            } else {
                ilCharged = ilOnPosition;
                uint256 shortfall = ilOnPosition - pool.juniorReserve;
                pool.juniorReserve = 0;
                uint256 maxSeniorIL = pos.principalValue * pool.maxSeniorILExposureBps / 10_000;
                uint256 seniorIL = shortfall > maxSeniorIL ? maxSeniorIL : shortfall;
                principalPayout = pos.principalValue > seniorIL ? pos.principalValue - seniorIL : 0;
            }
        }
        payout = principalPayout + positionEarned;
        pos.cumulativeILAbsorbed = ilCharged;
    }

    /// @dev R2-01 (mirror of A-06): junior IL is the MAXIMUM of the IL at the exit spot price and at the
    ///      block-start anchor. A junior self-sandwich (pump the price back toward entry, exit with
    ///      suppressed IL, dump) would otherwise starve the clawback that funds the reserve. Pass 0 to skip.
    function settleJunior(
        TranchePosition storage pos,
        PoolTrancheState storage pool,
        uint160 exitSqrt,
        uint160 anchorSqrt
    ) external returns (uint256 payout, uint256 ilCharged, uint256 positionEarned) {
        uint256 ilOnPosition = _juniorGuardedIL(pos, exitSqrt, anchorSqrt);
        ilCharged = ilOnPosition;
        pos.cumulativeILAbsorbed = ilOnPosition;

        // R-H2: roll + harvest, pay the SMOOTHED earnings, forfeit the current bucket's unvested remainder
        // to the junior buffer (FR-14). Harvest consumes the per-share delta.
        _harvestAndVest(pos, pool);
        (uint256 curVested, uint256 bucket) = _currentBucketVested(pos, pool);
        uint256 unvested = bucket - curVested;
        if (unvested > 0) pool.juniorReserve += unvested; // FR-14, INV-05-sanctioned credit
        positionEarned = pos.vestedClaimable + curVested;
        uint256 feeShare = positionEarned;

        if (ilOnPosition > feeShare + pos.principalValue) {
            payout = 0;
        } else if (ilOnPosition > feeShare) {
            payout = pos.principalValue - (ilOnPosition - feeShare);
        } else {
            payout = pos.principalValue + feeShare - ilOnPosition;
        }
    }

    /// @dev R2-01: junior-side anchor guard. The buffer-conservative IL for a junior charge is the MAX of
    ///      the IL valued at the exit price and at the block-start anchor, so a same-block price push can
    ///      only ever increase what the junior absorbs, never suppress it. anchorSqrt == 0 skips the guard.
    function _juniorGuardedIL(TranchePosition storage pos, uint160 exitSqrt, uint160 anchorSqrt)
        internal
        view
        returns (uint256 il)
    {
        il = ILMath.ilForRange(pos.entrySqrtPriceX96, exitSqrt, pos.tickLower, pos.tickUpper, pos.liquidity);
        if (anchorSqrt != 0 && anchorSqrt != exitSqrt) {
            uint256 ilAtAnchor =
                ILMath.ilForRange(pos.entrySqrtPriceX96, anchorSqrt, pos.tickLower, pos.tickUpper, pos.liquidity);
            if (ilAtAnchor > il) il = ilAtAnchor;
        }
    }

    /// @notice Roll completed epochs to fully-vested and harvest the latest per-share earnings into the
    ///         current epoch's smoothing bucket (FR-07). Idempotent within a block (NFR-02).
    /// @dev Two-stage pipeline. (1) If an epoch boundary was crossed since the last touch, the prior bucket's
    ///      smoothing window has fully elapsed, so it is moved into `vestedClaimable` (fully vested) and the
    ///      bucket reset. (2) The per-share delta (only ever bumped at closeEpoch) is harvested into the now
    ///      fresh current-epoch bucket and the checkpoint advanced so value crosses exactly once. The current
    ///      bucket vests linearly across the CURRENT epoch (see `_currentBucketVested`); its unvested part is
    ///      forfeited to `juniorReserve` at settlement (FR-14). Earnings flow attribute -> roll -> smooth, a
    ///      single pipeline, so the per-share model and the buckets never double-pay.
    function harvestAndVest(TranchePosition storage pos, PoolTrancheState storage pool) external {
        _harvestAndVest(pos, pool);
    }

    function _harvestAndVest(TranchePosition storage pos, PoolTrancheState storage pool) internal {
        // (1) ROLL: a crossed epoch boundary means the prior bucket finished its smoothing window.
        if (pos.lastSettledEpoch < pool.currentEpoch) {
            pos.vestedClaimable += pos.accruedFixedYield + pos.excessFeesEarned;
            pos.accruedFixedYield = 0;
            pos.excessFeesEarned = 0;
            pos.lastSettledEpoch = pool.currentEpoch;
        }

        // (2) HARVEST: pull the per-share delta into the current-epoch bucket, then consume it.
        uint256 feePerShareNow =
            pos.tranche == TrancheType.SENIOR ? pool.seniorFeePerShareX128 : pool.juniorFeePerShareX128;
        uint256 deltaX128 = feePerShareNow - pos.feePerShareCheckpointX128; // monotone accumulators: never underflows
        if (deltaX128 > 0) {
            uint256 earned = FullMath.mulDiv(pos.principalValue, deltaX128, uint256(1) << 128); // R-H3 safe
            if (pos.tranche == TrancheType.SENIOR) {
                pos.accruedFixedYield += earned;
            } else {
                pos.excessFeesEarned += earned;
            }
            pos.feePerShareCheckpointX128 = feePerShareNow; // consume: delta is now 0, no double count
        }
    }

    /// @notice Linearly-vested amount of the CURRENT epoch's bucket, by epoch phase, and the bucket total.
    /// @dev Anchored to `epochStartTimestamp`; the closeEpoch time-gate keeps this advancing by whole windows
    ///      only, so it cannot be griefed shorter (R-M5 bounded). Read-only: the partial vest is realized at
    ///      settlement, never stored, so it stays forfeit-able until the position actually exits.
    function currentBucketVested(TranchePosition storage pos, PoolTrancheState storage pool)
        external
        view
        returns (uint256 vested, uint256 bucket)
    {
        return _currentBucketVested(pos, pool);
    }

    function _currentBucketVested(TranchePosition storage pos, PoolTrancheState storage pool)
        internal
        view
        returns (uint256 vested, uint256 bucket)
    {
        bucket = pos.accruedFixedYield + pos.excessFeesEarned;
        if (bucket == 0) return (0, 0);
        uint256 elapsed = block.timestamp - pool.epochStartTimestamp;
        vested = EpochAccounting.vestedToDate(bucket, elapsed, pool.smoothingEpochSeconds);
    }

    function principalFromDelta(BalanceDelta delta, uint160 sqrtPriceX96) external pure returns (uint256) {
        return _principalFromDelta(delta, sqrtPriceX96);
    }

    function _principalFromDelta(BalanceDelta delta, uint160 sqrtPriceX96) internal pure returns (uint256) {
        int128 a0 = delta.amount0();
        int128 a1 = delta.amount1();
        uint256 v0 = a0 < 0 ? uint256(uint128(-a0)) : uint256(uint128(a0));
        uint256 v1 = a1 < 0 ? uint256(uint128(-a1)) : uint256(uint128(a1));
        return ILMath.valueInToken0(v0, v1, sqrtPriceX96);
    }

    function deltaValueToken0(BalanceDelta delta, uint160 sqrtPriceX96) external pure returns (uint256) {
        return _principalFromDelta(delta, sqrtPriceX96);
    }

    /// @notice Value a withdrawal delta at BOTH the exit price and the block-start anchor, returning the
    ///         larger (A-06). Used only to size the senior make-whole gap: the senior-conservative valuation
    ///         minimizes the reserve draw under same-block price manipulation while leaving honest
    ///         withdrawals (anchor == exit, or anchor unset) unchanged.
    /// @dev anchorSqrt == 0 means "no anchor recorded"; the exit valuation is used as-is.
    function deltaValueToken0Guarded(BalanceDelta delta, uint160 exitSqrt, uint160 anchorSqrt)
        external
        pure
        returns (uint256 value0)
    {
        value0 = _principalFromDelta(delta, exitSqrt);
        if (anchorSqrt != 0 && anchorSqrt != exitSqrt) {
            uint256 atAnchor = _principalFromDelta(delta, anchorSqrt);
            if (atAnchor > value0) value0 = atAnchor;
        }
    }

    function conservationCheck(uint256 principalIn, uint256 payout, uint256 positionEarnedFees) external pure {
        if (payout > principalIn + positionEarnedFees + ROUNDING_TOLERANCE) {
            revert StratumErrors.ConservationViolation();
        }
    }

    // -------------------------------------------------------------------------
    // Tranche migration (FR-31): in-place reclassification of an existing position
    // -------------------------------------------------------------------------

    /// @notice Reclassify a position from its current tranche to `newTranche` WITHOUT moving the underlying
    ///         Uniswap liquidity or any real tokens. The position's accrued IL is realized under its CURRENT
    ///         tranche first, then the IL/yield clock is reset so the position earns and absorbs as the new
    ///         tranche from this point forward (FR-30/FR-31).
    /// @dev Why realize IL before flipping: senior/junior status only changes how STRATUM's waterfall TREATS
    ///      the same liquidity. If we reset `entrySqrtPriceX96` without first charging the IL that accrued
    ///      under the old tranche, a junior could migrate to senior the instant before an adverse move and
    ///      shed IL it already incurred onto the junior buffer / remaining juniors (golden rule 3, INV-05).
    ///      So:
    ///        - JUNIOR-now: the junior already bears IL directly, so realized IL reduces the carried principal.
    ///          The buffer is untouched (the junior, not the buffer, ate it) - INV-05 safe.
    ///        - SENIOR-now: protected, so realized IL is charged to `juniorReserve` first (INV-05-sanctioned
    ///          IL absorption), overflowing onto the senior's own principal only past the buffer and only up to
    ///          `maxSeniorILExposureBps` (INV-02). Identical to `settleSenior`'s IL branch.
    ///      Carried principal can only ever be <= old principal (IL never adds value), so the caller's
    ///      conservation check (carried <= old + tolerance) holds by construction (INV-03). Current-epoch
    ///      unvested earnings are forfeited to the buffer (FR-14) exactly as at settlement, and `vestedClaimable`
    ///      is preserved across the flip (it is owed regardless of tranche). Liquidity, tick range and owner are
    ///      left untouched: this is the SAME position, reclassified.
    /// @param pos The position being migrated (mutated in place).
    /// @param pool The pool state (buffer debits and obligation re-sync happen against this).
    /// @param currentSqrt Current pool sqrtPriceX96 (candidate IL realization endpoint and IL-clock origin).
    /// @param anchorSqrt Block-start price anchor (0 to skip the guard). R2-01: the migration is valued at a
    ///        SINGLE price X picked buffer-conservatively between current and anchor - max-IL when a junior
    ///        is realizing (it cannot self-sandwich its IL away before flipping to protected senior), min-IL
    ///        when a senior is realizing (a sandwich cannot inflate the buffer debit). The new IL clock
    ///        starts at the SAME X so no price segment is dropped or double-counted across the flip.
    /// @param newTranche The destination tranche (must differ from the current tranche; checked by the hook).
    /// @return carriedPrincipal Principal re-registered in the new tranche (post IL realization).
    /// @return realizedIL IL realized under the old tranche during this migration.
    function migratePosition(
        TranchePosition storage pos,
        PoolTrancheState storage pool,
        uint160 currentSqrt,
        uint160 anchorSqrt,
        TrancheType newTranche
    ) external returns (uint256 carriedPrincipal, uint256 realizedIL) {
        // (1) Settle earnings up to now under the OLD tranche: roll completed epochs, harvest the per-share
        // delta, vest the current bucket's earned portion into vestedClaimable, forfeit the unvested remainder
        // to the junior buffer (FR-14). This drains accruedFixedYield/excessFeesEarned so the new tranche's
        // per-share model starts clean and never double-counts old-tranche earnings.
        _harvestAndVest(pos, pool);
        (uint256 curVested, uint256 bucket) = _currentBucketVested(pos, pool);
        uint256 unvested = bucket - curVested;
        if (unvested > 0) pool.juniorReserve += unvested; // FR-14, INV-05-sanctioned credit
        pos.vestedClaimable += curVested;
        pos.accruedFixedYield = 0;
        pos.excessFeesEarned = 0;

        // (2) Realize IL accrued from entry to now, charged per the CURRENT tranche's rules. R2-01: value the
        // migration at a single anchor-guarded price X (see @param anchorSqrt) so a same-block manipulation
        // can neither shed junior IL onto the buffer nor inflate the buffer debit of a senior flip.
        uint160 migrationSqrt = currentSqrt;
        realizedIL = ILMath.ilForRange(pos.entrySqrtPriceX96, currentSqrt, pos.tickLower, pos.tickUpper, pos.liquidity);
        if (anchorSqrt != 0 && anchorSqrt != currentSqrt) {
            uint256 ilAtAnchor =
                ILMath.ilForRange(pos.entrySqrtPriceX96, anchorSqrt, pos.tickLower, pos.tickUpper, pos.liquidity);
            bool anchorWins = pos.tranche == TrancheType.JUNIOR ? ilAtAnchor > realizedIL : ilAtAnchor < realizedIL;
            if (anchorWins) {
                realizedIL = ilAtAnchor;
                migrationSqrt = anchorSqrt;
            }
        }
        carriedPrincipal = pos.principalValue;
        if (realizedIL > 0) {
            if (pos.tranche == TrancheType.JUNIOR) {
                // The junior bears IL on its own principal. Buffer untouched.
                carriedPrincipal = pos.principalValue > realizedIL ? pos.principalValue - realizedIL : 0;
            } else {
                // Senior is protected: buffer absorbs first, residual onto senior principal up to the cap.
                if (pool.juniorReserve >= realizedIL) {
                    pool.juniorReserve -= realizedIL;
                } else {
                    uint256 shortfall = realizedIL - pool.juniorReserve;
                    pool.juniorReserve = 0;
                    uint256 maxSeniorIL = pos.principalValue * pool.maxSeniorILExposureBps / 10_000;
                    uint256 seniorIL = shortfall > maxSeniorIL ? maxSeniorIL : shortfall;
                    carriedPrincipal = pos.principalValue > seniorIL ? pos.principalValue - seniorIL : 0;
                }
            }
        }
        pos.cumulativeILAbsorbed += realizedIL;

        // (3) Reset the position into the new tranche. The IL/yield clock restarts at the SAME price the old
        // tranche was settled at (R2-01), so the entry-to-now segment crosses the flip exactly once; the
        // receipt-token swap, TVL ledger move and coverage enforcement happen in the hook (it owns those).
        pos.tranche = newTranche;
        pos.principalValue = carriedPrincipal;
        pos.entrySqrtPriceX96 = migrationSqrt;
        pos.entryTimestamp = block.timestamp;
        pos.entryEpoch = pool.currentEpoch;
        pos.lastSettledEpoch = pool.currentEpoch;
        pos.feePerShareCheckpointX128 =
            newTranche == TrancheType.SENIOR ? pool.seniorFeePerShareX128 : pool.juniorFeePerShareX128;
    }

    // -------------------------------------------------------------------------
    // Brevis integration helpers (Phase 5, FR-21, FR-22)
    // -------------------------------------------------------------------------

    /// @notice Return true if the registered peripheral is an enabled Brevis shim.
    /// @dev Reads kind() with a try-catch; returns false on any failure (peripheral may not be a
    ///      Brevis shim, may be disabled, or the call may revert).  Never blocks.
    function isBrevisEnabled(address reg) external view returns (bool) {
        return _isBrevisEnabled(reg);
    }

    function _isBrevisEnabled(address reg) internal view returns (bool) {
        if (reg == address(0)) return false;
        try IPeripheral(reg).kind() returns (bytes32 k) {
            if (k != BREVIS_KIND) return false;
        } catch {
            return false;
        }
        try IPeripheral(reg).isEnabled() returns (bool en) {
            return en;
        } catch {
            return false;
        }
    }

    /// @notice Query the Brevis shim for the proven time-weighted contribution of a position.
    /// @dev Falls back to (false, 0) on any failure (FR-22, NFR-01).
    function queryBrevisContribution(address reg, bytes32 positionId)
        external
        view
        returns (bool proven, uint256 contribution)
    {
        if (!_isBrevisEnabled(reg)) return (false, 0);
        try IBrevisSettlementReader(reg).verifyTimeWeightedContribution(positionId) returns (bool p, uint256 c) {
            return (p, c);
        } catch {
            return (false, 0);
        }
    }

    /// @notice Query the Brevis shim for the proven IL attribution of a position.
    /// @dev Falls back to (false, 0) on any failure (FR-22, NFR-01).
    function queryBrevisIL(address reg, bytes32 positionId) external view returns (bool proven, uint256 ilAttribution) {
        if (!_isBrevisEnabled(reg)) return (false, 0);
        try IBrevisSettlementReader(reg).verifyILAttribution(positionId) returns (bool p, uint256 il) {
            return (p, il);
        } catch {
            return (false, 0);
        }
    }

    /// @notice Junior settlement using Brevis-proven contribution and IL (FR-21).
    /// @dev Mirrors `_settleJunior` in structure but substitutes ZK-proven values for the
    ///      approximate on-chain numbers.  The conservation check in `afterRemoveLiquidity`
    ///      fires after this returns (INV-03).
    ///      INV-05: juniorReserve credit for unvested fees (FR-14) still applies; the proven
    ///      contribution replaces only the fee-share portion, not the vesting mechanics.
    function settleJuniorWithProof(
        TranchePosition storage pos,
        PoolTrancheState storage pool,
        uint256 provenContribution,
        uint256 provenIL,
        uint160 exitSqrt,
        uint160 anchorSqrt
    ) external returns (uint256 payout, uint256 ilCharged, uint256 positionEarned) {
        // A-10: floor the proven IL at the independent on-chain tick-derived IL. The BS1/BS2 ceiling stops a
        // forged proof INFLATING the payout, but a one-sided clamp still let a forged/stale LOW provenIL
        // suppress the junior IL clawback entirely (payout = principal + fees with zero IL charge), starving
        // the reserve that senior make-whole draws from. With a stub verifier the proof may only refine the
        // split UPWARD from the on-chain floor; when a real circuit is wired this floor can be revisited.
        // R2-01: the floor itself is anchor-guarded (max of exit/anchor) so a same-block self-sandwich
        // cannot lower the floor the proof is held to.
        uint256 onChainIL = _juniorGuardedIL(pos, exitSqrt, anchorSqrt);
        if (provenIL < onChainIL) provenIL = onChainIL;
        ilCharged = provenIL;
        pos.cumulativeILAbsorbed = provenIL;

        // Harvest + vest: the vesting mechanics are on-chain and not part of the ZK proof.
        // The proven contribution substitutes for the fee-share accumulator logic; vested
        // amounts already recorded in vestedClaimable are additive.
        _harvestAndVest(pos, pool);
        (uint256 curVested, uint256 bucket) = _currentBucketVested(pos, pool);
        uint256 unvested = bucket - curVested;
        if (unvested > 0) pool.juniorReserve += unvested; // FR-14, INV-05

        // BS1/BS2 fix. A ZK proof may REFINE the IL/contribution split, but in this build the verifier is a
        // stub (any non-empty bytes pass), so a proof must never INFLATE the payout beyond what on-chain fee
        // accounting justifies. We compute the payout with the proven values for precision, then CLAMP the
        // total to an INDEPENDENT on-chain ceiling and use that ceiling (not the proven value) as the
        // conservation bound. A forged `provenContribution`/`provenIL` therefore can never over-pay (INV-03);
        // at worst it is clamped to the honest on-chain amount. When a real circuit is wired, the ceiling can
        // be relaxed to the circuit-verified pool-fee bound.
        uint256 onChainEarned = pos.vestedClaimable + curVested;
        uint256 effectiveEarned = provenContribution > onChainEarned ? provenContribution : onChainEarned;

        uint256 raw;
        if (provenIL > effectiveEarned + pos.principalValue) {
            raw = 0;
        } else if (provenIL > effectiveEarned) {
            raw = pos.principalValue - (provenIL - effectiveEarned);
        } else {
            raw = pos.principalValue + effectiveEarned - provenIL;
        }

        uint256 ceiling = pos.principalValue + onChainEarned + ROUNDING_TOLERANCE;
        payout = raw > ceiling ? ceiling : raw;
        positionEarned = onChainEarned; // independent conservation bound, NOT the attacker-controlled proof
    }
}
