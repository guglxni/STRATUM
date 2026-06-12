// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { EnvConfig } from "./EnvConfig.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { PoolManager } from "@uniswap/v4-core/src/PoolManager.sol";

import { StratumHook } from "../src/StratumHook.sol";
import { EpochSettler } from "../src/peripherals/reactive/EpochSettler.sol";
import { CoverageMonitor } from "../src/peripherals/reactive/CoverageMonitor.sol";
import { ReserveBalancer } from "../src/peripherals/reactive/ReserveBalancer.sol";
import { CorrelationRegistry } from "../src/peripherals/across/CorrelationRegistry.sol";
import { CrossPoolHedgingRouter } from "../src/peripherals/across/CrossPoolHedgingRouter.sol";
import { BrevisVerifierShim } from "../src/peripherals/brevis/BrevisVerifierShim.sol";
import { StylusShim } from "../src/peripherals/stylus/StylusShim.sol";
import { LVRAuctionReceiver } from "../src/peripherals/eigenlayer/LVRAuctionReceiver.sol";
import { MatchAttestation } from "../src/peripherals/eigenlayer/MatchAttestation.sol";
import { IStratumHook } from "../src/interfaces/IStratumHook.sol";
import { IReserveRebalanceTarget } from "../src/peripherals/reactive/IReserveRebalanceTarget.sol";
import { HookMiner } from "../test/utils/HookMiner.sol";
import { StratumFlags } from "../test/utils/StratumFlags.sol";
import { CanonicalAddresses } from "./CanonicalAddresses.sol";

