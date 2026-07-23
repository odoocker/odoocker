#!/usr/bin/env bash
#
# Create one (or many) per-workflow OIDC machine identities in Infisical Cloud
# to spec — same shape as the infisical-identities/ TF env's resources, but
# imperative and API-driven so it can run from anywhere (CI, ad-hoc, etc.)
# without a TF apply.
#
# Companion to scripts/infisical-admin-bootstrap.sh (which creates the ONE
# admin identity that this script uses to create everything else).
#
# Usage:
#   ./scripts/infisical-add-workflow-identity.sh \
#       --name sandbox-reaper \
#       --workflow sandbox-reaper.yml
#
#   # Bulk (loop in shell):
#   for pair in sandbox-reaper:sandbox-reaper.yml sandbox-deploy:sandbox-deploy.yml release:release.yml; do
#     name="${pair%%:*}" file="${pair##*:}"
#     ./scripts/infisical-add-workflow-identity.sh --name "$name" --workflow "$file"
#   done
#
# Flow per workflow:
#   1. Exchange tf-infisical-admin Universal Auth client-id/secret for an
#      access token (Infisical's CLI doesn't auto-exchange env vars — see
#      memory/feedback_infisical_uuid_vs_slug.md). Body via stdin, never argv.
#   2. POST /v1/identities — create "gh-oidc-odoocker-<name>" with org role
#      "no-access" (least privilege; only project membership grants any
#      capability).
#   3. POST /v1/auth/oidc-auth/identities/<id> — attach OIDC Auth with the
#      locked trust policy (per memory/feedback_oidc_trust_policy_pattern.md):
#      bound_subject + bound_claims.job_workflow_ref both pin LITERAL repo +
#      workflow_ref + branch. No actor binding. No globs.
#   4. POST /v2/workspace/<project-id>/identity-memberships — grant Viewer
#      role on grove-odoocker so the workflow can READ secrets but never
#      mutate them.
#   5. Output the new identity's UUID as JSON to stdout (everything else
#      goes to stderr).
#
# Idempotency: each step detects "already done" state before re-creating.
# Re-running on a partial failure cleanly recovers from any step. Same
# pattern as infisical-admin-bootstrap.sh post-PR #45 fix.
#
# Drift relationship with infisical-identities/ TF env:
#   - Identities created here are NOT in TF state. Drift signal: if you
#     later add the same name to var.odoocker_workflows in the TF env's
#     variables.tf AND run `terraform apply`, Infisical's API rejects the
#     duplicate-name create with a 409.
#   - To bring a script-created identity under TF management:
#       1. Add the entry to var.odoocker_workflows in the TF env
#       2. terraform import \
#            'infisical_identity.odoocker_workflow["<name>"]' \
#            '<uuid-this-script-printed>'
#       3. Repeat for the oidc_auth + project_identity resources
#       4. terraform plan should now show no changes
#   - Acceptable to never import — pure-script-managed identities are fine,
#     just don't double-declare.

set -euo pipefail

# ── config ──────────────────────────────────────────────────────────────────
INFISICAL_ORG_ID="${INFISICAL_ORG_ID:-952236a8-4ed4-45c0-81e8-5157b48557a2}"
INFISICAL_PROJECT_ID="${INFISICAL_PROJECT_ID:-850603f8-e175-4c38-9038-97a1e69d72e6}"
OP_VAULT="${OP_VAULT:-Goldberry Grove - Admin}"
OP_ITEM="${OP_ITEM:-GoldberryGrove Infra}"
OP_FIELD_CLIENT_ID="${OP_FIELD_CLIENT_ID:-infisical_admin_client_id}"
OP_FIELD_CLIENT_SECRET="${OP_FIELD_CLIENT_SECRET:-infisical_admin_client_secret}"
GITHUB_REPO="${GITHUB_REPO:-Goldberry-Playground/odoocker-goldberrygrove}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
IDENTITY_NAME_PREFIX="${IDENTITY_NAME_PREFIX:-gh-oidc-odoocker-}"
PROJECT_VIEWER_ROLE_SLUG="${PROJECT_VIEWER_ROLE_SLUG:-viewer}"
ACCESS_TOKEN_TTL="${ACCESS_TOKEN_TTL:-600}"
ACCESS_TOKEN_MAX_TTL="${ACCESS_TOKEN_MAX_TTL:-1800}"
INFISICAL_DOMAIN="${INFISICAL_DOMAIN:-https://app.infisical.com}"
INFISICAL_API="${INFISICAL_DOMAIN}/api"

