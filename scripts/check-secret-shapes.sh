#!/usr/bin/env bash
# Post-Infisical-fetch assertion: verify every fetched secret has the
# expected byte-shape without ever printing the value.
#
# Why: Infisical secrets can silently return empty strings on auth glitches,
# get mangled by GH Actions' secret-scrubber (trailing newline strip), or
# be misconfigured in the source vault (e.g., an operator pasted the URL
# with the http:// scheme missing). Each of these manifests DOWNSTREAM as
# a confusing error -- 401 from DO, malformed SSH key, curl 000 to Discord.
#
# This script fails at fetch time with a specific message about which
# secret is wrong and why. All output is length + first-byte + boolean
# checks -- no secret material.
#
# Extends the pattern PR #135 introduced for GROVE_QA_CI_SSH_PRIVATE_KEY.
#
# Usage:
#   scripts/check-secret-shapes.sh
#
# Env checked (all optional; skipped if unset):
#   DIGITALOCEAN_TOKEN         DO PAT (73 bytes: "dop_v1_<64-hex>")
#   DIGITALOCEAN_TOKEN_TEARDOWN same
#   CLOUDFLARE_API_TOKEN       CF token: legacy 40-char alphanumeric OR
#                              modern prefixed format like cfut_<...> (~53 chars)
#   DISCORD_OPS_WEBHOOK_URL    https://discord.com/api/webhooks/<id>/<token>
#   GROVE_QA_CI_SSH_PRIVATE_KEY  PEM starting with the standard OpenSSH PEM header
#   SPACES_ACCESS_KEY_ID       20-char DO Spaces key
#   SPACES_SECRET_ACCESS_KEY   43-char DO Spaces secret
#
# Exit codes:
#   0  all present secrets have expected shape (missing ones are skipped)
#   1  one or more secrets failed a shape check
set -euo pipefail

failures=0

# Helper: probe a var without echoing its content
probe() {
  local name="$1"
  local val="${!name:-}"
  local expected_min_len="$2"
  local expected_max_len="$3"
  local expected_prefix="${4:-}"   # optional prefix; empty = no check

  if [ -z "$val" ]; then
    echo "  - $name: (not set, skipping)"
    return 0
  fi

  local len=${#val}
  local prefix_shape
  prefix_shape=$(printf '%s' "$val" | head -c 20 | sed 's/[a-zA-Z0-9]/X/g')

  # Length check
  if [ "$len" -lt "$expected_min_len" ] || [ "$len" -gt "$expected_max_len" ]; then
    echo "::error::$name has bad length: got ${len} bytes, expected ${expected_min_len}-${expected_max_len}"
    echo "    first_20_shape (chars masked as X, punctuation kept) = '$prefix_shape'"
    failures=$((failures + 1))
    return 1
  fi

  # Prefix check (literal string match on first N chars)
  if [ -n "$expected_prefix" ]; then
    local actual_prefix
    actual_prefix=$(printf '%s' "$val" | head -c ${#expected_prefix})
    if [ "$actual_prefix" != "$expected_prefix" ]; then
      # Show what prefix WE got, masked so no material leaks
      local got_prefix_shape
      got_prefix_shape=$(printf '%s' "$actual_prefix" | sed 's/[a-zA-Z0-9]/X/g')
      echo "::error::$name has wrong prefix: expected '${expected_prefix}', got shape '${got_prefix_shape}'"
      echo "    length=${len} bytes (within expected range)"
      failures=$((failures + 1))
      return 1
    fi
  fi

  echo "  ✓ $name: length=${len}${expected_prefix:+, prefix=OK}"
}

echo "== Secret shape probes =="

# DO tokens: "dop_v1_" + 64 hex chars = 71 chars total. Historically 73 with
# older format; accept range 60-90 to cover both.
probe DIGITALOCEAN_TOKEN 60 90 "dop_"
probe DIGITALOCEAN_TOKEN_TEARDOWN 60 90 "dop_"

# Cloudflare API tokens: two shapes coexist in the wild.
#   - Legacy: 40 pure ASCII alphanumeric chars
#   - Modern: prefixed like cfut_<...> at ~53 chars (User API Token page in
#     dashboard hands these out post-2025)
# Range 35-70 accepts both without becoming so loose it lets a webhook URL
# (120+ chars) or a PEM key (400+) sneak through. If CF ever ships a wider
# format, widen this to match — do NOT drop the upper bound, it's what
# catches wrong-value-pasted mistakes.
probe CLOUDFLARE_API_TOKEN 35 70

# Discord webhook URL: https://discord.com/api/webhooks/<id_18-20_digits>/<token_68_chars>
# Total length ~120 chars.
probe DISCORD_OPS_WEBHOOK_URL 100 140 "https://discord.com/api/webhooks/"

# OpenSSH private key PEM: starts with the standard PEM header.
# Typical ed25519 key: ~400 bytes. RSA can be 1600+. Accept range.
# Literal PEM header extracted to a variable so gitleaks:allow can whitelist
# THIS specific benign string without leaving no-op annotation garbage in
# the probe call's shell argument.
OPENSSH_PEM_HEADER='-----BEGIN OPENSSH PRIVATE KEY-----' # gitleaks:allow
probe GROVE_QA_CI_SSH_PRIVATE_KEY 300 3000 "$OPENSSH_PEM_HEADER"

# DO Spaces credentials
probe SPACES_ACCESS_KEY_ID 18 22
probe SPACES_SECRET_ACCESS_KEY 40 50

echo ""
if [ "$failures" -gt 0 ]; then
  echo "::error::$failures secret(s) failed shape check. See lines above for what to fix."
  echo "  Common recovery: verify the source in Infisical vault matches the format expected,"
  echo "  re-fetch (some secrets have wrappers with trailing whitespace that strip on set),"
  echo "  or check for a race between the Infisical secrets-action step and this check."
  exit 1
fi

echo "  ✓ all present secrets passed shape check"
