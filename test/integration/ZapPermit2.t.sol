// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { Deployers } from "@uniswap/v4-core/test/utils/Deployers.sol";
import { LPFeeLibrary } from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";
import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";
import { DeployPermit2 } from "permit2/test/utils/DeployPermit2.sol";

import { StratumHook } from "../../src/StratumHook.sol";
import { IStratumHook } from "../../src/interfaces/IStratumHook.sol";
import { PoolInitParams, TrancheType } from "../../src/StratumTypes.sol";
import { StratumZap } from "../../src/peripherals/zap/StratumZap.sol";
import { HookMiner } from "../utils/HookMiner.sol";
import { StratumFlags } from "../utils/StratumFlags.sol";

/// @title ZapPermit2Test
/// @notice D-6: funding a zap deposit through a single Permit2 signature instead of a prior ERC-20 approval.
///         Proves a real Permit2 (deployed at its canonical address) authorizes the pull, that the zap holds no
///         standing allowance, and that the signed cap bounds the transfer.
contract ZapPermit2Test is Test, Deployers, DeployPermit2 {
    using PoolIdLibrary for PoolKey;

    // Canonical deterministic Permit2 address (matches StratumZap.PERMIT2).
    address constant PERMIT2_ADDR = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    bytes32 constant TOKEN_PERMISSIONS_TYPEHASH = keccak256("TokenPermissions(address token,uint256 amount)");
    bytes32 constant PERMIT_BATCH_TYPEHASH = keccak256(
        "PermitBatchTransferFrom(TokenPermissions[] permitted,address spender,uint256 nonce,uint256 deadline)TokenPermissions(address token,uint256 amount)"
    );

    StratumHook hook;
    StratumZap zap;
    PoolInitParams params;

    uint256 aliceKey = 0xA11CE;
    address alice;

    function setUp() public {
        alice = vm.addr(aliceKey);

        // Etch the real Permit2 at its canonical address from the precompiled blob (DeployPermit2). The blob's
        // baked DOMAIN_SEPARATOR is computed for the canonical address on chainid 31337 (the foundry default).
        deployPermit2();

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
            protocolFeeBps: 100,
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
        hook.preparePool(key, params);
        manager.initialize(key, SQRT_PRICE_1_1);

        zap = new StratumZap(IPoolManager(address(manager)), IStratumHook(address(hook)));

        // Alice funds and grants the ONE-TIME Permit2 approval (not the zap). The zap holds no allowance.
        MockERC20(Currency.unwrap(currency0)).mint(alice, 1e24);
        MockERC20(Currency.unwrap(currency1)).mint(alice, 1e24);
        vm.startPrank(alice);
        MockERC20(Currency.unwrap(currency0)).approve(PERMIT2_ADDR, type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(PERMIT2_ADDR, type(uint256).max);
        vm.stopPrank();

        // Seed junior liquidity so the pool is live.
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -6000, tickUpper: 6000, liquidityDelta: 1e21, salt: bytes32("seed-j")
            }),
            abi.encode(TrancheType.JUNIOR, bytes32("seed-j"))
        );
    }

    function _buildPermit(uint256 amount0Max, uint256 amount1Max, uint256 nonce)
        internal
        view
        returns (ISignatureTransfer.PermitBatchTransferFrom memory permit, bytes memory sig)
    {
        ISignatureTransfer.TokenPermissions[] memory permitted = new ISignatureTransfer.TokenPermissions[](2);
        permitted[0] =
            ISignatureTransfer.TokenPermissions({ token: Currency.unwrap(currency0), amount: amount0Max });
        permitted[1] =
            ISignatureTransfer.TokenPermissions({ token: Currency.unwrap(currency1), amount: amount1Max });
        permit = ISignatureTransfer.PermitBatchTransferFrom({
            permitted: permitted, nonce: nonce, deadline: block.timestamp + 1 hours
        });

        bytes32[] memory tp = new bytes32[](2);
        tp[0] = keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, permitted[0]));
        tp[1] = keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, permitted[1]));
        bytes32 structHash = keccak256(
            abi.encode(
                PERMIT_BATCH_TYPEHASH,
                keccak256(abi.encodePacked(tp)),
                address(zap), // spender == the zap
                permit.nonce,
                permit.deadline
            )
        );
        bytes32 domainSeparator = ISignatureTransfer(PERMIT2_ADDR).DOMAIN_SEPARATOR();
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(aliceKey, digest);
        sig = bytes.concat(r, s, bytes1(v));
    }

    /// @notice A signature-funded deposit opens a position, the zap retains nothing, and crucially the zap
    ///         never held a standing ERC-20 allowance on alice's tokens.
    function test_depositWithPermit2_opensPosition() public {
        PoolId id = key.toId();
        uint256 juniorBefore = hook.poolState(id).juniorTVL;

        // The zap has zero allowance: a plain (non-permit) deposit would revert on transferFrom.
        assertEq(MockERC20(Currency.unwrap(currency0)).allowance(alice, address(zap)), 0, "no zap allowance");

        (ISignatureTransfer.PermitBatchTransferFrom memory permit, bytes memory sig) = _buildPermit(1e22, 1e22, 0);

        vm.prank(alice);
        bytes32 positionId = zap.depositWithPermit2(key, -6000, 6000, 1e20, TrancheType.JUNIOR, bytes32("p1"), permit, sig);

        assertEq(zap.zapPositionOwner(positionId), alice, "zap records alice");
        assertEq(hook.position(positionId).owner, address(zap), "hook records the zap");
        assertGt(hook.poolState(id).juniorTVL, juniorBefore, "junior TVL grew");
        assertEq(MockERC20(Currency.unwrap(currency0)).balanceOf(address(zap)), 0, "zap holds no token0");
        assertEq(MockERC20(Currency.unwrap(currency1)).balanceOf(address(zap)), 0, "zap holds no token1");

        // Round-trips like any zap position: alice can withdraw it back.
        vm.prank(alice);
        zap.withdraw(key, -6000, 6000, bytes32("p1"));
        assertEq(hook.position(positionId).owner, address(0), "position settled");
    }

    /// @notice A replayed signature (same nonce) reverts: Permit2's nonce bitmap is single-use.
    function test_depositWithPermit2_nonceReplayReverts() public {
        (ISignatureTransfer.PermitBatchTransferFrom memory permit, bytes memory sig) = _buildPermit(1e22, 1e22, 7);
        vm.prank(alice);
        zap.depositWithPermit2(key, -6000, 6000, 1e20, TrancheType.JUNIOR, bytes32("n1"), permit, sig);

        // Reusing the same nonce must fail inside Permit2 (InvalidNonce).
        vm.prank(alice);
        vm.expectRevert();
        zap.depositWithPermit2(key, -6000, 6000, 1e20, TrancheType.JUNIOR, bytes32("n2"), permit, sig);
    }

    /// @notice A permit whose tokens don't match the pool's currencies is rejected before any transfer.
    function test_depositWithPermit2_tokenMismatchReverts() public {
        (ISignatureTransfer.PermitBatchTransferFrom memory permit, bytes memory sig) = _buildPermit(1e22, 1e22, 1);
        // Corrupt the first token so it no longer matches currency0.
        permit.permitted[0].token = address(0xdead);
        vm.prank(alice);
        vm.expectRevert(StratumZap.Permit2TokenMismatch.selector);
        zap.depositWithPermit2(key, -6000, 6000, 1e20, TrancheType.JUNIOR, bytes32("m1"), permit, sig);
    }
}
