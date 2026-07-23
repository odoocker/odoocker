#!/usr/bin/env bash
# qa-status.sh — Single-command inventory of the Grove QA env in DigitalOcean
# plus an HTTP probe of the public URLs.
#
# Replaces the 6+ ad-hoc curl invocations that bit us during the 2026-06-24
# QA bring-up. Run this when you suspect drift between TF state and reality,
# or when "is QA actually up?" needs a fast answer.
#
# Usage:
#   bash scripts/qa-status.sh              # uses DIGITALOCEAN_TOKEN from env
#   make qa-status                         # wraps via `op run --env-file=...`
#
# Required env:
#   DIGITALOCEAN_TOKEN  Read-scoped DO token (the existing GoldberryGrove
#                       Infra/do_token works — only reads, no writes).
#
# Optional env:
#   QA_ZONE             Override the QA zone (default: qa.gatheringatthegrove.com)
#   TENANT_SUBDOMAINS   Space-separated list (default: goldberry ggg nursery odoo)
#   PROBE_TIMEOUT       curl --max-time per URL (default: 5)
#   COLOR               Set to 'never' to disable ANSI output
#
# Exit codes:
#   0  Inventory printed successfully (no opinion on health — read the output)
#   1  DIGITALOCEAN_TOKEN missing or API auth failed
#
# Output is human-readable + ANSI colored. Pipe through `tee` if you want a
# log of the snapshot.

set -euo pipefail

QA_ZONE="${QA_ZONE:-qa.gatheringatthegrove.com}"
TENANT_SUBDOMAINS="${TENANT_SUBDOMAINS:-goldberry ggg nursery odoo}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-10}"  # bumped from 5 -- some tenants serve in 7-9s on cold cache

if [ -z "${DIGITALOCEAN_TOKEN:-}" ]; then
  echo "ERROR: DIGITALOCEAN_TOKEN not set. Run via:" >&2
  echo "  op run --env-file=infra/terraform/environments/qa/.env.op -- bash scripts/qa-status.sh" >&2
  echo "or:" >&2
  echo "  make qa-status" >&2
  exit 1
fi

# Color helpers
if [ "${COLOR:-auto}" = "never" ] || [ ! -t 1 ]; then
  GREEN=""; YELLOW=""; RED=""; BOLD=""; DIM=""; NC=""
else
  GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"
  BOLD="\033[1m"; DIM="\033[2m"; NC="\033[0m"
fi

do_api() {
  curl -sf -H "Authorization: Bearer $DIGITALOCEAN_TOKEN" "https://api.digitalocean.com/v2/$1" 2>/dev/null
}

# Verify token works at all
if ! do_api 'account' >/dev/null; then
  echo -e "${RED}ERROR: DO API auth failed (token revoked, expired, or wrong scope)${NC}" >&2
  exit 1
fi

echo -e "${BOLD}── Grove QA env — DigitalOcean inventory ──${NC}"
echo -e "${DIM}$(date '+%Y-%m-%d %H:%M:%S %Z')${NC}"
echo

echo -e "${BOLD}Droplets (tag: env-qa)${NC}"
droplets=$(do_api 'droplets?tag_name=env-qa')
count=$(echo "$droplets" | jq '.droplets | length')
if [ "$count" -eq 0 ]; then
  echo -e "  ${YELLOW}(none)${NC}"
else
  echo "$droplets" | jq -r '.droplets[] | "  • \(.name)  id=\(.id)  status=\(.status)  ip=\(.networks.v4[0].ip_address // "(no public ip)")  created=\(.created_at)"'
fi
echo

echo -e "${BOLD}Domains (matching gatheringatthegrove)${NC}"
domains=$(do_api 'domains?per_page=200' | jq '[.domains[] | select(.name | test("gatheringatthegrove"))]')
count=$(echo "$domains" | jq 'length')
if [ "$count" -eq 0 ]; then
  echo -e "  ${YELLOW}(none)${NC}"
else
  echo "$domains" | jq -r '.[] | "  • \(.name)  ttl=\(.ttl)"'
fi
echo

echo -e "${BOLD}SSH keys (matching grove-qa)${NC}"
keys=$(do_api 'account/keys?per_page=200' | jq '[.ssh_keys[] | select(.name | test("grove-qa"))]')
count=$(echo "$keys" | jq 'length')
if [ "$count" -eq 0 ]; then
  echo -e "  ${YELLOW}(none)${NC}"
else
  echo "$keys" | jq -r '.[] | "  • \(.name)  id=\(.id)  fp=\(.fingerprint)"'
fi
echo

echo -e "${BOLD}Firewalls (matching grove-qa)${NC}"
fws=$(do_api 'firewalls?per_page=200' | jq '[.firewalls[] | select(.name | test("grove-qa"))]')
count=$(echo "$fws" | jq 'length')
if [ "$count" -eq 0 ]; then
  echo -e "  ${YELLOW}(none)${NC}"
else
  echo "$fws" | jq -r '.[] | "  • \(.name)  id=\(.id)  droplets=\(.droplet_ids | length)"'
fi
echo

echo -e "${BOLD}URL health probe${NC}"
# Audit fix SC2116 (2026-06-29): drop the useless $(echo ...) wrapper.
# shellcheck disable=SC2086  # intentional word-splitting on TENANT_SUBDOMAINS
for sub in "" $TENANT_SUBDOMAINS; do
  if [ -z "$sub" ]; then
    host="$QA_ZONE"
    label="hub"
  else
    host="${sub}.${QA_ZONE}"
    label="$sub"
  fi
  # Bump default timeout to 10s and use a fallback that doesn't append the
  # "000" twice. Previously: `... || echo "000"` after `-w '%{http_code}'`
  # produced "000000" when curl wrote 000 on timeout then the || added another.
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time "$PROBE_TIMEOUT" "https://$host/" 2>/dev/null)
  [ -z "$code" ] && code="000"
  case "$code" in
    2*|3*) col="$GREEN"; sym="✓" ;;
    000)   col="$RED";   sym="✗ (connection failed / timeout)" ;;
    *)     col="$YELLOW"; sym="?" ;;
  esac
  printf "  ${col}%-1s${NC} %-12s  %-50s  HTTP %s\n" "$sym" "$label" "https://$host/" "$code"
done
echo

echo -e "${DIM}Tip: run \`make qa-output\` to see what TF thinks vs. the above.${NC}"
