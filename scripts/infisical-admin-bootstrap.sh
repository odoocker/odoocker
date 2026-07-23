#!/usr/bin/env bash
#
# One-shot bootstrap for the Infisical admin machine identity that the
# infisical-identities/ Terraform env will use to create all other identities
# (per-workflow OIDC, etc.).
#
# Flow:
#   1. Browser-based user login (the only interactive step — irreducible
#      chicken-and-egg: to call the API you need creds, to get creds you need
#      an identity, so the first one must come from outside the API)
#   2. POST /v1/identities — create tf-infisical-admin with org Admin role
#   3. POST /v1/auth/universal-auth/identities/<id> — add Universal Auth
#   4. POST /v1/auth/universal-auth/identities/<id>/client-secrets — mint
#      a Client Secret
#   5. Store Client ID + Client Secret in 1Password under GoldberryGrove Infra
#      as `infisical_admin_client_id` / `infisical_admin_client_secret`
#   6. Wipe the user token; we don't persist it past this run
#
# Idempotent on a fresh failure: re-running detects an existing identity by
# name and skips the create step. If you need to fully reset (e.g. a partial
# previous run left orphan state), delete the identity in the Infisical UI
# first and re-run.
#
# Usage:
#   ./scripts/infisical-admin-bootstrap.sh
#
# Prerequisites: infisical CLI, op (1Password) CLI signed in, jq, curl.

set -euo pipefail

# ── config ──────────────────────────────────────────────────────────────────
ORG_ID="${INFISICAL_ORG_ID:-952236a8-4ed4-45c0-81e8-5157b48557a2}"
IDENTITY_NAME="${INFISICAL_ADMIN_IDENTITY_NAME:-tf-infisical-admin}"
OP_VAULT="${OP_VAULT:-Goldberry Grove - Admin}"
OP_ITEM="${OP_ITEM:-GoldberryGrove Infra}"
OP_FIELD_CLIENT_ID="${OP_FIELD_CLIENT_ID:-infisical_admin_client_id}"
OP_FIELD_CLIENT_SECRET="${OP_FIELD_CLIENT_SECRET:-infisical_admin_client_secret}"
INFISICAL_DOMAIN="${INFISICAL_DOMAIN:-https://app.infisical.com}"
INFISICAL_API="${INFISICAL_DOMAIN}/api"

# ── arg parsing ─────────────────────────────────────────────────────────────
# --identity-id <UUID>: skip the create step (use when the identity already
# exists but the by-name idempotency lookup doesn't find it — e.g., the
# user-login token's permissions don't include the org-identity-list
# endpoint). Mint a fresh Client Secret + run the project-grant step.
EXPLICIT_IDENTITY_ID=""
while [ $# -gt 0 ]; do
  case "$1" in
    --identity-id) EXPLICIT_IDENTITY_ID="$2"; shift 2 ;;
    --help|-h)
      grep -E "^# " "$0" | head -30 | sed 's/^# \?//'
      exit 0
      ;;
    *) echo "ERROR: unknown arg '$1'. Use --help." >&2; exit 1 ;;
  esac
done

# ── preflight ───────────────────────────────────────────────────────────────
for bin in infisical op jq curl; do
  command -v "$bin" >/dev/null || { echo "ERROR: $bin not found in PATH" >&2; exit 1; }
done
# Confirm op is signed in (must be able to read items)
op item get "$OP_ITEM" --vault "$OP_VAULT" --format json >/dev/null 2>&1 || {
  echo "ERROR: op CLI cannot read $OP_VAULT/$OP_ITEM. Sign in to 1Password first." >&2
  exit 1
}

# ── cleanup trap (always wipe TOKEN + temp files on exit) ───────────────────
TMPFILE=""
TOKEN=""
cleanup() {
  unset TOKEN
  if [ -n "$TMPFILE" ]; then
    rm -f "$TMPFILE"
  fi
  # Explicit return 0 so the trap's exit status doesn't become the
  # script's. Without this, `set -e` + a falsy [ -n "$TMPFILE" ] makes
  # bash exit 1 on an otherwise-successful run.
  return 0
}
trap cleanup EXIT INT TERM

# ── step 1: browser-based user login ────────────────────────────────────────
echo "→ Opening browser for Infisical user login..."
echo "  (the only manual step — everything else is automated)"
TMPFILE=$(mktemp)
chmod 600 "$TMPFILE"
infisical login --method=user --plain --silent --domain="$INFISICAL_DOMAIN" > "$TMPFILE"
TOKEN=$(cat "$TMPFILE")
rm -f "$TMPFILE"
TMPFILE=""
if [ -z "$TOKEN" ]; then
  echo "ERROR: login returned empty token" >&2
  exit 1
fi
echo "  ✓ user token captured (len=${#TOKEN}, won't be persisted)"

