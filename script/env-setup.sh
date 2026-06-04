#!/usr/bin/env bash
# Manage STRATUM .env keys from the CLI (never prints PRIVATE_KEY or API keys).
set -euo pipefail
cd "$(dirname "$0")/.."
ENV_FILE="${ENV_FILE:-.env}"

usage() {
  cat <<'EOF'
Usage:
  ./script/env-setup.sh status            # list keys (values masked)
  ./script/env-setup.sh set KEY VALUE   # set or update one key
  ./script/env-setup.sh blockscout-sync   # write Blockscout URLs from official docs
  ./script/env-setup.sh deploy-addrs      # Unichain Sepolia deploy addresses
  ./script/env-setup.sh test-blockscout   # ping Core REST + ETH RPC (uses .env key)
  ./script/env-setup.sh verify            # rate-limited forge verify (Core REST API)

Docs:
  Core REST (verify, explorer): https://unichain-sepolia.blockscout.com/api-docs?tab=rest_api#blockscout-core-api
  ETH RPC: https://docs.blockscout.com/devs/apis/rpc/eth-rpc
  Skip for STRATUM: stats-api, bens-api, user-ops-api
EOF
}

mask_env() {
  [[ -f "$ENV_FILE" ]] || { echo "No $ENV_FILE"; exit 1; }
  grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$ENV_FILE" | sed 's/=.*/=<set>/' || true
}

set_key() {
  local key="$1"
  local val="$2"
  touch "$ENV_FILE"
  if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
    if [[ "$(uname)" == "Darwin" ]]; then
      sed -i '' "s|^${key}=.*|${key}=${val}|" "$ENV_FILE"
    else
      sed -i "s|^${key}=.*|${key}=${val}|" "$ENV_FILE"
    fi
  else
    echo "${key}=${val}" >> "$ENV_FILE"
  fi
  echo "set ${key}=<ok>"
}

blockscout_sync() {
  # https://unichain-sepolia.blockscout.com/api-docs + https://docs.blockscout.com/devs/apis/rpc/eth-rpc
  set_key "UNICHAIN_CHAIN_ID" "1301"
  set_key "BLOCKSCOUT_CORE_API_URL" "https://unichain-sepolia.blockscout.com/api"
  set_key "BLOCKSCOUT_ETH_RPC_URL" "https://unichain-sepolia.blockscout.com/api/eth-rpc"
  set_key "BLOCKSCOUT_PRO_JSON_RPC_URL" "https://api.blockscout.com/1301/json-rpc"
  set_key "BLOCKSCOUT_API_URL" "https://unichain-sepolia.blockscout.com/api"
  set_key "VERIFY_DELAY_SECONDS" "1"
  set_key "VERIFY_RETRIES" "5"

  grep -q '^# --- Blockscout API map' "$ENV_FILE" 2>/dev/null || cat >>"$ENV_FILE" <<'EOF'

# --- Blockscout API map (Unichain Sepolia) ---
# USE: blockscout-core-api -> UNICHAIN_ETHERSCAN_API_KEY + BLOCKSCOUT_CORE_API_URL (forge verify)
# USE: eth-rpc -> BLOCKSCOUT_ETH_RPC_URL (optional; or keep UNICHAIN_SEPOLIA_RPC)
# SKIP: stats-api, bens-api, user-ops-api (not needed for STRATUM core)
# PRO (multichain): BLOCKSCOUT_PRO_JSON_RPC_URL + Blockscout PRO key (optional later)
EOF
  echo "Blockscout URLs synced to $ENV_FILE"
}

deploy_addrs() {
  set_key "POOL_MANAGER_ADDRESS" "0x5CEF95e5fAFc5E82eeaE84E5Bdb4A7a33096E0E9"
  set_key "STRATUM_HOOK_ADDRESS" "0x9E8b77f489a27A73675EB66f190A7183c3F467c0"
  set_key "EPOCH_SETTLER_ADDRESS" "0x64842Cd033daA6bf8595BcCa52112d7b53726fEe"
  set_key "COVERAGE_MONITOR_ADDRESS" "0x7dC78fB19a250AC969d7633d25b72c25b2320843"
  blockscout_sync
  echo "deploy addresses written to $ENV_FILE"
}

load_env() {
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
}

test_blockscout() {
  load_env
  local key="${UNICHAIN_ETHERSCAN_API_KEY:-}"
  local hook="${STRATUM_HOOK_ADDRESS:-0x9E8b77f489a27A73675EB66f190A7183c3F467c0}"
  local core="${BLOCKSCOUT_CORE_API_URL:-https://unichain-sepolia.blockscout.com/api}"
  local eth_rpc="${BLOCKSCOUT_ETH_RPC_URL:-https://unichain-sepolia.blockscout.com/api/eth-rpc}"
  local uni_rpc="${UNICHAIN_SEPOLIA_RPC:-https://sepolia.unichain.org}"

  echo "== 1) Public RPC (UNICHAIN_SEPOLIA_RPC) =="
  cast chain-id --rpc-url "$uni_rpc"

  echo "== 2) Blockscout ETH RPC (eth_chainId) =="
  curl -sS -X POST "$eth_rpc" \
    -H "Content-Type: application/json" \
    ${key:+ -H "X-API-Key: $key"} \
    -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' | head -c 200
  echo ""

  echo "== 3) Blockscout Core REST (contract sourcecode) =="
  if [[ -z "$key" ]]; then
    echo "SKIP: UNICHAIN_ETHERSCAN_API_KEY not set"
  else
    local url="${core}?module=contract&action=getsourcecode&address=${hook}&apikey=${key}"
    local status
    status=$(curl -sS -o /tmp/bs_core.json -w "%{http_code}" "$url")
    echo "HTTP ${status}"
    if command -v jq >/dev/null 2>&1; then
      jq -r '.message // .status // "no message"' /tmp/bs_core.json 2>/dev/null | head -3
    else
      head -c 120 /tmp/bs_core.json; echo ""
    fi
  fi

  echo "== 4) Hook bytecode on chain =="
  cast code "$hook" --rpc-url "$uni_rpc" | head -c 20
  echo "... (truncated)"
}

run_verify() {
  load_env
  if [[ -z "${UNICHAIN_ETHERSCAN_API_KEY:-}" ]]; then
    echo "Set UNICHAIN_ETHERSCAN_API_KEY first (Blockscout core API key)."
    exit 1
  fi
  if [[ -z "${STRATUM_HOOK_ADDRESS:-}" || -z "${POOL_MANAGER_ADDRESS:-}" ]]; then
    echo "Run: ./script/env-setup.sh deploy-addrs"
    exit 1
  fi
  exec ./script/verify.sh
}

cmd="${1:-status}"
case "$cmd" in
  status) mask_env ;;
  set)
    [[ $# -eq 3 ]] || { usage; exit 1; }
    set_key "$2" "$3"
    ;;
  blockscout-sync) blockscout_sync ;;
  deploy-addrs) deploy_addrs ;;
  test-blockscout) test_blockscout ;;
  verify) run_verify ;;
  blockscout-hint) blockscout_sync; test_blockscout 2>/dev/null || true; usage ;;
  *) usage; exit 1 ;;
esac