/// @title DeployStratum
/// @notice Full STRATUM deployment: core hook + all six peripheral layers.
///         Deploys to Unichain Sepolia (testnet). In a production deployment replace the
///         PoolManager address with the canonical Unichain mainnet PoolManager.
///
/// @dev Broadcast command:
///        forge script script/DeployStratum.s.sol \
///          --rpc-url $UNICHAIN_SEPOLIA_RPC \
///          --broadcast \
///          --slow \
///          --delay 1
///
///      Verify (Blockscout rate-limited):
///        ./script/verify.sh (set addresses from console output to .env first)
///
///      Required env vars:
///        PRIVATE_KEY            Deployer key (0x-prefixed or raw hex)
///        UNICHAIN_SEPOLIA_RPC   RPC endpoint
///        ACROSS_SPOKE_POOL      Across V3 SpokePool on Unichain Sepolia (optional; address(0) = disabled)
///
/// @dev phase-seven This script satisfies PRD C1 (core deploys + initialize cycle) and provides the
///      addresses needed for the demo frontend and the stress scenario fork test.
contract DeployStratum is EnvConfig {
    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    /// @dev Canonical CREATE2 deployer used by Foundry `new Contract{salt:}`.
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @dev Default divergence threshold for ReserveBalancer: 20% deviation triggers rebalance signal.
    uint16 internal constant DEFAULT_DIVERGENCE_THRESHOLD_BPS = 2_000;

    /// @dev 2-of-3 quorum for MatchAttestation (hackathon stub; production uses BLS aggregation).
    uint256 internal constant ATTEST_QUORUM = 2;

    /// @dev Across fill-deadline buffer: 30 minutes from submission time.
    uint32 internal constant ACROSS_FILL_DEADLINE_BUFFER = 30 minutes;

    /// @dev Default relayer fee for Across bridge: 0.05% of the bridged amount.
    uint16 internal constant ACROSS_RELAYER_FEE_BPS = 5;

    // -------------------------------------------------------------------------
    // run()
    // -------------------------------------------------------------------------

    /// @notice Deploy all STRATUM contracts and wire the peripheral graph.
    function run() external {
        // NFR-05: STRATUM is testnet-only for UHI9. Hard-revert on Ethereum / known L2 mainnets so a
        // misconfigured RPC can never deploy to a production chain.
        require(block.chainid != 1, "NFR-05: mainnet (Ethereum) deployment is forbidden");
        require(block.chainid != 130, "NFR-05: Unichain mainnet deployment is forbidden");
        require(block.chainid != 10 && block.chainid != 42_161 && block.chainid != 8453, "NFR-05: L2 mainnet forbidden");

        uint256 deployerKey = privateKeyFromEnv();
        address deployer = vm.addr(deployerKey);

        // Across SpokePool resolution (FR-19): explicit env override > canonical address for this chain >
        // address(0) (cross-chain disabled). Binding the REAL SpokePool makes bridgeReserve live, not a stub.
        address spokePoolAddr = vm.envOr("ACROSS_SPOKE_POOL", CanonicalAddresses.acrossSpokePool(block.chainid));

        // PoolManager resolution: explicit env override > canonical v4 PoolManager for this chain > deploy a
        // fresh one (greenfield/local only). Using the canonical manager is the mainnet-correct path: the hook
        // attaches to the same PoolManager real routers and liquidity use.
        address canonicalPM = vm.envOr("POOL_MANAGER_ADDRESS", CanonicalAddresses.poolManager(block.chainid));

        vm.startBroadcast(deployerKey);

        // ----------------------------------------------------------------
        // 1. Core infrastructure
        // ----------------------------------------------------------------

        IPoolManager poolManager;
        if (canonicalPM != address(0)) {
            require(canonicalPM.code.length > 0, "DeployStratum: configured PoolManager has no code");
            poolManager = IPoolManager(canonicalPM);
        } else {
            // Greenfield fallback: no canonical manager known for this chain, deploy a self-contained one.
            poolManager = IPoolManager(address(new PoolManager(deployer)));
        }

        // Mine a CREATE2 salt so the hook address has the correct permission flag bits.
        (address hookAddr, bytes32 hookSalt) = HookMiner.find(
            CREATE2_DEPLOYER,
            StratumFlags.STRATUM_HOOK_FLAGS,
            type(StratumHook).creationCode,
            abi.encode(address(poolManager))
        );

        StratumHook hook = new StratumHook{ salt: hookSalt }(poolManager);
        require(address(hook) == hookAddr, "DeployStratum: hook address mismatch");

        // ----------------------------------------------------------------
        // 2. Reactive peripherals (Phase 3)
        // ----------------------------------------------------------------

        EpochSettler settler = new EpochSettler(IStratumHook(address(hook)), deployer, block.chainid);
        CoverageMonitor monitor = new CoverageMonitor(IStratumHook(address(hook)), deployer, block.chainid);

        // ReserveBalancer: 20% divergence threshold. CPHR is wired after it is deployed.
        ReserveBalancer balancer = new ReserveBalancer(
            IStratumHook(address(hook)), deployer, DEFAULT_DIVERGENCE_THRESHOLD_BPS, block.chainid
        );

        // ----------------------------------------------------------------
        // 3. Across / CPHR (Phase 4)
        // ----------------------------------------------------------------

        CorrelationRegistry registry = new CorrelationRegistry(deployer);

        CrossPoolHedgingRouter cphr = new CrossPoolHedgingRouter(
            deployer, // operator
            IStratumHook(address(hook)), // hook
            registry,
            spokePoolAddr, // address(0) = cross-chain disabled for now
            ACROSS_FILL_DEADLINE_BUFFER,
            ACROSS_RELAYER_FEE_BPS
        );

        // Wire the balancer to use the CPHR as the rebalance target, and gate CPHR rebalance signals to it (CP5).
        balancer.configure(IReserveRebalanceTarget(address(cphr)), address(0));
        cphr.setReserveBalancer(address(balancer));

        // ----------------------------------------------------------------
        // 4. Brevis verifier shim (Phase 5)
        // ----------------------------------------------------------------

        // Brevis is a MAINNET-ONLY live path: the hosted proving service only serves Ethereum Mainnet (source)
        // -> Arbitrum One (destination). This script is testnet-only (NFR-05 reverts above forbid any mainnet
        // chainid), so a live Brevis wiring is impossible here by construction. We therefore deploy the shim
        // in disabled stub mode (NFR-01): circuitAddress == address(0), _enabled == false, so the core uses the
        // FR-22 approximate on-chain accounting fallback. The ABI surface still exists for the demo/tests.
        // Enabling the stub later requires an explicit acknowledgeStubMode(true) (BS9). For a production Arbitrum
        // One deployment the operator wires a real verifier via setCircuitAddress(liveVerifier) then
        // setEnabled(true); no code change is needed. See src/peripherals/brevis NatSpec for chain compatibility.
        BrevisVerifierShim brevisShim = new BrevisVerifierShim(deployer);

        // ----------------------------------------------------------------
        // 5. Stylus shim (Phase 6)
        // ----------------------------------------------------------------

        // Stylus engine address is not yet deployed; the operator calls configure() after deployment.
        StylusShim stylusShim = new StylusShim(IStratumHook(address(hook)), deployer);

        // ----------------------------------------------------------------
        // 6. EigenLayer peripherals (Phase 6)
        // ----------------------------------------------------------------

        // MatchAttestation: 2-of-N quorum. Operators are registered post-deploy via registerOperator().
        // The quorum can be updated once the operator set is known (setQuorumThreshold).
        MatchAttestation matchAttestation = new MatchAttestation(deployer, ATTEST_QUORUM);

        LVRAuctionReceiver lvrReceiver = new LVRAuctionReceiver(IStratumHook(address(hook)), deployer);
        // Wire the attestation contract into the receiver.
        lvrReceiver.setMatchAttestation(matchAttestation);
        // FR-24: gate cross-chain bridges on the same AVS attestation quorum. Until >= ATTEST_QUORUM operators
        // are registered, attested bridges are blocked (fail-closed); same-chain rebalance remains available.
        cphr.setMatchAttestation(matchAttestation);
        // FR-23: the LVR receiver is registered as each pool's reserve yield source PER POOL, by the pool
        // creator, in InitStratumPool (hook.setReserveYieldSource(poolId, lvrReceiver)). It cannot be wired
        // here because no pool exists yet, and the setter is creator-gated (EI1 fix) to prevent front-running.

        vm.stopBroadcast();

        // ----------------------------------------------------------------
        // 7. Print deployment manifest
        // ----------------------------------------------------------------

        console2.log("======= STRATUM Deployment Manifest =======");
        console2.log("Deployer              :", deployer);
        console2.log("Chain ID              :", block.chainid);
        console2.log("--- Core ---");
        console2.log("PoolManager           :", address(poolManager));
        console2.log("PoolManager source    :", canonicalPM != address(0) ? "canonical/env" : "fresh (greenfield)");
        console2.log("StratumHook           :", address(hook));
        console2.log("hookSalt              :", vm.toString(hookSalt));
        console2.log("--- Reactive (Phase 3) ---");
        console2.log("EpochSettler          :", address(settler));
        console2.log("CoverageMonitor       :", address(monitor));
        console2.log("ReserveBalancer       :", address(balancer));
        console2.log("--- Across / CPHR (Phase 4) ---");
        console2.log("CorrelationRegistry   :", address(registry));
        console2.log("CrossPoolHedgingRouter:", address(cphr));
        console2.log("AcrosSpokePool        :", spokePoolAddr);
        console2.log("--- Brevis (Phase 5) ---");
        console2.log("BrevisVerifierShim    :", address(brevisShim));
        console2.log("--- Stylus (Phase 6) ---");
        console2.log("StylusShim            :", address(stylusShim));
        console2.log("--- EigenLayer (Phase 6) ---");
        console2.log("MatchAttestation      :", address(matchAttestation));
        console2.log("LVRAuctionReceiver    :", address(lvrReceiver));
        console2.log("===========================================");
        console2.log("");
        console2.log("Next steps:");
        console2.log("  1. Run DemoLifecycle.s.sol to deploy demo tokens + init a pool + run the full e2e flow.");
        console2.log("  2. CPHR already bound to the real Across SpokePool above (cross-chain origin is live).");
        console2.log("     For the destination leg run WireCrossChain.s.sol on both chains.");
        console2.log("  3. Register EigenLayer operators: matchAttestation.registerOperator(opAddr) x quorum.");
        console2.log("  4. Set Stylus engine (after cargo stylus deploy): stylusShim.configure(engineAddr, attest).");
        console2.log("  5. Brevis stays disabled (NFR-01). Wire a real verifier then setEnabled(true) for the ZK path.");
    }
}
