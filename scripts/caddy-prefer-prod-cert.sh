#!/usr/bin/env bash
# caddy-prefer-prod-cert.sh — Detect + upgrade Caddy staging certs to LE prod.
#
# WHY: PR-D (#98) added Caddy multi-issuer fallback — when LE prod is
# rate-limited, Caddy auto-falls back to LE staging so the deploy never
# blocks. But: once Caddy has a valid staging cert (lifetime ~80 days),
# it keeps using it. Browser shows "untrusted cert" warning. There's no
# native Caddy mechanism to "re-try prod when rate limit clears."
#
# This script closes that gap. Idempotent, safe to run on every deploy
# OR on a cron schedule. No droplet reboot — just touches Caddy:
#   1. SSH the droplet
#   2. Inspect /data/caddy/certificates/ for the staging directory
#   3. If found: delete staging certs + docker restart caddy
#   4. Caddy on restart requests a fresh cert from ACME_CA (prod by default)
#      - If prod budget available: ✓ new prod cert, browser-trusted
#      - If prod still rate-limited: multi-issuer fallback → staging again,
#        no worse than starting state
#   5. Report final issuer + exit
#
# Required env:
#   DIGITALOCEAN_TOKEN          DO API token with droplet:read scope
#                               (resolves droplet IP by tag — survives recreates)
#
# Required on caller's filesystem:
#   ~/.ssh/grove-qa-admin       SSH private key for the droplet (PR #63 pattern)
#
# Optional env:
#   QA_DROPLET_TAG              Tag to discover droplet by (default: env-qa)
#   POLL_SECONDS                How long to wait for cert issuance (default: 60)
#   EXPECTED_HOST               Hostname to probe for cert issuer check
#                               (default: hub.qa.gatheringatthegrove.com)
#
# Exit codes:
#   0  Already on prod cert (no action) OR successfully upgraded to prod
#   1  Required env missing
#   2  Failed to discover droplet
#   3  Staging cert detected but new request also yielded staging
#      (prod LE still rate-limited; retry later)
#   4  Caddy crashed or unreachable after restart

set -euo pipefail

QA_DROPLET_TAG="${QA_DROPLET_TAG:-env-qa}"
POLL_SECONDS="${POLL_SECONDS:-60}"
EXPECTED_HOST="${EXPECTED_HOST:-hub.qa.gatheringatthegrove.com}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/grove-qa-admin}"

# ── prerequisites ──────────────────────────────────────────────────────────
if [ -z "${DIGITALOCEAN_TOKEN:-}" ]; then
  echo "ERROR: DIGITALOCEAN_TOKEN not set" >&2
  exit 1
fi
if [ ! -f "$SSH_KEY" ]; then
  echo "ERROR: SSH key not found at $SSH_KEY" >&2
  exit 1
fi

# ── discover droplet IP ────────────────────────────────────────────────────
DROPLET_IP=$(curl -sf -H "Authorization: Bearer $DIGITALOCEAN_TOKEN" \
  "https://api.digitalocean.com/v2/droplets?tag_name=$QA_DROPLET_TAG" \
  | python3 -c "import json,sys;d=json.load(sys.stdin);ips=[n['ip_address'] for x in d['droplets'] for n in x['networks']['v4'] if n['type']=='public'];print(ips[0] if ips else '')")

if [ -z "$DROPLET_IP" ]; then
  echo "ERROR: no droplet with tag $QA_DROPLET_TAG found" >&2
  exit 2
fi

echo "→ droplet: $DROPLET_IP"

SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=15"
SSH="ssh $SSH_OPTS root@$DROPLET_IP"

# ── detect current cert issuer ─────────────────────────────────────────────
get_issuer() {
  $SSH "echo | openssl s_client -servername $EXPECTED_HOST -connect 127.0.0.1:443 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null" 2>/dev/null || echo "(unreachable)"
}

INITIAL_ISSUER=$(get_issuer)
echo "→ initial issuer: $INITIAL_ISSUER"

# ── decide if upgrade needed ───────────────────────────────────────────────
if echo "$INITIAL_ISSUER" | grep -qE "STAGING|Pebble|Fake"; then
  echo "→ STAGING cert detected — attempting prod upgrade"
elif echo "$INITIAL_ISSUER" | grep -qE "Let's Encrypt|ISRG"; then
  echo "✓ already on LE PROD cert ($INITIAL_ISSUER) — no action"
  exit 0
elif echo "$INITIAL_ISSUER" | grep -q "(unreachable)"; then
  echo "ERROR: cannot reach Caddy on $DROPLET_IP:443 — droplet may be down" >&2
  exit 4
else
  echo "→ unknown issuer ($INITIAL_ISSUER) — leaving alone (no auto-action on unrecognized)"
  exit 0
fi

# ── upgrade path: nuke staging cert dir + restart Caddy ────────────────────
echo "→ deleting staging cert directory from /data"
$SSH "docker exec grove-qa-caddy-1 rm -rf /data/caddy/certificates/acme-staging-v02.api.letsencrypt.org-directory" || {
  echo "ERROR: failed to delete staging cert dir" >&2
  exit 4
}

echo "→ docker restart caddy (no other containers affected)"
$SSH "docker restart grove-qa-caddy-1" >/dev/null
sleep 5

# ── poll until cert issuer changes (or timeout) ────────────────────────────
echo "→ polling for new cert issuance (up to ${POLL_SECONDS}s)..."
elapsed=0
while [ "$elapsed" -lt "$POLL_SECONDS" ]; do
  NEW_ISSUER=$(get_issuer)
  if echo "$NEW_ISSUER" | grep -qE "Let's Encrypt|ISRG" && ! echo "$NEW_ISSUER" | grep -qE "STAGING|Pebble|Fake"; then
    echo "✓ UPGRADED to LE PROD: $NEW_ISSUER"
    exit 0
  fi
  sleep 5
  elapsed=$((elapsed + 5))
  printf "  ...still waiting (%ds elapsed, current issuer: %s)\n" "$elapsed" "${NEW_ISSUER:0:60}"
done

# ── timeout: still on staging means prod LE still rate-limited ─────────────
FINAL_ISSUER=$(get_issuer)
if echo "$FINAL_ISSUER" | grep -qE "STAGING|Pebble|Fake"; then
  echo "WARN: prod upgrade FAILED — Caddy fell back to staging again (LE prod likely still rate-limited)"
  echo "      Current issuer: $FINAL_ISSUER"
  echo "      Retry tomorrow OR check LE rate-limit status at https://crt.sh/?q=qa.gatheringatthegrove.com"
  exit 3
fi

echo "WARN: timeout reached, final issuer: $FINAL_ISSUER"
exit 4
