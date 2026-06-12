// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title CanonicalAddresses
/// @notice Canonical, verified testnet contract addresses for the external protocols STRATUM integrates with.
///         Centralising them here keeps the deploy + wiring scripts honest: a live deployment binds the REAL
///         on-chain PoolManager and Across SpokePool, never `address(0)` placeholders.
///
/// @dev Addresses confirmed on-chain (code present) and cross-checked against official docs (2026-06):
///        - Uniswap v4 PoolManager: https://docs.uniswap.org/contracts/v4/deployments
///        - Across V3 SpokePool:    https://docs.across.to/reference/contract-addresses
///        - Reactive Network:       https://dev.reactive.network (system contract is chain-constant)
///        - Brevis BrevisRequest:   https://docs.brevis.network/developer-resources/contract-addresses-and-rpc-endpoints
///
///      Sentinel `address(0)` means "not configured for this chain"; callers must fall back (deploy a fresh
///      instance for a greenfield test, or disable the optional integration).
library CanonicalAddresses {
    // -------------------------------------------------------------------------
    // Chain IDs
    // -------------------------------------------------------------------------
    uint256 internal constant SEPOLIA = 11_155_111;
    uint256 internal constant OPTIMISM_SEPOLIA = 11_155_420;
    uint256 internal constant BASE_SEPOLIA = 84_532;
    uint256 internal constant ARBITRUM_SEPOLIA = 421_614;
    uint256 internal constant UNICHAIN_SEPOLIA = 1301;
    uint256 internal constant REACTIVE_LASNA = 5_318_007;
    uint256 internal constant ETHEREUM_MAINNET = 1;
    uint256 internal constant ARBITRUM_ONE = 42_161;

    // -------------------------------------------------------------------------
    // Reactive Network system contract (chain-constant: RSCs subscribe through it)
    // -------------------------------------------------------------------------
    address internal constant REACTIVE_SYSTEM_CONTRACT = 0x0000000000000000000000000000000000fffFfF;

    /// @notice Canonical Uniswap v4 PoolManager for `chainId`, or address(0) if unknown.
    function poolManager(uint256 chainId) internal pure returns (address) {
        if (chainId == UNICHAIN_SEPOLIA) return 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;
        if (chainId == SEPOLIA) return 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
        if (chainId == BASE_SEPOLIA) return 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
        if (chainId == ARBITRUM_SEPOLIA) return 0xFB3e0C6F74eB1a21CC1Da29aeC80D2Dfe6C9a317;
        return address(0);
    }

    /// @notice Canonical Across V3 SpokePool for `chainId`, or address(0) if unknown.
    function acrossSpokePool(uint256 chainId) internal pure returns (address) {
        if (chainId == UNICHAIN_SEPOLIA) return 0x6999526e507Cc3b03b180BbE05E1Ff938259A874;
        if (chainId == SEPOLIA) return 0x5ef6C01E11889d86803e0B23e3cB3F9E9d97B662;
        if (chainId == BASE_SEPOLIA) return 0x82B564983aE7274c86695917BBf8C99ECb6F0F8F;
        if (chainId == ARBITRUM_SEPOLIA) return 0x7E63A5f1a8F0B4d0934B2f2327DAED3F6bb2ee75;
        if (chainId == OPTIMISM_SEPOLIA) return 0x4e8E101924eDE233C13e2D8622DC8aED2872d505;
        return address(0);
    }

    /// @notice Brevis `BrevisRequest` verifier entrypoint for `chainId`, or address(0) if unknown.
    /// @dev IMPORTANT (verified 2026-06-09, see docs/BREVIS_ROUTE_RESOLUTION.md): the hosted Brevis
    ///      app-SDK gateway (`appsdkv3.brevis.network`) serves exactly ONE proving route -
    ///      source = Ethereum Mainnet (1), destination = Arbitrum One (42161). The testnet entries
    ///      below ARE deployed (code present) but the gateway's SMT indexer does NOT serve them: every
    ///      Sepolia request returns `1002 SMT info missing` and the Sepolia BrevisRequest points at a
    ///      `MockSMT` with zero root commits. They remain here for the on-chain-only `BrevisVerifierShim`
    ///      (operator-fed, gateway-independent) and for the day Brevis adds testnet pairs ("more pairs are
    ///      underway"). For a real gateway-settled proof use ARBITRUM_ONE.
    ///        - Arbitrum One (42161): VERIFIED live - confirmed as the `to` of a successful Brevis
    ///          settlement tx 0x28e8...ce5f and matches the corrected Brevis docs.
    function brevisRequest(uint256 chainId) internal pure returns (address) {
        // Gateway-served destination (the only route the hosted prover/indexer currently fulfils).
        if (chainId == ARBITRUM_ONE) return 0x91540fE35a245BA83459f6410c86f1AEC309B290;
        // Deployed-but-not-gateway-served testnet verifiers (BrevisVerifierShim / future pairs only).
        if (chainId == SEPOLIA) return 0xa082F86d9d1660C29cf3f962A31d7D20E367154F;
        if (chainId == BASE_SEPOLIA) return 0x4a97B63b27576d774b6BD288Fa6aAe24F086B84c;
        if (chainId == ARBITRUM_SEPOLIA) return 0x1CD3530F69a85B826b952033365adC4A008F3654;
        return address(0);
    }

    /// @notice True for chain ids STRATUM has verified canonical PoolManager + SpokePool addresses on.
    function isSupportedTestnet(uint256 chainId) internal pure returns (bool) {
        return poolManager(chainId) != address(0);
    }
}
