// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { CanonicalAddresses } from "../../script/CanonicalAddresses.sol";

/// @title CanonicalAddressesTest
/// @notice Pure unit assertions over the verified address map (no fork needed). Locks the on-chain-verified
///         PoolManager / SpokePool / Brevis entries so a future edit cannot silently drop or change a chain
///         without a test failure.
contract CanonicalAddressesTest is Test {
    /// @notice Optimism Sepolia has a SpokePool but NO PoolManager, so isSupportedTestnet must be false
    ///         (a STRATUM pool cannot be created there). Guards against re-introducing the H1 hallucination.
    function test_optimismSepolia_notHookDeployable() public pure {
        assertEq(CanonicalAddresses.poolManager(CanonicalAddresses.OPTIMISM_SEPOLIA), address(0), "no v4 PM on OP Sep");
        assertTrue(CanonicalAddresses.acrossSpokePool(CanonicalAddresses.OPTIMISM_SEPOLIA) != address(0), "has spoke");
        assertFalse(CanonicalAddresses.isSupportedTestnet(CanonicalAddresses.OPTIMISM_SEPOLIA), "not deployable");
    }

    /// @notice The four hook-deployable testnets all report supported (PoolManager present).
    function test_isSupportedTestnet_fourChains() public pure {
        assertTrue(CanonicalAddresses.isSupportedTestnet(CanonicalAddresses.UNICHAIN_SEPOLIA), "unichain");
        assertTrue(CanonicalAddresses.isSupportedTestnet(CanonicalAddresses.SEPOLIA), "ethereum sepolia");
        assertTrue(CanonicalAddresses.isSupportedTestnet(CanonicalAddresses.BASE_SEPOLIA), "base sepolia");
        assertTrue(CanonicalAddresses.isSupportedTestnet(CanonicalAddresses.ARBITRUM_SEPOLIA), "arbitrum sepolia");
    }

    /// @notice The hosted Brevis gateway serves exactly one route: Ethereum Mainnet -> Arbitrum One.
    ///         Locks the on-chain-verified Arbitrum One BrevisRequest (the `to` of a real settlement tx
    ///         0x28e8...ce5f and the address in Brevis's corrected docs). See docs/BREVIS_ROUTE_RESOLUTION.md.
    function test_brevisRequest_arbitrumOneIsGatewayRoute() public pure {
        assertEq(
            CanonicalAddresses.brevisRequest(CanonicalAddresses.ARBITRUM_ONE),
            0x91540fE35a245BA83459f6410c86f1AEC309B290,
            "arbitrum one BrevisRequest (gateway-served destination)"
        );
    }

    /// @notice Testnet Brevis verifiers are deployed-but-not-gateway-served; they still resolve (for the
    ///         operator-fed BrevisVerifierShim) but the gateway returns 1002 SMT-info-missing for them.
    function test_brevisRequest_testnetsResolveButNotGatewayServed() public pure {
        assertTrue(CanonicalAddresses.brevisRequest(CanonicalAddresses.SEPOLIA) != address(0), "sepolia present");
        assertTrue(CanonicalAddresses.brevisRequest(CanonicalAddresses.BASE_SEPOLIA) != address(0), "base present");
        // Ethereum mainnet has no BrevisRequest entry here: it is the gateway SOURCE, not a callback dest.
        assertEq(CanonicalAddresses.brevisRequest(CanonicalAddresses.ETHEREUM_MAINNET), address(0), "mainnet is source");
    }
}
