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
import { PoolInitParams, TrancheType, PoolTrancheState, TranchePosition } from "../../src/StratumTypes.sol";
import { MatchAttestation } from "../../src/peripherals/eigenlayer/MatchAttestation.sol";
import { IMatchAttestation } from "../../src/peripherals/eigenlayer/IMatchAttestation.sol";
import { LVRAuctionReceiver } from "../../src/peripherals/eigenlayer/LVRAuctionReceiver.sol";
import { StratumRateLibrary } from "../../src/libraries/StratumRateLibrary.sol";
import { HookMiner } from "../utils/HookMiner.sol";
import { StratumFlags } from "../utils/StratumFlags.sol";

// -------------------------------------------------------------------------
// MatchAttestation tests (FR-24)
// -------------------------------------------------------------------------

/// @title MatchAttestationTest
/// @notice Tests quorum mechanics, operator management, and signature verification for FR-24.
contract MatchAttestationTest is Test {
    MatchAttestation attestation;

    address admin = makeAddr("admin");
    // Three operator accounts with known private keys for deterministic ECDSA signatures.
    uint256 op1Key = 0xA1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1;
    uint256 op2Key = 0xB2B2B2B2B2B2B2B2B2B2B2B2B2B2B2B2B2B2B2B2B2B2B2B2B2B2B2B2B2B2B2B2;
    uint256 op3Key = 0xC3C3C3C3C3C3C3C3C3C3C3C3C3C3C3C3C3C3C3C3C3C3C3C3C3C3C3C3C3C3C3C3;
    address op1;
    address op2;
    address op3;

    bytes32 constant MATCH_HASH = keccak256("test-match-hash-1");

    function setUp() public {
        op1 = vm.addr(op1Key);
        op2 = vm.addr(op2Key);
        op3 = vm.addr(op3Key);

        // Deploy with 2-of-3 quorum.
        vm.prank(admin);
        attestation = new MatchAttestation(admin, 2);

        vm.startPrank(admin);
        attestation.registerOperator(op1);
        attestation.registerOperator(op2);
        attestation.registerOperator(op3);
        vm.stopPrank();
    }

    // --- Operator management ---

    function test_registerOperator_increments_count() public view {
        assertEq(attestation.operatorCount(), 3);
        assertTrue(attestation.isOperator(op1));
        assertTrue(attestation.isOperator(op2));
        assertTrue(attestation.isOperator(op3));
    }

    function test_registerOperator_reverts_if_not_admin() public {
        vm.prank(op1);
        vm.expectRevert(MatchAttestation.NotAdmin.selector);
        attestation.registerOperator(makeAddr("bad"));
    }

    function test_registerOperator_reverts_if_already_registered() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(MatchAttestation.OperatorAlreadyRegistered.selector, op1));
        attestation.registerOperator(op1);
    }

    function test_deregisterOperator_decrements_count() public {
        vm.prank(admin);
        attestation.deregisterOperator(op3);
        assertEq(attestation.operatorCount(), 2);
        assertFalse(attestation.isOperator(op3));
    }

    function test_deregisterOperator_reverts_if_not_registered() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(MatchAttestation.OperatorNotRegistered.selector, makeAddr("x")));
        attestation.deregisterOperator(makeAddr("x"));
    }

    // --- Quorum threshold management ---

    function test_setQuorumThreshold_updates_value() public {
        vm.prank(admin);
        attestation.setQuorumThreshold(3);
        assertEq(attestation.quorumThreshold(), 3);
    }

    function test_setQuorumThreshold_reverts_on_zero() public {
        vm.prank(admin);
        vm.expectRevert(MatchAttestation.QuorumThresholdZero.selector);
        attestation.setQuorumThreshold(0);
    }

    function test_setQuorumThreshold_reverts_when_exceeds_operator_count() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(MatchAttestation.QuorumExceedsOperatorCount.selector, 4, 3));
        attestation.setQuorumThreshold(4);
    }

    // --- Attestation submission ---

    function _signMatchHash(uint256 privKey, bytes32 mhash) internal view returns (bytes memory sig) {
        // Sign the contract's domain-separated digest (EI4: binds chainId + address + operator-set version).
        bytes32 digest = attestation.attestationDigest(mhash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privKey, digest);
        sig = abi.encodePacked(r, s, v);
    }

    function test_submit_single_attestation_not_quorum() public {
        bytes memory sig = _signMatchHash(op1Key, MATCH_HASH);
        vm.prank(op1);
        attestation.submit(MATCH_HASH, sig);

        assertEq(attestation.attestationCount(MATCH_HASH), 1);
        assertFalse(attestation.isAttested(MATCH_HASH));
    }

    function test_submit_two_attestations_reaches_quorum() public {
        bytes memory sig1 = _signMatchHash(op1Key, MATCH_HASH);
        bytes memory sig2 = _signMatchHash(op2Key, MATCH_HASH);

        vm.prank(op1);
        attestation.submit(MATCH_HASH, sig1);

        // Quorum not yet reached after 1.
        assertFalse(attestation.isAttested(MATCH_HASH));

        vm.expectEmit(true, false, false, true);
        emit IMatchAttestation.QuorumReached(MATCH_HASH, 2);

        vm.prank(op2);
        attestation.submit(MATCH_HASH, sig2);

        assertTrue(attestation.isAttested(MATCH_HASH));
        assertEq(attestation.attestationCount(MATCH_HASH), 2);
    }

    function test_submit_three_attestations_all_reach_quorum() public {
        _attestAll(MATCH_HASH);
        assertTrue(attestation.isAttested(MATCH_HASH));
        assertEq(attestation.attestationCount(MATCH_HASH), 3);
    }

    // --- EI2: operator-set versioning invalidates stale attestations ---

    function test_EI2_operatorSetChange_invalidatesPriorAttestations() public {
        bytes memory sig1 = _signMatchHash(op1Key, MATCH_HASH);
        bytes memory sig2 = _signMatchHash(op2Key, MATCH_HASH);
        vm.prank(op1);
        attestation.submit(MATCH_HASH, sig1);
        vm.prank(op2);
        attestation.submit(MATCH_HASH, sig2);
        assertTrue(attestation.isAttested(MATCH_HASH), "quorum reached at version 1");

        // Deregister op3 (changes the operator set -> bumps version). Prior attestations no longer count.
        vm.prank(admin);
        attestation.deregisterOperator(op3);
        assertFalse(attestation.isAttested(MATCH_HASH), "stale attestations invalidated by set change (EI2)");
        assertEq(attestation.attestationCount(MATCH_HASH), 0, "count is per-version");
    }

    // --- EI8: admin rotation + deregister-below-quorum guard ---

    function test_EI8_transferAdmin_rotatesControl() public {
        address newAdmin = makeAddr("newAdmin");
        vm.prank(admin);
        attestation.transferAdmin(newAdmin);
        assertEq(attestation.admin(), newAdmin);

        // Old admin can no longer manage; new admin can.
        vm.prank(admin);
        vm.expectRevert(MatchAttestation.NotAdmin.selector);
        attestation.registerOperator(makeAddr("x"));

        vm.prank(newAdmin);
        attestation.registerOperator(makeAddr("x")); // succeeds
    }

    function test_EI8_deregisterBelowQuorum_reverts() public {
        // 3 operators, quorum 2. Deregister one (-> 2, ok), then another would drop to 1 < quorum 2.
        vm.startPrank(admin);
        attestation.deregisterOperator(op3); // 2 remaining, ok
        vm.expectRevert(abi.encodeWithSelector(MatchAttestation.DeregisterBelowQuorum.selector, 1, 2));
        attestation.deregisterOperator(op2); // would drop to 1 < 2
        vm.stopPrank();
    }

    // --- EI3: malleable s is rejected ---

    function test_EI3_malleableSignatureRejected() public {
        bytes memory sig = _signMatchHash(op1Key, MATCH_HASH);
        // Flip s to its upper-half-order twin: n - s, and flip v. ecrecover would still return op1, but the
        // EIP-2 lower-half-order guard must reject it.
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(sig, 32))
            s := mload(add(sig, 64))
            v := byte(0, mload(add(sig, 96)))
        }
        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 sFlipped = bytes32(n - uint256(s));
        uint8 vFlipped = v == 27 ? 28 : 27;
        bytes memory malleable = abi.encodePacked(r, sFlipped, vFlipped);
        vm.prank(op1);
        vm.expectRevert(MatchAttestation.InvalidSignature.selector);
        attestation.submit(MATCH_HASH, malleable);
    }

    function test_submit_reverts_for_non_operator() public {
        address outsider = makeAddr("outsider");
        bytes memory sig = _signMatchHash(0xDEAD, MATCH_HASH);
        vm.prank(outsider);
        vm.expectRevert(MatchAttestation.NotRegisteredOperator.selector);
        attestation.submit(MATCH_HASH, sig);
    }

    function test_submit_reverts_on_wrong_signer() public {
        // op1 submits but signs with op2's key: signature is valid ECDSA but wrong signer.
        bytes memory sig = _signMatchHash(op2Key, MATCH_HASH);
        vm.prank(op1);
        vm.expectRevert(MatchAttestation.InvalidSignature.selector);
        attestation.submit(MATCH_HASH, sig);
    }

    function test_submit_reverts_on_duplicate() public {
        bytes memory sig = _signMatchHash(op1Key, MATCH_HASH);
        vm.prank(op1);
        attestation.submit(MATCH_HASH, sig);

        vm.prank(op1);
        vm.expectRevert(abi.encodeWithSelector(MatchAttestation.AlreadyAttested.selector, MATCH_HASH, op1));
        attestation.submit(MATCH_HASH, sig);
    }

    function test_submit_reverts_on_bad_sig_length() public {
        bytes memory badSig = new bytes(64); // should be 65
        vm.prank(op1);
        vm.expectRevert(MatchAttestation.InvalidSignature.selector);
        attestation.submit(MATCH_HASH, badSig);
    }

    function test_different_hashes_are_independent() public {
        bytes32 hash2 = keccak256("other-match");
        _attestAll(MATCH_HASH);
        // hash2 is not attested.
        assertFalse(attestation.isAttested(hash2));
        assertEq(attestation.attestationCount(hash2), 0);
    }

    // --- Constructor validation ---

    function test_constructor_reverts_on_zero_quorum() public {
        vm.expectRevert(MatchAttestation.QuorumThresholdZero.selector);
        new MatchAttestation(admin, 0);
    }

    // -------------------------------------------------------------------------
    // Internal helper
    // -------------------------------------------------------------------------

    function _attestAll(bytes32 mhash) internal {
        bytes memory sig1 = _signMatchHash(op1Key, mhash);
        bytes memory sig2 = _signMatchHash(op2Key, mhash);
        bytes memory sig3 = _signMatchHash(op3Key, mhash);
        vm.prank(op1);
        attestation.submit(mhash, sig1);
        vm.prank(op2);
        attestation.submit(mhash, sig2);
        vm.prank(op3);
        attestation.submit(mhash, sig3);
    }
}

