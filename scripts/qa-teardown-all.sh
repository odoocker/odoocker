#!/usr/bin/env bash
# qa-teardown-all.sh -- Full QA env teardown via direct DO/Cloudflare APIs.
#
# The script-equivalent of `terraform destroy` on infra/terraform/environments/qa,
# but using direct API calls instead of TF. Why bypass TF here?
#
#   - The DO provider's hardcoded 1m destroy poll routinely times out on
#     droplet destroy when DO is slow (verified 2026-06-24)
#   - TF destroy requires the teardown token to have delete scope on EVERY
#     resource type in state (ssh_key, firewall too) -- the current teardown
#     token only has droplet+domain delete
#   - The teardown only needs to kill the EXPENSIVE resources (droplet) and
#     the dynamic ones (DNS records). SSH keys + firewall are safe to leave
#     orphaned -- the next deploy reuses them in-place.
#
# Used by:
#   - .github/workflows/qa-ttl-sweeper.yml (scheduled auto-destroy after TTL)
#   - .github/workflows/qa-teardown.yml (manual teardown via workflow_dispatch)
#   - `make qa-teardown-all` (operator local)
#
# Usage:
#   bash scripts/qa-teardown-all.sh
#   bash scripts/qa-teardown-all.sh --dry-run
#   bash scripts/qa-teardown-all.sh --keep-dns      # leave DO domain + records
#   bash scripts/qa-teardown-all.sh --with-cloudflare  # ALSO remove CF NS delegation
#
# Required env:
#   DIGITALOCEAN_TOKEN   Must have droplet:delete + domain:delete scopes
#
# Required env if --with-cloudflare:
#   CLOUDFLARE_API_TOKEN
#
# Exit codes:
#   0  All teardown steps succeeded
#   non-zero  See child script exit codes

set -euo pipefail

# Parse flags (pass through to children where applicable)
KEEP_DNS=0
WITH_CF=0
DRY_RUN=0
PASSTHROUGH=()
# Audit fix SC2034 (2026-06-29): WITH_CF is set for readability/audit-trail
# but only PASSTHROUGH is actually consumed downstream. Disable the warning
# rather than remove — the named bool documents intent at the call site.
# Directive lives here (before the `for`) because shellcheck rejects
# disable comments inside individual case branches (SC1124).
# shellcheck disable=SC2034
for arg in "$@"; do
  case "$arg" in
    --keep-dns)        KEEP_DNS=1 ;;
    --with-cloudflare) WITH_CF=1; PASSTHROUGH+=("--with-cloudflare") ;;
    --dry-run)         DRY_RUN=1; PASSTHROUGH+=("--dry-run") ;;
    *) echo "Unknown flag: $arg" >&2; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "== QA env full teardown =="
[ "$DRY_RUN" = "1" ] && echo "(DRY-RUN -- no resources will be destroyed)"
echo

# Step 1: Droplet(s)
DRY_FLAG=()
[ "$DRY_RUN" = "1" ] && DRY_FLAG=("--dry-run")
"$SCRIPT_DIR/qa-teardown-droplet.sh" "${DRY_FLAG[@]}"
echo

# Step 2: DNS (skipped if --keep-dns)
if [ "$KEEP_DNS" = "1" ]; then
  echo "-- skipping DNS teardown (--keep-dns) --"
else
  "$SCRIPT_DIR/qa-teardown-dns.sh" "${PASSTHROUGH[@]}"
fi
echo

echo "== teardown complete =="
echo "NOTE: SSH keys (grove-qa-admin, grove-qa-deploy) + firewall are intentionally"
echo "      left in place. They're idle without a droplet to attach to, and reusing"
echo "      them on the next qa-deploy is faster than recreating."
echo ""
echo "      Caddy's LE certs are NOT persisted across teardowns -- that's fine"
echo "      because Caddy uses DO DNS-01 wildcard (one cert covers apex + *.qa.*),"
echo "      well within LE's 50-certs-per-week-per-domain limit. The brief PR #81"
echo "      experiment with a persistent volume for Caddy /data was reverted in"
echo "      PR #82 once DNS-01 made it unnecessary."
