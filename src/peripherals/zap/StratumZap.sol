// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import { TransientStateLibrary } from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { IERC20 } from "@uniswap/v4-core/lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@uniswap/v4-core/lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";

import { IStratumHook } from "../../interfaces/IStratumHook.sol";
import { TranchePosition, TrancheType } from "../../StratumTypes.sol";

/// @title StratumZap
/// @notice End-user position router for STRATUM tranches. Wraps the v4 unlock/modifyLiquidity
///         plumbing so a user (or a payment flow) can enter and exit a senior or junior position
///         in one call, without writing an unlock-callback contract.
/// @dev Design notes:
///      - The zap is the v4 `sender`, so the hook records it as the position owner and mints the
///        stLP/jtLP receipt tokens to it. The receipts are CUSTODIED by the zap while the position
///        is open: the hook burns them from the sender at settlement, so distributing them to end
///        users would break the close path. End-user ownership lives in `zapPositionOwner`.
///      - Per-user isolation: the v4 salt is keccak256(user, userSalt), so two users can never
///        collide on a position id and only the recorded user can act on a position.
///      - Delivered-balance mode supports the Trading API custom-recipient flow (see
///        docs/UNISWAP_DEV_PORTAL_INTEGRATION.md): a swap delivers tokens straight to the zap and
///        the follow-up deposit consumes them without a transferFrom. The zap is NOT a vault:
///        deposits sweep all remaining balance of the pool's currencies back to the caller, so
///        delivered tokens must be consumed in the same transaction batch that delivered them.
///      - Trust model: the zap holds no role on the hook; from the core's perspective it is just
///        another LP. A malicious or buggy zap can only affect its own users (golden rule 1).
contract StratumZap is IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using TransientStateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    /// @notice Caller is not the PoolManager.
    error OnlyPoolManager();
    /// @notice Pool uses native currency; the zap supports ERC-20 pools only.
    error NativeCurrencyNotSupported();
    /// @notice Caller is not the recorded end-user owner of the zap position.
    error NotZapPositionOwner();
    /// @notice Zero liquidity requested.
    error ZeroLiquidity();
    /// @notice The position does not exist on the hook.
    error PositionUnknown();
    /// @notice The Permit2 batch permit did not contain exactly the pool's two currencies.
    error Permit2BadLength();
    /// @notice The Permit2 permitted tokens did not match the pool's [currency0, currency1] order.
    error Permit2TokenMismatch();

    /// @notice Emitted when a user opens a tranche position through the zap.
    /// @param poolId Pool the position was opened in.
    /// @param positionId Hook position id.
    /// @param user End-user owner recorded by the zap.
    /// @param tranche Tranche selected.
    /// @param liquidity Liquidity deposited.
    event ZapDeposited(
        PoolId indexed poolId, bytes32 indexed positionId, address indexed user, TrancheType tranche, uint128 liquidity
    );

    /// @notice Emitted when a user closes a tranche position through the zap.
    /// @param poolId Pool the position was closed in.
    /// @param positionId Hook position id.
    /// @param user End-user owner the proceeds were sent to.
    event ZapWithdrawn(PoolId indexed poolId, bytes32 indexed positionId, address indexed user);

    /// @notice Canonical Permit2 (`SignatureTransfer`), deployed at the same address on every chain via the
    ///         deterministic deployer. Used by `depositWithPermit2` for gasless-approval (signature) funding.
    ISignatureTransfer public constant PERMIT2 = ISignatureTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    IPoolManager public immutable poolManager;
    IStratumHook public immutable hook;

    /// @notice End-user owner of each zap-opened position (hook-side owner is the zap itself).
    mapping(bytes32 => address) public zapPositionOwner;

    constructor(IPoolManager poolManager_, IStratumHook hook_) {
        poolManager = poolManager_;
        hook = hook_;
    }

    struct CallbackData {
        PoolKey key;
        IPoolManager.ModifyLiquidityParams params;
        bytes hookData;
        // Address positive deltas are taken to: the zap on deposit (for the refund sweep), the
        // end user on withdrawal (proceeds, including any senior make-whole credit, go direct).
        address takeTo;
    }

    // -------------------------------------------------------------------------
    // Deposit / withdraw
    // -------------------------------------------------------------------------

    /// @notice Open a tranche position. Funding tokens are pulled from the caller unless
    ///         `useDeliveredBalance` is set, in which case tokens already held by the zap (e.g.
    ///         delivered by a Trading API swap with `recipient = zap`) are consumed.
    /// @dev Any balance of the pool's currencies remaining on the zap after the deposit is swept
    ///      to the caller (max-in refund). Invariant preserved: the zap never retains user funds
    ///      between transactions.
    /// @param key Target pool (must be a STRATUM pool or the hook reverts the add).
    /// @param tickLower Position lower tick.
    /// @param tickUpper Position upper tick.
    /// @param liquidity Liquidity to add (sized off-chain; unused funding is refunded).
    /// @param tranche Tranche to enter.
    /// @param userSalt Caller-chosen salt; the v4 salt becomes keccak256(caller, userSalt).
    /// @param amount0Max Max currency0 to pull from the caller (ignored in delivered mode).
    /// @param amount1Max Max currency1 to pull from the caller (ignored in delivered mode).
    /// @param useDeliveredBalance Consume tokens already on the zap instead of pulling.
    /// @return positionId The hook position id now owned (zap-side) by the caller.
    function deposit(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        TrancheType tranche,
        bytes32 userSalt,
        uint256 amount0Max,
        uint256 amount1Max,
        bool useDeliveredBalance
    ) external returns (bytes32 positionId) {
        if (liquidity == 0) revert ZeroLiquidity();
        if (key.currency0.isAddressZero()) revert NativeCurrencyNotSupported();

        bytes32 zapSalt = _zapSalt(msg.sender, userSalt);

        if (!useDeliveredBalance) {
            if (amount0Max > 0) {
                IERC20(Currency.unwrap(key.currency0)).safeTransferFrom(msg.sender, address(this), amount0Max);
            }
            if (amount1Max > 0) {
                IERC20(Currency.unwrap(key.currency1)).safeTransferFrom(msg.sender, address(this), amount1Max);
            }
        }

        positionId = _openAndRecord(key, tickLower, tickUpper, liquidity, tranche, zapSalt);
    }

    /// @notice Open a tranche position funding it through a single Permit2 signature instead of a prior ERC-20
    ///         approval (D-6, gasless-approval UX). The user signs a Permit2 batch permit authorizing the zap
    ///         to pull up to `amount0Max`/`amount1Max` of the pool's two currencies; the zap pulls them to
    ///         itself, opens the position, and sweeps any unused remainder back, exactly like `deposit`.
    /// @dev The zap holds NO new privilege: Permit2 transfers are bounded by the user's own signed permit
    ///      (token, amount, nonce, deadline), so a buggy zap can still only touch the funds the user signed for
    ///      this call. The user must have approved Permit2 once on each token (the standard one-time Permit2
    ///      setup), after which all future deposits are signature-only. The permit's `permitted` array must be
    ///      ordered [currency0, currency1] and the zap must be the signed spender.
    /// @param key Target STRATUM pool.
    /// @param tickLower Position lower tick.
    /// @param tickUpper Position upper tick.
    /// @param liquidity Liquidity to add (unused funding is refunded).
    /// @param tranche Tranche to enter.
    /// @param userSalt Caller-chosen salt; the v4 salt becomes keccak256(caller, userSalt).
    /// @param permit The Permit2 batch permit the caller signed (permitted[0]=currency0, permitted[1]=currency1).
    /// @param signature The caller's Permit2 signature over `permit` with this zap as spender.
    /// @return positionId The hook position id now owned (zap-side) by the caller.
    function depositWithPermit2(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        TrancheType tranche,
        bytes32 userSalt,
        ISignatureTransfer.PermitBatchTransferFrom calldata permit,
        bytes calldata signature
    ) external returns (bytes32 positionId) {
        if (liquidity == 0) revert ZeroLiquidity();
        if (key.currency0.isAddressZero()) revert NativeCurrencyNotSupported();
        if (permit.permitted.length != 2) revert Permit2BadLength();
        if (
            permit.permitted[0].token != Currency.unwrap(key.currency0)
                || permit.permitted[1].token != Currency.unwrap(key.currency1)
        ) revert Permit2TokenMismatch();

        // Pull both currencies to the zap in one signed transfer; requestedAmount is the user's signed cap.
        ISignatureTransfer.SignatureTransferDetails[] memory details =
            new ISignatureTransfer.SignatureTransferDetails[](2);
        details[0] = ISignatureTransfer.SignatureTransferDetails({
            to: address(this), requestedAmount: permit.permitted[0].amount
        });
        details[1] = ISignatureTransfer.SignatureTransferDetails({
            to: address(this), requestedAmount: permit.permitted[1].amount
        });
        PERMIT2.permitTransferFrom(permit, details, msg.sender, signature);

        positionId = _openAndRecord(key, tickLower, tickUpper, liquidity, tranche, _zapSalt(msg.sender, userSalt));
    }

    /// @dev Shared tail for both deposit paths: assumes funding tokens are already on the zap, opens the v4
    ///      position through the unlock callback, records the end-user owner, and sweeps the unused remainder
    ///      back to the caller (the zap never retains funds between transactions).
    function _openAndRecord(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        TrancheType tranche,
        bytes32 zapSalt
    ) internal returns (bytes32 positionId) {
        positionId = keccak256(abi.encode(address(this), tickLower, tickUpper, zapSalt));

        poolManager.unlock(
            abi.encode(
                CallbackData({
                    key: key,
                    params: IPoolManager.ModifyLiquidityParams({
                        tickLower: tickLower,
                        tickUpper: tickUpper,
                        liquidityDelta: int256(uint256(liquidity)),
                        salt: zapSalt
                    }),
                    hookData: abi.encode(tranche, zapSalt),
                    takeTo: address(this)
                })
            )
        );

        zapPositionOwner[positionId] = msg.sender;

        // Max-in refund: return every remaining unit of the pool's currencies to the caller.
        _sweep(key.currency0, msg.sender);
        _sweep(key.currency1, msg.sender);

        emit ZapDeposited(key.toId(), positionId, msg.sender, tranche, liquidity);
    }

    /// @notice Close a zap-opened position in full (the hook requires full-position removal) and
    ///         deliver all proceeds - including any senior make-whole credit - to the recorded user.
    /// @param key The pool the position lives in.
    /// @param tickLower Position lower tick.
    /// @param tickUpper Position upper tick.
    /// @param userSalt The salt used at deposit.
    function withdraw(PoolKey calldata key, int24 tickLower, int24 tickUpper, bytes32 userSalt) external {
        bytes32 zapSalt = _zapSalt(msg.sender, userSalt);
        bytes32 positionId = keccak256(abi.encode(address(this), tickLower, tickUpper, zapSalt));
        if (zapPositionOwner[positionId] != msg.sender) revert NotZapPositionOwner();

        TranchePosition memory pos = hook.position(positionId);
        if (pos.owner != address(this)) revert PositionUnknown();

        delete zapPositionOwner[positionId];

        poolManager.unlock(
            abi.encode(
                CallbackData({
                    key: key,
                    params: IPoolManager.ModifyLiquidityParams({
                        tickLower: tickLower,
                        tickUpper: tickUpper,
                        liquidityDelta: -int256(uint256(pos.liquidity)),
                        salt: zapSalt
                    }),
                    hookData: abi.encode(pos.tranche, zapSalt),
                    takeTo: msg.sender
                })
            )
        );

        emit ZapWithdrawn(key.toId(), positionId, msg.sender);
    }

    /// @inheritdoc IUnlockCallback
    /// @dev Settles negative deltas from the zap's own balance and takes positive deltas to
    ///      `takeTo`. The hook may adjust the removal deltas (IL clawback / senior make-whole);
    ///      per the hook's R-C1 guarantee the zap's per-currency delta is never pushed negative on
    ///      removal, so withdrawals always settle.
    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        CallbackData memory data = abi.decode(rawData, (CallbackData));

        poolManager.modifyLiquidity(data.key, data.params, data.hookData);

        _settleOrTake(data.key.currency0, data.takeTo);
        _settleOrTake(data.key.currency1, data.takeTo);
        return "";
    }

    // -------------------------------------------------------------------------
    // Owner-surface forwarders (the zap is the hook-side owner)
    // -------------------------------------------------------------------------

    /// @notice Forward `claimVested` for a zap-owned position. Gated to the recorded user.
    /// @param positionId The hook position id.
    /// @return claimed The vested amount reported by the hook.
    function claimVested(bytes32 positionId) external returns (uint256 claimed) {
        if (zapPositionOwner[positionId] != msg.sender) revert NotZapPositionOwner();
        return hook.claimVested(positionId);
    }

    /// @notice Forward `approveMigrator` for a zap-owned position. Gated to the recorded user.
    /// @param positionId The hook position id.
    /// @param migrator Address allowed to migrate the position's tranche; address(0) revokes.
    function approveMigrator(bytes32 positionId, address migrator) external {
        if (zapPositionOwner[positionId] != msg.sender) revert NotZapPositionOwner();
        hook.approveMigrator(positionId, migrator);
    }

    /// @notice Forward `migrateTranchePosition` for a zap-owned position. Gated to the recorded user.
    /// @param positionId The hook position id.
    /// @param newTranche Destination tranche.
    /// @return carriedPrincipal Principal carried into the destination tranche.
    function migrateTranchePosition(bytes32 positionId, TrancheType newTranche)
        external
        returns (uint256 carriedPrincipal)
    {
        if (zapPositionOwner[positionId] != msg.sender) revert NotZapPositionOwner();
        return hook.migrateTranchePosition(positionId, newTranche);
    }

    // -------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------

    function _zapSalt(address user, bytes32 userSalt) internal pure returns (bytes32) {
        return keccak256(abi.encode(user, userSalt));
    }

    /// @dev Resolve this contract's outstanding delta for `currency`: pay the PoolManager from the
    ///      zap's balance when negative, take to `takeTo` when positive.
    function _settleOrTake(Currency currency, address takeTo) internal {
        int256 delta = poolManager.currencyDelta(address(this), currency);
        if (delta < 0) {
            poolManager.sync(currency);
            IERC20(Currency.unwrap(currency)).safeTransfer(address(poolManager), uint256(-delta));
            poolManager.settle();
        } else if (delta > 0) {
            poolManager.take(currency, takeTo, uint256(delta));
        }
    }

    function _sweep(Currency currency, address to) internal {
        uint256 bal = IERC20(Currency.unwrap(currency)).balanceOf(address(this));
        if (bal > 0) IERC20(Currency.unwrap(currency)).safeTransfer(to, bal);
    }
}