# ── arg parsing ─────────────────────────────────────────────────────────────
WORKFLOW_NAME=""
WORKFLOW_FILE=""
EXPLICIT_IDENTITY_ID=""
SHARED_READONLY="no"
while [ $# -gt 0 ]; do
  case "$1" in
    --name) WORKFLOW_NAME="$2"; shift 2 ;;
    --workflow) WORKFLOW_FILE="$2"; shift 2 ;;
    --identity-id)
      # For recovering from a partial create: pass an existing identity's
      # UUID to skip the create step and jump straight to OIDC auth attach
      # + membership grant. Needed because Infisical's org-identity-list
      # endpoint requires permissions tf-infisical-admin doesn't carry, so
      # by-name idempotency isn't possible — the operator owns the UUID for
      # known-already-exists cases.
      EXPLICIT_IDENTITY_ID="$2"; shift 2 ;;
    --shared-readonly)
      # SHARED-IDENTITY mode: omit the bound_claims.job_workflow_ref binding
      # so the trust policy accepts ANY workflow in the configured repo+ref
      # combination. Used to fit multiple low-risk workflows under a single
      # Infisical identity (free tier caps at 5 identities total).
      #
      # Per memory/feedback_oidc_trust_policy_pattern.md (updated 2026-06-23):
      # the per-workflow-binding pattern is the default; this flag is the
      # explicit opt-out for shared-secret-set workflows where the blast
      # radius is unchanged by sharing (all already read the same secrets).
      # NEVER use this flag for an identity that touches prod credentials.
      SHARED_READONLY="yes"; shift 1 ;;
    --help|-h)
      grep -E "^# " "$0" | head -40 | sed 's/^# \?//'
      exit 0
      ;;
    *)
      echo "ERROR: unknown arg '$1'. Use --help." >&2
      exit 1
      ;;
  esac
done
: "${WORKFLOW_NAME:?must pass --name <short-name>}"
: "${WORKFLOW_FILE:?must pass --workflow <file.yml>}"

# ── preflight ───────────────────────────────────────────────────────────────
for bin in op jq curl python3; do
  command -v "$bin" >/dev/null || { echo "ERROR: $bin not found in PATH" >&2; exit 1; }
done

# ── cleanup ─────────────────────────────────────────────────────────────────
TOKEN=""
RESP=""
cleanup() {
  unset TOKEN
  if [ -n "$RESP" ] && [ -f "$RESP" ]; then
    rm -f "$RESP"
  fi
  return 0
}
trap cleanup EXIT INT TERM

# ── helper: api wrapper ─────────────────────────────────────────────────────
# Body comes from stdin via printf so values never appear in argv. Returns
# body on stdout, http code via $LAST_HTTP_CODE.
LAST_HTTP_CODE=""
api() {
  local method="$1" path="$2" body="${3:-}"
  local code
  RESP=$(mktemp)
  chmod 600 "$RESP"
  if [ -n "$body" ]; then
    code=$(printf '%s' "$body" \
      | curl -sS -o "$RESP" -w '%{http_code}' \
          -X "$method" \
          -H "Authorization: Bearer $TOKEN" \
          -H "Content-Type: application/json" \
          --data @- \
          "$INFISICAL_API$path")
  else
    code=$(curl -sS -o "$RESP" -w '%{http_code}' \
      -X "$method" \
      -H "Authorization: Bearer $TOKEN" \
      "$INFISICAL_API$path")
  fi
  LAST_HTTP_CODE="$code"
  cat "$RESP"
  rm -f "$RESP"
  RESP=""
}

