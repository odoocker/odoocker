#!/usr/bin/env bash
# check-ghcr-images.sh — Verify Grove GHCR images are anonymously pullable.
#
# Catches the failure mode that wasted ~20 min on 2026-06-24: a private GHCR
# package silently breaks cloud-init's `docker compose pull` step on the QA
# droplet, with no signal until 20+ min later when the grove-ready sentinel
# poll times out. Run this BEFORE droplet creation to fail fast.
#
# Probe is anonymous HEAD via the GHCR manifest API. If a package is private,
# anonymous gets 403 → we exit non-zero with the package name. If it's public
# the response is 200 (or 401 with a token-required hint, depending on tag —
# both are treated as "exists & accessible to anonymous puller").
#
# Usage:
#   bash scripts/check-ghcr-images.sh                # default images + 'latest'
#   ODOO_TAG=sha-abc IMAGE_TAGS_FRONTEND=sha-def bash scripts/check-ghcr-images.sh
#
# Env config:
#   ODOO_TAG               Tag for grove-odoo (default: latest)
#   FRONTEND_TAG           Tag for the 4 grove-* frontends (default: latest)
#   EXTRA_IMAGES           Space-separated list of additional <image>:<tag> to check
#   GHCR_OWNER             Owner namespace (default: goldberry-playground)
#
# Exit codes:
#   0  All images publicly pullable
#   1  At least one image not anonymously accessible (private, missing tag, or owner typo)
#   2  No images to check (config error)

set -euo pipefail

GHCR_OWNER="${GHCR_OWNER:-goldberry-playground}"
ODOO_TAG="${ODOO_TAG:-latest}"
FRONTEND_TAG="${FRONTEND_TAG:-latest}"

# Canonical Grove image list — kept in sync with infra/terraform/environments/qa/compose/docker-compose.qa.yml
declare -a IMAGES=(
  "grove-odoo:${ODOO_TAG}"
  "grove-caddy:${CADDY_TAG:-latest}"
  "grove-hub:${FRONTEND_TAG}"
  "grove-goldberry:${FRONTEND_TAG}"
  "grove-ggg:${FRONTEND_TAG}"
  "grove-nursery:${FRONTEND_TAG}"
)

# Allow ad-hoc additions, e.g. for testing a new image before adding to the canonical list
if [ -n "${EXTRA_IMAGES:-}" ]; then
  for img in $EXTRA_IMAGES; do IMAGES+=("$img"); done
fi

if [ "${#IMAGES[@]}" -eq 0 ]; then
  echo "ERROR: no images to check" >&2
  exit 2
fi

fail=0
echo "── GHCR pullability check (owner: ${GHCR_OWNER}) ──"
for entry in "${IMAGES[@]}"; do
  name="${entry%:*}"
  tag="${entry##*:}"
  # GHCR uses the OCI distribution-spec manifest endpoint. Anonymous access
  # works for public packages. For private, we'd get 403; for missing tag, 404.
  url="https://ghcr.io/v2/${GHCR_OWNER}/${name}/manifests/${tag}"
  code=$(curl -s -o /dev/null -w '%{http_code}' \
    -H "Accept: application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json" \
    --max-time 10 "$url" || echo "000")
  case "$code" in
    200)         echo "  ✓ ${name}:${tag}  (HTTP 200, public)" ;;
    401)         echo "  ✓ ${name}:${tag}  (HTTP 401, exists — server requested auth, treated as accessible)" ;;
    403)         echo "  ✗ ${name}:${tag}  (HTTP 403, PRIVATE — make the package public in GHCR or wire docker login)"; fail=1 ;;
    404)         echo "  ✗ ${name}:${tag}  (HTTP 404, tag/package not found — check owner '${GHCR_OWNER}' and tag '${tag}')"; fail=1 ;;
    000)         echo "  ✗ ${name}:${tag}  (HTTP 000, connection failed)"; fail=1 ;;
    *)           echo "  ? ${name}:${tag}  (HTTP $code, unexpected)"; fail=1 ;;
  esac
done

if [ "$fail" -ne 0 ]; then
  echo
  echo "ERROR: one or more images not anonymously pullable. The QA droplet's cloud-init" >&2
  echo "will fail at \`docker compose pull\` and the grove-ready sentinel will never fire." >&2
  echo "Fix the package visibility in GHCR before re-dispatching qa-deploy." >&2
  echo "Org admin UI: https://github.com/orgs/${GHCR_OWNER}/packages" >&2
  exit 1
fi

echo
echo "✓ all ${#IMAGES[@]} images pullable — cloud-init's docker compose pull will succeed"
