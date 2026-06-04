// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";

/// @title UnichainSepoliaForkTest
/// @notice Fork tests run when UNICHAIN_SEPOLIA_RPC is set (Phase 2, C1).
/// forge test --fork-url $UNICHAIN_SEPOLIA_RPC --match-path test/fork/*
contract UnichainSepoliaForkTest is Test {
    function test_fork_rpcAvailable() public view {
        string memory rpc = vm.envOr("UNICHAIN_SEPOLIA_RPC", string(""));
        if (bytes(rpc).length == 0) {
            return;
        }
        assertGt(block.chainid, 0);
    }
}
