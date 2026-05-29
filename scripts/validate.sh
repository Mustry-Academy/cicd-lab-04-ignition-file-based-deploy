#!/bin/bash
# validate.sh — local mirror of .github/workflows/ci.yml.
#
# Run this before opening a PR to catch the cheap stuff the CI workflow checks,
# without waiting for a runner:
#   1. Every *.json under projects/ and services/ parses.
#   2. .deployignore patterns are relative (no leading /).
#   3. actionlint passes on .github/workflows/ (only if actionlint is installed).
#
# Exits non-zero if any check fails. No Ignition or Docker needed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
cd "$PROJECT_ROOT"

rc=0

# 1. JSON validity sweep -------------------------------------------------------
echo "→ JSON validity sweep (projects/, services/)"
json_fail=0
while IFS= read -r f; do
  if ! python3 -m json.tool "$f" > /dev/null 2>&1; then
    echo -e "  ${RED}invalid JSON:${NC} $f"
    json_fail=1
  fi
done < <(find projects services -type f -name '*.json' 2>/dev/null)
if [ "$json_fail" -eq 0 ]; then
  echo -e "  ${GREEN}ok${NC} — all JSON parses"
else
  rc=1
fi

# 2. .deployignore syntax ------------------------------------------------------
echo "→ .deployignore syntax (patterns must be relative)"
if [ -f .deployignore ]; then
  di_fail=0
  n=0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    if [[ "$line" =~ ^/ ]]; then
      echo -e "  ${RED}line $n:${NC} pattern must be relative, not absolute: $line"
      di_fail=1
    fi
  done < .deployignore
  if [ "$di_fail" -eq 0 ]; then
    echo -e "  ${GREEN}ok${NC} — patterns look fine"
  else
    rc=1
  fi
else
  echo "  (no .deployignore — skipped)"
fi

# 3. actionlint (optional) -----------------------------------------------------
echo "→ actionlint (.github/workflows/)"
if command -v actionlint > /dev/null 2>&1; then
  if actionlint -color; then
    echo -e "  ${GREEN}ok${NC}"
  else
    rc=1
  fi
else
  echo -e "  ${YELLOW}skipped${NC} — actionlint not installed (CI runs it; install from https://github.com/rhysd/actionlint to check locally)"
fi

echo ""
if [ "$rc" -eq 0 ]; then
  echo -e "${GREEN}validate.sh: all checks passed${NC}"
else
  echo -e "${RED}validate.sh: one or more checks failed${NC}"
fi
exit "$rc"
