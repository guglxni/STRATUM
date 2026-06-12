// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";

library StratumFlags {
    uint160 internal constant STRATUM_HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            // D-1: protocol-fee realization returns a delta from afterSwap. Adding this bit changes the mined
            // hook address, so every deployment (and every test that mines a hook) picks it up centrally here.
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );
}
