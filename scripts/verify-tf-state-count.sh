#!/usr/bin/env bash
# Assert that `terraform state list` returns at least the expected number
# of resources. Catches the class of failure where `terraform apply` reports
# exit 0 but only SOME of the planned resources actually landed in state.
#
# Real incident: 2026-06-30 Level 3 first apply.
#   - Reported "Apply complete! Resources: 19 added"
#   - Exit code 0
#   - `terraform state list | wc -l` -> 10 (nine resources missing)
#   - First failure was digitalocean_ssh_key (422 duplicate content)
#   - Downstream resources (droplets, DNS, firewalls) never ran
#   - No signal until DNS + URLs failed 12 hours later
#
# Root cause: TF's parallel-apply + partial-success state save + exit
# code that doesn't reflect mid-apply failures.
#
# This script closes the visibility gap: after every apply, run the count
# assertion. If mismatched, dump the current state list AND fail the job so
# the operator sees the partial-apply immediately instead of hunting for it.
#
# Usage:
#   scripts/verify-tf-state-count.sh <tf_dir> <expected_min>
#
# Example (called from qa-deploy.yml after terraform apply):
#   scripts/verify-tf-state-count.sh infra/terraform/environments/qa 8
#
# Exit codes:
#   0  state count >= expected_min
#   1  state count < expected_min (partial-apply detected)
#   2  bad args or state list failed
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <tf_dir> <expected_min>" >&2
  echo "  tf_dir       Terraform working directory (e.g. infra/terraform/environments/qa)" >&2
  echo "  expected_min Minimum resource count (typed as integer)" >&2
  exit 2
fi

tf_dir="$1"
expected_min="$2"

if ! [[ "$expected_min" =~ ^[0-9]+$ ]]; then
  echo "::error::expected_min must be a non-negative integer; got: $expected_min" >&2
  exit 2
fi

if [ ! -d "$tf_dir" ]; then
  echo "::error::tf_dir does not exist: $tf_dir" >&2
  exit 2
fi

# Run state list in the TF dir. Requires TF to be already-initialized (which
# it will be after `terraform apply` -- init is a prerequisite of apply).
actual=$(cd "$tf_dir" && terraform state list 2>/dev/null | wc -l | tr -d ' ')

if [ -z "$actual" ]; then
  echo "::error::terraform state list returned empty output in $tf_dir." >&2
  echo "  Was terraform init + apply run first? Is state locked?" >&2
  exit 2
fi

echo "  TF state resource count: $actual (expected >= $expected_min)"

if [ "$actual" -lt "$expected_min" ]; then
  echo "::error::TF state has $actual resources, expected at least $expected_min."
  echo "  This suggests a PARTIAL APPLY -- terraform apply reported success but"
  echo "  some resources never made it into state. Likely causes:"
  echo "    - Provider API returned 4xx on a resource, TF continued past it,"
  echo "      and exit code didn't reflect the mid-apply failure"
  echo "    - State save failed mid-write (network / backend issue)"
  echo "    - Concurrent apply overwrote state (rare, needs stale lock)"
  echo ""
  echo "  Current state resources:"
  (cd "$tf_dir" && terraform state list 2>/dev/null | sed 's/^/    /') || true
  echo ""
  echo "  Recovery: re-run 'terraform plan' + inspect for 'will be created'"
  echo "  entries. If any pre-flight uniqueness check applies (e.g.,"
  echo "  scripts/preflight-do-uniqueness.sh), re-run that too."
  exit 1
fi

echo "  ✓ state count assertion passed"
