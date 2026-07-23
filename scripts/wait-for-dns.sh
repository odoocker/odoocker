#!/usr/bin/env bash
# Poll public DNS resolvers until the given hostnames resolve to A records.
# Fails the job if records don't propagate within the timeout.
#
# Why not trust `terraform apply` exit 0: the 2026-06-30 apply reported
# 19 resources created, but the 4 DNS records never actually landed in
# DO's zone (SOA serial stayed at 0). TF's DO provider ack'd the API
# calls but records weren't persisted. This wasn't detectable until URLs
# failed 12+ hours later.
#
# This script closes that gap: after apply, actively verify the world's
# public resolvers can see the records. If DO's zone silently didn't
# accept the record, this fails within the timeout window instead of at
# grove-ready-sentinel time 20 minutes later.
#
# Uses 3 independent public resolvers to avoid single-source dependency:
#   8.8.8.8   Google DNS
#   1.1.1.1   Cloudflare DNS
#   9.9.9.9   Quad9
# A hostname is considered propagated when ANY resolver returns a non-empty
# A record answer (not all 3 -- propagation is uneven and we don't need
# consensus to prove the record exists).
#
# Usage:
#   scripts/wait-for-dns.sh <timeout_seconds> <host> [<host>...]
#
# Example:
#   scripts/wait-for-dns.sh 180 hub.qa.gatheringatthegrove.com odoo.qa.gatheringatthegrove.com
#
# Exit codes:
#   0  all hosts resolved within timeout
#   1  one or more hosts didn't resolve
#   2  bad args or dig missing
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "Usage: $0 <timeout_seconds> <host> [<host>...]" >&2
  exit 2
fi

timeout="$1"
shift
if ! [[ "$timeout" =~ ^[0-9]+$ ]]; then
  echo "::error::timeout must be integer seconds; got: $timeout" >&2
  exit 2
fi

if ! command -v dig >/dev/null 2>&1; then
  echo "::error::dig not found. Install dnsutils / bind-utils." >&2
  exit 2
fi

resolvers=(8.8.8.8 1.1.1.1 9.9.9.9)
hosts=("$@")

echo "  Waiting up to ${timeout}s for ${#hosts[@]} hostname(s) to resolve..."
echo "  Resolvers: ${resolvers[*]}"

start=$(date +%s)
deadline=$(( start + timeout ))
declare -A resolved=()   # host -> "1" once seen

while [ "$(date +%s)" -lt "$deadline" ]; do
  all_ok=1
  for h in "${hosts[@]}"; do
    [ -n "${resolved[$h]:-}" ] && continue
    for r in "${resolvers[@]}"; do
      ans=$(dig +short +time=2 +tries=1 A "$h" "@$r" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
      if [ -n "$ans" ]; then
        resolved[$h]="$ans"
        echo "  ✓ $h -> $ans (via $r)"
        break
      fi
    done
    if [ -z "${resolved[$h]:-}" ]; then
      all_ok=0
    fi
  done
  if [ "$all_ok" = "1" ]; then
    echo "  ✓ all ${#hosts[@]} hostname(s) propagated in $(( $(date +%s) - start ))s"
    exit 0
  fi
  sleep 5
done

echo "::error::DNS propagation timed out after ${timeout}s."
echo "  Unresolved hostnames:"
for h in "${hosts[@]}"; do
  if [ -z "${resolved[$h]:-}" ]; then
    echo "    - $h"
  fi
done
echo ""
echo "  Likely causes:"
echo "    - Records never actually persisted in DO despite TF apply exit 0"
echo "      (verify via 'doctl compute domain records list <zone>' or DO UI)"
echo "    - NS delegation misconfigured (records exist but nameservers"
echo "      not authoritative from public-resolver perspective)"
echo "    - Propagation legitimately slow (2min is aggressive; if the zone"
echo "      is minutes old, retry once)"
exit 1
