// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { LPFeeLibrary } from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { BalanceDelta, BalanceDeltaLibrary, toBalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { BeforeSwapDelta, BeforeSwapDeltaLibrary } from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { SafeCast } from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";

import { StratumBaseHook } from "./base/StratumBaseHook.sol";
import { TrancheToken } from "./TrancheToken.sol";
import { TrancheType, TranchePosition, PoolTrancheState, PoolInitParams } from "./StratumTypes.sol";
import { IStratumHook } from "./interfaces/IStratumHook.sol";
import { IPeripheral } from "./interfaces/IPeripheral.sol";
import { ILMath } from "./libraries/ILMath.sol";
import { Waterfall } from "./libraries/Waterfall.sol";
import { CoverageRatio } from "./libraries/CoverageRatio.sol";
import { EpochAccounting } from "./libraries/EpochAccounting.sol";
import { ReserveMath } from "./libraries/ReserveMath.sol";
import { StratumErrors } from "./StratumErrors.sol";

/// @title StratumHook
/// @notice Uniswap v4 hook implementing senior/junior credit tranching with a priority waterfall.
/// @dev Core works with zero peripherals (NFR-01). IL from pool ticks only (golden rule 2).
contract StratumHook is StratumBaseHook, IStratumHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using LPFeeLibrary for uint24;
    using BalanceDeltaLibrary for BalanceDelta;
    using SafeCast for uint256;

    mapping(PoolId => PoolTrancheState) public poolStates;
    mapping(bytes32 => TranchePosition) public positions;
    mapping(PoolId => uint160) public lastSqrtPriceX96;
    mapping(PoolId => PoolInitParams) public pendingPoolInit;
    mapping(PoolId => address) public poolCreators;
    mapping(PoolId => uint16) private _pendingSwapFeeBps;
    mapping(bytes32 => PoolId) public positionPool;

    /// @notice Real token0/token1 held by the hook as the token-backed junior buffer (R-H1). Funded by the
    ///         IL-clawback `take()`s (junior IL absorption), drawn to deliver senior make-whole in real
    ///         tokens. Kept strictly separate from the abstract `PoolTrancheState.juniorReserve` accumulator
    ///         (INV-05): these are held-but-earmarked tokens, not the waterfall buffer number.
    mapping(PoolId => uint256) public reserve0;
    mapping(PoolId => uint256) public reserve1;

    /// @dev The hook must hold native ETH to settle a native make-whole leg (currency0 == address(0)).
    receive() external payable { }

    uint256 public constant ROUNDING_TOLERANCE = 100;

    /// @dev Gas stipend forwarded to a peripheral so it can never gas-grief core settlement (NFR-01). A
    ///      safety bound, not a pool parameter, so it lives here rather than in PoolTrancheState.
    uint256 public constant PERIPHERAL_GAS_STIPEND = 150_000;

    constructor(IPoolManager _poolManager) StratumBaseHook(_poolManager) {
        Hooks.validateHookPermissions(
            this,
            Hooks.Permissions({
                beforeInitialize: true,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: true,
                beforeRemoveLiquidity: true,
                afterRemoveLiquidity: true,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: true
            })
        );
    }

    /// @inheritdoc IStratumHook
    function poolState(PoolId id) external view returns (PoolTrancheState memory) {
        return poolStates[id];
    }

    /// @inheritdoc IStratumHook
    function position(bytes32 positionId) external view returns (TranchePosition memory) {
        return positions[positionId];
    }

    /// @inheritdoc IStratumHook
    function reserveBalances(PoolId id) external view returns (uint256 r0, uint256 r1) {
        return (reserve0[id], reserve1[id]);
    }

    /// @inheritdoc IStratumHook
    /// @dev Harvests the position's per-share earnings and advances its linear vesting (FR-07), returning the
    ///      cumulative vested-to-date amount. It does NOT transfer tokens: the hook can only move tokens
    ///      inside a PoolManager unlock callback, so the vested earnings are delivered when the position is
    ///      removed (afterRemoveLiquidity). This makes the vesting state observable and is idempotent within
    ///      a block (NFR-02). Replaces the prior inverted body that could never pay (R-L1).
    function claimVested(bytes32 positionId) external returns (uint256 vested) {
        TranchePosition storage pos = positions[positionId];
        if (pos.owner != msg.sender) revert StratumErrors.NotPositionOwner();
        PoolTrancheState storage pool = poolStates[positionPool[positionId]];
        _harvestAndVest(pos, pool);
        (uint256 curVested,) = _currentBucketVested(pos, pool);
        return pos.vestedClaimable + curVested;
    }

    /// @notice Store pool parameters before `PoolManager.initialize`. Caller becomes pool creator.
    function preparePool(PoolKey calldata key, PoolInitParams calldata params) external {
        PoolId id = key.toId();
        if (poolStates[id].initialized) revert StratumErrors.Unauthorized();
        if (poolCreators[id] != address(0) && poolCreators[id] != msg.sender) {
            revert StratumErrors.Unauthorized();
        }
        poolCreators[id] = msg.sender;
        pendingPoolInit[id] = params;
    }

    /// @notice Close the current epoch and open the next (FR-13).
    function closeEpoch(PoolId id) external {
        PoolTrancheState storage pool = poolStates[id];
        if (!pool.initialized) revert StratumErrors.PoolNotInitialized();
        if (block.timestamp < pool.epochStartTimestamp + pool.smoothingEpochSeconds) {
            revert StratumErrors.EpochNotElapsed();
        }

        uint256 accumulated = pool.epochAccumulatedFees;
        uint256 obligation = pool.epochSeniorObligation;
        (uint256 surplus, uint256 shortfall) =
            EpochAccounting.epochSurplus(accumulated, obligation, pool.epochSeniorFunded);

        if (shortfall > 0) {
            uint256 cover = shortfall > pool.juniorReserve ? pool.juniorReserve : shortfall;
            pool.juniorReserve -= cover;
            pool.epochSeniorFunded += cover;
        }

        if (pool.seniorTVL > 0 && pool.epochSeniorFunded > 0) {
            pool.seniorFeePerShareX128 += (pool.epochSeniorFunded << 128) / pool.seniorTVL;
        }

        if (surplus > 0 && pool.juniorTVL > 0) {
            pool.juniorReserve += surplus;
            pool.juniorFeePerShareX128 += (surplus << 128) / pool.juniorTVL;
        }

        // Capture pre-reset values for the event/ctx before the accumulators roll forward.
        uint64 closedEpoch = pool.currentEpoch;
        uint256 funded = pool.epochSeniorFunded;
        emit EpochClosed(id, closedEpoch, funded, surplus);
        emit JuniorReserveUpdated(id, closedEpoch, pool.juniorReserve);

        pool.currentEpoch += 1;
        pool.epochAccumulatedFees = 0;
        pool.epochSeniorFunded = 0;
        pool.epochSeniorObligation =
            EpochAccounting.seniorObligationForEpoch(pool.seniorTVL, pool.targetAPYBps, pool.smoothingEpochSeconds);
        pool.epochStartTimestamp = block.timestamp;

        // Notify-only peripheral dispatch AFTER all core state is finalized, so a peripheral can never
        // reorder waterfall math (INV-04) or the epoch roll (INV-06). No-op when running core-only (NFR-01).
        _notifyEpochClose(
            id, closedEpoch, abi.encode(funded, surplus, pool.juniorReserve, pool.juniorTVL, pool.seniorTVL)
        );
    }

    /// @dev Notify the registered peripheral that an epoch closed. Notify-only: the return value and any
    ///      state the peripheral mutates are ignored by the core (preserves INV-03/INV-05). Failures and gas
    ///      exhaustion are swallowed so a peripheral can never block settlement (NFR-01, golden rule 1).
    function _notifyEpochClose(PoolId id, uint64 epoch, bytes memory ctx) internal {
        address reg = poolStates[id].peripheralRegistry;
        if (reg == address(0)) return;
        try IPeripheral(reg).onEpochClose{ gas: PERIPHERAL_GAS_STIPEND }(id, epoch, ctx) returns (
            bytes memory
        ) {
        // result intentionally discarded
        }
        catch {
            emit PeripheralCallFailed(id, reg, IPeripheral.onEpochClose.selector);
        }
    }

    /// @dev Notify the registered peripheral of coverage stress. Notify-only, gas-bounded, non-blocking.
    function _notifyCoverageStress(PoolId id, uint16 ratioBps) internal {
        address reg = poolStates[id].peripheralRegistry;
        if (reg == address(0)) return;
        try IPeripheral(reg).onCoverageStress{ gas: PERIPHERAL_GAS_STIPEND }(id, ratioBps) {
        // no-op on success
        }
        catch {
            emit PeripheralCallFailed(id, reg, IPeripheral.onCoverageStress.selector);
        }
    }

    /// @inheritdoc IHooks
    function beforeInitialize(address, PoolKey calldata key, uint160)
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        PoolId id = key.toId();
        PoolInitParams memory params = pendingPoolInit[id];
        if (params.smoothingEpochSeconds == 0) revert StratumErrors.PoolNotInitialized();
        delete pendingPoolInit[id];
        if (params.minFeeBps > params.baseFeeBps || params.baseFeeBps > params.maxFeeBps) {
            revert StratumErrors.FeeBoundsInvalid();
        }
        if (params.minCoverageRatioBps == 0 || params.maxSeniorILExposureBps > 10_000) {
            revert StratumErrors.FeeBoundsInvalid();
        }
        if (params.protocolFeeBps > 3000) revert StratumErrors.FeeBoundsInvalid();

        TrancheToken senior = new TrancheToken("Stratum Senior LP", "stLP", TrancheType.SENIOR, address(this));
        TrancheToken junior = new TrancheToken("Stratum Junior LP", "jtLP", TrancheType.JUNIOR, address(this));

        poolStates[id] = PoolTrancheState({
            seniorTVL: 0,
            juniorTVL: 0,
            juniorReserve: 0,
            targetAPYBps: params.targetAPYBps,
            minCoverageRatioBps: params.minCoverageRatioBps,
            maxSeniorILExposureBps: params.maxSeniorILExposureBps,
            smoothingEpochSeconds: params.smoothingEpochSeconds,
            currentEpoch: 0,
            epochAccumulatedFees: 0,
            epochSeniorObligation: EpochAccounting.seniorObligationForEpoch(
                0, params.targetAPYBps, params.smoothingEpochSeconds
            ),
            epochSeniorFunded: 0,
            volatilityEWMA: 0,
            baseFeeBps: params.baseFeeBps,
            minFeeBps: params.minFeeBps,
            maxFeeBps: params.maxFeeBps,
            protocolFeeBps: params.protocolFeeBps,
            poolCumulativeIL: 0,
            peripheralRegistry: params.peripheralRegistry,
            seniorToken: address(senior),
            juniorToken: address(junior),
            initialized: true,
            epochStartTimestamp: block.timestamp,
            seniorFeePerShareX128: 0,
            juniorFeePerShareX128: 0
        });

        return IHooks.beforeInitialize.selector;
    }

    /// @inheritdoc IHooks
    function afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, BalanceDelta) {
        PoolId id = key.toId();
        PoolTrancheState storage pool = poolStates[id];
        if (!pool.initialized) revert StratumErrors.PoolNotInitialized();

        (TrancheType tranche, bytes32 salt) = abi.decode(hookData, (TrancheType, bytes32));
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(id);
        lastSqrtPriceX96[id] = sqrtPriceX96;

        uint256 principalValue = _principalFromDelta(delta, sqrtPriceX96);
        uint128 liquidity = uint128(uint256(params.liquidityDelta > 0 ? params.liquidityDelta : -params.liquidityDelta));

        bytes32 positionId = keccak256(abi.encode(sender, params.tickLower, params.tickUpper, salt));
        if (positions[positionId].owner != address(0)) revert StratumErrors.PositionAlreadyExists();

        uint256 feeCheckpoint = tranche == TrancheType.SENIOR ? pool.seniorFeePerShareX128 : pool.juniorFeePerShareX128;

        if (tranche == TrancheType.SENIOR) {
            CoverageRatio.enforceOnSeniorIntake(
                pool.juniorTVL, pool.seniorTVL, principalValue, pool.minCoverageRatioBps
            );
            pool.seniorTVL += principalValue;
            _syncSeniorObligation(pool);
            TrancheToken(pool.seniorToken).mint(sender, principalValue);
        } else {
            pool.juniorTVL += principalValue;
            TrancheToken(pool.juniorToken).mint(sender, principalValue);
        }

        positions[positionId] = TranchePosition({
            tranche: tranche,
            owner: sender,
            entrySqrtPriceX96: sqrtPriceX96,
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            liquidity: liquidity,
            cumulativeILAbsorbed: 0,
            accruedFixedYield: 0,
            excessFeesEarned: 0,
            entryEpoch: pool.currentEpoch,
            lastSettledEpoch: pool.currentEpoch,
            vestedClaimable: 0,
            principalValue: principalValue,
            entryTimestamp: block.timestamp,
            feePerShareCheckpointX128: feeCheckpoint
        });
        positionPool[positionId] = id; // resolve pool for claimVested (ABI-stable)

        emit TrancheDeposited(id, positionId, sender, tranche, liquidity, pool.currentEpoch);

        uint16 ratio = CoverageRatio.ratioBps(pool.juniorTVL, pool.seniorTVL);
        uint16 stress = CoverageRatio.stressLevel(ratio, pool.minCoverageRatioBps);
        if (stress > 5000) {
            emit CoverageStress(id, ratio, stress);
            _notifyCoverageStress(id, ratio); // notify-only; runs after intake enforcement already passed
        }

        return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /// @inheritdoc IHooks
    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        PoolTrancheState storage pool = poolStates[id];
        uint16 ratio = CoverageRatio.ratioBps(pool.juniorTVL, pool.seniorTVL);
        uint16 stress = CoverageRatio.stressLevel(ratio, pool.minCoverageRatioBps);
        uint16 feeBps =
            Waterfall.dynamicFeeBps(pool.baseFeeBps, pool.minFeeBps, pool.maxFeeBps, pool.volatilityEWMA, stress);
        _pendingSwapFeeBps[id] = feeBps;
        uint24 lpFee = uint24(uint256(feeBps) * 100);
        if (lpFee > LPFeeLibrary.MAX_LP_FEE) lpFee = LPFeeLibrary.MAX_LP_FEE;
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, lpFee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    /// @inheritdoc IHooks
    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata swapParams,
        BalanceDelta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, int128) {
        PoolId id = key.toId();
        PoolTrancheState storage pool = poolStates[id];

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(id);
        uint160 prev = lastSqrtPriceX96[id];
        if (prev != 0) {
            pool.poolCumulativeIL += ILMath.incrementalIL(prev, sqrtPriceX96, uint128(pool.juniorTVL / 1e12 + 1));
            pool.volatilityEWMA = ILMath.updateVolatilityEWMA(pool.volatilityEWMA, prev, sqrtPriceX96);
        }
        lastSqrtPriceX96[id] = sqrtPriceX96;

        uint16 feeBps = _pendingSwapFeeBps[id];
        delete _pendingSwapFeeBps[id];
        uint256 swapAmount = swapParams.amountSpecified < 0
            ? uint256(-int256(swapParams.amountSpecified))
            : uint256(int256(swapParams.amountSpecified));
        uint256 feeAmount = swapAmount * feeBps / 10_000;
        if (feeAmount == 0 && swapAmount > 0 && feeBps > 0) feeAmount = 1;

        if (feeAmount > 0) {
            uint16 ratio = CoverageRatio.ratioBps(pool.juniorTVL, pool.seniorTVL);
            uint16 stress = CoverageRatio.stressLevel(ratio, pool.minCoverageRatioBps);
            Waterfall.Split memory split =
                Waterfall.splitFee(feeAmount, pool.protocolFeeBps, pool.volatilityEWMA, stress);
            pool.epochAccumulatedFees += feeAmount;
            uint256 fund = split.seniorPortion;
            if (pool.epochSeniorFunded + fund > pool.epochSeniorObligation) {
                fund = pool.epochSeniorObligation > pool.epochSeniorFunded
                    ? pool.epochSeniorObligation - pool.epochSeniorFunded
                    : 0;
            }
            pool.epochSeniorFunded += fund;
            // R-H5: junior surplus is credited ONCE, at closeEpoch, against the fully-funded obligation
            // (INV-04). Crediting split.juniorPortion here too double-counted it, because
            // epochAccumulatedFees already carries that portion and closeEpoch re-credits the surplus.
            emit SwapAccounted(id, pool.currentEpoch, feeAmount, pool.volatilityEWMA, ratio);
        }

        return (IHooks.afterSwap.selector, 0);
    }

    /// @inheritdoc IHooks
    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4) {
        bytes32 positionId = _positionId(sender, params, hookData);
        TranchePosition storage pos = positions[positionId];
        if (pos.owner == address(0)) revert StratumErrors.PositionNotFound();
        PoolTrancheState storage pool = poolStates[key.toId()];
        // Harvest + vest unconditionally so partial-epoch earnings are captured before settlement.
        _harvestAndVest(pos, pool);
        return IHooks.beforeRemoveLiquidity.selector;
    }

    /// @inheritdoc IHooks
    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, BalanceDelta) {
        PoolId id = key.toId();
        PoolTrancheState storage pool = poolStates[id];
        bytes32 positionId = _positionId(sender, params, hookData);
        TranchePosition storage pos = positions[positionId];
        if (pos.owner != sender) revert StratumErrors.NotPositionOwner();

        (uint160 exitSqrt,,,) = poolManager.getSlot0(id);
        uint256 payout;
        uint256 ilCharged;
        uint256 positionEarned;
        TrancheType tranche = pos.tranche; // capture before `delete pos` (needed for the make-whole branch)

        if (pos.tranche == TrancheType.SENIOR) {
            (payout, ilCharged, positionEarned) = _settleSenior(pos, pool, exitSqrt);
            pool.seniorTVL = pool.seniorTVL > pos.principalValue ? pool.seniorTVL - pos.principalValue : 0;
            _syncSeniorObligation(pool);
            TrancheToken(pool.seniorToken).burn(sender, pos.principalValue);
        } else {
            uint256 newJuniorTVL = pool.juniorTVL > pos.principalValue ? pool.juniorTVL - pos.principalValue : 0;
            if (pool.seniorTVL > 0) {
                uint16 prospective = CoverageRatio.ratioBps(newJuniorTVL, pool.seniorTVL);
                if (prospective < pool.minCoverageRatioBps) {
                    revert StratumErrors.CoverageRatioBelowFloor();
                }
            }
            (payout, ilCharged, positionEarned) = _settleJunior(pos, pool, exitSqrt);
            pool.juniorTVL = newJuniorTVL;
            TrancheToken(pool.juniorToken).burn(sender, pos.principalValue);
        }

        _conservationCheck(pos.principalValue, payout, positionEarned);
        emit TrancheSettled(id, positionId, sender, pos.tranche, payout, ilCharged);
        delete positions[positionId];
        positionPool[positionId] = PoolId.wrap(bytes32(0));

        uint256 received = _deltaValueToken0(delta, exitSqrt);

        // received > payout: the pool returned more than the tranche payout (IL clawback). The hook
        //   reclaims the difference. The difference is a token0-denominated VALUE, but the LP holds it
        //   across both currencies, so we must settle PER CURRENCY and clamp each take to what the LP
        //   actually withdrew (delta.amountN) - never size a single-currency take with a blended value
        //   (R-C1). This keeps the caller's per-currency delta >= 0, so unlock() never reverts
        //   CurrencyNotSettled and no wrong asset is seized.
        // received < payout (SENIOR): the protected payout exceeds the pool's natural return. The hook tops
        //   up the gap in REAL tokens from the token-backed reserve (R-H1), settling per currency via
        //   sync->transfer->settle and returning a NEGATIVE delta so v4 credits the LP the extra. Clamped to
        //   the reserve held (partial + shortfall event if underfunded); never reverts the withdrawal.
        if (received > payout) {
            return (IHooks.afterRemoveLiquidity.selector, _clawback(key, delta, exitSqrt, received - payout));
        }
        if (tranche == TrancheType.SENIOR && payout > received) {
            return (IHooks.afterRemoveLiquidity.selector, _makeWhole(key, id, payout - received, exitSqrt));
        }
        return (IHooks.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /// @notice Top up a withdrawing senior LP by `owedValue0` (token0-denominated) from the token-backed
    ///         reserve, in REAL tokens, settled per currency (R-H1). Never reverts on underfunding.
    /// @dev Pays currency0 first, then converts the remainder to currency1, clamping each leg to the held
    ///      reserve (ReserveMath.splitOwed). Each leg runs the atomic sync->transfer->settle triple; the
    ///      returned NEGATIVE delta magnitude equals the tokens settled per currency, so v4 credits the LP
    ///      exactly that and the hook's PoolManager delta nets to 0 (no CurrencyNotSettled).
    function _makeWhole(PoolKey calldata key, PoolId id, uint256 owedValue0, uint160 exitSqrt)
        internal
        returns (BalanceDelta)
    {
        (uint256 pay0, uint256 pay1,, uint256 shortfall) =
            ReserveMath.splitOwed(owedValue0, reserve0[id], reserve1[id], exitSqrt);

        if (pay0 > 0) {
            reserve0[id] -= pay0;
            _settleOut(key.currency0, pay0);
        }
        if (pay1 > 0) {
            reserve1[id] -= pay1;
            _settleOut(key.currency1, pay1);
        }

        emit SeniorMakeWhole(id, pay0, pay1);
        if (shortfall > 0) emit SeniorMakeWholeShortfall(id, shortfall);

        // NEGATIVE per currency: v4 computes callerDelta = delta - hookDelta, so -pay credits the LP +pay.
        return toBalanceDelta(-(pay0.toInt128()), -(pay1.toInt128()));
    }

    /// @notice Move `amount` of `currency` from the hook's reserve into the PoolManager to credit an LP.
    /// @dev Canonical v4 sync->transfer->settle. Native (currency0 == address(0)) uses settle{value:} with no
    ///      transfer; in v4 sort order only currency0 can be native, so at most one native settle occurs.
    function _settleOut(Currency currency, uint256 amount) internal {
        poolManager.sync(currency);
        if (currency.isAddressZero()) {
            poolManager.settle{ value: amount }();
        } else {
            currency.transfer(address(poolManager), amount);
            poolManager.settle();
        }
    }

    /// @notice Reclaim `clawbackValue0` of token0-denominated value from a withdrawing LP, settled per currency.
    /// @dev Takes currency0 first (already in token0 units), then converts any remainder to token1 units and
    ///      takes currency1. Each take is clamped to the LP's withdrawn amount for that currency, so the
    ///      caller's PoolManager delta can never go negative. Returns the hook's positive return delta,
    ///      which v4 subtracts from the caller delta and the hook settles via the take() calls.
    function _clawback(PoolKey calldata key, BalanceDelta delta, uint160 exitSqrt, uint256 clawbackValue0)
        internal
        returns (BalanceDelta)
    {
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

        if (take0 > 0) poolManager.take(key.currency0, address(this), take0);
        if (take1 > 0) poolManager.take(key.currency1, address(this), take1);

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

    function _settleSenior(TranchePosition storage pos, PoolTrancheState storage pool, uint160 exitSqrt)
        internal
        returns (uint256 payout, uint256 ilCharged, uint256 positionEarned)
    {
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
        positionEarned = vestedPaid + fixedYieldVested;

        uint256 ilOnPosition =
            ILMath.ilForRange(pos.entrySqrtPriceX96, exitSqrt, pos.tickLower, pos.tickUpper, pos.liquidity);

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

    function _settleJunior(TranchePosition storage pos, PoolTrancheState storage pool, uint160 exitSqrt)
        internal
        returns (uint256 payout, uint256 ilCharged, uint256 positionEarned)
    {
        uint256 ilOnPosition =
            ILMath.ilForRange(pos.entrySqrtPriceX96, exitSqrt, pos.tickLower, pos.tickUpper, pos.liquidity);
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

    /// @notice Roll completed epochs to fully-vested and harvest the latest per-share earnings into the
    ///         current epoch's smoothing bucket (FR-07). Idempotent within a block (NFR-02).
    /// @dev Two-stage pipeline. (1) If an epoch boundary was crossed since the last touch, the prior bucket's
    ///      smoothing window has fully elapsed, so it is moved into `vestedClaimable` (fully vested) and the
    ///      bucket reset. (2) The per-share delta (only ever bumped at closeEpoch) is harvested into the now
    ///      fresh current-epoch bucket and the checkpoint advanced so value crosses exactly once. The current
    ///      bucket vests linearly across the CURRENT epoch (see `_currentBucketVested`); its unvested part is
    ///      forfeited to `juniorReserve` at settlement (FR-14). Earnings flow attribute -> roll -> smooth, a
    ///      single pipeline, so the per-share model and the buckets never double-pay.
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

    function _principalFromDelta(BalanceDelta delta, uint160 sqrtPriceX96) internal pure returns (uint256) {
        int128 a0 = delta.amount0();
        int128 a1 = delta.amount1();
        uint256 v0 = a0 < 0 ? uint256(uint128(-a0)) : uint256(uint128(a0));
        uint256 v1 = a1 < 0 ? uint256(uint128(-a1)) : uint256(uint128(a1));
        return ILMath.valueInToken0(v0, v1, sqrtPriceX96);
    }

    function _deltaValueToken0(BalanceDelta delta, uint160 sqrtPriceX96) internal pure returns (uint256) {
        return _principalFromDelta(delta, sqrtPriceX96);
    }

    function _positionId(address sender, IPoolManager.ModifyLiquidityParams calldata params, bytes calldata hookData)
        internal
        pure
        returns (bytes32)
    {
        (, bytes32 salt) = abi.decode(hookData, (TrancheType, bytes32));
        return keccak256(abi.encode(sender, params.tickLower, params.tickUpper, salt));
    }

    function _syncSeniorObligation(PoolTrancheState storage pool) internal {
        pool.epochSeniorObligation =
            EpochAccounting.seniorObligationForEpoch(pool.seniorTVL, pool.targetAPYBps, pool.smoothingEpochSeconds);
    }

    function _conservationCheck(uint256 principalIn, uint256 payout, uint256 positionEarnedFees) internal pure {
        if (payout > principalIn + positionEarnedFees + ROUNDING_TOLERANCE) {
            revert StratumErrors.ConservationViolation();
        }
    }
}