# ── step 0: get admin access token from 1P-stored client credentials ────────
echo "[$WORKFLOW_NAME] auth: exchanging tf-infisical-admin client-creds for access token" >&2
TMPFILE=$(mktemp)
chmod 600 "$TMPFILE"
cat > "$TMPFILE" <<EOF
INFISICAL_CLIENT_ID=op://${OP_VAULT}/${OP_ITEM}/${OP_FIELD_CLIENT_ID}
INFISICAL_CLIENT_SECRET=op://${OP_VAULT}/${OP_ITEM}/${OP_FIELD_CLIENT_SECRET}
EOF
# shellcheck disable=SC2016
# Single quotes intentional — $INFISICAL_CLIENT_ID/_SECRET are injected by
# op run into the inner bash, NOT expanded by the outer shell. Only
# $INFISICAL_API is splice-substituted (it's a config value, not a secret).
TOKEN=$(op run --env-file="$TMPFILE" -- bash -c '
  printf "{\"clientId\":\"%s\",\"clientSecret\":\"%s\"}" \
    "$INFISICAL_CLIENT_ID" "$INFISICAL_CLIENT_SECRET" \
  | curl -sf -X POST "'"$INFISICAL_API"'/v1/auth/universal-auth/login" \
      -H "Content-Type: application/json" --data @- \
  | jq -r .accessToken
')
rm -f "$TMPFILE"
if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
  echo "ERROR: universal-auth token exchange failed for tf-infisical-admin" >&2
  exit 1
fi

# ── step 1: create the identity (or use --identity-id for recovery) ─────────
IDENTITY_NAME="${IDENTITY_NAME_PREFIX}${WORKFLOW_NAME}"

if [ -n "$EXPLICIT_IDENTITY_ID" ]; then
  echo "[$WORKFLOW_NAME] using --identity-id $EXPLICIT_IDENTITY_ID (recovery mode, skipping create)" >&2
  IDENTITY_ID="$EXPLICIT_IDENTITY_ID"
else
  echo "[$WORKFLOW_NAME] POST /v1/identities" >&2
  CREATE_BODY=$(jq -n \
    --arg name "$IDENTITY_NAME" \
    --arg orgId "$INFISICAL_ORG_ID" \
    '{name: $name, organizationId: $orgId, role: "no-access"}')
  CREATE_RESP=$(api POST "/v1/identities" "$CREATE_BODY")
  IDENTITY_ID=$(echo "$CREATE_RESP" | jq -r '.identity.id // empty')
  if [ -z "$IDENTITY_ID" ]; then
    echo "[$WORKFLOW_NAME]   ✗ identity create failed (HTTP $LAST_HTTP_CODE)" >&2
    echo "[$WORKFLOW_NAME]   response: $CREATE_RESP" >&2
    echo "" >&2
    echo "  If the error is 'name already exists', the identity was created" >&2
    echo "  in a previous (partially-failed) run. Recover with:" >&2
    echo "    1. Find the UUID in Infisical UI: Org → Access Control → Identities → '$IDENTITY_NAME'" >&2
    echo "    2. Re-run with --identity-id <UUID> to attach OIDC + grant project access" >&2
    exit 1
  fi
  echo "[$WORKFLOW_NAME]   ✓ created identity $IDENTITY_ID" >&2
fi

# ── step 2: get-or-attach OIDC auth method ──────────────────────────────────
echo "[$WORKFLOW_NAME] checking if OIDC auth already attached" >&2
HAS_OIDC_AUTH=$(api GET "/v1/auth/oidc-auth/identities/$IDENTITY_ID" \
  | jq -r 'if .identityOidcAuth then "yes" else "no" end' 2>/dev/null \
  || echo "no")

if [ "$HAS_OIDC_AUTH" = "yes" ]; then
  echo "[$WORKFLOW_NAME]   ⚠ OIDC auth already attached — skipping" >&2
else
  echo "[$WORKFLOW_NAME]   POST /v1/auth/oidc-auth/identities/$IDENTITY_ID" >&2
  # Trust policy:
  #   - bound_subject pins to LITERAL repo + ref (always)
  #   - bound_claims.job_workflow_ref pins to a SPECIFIC workflow file
  #     UNLESS --shared-readonly was passed (in which case the trust policy
  #     accepts ANY workflow on the configured repo+ref; used to fit multiple
  #     low-risk workflows under one identity under the free-tier 5-identity cap)
  # Per [[feedback_oidc_trust_policy_pattern]] (updated 2026-06-23).
  BOUND_SUBJECT="repo:${GITHUB_REPO}:ref:refs/heads/${GITHUB_BRANCH}"
  BOUND_WORKFLOW_REF="${GITHUB_REPO}/.github/workflows/${WORKFLOW_FILE}@refs/heads/${GITHUB_BRANCH}"
  if [ "$SHARED_READONLY" = "yes" ]; then
    echo "[$WORKFLOW_NAME]   (--shared-readonly: omitting bound_claims.job_workflow_ref — any workflow on $GITHUB_REPO:$GITHUB_BRANCH can use this identity)" >&2
    OIDC_BODY=$(jq -n \
      --arg discovery "https://token.actions.githubusercontent.com" \
      --arg issuer "https://token.actions.githubusercontent.com" \
      --arg subject "$BOUND_SUBJECT" \
      --argjson ttl "$ACCESS_TOKEN_TTL" \
      --argjson maxttl "$ACCESS_TOKEN_MAX_TTL" \
      '{
        oidcDiscoveryUrl: $discovery,
        boundIssuer: $issuer,
        boundSubject: $subject,
        boundClaims: {},
        accessTokenTTL: $ttl,
        accessTokenMaxTTL: $maxttl,
        accessTokenNumUsesLimit: 0,
        accessTokenTrustedIps: [{ipAddress: "0.0.0.0/0"}]
      }')
  else
    OIDC_BODY=$(jq -n \
      --arg discovery "https://token.actions.githubusercontent.com" \
      --arg issuer "https://token.actions.githubusercontent.com" \
      --arg subject "$BOUND_SUBJECT" \
      --arg wfref "$BOUND_WORKFLOW_REF" \
      --argjson ttl "$ACCESS_TOKEN_TTL" \
      --argjson maxttl "$ACCESS_TOKEN_MAX_TTL" \
      '{
        oidcDiscoveryUrl: $discovery,
        boundIssuer: $issuer,
        boundSubject: $subject,
        boundClaims: { job_workflow_ref: $wfref },
        accessTokenTTL: $ttl,
        accessTokenMaxTTL: $maxttl,
        accessTokenNumUsesLimit: 0,
        accessTokenTrustedIps: [{ipAddress: "0.0.0.0/0"}]
      }')
  fi
  api POST "/v1/auth/oidc-auth/identities/$IDENTITY_ID" "$OIDC_BODY" >/dev/null
  if [ "$LAST_HTTP_CODE" -lt 200 ] || [ "$LAST_HTTP_CODE" -ge 300 ]; then
    echo "[$WORKFLOW_NAME]   ✗ OIDC auth attach failed (HTTP $LAST_HTTP_CODE)" >&2
    exit 1
  fi
  echo "[$WORKFLOW_NAME]   ✓ OIDC auth attached" >&2
fi

# ── step 3: get-or-grant project membership ─────────────────────────────────
# Endpoint per Infisical TF provider's project_identity.go:
#   POST /api/v2/workspace/{projectId}/identity-memberships/{identityId}
# Identity ID is in BOTH the URL path AND the request body. Body shape:
#   {projectId, identityId, roles: [{role: "<slug>"}]}
echo "[$WORKFLOW_NAME] checking project membership on grove-odoocker" >&2
HAS_MEMBERSHIP=$(api GET "/v2/workspace/$INFISICAL_PROJECT_ID/identity-memberships" \
  | jq -r --arg id "$IDENTITY_ID" \
      'if (.identityMemberships[]? | select(.identity.id == $id)) then "yes" else "no" end' \
  | head -1)
HAS_MEMBERSHIP="${HAS_MEMBERSHIP:-no}"

if [ "$HAS_MEMBERSHIP" = "yes" ]; then
  echo "[$WORKFLOW_NAME]   ⚠ already a member of grove-odoocker — skipping" >&2
else
  echo "[$WORKFLOW_NAME]   POST /v2/workspace/$INFISICAL_PROJECT_ID/identity-memberships/$IDENTITY_ID" >&2
  MEMBERSHIP_BODY=$(jq -n \
    --arg pid "$INFISICAL_PROJECT_ID" \
    --arg iid "$IDENTITY_ID" \
    --arg role "$PROJECT_VIEWER_ROLE_SLUG" \
    '{projectId: $pid, identityId: $iid, roles: [{role: $role}]}')
  api POST "/v2/workspace/$INFISICAL_PROJECT_ID/identity-memberships/$IDENTITY_ID" "$MEMBERSHIP_BODY" >/dev/null
  if [ "$LAST_HTTP_CODE" -lt 200 ] || [ "$LAST_HTTP_CODE" -ge 300 ]; then
    echo "[$WORKFLOW_NAME]   ✗ membership grant failed (HTTP $LAST_HTTP_CODE)" >&2
    exit 1
  fi
  echo "[$WORKFLOW_NAME]   ✓ Viewer role granted on grove-odoocker" >&2
fi

# ── step 4: emit JSON result on stdout ──────────────────────────────────────
jq -n \
  --arg name "$WORKFLOW_NAME" \
  --arg identity_name "$IDENTITY_NAME" \
  --arg identity_id "$IDENTITY_ID" \
  --arg workflow "$WORKFLOW_FILE" \
  --arg repo "$GITHUB_REPO" \
  --arg branch "$GITHUB_BRANCH" \
  '{
    name: $name,
    identity_name: $identity_name,
    identity_id: $identity_id,
    workflow_file: $workflow,
    bound_workflow_ref: "\($repo)/.github/workflows/\($workflow)@refs/heads/\($branch)"
  }'

echo "[$WORKFLOW_NAME] done — paste identity_id into the workflow YAML's INFISICAL_IDENTITY_ID env" >&2
