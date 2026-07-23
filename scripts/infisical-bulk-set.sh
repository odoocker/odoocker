#!/usr/bin/env bash
#
# Bulk-set secrets in Infisical Cloud. Generic — reads secret values from
# env vars (one per secret name passed as an arg). Designed to work from
# either:
#   - GitHub Actions (env vars set from secrets.* in the workflow's env block)
#   - Local terminal (env vars set by `op run --env-file=...`)
#
# Authentication:
#   - Universal Auth client_id + client_secret from env (always — same
#     pattern as scripts/infisical-seed.sh; values pipe through stdin
#     to curl, never via argv)
#
# Usage:
#   INFISICAL_UNIVERSAL_AUTH_CLIENT_ID=...  \
#   INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET=...  \
#   INFISICAL_PROJECT_ID=850603f8-...  \
#   INFISICAL_ENV_SLUG=prod  \
#   PROD_SSH_PRIVATE_KEY="$(cat ~/.ssh/grove-prod)"  \
#   PROD_HOST="erp.gatheringatthegrove.com"  \
#   ./scripts/infisical-bulk-set.sh PROD_SSH_PRIVATE_KEY PROD_HOST
#
# Each positional arg names a secret. The script reads the value from
# the env var with that name and POSTs it to Infisical's secrets API.
# Per-secret status reported; values never logged.

set -euo pipefail

# ── preflight ───────────────────────────────────────────────────────────────
for bin in curl jq python3; do
  command -v "$bin" >/dev/null || { echo "ERROR: $bin not found in PATH" >&2; exit 1; }
done

: "${INFISICAL_UNIVERSAL_AUTH_CLIENT_ID:?must be set}"
: "${INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET:?must be set}"
: "${INFISICAL_PROJECT_ID:?must be set — project UUID}"
INFISICAL_ENV_SLUG="${INFISICAL_ENV_SLUG:-prod}"
INFISICAL_SECRET_PATH="${INFISICAL_SECRET_PATH:-/}"
INFISICAL_API="${INFISICAL_API:-https://app.infisical.com/api}"

if [ $# -eq 0 ]; then
  echo "ERROR: no secret names passed. Usage: $0 SECRET_NAME [SECRET_NAME ...]" >&2
  exit 1
fi

# ── cleanup ─────────────────────────────────────────────────────────────────
TOKEN=""
cleanup() { unset TOKEN; return 0; }
trap cleanup EXIT INT TERM

# ── auth: exchange client-creds for access token ────────────────────────────
echo "  authenticating to Infisical (Universal Auth)..." >&2
TOKEN=$(printf '{"clientId":"%s","clientSecret":"%s"}' \
    "$INFISICAL_UNIVERSAL_AUTH_CLIENT_ID" \
    "$INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET" \
  | curl -sf -X POST "$INFISICAL_API/v1/auth/universal-auth/login" \
      -H "Content-Type: application/json" \
      --data @- \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['accessToken'])"
)
if [ -z "$TOKEN" ]; then
  echo "ERROR: Infisical Universal Auth login failed." >&2
  exit 1
fi
unset INFISICAL_UNIVERSAL_AUTH_CLIENT_ID INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET

# ── per-secret upsert ───────────────────────────────────────────────────────
# Infisical's POST /api/v3/secrets/raw/{name} creates the secret. If it
# already exists, the API returns 400 "Secret already exists". We catch
# that and retry with PATCH (update). Either way the secret ends up set
# to the env-var value.
echo "  setting ${#@} secret(s) in project=$INFISICAL_PROJECT_ID env=$INFISICAL_ENV_SLUG path=$INFISICAL_SECRET_PATH" >&2

missing=0
created=0
updated=0
failed=0
for SECRET_NAME in "$@"; do
  SECRET_VALUE="${!SECRET_NAME:-}"
  if [ -z "$SECRET_VALUE" ]; then
    echo "  ⚠  $SECRET_NAME — env var unset or empty, skipping" >&2
    missing=$((missing + 1))
    continue
  fi

  # Build the JSON body via jq --arg (handles newlines, quotes, backslashes
  # correctly). Pipe to curl via stdin — value never appears in argv.
  BODY=$(jq -n \
    --arg type "shared" \
    --arg env "$INFISICAL_ENV_SLUG" \
    --arg path "$INFISICAL_SECRET_PATH" \
    --arg workspaceId "$INFISICAL_PROJECT_ID" \
    --arg value "$SECRET_VALUE" \
    '{type: $type, environment: $env, secretPath: $path, workspaceId: $workspaceId, secretValue: $value}')

  # Try POST (create). On 400 (already exists), retry with PATCH (update).
  HTTP_CODE=$(printf '%s' "$BODY" \
    | curl -sS -o /tmp/infisical-resp -w '%{http_code}' \
        -X POST "$INFISICAL_API/v3/secrets/raw/$SECRET_NAME" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        --data @-)

  if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
    echo "  ✓  $SECRET_NAME — created" >&2
    created=$((created + 1))
  elif [ "$HTTP_CODE" = "400" ] || [ "$HTTP_CODE" = "409" ]; then
    # Likely already exists — retry with PATCH
    HTTP_CODE_PATCH=$(printf '%s' "$BODY" \
      | curl -sS -o /tmp/infisical-resp -w '%{http_code}' \
          -X PATCH "$INFISICAL_API/v3/secrets/raw/$SECRET_NAME" \
          -H "Authorization: Bearer $TOKEN" \
          -H "Content-Type: application/json" \
          --data @-)
    if [ "$HTTP_CODE_PATCH" = "200" ]; then
      echo "  ✓  $SECRET_NAME — updated (existed)" >&2
      updated=$((updated + 1))
    else
      echo "  ✗  $SECRET_NAME — PATCH failed HTTP $HTTP_CODE_PATCH" >&2
      cat /tmp/infisical-resp >&2 || true
      echo >&2
      failed=$((failed + 1))
    fi
  else
    echo "  ✗  $SECRET_NAME — POST failed HTTP $HTTP_CODE" >&2
    cat /tmp/infisical-resp >&2 || true
    echo >&2
    failed=$((failed + 1))
  fi
done

rm -f /tmp/infisical-resp

echo "" >&2
echo "  Summary: created=$created updated=$updated missing=$missing failed=$failed" >&2
if [ "$failed" -gt 0 ]; then
  exit 1
fi
