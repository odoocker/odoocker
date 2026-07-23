#!/usr/bin/env bash
# destroy-orphan-droplet.sh — Force-destroy a stuck/orphan DigitalOcean droplet.
#
# Built for the 2026-06-24 incident: TF apply's destroy step hits DO provider's
# hardcoded 1-min poll timeout and leaves a "destroying" droplet that TF state
# still thinks exists but actually got destroyed asynchronously. Or sometimes
# the destroy never actually started because the token lacked scope.
#
# This script side-steps the provider entirely: direct DO API DELETE call,
# generous poll loop, clear error if scope-blocked.
#
# Usage:
#   bash scripts/destroy-orphan-droplet.sh <DROPLET_ID>
#
# Required env:
#   DIGITALOCEAN_TOKEN  Must have `droplet:delete` scope. The standard
#                       GoldberryGrove Infra/do_token is READ+CREATE only and
#                       will 403. Use do_token_teardown instead:
#                       eval $(op item get "GoldberryGrove Infra" --vault "Goldberry Grove - Admin" \
#                              --fields label=do_token_teardown --reveal | xargs -I {} echo "export DIGITALOCEAN_TOKEN={}")
#
# Optional env:
#   POLL_MAX_SECONDS    Total poll budget (default: 300 = 5 min)
#   POLL_INTERVAL       Seconds between polls (default: 5)
#
# Exit codes:
#   0  Droplet destroyed (or already gone — idempotent)
#   1  Required arg/env missing
#   2  403 Forbidden — token lacks `droplet:delete` scope
#   3  Poll timeout — DO API never reported 404 within POLL_MAX_SECONDS
#   4  Unexpected error

set -euo pipefail

DROPLET_ID="${1:-}"
if [ -z "$DROPLET_ID" ]; then
  echo "Usage: $0 <DROPLET_ID>" >&2
  echo "Find IDs with: bash scripts/qa-status.sh" >&2
  exit 1
fi

if [ -z "${DIGITALOCEAN_TOKEN:-}" ]; then
  echo "ERROR: DIGITALOCEAN_TOKEN not set." >&2
  echo "Fetch the teardown-scoped token:" >&2
  echo "  export DIGITALOCEAN_TOKEN=\$(op item get \"GoldberryGrove Infra\" --vault \"Goldberry Grove - Admin\" --fields label=do_token_teardown --reveal)" >&2
  exit 1
fi

POLL_MAX_SECONDS="${POLL_MAX_SECONDS:-300}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"

echo "── Destroying DO droplet $DROPLET_ID ──"

# Issue the DELETE
http_code=$(curl -s -o /tmp/destroy-response.$$ -w '%{http_code}' \
  -X DELETE -H "Authorization: Bearer $DIGITALOCEAN_TOKEN" \
  "https://api.digitalocean.com/v2/droplets/${DROPLET_ID}")
body=$(cat /tmp/destroy-response.$$ 2>/dev/null || echo "")
rm -f /tmp/destroy-response.$$

case "$http_code" in
  204)
    echo "  ✓ DELETE accepted (HTTP 204) — polling for confirmation..."
    ;;
  404)
    echo "  ✓ Already gone (HTTP 404)"
    exit 0
    ;;
  403)
    echo "  ✗ HTTP 403 Forbidden" >&2
    echo "    Response: $body" >&2
    echo "    Your token lacks 'droplet:delete' scope. Mint a token with delete scope at" >&2
    echo "    https://cloud.digitalocean.com/account/api/tokens" >&2
    exit 2
    ;;
  *)
    echo "  ✗ Unexpected HTTP $http_code" >&2
    echo "    Response: $body" >&2
    exit 4
    ;;
esac

# Poll until 404 or budget exhausted
start=$(date +%s)
deadline=$((start + POLL_MAX_SECONDS))
attempt=0
while [ "$(date +%s)" -lt "$deadline" ]; do
  attempt=$((attempt + 1))
  code=$(curl -s -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer $DIGITALOCEAN_TOKEN" \
    "https://api.digitalocean.com/v2/droplets/${DROPLET_ID}")
  if [ "$code" = "404" ]; then
    elapsed=$(($(date +%s) - start))
    echo "  ✓ Confirmed destroyed (HTTP 404 after ${elapsed}s, ${attempt} polls)"
    exit 0
  fi
  echo "  [poll ${attempt}] HTTP $code — still present, waiting ${POLL_INTERVAL}s"
  sleep "$POLL_INTERVAL"
done

echo "  ✗ Poll timeout: droplet still present after ${POLL_MAX_SECONDS}s" >&2
echo "    DO API may genuinely be slow today, or the destroy was rejected silently." >&2
echo "    Check droplet status manually:" >&2
echo "      curl -H 'Authorization: Bearer \$DIGITALOCEAN_TOKEN' https://api.digitalocean.com/v2/droplets/${DROPLET_ID}" >&2
exit 3
