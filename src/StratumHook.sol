// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { LPFeeLibrary } from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { BeforeSwapDelta, BeforeSwapDeltaLibrary } from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import { StratumBaseHook } from "./base/StratumBaseHook.sol";
import { TrancheToken } from "./TrancheToken.sol";
import { TrancheType, TranchePosition, PoolTrancheState, PoolInitParams } from "./StratumTypes.sol";
import { IStratumHook } from "./interfaces/IStratumHook.sol";
import { IPeripheral } from "./interfaces/IPeripheral.sol";
import { ILMath } from "./libraries/ILMath.sol";
import { Waterfall } from "./libraries/Waterfall.sol";
import { CoverageRatio } from "./libraries/CoverageRatio.sol";
import { EpochAccounting } from "./libraries/EpochAccounting.sol";
import { StratumErrors } from "./StratumErrors.sol";
import { StratumRateLibrary } from "./libraries/StratumRateLibrary.sol";
import { TrancheSettlementLib } from "./libraries/TrancheSettlementLib.sol";
import { PoolInitLib } from "./libraries/PoolInitLib.sol";

/// @notice Narrow interface for a Stylus volatility source consumed in beforeSwap (BS3). Declared at file
///         scope (interfaces cannot nest in contracts) so the hook needs no concrete Stylus import.
interface IVolatilitySource {
    function getVolatilityOverride(PoolId id) external view returns (uint256 ewma);
}

