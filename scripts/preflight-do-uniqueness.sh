#!/usr/bin/env bash
# Pre-flight probe against the DO API for resource-uniqueness conflicts.
#
# DO's API enforces uniqueness on some resource identities in ways that
# aren't obvious from TF code:
#
#   1. SSH keys: uniqueness is on public-key FINGERPRINT, not name. Two
#      resources with different names but the same content = 422 conflict.
#      Caught us on the 2026-06-30 Level 3 first apply -- the L3 env tried
#      to add `grove-qa-l3-deploy` with the same public key content the
#      monolith had already uploaded as `grove-qa-deploy`. Fix: data source.
#
#   2. Droplets: name isn't unique globally, but tag+name pairs create
#      confusing orphans. If a previous partial apply left an orphan, the
#      next apply doesn't detect it and creates a duplicate.
#
#   3. Domains: create is idempotent (returns 200 whether or not the zone
#      exists), so no conflict class here. Not worth checking.
#
# This script probes for the classes we've actually been bitten by. Adds
# no new state, just SURFACES problems at plan time with actionable errors.
#
# Usage:
#   scripts/preflight-do-uniqueness.sh <tf_dir>
#
# Env required:
#   DO_TOKEN or DIGITALOCEAN_TOKEN   for the DO API queries
#
# Exit codes:
#   0  no conflicts detected
#   1  conflict detected (message identifies what + how to fix)
#   2  bad args, missing token, or DO API unreachable
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <tf_dir>" >&2
  exit 2
fi

tf_dir="$1"
if [ ! -d "$tf_dir" ]; then
  echo "::error::tf_dir does not exist: $tf_dir" >&2
  exit 2
fi

# Accept either name (workflows use different conventions)
DO_TOKEN="${DO_TOKEN:-${DIGITALOCEAN_TOKEN:-${TF_VAR_do_token:-}}}"
if [ -z "$DO_TOKEN" ]; then
  echo "::error::No DO API token in env (checked DO_TOKEN, DIGITALOCEAN_TOKEN, TF_VAR_do_token)" >&2
  exit 2
fi

# ── (1) SSH key fingerprint conflict ─────────────────────────────────────────
# Extract every ssh-key public_key value from the TF code. For each, compute
# its fingerprint locally (via ssh-keygen -lf on the pubkey blob), then check
# DO for any existing SSH key with that same fingerprint under a DIFFERENT
# name. If a match is found, that's the 422-duplicate class -- refactor the
# resource block to a data source before apply.

grep_pubkeys() {
  # Extract the public_key value from every `resource "digitalocean_ssh_key" ... { ... public_key = "ssh-... }` block
  # jq-friendly grep: return "resource_name<TAB>pubkey" lines
  perl -ne 'BEGIN{$/=undef}
    while (/resource\s+"digitalocean_ssh_key"\s+"([^"]+)"\s*\{[^}]*?public_key\s*=\s*(?:var\.\S+|"([^"]+)")/gs) {
      my ($name, $key) = ($1, $2);
      # If key came from var (no literal), skip -- we can only check literals
      next unless $key;
      print "$name\t$key\n";
    }' "$tf_dir"/*.tf 2>/dev/null || true
}

conflicts=0
while IFS=$'\t' read -r tf_name pubkey; do
  [ -z "$tf_name" ] && continue
  # Compute local fingerprint of the pubkey blob (md5 form, matches DO API)
  # ssh-keygen wants a file; feed via /dev/stdin
  local_fp=$(printf '%s' "$pubkey" | ssh-keygen -E md5 -lf /dev/stdin 2>/dev/null | awk '{print $2}' | sed 's/^MD5://')
  if [ -z "$local_fp" ]; then
    continue
  fi
  # Query DO for SSH keys and match fingerprint
  match=$(curl -sf -H "Authorization: Bearer $DO_TOKEN" \
    "https://api.digitalocean.com/v2/account/keys?per_page=100" 2>/dev/null \
    | jq -r --arg fp "$local_fp" --arg tfname "$tf_name" \
        '.ssh_keys[] | select(.fingerprint == $fp) | select(.name != $tfname) | .name' \
    | head -1)
  if [ -n "$match" ]; then
    echo "::error::SSH key CONFLICT: TF resource digitalocean_ssh_key.$tf_name has the same public key content as existing DO key '$match'."
    echo "  DO API rejects duplicate key content with 422. Refactor the TF resource"
    echo "  to a data source referencing '$match':"
    echo ""
    echo "    data \"digitalocean_ssh_key\" \"$tf_name\" {"
    echo "      name = \"$match\""
    echo "    }"
    echo ""
    echo "  Then update every 'digitalocean_ssh_key.${tf_name}.fingerprint' reference"
    echo "  to 'data.digitalocean_ssh_key.${tf_name}.fingerprint'."
    conflicts=$((conflicts + 1))
  fi
done < <(grep_pubkeys)

# ── (2) Orphan droplet with target name ──────────────────────────────────────
# Extract droplet names from the TF. Query DO for droplets matching those
# names. Warn if a matching droplet exists AND its ID isn't in TF state --
# means an orphan from a previous partial apply.
#
# Note: this DOESN'T fail the run (droplets are cheap to reconcile via
# terraform import or destroy-and-recreate), just warns.
droplet_names=$(perl -ne 'BEGIN{$/=undef}
  while (/resource\s+"digitalocean_droplet"[^{]+\{[^}]*?name\s*=\s*"([^"]+)"/gs) {
    print "$1\n";
  }' "$tf_dir"/*.tf 2>/dev/null || true)

for dname in $droplet_names; do
  existing=$(curl -sf -H "Authorization: Bearer $DO_TOKEN" \
    "https://api.digitalocean.com/v2/droplets?per_page=200" 2>/dev/null \
    | jq -r --arg n "$dname" '.droplets[] | select(.name == $n) | .id' | head -1)
  if [ -n "$existing" ]; then
    # Check TF state; if the droplet is already tracked, no orphan
    in_state=$(cd "$tf_dir" && terraform state list 2>/dev/null | grep -c "digitalocean_droplet\." || true)
    if [ "${in_state:-0}" -eq 0 ]; then
      echo "::warning::Droplet named '$dname' (id=$existing) exists in DO but no droplet in TF state."
      echo "  Likely orphan from a partial apply. Options:"
      echo "    - 'doctl compute droplet delete $existing' + re-apply"
      echo "    - 'terraform import digitalocean_droplet.<name> $existing' + re-apply"
    fi
  fi
done

if [ "$conflicts" -gt 0 ]; then
  echo "::error::$conflicts uniqueness conflict(s) detected. Address the messages above before apply."
  exit 1
fi

echo "  ✓ DO uniqueness preflight passed"
