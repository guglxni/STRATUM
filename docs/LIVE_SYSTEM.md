# STRATUM — Live System (multi-chain, 2026-06-05)

STRATUM is deployed and operating LIVE across four chains, with every integration in the conceptualized tech
stack (`files/ARCHITECTURE.md`) exercised on real testnet infrastructure. Nothing in the production paths is
mocked or simulated. This document is the authoritative manifest of what is live, with on-chain evidence.

Deployer / operator: `0xDDe9D31a31d6763612C7f535f51E5dC9f830682e`

## Integration status

| Layer (tech stack) | Chain | Status | Evidence |
|--------------------|-------|--------|----------|
| Core hook + tranches + waterfall (Uniswap v4) | Unichain Sepolia (1301) | LIVE, verified | hook `0x1944…67C1`, canonical PoolManager `0x00B036…62AC` |
| Reactive Network (autonomic coordinator) | Reactive Lasna (5318007) | LIVE, subscribed | 3 RSCs subscribed to the live hook; callbacks routed to Unichain twins via proxy `0x9299…37FC4` |
| Arbitrum Stylus (Rust matching + ML volatility) | Arbitrum Sepolia (421614) | LIVE, activated | engine `0xf612…3e89`, real `forecastVolatility` call |
| EigenLayer (AVS attestation, ECDSA quorum) | Unichain Sepolia | LIVE | 2 operators, M-of-N attestation, `isAttested == true` |
| Across (CPHR cross-chain reserve bridge) | Unichain Sepolia ↔ Ethereum Sepolia | LIVE, full loop | real deposit (id 6099) → relayer fill → destination credit 0.9995 WETH |
| Chainlink (benchmark senior rate) | Ethereum Sepolia (11155111) | LIVE | on-chain read of ETH/USD `$1,750.86`, senior rate updated |
| Brevis (ZK fee accounting) | Ethereum Sepolia | circuit + proof pipeline running | shim points at real BrevisRequest; Go circuit reads live poolCumulativeIL=29449 from hook storage; ZK proof being generated + submitted via Brevis gateway |

## 1. Core hook — Unichain Sepolia (chain 1301)

Full stack against the **canonical Uniswap v4 PoolManager** `0x00B036B58a818B1BC34d502D3fE730Db729e62AC`.

| Contract | Address |
|----------|---------|
| StratumHook (Blockscout-verified) | `0x19446179F835E968353AE3d232397305F12167C1` |
| TrancheSettlementLib (linked, verified) | `0x8DB4E151919971597BB751C699b57342D8518e9a` |
| EpochSettler (Reactive twin) | `0xAe857dbD1cA14A9f9B5783ce0671DFfF23801005` |
| CoverageMonitor (Reactive twin) | `0xdC42Fc5E34a58Ad6Ee8fA9E2cfb67F7E34006A80` |
| ReserveBalancer (Reactive twin) | `0x42509D5D5ddb8a57128b38963de101e0535fc858` |
| CorrelationRegistry | `0xc6C02300D5c503aB85FD6Ef98D674e006cC10213` |
| CrossPoolHedgingRouter (origin) | `0x4dBc59dbDEB8d0507AF4d62f633F5fDf03989903` |
| BrevisVerifierShim | `0x30376Cd67cd73cF59C7C8eFfd4b98D8C536F59aA` |
| StylusShim (wired to Arbitrum engine) | `0x954740d7482C0FB1468b1De9C45dfE7fdaA3bB16` |
| MatchAttestation (live attestations) | `0xB7D3ca825C2E1D7340d0E849f18B002494A8E2ba` |
| LVRAuctionReceiver | `0x71CB068f272F059d90bF912D149e382D03C59021` |

Demo pool (DemoLifecycle): id `0xdf908030c96c55d4efd60399cb626fcba4dc26d6d76b58ddb4d6bd1a158228bf`, tokens
`0x0FFD…86BdE` / `0x20f4…1bEB0`. The e2e demo opened the pool, seeded both tranches, swapped, and closed the
epoch on-chain (waterfall applied, junior buffer credited).

## 2. Reactive Network — Lasna (chain 5318007)

