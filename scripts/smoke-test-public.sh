#!/usr/bin/env bash
# smoke-test-public.sh — Public-URL smoke test for the Grove production stack.
#
# Usage:
#   bash scripts/smoke-test-public.sh
#
# Configuration (environment variables):
#   SMOKE_URLS        Newline-separated list of URLs to check. When set, it
#                     overrides the DEFAULT_URLS list compiled into this script.
#   SMOKE_TIMEOUT     Per-URL curl timeout in seconds (default: 20)
#   SMOKE_RETRIES     Number of curl retries per URL (default: 3)
#   SMOKE_RETRY_DELAY Delay between retries in seconds (default: 5)
#
# Exit codes:
#   0  All URLs responded with 2xx or 3xx
#   1  One or more URLs failed
#
# Used by:
#   - .github/workflows/release.yml  (post-deploy-smoke + sandbox-smoke jobs)
#
set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────

SMOKE_TIMEOUT="${SMOKE_TIMEOUT:-20}"
SMOKE_RETRIES="${SMOKE_RETRIES:-3}"
SMOKE_RETRY_DELAY="${SMOKE_RETRY_DELAY:-5}"

# Default production URL list — compiled from nginx/grove-ghost.conf and .env.
# Override by setting the SMOKE_URLS environment variable.
DEFAULT_URLS="https://erp.gatheringatthegrove.com
https://goldberrygrove.farm
https://woodworkingeorge.com
https://atthegrovenursery.com
https://blog.goldberrygrove.farm
https://blog.woodworkingeorge.com
https://blog.atthegrovenursery.com"

# ── Build URL list ────────────────────────────────────────────────────────────

if [ -n "${SMOKE_URLS:-}" ]; then
  URL_LIST="$SMOKE_URLS"
else
  URL_LIST="$DEFAULT_URLS"
fi

# ── Helpers ───────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Colour

# Audit note SC2329 (2026-06-29): fail() is currently unused — kept for symmetry
# with pass()/warn() so future checks have a ready-made red-print helper.
# shellcheck disable=SC2329
pass() { echo -e "${GREEN}PASS${NC} $1"; }
fail() { echo -e "${RED}FAIL${NC} $1"; }
warn() { echo -e "${YELLOW}WARN${NC} $1"; }

# ── Run checks ────────────────────────────────────────────────────────────────

FAILURES=0
TOTAL=0

echo "=== Grove Public Smoke Test ==="
echo "Timeout:     ${SMOKE_TIMEOUT}s per URL"
echo "Retries:     ${SMOKE_RETRIES} (delay: ${SMOKE_RETRY_DELAY}s)"
echo ""

# Read URLs line-by-line; skip empty lines and comments
while IFS= read -r url; do
  # Strip leading/trailing whitespace
  url="${url#"${url%%[! ]*}"}"
  url="${url%"${url##*[! ]}"}"

  # Skip blank lines and comment lines
  [ -z "$url" ] && continue
  [[ "$url" == \#* ]] && continue

  TOTAL=$(( TOTAL + 1 ))

  HTTP_STATUS=$(curl \
    --silent \
    --output /dev/null \
    --write-out "%{http_code}" \
    --location \
    --max-time "${SMOKE_TIMEOUT}" \
    --retry "${SMOKE_RETRIES}" \
    --retry-delay "${SMOKE_RETRY_DELAY}" \
    --retry-connrefused \
    "${url}" 2>/dev/null || echo "000")

  if [[ "${HTTP_STATUS}" =~ ^[23] ]]; then
    pass "${url} → ${HTTP_STATUS}"
  elif [ "${HTTP_STATUS}" = "000" ]; then
    fail "${url} → connection error (curl returned 000)"
    FAILURES=$(( FAILURES + 1 ))
  else
    fail "${url} → HTTP ${HTTP_STATUS}"
    FAILURES=$(( FAILURES + 1 ))
  fi

done <<< "$URL_LIST"

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "=== Results: $((TOTAL - FAILURES))/${TOTAL} passed ==="

if [ "${FAILURES}" -gt 0 ]; then
  echo -e "${RED}${FAILURES} URL(s) failed smoke test.${NC}"
  exit 1
fi

echo -e "${GREEN}All ${TOTAL} URLs healthy.${NC}"
exit 0
