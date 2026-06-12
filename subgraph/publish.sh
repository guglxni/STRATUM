#!/usr/bin/env bash
#
# Publish the STRATUM subgraph to The Graph's Subgraph Studio (Unichain Sepolia is supported).
#
# Prerequres (one-time, on your side - needs a free account, which an agent cannot create for you):
#   1. Sign in at https://thegraph.com/studio with a wallet.
#   2. Click "Create a Subgraph", give it a slug (e.g. "stratum"). Studio shows a DEPLOY KEY.
#
# Usage:
#   ./publish.sh <DEPLOY_KEY> [SUBGRAPH_SLUG]
#     DEPLOY_KEY     the key shown on the subgraph's Studio page
#     SUBGRAPH_SLUG  the slug you chose in Studio (default: stratum)
#
# After it deploys and syncs, Studio shows a QUERY URL like
#   https://api.studio.thegraph.com/query/<id>/<slug>/<version>
# Put that in frontend/.env as:
#   NEXT_PUBLIC_SUBGRAPH_URL=<that url>
# and the dashboard History panel switches from on-chain reads to The Graph automatically.

set -euo pipefail

DEPLOY_KEY="${1:-}"
SLUG="${2:-stratum}"
VERSION="v0.0.1-$(date +%Y%m%d%H%M)"

cd "$(dirname "$0")"

if [ -z "$DEPLOY_KEY" ]; then
  echo "ERROR: pass your Studio deploy key:  ./publish.sh <DEPLOY_KEY> [slug]" >&2
  echo "Get it from https://thegraph.com/studio after creating the subgraph." >&2
  exit 1
fi

command -v graph >/dev/null 2>&1 || { echo "Installing @graphprotocol/graph-cli..."; npm i -g @graphprotocol/graph-cli; }

echo "==> codegen + build (addresses come from networks.json / subgraph.yaml)"
npm run codegen
graph build --network unichain-sepolia

echo "==> auth"
graph auth "$DEPLOY_KEY"

echo "==> deploy ($SLUG @ $VERSION)"
graph deploy "$SLUG" --version-label "$VERSION"

cat <<EONOTE

Done. Final step (manual):
  1. In Studio, copy the subgraph's QUERY URL.
  2. Add to frontend/.env:
       NEXT_PUBLIC_SUBGRAPH_URL=<query url>
  3. Restart the frontend (npm run dev). The History panel will tag its source as "The Graph".
EONOTE
