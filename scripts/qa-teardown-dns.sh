#!/usr/bin/env bash
# qa-teardown-dns.sh -- Destroy the QA DNS surface.
#
# Removes:
#   1. The DO-managed zone qa.gatheringatthegrove.com (which destroys all
#      child A/CNAME records as a side effect)
#   2. Optionally: the 3 Cloudflare NS records that delegate the qa subdomain
#      to DO. Skipped by default because they're cheap to keep and the next
#      deploy benefits from instant delegation (TTL=1 / "Auto"); only useful
#      if migrating delegation elsewhere.
#
# Idempotent: missing domain/records are treated as success.
#
# Usage:
#   bash scripts/qa-teardown-dns.sh                # destroys DO domain only
#   bash scripts/qa-teardown-dns.sh --with-cloudflare   # ALSO removes CF NS records
#   bash scripts/qa-teardown-dns.sh --dry-run
#
# Required env:
#   DIGITALOCEAN_TOKEN     Must have `domain:delete` scope (do_token_teardown)
#
# Required env if --with-cloudflare:
#   CLOUDFLARE_API_TOKEN   Zone:DNS:Edit on gatheringatthegrove.com
#
# Optional env:
#   QA_ZONE                Override (default: qa.gatheringatthegrove.com)
#   CF_APEX_ZONE           Apex Cloudflare zone (default: gatheringatthegrove.com)
#
# Exit codes:
#   0  Teardown succeeded (or nothing to remove)
#   1  Required env missing
#   2  DO domain delete failed
#   3  Cloudflare cleanup failed

set -euo pipefail

WITH_CF=0
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --with-cloudflare) WITH_CF=1 ;;
    --dry-run)         DRY_RUN=1 ;;
    *) echo "Unknown flag: $arg" >&2; exit 1 ;;
  esac
done

QA_ZONE="${QA_ZONE:-qa.gatheringatthegrove.com}"
CF_APEX_ZONE="${CF_APEX_ZONE:-gatheringatthegrove.com}"

if [ -z "${DIGITALOCEAN_TOKEN:-}" ]; then
  echo "ERROR: DIGITALOCEAN_TOKEN not set." >&2
  exit 1
fi
if [ "$WITH_CF" = "1" ] && [ -z "${CLOUDFLARE_API_TOKEN:-}" ]; then
  echo "ERROR: CLOUDFLARE_API_TOKEN required for --with-cloudflare" >&2
  exit 1
fi

echo "-- QA DNS teardown --"

# 1. DO domain (destroys all child records)
echo "  -> DO domain $QA_ZONE"
code=$(curl -s -o /tmp/dns.$$ -w '%{http_code}' \
  -X DELETE -H "Authorization: Bearer $DIGITALOCEAN_TOKEN" \
  "https://api.digitalocean.com/v2/domains/${QA_ZONE}")
case "$code" in
  204) echo "     destroyed (HTTP 204)" ;;
  404) echo "     already gone (HTTP 404)" ;;
  403) echo "     FAIL: HTTP 403 (token lacks domain:delete scope)" >&2; exit 2 ;;
  *)   echo "     FAIL: HTTP $code -- response: $(cat /tmp/dns.$$ 2>/dev/null)" >&2; exit 2 ;;
esac
rm -f /tmp/dns.$$

if [ "$DRY_RUN" = "1" ]; then echo "  DRY-RUN: would also destroy above"; fi

# 2. Cloudflare NS records (optional)
if [ "$WITH_CF" = "1" ]; then
  echo "  -> Cloudflare NS records for $QA_ZONE.$CF_APEX_ZONE"
  zone_id=$(curl -sf -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    "https://api.cloudflare.com/client/v4/zones?name=${CF_APEX_ZONE}" | jq -r '.result[0].id')
  if [ -z "$zone_id" ] || [ "$zone_id" = "null" ]; then
    echo "     FAIL: couldn't resolve CF zone for $CF_APEX_ZONE" >&2
    exit 3
  fi
  # Find NS records for QA_ZONE. The Cloudflare API filters by full name,
  # not by leftmost label, so we pass ${QA_ZONE} verbatim.
  record_ids=$(curl -sf -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?type=NS&name=${QA_ZONE}" \
    | jq -r '.result[].id // empty')
  if [ -z "$record_ids" ]; then
    echo "     (no NS records to remove)"
  else
    count=$(echo "$record_ids" | wc -l | tr -d ' ')
    echo "     $count NS record(s) to remove"
    for rid in $record_ids; do
      code=$(curl -s -o /dev/null -w '%{http_code}' \
        -X DELETE -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
        "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records/${rid}")
      if [ "$code" != "200" ]; then
        echo "     FAIL: HTTP $code on NS record $rid" >&2
        exit 3
      fi
    done
    echo "     done"
  fi
fi

echo "  done -- DNS teardown complete"
