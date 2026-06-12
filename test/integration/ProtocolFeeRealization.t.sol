// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { Deployers } from "@uniswap/v4-core/test/utils/Deployers.sol";
import { LPFeeLibrary } from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";

import { StratumHook } from "../../src/StratumHook.sol";
import { PoolInitParams, TrancheType } from "../../src/StratumTypes.sol";
import { StratumErrors } from "../../src/StratumErrors.sol";
import { HookMiner } from "../utils/HookMiner.sol";
import { StratumFlags } from "../utils/StratumFlags.sol";

/// @title ProtocolFeeRealizationTest
/// @notice D-1: realizing the protocol fee as a real-token swap surcharge via the AFTER_SWAP_RETURNS_DELTA
///         permission. Verifies the opt-in default is byte-for-byte the legacy accounting-only behavior, that
///         enabling it pulls real tokens into the token-backed reserve, that collection is creator-gated and
///         conserves tokens, and that the hook actually custodies what its ledger claims.
contract ProtocolFeeRealizationTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    StratumHook hook;
    PoolInitParams params;
    address creator;

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        params = PoolInitParams({
            targetAPYBps: 500,
            minCoverageRatioBps: 3000,
            maxSeniorILExposureBps: 500,
            smoothingEpochSeconds: 1 days,
            baseFeeBps: 30,
            minFeeBps: 5,
            maxFeeBps: 200,
            protocolFeeBps: 1000, // 10% protocol weight so the surcharge is clearly observable
            peripheralRegistry: address(0),
            coverageTriggerBps: 3000,
            coverageTargetBps: 3000
        });

        (address hookAddr, bytes32 salt) = HookMiner.find(
            address(this), StratumFlags.STRATUM_HOOK_FLAGS, type(StratumHook).creationCode, abi.encode(address(manager))
        );
        hook = new StratumHook{ salt: salt }(IPoolManager(address(manager)));
        assertEq(address(hook), hookAddr);

        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        creator = address(this); // preparePool caller is the creator / fee authority
        hook.preparePool(key, params);
        manager.initialize(key, SQRT_PRICE_1_1);
    }

    function _seedJunior() internal {
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -6000, tickUpper: 6000, liquidityDelta: 1e21, salt: bytes32("seed-j")
            }),
            abi.encode(TrancheType.JUNIOR, bytes32("seed-j"))
        );
    }

    function _swap(uint256 amount) internal {
        swapRouterNoChecks.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(-3000)
            })
        );
    }

    /// @notice Default (realization OFF) is the legacy path: nonzero accounting ledger, NO real tokens held.
    function test_default_isAccountingOnly_noRealTokens() public {
        _seedJunior();
        PoolId id = key.toId();
        assertFalse(hook.protocolFeeRealization(id), "realization off by default");

        _swap(1e20);

        assertGt(hook.protocolFeesAccrued(id), 0, "accounting ledger still accrues (A-15)");
        (uint256 p0, uint256 p1) = hook.protocolFeeReserveBalances(id);
        assertEq(p0 + p1, 0, "no real protocol tokens taken when realization is off");
    }

    /// @notice With realization ON a zeroForOne exact-input swap pulls real token1 (the unspecified output leg)
    ///         into the protocol-fee reserve, and the hook actually custodies at least what the ledger claims.
    function test_realization_takesRealTokensIntoReserve() public {
        _seedJunior();
        PoolId id = key.toId();
        hook.setProtocolFeeRealization(id, true);
        assertTrue(hook.protocolFeeRealization(id), "realization enabled");

        _swap(1e20);

        (uint256 p0, uint256 p1) = hook.protocolFeeReserveBalances(id);
        assertEq(p0, 0, "specified=token0 -> surcharge taken in token1 only");
        assertGt(p1, 0, "real token1 surcharge realized into the reserve");

        // The hook must hold at least the token1 it claims (it took the tokens during afterSwap).
        uint256 hookBal1 = MockERC20(Currency.unwrap(currency1)).balanceOf(address(hook));
        assertGe(hookBal1, p1, "hook custodies the realized protocol tokens");
    }

    /// @notice Collection is creator-gated, pays the held reserve to the recipient in real tokens, and zeroes
    ///         the ledger. Conservation: the recipient receives exactly the reserve, the hook keeps nothing.
    function test_collect_creatorGated_conserves() public {
        _seedJunior();
        PoolId id = key.toId();
        hook.setProtocolFeeRealization(id, true);
        _swap(1e20);

        (, uint256 p1) = hook.protocolFeeReserveBalances(id);
        assertGt(p1, 0, "reserve funded");

        address treasury = makeAddr("treasury");

        // Non-creator cannot collect or toggle.
        vm.startPrank(makeAddr("stranger"));
        vm.expectRevert(StratumErrors.Unauthorized.selector);
        hook.collectProtocolFees(id, treasury);
        vm.expectRevert(StratumErrors.Unauthorized.selector);
        hook.setProtocolFeeRealization(id, false);
        vm.stopPrank();

        uint256 treasuryBefore = MockERC20(Currency.unwrap(currency1)).balanceOf(treasury);
        (uint256 a0, uint256 a1) = hook.collectProtocolFees(id, treasury);
        assertEq(a0, 0, "no token0 protocol fees");
        assertEq(a1, p1, "collected exactly the token1 reserve");
        assertEq(
            MockERC20(Currency.unwrap(currency1)).balanceOf(treasury) - treasuryBefore, p1, "treasury received it"
        );

        (uint256 q0, uint256 q1) = hook.protocolFeeReserveBalances(id);
        assertEq(q0 + q1, 0, "ledger zeroed after collection");
    }

    /// @notice Toggling realization off mid-life reverts to accounting-only for subsequent swaps; the already
    ///         realized reserve is untouched and remains collectable.
    function test_toggleOff_revertsToAccountingOnly() public {
        _seedJunior();
        PoolId id = key.toId();
        hook.setProtocolFeeRealization(id, true);
        _swap(1e20);
        (, uint256 p1AfterOn) = hook.protocolFeeReserveBalances(id);
        assertGt(p1AfterOn, 0, "first swap realized");

        hook.setProtocolFeeRealization(id, false);
        uint256 accruedBefore = hook.protocolFeesAccrued(id);
        _swap(1e20);

        (, uint256 p1AfterOff) = hook.protocolFeeReserveBalances(id);
        assertEq(p1AfterOff, p1AfterOn, "no new real tokens taken while off");
        assertGt(hook.protocolFeesAccrued(id), accruedBefore, "accounting ledger resumes");
    }
}
