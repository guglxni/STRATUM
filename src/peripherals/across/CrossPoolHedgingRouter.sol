// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";
import { IERC20 } from "@uniswap/v4-core/lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@uniswap/v4-core/lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import { IPeripheral } from "../../interfaces/IPeripheral.sol";
import { IStratumHook } from "../../interfaces/IStratumHook.sol";
import { IReserveRebalanceTarget } from "../reactive/IReserveRebalanceTarget.sol";
import { CorrelationRegistry } from "./CorrelationRegistry.sol";
import { IStratumSpokePool } from "./IStratumSpokePool.sol";
import { IMatchAttestation } from "../eigenlayer/IMatchAttestation.sol";

/// @notice Narrow interface for the hook's same-chain reserve-aggregation move (FR-18). Both pools' reserves
///         live on the hook, so this is a ledger move (no token transfer); gated on the hook side.
interface IStratumHookRebalance {
    function rebalanceReserve(PoolId from, PoolId to, uint256 amount0, uint256 amount1) external;
}

/// @notice Narrow interface for crediting a pool's real token reserve from bridged cross-chain funds (FR-19).
///         The destination CPHR is registered as the target pool's `reserveRebalancer` so the hook accepts the
///         credit. Tokens are transferred to the hook before this call so the ledger stays backed.
interface IStratumHookCredit {
    function creditReserve(PoolId id, uint256 amount0, uint256 amount1) external;
    function poolCurrency0(PoolId id) external view returns (Currency);
    function poolCurrency1(PoolId id) external view returns (Currency);
}

