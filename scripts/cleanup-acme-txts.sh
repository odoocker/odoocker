#!/usr/bin/env bash
# cleanup-acme-txts.sh — Delete all orphan _acme-challenge TXT records in a
# DO-managed DNS zone. Works around the caddy-dns/digitalocean plugin's
# delete bug.
#
# Background: the caddy-dns/digitalocean plugin's solver-cleanup step fails
# with `strconv.Atoi: parsing "": invalid syntax` when trying to remove the
# TXT it created after a successful ACME challenge. Result: every cert
# request leaves a permanent TXT. Accumulate enough of them and LE rejects
# subsequent validations with "Incorrect TXT record (and N more)". On
# 2026-06-26 we hit 17 stale TXTs before noticing.
#
# This script lists all TXT records named "_acme-challenge" in the given
# zone and DELETEs each. Caddy's next ACME attempt creates a single fresh
# TXT, LE sees only the one it expects, validation succeeds.
#
# Idempotent: if no _acme-challenge TXTs exist, exits 0.
#
# Usage:
#   bash scripts/cleanup-acme-txts.sh                            # default zone
#   ZONE=preview.gatheringatthegrove.com bash scripts/cleanup-acme-txts.sh
#
# Required env:
#   DIGITALOCEAN_TOKEN  Must have domain:write scope. The deploy do_token
#                       from 1P 'GoldberryGrove Infra' has this.
#
# Optional env:
#   ZONE                DO-managed DNS zone (default: qa.gatheringatthegrove.com)
#
# Exit codes:
#   0  All orphan TXTs deleted (or none existed)
#   1  Required env missing
#   2  At least one DELETE failed (likely scope or transient DO API issue)

set -euo pipefail

ZONE="${ZONE:-qa.gatheringatthegrove.com}"

if [ -z "${DIGITALOCEAN_TOKEN:-}" ]; then
  echo "ERROR: DIGITALOCEAN_TOKEN not set." >&2
  exit 1
fi

API="https://api.digitalocean.com/v2/domains/${ZONE}/records"

# List + extract _acme-challenge TXT record IDs.
# Use jq + while-read (NUL-delimited via printf) to avoid the zsh word-
# splitting bug from an earlier ad-hoc fix attempt: `for id in $IDS` in
# zsh treats $IDS as one word even with newlines, so the loop runs ONCE
# with all IDs concatenated as a malformed URL. printf '%s\n' | while
# read is portable across bash + zsh.
ids_json=$(curl -sf -H "Authorization: Bearer $DIGITALOCEAN_TOKEN" \
  "${API}?per_page=200" | jq -r '.domain_records[]
    | select(.type == "TXT" and .name == "_acme-challenge")
    | .id')

if [ -z "$ids_json" ]; then
  echo "  no _acme-challenge TXT records in $ZONE -- nothing to clean up"
  exit 0
fi

count=$(printf '%s\n' "$ids_json" | wc -l | tr -d ' ')
echo "  found $count orphan _acme-challenge TXT record(s) in $ZONE; deleting..."

fail=0
# Process substitution instead of `printf | while` -- the latter runs the while
# loop in a subshell, so `fail=1` never escapes to the parent (audit finding
# 2026-06-27 #1). Partial DELETE failures would silently be treated as success.
while IFS= read -r id; do
  [ -z "$id" ] && continue
  code=$(curl -s -o /dev/null -w '%{http_code}' \
    -X DELETE -H "Authorization: Bearer $DIGITALOCEAN_TOKEN" \
    "${API}/${id}")
  case "$code" in
    204) echo "    ✓ deleted record $id" ;;
    404) echo "    ✓ record $id already gone (HTTP 404)" ;;
    403) echo "    ✗ HTTP 403 deleting $id -- token lacks domain:write?" >&2; fail=1 ;;
    *)   echo "    ✗ HTTP $code deleting $id" >&2; fail=1 ;;
  esac
done < <(printf '%s\n' "$ids_json")

# Per-delete failures are now visible. Exit early with the operator-friendly
# message before the verify-count step (which would mask single-record
# failures if other records cleaned up the same name).
if [ "$fail" = "1" ]; then
  echo "  ERROR: one or more DELETEs returned non-2xx -- see above for details" >&2
  exit 2
fi

# verify final state. The `|| true` keeps a transient DO API failure during
# verification from aborting the script under set-euo-pipefail (audit finding
# #4) -- we explicitly handle the "couldn't verify" case below.
remaining=$(curl -sf -H "Authorization: Bearer $DIGITALOCEAN_TOKEN" \
  "${API}?per_page=200" 2>/dev/null | jq -r '[.domain_records[] |
    select(.type == "TXT" and .name == "_acme-challenge")] | length' 2>/dev/null || echo "?")

if [ "$remaining" = "?" ]; then
  echo "  WARN: could not verify final TXT count (DO API call failed). Deletes above succeeded; rerun for verification if needed." >&2
  exit 0
fi
if [ "$remaining" -ne 0 ]; then
  echo "  WARN: $remaining _acme-challenge TXT(s) remain after cleanup pass" >&2
  exit 2
fi
echo "  ✓ zone $ZONE has 0 orphan _acme-challenge TXTs after cleanup"
