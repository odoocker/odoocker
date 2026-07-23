#!/usr/bin/env bash
# check-image-shape.sh — Verify Grove images contain the files / behaviors
# we depend on, BEFORE qa-deploy hands them to a live droplet.
#
# Background: PR #90 took ~2 hours to diagnose because the grove-odoo image
# successfully built + pushed + pulled, but it didn't actually contain our
# custom entrypoint.sh (the Dockerfile was missing a COPY line). docker-odoo's
# CI smoke test boots `odoo --stop-after-init` which exercises NONE of the
# entrypoint's orchestration -- so the regression sailed past CI and got
# caught only by SSH-md5-diff on the running container.
#
# This script asserts known invariants ABOUT THE IMAGE BITS, not "did it
# build." Run from qa-deploy.yml as the last preflight before TF apply.
#
# What it checks:
#   grove-odoo:
#     - /entrypoint.sh contains "odoorc.sh"           (PR #90 regression)
#     - /entrypoint.sh contains "APP_ENV"             (PR #89 regression)
#     - /entrypoint.sh has `: ${HOST:=`               (PR #91 regression)
#     - /odoorc.sh contains "done < <(env)"           (PR #89 fix present)
#   grove-caddy:
#     - `caddy list-modules` contains dns.providers.digitalocean
#     - `caddy version` exits 0
#
# Usage:
#   bash scripts/check-image-shape.sh                            # defaults
#   ODOO_IMAGE=ghcr.io/foo/grove-odoo:abc bash scripts/check-image-shape.sh
#
# Env:
#   ODOO_IMAGE      Full image ref (default: ghcr.io/goldberry-playground/grove-odoo:latest)
#   CADDY_IMAGE     Full image ref (default: ghcr.io/goldberry-playground/grove-caddy:latest)
#
# Exit codes:
#   0  All assertions passed
#   1  At least one assertion failed; output names the failing image + check

set -euo pipefail

ODOO_IMAGE="${ODOO_IMAGE:-ghcr.io/goldberry-playground/grove-odoo:latest}"
CADDY_IMAGE="${CADDY_IMAGE:-ghcr.io/goldberry-playground/grove-caddy:latest}"

fail=0

# Inspect grove-odoo by bypassing ENTRYPOINT. Our entrypoint expects a
# bind-mounted /.env and crashes without it -- the structural checks only
# need to read files, so we use --entrypoint bash. (entrypoint.sh's .env
# loader fragility was fixed in this same PR's odoo/entrypoint.sh change,
# but older :latest tags still in the wild crash without the bypass.)
check_odoo() {
  local description="$1"
  local cmd="$2"
  if docker run --rm --entrypoint bash "$ODOO_IMAGE" -c "$cmd" >/dev/null 2>&1; then
    echo "  ✓ $ODOO_IMAGE: $description"
  else
    echo "  ✗ $ODOO_IMAGE: $description"
    fail=1
  fi
}

# Inspect grove-caddy via its normal entrypoint (which is just the caddy
# binary -- it forwards args fine). No bypass needed.
check_caddy() {
  local description="$1"
  shift
  if docker run --rm "$CADDY_IMAGE" "$@" >/dev/null 2>&1; then
    echo "  ✓ $CADDY_IMAGE: $description"
  else
    echo "  ✗ $CADDY_IMAGE: $description"
    fail=1
  fi
}

echo "── grove-odoo image-shape checks ($ODOO_IMAGE) ──"
docker pull -q "$ODOO_IMAGE" >/dev/null
check_odoo "/entrypoint.sh invokes /odoorc.sh (PR #90 fix)" \
  'grep -q odoorc.sh /entrypoint.sh'
check_odoo "/entrypoint.sh handles APP_ENV (PR #89 fix)" \
  'grep -q "APP_ENV" /entrypoint.sh'
check_odoo "/entrypoint.sh has HOST/PORT defaults (PR #91 fix)" \
  'grep -qE "^: \\\$\\{HOST:=" /entrypoint.sh'
check_odoo "/odoorc.sh iterates over full env (PR #89 fix)" \
  'grep -q "done < <(env)" /odoorc.sh'
check_odoo "/entrypoint.sh .env loader is guarded (this PR fix)" \
  'grep -q "if \\[ -f .env \\]" /entrypoint.sh'

echo
echo "── grove-caddy image-shape checks ($CADDY_IMAGE) ──"
docker pull -q "$CADDY_IMAGE" >/dev/null
check_caddy "caddy binary boots" caddy version
check_caddy "caddy-dns/digitalocean module is loaded (xcaddy build worked)" \
  sh -c 'caddy list-modules | grep -q dns.providers.digitalocean'

echo
if [ "$fail" -ne 0 ]; then
  cat >&2 <<EOF
ERROR: one or more image-shape assertions failed. Do NOT deploy this image to
QA -- it's missing files or behaviors that the runtime needs. Fix the
underlying Dockerfile / script issue and re-trigger the image-rebuild
workflow (docker-odoo.yml / docker-caddy.yml) before re-attempting deploy.

Recovery for the most common failure (PR #90-class missing COPY):
  1. SSH the most recent failed QA droplet AND a known-good local build.
  2. md5 the relevant file (entrypoint.sh, odoorc.sh, Dockerfile) on each.
  3. If they differ, audit the Dockerfile for missing COPY of the source file.
EOF
  exit 1
fi

echo "✓ all image-shape assertions passed"
