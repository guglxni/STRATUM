# AI-DLC workflow for STRATUM

This project follows [AWS AI-DLC adaptive workflows](https://github.com/awslabs/aidlc-workflows) for phased delivery.

## Phases (see `docs/PLAN.md`)

| Phase | Status | Exit criterion |
|-------|--------|----------------|
| 0 Foundation | Done | `forge build`, CI |
| 1 Core hook | Done | Unit + integration + stress tests green |
| 2 Unichain deploy | Ready | Script + `.env.example`; needs `PRIVATE_KEY` |
| 3 Reactive | Planned | EpochSettler, CoverageMonitor |
| 4 CPHR (Across) | Planned | Cross-pool reserves |
| 5 Brevis | Planned | ZK time-weighted proofs |
| 6 Stylus + EigenLayer | Planned | Matcher + LVR |
| 7 Demo UI | Planned | Frontend stress viz |

## Security review cadence

After each phase merge:

1. [solidity-agent-kit](https://github.com/0xlayerghost/solidity-agent-kit): coding, testing, deploy checklist
2. [pashov/skills](https://github.com/pashov/skills): `x-ray` pre-audit, `solidity-auditor` on diffs
3. [quillshield_skills](https://github.com/quillai-network/quillshield_skills): invariant and DeFi attack-chain review

## Testnet deploy

```bash
cp .env.example .env
# Set PRIVATE_KEY and UNICHAIN_SEPOLIA_RPC
forge script script/DeployStratum.s.sol --rpc-url $UNICHAIN_SEPOLIA_RPC --broadcast
```

Testnet only (NFR-05). No mainnet targets.
