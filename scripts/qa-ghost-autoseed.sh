#!/usr/bin/env bash
# Autoseed the QA droplet's 3 Ghost instances + wire their Content API keys
# into /etc/grove/.env, then recreate the storefronts so they pick the keys
# up. Runs ON the QA droplet -- invoked by cloud-init after compose up
# (non-fatal), and safe to re-run by hand via SSH.
#
# Replaces the manual flow in docs/GHOST.md (SSH + setup-all-ghosts.sh +
# paste keys into Infisical + restart). Keys never leave the droplet: they
# are only valid for the Ghosts on this droplet and both die together on
# recreate, so pushing them to Infisical bought nothing but steps.
#
# Self-contained: the bootstrap logic (/opt/grove/ghost-bootstrap.js) runs
# INSIDE each ghost container via `docker compose exec -T ... node` -- the
# ghost:5 image ships node 18+ with global fetch. No dependency on the
# grove-odoo-modules checkout (the QA droplet has no git-sync mount).
#
# Idempotent: Ghost setup is skipped if done; the integration is
# find-or-create by name, so re-runs upsert the SAME keys into .env.
#
# Files:
#   /etc/grove/.ghost-admin-pass   generated once per droplet (0600) --
#                                  operator can read it to log into a Ghost
#                                  admin UI over an SSH tunnel
#   /etc/grove/.env                gains/updates GHOST_KEY_{GOLDBERRY,GGG,NURSERY}
#
# Exit codes: 0 = all tenants seeded + frontends recreated; 1 = any failure
# (cloud-init treats this as non-fatal; deploys never block on Ghost).
set -euo pipefail

COMPOSE_FILE="${COMPOSE_FILE:-/etc/grove/docker-compose.yml}"
ENV_FILE="${ENV_FILE:-/etc/grove/.env}"
BOOTSTRAP_JS="${BOOTSTRAP_JS:-/opt/grove/ghost-bootstrap.js}"
PASS_FILE="/etc/grove/.ghost-admin-pass"
ADMIN_EMAIL_DOMAIN="${ADMIN_EMAIL_DOMAIN:-qa.gatheringatthegrove.com}"

compose() { docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" "$@"; }

for f in "$COMPOSE_FILE" "$ENV_FILE" "$BOOTSTRAP_JS"; do
  [ -f "$f" ] || { echo "ERROR: $f not found" >&2; exit 1; }
done

# One admin password per droplet, generated on first run. QA is ephemeral;
# the password's whole lifetime is this droplet's lifetime.
if [ ! -f "$PASS_FILE" ]; then
  umask 077
  openssl rand -hex 16 > "$PASS_FILE"
  umask 022
fi
GHOST_ADMIN_PASSWORD=$(cat "$PASS_FILE")

# tenant|internal port|blog title|integration name
TENANTS="goldberry|2368|Goldberry Grove Farm|Goldberry Next.js Frontend
ggg|2369|GGG Woodworking|GGG Next.js Frontend
nursery|2370|At The Grove Nursery|Nursery Next.js Frontend"

# Upsert KEY=VALUE into the env file (replace if present, append if not).
upsert_env() {
  local key="$1" value="$2"
  if grep -q "^${key}=" "$ENV_FILE"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
  fi
}

overall_fail=0
while IFS='|' read -r tenant port title integration; do
  [ -n "$tenant" ] || continue
  service="ghost-${tenant}"
  echo "=== ${tenant} (${service}:${port}) ==="

  # Wait up to 120s for Ghost to answer inside its own container. Fresh
  # containers run SQLite migrations on first boot (~30-60s). node -e
  # probe because the ghost image has no curl/wget guarantee.
  ready=0
  for _ in $(seq 1 24); do
    # </dev/null is LOAD-BEARING: docker compose exec attaches stdin even
    # with -T, and inside a `while read` loop it drains the loop's input.
    # First live run (2026-07-04, run 28713663225) seeded ONLY goldberry
    # because this probe swallowed the ggg + nursery lines.
    if compose exec -T "$service" node -e "fetch('http://localhost:${port}/ghost/api/admin/site/').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" </dev/null 2>/dev/null; then
      ready=1
      break
    fi
    sleep 5
  done
  if [ "$ready" != "1" ]; then
    echo "  ERROR: ${service} not responsive after 120s -- check 'docker compose logs ${service}'" >&2
    overall_fail=1
    continue
  fi

  # Bootstrap inside the container; capture only the key line from stdout.
  key_line=$(compose exec -T \
    -e "GHOST_URL=http://localhost:${port}" \
    -e "GHOST_ORIGIN=http://${service}:${port}" \
    -e "GHOST_ADMIN_EMAIL=admin+${tenant}@${ADMIN_EMAIL_DOMAIN}" \
    -e "GHOST_ADMIN_PASSWORD=${GHOST_ADMIN_PASSWORD}" \
    -e "GHOST_ADMIN_NAME=${title}" \
    -e "GHOST_BLOG_TITLE=${title}" \
    -e "GHOST_INTEGRATION_NAME=${integration}" \
    "$service" node < "$BOOTSTRAP_JS") || {
    echo "  ERROR: bootstrap failed for ${tenant}" >&2
    overall_fail=1
    continue
  }

  content_key="${key_line#GHOST_CONTENT_KEY=}"
  if [ -z "$content_key" ] || [ "$content_key" = "$key_line" ]; then
    echo "  ERROR: no GHOST_CONTENT_KEY in bootstrap output for ${tenant}" >&2
    overall_fail=1
    continue
  fi

  env_key="GHOST_KEY_$(echo "$tenant" | tr '[:lower:]' '[:upper:]')"
  upsert_env "$env_key" "$content_key"
  echo "  ok: ${env_key} written (len=${#content_key})"
done <<< "$TENANTS"

if [ "$overall_fail" != "0" ]; then
  echo "ERROR: one or more tenants failed to seed -- frontends NOT recreated" >&2
  exit 1
fi

# Recreate the storefronts so compose re-reads the env file. `up -d` only
# recreates services whose config changed (the env values), so the rest of
# the stack is untouched.
echo "=== recreating frontends with fresh Ghost keys ==="
compose up -d hub goldberry ggg nursery
echo "done."
