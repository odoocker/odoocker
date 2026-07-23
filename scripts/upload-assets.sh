#!/usr/bin/env bash
# Upload a file (or directory) to the grove-assets Spaces bucket under the
# given tenant prefix, then purge that path from the DO CDN cache so the
# new asset is served immediately.
#
# Uses the operator RW Spaces key stored in 1Password (from the TF apply
# output of infra/terraform/environments/assets/). Never echoes the key.
#
# Usage:
#   scripts/upload-assets.sh <tenant> <local-path> [<remote-path>]
#
# Examples:
#   # Upload a single file, keeping its basename
#   scripts/upload-assets.sh goldberry ~/Downloads/hero-orchard.jpg
#   -> uploads to grove-assets/goldberry/hero-orchard.jpg
#   -> served at https://assets.gatheringatthegrove.com/goldberry/hero-orchard.jpg
#
#   # Upload with a specific remote path (useful for renaming)
#   scripts/upload-assets.sh goldberry ~/Downloads/DSC_0132.jpg photos/spring-planting.jpg
#   -> uploads to grove-assets/goldberry/photos/spring-planting.jpg
#
#   # Upload a whole directory (recursive, keeps directory structure)
#   scripts/upload-assets.sh nursery ~/Photos/nursery-summer-2026/
#   -> uploads every file under that dir to grove-assets/nursery/nursery-summer-2026/
#
# Requirements:
#   - `op` CLI signed in (Goldberry Grove - Admin vault)
#   - `s3cmd` installed (`brew install s3cmd`) OR mc if fallback needed
#   - Network access to DO Spaces + DO API
#
# Exit codes:
#   0  upload + cache purge succeeded
#   1  bad args
#   2  tenant not in the known-tenant list (see TENANTS below)
#   3  op read failed (key not in 1Password OR op not signed in)
#   4  s3cmd upload failed
#   5  cache purge failed (upload succeeded but CDN may still serve stale)
set -euo pipefail

TENANTS=(hub goldberry ggg nursery shared)
BUCKET="grove-assets"
REGION="nyc3"
CDN_ENDPOINT_HOSTNAME="assets.gatheringatthegrove.com"

# 1Password references (must match what post-apply pushes into 1P)
OP_KEY_ID_REF="op://Goldberry Grove - Admin/GoldberryGrove Infra/grove_assets_access_key_id"
OP_SECRET_REF="op://Goldberry Grove - Admin/GoldberryGrove Infra/grove_assets_secret_key"
OP_DO_TOKEN_REF="op://Goldberry Grove - Admin/GoldberryGrove Infra/do_token"

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "Usage: $0 <tenant> <local-path> [<remote-path>]" >&2
  echo "  tenant       one of: ${TENANTS[*]}" >&2
  echo "  local-path   file or directory on your machine" >&2
  echo "  remote-path  optional: path inside the tenant prefix (default: basename of local-path)" >&2
  exit 1
fi

TENANT="$1"
LOCAL_PATH="$2"
REMOTE_SUFFIX="${3:-}"

# Validate tenant against known list
found=0
for t in "${TENANTS[@]}"; do
  if [ "$t" = "$TENANT" ]; then
    found=1
    break
  fi
done
if [ "$found" = "0" ]; then
  echo "::error::Unknown tenant '$TENANT'. Expected one of: ${TENANTS[*]}" >&2
  echo "  If adding a new tenant, add it to TENANTS in this script + var.tenant_prefixes in the TF env." >&2
  exit 2
fi

# Validate local path exists
if [ ! -e "$LOCAL_PATH" ]; then
  echo "::error::Local path does not exist: $LOCAL_PATH" >&2
  exit 1
fi

# Fetch Spaces credentials from 1Password (never echoes them)
if ! ACCESS_KEY_ID=$(op read "$OP_KEY_ID_REF" 2>/dev/null); then
  echo "::error::Could not read Spaces access key from 1Password ($OP_KEY_ID_REF)." >&2
  echo "  Either op is not signed in ('op signin') OR the TF apply for infra/terraform/environments/assets/ hasn't been" >&2
  echo "  followed by the post-apply push of the outputs into 1Password. See that env's README." >&2
  exit 3
fi
if ! SECRET_KEY=$(op read "$OP_SECRET_REF" 2>/dev/null); then
  echo "::error::Could not read Spaces secret key from 1Password ($OP_SECRET_REF)." >&2
  exit 3
fi

# Prefer s3cmd; fall back to mc if not installed
if command -v s3cmd >/dev/null 2>&1; then
  UPLOADER="s3cmd"