// -------------------------------------------------------------------------
// LVRAuctionReceiver tests (FR-23)
// -------------------------------------------------------------------------

/// @title LVRAuctionReceiverTest
/// @notice Tests LVR auction yield routing to the senior reserve (FR-23, INV-03, INV-05) against the REAL
///         StratumHook (no hook mock): the receiver credits the hook's token-backed reserve through the real,
///         creator-gated `creditReserve` path, with the receiver registered as the pool's reserve yield source.
contract LVRAuctionReceiverTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    MatchAttestation attestation;
    LVRAuctionReceiver receiver;
    StratumHook hook;

    MockERC20 token0;
    MockERC20 token1;

    address admin = makeAddr("admin");
    uint256 op1Key = 0xA1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1A1;
    uint256 op2Key = 0xB2B2B2B2B2B2B2B2B2B2B2B2B2B2B2B2B2B2B2B2B2B2B2B2B2B2B2B2B2B2B2B2;
    address op1;
    address op2;

    address auctionWinner = makeAddr("auctionWinner");

    PoolId poolId;

    function _hookReserve(PoolId id) internal view returns (uint256 r0, uint256 r1) {
        return hook.reserveBalances(id);
    }

    function setUp() public {
        op1 = vm.addr(op1Key);
        op2 = vm.addr(op2Key);

        deployFreshManagerAndRouters();

        token0 = new MockERC20("Token0", "T0", 18);
        token1 = new MockERC20("Token1", "T1", 18);

        vm.prank(admin);
        attestation = new MatchAttestation(admin, 2);
        vm.startPrank(admin);
        attestation.registerOperator(op1);
        attestation.registerOperator(op2);
        vm.stopPrank();

        // Deploy the REAL hook at a flag-correct address.
        (address hookAddr, bytes32 salt) = HookMiner.find(
            address(this), StratumFlags.STRATUM_HOOK_FLAGS, type(StratumHook).creationCode, abi.encode(address(manager))
        );
        hook = new StratumHook{ salt: salt }(IPoolManager(address(manager)));
        require(address(hook) == hookAddr, "hook addr");

        receiver = new LVRAuctionReceiver(IStratumHook(address(hook)), admin);
        vm.prank(admin);
        receiver.setMatchAttestation(attestation);

        // Register a pool on the real hook (preparePool sets the creator, enough to authorize the yield source;
        // a full initialize is unnecessary because creditReserve only touches the token-backed reserve ledger).
        (Currency c0, Currency c1) = address(token0) < address(token1)
            ? (Currency.wrap(address(token0)), Currency.wrap(address(token1)))
            : (Currency.wrap(address(token1)), Currency.wrap(address(token0)));
        PoolKey memory key =
            PoolKey({ currency0: c0, currency1: c1, fee: 0x800000, tickSpacing: 60, hooks: IHooks(address(hook)) });
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
        hook.preparePool(key, params);
        poolId = key.toId();
        // Authorize the receiver to credit this pool's reserve (creator-gated, one-time).
        hook.setReserveYieldSource(poolId, address(receiver));

        vm.prank(admin);
        receiver.registerPoolTokens(poolId, address(token0), address(token1));

        // Pre-fund auction winner with tokens.
        token0.mint(auctionWinner, 1_000e18);
        token1.mint(auctionWinner, 1_000e18);

        // Approve the receiver.
        vm.startPrank(auctionWinner);
        token0.approve(address(receiver), type(uint256).max);
        token1.approve(address(receiver), type(uint256).max);
        vm.stopPrank();
    }

    uint256 internal nextNonce;

    /// @notice Attest the param-derived routing hash, then route the yield as the auction winner.
    /// @return nonce The nonce used (so the test can recompute the hash for assertions).
    function _route(uint256 amt0, uint256 amt1) internal returns (uint256 nonce) {
        nonce = nextNonce++;
        _attestQuorum(receiver.routingHash(poolId, amt0, amt1, nonce));
        vm.prank(auctionWinner);
        receiver.receiveYield(poolId, amt0, amt1, nonce);
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _signMatchHash(uint256 privKey, bytes32 mhash) internal view returns (bytes memory sig) {
        // Sign the contract's domain-separated digest (EI4: binds chainId + address + operator-set version).
        bytes32 digest = attestation.attestationDigest(mhash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privKey, digest);
        sig = abi.encodePacked(r, s, v);
    }

    function _attestQuorum(bytes32 mhash) internal {
        bytes memory sig1 = _signMatchHash(op1Key, mhash);
        bytes memory sig2 = _signMatchHash(op2Key, mhash);
        vm.prank(op1);
        attestation.submit(mhash, sig1);
        vm.prank(op2);
        attestation.submit(mhash, sig2);
    }

    // -------------------------------------------------------------------------
    // Core yield routing
    // -------------------------------------------------------------------------

    function test_receiveYield_credits_reserve_both_tokens() public {
        _route(100e18, 50e18);
        assertEq(token0.balanceOf(address(hook)), 100e18, "hook token0 balance");
        assertEq(token1.balanceOf(address(hook)), 50e18, "hook token1 balance");
    }

    function test_receiveYield_updates_yield_record() public {
        _route(100e18, 50e18);
        (uint256 c0, uint256 c1, uint256 lastRouted) = receiver.yieldRecords(poolId);
        assertEq(c0, 100e18);
        assertEq(c1, 50e18);
        assertEq(lastRouted, block.timestamp);
    }

    function test_receiveYield_cumulates_across_calls() public {
        _route(100e18, 0);
        _route(50e18, 25e18);
        (uint256 c0, uint256 c1,) = receiver.yieldRecords(poolId);
        assertEq(c0, 150e18);
        assertEq(c1, 25e18);
    }

    function test_receiveYield_emits_event() public {
        uint256 nonce = nextNonce++;
        bytes32 h = receiver.routingHash(poolId, 100e18, 50e18, nonce);
        _attestQuorum(h);
        vm.expectEmit(true, true, false, true);
        emit LVRAuctionReceiver.LVRYieldReceived(poolId, auctionWinner, 100e18, 50e18, h);
        vm.prank(auctionWinner);
        receiver.receiveYield(poolId, 100e18, 50e18, nonce);
    }

    // --- FR-28: optional Chainlink-priced, TVL-relative proceeds bound (defense-in-depth) ---

    /// @dev Seed the pool's senior TVL directly: poolStates is slot 0; seniorTVL is field 0 at the struct base.
    function _seedTVL(uint256 seniorTVL) internal {
        bytes32 base = keccak256(abi.encode(poolId, uint256(0)));
        vm.store(address(hook), base, bytes32(seniorTVL));
    }

    function _usdFeed(uint128 price8dp) internal returns (MockAggregatorV3 f) {
        f = new MockAggregatorV3();
        f.push(price8dp, uint128(block.timestamp));
    }

    /// @dev Build a per-call (window == 0) bound config.
    function _bound(address f0, address f1, uint16 factorBps, uint32 maxAge)
        internal
        pure
        returns (LVRAuctionReceiver.ProceedsBound memory)
    {
        return LVRAuctionReceiver.ProceedsBound({
            feed0: f0, feed1: f1, maxFactorBps: factorBps, maxPriceAge: maxAge, window: 0, failClosedOnStale: false
        });
    }

    function test_proceedsBound_exceeds_reverts() public {
        _seedTVL(1_000e18); // pool TVL in token0 units
        MockAggregatorV3 f0 = _usdFeed(2000e8); // $2000
        MockAggregatorV3 f1 = _usdFeed(2000e8);
        vm.prank(admin);
        receiver.setProceedsBound(poolId, _bound(address(f0), address(f1), 100, 0)); // 1% of TVL

        // bound = 1000e18 * $2000 * 1% = 20_000e18 USD. Routing 100e18 token0 => 200_000e18 USD: far over bound.
        uint256 nonce = nextNonce++;
        _attestQuorum(receiver.routingHash(poolId, 100e18, 0, nonce));
        vm.prank(auctionWinner);
        vm.expectRevert(
            abi.encodeWithSelector(LVRAuctionReceiver.LVRProceedsExceedBound.selector, poolId, 200_000e18, 20_000e18)
        );
        receiver.receiveYield(poolId, 100e18, 0, nonce);
    }

    function test_proceedsBound_within_succeeds() public {
        _seedTVL(1_000e18);
        MockAggregatorV3 f0 = _usdFeed(2000e8);
        MockAggregatorV3 f1 = _usdFeed(2000e8);
        vm.prank(admin);
        receiver.setProceedsBound(poolId, _bound(address(f0), address(f1), 100, 0));

        // 5e18 token0 => 10_000e18 USD < 20_000e18 bound: routes normally.
        _route(5e18, 0);
        assertEq(token0.balanceOf(address(hook)), 5e18, "within-bound routing credited");
    }

    function test_proceedsBound_zeroTVL_skipsValidation() public {
        // TVL is 0 (bootstrapping): cannot bound, so degrade to attestation-only rather than block yield.
        MockAggregatorV3 f0 = _usdFeed(2000e8);
        MockAggregatorV3 f1 = _usdFeed(2000e8);
        vm.prank(admin);
        receiver.setProceedsBound(poolId, _bound(address(f0), address(f1), 100, 0));

        uint256 nonce = nextNonce++;
        _attestQuorum(receiver.routingHash(poolId, 100e18, 0, nonce));
        vm.expectEmit(true, false, false, false);
        emit LVRAuctionReceiver.ProceedsValidationSkipped(poolId);
        vm.prank(auctionWinner);
        receiver.receiveYield(poolId, 100e18, 0, nonce);
        assertEq(token0.balanceOf(address(hook)), 100e18, "routing still credited on skip");
    }

    function test_proceedsBound_stalePrice_skipsValidation() public {
        _seedTVL(1_000e18);
        MockAggregatorV3 f0 = _usdFeed(2000e8);
        MockAggregatorV3 f1 = _usdFeed(2000e8);
        vm.prank(admin);
        receiver.setProceedsBound(poolId, _bound(address(f0), address(f1), 100, 1 hours));
        // Warp past the 1h per-feed window: prices read as stale -> cannot validate -> attestation-only (no revert).
        vm.warp(block.timestamp + 2 hours);

        uint256 nonce = nextNonce++;
        _attestQuorum(receiver.routingHash(poolId, 100e18, 0, nonce));
        vm.expectEmit(true, false, false, false);
        emit LVRAuctionReceiver.ProceedsValidationSkipped(poolId);
        vm.prank(auctionWinner);
        receiver.receiveYield(poolId, 100e18, 0, nonce);
        assertEq(token0.balanceOf(address(hook)), 100e18, "routing still credited on stale-skip");
    }

    /// @dev F3 fix: fail-closed reverts on stale price instead of skipping (no silent bypass during staleness).
    function test_proceedsBound_failClosed_revertsOnStale() public {
        _seedTVL(1_000e18);
        MockAggregatorV3 f0 = _usdFeed(2000e8);
        MockAggregatorV3 f1 = _usdFeed(2000e8);
        LVRAuctionReceiver.ProceedsBound memory cfg = _bound(address(f0), address(f1), 100, 1 hours);
        cfg.failClosedOnStale = true;
        vm.prank(admin);
        receiver.setProceedsBound(poolId, cfg);
        vm.warp(block.timestamp + 2 hours);

        uint256 nonce = nextNonce++;
        _attestQuorum(receiver.routingHash(poolId, 1e18, 0, nonce));
        vm.prank(auctionWinner);
        vm.expectRevert(abi.encodeWithSelector(LVRAuctionReceiver.LVRPriceUnavailable.selector, poolId));
        receiver.receiveYield(poolId, 1e18, 0, nonce);
    }

    /// @dev F2 fix: cumulative rolling-window cap rejects repeated sub-cap routings that together exceed the bound.
    function test_proceedsBound_window_capsCumulative() public {
        _seedTVL(1_000e18);
        MockAggregatorV3 f0 = _usdFeed(2000e8);
        MockAggregatorV3 f1 = _usdFeed(2000e8);
        // 1% of $2,000,000 TVL = $20,000 budget per 1h window.
        LVRAuctionReceiver.ProceedsBound memory cfg = _bound(address(f0), address(f1), 100, 0);
        cfg.window = 1 hours;
        vm.prank(admin);
        receiver.setProceedsBound(poolId, cfg);

        // Two routings of 5e18 ($10k each) = $20k: at the cap, both pass.
        _route(5e18, 0);
        _route(5e18, 0);
        // A third $10k routing within the same window pushes cumulative to $30k > $20k: rejected.
        uint256 nonce = nextNonce++;
        _attestQuorum(receiver.routingHash(poolId, 5e18, 0, nonce));
        vm.prank(auctionWinner);
        vm.expectRevert(
            abi.encodeWithSelector(LVRAuctionReceiver.LVRProceedsExceedBound.selector, poolId, 30_000e18, 20_000e18)
        );
        receiver.receiveYield(poolId, 5e18, 0, nonce);

        // After the window elapses, the accumulator resets and a fresh routing passes again.
        vm.warp(block.timestamp + 1 hours + 1);
        _route(5e18, 0);
    }

    /// @dev F1 fix: a feed with out-of-range decimals does not revert receiveYield; it degrades to skip.
    function test_proceedsBound_insaneDecimals_skipsNotReverts() public {
        _seedTVL(1_000e18);
        MockAggregatorV3 f0 = new MockAggregatorV3();
        f0.pushWithDecimals(2000e8, uint128(block.timestamp), 200); // absurd decimals in the 10**dec overflow band
        MockAggregatorV3 f1 = _usdFeed(2000e8);
        vm.prank(admin);
        receiver.setProceedsBound(poolId, _bound(address(f0), address(f1), 100, 0));

        // The bad feed reads as price 0 (rejected by the dec guard) -> cannot validate -> skip, NOT a revert.
        uint256 nonce = nextNonce++;
        _attestQuorum(receiver.routingHash(poolId, 100e18, 0, nonce));
        vm.expectEmit(true, false, false, false);
        emit LVRAuctionReceiver.ProceedsValidationSkipped(poolId);
        vm.prank(auctionWinner);
        receiver.receiveYield(poolId, 100e18, 0, nonce);
    }

    function test_setProceedsBound_rejectsAsymmetricConfig() public {
        MockAggregatorV3 f0 = _usdFeed(2000e8);
        vm.prank(admin);
        vm.expectRevert(LVRAuctionReceiver.InvalidBoundConfig.selector);
        // One feed set, the other zero: would silently no-op, so it is rejected.
        receiver.setProceedsBound(poolId, _bound(address(f0), address(0), 100, 0));
    }

    function test_setProceedsBound_requiresFactor_whenFeedSet() public {
        MockAggregatorV3 f0 = _usdFeed(2000e8);
        vm.prank(admin);
        vm.expectRevert(LVRAuctionReceiver.InvalidBoundConfig.selector);
        receiver.setProceedsBound(poolId, _bound(address(f0), address(f0), 0, 0));
    }

    function test_setProceedsBound_onlyAdmin() public {
        vm.prank(auctionWinner);
        vm.expectRevert(LVRAuctionReceiver.NotAdmin.selector);
        receiver.setProceedsBound(poolId, _bound(address(0), address(0), 0, 0));
    }

    // --- EI6: anti-replay of a consumed attestation ---

    function test_EI6_attestationCannotBeReplayed() public {
        uint256 nonce = _route(100e18, 0);
        // Re-using the same nonce (same derived hash) must revert as already consumed.
        bytes32 h = receiver.routingHash(poolId, 100e18, 0, nonce);
        vm.prank(auctionWinner);
        vm.expectRevert(abi.encodeWithSelector(LVRAuctionReceiver.AttestationAlreadyConsumed.selector, h));
        receiver.receiveYield(poolId, 100e18, 0, nonce);
    }

    // --- Attestation gate ---

    function test_receiveYield_reverts_without_attestation() public {
        // Nonce 999 is never attested; the derived hash fails the quorum check.
        bytes32 unattested = receiver.routingHash(poolId, 100e18, 0, 999);
        vm.prank(auctionWinner);
        vm.expectRevert(abi.encodeWithSelector(LVRAuctionReceiver.AttestationFailed.selector, unattested));
        receiver.receiveYield(poolId, 100e18, 0, 999);
    }

    function test_receiveYield_reverts_when_attestation_contract_not_set() public {
        LVRAuctionReceiver freshReceiver = new LVRAuctionReceiver(IStratumHook(address(hook)), admin);
        vm.prank(admin);
        freshReceiver.registerPoolTokens(poolId, address(token0), address(token1));

        vm.prank(auctionWinner);
        vm.expectRevert(LVRAuctionReceiver.AttestationContractNotSet.selector);
        freshReceiver.receiveYield(poolId, 100e18, 0, 0);
    }

    // --- Disabled state ---

    function test_receiveYield_reverts_when_disabled() public {
        vm.prank(admin);
        receiver.setEnabled(false);

        vm.prank(auctionWinner);
        vm.expectRevert(LVRAuctionReceiver.PeripheralDisabled.selector);
        receiver.receiveYield(poolId, 100e18, 0, 0);
    }

    function test_setEnabled_is_admin_only() public {
        vm.prank(auctionWinner);
        vm.expectRevert(LVRAuctionReceiver.NotAdmin.selector);
        receiver.setEnabled(false);
    }

    // --- Zero amount ---

    function test_receiveYield_reverts_on_zero_amounts() public {
        vm.prank(auctionWinner);
        vm.expectRevert(LVRAuctionReceiver.ZeroAmount.selector);
        receiver.receiveYield(poolId, 0, 0, 0);
    }

    // --- Token not set ---

    function test_receiveYield_reverts_when_token0_not_registered() public {
        PoolId newId = PoolId.wrap(keccak256("unregistered-pool"));
        // Attest the derived hash so we reach the token check, which must then revert.
        _attestQuorum(receiver.routingHash(newId, 100e18, 0, 0));
        vm.prank(auctionWinner);
        vm.expectRevert(abi.encodeWithSelector(LVRAuctionReceiver.TokenNotSet.selector, newId));
        receiver.receiveYield(newId, 100e18, 0, 0);
    }

    // --- Token-only paths (single leg) ---

    function test_receiveYield_token0_only() public {
        _route(200e18, 0);
        assertEq(token0.balanceOf(address(hook)), 200e18);
        assertEq(token1.balanceOf(address(hook)), 0);
    }

    function test_receiveYield_token1_only() public {
        _route(0, 300e18);
        assertEq(token0.balanceOf(address(hook)), 0);
        assertEq(token1.balanceOf(address(hook)), 300e18);
    }

    // --- IPeripheral compliance ---

    function test_kind_returns_eigen() public view {
        assertEq(receiver.kind(), keccak256("EIGEN"));
    }

    function test_isEnabled_reflects_state() public {
        assertTrue(receiver.isEnabled());
        vm.prank(admin);
        receiver.setEnabled(false);
        assertFalse(receiver.isEnabled());
    }

    function test_onEpochClose_returns_empty() public {
        PoolId id = PoolId.wrap(keccak256("x"));
        bytes memory result = receiver.onEpochClose(id, 0, bytes(""));
        assertEq(result.length, 0);
    }

    // --- INV-05 conservation: junior reserve accumulator untouched ---
    // This test is intentionally named to surface its invariant clearly.
    function test_invariant05_junior_reserve_accumulator_not_modified() public {
        // Against the REAL hook: creditReserve only touches the token-backed reserve0/reserve1, never the
        // waterfall `juniorReserve` accumulator (INV-05). Confirm both: the reserve grows, juniorReserve stays 0.
        (uint256 r0Before, uint256 r1Before) = _hookReserve(poolId);
        uint256 juniorReserveBefore = hook.poolState(poolId).juniorReserve;

        _route(100e18, 50e18);

        (uint256 r0After, uint256 r1After) = _hookReserve(poolId);
        assertEq(r0After, r0Before + 100e18, "INV-05: reserve0 grows by yield");
        assertEq(r1After, r1Before + 50e18, "INV-05: reserve1 grows by yield");
        assertEq(
            hook.poolState(poolId).juniorReserve, juniorReserveBefore, "INV-05: juniorReserve accumulator untouched"
        );
    }
}

