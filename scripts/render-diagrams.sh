#!/usr/bin/env bash
# Render all STRATUM diagrams: Mermaid → SVG + PNG (npx mmdc), draw.io → SVG + PNG.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MMD="${ROOT}/docs/diagrams/mermaid"
DRAWIO_SRC="${ROOT}/docs/diagrams/drawio"
SVG="${ROOT}/docs/diagrams/svg"
PNG="${ROOT}/docs/diagrams/png"

mkdir -p "$SVG" "$PNG"

# Puppeteer: use system Chrome when bundled Chrome is missing (CI/sandbox)
if [[ -z "${PUPPETEER_EXECUTABLE_PATH:-}" ]]; then
  for chrome in \
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
    "/Applications/Chromium.app/Contents/MacOS/Chromium"; do
    if [[ -x "$chrome" ]]; then
      export PUPPETEER_EXECUTABLE_PATH="$chrome"
      break
    fi
  done
fi

# One npx install for the whole run (faster than per-file -p)
export npm_config_yes=true
MMDC=(npx -y @mermaid-js/mermaid-cli mmdc)
echo "Using: ${MMDC[*]}"

shopt -s nullglob
mmd_files=("$MMD"/*.mmd)
if ((${#mmd_files[@]} == 0)); then
  echo "No .mmd files in $MMD"
else
  for f in "${mmd_files[@]}"; do
    base="$(basename "$f" .mmd)"
    echo "mermaid → svg/png: $base"
    "${MMDC[@]}" -i "$f" -o "$SVG/${base}.svg" -b transparent --scale 2
    "${MMDC[@]}" -i "$f" -o "$PNG/${base}.png" -b white --scale 2 -w 1920 -H 1080
  done
fi

DRAWIO_APP="/Applications/draw.io.app/Contents/MacOS/draw.io"
if [[ ! -x "$DRAWIO_APP" ]]; then
  echo "draw.io CLI not found at $DRAWIO_APP"
  echo "Install: brew install --cask drawio"
else
  drawio_files=("$DRAWIO_SRC"/*.drawio)
  for f in "${drawio_files[@]}"; do
    [[ -f "$f" ]] || continue
    base="$(basename "$f" .drawio)"
    echo "drawio → svg/png: $base"
    "$DRAWIO_APP" -x -f svg -o "$SVG/${base}.svg" "$f"
    "$DRAWIO_APP" -x -f png -o "$PNG/${base}.png" "$f"
  done
fi

echo ""
echo "Rendered:"
echo "  SVG: $SVG ($(find "$SVG" -type f | wc -l | tr -d ' ') files)"
echo "  PNG: $PNG ($(find "$PNG" -type f | wc -l | tr -d ' ') files)"