/// @title StratumHook
/// @notice Uniswap v4 hook implementing senior/junior credit tranching with a priority waterfall.
/// @dev Core works with zero peripherals (NFR-01). IL from pool ticks only (golden rule 2).
contract StratumHook is StratumBaseHook, IStratumHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using LPFeeLibrary for uint24;
    using BalanceDeltaLibrary for BalanceDelta;

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

    /// @notice Per-pool currency identities, recorded at initialize so external reserve crediters (the CPHR's
    ///         cross-chain leg, FR-19) can prove a bridged token actually matches the pool's reserve currency
    ///         before crediting. Defends INV-03: the reserve ledger must only ever count the pool's own tokens.
    mapping(PoolId => Currency) public poolCurrency0;
    mapping(PoolId => Currency) public poolCurrency1;

    /// @notice Per-pool registered contract allowed to credit the token-backed reserve from an external yield
    ///         source (e.g. the EigenLayer LVRAuctionReceiver, FR-23). Set once per pool by the pool creator.
    /// @dev Per-pool + creator-gated (EI1 fix): a global, unauthenticated setter let any address front-run
    ///      deployment, claim crediting rights, and inflate the reserve without backing tokens (INV-03).
    mapping(PoolId => address) public reserveYieldSource;

    /// @notice FR-25 benchmark-rate config per pool: Chainlink feed, spread (bps), and the configured APY floor.
    /// @dev Optional. When the feed is address(0) the senior rate stays the static `targetAPYBps` (golden rule
    ///      2: the benchmark only adjusts the senior TARGET, never IL accounting).
    mapping(PoolId => address) public seniorRateFeed;
    mapping(PoolId => uint256) public seniorRateSpreadBps;
    mapping(PoolId => uint256) public seniorRateFloorBps;
    /// @notice Per-pool hardening for the benchmark read (golden rule 2 stays intact; bounds the senior TARGET).
    /// @dev `seniorRateMaxBenchmarkBps`: a raw benchmark above this is treated as a misconfigured feed (e.g. a
    ///      USD price feed wired where a rate feed was expected) and ignored, so the senior target falls back to
    ///      the floor instead of pinning the hard cap. `seniorRateMaxFeedAge`: per-feed staleness window (set to
    ///      the feed's heartbeat + grace). 0 in either means "use the library default" (MAX_BENCHMARK_BPS / 25h).
    mapping(PoolId => uint256) public seniorRateMaxBenchmarkBps;
    mapping(PoolId => uint256) public seniorRateMaxFeedAge;

    /// @notice Emitted when a pool's senior benchmark feed config changes (NFR-26 observability).
    event SeniorRateFeedConfigured(
        PoolId indexed id, address feed, uint256 spreadBps, uint256 maxBenchmarkBps, uint256 maxFeedAge
    );

    /// @notice Emitted when `refreshSeniorRate` updates a pool's benchmark-driven senior target APY.
    event SeniorRateRefreshed(PoolId indexed id, uint256 newTargetAPYBps);

    /// @notice FR-18: per-pool contract permitted to move reserve between this pool and a sibling pool (the
    ///         CPHR). Creator-gated, like the yield source. address(0) = no cross-pool aggregation.
    mapping(PoolId => address) public reserveRebalancer;

    /// @notice BS3: per-pool Stylus shim supplying an ML volatility override consumed in beforeSwap.
    mapping(PoolId => address) public volatilitySource;

    /// @notice FR-30/FR-31: per-position address authorized to migrate that position's tranche on the owner's
    ///         behalf (e.g. the TrancheIntentRegistry executing an LP's pre-registered conditional intent).
    /// @dev Scoped to a SINGLE position and revocable, like an ERC-20 allowance for migration rights only.
    ///      Default address(0) means only the owner can migrate (core runs unaffected, NFR-01). The approved
    ///      migrator can only flip the tranche of THIS position; it can never move funds or touch other
    ///      positions, and the migration itself is conservation- and coverage-checked (INV-01/03).
    mapping(bytes32 => address) public migratorApproval;

    /// @notice Per-pool block-start price anchor (A-06 sandwich guard). The FIRST pool touch in a block
    ///         (swap or removal) snapshots the pre-action sqrtPrice; senior settlement then sizes IL and the
    ///         make-whole gap against BOTH the exit spot and this anchor, taking the senior-conservative side.
    ///         An atomic sandwich (swap -> withdraw -> swap back) therefore cannot fabricate IL or a payout
    ///         gap, because the anchor predates the attacker's first swap. Cross-block manipulation remains
    ///         possible but carries real inventory and arbitrage risk for a full block (documented residual).
    struct PriceAnchor {
        uint160 sqrtPriceX96;
        uint96 blockNumber;
    }

    mapping(PoolId => PriceAnchor) public blockStartAnchor;

    /// @notice A-15: per-pool protocol fee share (token0-denominated accounting value). When realization is
    ///         OFF (default) it is carved out of each swap's fee BEFORE the epoch accumulator so it can never
    ///         inflate the junior surplus, and stays an observability/claims ledger. When realization is ON
    ///         (D-1) it accumulates the token0 VALUE of the fees actually realized as real tokens below.
    mapping(PoolId => uint256) public protocolFeesAccrued;

    /// @notice D-1: per-pool opt-in for realizing the protocol fee as a real-token swap surcharge via the
    ///         `afterSwap` return delta. Creator-gated. Default false keeps the legacy accounting-only behavior
    ///         (and a zero afterSwap delta), so a fresh deployment is indistinguishable from the pre-D-1 hook
    ///         until a pool creator explicitly opts in. Under this model the protocol fee becomes an ADDITIVE
    ///         surcharge on the swap (not a carve-out of the LP fee): junior/senior keep the full LP fee and the
    ///         protocol is paid from real tokens taken off the swap's output leg.
    mapping(PoolId => bool) public protocolFeeRealization;

    /// @notice D-1: token-backed protocol-fee reserve (real tokens held by the hook), credited by the
    ///         `afterSwap` surcharge take and drawn by `collectProtocolFees`. Kept strictly separate from the
    ///         junior buffer (`reserve0`/`reserve1`) and from `juniorReserve` (INV-05): protocol fees are the
    ///         protocol's, never collateral for senior make-whole.
    mapping(PoolId => uint256) public protocolFeeReserve0;
    mapping(PoolId => uint256) public protocolFeeReserve1;

    /// @notice Emitted when a pool creator toggles protocol-fee realization (D-1 observability).
    event ProtocolFeeRealizationSet(PoolId indexed id, bool enabled);

    /// @notice Emitted when an `afterSwap` realizes protocol fees as real tokens (D-1). Re-declared in
    ///         `TrancheSettlementLib` with an identical signature so the emitted topic matches.
    event ProtocolFeeRealized(PoolId indexed poolId, uint256 amount0, uint256 amount1, uint256 value0);

    /// @notice Emitted when a pool creator withdraws the token-backed protocol-fee reserve (D-1).
    event ProtocolFeesCollected(PoolId indexed id, address indexed to, uint256 amount0, uint256 amount1);

    /// @dev The hook must hold native ETH to settle a native make-whole leg (currency0 == address(0)).
    receive() external payable { }

    uint256 public constant ROUNDING_TOLERANCE = 100;

    /// @dev Gas stipend forwarded to a peripheral so it can never gas-grief core settlement (NFR-01). A
    ///      safety bound, not a pool parameter, so it lives here rather than in PoolTrancheState.
    uint256 public constant PERIPHERAL_GAS_STIPEND = 150_000;

    /// @dev kind() discriminator for the Brevis verifier shim peripheral (DESIGN section 11).
    bytes32 public constant BREVIS_KIND = keccak256("stratum.brevis.verifier");

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
                // D-1: enabled so afterSwap can realize the protocol fee as a real-token swap surcharge
                // (return-delta). Opt-in PER POOL via `setProtocolFeeRealization`; default off => afterSwap
                // returns a zero delta and behaves byte-for-byte as before. Enabling this flag changes the
                // mined hook address, so it ships as a redeploy: existing deployments are immutable and
                // unaffected; new deployments mine the new address (see test/utils/StratumFlags.sol).
                afterSwapReturnDelta: true,
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

    /// @notice One-time, per-pool wiring of the external reserve yield source (e.g. LVRAuctionReceiver, FR-23).
    /// @dev Gated to the pool creator (the address that called `preparePool`), the natural trust anchor for a
    ///      pool. Set once per pool, then locked. If never set, `creditReserve` reverts and the core runs
    ///      unaffected (golden rule 1 / NFR-01). Does not change the hook address.
    /// @param id Pool to configure.
    /// @param source The contract permitted to credit this pool's reserve.
    function setReserveYieldSource(PoolId id, address source) external {
        if (msg.sender != poolCreators[id]) revert StratumErrors.Unauthorized();
        if (reserveYieldSource[id] != address(0)) revert StratumErrors.Unauthorized();
        reserveYieldSource[id] = source;
    }

    /// @notice Credit the token-backed reserve from the pool's registered yield source (LVR proceeds, FR-23).
    /// @dev The source MUST have already transferred `amount0`/`amount1` of the pool currencies to this hook
    ///      before calling. Gated to the pool's registered source so the ledger can never be inflated without
    ///      backing tokens (INV-03). Augments the real-token reserve only, never `juniorReserve` (INV-05).
    /// @param id Pool to credit.
    /// @param amount0 token0 added to the reserve (already transferred in).
    /// @param amount1 token1 added to the reserve (already transferred in).
    function creditReserve(PoolId id, uint256 amount0, uint256 amount1) external {
        // Accepted from the pool's registered yield source (LVR proceeds, FR-23) OR its registered rebalancer
        // (cross-chain bridged reserve via the CPHR, FR-19). Both are creator-gated registrations.
        if (msg.sender != reserveYieldSource[id] && msg.sender != reserveRebalancer[id]) {
            revert StratumErrors.Unauthorized();
        }
        reserve0[id] += amount0;
        reserve1[id] += amount1;
        emit ReserveFunded(id, amount0, amount1);
    }

    /// @notice Configure the Chainlink benchmark feed + spread + bounds for a pool's senior rate (FR-25,
    ///         creator-gated).
    /// @dev Optional. The effective senior APY becomes `max(configuredFloor, benchmark + spread)`, applied by
    ///      `refreshSeniorRate`. The feed is read only for the senior TARGET, never IL accounting (golden rule 2).
    /// @param id              Pool to configure.
    /// @param feed            Chainlink AggregatorV3 RATE feed (bps-scaled). Pass a *rate* feed, not a price feed.
    /// @param spreadBps       Spread added on top of the benchmark rate (bps).
    /// @param maxBenchmarkBps Sane ceiling on the raw benchmark; a value above this is ignored (likely a price
    ///                        feed wired by mistake). Pass 0 for the library default (`MAX_BENCHMARK_BPS`).
    /// @param maxFeedAge      Per-feed staleness window in seconds (the feed's heartbeat + grace). Pass 0 for 25h.
    function setSeniorRateFeed(PoolId id, address feed, uint256 spreadBps, uint256 maxBenchmarkBps, uint256 maxFeedAge)
        external
    {
        if (msg.sender != poolCreators[id]) revert StratumErrors.Unauthorized();
        seniorRateFeed[id] = feed;
        seniorRateSpreadBps[id] = spreadBps;
        seniorRateMaxBenchmarkBps[id] = maxBenchmarkBps;
        seniorRateMaxFeedAge[id] = maxFeedAge;
        emit SeniorRateFeedConfigured(id, feed, spreadBps, maxBenchmarkBps, maxFeedAge);
    }

    /// @notice Refresh a pool's senior `targetAPYBps` from its Chainlink benchmark feed (FR-25).
    /// @dev Permissionless: the value is bounded by `StratumRateLibrary` (stale/zero feed -> falls back to the
    ///      configured floor; capped at MAX_BENCHMARK_BPS), and is computed from the immutable floor so it
    ///      cannot ratchet. No-op if no feed is configured. Resyncs the epoch obligation to the new rate.
    function refreshSeniorRate(PoolId id) external {
        PoolTrancheState storage pool = poolStates[id];
        if (!pool.initialized) revert StratumErrors.PoolNotInitialized();
        address feed = seniorRateFeed[id];
        if (feed == address(0)) return;
        pool.targetAPYBps = StratumRateLibrary.effectiveTargetAPYBps(
            seniorRateFloorBps[id],
            seniorRateSpreadBps[id],
            feed,
            seniorRateMaxBenchmarkBps[id],
            seniorRateMaxFeedAge[id]
        );
        _syncSeniorObligation(pool);
        emit SeniorRateRefreshed(id, pool.targetAPYBps);
    }

    /// @notice Register the per-pool reserve rebalancer (the CPHR) permitted to draw this pool's reserve (FR-18).
    /// @dev Creator-gated, one-time. address(0) (default) means the pool does not participate in cross-pool
    ///      aggregation. Gating here is the authoritative fund-movement control (defense-in-depth vs CP5).
    function setReserveRebalancer(PoolId id, address rebalancer) external {
        if (msg.sender != poolCreators[id]) revert StratumErrors.Unauthorized();
        if (reserveRebalancer[id] != address(0)) revert StratumErrors.Unauthorized();
        reserveRebalancer[id] = rebalancer;
    }

    /// @notice Move real-token reserve from a donor pool to a recipient pool on this hook (FR-18 aggregation).
    /// @dev Both reserves live on this hook, so this is a ledger move (no token transfer): debit `from`, credit
    ///      `to`. Gated to the DONOR pool's registered rebalancer (its creator's consent). Total reserve across
    ///      pools is conserved (INV-03); `juniorReserve` is untouched (INV-05). Reverts if the donor lacks the
    ///      requested amounts (no negative reserves).
    /// @param from Donor pool (reserve drawn from).
    /// @param to Recipient pool (reserve credited to).
    /// @param amount0 token0 reserve to move.
    /// @param amount1 token1 reserve to move.
    function rebalanceReserve(PoolId from, PoolId to, uint256 amount0, uint256 amount1) external {
        if (msg.sender != reserveRebalancer[from]) revert StratumErrors.Unauthorized();
        if (amount0 > reserve0[from] || amount1 > reserve1[from]) revert StratumErrors.ConservationViolation();
        reserve0[from] -= amount0;
        reserve1[from] -= amount1;
        reserve0[to] += amount0;
        reserve1[to] += amount1;
        emit ReserveRebalanced(from, to, amount0, amount1);
    }

    /// @notice Batched form of `rebalanceReserve` (FR-18, Fiet batched-execution pattern): apply N cross-pool
    ///         reserve moves in a single transaction so repeated cross-chain rebalance signals net into one
    ///         settlement instead of N separate hedges.
    /// @dev Each move carries the SAME guarantees as the single-move path: independently gated to the donor
    ///      pool's registered rebalancer (so a caller can only move pools it is authorized for) and bounded by
    ///      the donor's held reserve (no negative reserves). Total reserve across all pools is conserved
    ///      (INV-03), `juniorReserve` is untouched (INV-05). Reverts atomically on any invalid move, so a
    ///      partial batch can never leave the ledger half-applied.
    ///      Each step checks the LIVE (mid-batch) balance, so a later move may draw on reserve credited by an
    ///      earlier move in the same batch (an intentional A->B->C routing chain). This is sound: every step is
    ///      still donor-gated and bounded, and the net effect across the batch conserves total reserve (audit F5).
    /// @param from Donor pools (reserve drawn from), one per move.
    /// @param to Recipient pools (reserve credited to), one per move.
    /// @param amount0 token0 amounts to move, one per move.
    /// @param amount1 token1 amounts to move, one per move.
    function batchRebalanceReserve(
        PoolId[] calldata from,
        PoolId[] calldata to,
        uint256[] calldata amount0,
        uint256[] calldata amount1
    ) external {
        uint256 n = from.length;
        if (to.length != n || amount0.length != n || amount1.length != n) revert StratumErrors.LengthMismatch();
        for (uint256 i = 0; i < n; ++i) {
            if (msg.sender != reserveRebalancer[from[i]]) revert StratumErrors.Unauthorized();
            if (amount0[i] > reserve0[from[i]] || amount1[i] > reserve1[from[i]]) {
                revert StratumErrors.ConservationViolation();
            }
            reserve0[from[i]] -= amount0[i];
            reserve1[from[i]] -= amount1[i];
            reserve0[to[i]] += amount0[i];
            reserve1[to[i]] += amount1[i];
            emit ReserveRebalanced(from[i], to[i], amount0[i], amount1[i]);
        }
    }

    /// @notice Register the per-pool Stylus volatility source consumed in beforeSwap (BS3, creator-gated).
    /// @dev Optional. address(0) (default) keeps beforeSwap on the pure on-chain EWMA (no hot-path call).
    function setVolatilitySource(PoolId id, address source) external {
        if (msg.sender != poolCreators[id]) revert StratumErrors.Unauthorized();
        volatilitySource[id] = source;
    }

    /// @notice D-1: opt this pool into (or out of) realizing the protocol fee as a real-token swap surcharge.
    /// @dev Creator-gated, toggleable. Default false preserves the legacy accounting-only ledger AND a zero
    ///      `afterSwap` delta, so the hook is behaviorally identical to the pre-D-1 build until a creator opts
    ///      in. Turning it on changes the fee model for THIS pool only: the protocol fee becomes an additive
    ///      surcharge taken from the swap's output leg into `protocolFeeReserve0/1`, and junior/senior keep the
    ///      full LP fee. Requires the deployed hook to carry the `AFTER_SWAP_RETURNS_DELTA` permission bit
    ///      (true on this build); on a hook mined without it, enabling realization would be a no-op delta, so
    ///      the toggle is only meaningful on a D-1 deployment.
    /// @param id Pool to configure.
    /// @param enabled Whether to realize protocol fees as real tokens for this pool.
    function setProtocolFeeRealization(PoolId id, bool enabled) external {
        if (msg.sender != poolCreators[id]) revert StratumErrors.Unauthorized();
        protocolFeeRealization[id] = enabled;
        emit ProtocolFeeRealizationSet(id, enabled);
    }

    /// @notice D-1: withdraw the token-backed protocol-fee reserve accrued for a pool to `to`, in real tokens.
    /// @dev Creator-gated. Pays the held `protocolFeeReserve0/1` (real tokens the hook took during swaps) and
    ///      zeroes the ledger. This reserve is strictly the protocol's: it is never `juniorReserve` and never
    ///      the token-backed junior buffer (`reserve0`/`reserve1`), so a collection can never touch senior
    ///      make-whole collateral or junior IL absorption (INV-05). Currency transfer handles native + ERC20.
    /// @param id Pool to collect from.
    /// @param to Recipient of the protocol fees.
    /// @return amount0 token0 paid out.
    /// @return amount1 token1 paid out.
    function collectProtocolFees(PoolId id, address to) external returns (uint256 amount0, uint256 amount1) {
        if (msg.sender != poolCreators[id]) revert StratumErrors.Unauthorized();
        amount0 = protocolFeeReserve0[id];
        amount1 = protocolFeeReserve1[id];
        protocolFeeReserve0[id] = 0;
        protocolFeeReserve1[id] = 0;
        if (amount0 > 0) poolCurrency0[id].transfer(to, amount0);
        if (amount1 > 0) poolCurrency1[id].transfer(to, amount1);
        emit ProtocolFeesCollected(id, to, amount0, amount1);
    }

    /// @notice D-1: read the token-backed protocol-fee reserve held for a pool.
    /// @param id Pool to query.
    /// @return p0 token0 protocol-fee reserve.
    /// @return p1 token1 protocol-fee reserve.
    function protocolFeeReserveBalances(PoolId id) external view returns (uint256 p0, uint256 p1) {
        return (protocolFeeReserve0[id], protocolFeeReserve1[id]);
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
        TrancheSettlementLib.harvestAndVest(pos, pool);
        (uint256 curVested,) = TrancheSettlementLib.currentBucketVested(pos, pool);
        return pos.vestedClaimable + curVested;
    }

    /// @notice Authorize (or revoke) an address to migrate this position's tranche on the owner's behalf (FR-30).
    /// @dev Owner-gated, per position, revocable (pass address(0) to revoke). The approved migrator (typically
    ///      the TrancheIntentRegistry running a pre-registered conditional intent) can ONLY flip this position's
    ///      tranche through the conservation/coverage-checked `migrateTranchePosition`; it can move no funds and
    ///      touch no other position. This is the LP's explicit, narrow consent for keeper-free automation.
    /// @param positionId Position to delegate migration rights for.
    /// @param migrator Address allowed to call `migrateTranchePosition` for this position; address(0) revokes.
    function approveMigrator(bytes32 positionId, address migrator) external {
        if (positions[positionId].owner != msg.sender) revert StratumErrors.NotPositionOwner();
        migratorApproval[positionId] = migrator;
        emit MigratorApproved(positionId, msg.sender, migrator);
    }

    /// @notice Reclassify a position between the senior and junior tranches in place (FR-31). The underlying
    ///         Uniswap liquidity does not move and no real tokens are transferred: only STRATUM's senior/junior
    ///         overlay flips. Accrued IL is realized under the CURRENT tranche before the clock resets, so a
    ///         migration can never shed already-incurred IL onto the junior buffer (golden rule 3).
    /// @dev Callable by the position owner or its approved migrator (FR-30). Effects-before-interactions: all
    ///      accounting (IL realization, buffer/TVL updates, coverage enforcement) completes before the only
    ///      external calls (receipt-token burn/mint on the hook-deployed, callback-free solmate TrancheTokens),
    ///      so no reentrancy guard is required. A junior->senior flip is enforced against the coverage floor
    ///      (INV-01); a senior->junior flip only raises coverage. Conservation (INV-03) holds by construction:
    ///      the carried principal is never greater than the old principal.
    /// @param positionId Position to migrate.
    /// @param newTranche Destination tranche (must differ from the current one).
    /// @return carriedPrincipal Principal re-registered in the destination tranche after IL realization.
    function migrateTranchePosition(bytes32 positionId, TrancheType newTranche)
        external
        returns (uint256 carriedPrincipal)
    {
        TranchePosition storage pos = positions[positionId];
        address owner = pos.owner;
        if (owner == address(0)) revert StratumErrors.PositionNotFound();
        if (msg.sender != owner && msg.sender != migratorApproval[positionId]) {
            revert StratumErrors.Unauthorized();
        }

        TrancheType oldTranche = pos.tranche;
        if (oldTranche == newTranche) revert StratumErrors.MigrationToSameTranche();

        PoolId id = positionPool[positionId];
        PoolTrancheState storage pool = poolStates[id];
        if (!pool.initialized) revert StratumErrors.PoolNotInitialized();

        uint256 oldPrincipal = pos.principalValue;
        (uint160 currentSqrt,,,) = poolManager.getSlot0(id);
        // R2-01: anchor the migration pricing to the block-start price so a same-block sandwich can neither
        // shed accrued junior IL before a junior->senior flip nor inflate the buffer debit of a senior flip.
        uint160 anchorSqrt = _touchBlockAnchor(id);

        // Heavy lifting (IL realization under the old tranche, field resets) lives in the settlement library to
        // keep the hook under EIP-170. It mutates `pos` and may debit `juniorReserve` (INV-05-sanctioned).
        uint256 realizedIL;
        (carriedPrincipal, realizedIL) =
            TrancheSettlementLib.migratePosition(pos, pool, currentSqrt, anchorSqrt, newTranche);

        // Move the principal across the TVL ledgers. Aggregate seniorTVL+juniorTVL drops only by IL realized
        // against principal (junior path) - the buffer absorbed the senior path - so no value is conjured.
        if (oldTranche == TrancheType.SENIOR) {
            pool.seniorTVL = pool.seniorTVL > oldPrincipal ? pool.seniorTVL - oldPrincipal : 0;
        } else {
            pool.juniorTVL = pool.juniorTVL > oldPrincipal ? pool.juniorTVL - oldPrincipal : 0;
        }
        if (newTranche == TrancheType.SENIOR) {
            pool.seniorTVL += carriedPrincipal;
            // INV-01: a junior->senior flip lowers coverage; it must not breach the floor.
            if (pool.seniorTVL > 0) {
                uint16 ratio = CoverageRatio.ratioBps(pool.juniorTVL, pool.seniorTVL);
                if (ratio < pool.minCoverageRatioBps) revert StratumErrors.CoverageRatioBelowFloor();
            }
        } else {
            pool.juniorTVL += carriedPrincipal;
        }
        _syncSeniorObligation(pool);

        // INV-03: migration never creates value (carried <= old + tolerance).
        TrancheSettlementLib.conservationCheck(oldPrincipal, carriedPrincipal, 0);

        // Interactions last (CEI): retire the old receipt, issue the new one for the carried principal.
        address oldToken = oldTranche == TrancheType.SENIOR ? pool.seniorToken : pool.juniorToken;
        address newToken = newTranche == TrancheType.SENIOR ? pool.seniorToken : pool.juniorToken;
        TrancheToken(oldToken).burn(owner, oldPrincipal);
        if (carriedPrincipal > 0) TrancheToken(newToken).mint(owner, carriedPrincipal);

        emit PositionMigrated(id, positionId, owner, oldTranche, newTranche, carriedPrincipal, realizedIL);
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
            // H-02: the epoch surplus is the junior tranche's earnings and is distributed to junior LPs via the
            // per-share accumulator below. It must NOT also be added to `juniorReserve`: that abstract buffer
            // backs senior IL-absorption / shortfall make-whole, so crediting the same surplus to both ledgers
            // let one unit of fees simultaneously pay junior earnings AND authorize senior make-whole, breaking
            // conservation (INV-03/INV-05). The buffer remains funded by forfeited unvested fees (FR-14) and by
            // the real-token IL clawback (reserve0/reserve1); junior keeps its leveraged surplus via per-share.
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
    function beforeInitialize(address sender, PoolKey calldata key, uint160)
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        PoolId id = key.toId();
        PoolInitParams memory params = pendingPoolInit[id];
        if (params.smoothingEpochSeconds == 0) revert StratumErrors.PoolNotInitialized();
        // A-05: only the pool creator (the preparePool caller) may consume the prepared parameters. Without
        // this, a third party could front-run `PoolManager.initialize` and choose the initial sqrtPrice for a
        // pool whose tranche parameters the creator staged, skewing entry IL anchors from block one.
        if (sender != poolCreators[id]) revert StratumErrors.Unauthorized();
        delete pendingPoolInit[id];

        // Record the pool's currency identities so cross-chain reserve credits can be token-validated (INV-03).
        poolCurrency0[id] = key.currency0;
        poolCurrency1[id] = key.currency1;

        // Validation, tranche-token deployment, and the initial state write live in an external library
        // (delegatecall) so the TrancheToken creation bytecode does not count against this contract's
        // EIP-170 deployed-size budget. Behavior is byte-for-byte identical to the prior inline version.
        PoolInitLib.initializePool(poolStates, id, params, address(this));
        seniorRateFloorBps[id] = params.targetAPYBps; // FR-25: the configured APY is the benchmark floor

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

        uint256 principalValue = TrancheSettlementLib.principalFromDelta(delta, sqrtPriceX96);
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

        _signalCoverageStress(id, pool); // notify-only; runs after intake enforcement already passed

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
        // A-06: snapshot the pre-swap price as the block-start anchor if this is the pool's first touch this
        // block. A sandwich front-run lands here FIRST, so the anchor it records is the pre-attack price.
        _touchBlockAnchor(id);
        uint16 ratio = CoverageRatio.ratioBps(pool.juniorTVL, pool.seniorTVL);
        uint16 stress = CoverageRatio.stressLevel(ratio, pool.minCoverageRatioBps);
        // BS3: a registered Stylus shim may supply a forward (ML) volatility estimate. It can only RAISE the
        // volatility input (never lower it), so it can only widen the fee toward maxFeeBps - which is already
        // clamped by dynamicFeeBps. No source registered -> no hot-path call (core-only is untouched).
        uint256 vol = pool.volatilityEWMA;
        address vsrc = volatilitySource[id];
        if (vsrc != address(0)) {
            try IVolatilitySource(vsrc).getVolatilityOverride(id) returns (uint256 ov) {
                if (ov > vol) vol = ov;
            } catch { }
        }
        uint16 feeBps = Waterfall.dynamicFeeBps(pool.baseFeeBps, pool.minFeeBps, pool.maxFeeBps, vol, stress);
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
        BalanceDelta swapDelta,
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
        // A-04: `amountSpecified` is denominated in the SPECIFIED currency, which is token0 only when
        // (exactIn && zeroForOne) or (exactOut && oneForZero). Every downstream ledger this fee feeds
        // (epochAccumulatedFees, senior obligation funding, per-share accumulators, settlement payouts) is
        // token0-denominated, so a token1-specified swap must be converted at the post-swap price before
        // booking. Without this, asymmetric flow drifts the waterfall by the pool price (INV-03/INV-04).
        bool specifiedIsToken0 = (swapParams.amountSpecified < 0) == swapParams.zeroForOne;
        if (!specifiedIsToken0 && feeAmount > 0) {
            feeAmount = ILMath.valueInToken0(0, feeAmount, sqrtPriceX96);
        }
        if (feeAmount == 0 && swapAmount > 0 && feeBps > 0) feeAmount = 1;

        int128 hookDelta;
        if (feeAmount > 0) {
            uint16 ratio = CoverageRatio.ratioBps(pool.juniorTVL, pool.seniorTVL);
            uint16 stress = CoverageRatio.stressLevel(ratio, pool.minCoverageRatioBps);
            Waterfall.Split memory split =
                Waterfall.splitFee(feeAmount, pool.protocolFeeBps, pool.volatilityEWMA, stress);

            if (protocolFeeRealization[id] && split.protocolPortion > 0) {
                // D-1: under realization the protocol fee is an ADDITIVE real-token surcharge, not a carve-out.
                // Junior/senior keep the FULL LP fee in the accumulator; the protocol slice is taken off the
                // swap's output leg into the token-backed reserve via the return delta. The library returns the
                // int128 to hand back to v4 (0 if the output leg can't absorb it, in which case the protocol
                // simply forgoes this swap - junior keeps it - and the swap is never disturbed).
                pool.epochAccumulatedFees += feeAmount;
                uint256 realizedValue0;
                (hookDelta, realizedValue0) = TrancheSettlementLib.realizeProtocolSurcharge(
                    poolManager,
                    protocolFeeReserve0,
                    protocolFeeReserve1,
                    key,
                    swapDelta,
                    specifiedIsToken0,
                    split.protocolPortion,
                    sqrtPriceX96
                );
                if (realizedValue0 > 0) protocolFeesAccrued[id] += realizedValue0;
            } else {
                // A-15 (default): the protocol's share is carved out BEFORE the epoch accumulator. Previously it
                // was computed but never deducted, so closeEpoch folded it into the junior surplus and
                // protocolFeeBps silently did nothing. It accrues to an observable per-pool claims ledger
                // instead of junior earnings; afterSwap returns a zero delta (legacy behavior).
                pool.epochAccumulatedFees += feeAmount - split.protocolPortion;
                if (split.protocolPortion > 0) protocolFeesAccrued[id] += split.protocolPortion;
            }

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

        return (IHooks.afterSwap.selector, hookDelta);
    }

    /// @inheritdoc IHooks
    /// @dev When the Brevis peripheral is enabled: emits `BrevisProofRequested` so the off-chain
    ///      Brevis prover can prepare a ZK proof for the position's holding window before
    ///      `afterRemoveLiquidity` runs (FR-21, DESIGN section 3).  The emission is purely
    ///      informational; the hook never blocks on proof availability (FR-22).
    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4) {
        bytes32 positionId = _positionId(sender, params, hookData);
        TranchePosition storage pos = positions[positionId];
        if (pos.owner == address(0)) revert StratumErrors.PositionNotFound();
        PoolId id = key.toId();
        PoolTrancheState storage pool = poolStates[id];
        // A-06: ensure the block-start anchor exists before the removal executes, so a removal that is the
        // pool's first touch this block anchors to the (unmanipulated-in-this-block) current price.
        _touchBlockAnchor(id);
        // Harvest + vest unconditionally so partial-epoch earnings are captured before settlement.
        TrancheSettlementLib.harvestAndVest(pos, pool);

        // If a Brevis peripheral is registered and enabled, signal the off-chain prover.
        // We use a gas-bounded try-catch so a misbehaving registry can never block withdrawal.
        if (TrancheSettlementLib.isBrevisEnabled(pool.peripheralRegistry)) {
            emit BrevisProofRequested(positionId, pos.entryEpoch, pool.currentEpoch);
        }

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

        // H-03: settlement is sized to the FULL recorded position (principal/IL/payout) and deletes the
        // record, so it is only correct for a full close. v4 permits partial removal; allowing it here would
        // pay a full senior make-whole from the reserve while returning only a fraction of liquidity, and would
        // orphan the un-removed liquidity. Require the removal to retire the entire position.
        uint128 removed = uint128(uint256(params.liquidityDelta < 0 ? -params.liquidityDelta : params.liquidityDelta));
        if (removed != pos.liquidity) revert StratumErrors.PartialRemovalNotSupported();

        (uint160 exitSqrt,,,) = poolManager.getSlot0(id);
        // A-06: block-start anchor recorded in beforeRemoveLiquidity (or by the block's first swap). Senior
        // settlement charges min(IL at exit, IL at anchor) and sizes make-whole against the higher-valued
        // delta, so an atomic sandwich cannot fabricate a reserve draw.
        uint160 anchorSqrt = blockStartAnchor[id].sqrtPriceX96;
        uint256 payout;
        uint256 ilCharged;
        uint256 positionEarned;
        TrancheType tranche = pos.tranche; // capture before `delete pos` (needed for the make-whole branch)

        // Attempt to retrieve Brevis-proven values for this position (FR-21).  On any failure
        // (peripheral disabled, not proven, call reverts) the flag stays false and the hook falls
        // back to approximate on-chain accounting -- satisfying FR-22 and keeping NFR-01 green.
        (bool twProven, uint256 provenContribution) =
            TrancheSettlementLib.queryBrevisContribution(pool.peripheralRegistry, positionId);
        (bool ilProven, uint256 provenIL) = TrancheSettlementLib.queryBrevisIL(pool.peripheralRegistry, positionId);

        if (pos.tranche == TrancheType.SENIOR) {
            (payout, ilCharged, positionEarned) = TrancheSettlementLib.settleSenior(pos, pool, exitSqrt, anchorSqrt);
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
            if (twProven && ilProven) {
                // Brevis path (FR-21): use ZK-proven contribution and IL attribution to refine the split.
                // The proof is CLAMPED to an independent on-chain ceiling inside _settleJuniorWithProof so it
                // can never inflate the payout (BS1/BS2), keeping INV-03 sound even with a stub verifier.
                (payout, ilCharged, positionEarned) = TrancheSettlementLib.settleJuniorWithProof(
                    pos, pool, provenContribution, provenIL, exitSqrt, anchorSqrt
                );
            } else {
                // Fallback path (FR-22): approximate on-chain accounting, identical to core-only.
                (payout, ilCharged, positionEarned) = TrancheSettlementLib.settleJunior(pos, pool, exitSqrt, anchorSqrt);
            }
            pool.juniorTVL = newJuniorTVL;
            TrancheToken(pool.juniorToken).burn(sender, pos.principalValue);
            // A-18: a junior withdrawal moves coverage toward the floor exactly like a senior deposit does,
            // but only the deposit path signalled stress. Signal here too so peripherals (CoverageDefender,
            // CPHR) can begin remediation before the next intake hits the hard floor.
            _signalCoverageStress(id, pool);
        }

        TrancheSettlementLib.conservationCheck(pos.principalValue, payout, positionEarned);
        emit TrancheSettled(id, positionId, sender, pos.tranche, payout, ilCharged);
        delete positions[positionId];
        positionPool[positionId] = PoolId.wrap(bytes32(0));
        // Clear any migration delegation so a later position re-created under the same id (same owner, tick
        // range and salt) cannot inherit a stale approval the LP never granted for the new deposit (audit M-01).
        delete migratorApproval[positionId];

        uint256 received = TrancheSettlementLib.deltaValueToken0(delta, exitSqrt);

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
            return (
                IHooks.afterRemoveLiquidity.selector,
                TrancheSettlementLib.clawback(poolManager, reserve0, reserve1, key, delta, exitSqrt, received - payout)
            );
        }
        if (tranche == TrancheType.SENIOR && payout > received) {
            // A-06: size the make-whole gap against the HIGHER of the delta valued at exit vs at the
            // block-start anchor. A sandwich that crashes the exit price deflates `received` (inflating the
            // reserve draw); valuing the same withdrawn tokens at the pre-attack anchor neutralizes that leg.
            uint256 receivedGuarded = TrancheSettlementLib.deltaValueToken0Guarded(delta, exitSqrt, anchorSqrt);
            if (payout > receivedGuarded) {
                return (
                    IHooks.afterRemoveLiquidity.selector,
                    TrancheSettlementLib.makeWhole(
                        poolManager, reserve0, reserve1, key, id, payout - receivedGuarded, exitSqrt
                    )
                );
            }
        }
        return (IHooks.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /// @dev Record (or read) the pool's block-start price anchor (A-06). The first call in a block snapshots
    ///      the CURRENT pool price before the caller's action executes, so a same-block sandwich front-leg
    ///      can never poison the anchor used by senior settlement later in the block.
    function _touchBlockAnchor(PoolId id) internal returns (uint160 anchorSqrt) {
        PriceAnchor storage a = blockStartAnchor[id];
        if (a.blockNumber != uint96(block.number)) {
            (uint160 cur,,,) = poolManager.getSlot0(id);
            a.sqrtPriceX96 = cur;
            a.blockNumber = uint96(block.number);
            return cur;
        }
        return a.sqrtPriceX96;
    }

    /// @dev Emit + dispatch a coverage-stress signal when stress exceeds the notification threshold.
    ///      Shared by senior intake and junior withdrawal (A-18) so both coverage-moving paths signal.
    function _signalCoverageStress(PoolId id, PoolTrancheState storage pool) internal {
        uint16 ratio = CoverageRatio.ratioBps(pool.juniorTVL, pool.seniorTVL);
        uint16 stress = CoverageRatio.stressLevel(ratio, pool.minCoverageRatioBps);
        if (stress > 5000) {
            emit CoverageStress(id, ratio, stress);
            _notifyCoverageStress(id, ratio); // notify-only; never blocks the core path
        }
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
}