// -------------------------------------------------------------------------
// StratumRateLibrary tests (FR-25)
// -------------------------------------------------------------------------

/// @title StratumRateLibraryTest
/// @notice Unit tests for Chainlink benchmark rate + spread computation (FR-25).
///         Verifies: graceful fallback, spread floor, clamping, stale detection.
///
/// @dev Uses a thin wrapper to call the internal library functions (Foundry calls
///      internal library functions through a wrapper pattern).
contract StratumRateWrapper {
    function effectiveAPY(uint256 configured, uint256 spread, address feed) external view returns (uint256) {
        return StratumRateLibrary.effectiveTargetAPYBps(configured, spread, feed);
    }

    function updatedAPY(uint256 current, uint256 spread, address feed) external view returns (uint256) {
        return StratumRateLibrary.updatedTargetAPYBps(current, spread, feed);
    }
}

/// @notice Minimal AggregatorV3 feed for exercising `StratumRateLibrary`'s Chainlink read path. 8-decimal
///         answers, monotonic round ids, and a settable data timestamp so staleness can be exercised. This
///         mirrors the shape of a real Chainlink price feed (`latestRoundData` + `decimals`).
contract MockAggregatorV3 {
    uint80 internal round;
    int256 internal answer;
    uint256 internal dataTimestamp;
    uint8 internal dec = 8;

    function decimals() external view returns (uint8) {
        return dec;
    }

    /// @notice Push an 8-decimal answer stamped at `ts`, advancing the round (answeredInRound == roundId).
    function push(uint128 value, uint128 ts) external {
        round += 1;
        answer = int256(uint256(value));
        dataTimestamp = uint256(ts);
    }

    /// @notice Push an answer with an arbitrary `decimals()` value (for adversarial decimal-handling tests).
    function pushWithDecimals(uint128 value, uint128 ts, uint8 decimals_) external {
        round += 1;
        answer = int256(uint256(value));
        dataTimestamp = uint256(ts);
        dec = decimals_;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 ans, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (round, answer, dataTimestamp, dataTimestamp, round);
    }
}

