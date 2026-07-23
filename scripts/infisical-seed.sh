#!/usr/bin/env bash
#
# Seed an Infisical Cloud project with secrets — odoocker side.
#
# Usage:
#   op run --env-file=.env.infisical-seed.op -- ./scripts/infisical-seed.sh
#
# Reads from environment (populated by op run):
#   INFISICAL_UNIVERSAL_AUTH_CLIENT_ID      — Universal Auth client ID (CLI auto-exchanges)
#   INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET  — Universal Auth client secret
#   INFISICAL_PROJECT_ID         — slug of the target project (e.g. "grove-odoocker")
#   INFISICAL_ENV_SLUG           — environment slug (default: "prod")
#   DIGITALOCEAN_TOKEN           — value to seed
#   DISCORD_OPS_WEBHOOK_URL      — value to seed
#   SPACES_ACCESS_KEY_ID         — value to seed (from state-backend TF output)
#   SPACES_SECRET_ACCESS_KEY     — value to seed (from state-backend TF output)
#
# The CLI checks INFISICAL_UNIVERSAL_AUTH_CLIENT_ID + _SECRET and auto-exchanges
# them for a fresh short-lived access token on each invocation. This is the right
# pattern for a script that runs weeks apart — INFISICAL_TOKEN by contrast is a
# pre-obtained 2-hour access token that would expire between seed runs.
#
# Idempotent: Infisical's `secrets set` upserts. Re-runs safely after rotation.
#
# Per [[project_infisical_decision_cloud]]: this is Phase 1 of the OIDC retrofit.
# Phase 2 (one-way GitHub sync) is wired in the Infisical UI, not here.

set -euo pipefail

# ── preflight ────────────────────────────────────────────────────────────────
if ! command -v infisical >/dev/null 2>&1; then
  echo "ERROR: infisical CLI not found. Install: brew install infisical/get-cli/infisical" >&2
  exit 1
fi
if ! command -v curl >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: curl + python3 required for the Universal Auth REST exchange" >&2
  exit 1
fi

: "${INFISICAL_UNIVERSAL_AUTH_CLIENT_ID:?must be set — typically via op run --env-file=.env.infisical-seed.op}"
: "${INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET:?must be set — typically via op run --env-file=.env.infisical-seed.op}"
: "${INFISICAL_PROJECT_ID:?must be set — project UUID from the browser URL (NOT the slug — the API uses UUIDs)}"
INFISICAL_ENV_SLUG="${INFISICAL_ENV_SLUG:-prod}"
INFISICAL_API="${INFISICAL_API:-https://app.infisical.com/api}"

# ── exchange Universal Auth client-id/secret for a short-lived access token ──
# Per https://infisical.com/docs/api-reference/endpoints/universal-auth/login.
# The CLI does NOT auto-exchange these env vars in v0.43.x (an `infisical
# secrets` call with no cached session falls through to `infisical login`
# interactive). Do the exchange ourselves via the REST API.
#
# Body is piped from printf via stdin, so neither value ever appears on a
# command line (would otherwise be visible in ps aux for the curl process).
echo "  authenticating to Infisical Cloud (Universal Auth)..." >&2
INFISICAL_TOKEN=$(printf '{"clientId":"%s","clientSecret":"%s"}' \
    "$INFISICAL_UNIVERSAL_AUTH_CLIENT_ID" \
    "$INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET" \
  | curl -sf -X POST "$INFISICAL_API/v1/auth/universal-auth/login" \
      -H "Content-Type: application/json" \
      --data @- \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['accessToken'])" \
) || {
  echo "ERROR: Universal Auth login failed. Check client-id + client-secret in 1Password." >&2
  exit 1
}
export INFISICAL_TOKEN
unset INFISICAL_UNIVERSAL_AUTH_CLIENT_ID INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET

# Sanity-check the exchanged token works against the target project + env.
if ! infisical secrets --projectId="$INFISICAL_PROJECT_ID" --env="$INFISICAL_ENV_SLUG" --silent >/dev/null 2>&1; then
  echo "ERROR: infisical CLI auth failed against project=$INFISICAL_PROJECT_ID env=$INFISICAL_ENV_SLUG" >&2
  echo "  Token exchange succeeded but project access denied. Either:" >&2
  echo "    - project slug is wrong (UI: Org → Secret Manager → project list)" >&2
  echo "    - env slug is wrong (default 'prod'; check project's Environments tab)" >&2
  echo "    - identity wasn't granted access to this project (Project → Access Control → Machine Identities)" >&2
  exit 1
fi

# ── secret name → env var name mapping ───────────────────────────────────────
# Each entry: <Infisical secret name>:<env var name read by this script>
SECRETS=(
  "DIGITALOCEAN_TOKEN:DIGITALOCEAN_TOKEN"
  "DISCORD_OPS_WEBHOOK_URL:DISCORD_OPS_WEBHOOK_URL"
  "SPACES_ACCESS_KEY_ID:SPACES_ACCESS_KEY_ID"
  "SPACES_SECRET_ACCESS_KEY:SPACES_SECRET_ACCESS_KEY"
)

echo "=== Infisical seed: project=$INFISICAL_PROJECT_ID env=$INFISICAL_ENV_SLUG ==="

missing=0
for entry in "${SECRETS[@]}"; do
  name="${entry%%:*}"
  src_var="${entry##*:}"
  value="${!src_var:-}"
  if [ -z "$value" ]; then
    echo "  ⚠  $name — source env var $src_var is empty; skipping" >&2
    missing=$((missing + 1))
    continue
  fi
  # `infisical secrets set` upserts. --silent so the value doesn't echo.
  if infisical secrets set "$name=$value" \
        --projectId="$INFISICAL_PROJECT_ID" \
        --env="$INFISICAL_ENV_SLUG" \
        --silent >/dev/null 2>&1; then
    echo "  ✓  $name"
  else
    echo "  ✗  $name — set failed (check infisical CLI version + token scope)" >&2
    exit 1
  fi
done

if [ "$missing" -gt 0 ]; then
  echo "" >&2
  echo "WARN: $missing secret(s) skipped due to empty source vars." >&2
  echo "  This is expected for SPACES_* if state-backend hasn't been applied yet —" >&2
  echo "  fetch via: cd infra/terraform/environments/state-backend && terraform output -raw spaces_access_key_id" >&2
fi

echo ""
echo "Seed complete. Verify in UI:"
echo "  https://app.infisical.com/organizations/952236a8-4ed4-45c0-81e8-5157b48557a2/projects/secret-management/$INFISICAL_PROJECT_ID/secrets/$INFISICAL_ENV_SLUG"
