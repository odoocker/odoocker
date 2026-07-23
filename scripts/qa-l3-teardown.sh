#!/usr/bin/env bash
# Teardown for the Level 3 QA environment (infra/terraform/environments/
# qa-app-platform). The monolith's qa-teardown workflow died with the
# monolith -- this is its L3 successor, run LOCALLY (destroys are not CI
# material: the drift workflow's token deliberately can't delete).
#
# Two modes:
#   compute  - destroy the spend, keep the data + DNS:
#              4 App Platform apps + 2 droplets + volume attachment.
#              Managed PG (all Odoo data), the caddy-data volume (LE
#              certs -- rate-limit protection, see ADR-005), the DNS
#              zone, and firewalls all survive. Re-create with
#              `make qa-l3-up`; the droplets re-bootstrap unattended
#              from cloud-init and Odoo reconnects to the surviving DB.
#   all      - terraform destroy of EVERYTHING, including Managed PG
#              (IRREVERSIBLE data loss), the LE cert volume (next
#              deploy re-issues against the LE rate limit budget), the
#              qa DNS zone, and the Cloudflare NS delegation records.
#
# Usage:
#   bash scripts/qa-l3-teardown.sh compute
#   bash scripts/qa-l3-teardown.sh all
#
# Requirements:
#   - op CLI signed in (1Password: Infisical machine identity)
#   - Infisical holds SPACES_* (state backend), DIGITALOCEAN_TOKEN,
#     CLOUDFLARE_API_TOKEN, GROVE_REVALIDATE_SECRET, ODOO_API_KEYS_TF_JSON
#
# Known footguns (learned the hard way, 2026-06/07):
#   - The DO provider has an internal ~1m delete timeout that `timeouts`
#     blocks canNOT override. If a droplet delete trips it, terraform
#     errors but state stays consistent -- just re-run this script; the
#     second pass finds the droplet gone and continues.
#   - DO PATs can have silent scope gaps: a token that creates+reads
#     fine may 403 on destroy for firewalls/domains/volumes. If `all`
#     mode 403s, mint a full-scope token and re-run with
#     DIGITALOCEAN_TOKEN_OVERRIDE=<token> (never paste tokens into logs).
set -euo pipefail

MODE="${1:-}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$REPO_ROOT/infra/terraform/environments/qa-app-platform"
INFISICAL_PROJECT_ID="850603f8-e175-4c38-9038-97a1e69d72e6"
OP_INFRA_ITEM="qvkpvg24x2wbsn6owjyvn4vhx4"   # GoldberryGrove Infra

case "$MODE" in
  compute|all) ;;
  *) echo "usage: $0 {compute|all}"; exit 2 ;;
esac

if [ "$MODE" = "all" ]; then
  echo "!! 'all' destroys Managed PG (ALL Odoo data), the LE cert volume,"
  echo "!! the qa DNS zone, and the Cloudflare NS delegation."
else
  echo "'compute' destroys 14 resources: 4 App Platform apps, 2 droplets,"
  echo "volume attachment, plus their DEPENDENTS terraform pulls in via"
  echo "-target: droplet firewalls, the odoo/oo/keep/apex DNS records, and"
  echo "the PG trusted-sources firewall (verified via plan -destroy 2026-07-05)."
  echo "Survives: Managed PG cluster+data, the LE-cert volume, the qa DNS"
  echo "zone + CF delegation. NOTE: with the PG firewall destroyed the DB"
  echo "endpoint is password-only until rebuild. Rebuild: make qa-l3-up"
fi
printf "Type 'destroy-qa-l3-%s' to continue: " "$MODE"
read -r CONFIRM
[ "$CONFIRM" = "destroy-qa-l3-$MODE" ] || { echo "aborted"; exit 1; }

echo "==> Authenticating (1Password -> Infisical machine identity)..."
INF_TOKEN="$(infisical login --method=universal-auth \
  --client-id="$(op item get "$OP_INFRA_ITEM" --fields label=infisical_admin_client_id --reveal)" \
  --client-secret="$(op item get "$OP_INFRA_ITEM" --fields label=infisical_admin_client_secret --reveal)" \
  --plain)"

TARGETS=""
if [ "$MODE" = "compute" ]; then
  # -target on the bare for_each address (digitalocean_app.tenant)
  # covers all its instances.
  TARGETS="-target=digitalocean_app.hub -target=digitalocean_app.tenant -target=digitalocean_volume_attachment.caddy_data -target=digitalocean_droplet.odoo -target=digitalocean_droplet.obs"
fi

echo "==> terraform destroy ($MODE)..."
infisical run --projectId="$INFISICAL_PROJECT_ID" --env=prod --token="$INF_TOKEN" -- bash -c '
  set -euo pipefail
  export AWS_ACCESS_KEY_ID="$SPACES_ACCESS_KEY_ID"
  export AWS_SECRET_ACCESS_KEY="$SPACES_SECRET_ACCESS_KEY"
  # Full-scope override for `all` mode when the standard token 403s on
  # firewall/domain/volume deletes (silent DO PAT scope gaps).
  export TF_VAR_do_token="${DIGITALOCEAN_TOKEN_OVERRIDE:-$DIGITALOCEAN_TOKEN}"
  export TF_VAR_cloudflare_api_token="$CLOUDFLARE_API_TOKEN"
  export TF_VAR_grove_revalidate_secret="$GROVE_REVALIDATE_SECRET"
  export TF_VAR_odoo_api_keys="$ODOO_API_KEYS_TF_JSON"
  # -auto-approve is safe here: this script already required the typed
  # destroy-qa-l3-<mode> confirmation above.
  terraform -chdir="'"$TF_DIR"'" destroy '"$TARGETS"' -input=false -auto-approve
'

echo "==> Post-destroy state summary:"
infisical run --projectId="$INFISICAL_PROJECT_ID" --env=prod --token="$INF_TOKEN" -- bash -c '
  export AWS_ACCESS_KEY_ID="$SPACES_ACCESS_KEY_ID"
  export AWS_SECRET_ACCESS_KEY="$SPACES_SECRET_ACCESS_KEY"
  terraform -chdir="'"$TF_DIR"'" state list || true
'
echo "Done. Rebuild any time with: make qa-l3-up"