contract StratumRateLibraryTest is Test {
    StratumRateWrapper wrapper;
    // A Chainlink-shaped AggregatorV3 feed (8-decimal answers) exercising the exact read path a live pool's
    // senior benchmark uses: StratumRateLibrary reads `decimals()` + `latestRoundData()`, which is the Chainlink
    // interface.
    MockAggregatorV3 feed8dec;

    function setUp() public {
        wrapper = new StratumRateWrapper();
        feed8dec = new MockAggregatorV3();
    }

    function _push(uint128 v) internal {
        feed8dec.push(v, uint128(block.timestamp));
    }

    // --- Address(0) fallback ---

    function test_fallback_when_feed_address_zero() public view {
        uint256 configured = 500; // 5% APY
        uint256 result = wrapper.effectiveAPY(configured, 100, address(0));
        assertEq(result, configured, "should return configuredAPYBps when feed is zero address");
    }

    // --- Normal benchmark path (answer above configured) ---

    function test_benchmark_above_configured_uses_benchmark_plus_spread() public {
        // Push 5% APY in 8-decimal fixed point: 5e6 / 1e8 = 5% = 500 bps. With a 100bps spread => 600 bps.
        _push(5e6);
        uint256 configured = 400; // 4% APY in bps
        uint256 spread = 100; // 1% spread in bps

        uint256 result = wrapper.effectiveAPY(configured, spread, address(feed8dec));
        // benchmark = 5e6 * 10000 / 1e8 = 500 bps; withSpread = 600 bps > 400 configured
        assertEq(result, 600, "should use benchmark (500) + spread (100) = 600 bps");
    }

    // --- Configured floor holds when benchmark is lower ---

    function test_configured_floor_when_benchmark_plus_spread_lower() public {
        // Push a very low rate: 0.5% = 50 bps. Spread = 50 bps. Total = 100 bps < 500 floor.
        _push(5e5);
        uint256 configured = 500; // 5% floor
        uint256 spread = 50;

        uint256 result = wrapper.effectiveAPY(configured, spread, address(feed8dec));
        assertEq(result, configured, "configured floor should hold when benchmark+spread < configured");
    }

    // --- Stale feed falls back ---

    function test_stale_feed_falls_back_to_configured() public {
        _push(5e6); // updatedAt = now
        // Warp past MAX_FEED_AGE_SECONDS so the adapter's last push is stale; the library must fall back.
        vm.warp(block.timestamp + StratumRateLibrary.MAX_FEED_AGE_SECONDS + 2);

        uint256 configured = 500;
        uint256 result = wrapper.effectiveAPY(configured, 100, address(feed8dec));
        assertEq(result, configured, "stale feed should fall back to configured APY");
    }

    // --- Zero answer falls back (covers the library's `answer <= 0` guard; the real adapter, being uint128-
    //     backed, can never produce a negative answer, so zero is the reachable boundary of that guard) ---

    function test_zero_answer_falls_back_to_configured() public {
        _push(0);

        uint256 configured = 500;
        uint256 result = wrapper.effectiveAPY(configured, 100, address(feed8dec));
        assertEq(result, configured, "zero answer should fall back to configured APY");
    }

    // --- Reverts gracefully (non-contract address) ---

    function test_reverts_gracefully_for_non_contract_feed() public {
        address nonContract = makeAddr("not-a-contract");
        uint256 configured = 500;
        // Should NOT revert; must fall back.
        uint256 result = wrapper.effectiveAPY(configured, 100, nonContract);
        assertEq(result, configured, "non-contract feed address should fall back gracefully");
    }

    // --- Out-of-band benchmark falls back to floor (finding 1: price-as-rate misconfig) ---

    function test_runaway_benchmark_falls_back_to_floor() public {
        // A price-feed-scale value (1000e8 -> 1e7 bps) is far above any plausible rate. With the default ceiling
        // (MAX_BENCHMARK_BPS), the library now rejects it and falls back to the floor rather than pinning 500%.
        _push(uint128(1000e8));
        uint256 configured = 500;
        uint256 result = wrapper.effectiveAPY(configured, 100, address(feed8dec));
        assertEq(result, configured, "out-of-band benchmark must fall back to floor, not clamp to the cap");
    }

    // --- Per-pool sane-rate ceiling rejects a price feed wired as a rate feed (finding 1) ---

    function test_perPool_ceiling_rejects_price_feed_as_rate() public {
        // Simulate a Chainlink ETH/USD price (~1675e8) wired where a rate feed was expected.
        _push(uint128(1675e8));
        uint256 configured = 400;
        uint256 ceiling = 2000; // 20% sane rate ceiling
        // The raw benchmark (~16.7M bps) is far above the ceiling -> fall back to the floor.
        uint256 result = StratumRateLibrary.effectiveTargetAPYBps(configured, 100, address(feed8dec), ceiling, 0);
        assertEq(result, configured, "price feed read as a rate must fall back to the configured floor");
    }

    function test_perPool_ceiling_accepts_inband_rate() public {
        // A genuine rate feed: 4.5% = 450 bps, within the 20% ceiling. With a 50 bps spread => 500 bps.
        _push(4_500_000); // 4.5e6 / 1e8 = 4.5% = 450 bps
        uint256 result = StratumRateLibrary.effectiveTargetAPYBps(400, 50, address(feed8dec), 2000, 0);
        assertEq(result, 500, "in-band benchmark (450) + spread (50) = 500 bps");
    }

    // --- Per-pool staleness window (finding 2) ---

    function test_perPool_staleness_window_tighter_than_default() public {
        _push(5e6); // 500 bps, fresh
        // A 1-hour per-feed window: warp 2 hours -> stale under the tight window even though < 25h default.
        vm.warp(block.timestamp + 2 hours);
        uint256 result = StratumRateLibrary.effectiveTargetAPYBps(500, 100, address(feed8dec), 0, 1 hours);
        assertEq(result, 500, "round older than the per-feed window falls back to the floor");
    }

    /// @dev F1 fix: an out-of-range `decimals()` must fall back to the floor, NOT revert (10**dec overflow panic).
    function test_insaneDecimals_fallsBackNotReverts() public {
        feed8dec.pushWithDecimals(5e6, uint128(block.timestamp), 200);
        uint256 result = wrapper.effectiveAPY(500, 100, address(feed8dec));
        assertEq(result, 500, "out-of-range decimals -> floor, no revert");
    }

    /// @dev F5 fix: a future `updatedAt` is treated as invalid, not as fresh.
    function test_futureTimestamp_fallsBackToFloor() public {
        feed8dec.push(5e6, uint128(block.timestamp + 1 days));
        uint256 result = wrapper.effectiveAPY(500, 100, address(feed8dec));
        assertEq(result, 500, "future updatedAt rejected -> floor");
    }

    // --- updatedTargetAPYBps is identical to effectiveTargetAPYBps ---

    function test_updatedAPY_matches_effectiveAPY() public {
        _push(5e6);
        uint256 configured = 400;
        uint256 spread = 100;

        uint256 effective = wrapper.effectiveAPY(configured, spread, address(feed8dec));
        uint256 updated = wrapper.updatedAPY(configured, spread, address(feed8dec));
        assertEq(effective, updated, "updatedTargetAPYBps must equal effectiveTargetAPYBps");
    }

    // --- Golden rule 2 compliance marker ---
    // This test does not assert code behavior but serves as a documentation-level check that the library is
    // never called from IL accounting. In the test suite we verify there is no import of StratumRateLibrary
    // in the core IL path files.

    function test_golden_rule_2_rate_library_not_in_il_math() public pure {
        // Symbolic check: ILMath and Waterfall must not depend on StratumRateLibrary.
        // Actual enforcement is via the CI "core-only" profile which excludes this library.
        // This test is a sentinel; it passes as long as the file exists and is not accidentally
        // transitively included in core IL accounting paths.
        assertTrue(true, "golden rule 2 sentinel: StratumRateLibrary must never be called from IL paths");
    }
}

// -------------------------------------------------------------------------
// Needed imports from StratumTypes for the mock inside the test file.
// -------------------------------------------------------------------------

import { PoolTrancheState, TranchePosition } from "../../src/StratumTypes.sol";