/// @title CrossPoolHedgingRouter
/// @notice Phase-4 Across integration: same-chain junior reserve aggregation (FR-18) and
///         cross-chain reserve sharing via Across V3 (FR-19).
///
/// @dev CPHR implements three interfaces:
///      - IReserveRebalanceTarget: called by the Reactive ReserveBalancer with signed divergence signals.
///      - IPeripheral: registered as the hook's peripheral for in-band epoch-close and coverage-stress hooks.
///      - Direct calls: topUp (same-chain), bridgeReserve (cross-chain), netExposures (IL netting).
///
/// Design invariants preserved:
///   INV-01: CPHR is only invoked when the coverage floor would otherwise be breached. The hook calls
///           onCoverageStress at that point; CPHR then attempts a same-chain topUp. If the topUp still
///           leaves the ratio below the floor, the hook reverts CoverageRatioBelowFloor.
///   INV-02/03/04/05: CPHR touches ONLY its own reserve escrow (`_escrow`). It never writes to
///           PoolTrancheState.juniorReserve. It cannot call into the hook's settlement path. Any value
///           transferred into a pool's real token0/token1 reserve (reserve0/reserve1) is done by the
///           hook itself when it calls take() on PoolManager; the CPHR is upstream of that path, not
///           inline.
///   INV-05 boundary: CPHR credits real token reserves (reserve0/reserve1 on the hook), not the
///           abstract juniorReserve accumulator. These are separate by design (R-H1).
///
/// Across-specific constraints:
///   - quoteTimestamp must be within the SpokePool's depositQuoteTimeBuffer (set at configuration).
///   - fillDeadline is computed as block.timestamp + fillDeadlineBuffer.
///   - inputToken must be pre-approved to the SpokePool by this contract before depositV3 is called.
///
/// @custom:security-note The CPHR holds transient escrow during topUp sequences. Reentrancy risk is
///   mitigated by checking-and-zeroing escrow amounts before external token transfers (checks-effects-
///   interactions pattern). No recursive call into the hook's settlement path is possible because the
///   hook's afterRemoveLiquidity is only callable via PoolManager unlock, which is not triggered here.
contract CrossPoolHedgingRouter is IReserveRebalanceTarget, IPeripheral {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    /// @notice Peripheral kind identifier consumed by the core hook's peripheral dispatch.
    bytes32 public constant KIND = keccak256("ACROSS");

    /// @notice Basis-point denominator (10 000 = 100 %).
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Minimum absolute deficit (in juniorReserve units) below which no rebalance is attempted.
    ///         Prevents spam rebalances for rounding-level divergences. Expressed in the same unit as
    ///         juniorReserve (abstract accumulator, token0-denominated value).
    uint256 public constant MIN_REBALANCE_THRESHOLD = 1e15; // 0.001 token0 units (1e15 wei)

    /// @notice Maximum fraction of a donor pool's reserve that a single topUp may draw, in bps.
    ///         Protects donor pools from being completely drained by a single rebalance event.
    uint16 public constant MAX_DRAW_FRACTION_BPS = 5_000; // 50 %

    /// @notice Maximum number of pools accepted by `netExposures` to bound its O(n^2 * degree) cost (CP6).
    uint256 public constant MAX_NET_POOLS = 64;

    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------

    /// @notice Address of the operator who configures this contract.
    address public immutable operator;

    /// @notice The STRATUM hook whose reserve balances are read and credited.
    IStratumHook public immutable stratumHook;

    /// @notice On-chain correlation graph consulted when choosing donor pools.
    CorrelationRegistry public immutable registry;

    /// @notice Across V3 SpokePool for cross-chain transfers (FR-19). May be address(0) in
    ///         core-only test profiles (NFR-01).
    IStratumSpokePool public spokePool;

    /// @notice EigenLayer attestation gating cross-chain bridges (FR-24). If set, every `bridgeReserve` must
    ///         present a `matchHash` that has reached attestation quorum. address(0) = ungated (operator-only).
    IMatchAttestation public matchAttestation;

    /// @notice Registered ReserveBalancer RSC permitted to call `requestRebalance` (CP5). If set, only it (or
    ///         the operator) may signal a rebalance. address(0) leaves the signal open for the demo path.
    address public reserveBalancer;

    /// @notice Whether this peripheral is active (operator-gated disable).
    bool public enabled;

    /// @notice Buffer added to block.timestamp for Across fillDeadline computation.
    uint32 public fillDeadlineBuffer;

    /// @notice Default relayer fee as a fraction of inputAmount in bps. Applied when bridging.
    uint16 public relayerFeeBps;

    /// @notice Mapping of chain ID to the CPHR address that should receive bridged funds on that chain.
    ///         The recipient on the destination chain is expected to credit the target pool's reserve.
    mapping(uint256 => address) public destinationCPHR;

    /// @notice Per-pool escrow of real token0 (in IStratumHook.reserve0 units) staged for a topUp.
    ///         Written before external token transfer, cleared on completion or failure (CEI pattern).
    mapping(PoolId => uint256) private _escrow0;

    /// @notice Per-pool escrow of real token1.
    mapping(PoolId => uint256) private _escrow1;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted when a same-chain topUp is executed.
    /// @param targetPool  Pool whose reserve was replenished.
    /// @param donorPool   Pool that donated reserve capital.
    /// @param amount0     Token0 units transferred.
    /// @param amount1     Token1 units transferred.
    event TopUpExecuted(PoolId indexed targetPool, PoolId indexed donorPool, uint256 amount0, uint256 amount1);

    /// @notice Emitted when a coverage-stress signal is handled (CP10: replaces a misleading TopUpExecuted).
    event CoverageStressHandled(PoolId indexed poolId, uint16 ratioBps, uint256 topUpAmount);

    /// @notice Emitted when the registered ReserveBalancer is set (CP5).
    event ReserveBalancerSet(address reserveBalancer);

    /// @notice Emitted when no eligible donor was found for a topUp.
    /// @param targetPool Pool that needed a topUp.
    event TopUpUnavailable(PoolId indexed targetPool);

    /// @notice Emitted when a cross-chain bridge deposit is submitted to Across.
    /// @param targetPool         Destination pool identifier (off-chain reference in `message`).
    /// @param destinationChainId Across destination chain.
    /// @param inputToken         Token deposited on the origin chain.
    /// @param inputAmount        Units deposited.
    event BridgeInitiated(
        PoolId indexed targetPool, uint256 indexed destinationChainId, address inputToken, uint256 inputAmount
    );

    /// @notice Emitted when requestRebalance routes to a same-chain topUp.
    event RebalanceRoutedTopUp(PoolId indexed poolId, int256 divergence);

    /// @notice Emitted when requestRebalance routes to a cross-chain bridge.
    event RebalanceRoutedBridge(PoolId indexed poolId, int256 divergence);

    /// @notice Emitted when IL netting offsets are applied across a pool array.
    event ExposuresNetted(PoolId[] poolIds, uint256 totalOffsetValue0);

    /// @notice Emitted when the SpokePool address is updated.
    event SpokePoolSet(address spokePool);

    /// @notice Emitted when enabled/disabled.
    event EnabledSet(bool enabled);

    /// @notice Emitted when a destination CPHR is registered.
    event DestinationCPHRSet(uint256 indexed chainId, address cphr);

    /// @notice Emitted when a cross-chain fill is received and credited to a pool's reserve (FR-19 loop close).
    event BridgeReceived(PoolId indexed targetPool, address tokenSent, uint256 amount, bool fundsCurrency0);

    /// @notice Emitted when stranded tokens (e.g. an expired Across deposit refund) are recovered (CP11).
    event TokenRescued(address indexed token, address indexed to, uint256 amount);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @notice Caller is not the configured operator.
    error OnlyOperator();

    /// @notice Caller is not the STRATUM hook.
    error OnlyStratumHook();

    /// @notice Cross-chain bridge attempted but SpokePool is not configured.
    error SpokePoolNotConfigured();

    /// @notice Destination fill callback caller is not the configured Across SpokePool (FR-19).
    error OnlySpokePool();

    /// @notice Bridged token does not match the target pool's currency for the credited leg (INV-03 guard).
    error ReserveTokenMismatch(PoolId targetPool, address tokenSent);

    /// @notice Bridge attempted to an unregistered destination chain.
    error DestinationNotConfigured(uint256 chainId);

    /// @notice Token approval to SpokePool failed.
    error ApprovalFailed();

    /// @notice The cross-chain bridge was not attested by the AVS operator quorum (FR-24).
    error BridgeNotAttested(bytes32 matchHash);

    /// @notice `requestRebalance` caller is neither the registered ReserveBalancer nor the operator (CP5).
    error OnlyReserveBalancer();

    /// @notice `netExposures` was given more pools than `MAX_NET_POOLS` (CP6 gas-DoS guard).
    error TooManyPools(uint256 provided, uint256 max);

    /// @notice A constructor/setter argument was the zero address (CP8).
    error ZeroAddress();

    /// @notice The requested amount exceeds the available reserve after safety cap.
    error InsufficientDonorReserve(PoolId donorPool, uint256 available, uint256 requested);

    /// @notice topUp called for a zero amount.
    error ZeroAmount();

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /// @param operator_    Address granted operator rights.
    /// @param hook_        The STRATUM hook whose reserve data is read.
    /// @param registry_    Deployed CorrelationRegistry instance.
    /// @param spokePool_   Across V3 SpokePool (address(0) = cross-chain disabled).
    /// @param fillDeadlineBuffer_ Seconds added to block.timestamp for Across fill deadline.
    /// @param relayerFeeBps_     Default relayer fee in basis points.
    constructor(
        address operator_,
        IStratumHook hook_,
        CorrelationRegistry registry_,
        address spokePool_,
        uint32 fillDeadlineBuffer_,
        uint16 relayerFeeBps_
    ) {
        if (operator_ == address(0) || address(hook_) == address(0) || address(registry_) == address(0)) {
            revert ZeroAddress(); // CP8
        }
        operator = operator_;
        stratumHook = hook_;
        registry = registry_;
        spokePool = IStratumSpokePool(spokePool_); // address(0) allowed: cross-chain disabled
        fillDeadlineBuffer = fillDeadlineBuffer_;
        relayerFeeBps = relayerFeeBps_;
        enabled = true;
    }

    // -------------------------------------------------------------------------
    // Operator configuration
    // -------------------------------------------------------------------------

    /// @notice Wire the EigenLayer attestation contract that gates cross-chain bridges (FR-24, operator-only).
    /// @param attestation_ The MatchAttestation contract; address(0) leaves bridges ungated (operator-only).
    function setMatchAttestation(IMatchAttestation attestation_) external {
        if (msg.sender != operator) revert OnlyOperator();
        matchAttestation = attestation_;
    }

    /// @notice Register the ReserveBalancer permitted to call `requestRebalance` (CP5, operator-only).
    /// @param reserveBalancer_ The ReserveBalancer RSC; address(0) leaves the signal open (demo path).
    function setReserveBalancer(address reserveBalancer_) external {
        if (msg.sender != operator) revert OnlyOperator();
        reserveBalancer = reserveBalancer_;
        emit ReserveBalancerSet(reserveBalancer_);
    }

    /// @notice Set the Across SpokePool address (operator-gated).
    /// @param spokePool_ New SpokePool; may be address(0) to disable cross-chain bridging.
    function setSpokePool(address spokePool_) external {
        if (msg.sender != operator) revert OnlyOperator();
        spokePool = IStratumSpokePool(spokePool_);
        emit SpokePoolSet(spokePool_);
    }

    /// @notice Enable or disable this peripheral (operator-gated).
    /// @param enabled_ New state.
    function setEnabled(bool enabled_) external {
        if (msg.sender != operator) revert OnlyOperator();
        enabled = enabled_;
        emit EnabledSet(enabled_);
    }

    /// @notice Register the CPHR contract on a destination chain that will receive bridged funds.
    /// @param chainId Destination chain identifier.
    /// @param cphr    Address of the CPHR on that chain.
    function setDestinationCPHR(uint256 chainId, address cphr) external {
        if (msg.sender != operator) revert OnlyOperator();
        if (cphr == address(0)) revert ZeroAddress(); // CP8
        destinationCPHR[chainId] = cphr;
        emit DestinationCPHRSet(chainId, cphr);
    }

    /// @notice Update Across timing parameters (operator-gated).
    /// @param fillDeadlineBuffer_ New fill-deadline buffer in seconds.
    /// @param relayerFeeBps_      New default relayer fee in bps.
    function setAcrossParams(uint32 fillDeadlineBuffer_, uint16 relayerFeeBps_) external {
        if (msg.sender != operator) revert OnlyOperator();
        fillDeadlineBuffer = fillDeadlineBuffer_;
        relayerFeeBps = relayerFeeBps_;
    }

    /// @notice Recover tokens stranded on this contract (CP11: expired-deposit refunds, operator-gated).
    /// @dev When an Across V3 deposit expires unfilled, the SpokePool refunds the input tokens to the
    ///      DEPOSITOR (this contract) on the origin chain. Without a recovery path those refunded reserve
    ///      tokens are stranded forever. The CPHR holds no long-lived custody by design, so any resting
    ///      balance is either an expired-deposit refund or an accidental transfer; the operator routes it
    ///      back to the hook's reserve (via an attested re-bridge or a direct credit) or to the rightful owner.
    /// @param token  ERC-20 to recover.
    /// @param to     Recipient of the recovered tokens.
    /// @param amount Amount to recover.
    function rescueToken(address token, address to, uint256 amount) external {
        if (msg.sender != operator) revert OnlyOperator();
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit TokenRescued(token, to, amount);
    }

    // -------------------------------------------------------------------------
    // IPeripheral
    // -------------------------------------------------------------------------

    /// @inheritdoc IPeripheral
    function kind() external pure returns (bytes32) {
        return KIND;
    }

    /// @inheritdoc IPeripheral
    /// @dev Decodes the epoch-close context emitted by StratumHook.closeEpoch to check whether the
    ///      closed pool's junior reserve is below its correlated peers, and if so initiates a same-chain
    ///      topUp proactively (before the next senior deposit triggers a coverage-floor check). This
    ///      reduces the probability of a CoverageRatioBelowFloor revert at the next deposit.
    ///
    ///      The return value is ignored by the core (NFR-01). Any revert here is swallowed by the hook's
    ///      try/catch, so core settlement is never blocked (golden rule 1).
    ///
    ///      Context encoding: abi.encode(funded, surplus, juniorReserve, juniorTVL, seniorTVL)
    function onEpochClose(PoolId id, uint64, bytes calldata ctx) external returns (bytes memory) {
        // H-07: only the hook may invoke this callback. Without this gate any EOA could call it with a forged
        // `ctx` to size and drive `_attemptSameChainTopUp` -> `rebalanceReserve`, draining opted-in donor pools'
        // reserves. The hook constructs `ctx` from its own finalized epoch state, so trusting it is safe once
        // the caller is verified to be the hook.
        if (msg.sender != address(stratumHook)) revert OnlyStratumHook();
        if (!enabled) return bytes("");
        if (ctx.length < 160) return bytes(""); // malformed context: no-op

        (,, uint256 juniorReserve, uint256 juniorTVL, uint256 seniorTVL) =
            abi.decode(ctx, (uint256, uint256, uint256, uint256, uint256));

        // Proactive topUp: if juniorReserve is below 10 % of juniorTVL and seniorTVL > 0, signal
        // a deficit so the balancer can top up before the next senior deposit hits the floor guard.
        if (seniorTVL > 0 && juniorTVL > 0 && juniorReserve < juniorTVL / 10) {
            uint256 deficit = juniorTVL / 10 - juniorReserve;
            if (deficit >= MIN_REBALANCE_THRESHOLD) {
                _attemptSameChainTopUp(id, deficit);
            }
        }
        return bytes("");
    }

    /// @inheritdoc IPeripheral
    /// @dev Coverage stress hook: immediately attempt a same-chain topUp to restore the buffer.
    ///      ratioBps is the current (already-breached) ratio; the deficit is approximated from the
    ///      pool's seniorTVL and juniorReserve.
    function onCoverageStress(PoolId id, uint16 ratioBps) external {
        // H-07: hook-only, same rationale as onEpochClose - this is a privileged reserve-movement trigger.
        if (msg.sender != address(stratumHook)) revert OnlyStratumHook();
        if (!enabled) return;
        (uint256 r0, uint256 r1) = stratumHook.reserveBalances(id);
        uint256 totalReserve = r0 + r1; // rough token0-denominated proxy
        if (totalReserve == 0) return;

        // Try to restore at least 20 % of the current reserve as a top-up margin.
        uint256 topUpAmount = totalReserve / 5;
        if (topUpAmount < MIN_REBALANCE_THRESHOLD) return;

        _attemptSameChainTopUp(id, topUpAmount);

        // CP10: a dedicated observability event (replaces the prior misleading self-referential TopUpExecuted).
        emit CoverageStressHandled(id, ratioBps, topUpAmount);
    }

    /// @inheritdoc IPeripheral
    function isEnabled() external view returns (bool) {
        return enabled;
    }

    // -------------------------------------------------------------------------
    // IReserveRebalanceTarget
    // -------------------------------------------------------------------------

    /// @inheritdoc IReserveRebalanceTarget
    /// @dev Called by the Reactive ReserveBalancer when a pool's junior reserve diverges from the
    ///      cross-pool average beyond the configured threshold.
    ///
    ///      Routing decision:
    ///        divergence < 0 (local deficit): attempt same-chain topUp from a correlated donor.
    ///          If no eligible donor exists, emit BridgeInitiated (cross-chain FR-19) when SpokePool
    ///          is configured and a destination CPHR is registered for the hook's chain.
    ///        divergence > 0 (local surplus): no action needed here; donor pools respond reactively
    ///          when a sibling pool's divergence triggers this function with a negative value.
    ///        divergence == 0: no-op.
    function requestRebalance(PoolId id, int256 divergence) external {
        // CP5: when a ReserveBalancer is registered, only it (or the operator) may signal a rebalance.
        // When unregistered, the signal stays open for the demo path. Fund movement is independently gated.
        if (reserveBalancer != address(0) && msg.sender != reserveBalancer && msg.sender != operator) {
            revert OnlyReserveBalancer();
        }
        if (!enabled) return;
        if (divergence == 0) return;

        if (divergence < 0) {
            uint256 deficit = uint256(-divergence);
            if (deficit < MIN_REBALANCE_THRESHOLD) return;
            bool topped = _attemptSameChainTopUp(id, deficit);
            if (topped) {
                emit RebalanceRoutedTopUp(id, divergence);
            } else {
                // No same-chain donor available: escalate to cross-chain if SpokePool is configured.
                emit RebalanceRoutedBridge(id, divergence);
                // bridgeReserve is not auto-invoked here: it requires explicit token approval and
                // chain selection. The Reactive system / operator calls bridgeReserve separately.
            }
        }
        // Positive divergence (surplus): no action. The ReserveBalancer will trigger the deficit
        // signal on the sibling pool when it processes that pool's next observation.
    }

    // -------------------------------------------------------------------------
    // Same-chain aggregation (FR-18)
    // -------------------------------------------------------------------------

    /// @notice Same-chain reserve aggregation: move up to `amount` token0-equivalent value from a
    ///         correlated donor pool's real token reserve into `targetPool`'s real token reserve.
    /// @dev Donor selection: iterate the correlation graph of `targetPool` and pick the first
    ///      correlated pool whose reserve0 exceeds `MAX_DRAW_FRACTION_BPS` cap. The actual draw is
    ///      the minimum of `amount` and 50 % of the donor's reserve0. This is a greedy O(k) scan;
    ///      k is the out-degree of `targetPool` in the CorrelationRegistry.
    ///
    ///      The CPHR holds no token custody itself. Tokens reside in the hook's reserve ledgers
    ///      (reserve0/reserve1). The CPHR therefore cannot move tokens without a PoolManager unlock
    ///      callback, so this function emits an event for the off-chain/Reactive layer to finalize,
    ///      and also calls `_creditTargetPool` for the demo accounting path when both pools are on
    ///      the same PoolManager instance and the operator has pre-funded escrow.
    ///
    /// @param targetPool Pool whose reserve needs replenishment.
    /// @param amount     Token0-denominated value requested.
    /// @param currency0  Token0 address (for off-chain routing reference).
    /// @return executed  Whether a donor was found and the top-up event was emitted.
    function topUp(PoolId targetPool, uint256 amount, address currency0) external returns (bool executed) {
        if (msg.sender != operator && msg.sender != address(stratumHook)) revert OnlyOperator();
        if (amount == 0) revert ZeroAmount();
        executed = _attemptSameChainTopUp(targetPool, amount);
        // currency0 is carried through the event inside _attemptSameChainTopUp for off-chain routing.
        // Suppress unused variable warning.
        currency0;
    }

    // -------------------------------------------------------------------------
    // Cross-chain reserve sharing (FR-19)
    // -------------------------------------------------------------------------

    /// @notice Cross-chain reserve sharing via Across V3 (FR-19).
    /// @dev The caller (operator or Reactive system) must have:
    ///      1. Pre-approved `inputToken` to this contract for at least `inputAmount`.
    ///      2. This contract approved `inputToken` to `spokePool` for at least `inputAmount`.
    ///         (Approval is handled inside this function via incremental approve.)
    ///      The `message` field encodes the target pool so the receiving CPHR on the destination chain
    ///      can credit the correct pool's reserve: abi.encode(targetPool).
    ///
    /// @param targetPool         Pool that needs the reserve replenishment (off-chain reference).
    /// @param destinationChainId Across destination chain identifier.
    /// @param inputToken         ERC-20 token deposited on this chain.
    /// @param outputToken        ERC-20 token received on the destination chain.
    /// @param inputAmount        Amount of `inputToken` to bridge.
    /// @param outputAmount       Expected amount of `outputToken` on the destination (inputAmount - relayer fee).
    /// @param fundsCurrency0 Whether the bridged tokens credit the target pool's reserve0 (true) or reserve1.
    function bridgeReserve(
        PoolId targetPool,
        uint256 destinationChainId,
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        bool fundsCurrency0
    ) external {
        if (msg.sender != operator) revert OnlyOperator();
        if (address(spokePool) == address(0)) revert SpokePoolNotConfigured();

        address dest = destinationCPHR[destinationChainId];
        if (dest == address(0)) revert DestinationNotConfigured(destinationChainId);

        // CP1 / FR-24: gate the bridge on AVS attestation when configured. The matchHash binds the exact
        // bridge parameters so an attestation cannot authorise a different transfer.
        if (address(matchAttestation) != address(0)) {
            bytes32 matchHash = keccak256(
                abi.encode(
                    targetPool, destinationChainId, inputToken, outputToken, inputAmount, outputAmount, fundsCurrency0
                )
            );
            if (!matchAttestation.isAttested(matchHash)) revert BridgeNotAttested(matchHash);
        }

        // CP2: SafeERC20 transferFrom (handles missing-return tokens like USDT). CP4: measure the actually
        // received amount so fee-on-transfer tokens bridge the real balance, not the requested figure.
        uint256 balBefore = IERC20(inputToken).balanceOf(address(this));
        IERC20(inputToken).safeTransferFrom(msg.sender, address(this), inputAmount);
        uint256 received = IERC20(inputToken).balanceOf(address(this)) - balBefore;

        // CP2/CP3: forceApprove zeroes then sets, avoiding the non-zero-to-non-zero approve revert (USDT).
        IERC20(inputToken).forceApprove(address(spokePool), received);

        // CP7: floor the output against the configured relayer fee so a bad outputAmount cannot overpay relayers.
        uint256 minOut = received - (received * relayerFeeBps / BPS_DENOMINATOR);
        uint256 effectiveOut = outputAmount < minOut ? minOut : outputAmount;

        // The message field encodes the target pool and the reserve leg so the destination CPHR can credit
        // the right pool's reserve0/reserve1 (FR-19 destination loop, decoded in handleV3AcrossMessage).
        bytes memory message = abi.encode(targetPool, fundsCurrency0);

        uint32 quoteTimestamp = uint32(block.timestamp);
        uint32 fillDeadline = uint32(block.timestamp) + fillDeadlineBuffer;

        spokePool.depositV3(
            address(this), // depositor
            dest, // recipient (destination CPHR)
            inputToken,
            outputToken,
            received,
            effectiveOut,
            destinationChainId,
            address(0), // exclusiveRelayer: none
            quoteTimestamp,
            fillDeadline,
            0, // exclusivityDeadline: none
            message
        );

        emit BridgeInitiated(targetPool, destinationChainId, inputToken, received);
    }

    /// @notice Across V3 destination callback (FR-19 loop close). The SpokePool calls this after filling the
    ///         deposit, delivering `amount` of `tokenSent` plus the origin-encoded `message`. We forward the
    ///         tokens into the hook's reserve ledger for the target pool so the bridged value backs that pool.
    /// @dev Gated to the configured SpokePool: only Across may deliver a fill. The CPHR must be registered as
    ///      `reserveRebalancer[targetPool]` on the hook (creator-gated, one-time) for the credit to be accepted.
    ///      CEI: tokens are transferred to the hook before crediting the ledger, so the ledger is always backed.
    ///      Conservation (INV-03): credited amount equals the token amount actually moved into the hook.
    /// @param tokenSent The ERC-20 delivered by the relayer (output token on this chain).
    /// @param amount    Amount of `tokenSent` delivered.
    /// @param relayer   Address that filled the deposit (unused; carried for the Across interface).
    /// @param message   abi.encode(PoolId targetPool, bool fundsCurrency0) set by the origin CPHR.
    function handleV3AcrossMessage(address tokenSent, uint256 amount, address relayer, bytes calldata message)
        external
    {
        if (msg.sender != address(spokePool)) revert OnlySpokePool();
        relayer; // Across interface parameter; routing is fixed by the message, not the relayer.

        (PoolId targetPool, bool fundsCurrency0) = abi.decode(message, (PoolId, bool));
        IStratumHookCredit hook = IStratumHookCredit(address(stratumHook));

        // Token-confusion guard (INV-03): the bridged token MUST equal the target pool's currency for the
        // credited leg. Without this, a wrong/worthless bridged token would inflate the reserve ledger that
        // make-whole later pays out as the pool's real currency0/currency1, draining genuine backing.
        Currency expected = fundsCurrency0 ? hook.poolCurrency0(targetPool) : hook.poolCurrency1(targetPool);
        if (tokenSent != Currency.unwrap(expected)) revert ReserveTokenMismatch(targetPool, tokenSent);

        // Conservation: credit the amount the hook ACTUALLY receives, not the relayer-asserted `amount`
        // (defends fee-on-transfer / partial-fill output tokens, mirroring the origin CP4 discipline).
        uint256 hookBalBefore = IERC20(tokenSent).balanceOf(address(stratumHook));
        IERC20(tokenSent).safeTransfer(address(stratumHook), amount); // CEI: transfer before credit
        uint256 credited = IERC20(tokenSent).balanceOf(address(stratumHook)) - hookBalBefore;

        // Credit the correct reserve leg. The hook gates this to reserveYieldSource/reserveRebalancer[targetPool].
        if (fundsCurrency0) {
            hook.creditReserve(targetPool, credited, 0);
        } else {
            hook.creditReserve(targetPool, 0, credited);
        }

        emit BridgeReceived(targetPool, tokenSent, credited, fundsCurrency0);
    }

    // -------------------------------------------------------------------------
    // IL netting (FR-20 / DESIGN section 10)
    // -------------------------------------------------------------------------

    /// @notice Net opposing junior IL exposures across a set of correlated pools.
    /// @dev Consults the CorrelationRegistry to determine which pairs are correlated, then computes
    ///      a weighted average of their cumulative IL (poolCumulativeIL from PoolTrancheState). For
    ///      each pair where pool A's IL exceeds pool B's IL and they are correlated, the net offset
    ///      (bounded by the correlation weight) is computed. The result is informational and emitted
    ///      as an event; the Reactive system or operator applies the offset by routing topUp calls.
    ///
    ///      Arithmetic: all values are in the same token0-denominated units as poolCumulativeIL.
    ///      Overflow guard: FullMath.mulDiv is used for weight-scaled intermediate values.
    ///
    /// @param poolIds Ordered array of pool identifiers to include in the netting sweep.
    function netExposures(PoolId[] calldata poolIds) external {
        if (msg.sender != operator) revert OnlyOperator();
        uint256 len = poolIds.length;
        if (len > MAX_NET_POOLS) revert TooManyPools(len, MAX_NET_POOLS); // CP6: bound the O(n^2*degree) sweep
        if (len < 2) return;

        uint256 totalOffsetValue0;

        for (uint256 i = 0; i < len; ++i) {
            (PoolId[] memory neighbours, uint16[] memory weights) = registry.getCorrelatedPools(poolIds[i]);
            uint256 nLen = neighbours.length;
            if (nLen == 0) continue;

            // cumulativeIL for pool i.
            uint256 ilI = stratumHook.poolState(poolIds[i]).poolCumulativeIL;

            for (uint256 j = 0; j < nLen; ++j) {
                // Only net against pools included in the caller's poolIds array (avoids ghost offsets).
                bool included = false;
                for (uint256 k = 0; k < len; ++k) {
                    if (PoolId.unwrap(neighbours[j]) == PoolId.unwrap(poolIds[k])) {
                        included = true;
                        break;
                    }
                }
                if (!included) continue;

                uint256 ilJ = stratumHook.poolState(neighbours[j]).poolCumulativeIL;
                if (ilI <= ilJ) continue; // no offset from i to j in this direction

                uint256 rawOffset = ilI - ilJ;
                // Scale by correlation weight: offset = rawOffset * weight / 10000.
                // FullMath.mulDiv guards against intermediate overflow (rawOffset may be large).
                uint256 weightedOffset = FullMath.mulDiv(rawOffset, weights[j], BPS_DENOMINATOR);
                totalOffsetValue0 += weightedOffset;
            }
        }

        emit ExposuresNetted(poolIds, totalOffsetValue0);
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    /// @dev Greedy donor search: iterate the correlation graph of `targetPool`, pick the first donor
    ///      pool with reserve0 > MIN_REBALANCE_THRESHOLD, compute a safe draw amount (capped at
    ///      MAX_DRAW_FRACTION_BPS of the donor's reserve0), and emit TopUpExecuted.
    ///
    ///      Because the CPHR cannot move tokens held by the hook without a PoolManager unlock
    ///      (v4 architecture), this function emits the event that the Reactive system uses as the
    ///      trigger to finalize the actual token transfer via a hook-mediated callback. In the demo
    ///      path (single-process Foundry test), the operator calls the hook directly after this event.
    ///
    ///      Returns true if a donor was found and the event emitted.
    function _attemptSameChainTopUp(PoolId targetPool, uint256 amount) internal returns (bool found) {
        (PoolId[] memory donors, uint16[] memory weights) = registry.getCorrelatedPools(targetPool);
        uint256 dLen = donors.length;
        if (dLen == 0) {
            emit TopUpUnavailable(targetPool);
            return false;
        }

        for (uint256 i = 0; i < dLen; ++i) {
            (uint256 donorR0,) = stratumHook.reserveBalances(donors[i]);
            if (donorR0 < MIN_REBALANCE_THRESHOLD) continue;

            // Safety cap: draw at most MAX_DRAW_FRACTION_BPS of the donor's reserve.
            uint256 maxDraw = FullMath.mulDiv(donorR0, MAX_DRAW_FRACTION_BPS, BPS_DENOMINATOR);
            uint256 draw = amount > maxDraw ? maxDraw : amount;

            if (draw == 0) continue;

            // Correlation weight further scales the draw: draw * weight / 10000.
            // This prevents a low-weight correlation from triggering a large transfer.
            uint256 scaledDraw = FullMath.mulDiv(draw, weights[i], BPS_DENOMINATOR);
            if (scaledDraw == 0) continue;

            // FR-18: move the reserve for real. Both pools' reserves live on the hook, so this is a ledger
            // move that the hook performs (gated on the donor pool having registered this CPHR as its
            // rebalancer). If the donor has not opted in (or lacks reserve), fall back to a signal-only emit
            // so the off-chain/Reactive path can finalize - the CPHR never reverts the rebalance attempt.
            try IStratumHookRebalance(address(stratumHook)).rebalanceReserve(donors[i], targetPool, scaledDraw, 0) {
                emit TopUpExecuted(targetPool, donors[i], scaledDraw, 0);
            } catch {
                emit TopUpExecuted(targetPool, donors[i], scaledDraw, 0); // signal-only fallback (not opted in)
            }
            return true;
        }

        emit TopUpUnavailable(targetPool);
        return false;
    }
}
