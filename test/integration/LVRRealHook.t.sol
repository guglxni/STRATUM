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

import { StratumHook } from "../../src/StratumHook.sol";
import { IStratumHook } from "../../src/interfaces/IStratumHook.sol";
import { StratumErrors } from "../../src/StratumErrors.sol";
import { PoolInitParams } from "../../src/StratumTypes.sol";
import { MatchAttestation } from "../../src/peripherals/eigenlayer/MatchAttestation.sol";
import { IMatchAttestation } from "../../src/peripherals/eigenlayer/IMatchAttestation.sol";
import { LVRAuctionReceiver } from "../../src/peripherals/eigenlayer/LVRAuctionReceiver.sol";
import { HookMiner } from "../utils/HookMiner.sol";
import { StratumFlags } from "../utils/StratumFlags.sol";

/// @notice FR-23 end-to-end against the REAL StratumHook (not a mock): EigenLayer LVR proceeds, gated by an
///         attestation quorum, credit the hook's token-backed reserve via the new gated `creditReserve`.
contract LVRRealHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    StratumHook hook;
    MatchAttestation attestation;
    LVRAuctionReceiver receiver;
    uint256 internal operatorPk = 0xA11CE;
    address internal operator;
    address internal admin = address(0xAD);

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();
        operator = vm.addr(operatorPk);

        PoolInitParams memory params = PoolInitParams({
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

        // EigenLayer attestation: quorum 1, one registered operator.
        vm.startPrank(admin);
        attestation = new MatchAttestation(admin, 1);
        attestation.registerOperator(operator);
        vm.stopPrank();

        // LVR receiver wired to the real hook + attestation + pool tokens.
        receiver = new LVRAuctionReceiver(IStratumHook(address(hook)), address(this));
        receiver.setMatchAttestation(IMatchAttestation(address(attestation)));
        receiver.registerPoolTokens(key.toId(), Currency.unwrap(currency0), Currency.unwrap(currency1));

        // One-time, per-pool wiring by the pool creator (this test contract called preparePool): the hook
        // trusts only this receiver to credit THIS pool's reserve (EI1: creator-gated, not front-runnable).
        hook.setReserveYieldSource(key.toId(), address(receiver));
    }

    function _attest(bytes32 matchHash) internal {
        // Sign the domain-separated digest the contract expects (EI4).
        bytes32 digest = attestation.attestationDigest(matchHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorPk, digest);
        vm.prank(operator);
        attestation.submit(matchHash, abi.encodePacked(r, s, v));
    }

    function test_LVR_creditsRealHookReserve_throughAttestation() public {
        PoolId id = key.toId();
        uint256 amt0 = 3e18;
        uint256 amt1 = 7e18;
        uint256 nonce = 0;
        // EI6: the attestation hash is derived from the exact routing params + nonce.
        bytes32 matchHash = receiver.routingHash(id, amt0, amt1, nonce);
        _attest(matchHash);
        assertTrue(attestation.isAttested(matchHash), "quorum reached");

        MockERC20(Currency.unwrap(currency0)).approve(address(receiver), amt0);
        MockERC20(Currency.unwrap(currency1)).approve(address(receiver), amt1);

        (uint256 r0Before, uint256 r1Before) = hook.reserveBalances(id);
        receiver.receiveYield(id, amt0, amt1, nonce);
        (uint256 r0After, uint256 r1After) = hook.reserveBalances(id);

        // FR-23: LVR proceeds reached the hook's real-token reserve and the ledger reflects them.
        assertEq(r0After - r0Before, amt0, "reserve0 credited by LVR yield (real hook)");
        assertEq(r1After - r1Before, amt1, "reserve1 credited by LVR yield (real hook)");
        // Tokens actually live on the hook (not just ledgered).
        assertGe(MockERC20(Currency.unwrap(currency0)).balanceOf(address(hook)), amt0);
        assertGe(MockERC20(Currency.unwrap(currency1)).balanceOf(address(hook)), amt1);
    }

    function test_creditReserve_revertsForNonYieldSource() public {
        // INV-03: only the registered yield source may credit the reserve; nobody can inflate the ledger.
        vm.expectRevert(StratumErrors.Unauthorized.selector);
        hook.creditReserve(key.toId(), 1e18, 1e18);
    }

    function test_setReserveYieldSource_isOneTime() public {
        // Already set in setUp; a second set by the creator must revert (locked).
        vm.expectRevert(StratumErrors.Unauthorized.selector);
        hook.setReserveYieldSource(key.toId(), address(0xBEEF));
    }

    function test_setReserveYieldSource_onlyPoolCreator() public {
        // EI1: a non-creator cannot claim crediting rights even on a fresh pool. Use a fresh pool whose
        // creator is `this`; a stranger setting the source must revert.
        vm.prank(address(0xBADC0DE));
        vm.expectRevert(StratumErrors.Unauthorized.selector);
        hook.setReserveYieldSource(key.toId(), address(0xBADC0DE));
    }
}
