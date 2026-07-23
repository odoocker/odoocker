#!/usr/bin/env bash
# Phase C seed step: bootstrap all 3 QA Ghost instances at once + emit the
# infisical commands to push their Content Keys back into the vault.
#
# Runs on the QA droplet AFTER a fresh deploy, when the 3 ghost-* containers
# are healthy but before storefronts have real Content Keys. Idempotent: the
# underlying setup_ghost_integration.py skips setup + reuses the integration
# if it already exists, so re-running is safe.
#
# Usage:
#   ssh -i ~/.ssh/grove-qa-admin root@<droplet_ip>
#   bash /workspace/current/setup-all-ghosts.sh
#
# (Or from a runner with SSH access:)
#   ssh -i ~/.ssh/grove-qa-deploy root@<droplet_ip> \
#     'bash -s' < scripts/setup-all-ghosts.sh
#
# The script prints a block of `infisical secrets set ...` commands at the
# end. Copy those, run them on the operator laptop (where op auth is alive),
# then re-deploy or `docker restart hub goldberry ggg nursery` so the
# frontends pick up the new keys.
#
# Env inputs (with sensible defaults for QA):
#   GHOST_ADMIN_PASSWORD  required. Same value for all 3 instances; QA is
#                         low-value + rotates on every droplet recreate, so
#                         one password is fine. Prod would rotate per-tenant.
#   ADMIN_EMAIL_DOMAIN    optional; default 'qa.gatheringatthegrove.com'.
#
# See docs/GHOST.md for the full runbook.

set -euo pipefail

: "${GHOST_ADMIN_PASSWORD:?GHOST_ADMIN_PASSWORD is required (any value; QA is ephemeral)}"
ADMIN_EMAIL_DOMAIN="${ADMIN_EMAIL_DOMAIN:-qa.gatheringatthegrove.com}"

# Path to the per-tenant setup script -- lives in the grove-odoo-modules
# git-sync mount on the droplet. If you're running this LOCALLY against a
# local compose (not the QA droplet), override SETUP_SCRIPT.
SETUP_SCRIPT="${SETUP_SCRIPT:-/workspace/current/scripts/setup_ghost_integration.py}"

if [ ! -f "$SETUP_SCRIPT" ]; then
  echo "ERROR: $SETUP_SCRIPT not found." >&2
  echo "  On the QA droplet this comes from the grove-odoo-modules git-sync mount." >&2
  echo "  Override with SETUP_SCRIPT=/path/to/setup_ghost_integration.py if running elsewhere." >&2
  exit 1
fi

declare -A TENANTS=(
  [goldberry]="2368|Goldberry Grove Farm|Goldberry Next.js Frontend"
  [ggg]="2369|GGG Woodworking|GGG Next.js Frontend"
  [nursery]="2370|At The Grove Nursery|Nursery Next.js Frontend"
)

# Ordered list so output is stable (bash assoc arrays don't preserve order).
TENANT_ORDER=(goldberry ggg nursery)

declare -A KEYS=()

for tenant in "${TENANT_ORDER[@]}"; do
  IFS='|' read -r port blog_title integration_name <<< "${TENANTS[$tenant]}"
  ghost_container="ghost-${tenant}"
  ghost_url="http://${ghost_container}:${port}"

  echo ""
  echo "=== Seeding ${tenant} (${ghost_url}) ==="

  # Wait up to 90s for Ghost to be responsive. Fresh containers take ~30-60s
  # to boot the first time (SQLite migrations + Node startup).
  for i in $(seq 1 18); do
    if curl -sf -o /dev/null --max-time 5 "${ghost_url}/ghost/api/admin/site/"; then
      break
    fi
    if [ "$i" = "18" ]; then
      echo "  ERROR: ${ghost_container} not responsive at ${ghost_url} after 90s." >&2
      echo "  Check: docker ps | grep ${ghost_container} ; docker logs ${ghost_container}" >&2
      exit 1
    fi
    sleep 5
  done

  # Invoke the per-tenant setup script. Captures only stdout (the
  # GHOST_CONTENT_KEY=... line); stderr flows to the terminal for progress.
  key_line=$(
    GHOST_URL="$ghost_url" \
    GHOST_ADMIN_EMAIL="admin+${tenant}@${ADMIN_EMAIL_DOMAIN}" \
    GHOST_ADMIN_PASSWORD="$GHOST_ADMIN_PASSWORD" \
    GHOST_ADMIN_NAME="${blog_title}" \
    GHOST_BLOG_TITLE="${blog_title}" \
    GHOST_INTEGRATION_NAME="${integration_name}" \
    python3 "$SETUP_SCRIPT"
  )

  # Extract just the key value (right of the =).
  content_key="${key_line#GHOST_CONTENT_KEY=}"
  if [ -z "$content_key" ] || [ "$content_key" = "$key_line" ]; then
    echo "  ERROR: setup script did not emit GHOST_CONTENT_KEY=<...> for ${tenant}." >&2
    echo "  Got: ${key_line}" >&2
    exit 1
  fi
  KEYS[$tenant]="$content_key"
  echo "  ✓ content key captured (length=${#content_key})"
done

# Emit the infisical seed block. Deliberately printed as a code block the
# operator copies wholesale -- avoids the "forgot one tenant" mistake.
echo ""
echo "===================================================================="
echo "Copy + run this block on the operator laptop (where op auth is alive):"
echo "===================================================================="
echo ""
echo "# --- BEGIN infisical seed for QA Ghost Content Keys ---"
echo "infisical secrets set \\"
echo "  --projectId=\$INFISICAL_PROJECT_ID \\"
echo "  --env=prod \\"
echo "  GHOST_KEY_GOLDBERRY=${KEYS[goldberry]} \\"
echo "  GHOST_KEY_GGG=${KEYS[ggg]} \\"
echo "  GHOST_KEY_NURSERY=${KEYS[nursery]} \\"
echo "  >/dev/null 2>&1 && echo 'Ghost keys pushed to Infisical'"
echo "# --- END infisical seed ---"
echo ""
echo "Then either re-run 'gh workflow run \"QA Deploy\"' OR (fast path):"
echo "  ssh -i ~/.ssh/grove-qa-admin root@<droplet_ip> \\"
echo "    'docker restart hub goldberry ggg nursery'"
echo ""
