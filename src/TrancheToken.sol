// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { ERC20 } from "solmate/src/tokens/ERC20.sol";
import { TrancheType } from "./StratumTypes.sol";

/// @title TrancheToken
/// @notice Receipt token for senior (stLP) or junior (jtLP) tranche deposits (FR-02, FR-03).
contract TrancheToken is ERC20 {
    address public immutable hook;
    TrancheType public immutable tranche;

    error OnlyHook();

    constructor(string memory name_, string memory symbol_, TrancheType tranche_, address hook_)
        ERC20(name_, symbol_, 18)
    {
        hook = hook_;
        tranche = tranche_;
    }

    /// @notice Mint receipt tokens to an LP. Only the hook may call.
    function mint(address to, uint256 amount) external {
        if (msg.sender != hook) revert OnlyHook();
        _mint(to, amount);
    }

    /// @notice Burn receipt tokens before settlement. Only the hook may call.
    function burn(address from, uint256 amount) external {
        if (msg.sender != hook) revert OnlyHook();
        _burn(from, amount);
    }
}