# ── helper: API call wrapper ────────────────────────────────────────────────
# Returns body on stdout, http code on file descriptor 3 via a tempfile.
# This avoids putting body on a pipe where exit codes get lost.
api() {
  local method="$1" path="$2" body="${3:-}"
  local resp http_code
  resp=$(mktemp)
  chmod 600 "$resp"
  if [ -n "$body" ]; then
    http_code=$(printf '%s' "$body" \
      | curl -sS -o "$resp" -w '%{http_code}' \
          -X "$method" \
          -H "Authorization: Bearer $TOKEN" \
          -H "Content-Type: application/json" \
          --data @- \
          "$INFISICAL_API$path")
  else
    http_code=$(curl -sS -o "$resp" -w '%{http_code}' \
      -X "$method" \
      -H "Authorization: Bearer $TOKEN" \
      "$INFISICAL_API$path")
  fi
  if [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
    echo "  ✗ API $method $path → HTTP $http_code" >&2
    cat "$resp" >&2
    echo >&2
    rm -f "$resp"
    return 1
  fi
  cat "$resp"
  rm -f "$resp"
}

# ── step 2: create identity (idempotent — skip if exists) ───────────────────
# Three paths to "got the IDENTITY_ID":
#   a) --identity-id passed explicitly (recovery from a broken auto-lookup)
#   b) Auto-lookup via /v2/organization/{orgId}/identity-memberships finds
#      it by name (works when the user-login token has the right scope —
#      does NOT work in all configurations, hence path (a))
#   c) Doesn't exist → POST /v1/identities to create it
#
# Path (a) is the escape hatch for when (b) silently returns empty for an
# identity that demonstrably exists (Infisical's tier/permission semantics
# make the LIST endpoint return different results depending on auth scope).
# Observed 2026-06-23: user-login token returned empty for an identity the
# same token had just created successfully. Workaround: pass --identity-id.
if [ -n "$EXPLICIT_IDENTITY_ID" ]; then
  echo "→ Using --identity-id $EXPLICIT_IDENTITY_ID (recovery mode, skipping lookup + create)"
  IDENTITY_ID="$EXPLICIT_IDENTITY_ID"
else
echo "→ Checking if '$IDENTITY_NAME' already exists in org $ORG_ID..."
EXISTING_ID=$(api GET "/v2/organization/$ORG_ID/identity-memberships" 2>/dev/null \
  | jq -r ".identityMemberships[]? | select(.identity.name == \"$IDENTITY_NAME\") | .identity.id // empty" \
  || true)

if [ -n "$EXISTING_ID" ]; then
  echo "  ⚠ identity exists at id=$EXISTING_ID — skipping creation"
  echo "    (to fully reset: delete in Infisical UI first, then re-run)"
  IDENTITY_ID="$EXISTING_ID"
else
  echo "→ POST /v1/identities — create $IDENTITY_NAME (org role: admin)"
  IDENTITY_ID=$(api POST "/v1/identities" "$(jq -n \
    --arg name "$IDENTITY_NAME" \
    --arg orgId "$ORG_ID" \
    '{name: $name, organizationId: $orgId, role: "admin"}')" \
    | jq -r '.identity.id')
  if [ -z "$IDENTITY_ID" ] || [ "$IDENTITY_ID" = "null" ]; then
    echo "ERROR: create identity returned no id" >&2
    exit 1
  fi
  echo "  ✓ created identity $IDENTITY_ID"

  echo "→ POST /v1/auth/universal-auth/identities/$IDENTITY_ID — add Universal Auth"
  api POST "/v1/auth/universal-auth/identities/$IDENTITY_ID" "$(jq -n '{
    accessTokenTTL: 7200,
    accessTokenMaxTTL: 7776000,
    accessTokenNumUsesLimit: 0,
    accessTokenTrustedIps: [{ipAddress: "0.0.0.0/0"}],
    clientSecretTrustedIps: [{ipAddress: "0.0.0.0/0"}]
  }')" > /dev/null
  echo "  ✓ Universal Auth attached"
fi
fi  # close the EXPLICIT_IDENTITY_ID guard

# ── step 3: fetch Client ID (separate from Client Secret, both halves needed) ─
CLIENT_ID=$(api GET "/v1/auth/universal-auth/identities/$IDENTITY_ID" \
  | jq -r '.identityUniversalAuth.clientId')
if [ -z "$CLIENT_ID" ] || [ "$CLIENT_ID" = "null" ]; then
  echo "ERROR: could not fetch clientId for identity $IDENTITY_ID" >&2
  exit 1
fi

# ── step 4: mint a fresh Client Secret ──────────────────────────────────────
# Old secrets stay valid — operator can revoke them in UI if needed. Minting
# fresh here keeps re-runs cleanly recoverable.
echo "→ POST /v1/auth/universal-auth/identities/$IDENTITY_ID/client-secrets — mint Client Secret"
SECRET_JSON=$(api POST "/v1/auth/universal-auth/identities/$IDENTITY_ID/client-secrets" \
  "$(jq -n --arg desc "bootstrap $(date -u +%FT%TZ)" '{
    description: $desc,
    ttl: 0,
    numUsesLimit: 0
  }')")
