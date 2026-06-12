// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { IERC20 } from "@uniswap/v4-core/lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@uniswap/v4-core/lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { IPeripheral } from "../../interfaces/IPeripheral.sol";
import { IStratumHook } from "../../interfaces/IStratumHook.sol";
import { PoolTrancheState } from "../../StratumTypes.sol";
import { IMatchAttestation } from "./IMatchAttestation.sol";
import { LVRProceedsValidator } from "./LVRProceedsValidator.sol";

// ---------------------------------------------------------------------------
// Narrow interfaces placed at file scope (nested interface is not valid Solidity)
// ---------------------------------------------------------------------------

/// @notice Narrow interface exposing only the reserve credit function on the hook.
interface IStratumHookReserveCredit {
    function reserve0(PoolId id) external view returns (uint256);
    function reserve1(PoolId id) external view returns (uint256);
    function creditReserve(PoolId id, uint256 amount0, uint256 amount1) external;
}

/// @notice Minimal Chainlink AggregatorV3 surface used to value proceeds independently of the pool price.
interface IAggregatorV3 {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function decimals() external view returns (uint8);
}

/// @title LVRAuctionReceiver
/// @notice EigenLayer peripheral (kind == "EIGEN") that receives LVR auction proceeds and routes them as
///         supplementary yield into the STRATUM senior tranche (FR-23, DESIGN section 12).
///
/// @dev LVR (Loss-Versus-Rebalancing) auction mechanics:
///      AVS operators bid for the right to execute the first transaction in a block. The winning bid is paid
///      to this contract. Those proceeds are yield uncorrelated with swap volume, routing directly to the
///      senior tranche rather than going to validators. This strengthens the senior fixed yield guarantee,
///      particularly under low swap-fee regimes.
///
///      Token flow:
///      1. `receiveYield(poolId, amount0, amount1)` is called by a registered operator (gated by
///         `IMatchAttestation.isAttested`) after an auction settles.
///      2. The contract transfers `amount0` of token0 and `amount1` of token1 from the caller (caller must
///         have pre-approved this contract) and credits the hook's `reserve0`/`reserve1` token-backed reserve.
///      3. The hook emits `ReserveFunded`; when a senior LP withdraws, the make-whole path draws from this
///         reserve. The junior reserve accumulator (`PoolTrancheState.juniorReserve`) is NOT modified here;
///         only the token-backed reserve is augmented. This is an explicitly sanctioned INV-05 exception:
///         the auction proceeds are real tokens, not waterfall accounting entries.
///
///      Security:
///      - Caller must pass an `attestationHash` whose quorum is confirmed in the attestation contract.
///        This prevents arbitrary addresses from diluting or manipulating the reserve with fake yield.
///      - Optional proceeds bound (defense-in-depth, see `setProceedsBound`): when configured, a routing whose
///        USD value (Chainlink-priced) exceeds a fraction of the pool's on-chain TVL is rejected. WHILE the
///        prices are fresh this caps over-crediting even by a compromised quorum (per call, or cumulatively per
///        rolling window). Under a Chainlink staleness window the bound cannot be evaluated and either reverts
///        (`failClosedOnStale`) or degrades to attestation-only - it is not an unconditional guarantee.
///      - INV-03: yield-in increases the reserve; it does not create yield out of nothing. Conservation is
///        maintained because the new tokens come from external auction proceeds (genuine external inflow).
///      - INV-05: the junior waterfall accumulator is untouched; this goes to the real-token reserve only.
contract LVRAuctionReceiver is IPeripheral {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------

    /// @notice Recorded per pool: cumulative LVR yield routed to date.
    struct YieldRecord {
        uint256 cumulativeToken0;
        uint256 cumulativeToken1;
        uint256 lastRouted;
    }

    // -------------------------------------------------------------------------
    // Immutables
    // -------------------------------------------------------------------------

    IStratumHook public immutable stratumHook;
    address public immutable admin;

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    IMatchAttestation public matchAttestation;
    bool public enabled;

    /// @notice Cumulative LVR yield per pool for observability.
    mapping(PoolId => YieldRecord) public yieldRecords;

    /// @notice ERC-20 addresses for token0 and token1 per pool (set at registration).
    mapping(PoolId => address) public poolToken0;
    mapping(PoolId => address) public poolToken1;

    /// @notice Attestation hashes already consumed by a `receiveYield` call (EI6: anti-replay).
    mapping(bytes32 => bool) public consumedAttestation;

    /// @notice Optional per-pool proceeds-magnitude bound (defense-in-depth on top of the attestation quorum).
    /// @dev Independent Chainlink USD price feeds for token0/token1 value the routed proceeds, which are bounded
    ///      by `LVRProceedsValidator` to `maxFactorBps` of the pool's on-chain TVL. Both the prices (external
    ///      oracle) and the TVL (hook state) are outside the operator's control. Chainlink is used (not the pool's
    ///      own sqrtPrice) because the LVR winner executes block-top and could skew the pool price.
    ///
    ///      Honest guarantee (do not overstate): WHILE both prices are fresh, a single routing (or, if `window`
    ///      is set, the cumulative routings within a rolling window) cannot exceed `maxFactorBps` of pool TVL in
    ///      USD - so even a compromised quorum cannot over-credit during fresh-price periods. Under a Chainlink
    ///      staleness window the bound cannot be evaluated; it then either reverts (`failClosedOnStale = true`,
    ///      the security-first choice) or degrades to attestation-only (`false`, the liveness-first default).
    ///      `window == 0` is a per-CALL bound only: it blocks an absurd single routing but NOT repeated routings
    ///      across blocks - set a non-zero `window` to cap cumulative proceeds per period (the stronger mode).
    struct ProceedsBound {
        address feed0; // Chainlink USD price feed for token0 (address(0) disables the bound)
        address feed1; // Chainlink USD price feed for token1
        uint16 maxFactorBps; // max proceeds as a fraction of pool TVL, in bps (per call, or per window if window>0)
        uint32 maxPriceAge; // per-feed staleness window in seconds (0 => 25h default)
        uint32 window; // rolling cumulative-cap window in seconds (0 => per-call bound only)
        bool failClosedOnStale; // revert (true) vs skip-to-attestation-only (false) when a price is unavailable
    }

    mapping(PoolId => ProceedsBound) public proceedsBound;

    /// @notice Rolling-window accumulator for the cumulative proceeds cap (only used when `window > 0`).
    struct BoundWindow {
        uint64 start;
        uint256 cumulativeUSD;
    }

    mapping(PoolId => BoundWindow) internal _boundWindow;

    /// @dev EI7 reentrancy mutex. `receiveYield` measures balance deltas around external token calls; an
    ///      ERC-777-style token callback re-entering mid-measurement could otherwise skew the credited
    ///      amounts. 1 = unlocked, 2 = locked (non-zero resting value keeps the SSTORE warm/cheap).
    uint256 private _reentrancyLock = 1;

    modifier nonReentrant() {
        if (_reentrancyLock == 2) revert Reentrancy();
        _reentrancyLock = 2;
        _;
        _reentrancyLock = 1;
    }

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error NotAdmin();
    error PeripheralDisabled();
    error AttestationContractNotSet();
    error AttestationFailed(bytes32 attestationHash);
    error ZeroAmount();
    error TokenNotSet(PoolId id);
    error AttestationAlreadyConsumed(bytes32 attestationHash);
    error Reentrancy();
    error LVRProceedsExceedBound(PoolId id, uint256 proceedsUSD, uint256 maxProceedsUSD);
    error InvalidBoundConfig();
    error LVRPriceUnavailable(PoolId id);

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted when LVR auction proceeds are received and the reserve is credited.
    event LVRYieldReceived(
        PoolId indexed poolId, address indexed from, uint256 amount0, uint256 amount1, bytes32 attestationHash
    );

    /// @notice Emitted when pool tokens are registered for a pool.
    event PoolTokensRegistered(PoolId indexed poolId, address token0, address token1);

    /// @notice Emitted when the per-pool proceeds bound (price feeds + factor) is configured.
    event ProceedsBoundSet(PoolId indexed poolId, address priceFeed0, address priceFeed1, uint16 maxFactorBps);

    /// @notice Emitted when the proceeds bound was configured but a price was unavailable/stale, so the routing
    ///         proceeded on attestation alone (the bound could not be evaluated this call).
    event ProceedsValidationSkipped(PoolId indexed poolId);

    event AttestationContractSet(address attestation);
    event EnabledChanged(bool enabled);

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /// @param hook_   The STRATUM core hook.
    /// @param admin_  Address that can configure this peripheral.
    constructor(IStratumHook hook_, address admin_) {
        stratumHook = hook_;
        admin = admin_;
        enabled = true;
    }

    // -------------------------------------------------------------------------
    // Configuration
    // -------------------------------------------------------------------------

    /// @notice Set the EigenLayer attestation contract.
    function setMatchAttestation(IMatchAttestation attestation_) external {
        if (msg.sender != admin) revert NotAdmin();
        matchAttestation = attestation_;
        emit AttestationContractSet(address(attestation_));
    }

    /// @notice Enable or disable this peripheral.
    function setEnabled(bool v) external {
        if (msg.sender != admin) revert NotAdmin();
        enabled = v;
        emit EnabledChanged(v);
    }

    /// @notice Register the token addresses for a pool so the receiver knows which ERC-20 to pull.
    /// @param id     Pool to register.
    /// @param token0 ERC-20 address for currency0.
    /// @param token1 ERC-20 address for currency1.
    function registerPoolTokens(PoolId id, address token0, address token1) external {
        if (msg.sender != admin) revert NotAdmin();
        poolToken0[id] = token0;
        poolToken1[id] = token1;
        emit PoolTokensRegistered(id, token0, token1);
    }

    /// @notice Configure the optional per-pool proceeds-magnitude bound (defense-in-depth).
    /// @dev Admin-gated. To DISABLE the bound, pass both feeds as `address(0)`. To ENABLE it, BOTH feeds and a
    ///      non-zero `maxFactorBps` are required (an asymmetric one-feed-zero config is rejected, so a configured
    ///      bound is always an active bound - no silent no-op). See `ProceedsBound` for field semantics and the
    ///      honest guarantee.
    /// @param id  Pool to configure.
    /// @param cfg Bound configuration (feeds, factor, staleness window, rolling cap window, fail-closed toggle).
    function setProceedsBound(PoolId id, ProceedsBound calldata cfg) external {
        if (msg.sender != admin) revert NotAdmin();
        bool anyFeed = cfg.feed0 != address(0) || cfg.feed1 != address(0);
        // Enabling requires BOTH feeds + a non-zero factor: "configured" must always mean "active".
        if (anyFeed && (cfg.feed0 == address(0) || cfg.feed1 == address(0) || cfg.maxFactorBps == 0)) {
            revert InvalidBoundConfig();
        }
        proceedsBound[id] = cfg;
        delete _boundWindow[id]; // reset any rolling accumulator on reconfiguration
        emit ProceedsBoundSet(id, cfg.feed0, cfg.feed1, cfg.maxFactorBps);
    }

    // -------------------------------------------------------------------------
    // Core yield routing
    // -------------------------------------------------------------------------

    /// @notice The attestation hash the AVS operators must attest for a given routing (EI6: param-bound).
    /// @dev Binding the hash to `(id, amount0, amount1, nonce)` means an attestation authorises exactly this
    ///      credit and nothing else; `nonce` makes repeat routings distinct so each needs its own attestation.
    function routingHash(PoolId id, uint256 amount0, uint256 amount1, uint256 nonce) public pure returns (bytes32) {
        return keccak256(abi.encode(id, amount0, amount1, nonce));
    }

    /// @notice Receive LVR auction proceeds and credit the pool's token-backed senior reserve (FR-23).
    /// @dev Caller must have pre-approved `amount0`/`amount1` to this contract. The attestation hash is DERIVED
    ///      from the routing params (EI6), must have reached quorum, and is consumed (no replay). The reserve
    ///      is credited with the ACTUAL balance delta the hook received (EI5: fee-on-transfer safe). The
    ///      `creditReserve` call is atomic - if the receiver is not the pool's registered yield source it
    ///      reverts and the transfers roll back, so tokens are never stranded.
    /// @param id      Pool to credit.
    /// @param amount0 Amount of token0 to route.
    /// @param amount1 Amount of token1 to route.
    /// @param nonce   Routing nonce making this attestation unique (so identical amounts can route twice).
    function receiveYield(PoolId id, uint256 amount0, uint256 amount1, uint256 nonce) external nonReentrant {
        if (!enabled) revert PeripheralDisabled();
        if (amount0 == 0 && amount1 == 0) revert ZeroAmount();
        if (address(matchAttestation) == address(0)) revert AttestationContractNotSet();

        bytes32 attestationHash = routingHash(id, amount0, amount1, nonce);
        if (consumedAttestation[attestationHash]) revert AttestationAlreadyConsumed(attestationHash);
        if (!matchAttestation.isAttested(attestationHash)) revert AttestationFailed(attestationHash);
        consumedAttestation[attestationHash] = true; // EI6: mark consumed before external calls (CEI)

        address tok0 = poolToken0[id];
        address tok1 = poolToken1[id];
        if (amount0 > 0 && tok0 == address(0)) revert TokenNotSet(id);
        if (amount1 > 0 && tok1 == address(0)) revert TokenNotSet(id);

        // EI5: pull tokens into the hook and credit the MEASURED delta (fee-on-transfer / rebasing safe).
        // EI8: SafeERC20 handles missing-return tokens (USDT-style) that the prior raw bool check rejected.
        uint256 received0;
        uint256 received1;
        if (amount0 > 0) {
            uint256 before0 = IERC20(tok0).balanceOf(address(stratumHook));
            IERC20(tok0).safeTransferFrom(msg.sender, address(stratumHook), amount0);
            received0 = IERC20(tok0).balanceOf(address(stratumHook)) - before0;
        }
        if (amount1 > 0) {
            uint256 before1 = IERC20(tok1).balanceOf(address(stratumHook));
            IERC20(tok1).safeTransferFrom(msg.sender, address(stratumHook), amount1);
            received1 = IERC20(tok1).balanceOf(address(stratumHook)) - before1;
        }

        // Defense-in-depth (P5/FR-28): if a per-pool proceeds bound is configured, reject a routing whose USD
        // value exceeds a sane fraction of the pool's on-chain TVL. Both inputs (Chainlink prices, hook TVL) are
        // outside operator control, so this holds even if the attestation quorum is compromised. A stale/missing
        // price degrades to attestation-only rather than blocking legitimate yield.
        _enforceProceedsBound(id, received0, received1);

        // Credit the reserve with the real received amounts. Atomic: reverts (rolling back transfers) if this
        // receiver is not the pool's registered yield source.
        IStratumHookReserveCredit(address(stratumHook)).creditReserve(id, received0, received1);

        YieldRecord storage rec = yieldRecords[id];
        unchecked {
            rec.cumulativeToken0 += received0;
            rec.cumulativeToken1 += received1;
        }
        rec.lastRouted = block.timestamp;

        emit LVRYieldReceived(id, msg.sender, received0, received1, attestationHash);
    }

    // -------------------------------------------------------------------------
    // Proceeds bound (internal)
    // -------------------------------------------------------------------------

    /// @notice Enforce the optional proceeds-magnitude bound for a routing of `received0`/`received1`.
    /// @dev No-op when the bound is not configured. When configured, values the proceeds in USD with independent
    ///      Chainlink prices and rejects them (or, if `window > 0`, rejects once cumulative proceeds in the
    ///      rolling window) exceeding `maxFactorBps` of the pool's TVL (token0 units) valued at price0. If a price
    ///      is unavailable/stale: revert when `failClosedOnStale`, else emit `ProceedsValidationSkipped` and
    ///      degrade to attestation-only. Zero TVL (bootstrapping) always degrades to attestation-only.
    function _enforceProceedsBound(PoolId id, uint256 received0, uint256 received1) internal {
        ProceedsBound memory b = proceedsBound[id];
        if (b.maxFactorBps == 0 || b.feed0 == address(0) || b.feed1 == address(0)) return; // not configured

        uint256 p0 = _safePrice8dp(b.feed0, b.maxPriceAge);
        uint256 p1 = _safePrice8dp(b.feed1, b.maxPriceAge);
        if (p0 == 0 || p1 == 0) {
            if (b.failClosedOnStale) revert LVRPriceUnavailable(id);
            // Cannot value the proceeds independently: degrade to attestation-only rather than block yield.
            emit ProceedsValidationSkipped(id);
            return;
        }

        // Proceeds valued in USD (8-dp price * token amount / 1e8).
        uint256 proceedsUSD = received0 * p0 / 1e8 + received1 * p1 / 1e8;

        // Notional = pool TVL in token0 units (ILMath.valueInToken0), valued at the token0 USD price. The bound
        // is `LVRProceedsValidator.maxRationalProceeds(price0, tvl0, factor) = tvl0 * price0 / 1e8 * factor/1e4`.
        PoolTrancheState memory pool = stratumHook.poolState(id);
        uint256 tvl0 = pool.seniorTVL + pool.juniorTVL;
        if (tvl0 == 0) {
            // No TVL to bound against yet (bootstrapping): cannot meaningfully validate, so do not block yield.
            emit ProceedsValidationSkipped(id);
            return;
        }
        uint256 maxProceeds = LVRProceedsValidator.maxRationalProceeds(p0, tvl0, b.maxFactorBps);

        if (b.window == 0) {
            // Per-call sanity bound (weaker: does not cap repeated routings across blocks).
            if (proceedsUSD > maxProceeds) revert LVRProceedsExceedBound(id, proceedsUSD, maxProceeds);
            return;
        }

        // Rolling-window cumulative cap: total proceeds within `window` seconds cannot exceed maxFactorBps of TVL,
        // so a compromised quorum cannot drain via repeated sub-cap routings.
        BoundWindow storage w = _boundWindow[id];
        uint256 cumulative;
        if (block.timestamp >= uint256(w.start) + b.window) {
            w.start = uint64(block.timestamp); // open a fresh window
            cumulative = proceedsUSD;
        } else {
            cumulative = w.cumulativeUSD + proceedsUSD;
        }
        if (cumulative > maxProceeds) revert LVRProceedsExceedBound(id, cumulative, maxProceeds);
        w.cumulativeUSD = cumulative;
    }

    /// @notice Read a Chainlink feed and normalise its answer to 8-decimal fixed point, or 0 on any failure.
    /// @dev Mirrors the guards in `StratumRateLibrary`: extcodesize check (codeless address would revert
    ///      uncatchably under Cancun), try/catch, round completeness, staleness window, and positive answer.
    function _safePrice8dp(address feed, uint256 maxAge) internal view returns (uint256 price8dp) {
        uint256 codeSize;
        assembly ("memory-safe") {
            codeSize := extcodesize(feed)
        }
        if (codeSize == 0) return 0;
        uint256 age = maxAge == 0 ? 25 hours : maxAge;

        try IAggregatorV3(feed).decimals() returns (uint8 dec) {
            // Reject out-of-range decimals before exponentiating: `10 ** (dec-8)` overflows uint256 for large dec
            // and would revert with an arithmetic panic INSIDE this try body, which `catch` does not intercept,
            // bricking `receiveYield`. No real feed exceeds ~30 decimals.
            if (dec > 36) return 0;
            try IAggregatorV3(feed).latestRoundData() returns (
                uint80 roundId, int256 answer, uint256, uint256 updatedAt, uint80 answeredInRound
            ) {
                if (answeredInRound < roundId) return 0;
                if (updatedAt > block.timestamp) return 0; // a future timestamp is invalid, not "fresh"
                if (block.timestamp > updatedAt + age) return 0;
                if (answer <= 0) return 0;
                uint256 raw = uint256(answer);
                if (dec == 8) return raw;
                if (dec < 8) return raw * (10 ** (8 - uint256(dec)));
                return raw / (10 ** (uint256(dec) - 8));
            } catch {
                return 0;
            }
        } catch {
            return 0;
        }
    }

    // -------------------------------------------------------------------------
    // IPeripheral
    // -------------------------------------------------------------------------

    /// @inheritdoc IPeripheral
    function kind() external pure returns (bytes32) {
        return keccak256("EIGEN");
    }

    /// @inheritdoc IPeripheral
    function isEnabled() external view returns (bool) {
        return enabled;
    }

    /// @inheritdoc IPeripheral
    /// @dev No-op on epoch close; LVR yield is routed per auction, not per epoch.
    function onEpochClose(PoolId, uint64, bytes calldata) external returns (bytes memory) {
        return bytes("");
    }

    /// @inheritdoc IPeripheral
    /// @dev No-op on coverage stress; LVR yield routes are independent of coverage signals.
    function onCoverageStress(PoolId, uint16) external { }
}
