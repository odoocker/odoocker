#!/usr/bin/env bash
#
# Mirror secrets from Infisical → 1Password's GoldberryGrove Infra item as
# backup. Companion to the one-off GH migration workflow:
#   1. Workflow writes GH Secrets → Infisical (the canonical store)
#   2. THIS script reads Infisical → 1Password (the durable backup)
#
# Runs locally — uses tf-infisical-admin credentials from 1Password to
# authenticate to Infisical, then reads each named secret and writes it
# back to 1Password as a concealed field.
#
# Usage:
#   ./scripts/infisical-mirror-to-1password.sh PROD_SSH_PRIVATE_KEY PROD_HOST ...
#
# By default mirrors from grove-odoocker/prod. Override:
#   INFISICAL_PROJECT_ID=<uuid> ./scripts/infisical-mirror-to-1password.sh ...
#
# 1Password field name = lowercase(SECRET_NAME). E.g., PROD_SSH_PRIVATE_KEY
# in Infisical → prod_ssh_private_key in 1Password GoldberryGrove Infra.

set -euo pipefail

for bin in op infisical jq python3 curl; do
  command -v "$bin" >/dev/null || { echo "ERROR: $bin not found in PATH" >&2; exit 1; }
done

INFISICAL_PROJECT_ID="${INFISICAL_PROJECT_ID:-850603f8-e175-4c38-9038-97a1e69d72e6}"
INFISICAL_ENV_SLUG="${INFISICAL_ENV_SLUG:-prod}"
INFISICAL_SECRET_PATH="${INFISICAL_SECRET_PATH:-/}"
OP_VAULT="${OP_VAULT:-Goldberry Grove - Admin}"
OP_ITEM="${OP_ITEM:-GoldberryGrove Infra}"
INFISICAL_API="${INFISICAL_API:-https://app.infisical.com/api}"

if [ $# -eq 0 ]; then
  echo "ERROR: no secret names passed. Usage: $0 SECRET_NAME [SECRET_NAME ...]" >&2
  exit 1
fi

# Verify op is signed in by reading the target item
op item get "$OP_ITEM" --vault "$OP_VAULT" --format json >/dev/null 2>&1 || {
  echo "ERROR: op CLI cannot read $OP_VAULT/$OP_ITEM. Sign in to 1Password first." >&2
  exit 1
}

# ── auth: exchange tf-infisical-admin client-creds for access token ─────────
# Same pattern as scripts/infisical-seed.sh — client creds piped via stdin
# through op run, never reach this script's argv or env directly.
echo "  authenticating to Infisical (tf-infisical-admin)..." >&2
TMPFILE=$(mktemp)
chmod 600 "$TMPFILE"
trap 'rm -f "$TMPFILE"' EXIT INT TERM
cat > "$TMPFILE" <<EOF
INFISICAL_CLIENT_ID=op://${OP_VAULT}/${OP_ITEM}/infisical_admin_client_id
INFISICAL_CLIENT_SECRET=op://${OP_VAULT}/${OP_ITEM}/infisical_admin_client_secret
EOF

# shellcheck disable=SC2016
# Single quotes intentional — $INFISICAL_CLIENT_ID/_SECRET injected by op
# run into the inner bash; $INFISICAL_API is splice-substituted (config, not secret).
TOKEN=$(op run --env-file="$TMPFILE" -- bash -c '
  printf "{\"clientId\":\"%s\",\"clientSecret\":\"%s\"}" \
    "$INFISICAL_CLIENT_ID" "$INFISICAL_CLIENT_SECRET" \
  | curl -sf -X POST "'"$INFISICAL_API"'/v1/auth/universal-auth/login" \
      -H "Content-Type: application/json" --data @- \
  | jq -r .accessToken
')
rm -f "$TMPFILE"

if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
  echo "ERROR: Infisical login failed." >&2
  exit 1
fi

# ── per-secret read + write ────────────────────────────────────────────────
echo "  mirroring ${#@} secret(s) from Infisical → $OP_VAULT/$OP_ITEM" >&2

success=0
failed=0
for SECRET_NAME in "$@"; do
  RESP=$(mktemp)
  chmod 600 "$RESP"
  HTTP_CODE=$(curl -sS -o "$RESP" -w '%{http_code}' \
    "$INFISICAL_API/v3/secrets/raw/$SECRET_NAME?workspaceId=$INFISICAL_PROJECT_ID&environment=$INFISICAL_ENV_SLUG&secretPath=%2F" \
    -H "Authorization: Bearer $TOKEN")

  if [ "$HTTP_CODE" != "200" ]; then
    echo "  ✗  $SECRET_NAME — Infisical GET failed HTTP $HTTP_CODE" >&2
    rm -f "$RESP"
    failed=$((failed + 1))
    continue
  fi

  SECRET_VALUE=$(jq -r '.secret.secretValue // empty' < "$RESP")
  rm -f "$RESP"

  if [ -z "$SECRET_VALUE" ]; then
    echo "  ✗  $SECRET_NAME — empty value returned from Infisical" >&2
    failed=$((failed + 1))
    continue
  fi

  # 1Password field names are lowercase
  OP_FIELD=$(echo "$SECRET_NAME" | tr '[:upper:]' '[:lower:]')

  # op item edit takes assignments via argv. Single-tenant same-user shell
  # is the only attacker; values are concealed in 1P after the write. Same
  # trade-off as scripts/infisical-admin-bootstrap.sh's step 5.
  op item edit "$OP_ITEM" --vault "$OP_VAULT" \
    "${OP_FIELD}[concealed]=${SECRET_VALUE}" > /dev/null

  echo "  ✓  $SECRET_NAME → $OP_FIELD (len=${#SECRET_VALUE})" >&2
  success=$((success + 1))
done

unset SECRET_VALUE TOKEN

echo "" >&2
echo "  Summary: mirrored=$success failed=$failed" >&2
if [ "$failed" -gt 0 ]; then
  exit 1
fi
