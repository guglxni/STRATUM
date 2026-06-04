# Unichain Sepolia deployment

Chain ID: **1301**  
Explorer: [sepolia.uniscan.xyz](https://sepolia.uniscan.xyz)

## Live contracts (latest broadcast)

| Contract | Address |
|----------|---------|
| Deployer | `0xDDe9D31a31d6763612C7f535f51E5dC9f830682e` |
| PoolManager | `0x5CEF95e5fAFc5E82eeaE84E5Bdb4A7a33096E0E9` |
| StratumHook | `0x9E8b77f489a27A73675EB66f190A7183c3F467c0` |
| EpochSettler | `0x64842Cd033daA6bf8595BcCa52112d7b53726fEe` |
| CoverageMonitor | `0x7dC78fB19a250AC969d7633d25b72c25b2320843` |

Hook CREATE2 salt: `0x7422`

**Verified on Blockscout:** [StratumHook](https://unichain-sepolia.blockscout.com/address/0x9e8b77f489a27a73675eb66f190a7183c3f467c0) (Core REST API + `./script/env-setup.sh verify`)

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
