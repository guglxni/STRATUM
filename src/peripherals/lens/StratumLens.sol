// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";

import { StratumHook, IVolatilitySource } from "../../StratumHook.sol";
import { TranchePosition, PoolTrancheState, TrancheType } from "../../StratumTypes.sol";
import { CoverageRatio } from "../../libraries/CoverageRatio.sol";
import { Waterfall } from "../../libraries/Waterfall.sol";
import { ILMath } from "../../libraries/ILMath.sol";
import { EpochAccounting } from "../../libraries/EpochAccounting.sol";

/// @title StratumLens
/// @notice Read-only aggregator for STRATUM pool and position state, following the Uniswap v4
///         StateView pattern: one call returns everything a frontend, agent, or keeper needs to
///         render a pool or position, with the derived values (coverage, dynamic fee, live IL)
///         computed by the SAME libraries the hook uses, so the preview can never drift from the
///         contract behavior.
/// @dev Peripheral by placement only: the lens imports the core, never the reverse (NFR-01). It
///      holds no state, no roles, and can be redeployed freely.
contract StratumLens {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @notice Everything needed to render a pool card in one call.
    struct PoolOverview {
        // Live market state (PoolManager).
        uint160 sqrtPriceX96;
        int24 tick;
        // Tranche balances and protection state (hook).
        uint256 seniorTVL;
        uint256 juniorTVL;
        uint256 juniorReserve;
        uint16 coverageRatioBps;
        uint16 stressLevelBps;
        // Fee the next swap would pay, mirroring beforeSwap (including a volatility override).
        uint16 nextSwapFeeBps;
        // Epoch accounting progress.
        uint64 currentEpoch;
        uint256 epochAccumulatedFees;
        uint256 epochSeniorObligation;
        uint256 epochSeniorFunded;
        // Token-backed reserve and protocol fee ledger.
        uint256 reserve0;
        uint256 reserve1;
        uint256 protocolFeesAccrued;
        // D-1: protocol-fee realization. `protocolFeeRealization` is the per-pool opt-in; the reserves are the
        // real tokens collectable via `collectProtocolFees` (0 when realization has never been enabled).
        bool protocolFeeRealization;
        uint256 protocolFeeReserve0;
        uint256 protocolFeeReserve1;
        // Receipt tokens.
        address seniorToken;
        address juniorToken;
        bool initialized;
    }

    /// @notice A stored position plus its live, settlement-grade derived values.
    struct PositionOverview {
        TranchePosition position;
        PoolId poolId;
        // Mark-to-market IL at the current pool price (the value settleJunior/settleSenior start from).
        uint256 ilAtCurrentPrice;
        // IL at the block-start anchor: the other leg of the A-06/R2-01 guard. A settlement in this
        // block charges min(senior) / max(junior) of the two.
        uint256 ilAtAnchor;
        // Senior contractual coupon accrued to date (0 for junior positions). Pre-vesting value.
        uint256 accruedCoupon;
    }

    StratumHook public immutable hook;
    IPoolManager public immutable poolManager;

    constructor(StratumHook hook_, IPoolManager poolManager_) {
        hook = hook_;
        poolManager = poolManager_;
    }

    /// @notice Aggregate pool state, market state, and derived tranche metrics for one pool.
    /// @param key The pool key (the lens derives the id).
    /// @return o The populated overview. `initialized` false means the pool is unknown to STRATUM.
    function poolOverview(PoolKey calldata key) external view returns (PoolOverview memory o) {
        PoolId id = key.toId();
        PoolTrancheState memory pool = hook.poolState(id);

        (o.sqrtPriceX96, o.tick,,) = poolManager.getSlot0(id);
        o.seniorTVL = pool.seniorTVL;
        o.juniorTVL = pool.juniorTVL;
        o.juniorReserve = pool.juniorReserve;
        o.coverageRatioBps = CoverageRatio.ratioBps(pool.juniorTVL, pool.seniorTVL);
        o.stressLevelBps = CoverageRatio.stressLevel(o.coverageRatioBps, pool.minCoverageRatioBps);
        o.nextSwapFeeBps = _nextSwapFeeBps(id, pool, o.stressLevelBps);
        o.currentEpoch = pool.currentEpoch;
        o.epochAccumulatedFees = pool.epochAccumulatedFees;
        o.epochSeniorObligation = pool.epochSeniorObligation;
        o.epochSeniorFunded = pool.epochSeniorFunded;
        (o.reserve0, o.reserve1) = hook.reserveBalances(id);
        o.protocolFeesAccrued = hook.protocolFeesAccrued(id);
        o.protocolFeeRealization = hook.protocolFeeRealization(id);
        (o.protocolFeeReserve0, o.protocolFeeReserve1) = hook.protocolFeeReserveBalances(id);
        o.seniorToken = pool.seniorToken;
        o.juniorToken = pool.juniorToken;
        o.initialized = pool.initialized;
    }

    /// @notice A position plus the live IL and coupon values its next settlement would start from.
    /// @param positionId The hook position id (see `positionIdFor`).
    /// @return o Populated overview. `o.position.owner == address(0)` means no such position.
    function positionOverview(bytes32 positionId) external view returns (PositionOverview memory o) {
        o.position = hook.position(positionId);
        if (o.position.owner == address(0)) return o;
        o.poolId = hook.positionPool(positionId);

        (uint160 currentSqrt,,,) = poolManager.getSlot0(o.poolId);
        o.ilAtCurrentPrice = ILMath.ilForRange(
            o.position.entrySqrtPriceX96, currentSqrt, o.position.tickLower, o.position.tickUpper, o.position.liquidity
        );

        (uint160 anchorSqrt, uint96 anchorBlock) = hook.blockStartAnchor(o.poolId);
        if (anchorBlock == uint96(block.number) && anchorSqrt != 0) {
            o.ilAtAnchor = ILMath.ilForRange(
                o.position.entrySqrtPriceX96,
                anchorSqrt,
                o.position.tickLower,
                o.position.tickUpper,
                o.position.liquidity
            );
        } else {
            // No anchor recorded this block yet: the first touch would snapshot the current price.
            o.ilAtAnchor = o.ilAtCurrentPrice;
        }

        if (o.position.tranche == TrancheType.SENIOR) {
            PoolTrancheState memory pool = hook.poolState(o.poolId);
            o.accruedCoupon = o.position.principalValue * pool.targetAPYBps
                * (block.timestamp - o.position.entryTimestamp) / (10_000 * EpochAccounting.YEAR_SECONDS);
        }
    }

    /// @notice Derive the hook's position id for a (sender, range, salt) tuple.
    /// @dev Mirrors `StratumHook._positionId` so integrators never re-implement the preimage.
    /// @param sender The v4 sender that opened (or will open) the position - a router, not the end user.
    /// @param tickLower Position lower tick.
    /// @param tickUpper Position upper tick.
    /// @param salt The salt carried in hookData.
    /// @return The position id used by the hook's `positions` mapping.
    function positionIdFor(address sender, int24 tickLower, int24 tickUpper, bytes32 salt)
        external
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(sender, tickLower, tickUpper, salt));
    }

    /// @dev Mirror of the beforeSwap fee computation: EWMA volatility, optionally raised (never
    ///      lowered) by a registered volatility source, then the Waterfall dynamic fee curve.
    function _nextSwapFeeBps(PoolId id, PoolTrancheState memory pool, uint16 stress) internal view returns (uint16) {
        uint256 vol = pool.volatilityEWMA;
        address vsrc = hook.volatilitySource(id);
        if (vsrc != address(0)) {
            try IVolatilitySource(vsrc).getVolatilityOverride(id) returns (uint256 ov) {
                if (ov > vol) vol = ov;
            } catch { }
        }
        return Waterfall.dynamicFeeBps(pool.baseFeeBps, pool.minFeeBps, pool.maxFeeBps, vol, stress);
    }
}
