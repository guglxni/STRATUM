// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { EnvConfig } from "./EnvConfig.sol";

import { EpochSettler } from "../src/peripherals/reactive/EpochSettler.sol";
import { CoverageMonitor } from "../src/peripherals/reactive/CoverageMonitor.sol";
import { ReserveBalancer } from "../src/peripherals/reactive/ReserveBalancer.sol";
import { IStratumHook } from "../src/interfaces/IStratumHook.sol";

/// @title DeployReactive
/// @notice Deploys the three STRATUM Reactive Smart Contracts (RSCs) to the Reactive Lasna testnet
///         (chain 5318007) so they subscribe to the LIVE StratumHook on Unichain Sepolia (chain 1301) and
///         route their scheduled `Callback` to the already-deployed RSC twins on Unichain Sepolia.
///
/// @dev The Lasna instance is the SUBSCRIBER: on Lasna the system contract (0x...fffFfF) has code, so each
///      RSC's constructor registers a subscription on the origin chain (1301). Each RSC subscribes to ONE
///      concrete event (topic_0 pinned): EpochSettler -> EpochClosed, CoverageMonitor -> CoverageStress,
///      ReserveBalancer -> JuniorReserveUpdated. A catch-all topic_0 (REACTIVE_IGNORE) is REJECTED by the
///      system contract for a reactive-contract subscriber ("Failure") - see _subscribe in the RSCs. When the
///      Reactive Network delivers a matching log, the RSC's `react` emits
///      `Callback(1301, <unichain twin>, gasLimit, reactiveCallback(poolId))`. The Reactive Network then
///      executes `reactiveCallback(poolId)` on Unichain Sepolia against the twin, which reads the hook there.
///
///      The twin addresses on Unichain Sepolia are the EpochSettler/CoverageMonitor/ReserveBalancer that were
///      deployed by DeployStratum.s.sol. They are read from env so this script never hardcodes them.
///
/// @dev IMPORTANT - deployment method. `forge script ... --broadcast` REVERTS on Lasna with "Failure":
///      forge's local simulation pass executes the constructor's `subscribe` against the Reactive precompile
///      (0x...064), which returns Stop in simulation and makes `subscribe` revert. The subscription only
///      settles in a genuine broadcast tx. Deploy each RSC with `forge create` (which broadcasts directly,
///      skipping the simulation pass), then wire destinations with `cast send`:
///
///        forge create src/peripherals/reactive/EpochSettler.sol:EpochSettler \
///          --rpc-url $REACTIVE_LASNA_RPC --private-key $PRIVATE_KEY --legacy --broadcast \
///          --constructor-args <HOOK> <OPERATOR> 1301
///        # ...repeat for CoverageMonitor and ReserveBalancer (ReserveBalancer adds the divergence bps arg)
///        cast send <RSC> "setReactiveDestination(uint256,address)" 1301 <SEPOLIA_TWIN> \
///          --private-key $PRIVATE_KEY --rpc-url $REACTIVE_LASNA_RPC --legacy
///
///      This `run()` keeps the canonical orchestration for reference and for any future Reactive node whose
///      simulation does not reject the precompile, but the supported live path on current Lasna is forge create.
///
///      Required env vars:
///        PRIVATE_KEY               Deployer / operator key (0x-prefixed or raw hex)
///        REACTIVE_LASNA_RPC        Lasna RPC endpoint (chain 5318007)
///        EPOCH_SETTLER_ADDRESS     Unichain Sepolia EpochSettler twin (callback destination)
///        COVERAGE_MONITOR_ADDRESS  Unichain Sepolia CoverageMonitor twin (callback destination)
///        RESERVE_BALANCER_ADDRESS  Unichain Sepolia ReserveBalancer twin (callback destination)
contract DeployReactive is EnvConfig {
    /// @dev Live StratumHook on Unichain Sepolia (the origin chain the RSCs subscribe to).
    ///      D-1 redeploy 2026-06-11 (afterSwapReturnDelta enabled). Legacy: 0x19446179F835E968353AE3d232397305F12167C1.
    address internal constant STRATUM_HOOK = 0xe932923a5008721564021513838509211CF267c5;

    /// @dev Origin chain id: Unichain Sepolia. The hook lives here; callbacks execute here.
    uint256 internal constant ORIGIN_CHAIN_ID = 1301;

    /// @dev Reactive Lasna testnet chain id (where this script deploys the subscribers).
    uint256 internal constant LASNA_CHAIN_ID = 5_318_007;

    /// @dev Divergence threshold for ReserveBalancer (matches DeployStratum: 20%).
    uint16 internal constant DEFAULT_DIVERGENCE_THRESHOLD_BPS = 2_000;

    function run() external {
        require(block.chainid == LASNA_CHAIN_ID, "DeployReactive: must run on Reactive Lasna (5318007)");

        uint256 deployerKey = privateKeyFromEnv();
        address deployer = vm.addr(deployerKey);

        // Twin addresses on Unichain Sepolia: where the scheduled callback executes (reads the hook there).
        address epochSettlerTwin = vm.envAddress("EPOCH_SETTLER_ADDRESS");
        address coverageMonitorTwin = vm.envAddress("COVERAGE_MONITOR_ADDRESS");
        address reserveBalancerTwin = vm.envAddress("RESERVE_BALANCER_ADDRESS");
        require(epochSettlerTwin != address(0), "DeployReactive: EPOCH_SETTLER_ADDRESS unset");
        require(coverageMonitorTwin != address(0), "DeployReactive: COVERAGE_MONITOR_ADDRESS unset");
        require(reserveBalancerTwin != address(0), "DeployReactive: RESERVE_BALANCER_ADDRESS unset");

        vm.startBroadcast(deployerKey);

        // Deploy the three RSCs on Lasna. originChainId = 1301 so their constructors subscribe to the live
        // hook on Unichain Sepolia (subscribe() is a real call here because Lasna has the system contract).
        EpochSettler settler = new EpochSettler(IStratumHook(STRATUM_HOOK), deployer, ORIGIN_CHAIN_ID);
        CoverageMonitor monitor = new CoverageMonitor(IStratumHook(STRATUM_HOOK), deployer, ORIGIN_CHAIN_ID);
        ReserveBalancer balancer = new ReserveBalancer(
            IStratumHook(STRATUM_HOOK), deployer, DEFAULT_DIVERGENCE_THRESHOLD_BPS, ORIGIN_CHAIN_ID
        );

        // Route each Lasna RSC's scheduled callback to its twin on Unichain Sepolia (chain 1301). Without this
        // the callback would target address(this) on Lasna, where the hook does not exist.
        settler.setReactiveDestination(ORIGIN_CHAIN_ID, epochSettlerTwin);
        monitor.setReactiveDestination(ORIGIN_CHAIN_ID, coverageMonitorTwin);
        balancer.setReactiveDestination(ORIGIN_CHAIN_ID, reserveBalancerTwin);

        vm.stopBroadcast();

        console2.log("======= STRATUM Reactive (Lasna) Manifest =======");
        console2.log("Deployer / operator   :", deployer);
        console2.log("Lasna chain ID        :", block.chainid);
        console2.log("Origin (Unichain Sep) :", ORIGIN_CHAIN_ID);
        console2.log("Subscribed hook       :", STRATUM_HOOK);
        console2.log("--- Lasna RSC addresses (subscribers) ---");
        console2.log("EpochSettler   (Lasna):", address(settler));
        console2.log("CoverageMonitor(Lasna):", address(monitor));
        console2.log("ReserveBalancer(Lasna):", address(balancer));
        console2.log("--- Destination twins (Unichain Sepolia) ---");
        console2.log("EpochSettler   twin   :", epochSettlerTwin);
        console2.log("CoverageMonitor twin  :", coverageMonitorTwin);
        console2.log("ReserveBalancer twin  :", reserveBalancerTwin);
        console2.log("=================================================");
        console2.log("");
        console2.log("Next steps (on Unichain Sepolia, operator-gated):");
        console2.log("  For each twin call setReactiveCallbackSender(<Reactive callback proxy on 1301>)");
        console2.log("  so the relayed reactiveCallback(poolId) passes the sender gate.");
    }
}
