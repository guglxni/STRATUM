# Unichain Sepolia deployment

Chain ID: **1301**  
Explorer: [sepolia.uniscan.xyz](https://sepolia.uniscan.xyz)

## Live contracts (full-stack deployment, against canonical Uniswap v4)

Deployed 2026-06-05 against the **canonical Unichain Sepolia Uniswap v4 PoolManager** (not a self-deployed one),
with the cross-chain router bound to the **real Across V3 SpokePool**. This is the production-shaped deployment.

| Contract | Address |
|----------|---------|
| Deployer | `0xDDe9D31a31d6763612C7f535f51E5dC9f830682e` |
| PoolManager (canonical Uniswap v4) | `0x00B036B58a818B1BC34d502D3fE730Db729e62AC` |
| StratumHook | `0x19446179F835E968353AE3d232397305F12167C1` |
| TrancheSettlementLib (linked) | see `broadcast/DeployStratum.s.sol/1301/run-latest.json` |
| EpochSettler | `0xAe857dbD1cA14A9f9B5783ce0671DFfF23801005` |
| CoverageMonitor | `0xdC42Fc5E34a58Ad6Ee8fA9E2cfb67F7E34006A80` |
| ReserveBalancer | `0x42509D5D5ddb8a57128b38963de101e0535fc858` |
| CorrelationRegistry | `0xc6C02300D5c503aB85FD6Ef98D674e006cC10213` |
| CrossPoolHedgingRouter | `0x4dBc59dbDEB8d0507AF4d62f633F5fDf03989903` |
| Across V3 SpokePool (canonical, wired into CPHR) | `0x6999526e507Cc3b03b180BbE05E1Ff938259A874` |
| BrevisVerifierShim | `0x30376Cd67cd73cF59C7C8eFfd4b98D8C536F59aA` |
| StylusShim | `0x954740d7482C0FB1468b1De9C45dfE7fdaA3bB16` |
| MatchAttestation | `0xB7D3ca825C2E1D7340d0E849f18B002494A8E2ba` |
| LVRAuctionReceiver | `0x71CB068f272F059d90bF912D149e382D03C59021` |

Hook CREATE2 salt: `0x13e5`. Hook runtime size: **22,532 bytes** (under the 24,576 EIP-170 limit; the settlement
logic lives in `TrancheSettlementLib`, deployed separately and DELEGATECALL-linked).

### Live e2e demo pool (DemoLifecycle.s.sol)

| Item | Value |
|------|-------|
| Demo token A (currency0) | `0x0FFD12FA2b56Cec181236c790eBD4e539ee86BdE` |
| Demo token B (currency1) | `0x20f44559563B56ead0739F735033CE541d91bEB0` |
| PoolId | `0xdf908030c96c55d4efd60399cb626fcba4dc26d6d76b58ddb4d6bd1a158228bf` |
| LP router | `0xe43ce9697a9cc085327067D31De3d7DD01F42566` |
| Swap router | `0x3DE1a4A19f879595503ADFbf6885E5b0B2545Fb2` |

The demo opened the pool, seeded junior then senior liquidity, ran a fee/IL-accruing swap, and closed the epoch.

### Prior deployment (self-deployed PoolManager, superseded)

`PoolManager 0x5CEF...E0E9`, `StratumHook 0x9E8b...467c0` (salt `0x7422`). Functional but attached to a
STRATUM-deployed PoolManager rather than the canonical Uniswap one; kept for reference.

## Gas / faucet

Deploy used about **0.000012 ETH**. Wallet had ~**0.3 ETH** on Unichain Sepolia before deploy; **no extra testnet ETH required** for current work.

If you deploy many more pools or run heavy stress on-chain, use [Unichain faucets](https://docs.unichain.org/docs/tools/faucets) (Superchain, QuickNode, thirdweb).

## Explorer API rate limits

- **etherscan.io** (your dashboard): free tier **5 calls/sec**, **100,000/day**. Use for Ethereum Sepolia (`ETHERSCAN_API_KEY`).
- **Unichain Sepolia** verification uses **Blockscout** (`foundry.toml` → `unichain_sepolia`). The etherscan.io key is not interchangeable; create a Blockscout API key on [unichain-sepolia.blockscout.com](https://unichain-sepolia.blockscout.com) if verify fails.

Verify with rate limiting:

```bash
# In .env after deploy:
POOL_MANAGER_ADDRESS=0x5CEF95e5fAFc5E82eeaE84E5Bdb4A7a33096E0E9
STRATUM_HOOK_ADDRESS=0x9E8b77f489a27A73675EB66f190A7183c3F467c0

./script/verify.sh
# or: forge script ... --verify --delay 1 --retries 5
```

## Redeploy

```bash
forge script script/DeployStratum.s.sol --rpc-url $UNICHAIN_SEPOLIA_RPC --broadcast --slow
```