elif command -v mc >/dev/null 2>&1; then
  UPLOADER="mc"
else
  echo "::error::Neither s3cmd nor mc installed. Install one:" >&2
  echo "    brew install s3cmd    # macOS" >&2
  echo "    brew install minio-mc # macOS, alternative" >&2
  exit 1
fi

# Determine remote path
LOCAL_BASENAME=$(basename "$LOCAL_PATH")
if [ -z "$REMOTE_SUFFIX" ]; then
  REMOTE_SUFFIX="$LOCAL_BASENAME"
fi
REMOTE_PATH="${TENANT}/${REMOTE_SUFFIX}"

echo "  Uploading: $LOCAL_PATH"
echo "  Bucket:    $BUCKET/$REMOTE_PATH"
echo "  Via:       $UPLOADER"

# Do the upload
if [ "$UPLOADER" = "s3cmd" ]; then
  # Write a tempfile config so we don't touch the operator's ~/.s3cfg
  cfg=$(mktemp)
  # Single quotes: $cfg expands when the trap fires, not now (SC2064).
  trap 'rm -f "$cfg"' EXIT
  cat > "$cfg" <<CFG
[default]
access_key = $ACCESS_KEY_ID
secret_key = $SECRET_KEY
host_base = ${REGION}.digitaloceanspaces.com
host_bucket = %(bucket)s.${REGION}.digitaloceanspaces.com
use_https = True
signature_v2 = False
CFG

  # -r = recursive for directories; --acl-public since bucket is public-read
  # --guess-mime-type sets Content-Type from file extension
  # --no-progress keeps CI logs clean
  if [ -d "$LOCAL_PATH" ]; then
    s3cmd -c "$cfg" sync --acl-public --guess-mime-type --no-progress \
      "$LOCAL_PATH/" "s3://${BUCKET}/${REMOTE_PATH}/" || {
      echo "::error::s3cmd sync failed" >&2
      exit 4
    }
  else
    s3cmd -c "$cfg" put --acl-public --guess-mime-type --no-progress \
      "$LOCAL_PATH" "s3://${BUCKET}/${REMOTE_PATH}" || {
      echo "::error::s3cmd put failed" >&2
      exit 4
    }
  fi
else
  # mc alternative: configure alias, then cp
  MC_HOST_grove="https://${ACCESS_KEY_ID}:${SECRET_KEY}@${REGION}.digitaloceanspaces.com" \
    mc cp --quiet --recursive "$LOCAL_PATH" "grove/${BUCKET}/${REMOTE_PATH}" || {
    echo "::error::mc cp failed" >&2
    exit 4
  }
fi

echo "  [ok] uploaded"

# Purge the CDN cache for this path (so the new asset serves immediately
# instead of waiting for the edge TTL to expire).
if ! DO_TOKEN=$(op read "$OP_DO_TOKEN_REF" 2>/dev/null); then
  echo "::warning::Could not read DO token for cache purge. Upload succeeded; edge cache will refresh naturally after TTL." >&2
  exit 0
fi

# Look up the CDN endpoint ID (needed for the purge API call)
CDN_ID=$(curl -sf -H "Authorization: Bearer $DO_TOKEN" \
  "https://api.digitalocean.com/v2/cdn/endpoints?per_page=50" 2>/dev/null | \
  python3 -c "
import json, sys
d = json.load(sys.stdin)
for e in d.get('endpoints', []):
    if e.get('custom_domain') == '${CDN_ENDPOINT_HOSTNAME}':
        print(e['id'])
        break
")

if [ -z "$CDN_ID" ]; then
  echo "::warning::Couldn't find CDN endpoint for ${CDN_ENDPOINT_HOSTNAME}. Skipping purge (edge will refresh after TTL)." >&2
  exit 0
fi

# Purge specific path
PURGE_BODY=$(python3 -c "import json; print(json.dumps({'files': ['${REMOTE_PATH}']}))")
if curl -sf -X DELETE -H "Authorization: Bearer $DO_TOKEN" -H "Content-Type: application/json" \
    --data "$PURGE_BODY" "https://api.digitalocean.com/v2/cdn/endpoints/${CDN_ID}/cache" >/dev/null 2>&1; then
  echo "  [ok] CDN cache purged for /${REMOTE_PATH}"
  echo "  URL: https://${CDN_ENDPOINT_HOSTNAME}/${REMOTE_PATH}"
else
  echo "::warning::CDN purge failed. Upload succeeded; edge cache will refresh naturally after TTL." >&2
  exit 5
fi
