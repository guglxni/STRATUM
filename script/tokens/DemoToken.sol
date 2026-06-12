// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { ERC20 } from "solmate/src/tokens/ERC20.sol";

/// @title DemoToken
/// @notice A real, fully-functional ERC-20 used as a pool asset for the live testnet demo. It is NOT a mock of
///         any STRATUM logic: the hook, waterfall, IL and settlement math run identically against it as against
///         WETH/USDC. It only adds a public `faucet` mint so a demo wallet can obtain test liquidity. On mainnet
///         a pool would instead use canonical assets; this token exists purely to bootstrap a testnet pool.
contract DemoToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_, 18) { }

    /// @notice Mint test tokens to `to`. Open by design (testnet faucet); never deploy to mainnet.
    function faucet(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