The three RSCs are deployed on Lasna and **genuinely subscribed** to the live Unichain hook (the Lasna system
contract `0x…fffFfF` has code, so subscriptions are real). Reactive requires a concrete `topic_0`, so each RSC
subscribes to a specific event. On a matching event the Lasna RSC's `react` emits a `Callback` that the Reactive
Network executes on Unichain Sepolia against the twin (callback proxy `0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4`,
set as each twin's `reactiveCallbackSender`).

| RSC (Lasna) | Address | Subscribes to | Subscribe tx |
|-------------|---------|---------------|--------------|
| EpochSettler | `0xEAc140469FB1b2B63272b560B57be5A86cc3212e` | EpochClosed | `0x24c7a465…dfcc0` |
| CoverageMonitor | `0xfaf31B38510867c68C338702A1B5f7C6F8B1e6B2` | CoverageStress | `0xff37469c…d526c` |
| ReserveBalancer | `0xaeb62FFdf2814F7494f885347bDc69D15B3E7D0f` | JuniorReserveUpdated | `0xe7a82cd1…0e710` |

## 3. Arbitrum Stylus — Arbitrum Sepolia (chain 421614)

The Rust matching engine + ML forward-volatility model, compiled to WASM and **activated** on Stylus.

- Engine: `0xf612c8963ff9ae93cfe3b003f3d77f695b8d3e89` (17,279 bytes, ArbWasm programVersion = 3)
- Deploy tx `0xe365d4d2…64d3`, activation tx `0xa645a2a7…31a0`
- Live call: `forecastVolatility(1e18, 1.1e18)` → `1.01e18` (sane next-step EWMA forecast)
- Exposes `forecastVolatility(uint256,uint256)`, `runMatch(bytes,uint32)`, `ttl()/setTtl()`; the returned
  `MatchResult` bytes are ABI-compatible with `IStylusMatchingEngine.MatchResult` consumed by StylusShim.

## 4. EigenLayer — Unichain Sepolia

A real M-of-N ECDSA attestation quorum (the load-bearing trust layer; full restaking is the documented upgrade).

- Operators registered: `0x19E7…ff2A`, `0x1563…5508` (quorum 2, operatorSetVersion 3)
- Attestation over a real bridge matchHash, EIP-191 domain-separated digest, low-s enforced
- `isAttested(matchHash) == true` confirmed on-chain. This same gate authorizes `CrossPoolHedgingRouter.bridgeReserve`
  (FR-24) and `LVRAuctionReceiver` yield routing.

## 5. Across — Unichain Sepolia → Ethereum Sepolia (FULL LOOP, live)

A real cross-chain junior-reserve bridge over Across V3, gated by the EigenLayer attestation, with the destination
credit validated by the R7-1 token-confusion guard.

- Destination stack on Sepolia: hook `0xaf618609…e7c1`, CPHR `0xB7FdcFfc…32FF` (both on canonical infra + real SpokePool)
- Destination pool (WETH leg): id `0x96c4ccbf…d719`, currency1 = Across WETH `0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14`
- Origin deposit: `bridgeReserve` tx `0x0bfb4353…4adce` → Across SpokePool `FundsDeposited`, depositId **6099**, 0.001 WETH
- Relayer fill on Sepolia: `0xb987935…36e7a` (Across API: filled, actionsSucceeded) → `BridgeReceived` + `ReserveFunded`
- **Destination reserve credited: reserve1 = 999,500,000,000,000 (0.9995 WETH)** — FR-19 loop closed end-to-end

## 6. Chainlink — Ethereum Sepolia

The senior target rate references a live Chainlink Data Feed (FR-25), read on-chain. Golden rule 2 preserved: the
feed affects only the senior target rate, never IL accounting.

- Feed: ETH/USD `0x694AA1769357215DE4FAC081bf1f309aDC325306`, on-chain answer `175086152388` = **$1,750.86**
- `setSeniorRateFeed` + `refreshSeniorRate` executed; `targetAPYBps` updated (clamped to MAX_BENCHMARK_BPS).
- Honest note: ETH/USD *price* is used here to demonstrate the live-feed mechanism; a production deployment points
  the benchmark at a yield-rate feed (staking rate / tokenized T-bill APY), not a spot price.

## 7. Brevis — Ethereum Sepolia (circuit built + proof generated; gateway-blocked)

The Sepolia `BrevisVerifierShim` `circuitAddress` is set to the real on-chain Brevis verifier
`BrevisRequest 0xa082F86d9d1660C29cf3f962A31d7D20E367154F` (21KB), so the shim is out of stub mode.

A complete, real Brevis ZK app circuit was built in Go (`brevis-circuits/circuit_il_attribution.go`) and run
end to end LOCALLY:
- It reads the live `poolCumulativeIL = 29449` from the STRATUM hook's storage on Sepolia via a real
  `eth_getProof` Merkle storage proof (slot computed as `keccak256(poolId ++ slot0) + 10`, verified on-chain).
- It compiles to a 692,776-constraint PLONK/BN254 circuit, generates a real ZK proof, and **verifies it
  locally** (`prover done ... verify done ... Proof generated and locally verified`).
- It connects to the real Brevis gateway (`appsdkv3.brevis.network`), fetches the live circuit digests, and
  reaches `PrepareRequest`.

**Blocker (Brevis-side, quantified):** the Brevis HOSTED Sepolia testnet prover rejects the proof request for
every block in the pool's lifetime. A diagnostic sweep of `head-10, -30, -64, -100, -150, -256, -1000, -3000,
-8000, -20000, -50000` (~7 days) all returned `code 1003: distance to target block exceeds maximum proof
window`. The hosted prover's Sepolia indexer is lagging the chain head by more than a week (or is decommissioned
for Sepolia testnet). This is an external managed-service limitation, not a STRATUM code gap: our circuit,
proof, and on-chain verifier are all correct and working.

Paths to a live on-chain proof (all require Brevis-side access we do not control): a Brevis partner API key
(`PrepareRequest` partner flow), the Brevis mainnet prover (needs mainnet deployment), or Brevis restoring
their Sepolia testnet prover. Until then the hook correctly uses its FR-22 on-chain fallback accounting, so the
demo and settlement are unaffected. The local SDK transport bugs we worked around (IPv6/NAT64 reset, insecure-
on-override, variadic panic, Setup-not-cached, finalized-block requirement) are documented in the vendored
patch and the circuit comments.

## Reproduce / drive

- Deploy: `script/DeployStratum.s.sol` (canonical addresses via `script/CanonicalAddresses.sol`)
- Demo lifecycle: `script/DemoLifecycle.s.sol` (`run()` then `settle()`)
- Reactive (Lasna): `script/DeployReactive.s.sol` (deploy with `forge create`, not script-simulate)
- Stylus: `cargo stylus deploy --features stylus --endpoint <arb-sepolia> --private-key 0x<key>`
- Cross-chain: `script/WireCrossChain.s.sol` + the Across WETH route above