CLIENT_SECRET=$(echo "$SECRET_JSON" | jq -r '.clientSecret')
if [ -z "$CLIENT_SECRET" ] || [ "$CLIENT_SECRET" = "null" ]; then
  echo "ERROR: create Client Secret returned no value" >&2
  echo "$SECRET_JSON" >&2
  exit 1
fi
echo "  ✓ Client Secret minted"

# ── step 5: store in 1Password ──────────────────────────────────────────────
# op item edit takes values as CLI args. They'll briefly appear in argv for
# the op process (visible via ps aux to the same user only). Acceptable
# trade-off vs the complexity of a stdin-driven 1P write path.
echo "→ Storing in 1Password: $OP_VAULT / $OP_ITEM"
op item edit "$OP_ITEM" --vault "$OP_VAULT" \
  "${OP_FIELD_CLIENT_ID}[concealed]=${CLIENT_ID}" \
  "${OP_FIELD_CLIENT_SECRET}[concealed]=${CLIENT_SECRET}" > /dev/null
echo "  ✓ $OP_FIELD_CLIENT_ID      (len=${#CLIENT_ID})"
echo "  ✓ $OP_FIELD_CLIENT_SECRET  (len=${#CLIENT_SECRET})"

# ── step 6: grant the admin identity Admin role on each managed project ────
# Org-Admin role does NOT carry project-level permissions. Without this step,
# tf-infisical-admin cannot create project memberships for other identities
# (which is its entire job in the infisical-identities/ TF env and the
# infisical-add-workflow-identity.sh script). Comma-separated list of project
# UUIDs the admin should be granted Admin role on. Idempotent — skips if
# already a member.
# Comma-separated list of project UUIDs the admin should be granted Admin on.
# Default covers both Grove projects today (grove-odoocker pre-existing +
# grove-sites created by infra/terraform/environments/infisical-identities/).
# For the FIRST run before grove-sites exists, only the grove-odoocker UUID
# is valid; the script logs an error per failed project but completes the
# others. Operator re-runs the script post-TF-apply with the same default to
# pick up the grove-sites UUID.
INFISICAL_ADMIN_PROJECT_IDS="${INFISICAL_ADMIN_PROJECT_IDS:-850603f8-e175-4c38-9038-97a1e69d72e6}"
echo "→ Granting $IDENTITY_NAME admin role on managed project(s): $INFISICAL_ADMIN_PROJECT_IDS"
IFS=',' read -r -a PROJECT_IDS <<< "$INFISICAL_ADMIN_PROJECT_IDS"
for PROJECT_ID in "${PROJECT_IDS[@]}"; do
  PROJECT_ID="$(echo "$PROJECT_ID" | tr -d '[:space:]')"
  [ -z "$PROJECT_ID" ] && continue

  # Check if already a member by GET-listing project memberships
  EXISTING_MEMBER=$(api GET "/v2/workspace/$PROJECT_ID/identity-memberships" 2>/dev/null \
    | jq -r --arg id "$IDENTITY_ID" \
        '.identityMemberships[]? | select(.identity.id == $id) | .identity.id // empty' \
    | head -1)

  if [ -n "$EXISTING_MEMBER" ]; then
    echo "  ⚠ $PROJECT_ID — already member, skipping"
    continue
  fi

  # POST /v2/workspace/{projectId}/identity-memberships/{identityId}
  # Per the Infisical TF provider's project_identity.go. Identity ID is in
  # both the URL path AND the request body.
  MEMBERSHIP_BODY=$(jq -n \
    --arg pid "$PROJECT_ID" \
    --arg iid "$IDENTITY_ID" \
    '{projectId: $pid, identityId: $iid, roles: [{role: "admin"}]}')
  api POST "/v2/workspace/$PROJECT_ID/identity-memberships/$IDENTITY_ID" "$MEMBERSHIP_BODY" > /dev/null
  echo "  ✓ $PROJECT_ID — admin role granted"
done

# Explicit unsets before the trap runs them — defense in depth
unset CLIENT_ID CLIENT_SECRET SECRET_JSON TOKEN

# ── summary ─────────────────────────────────────────────────────────────────
cat <<EOF

═══════════════════════════════════════════════════════════════
 Bootstrap complete.
═══════════════════════════════════════════════════════════════
 Identity:       $IDENTITY_NAME
 Identity ID:    $IDENTITY_ID
 Org role:       Admin
 Auth method:    Universal Auth
 1Password:      $OP_VAULT / $OP_ITEM
                 - $OP_FIELD_CLIENT_ID
                 - $OP_FIELD_CLIENT_SECRET

 Next: the infra/terraform/environments/infisical-identities/ TF env will
 use these credentials to create the per-workflow OIDC identities for
 odoocker (terraform-drift, sandbox-reaper, sandbox-deploy, release) and
 eventually grove-sites.
EOF
