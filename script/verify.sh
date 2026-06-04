#!/usr/bin/env bash
# Verify STRATUM contracts with explorer API rate limiting (Etherscan free: 5 req/sec).
set -euo pipefail
cd "$(dirname "$0")/.."
source .env 2>/dev/null || true

DELAY="${VERIFY_DELAY_SECONDS:-1}"
RETRIES="${VERIFY_RETRIES:-5}"
RPC="${UNICHAIN_SEPOLIA_RPC:-https://sepolia.unichain.org}"
HOOK="${STRATUM_HOOK_ADDRESS:-}"
MANAGER="${POOL_MANAGER_ADDRESS:-}"

if [[ -z "$HOOK" || -z "$MANAGER" ]]; then
  echo "Set STRATUM_HOOK_ADDRESS and POOL_MANAGER_ADDRESS in .env after deploy."
  exit 1
fi

forge verify-contract "$HOOK" src/StratumHook.sol:StratumHook \
  --chain-id 1301 \
  --rpc-url "$RPC" \
  --etherscan-api-key "${UNICHAIN_ETHERSCAN_API_KEY}" \
  --verifier blockscout \
  --verifier-url "${BLOCKSCOUT_CORE_API_URL:-${BLOCKSCOUT_API_URL:-https://unichain-sepolia.blockscout.com/api}}" \
  --constructor-args "$(cast abi-encode "constructor(address)" "$MANAGER")" \
  --watch \
  --retries "$RETRIES" \
  --delay "$DELAY"
