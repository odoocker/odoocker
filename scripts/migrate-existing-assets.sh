#!/usr/bin/env bash
# One-time migration: move existing frontend assets out of grove-sites'
# apps/*/public/ directories and up to the grove-assets Spaces bucket.
#
# Currently in grove-sites (as of 2026-07-01 audit):
#   apps/goldberry/public/  22 MB across 25 files (photos/, video/)
#   apps/nursery/public/    1.5 MB across 9 files
#   apps/ggg/public/        0 bytes
#   apps/hub/public/        empty
#
# After this runs + you delete the migrated files from grove-sites, the
# next `docker build` of each frontend image drops by that amount (22 MB
# for goldberry alone). Assets served via `https://assets.gatheringatthegrove.com/`
# from that point forward.
#
# Requirements:
#   - infra/terraform/environments/assets/ applied
#   - Operator Spaces keys pushed to 1P (see that env's README)
#   - scripts/upload-assets.sh works
#   - grove-sites repo checked out as a sibling to odoocker (../grove-sites)
#
# Usage:
#   scripts/migrate-existing-assets.sh [--dry-run]
#
# Exit codes:
#   0  migration complete
#   1  grove-sites not found at ../grove-sites
#   2  upload-assets.sh not found or not executable
#   3  upload failed for at least one file
set -euo pipefail

DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then
  DRY_RUN=1
  echo "  (DRY RUN -- no uploads will happen)"
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GROVE_SITES="${REPO_ROOT}/../grove-sites"
UPLOAD_SCRIPT="${REPO_ROOT}/scripts/upload-assets.sh"

if [ ! -d "$GROVE_SITES" ]; then
  echo "::error::grove-sites repo not found at $GROVE_SITES." >&2
  echo "  Clone it as a sibling of odoocker: git clone git@github.com:Goldberry-Playground/grove-sites $GROVE_SITES" >&2
  exit 1
fi
if [ ! -x "$UPLOAD_SCRIPT" ]; then
  echo "::error::$UPLOAD_SCRIPT not found or not executable" >&2
  exit 2
fi

# Map grove-sites apps to tenant prefix in the bucket
declare -a PAIRS=(
  "goldberry:apps/goldberry/public"
  "nursery:apps/nursery/public"
  "ggg:apps/ggg/public"
  "hub:apps/hub/public"
)

fail=0
for pair in "${PAIRS[@]}"; do
  tenant="${pair%%:*}"
  src_rel="${pair#*:}"
  src="${GROVE_SITES}/${src_rel}"

  if [ ! -d "$src" ]; then
    echo "  [skip] $tenant -- $src doesn't exist"
    continue
  fi

  count=$(find "$src" -type f 2>/dev/null | wc -l | tr -d ' ')
  if [ "$count" = "0" ]; then
    echo "  [skip] $tenant -- $src is empty"
    continue
  fi

  size=$(du -sh "$src" 2>/dev/null | awk '{print $1}')
  echo ""
  echo "=== $tenant ==="
  echo "  source: $src"
  echo "  files:  $count ($size)"

  if [ "$DRY_RUN" = "1" ]; then
    echo "  (dry run -- would upload to grove-assets/$tenant/)"
    continue
  fi

  # Upload each CHILD of public/ separately so remote paths come out as
  # <tenant>/photos/... rather than <tenant>/public/photos/... --
  # assetPath() in grove-sites emits URLs WITHOUT the public/ segment.
  # (First migration run on 2026-07-02 hit this: passing the public/ dir
  # itself made upload-assets.sh default the remote prefix to "public".)
  tenant_fail=0
  for child in "$src"/*; do
    [ -e "$child" ] || continue
    if ! "$UPLOAD_SCRIPT" "$tenant" "$child" 2>&1; then
      tenant_fail=1
    fi
  done
  if [ "$tenant_fail" != "0" ]; then
    echo "::error::Upload failed for tenant $tenant" >&2
    fail=1
  fi
done

if [ "$fail" != "0" ]; then
  echo ""
  echo "::error::One or more tenant uploads failed. Review output above; retry per-tenant with upload-assets.sh." >&2
  exit 3
fi

echo ""
echo "  [ok] All migrations complete."
echo "  Next steps:"
echo "    1. Verify a few URLs in a browser (e.g. https://assets.gatheringatthegrove.com/goldberry/photos/some-file.jpg)"
echo "    2. In grove-sites, refactor image paths from '/path.jpg' to '\${NEXT_PUBLIC_ASSETS_URL}/goldberry/path.jpg' (etc.)"
echo "    3. Delete the migrated files from grove-sites/apps/*/public/ (keep favicon.ico + other non-image essentials)"
echo "    4. Commit + PR the grove-sites changes"
