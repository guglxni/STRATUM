#!/usr/bin/env bash
# Pre-commit / pre-push guard: fail if likely secrets are staged or tracked.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

FAIL=0

echo "== Checking .gitignore blocks .env =="
if git check-ignore -q .env 2>/dev/null; then
  echo "OK: .env is ignored"
else
  echo "FAIL: .env is not gitignored"
  FAIL=1
fi

echo "== Checking no .env in git index =="
if git ls-files --error-unmatch .env 2>/dev/null; then
  echo "FAIL: .env is tracked by git"
  FAIL=1
else
  echo "OK: .env not tracked"
fi

echo "== Checking audit docs not tracked =="
for f in docs/AUDIT.md docs/AUDIT_GAPS.md docs/AUDIT_FIXES.md; do
  if git ls-files --error-unmatch "$f" 2>/dev/null; then
    echo "FAIL: $f is tracked (must stay local)"
    FAIL=1
  fi
done

echo "== Scanning staged diff for high-risk patterns =="
PATTERN='(PRIVATE_KEY=0x[a-fA-F0-9]{32,}|PRIVATE_KEY=[a-fA-F0-9]{64}|api[_-]?key\s*=\s*[a-zA-Z0-9]{20,})'
if git diff --cached -G"$PATTERN" --name-only 2>/dev/null | grep -q .; then
  echo "FAIL: Possible secret in staged changes:"
  git diff --cached -G"$PATTERN" --name-only
  FAIL=1
else
  echo "OK: no obvious secrets in staged diff"
fi

if [[ $FAIL -ne 0 ]]; then
  echo ""
  echo "Abort: fix secret exposure before commit/push."
  exit 1
fi
echo "All secret checks passed."
