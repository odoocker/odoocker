#!/usr/bin/env bash
# infisical-set-quiet.sh — Set an Infisical secret without echoing its value.
#
# The infisical CLI's `secrets set` command prints a confirmation table that
# INCLUDES THE RAW VALUE in plaintext (verified CLI v0.43.97, 2026-06-24).
# That's a token-leak waiting to happen in any context where stdout is
# captured: CI logs, terminal scrollback, screen recordings, AI assistants.
#
# This wrapper redirects the CLI's chatty output and confirms success via a
# separate read call (length comparison — never reveals the value itself).
#
# Usage:
#   bash scripts/infisical-set-quiet.sh NAME VALUE [--projectId ...] [--env ...]
#
# Required args (positional):
#   NAME            Secret name (e.g. DIGITALOCEAN_TOKEN_TEARDOWN)
#   VALUE           Secret value (pass via $(op read ...) or another secure source)
#
# Required env (or pass as --projectId / --env after positional args):
#   INFISICAL_PROJECT_ID    UUID of the Infisical project
#   INFISICAL_ENV           Env slug (dev, staging, prod)
#
# Exit codes:
#   0  Secret set; readback confirmed value length matches what was sent
#   1  Args/env missing
#   2  Set call failed
#   3  Set appeared to succeed but readback returned a different length (suspicious)

set -euo pipefail

NAME="${1:-}"
VALUE="${2:-}"
shift 2 || true

if [ -z "$NAME" ] || [ -z "$VALUE" ]; then
  echo "Usage: $0 NAME VALUE [--projectId UUID] [--env SLUG]" >&2
  echo "  Or: INFISICAL_PROJECT_ID=... INFISICAL_ENV=... $0 NAME VALUE" >&2
  exit 1
fi

# Parse trailing --projectId / --env from args; otherwise from env
PROJECT_ID="${INFISICAL_PROJECT_ID:-}"
ENV_SLUG="${INFISICAL_ENV:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    # Audit fix SC2015 (2026-06-29): `A && B || C` is not if-then-else.
    # If B (the assignment) ever produced a non-zero exit, C would also run.
    # In practice assignments don't fail, but the pattern is a known footgun;
    # explicit if/else is unambiguous.
    --projectId|--projectId=*)
      if [[ "$1" == *=* ]]; then PROJECT_ID="${1#*=}"; else shift; PROJECT_ID="$1"; fi ;;
    --env|--env=*)
      if [[ "$1" == *=* ]]; then ENV_SLUG="${1#*=}"; else shift; ENV_SLUG="$1"; fi ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
  shift
done

if [ -z "$PROJECT_ID" ] || [ -z "$ENV_SLUG" ]; then
  echo "ERROR: --projectId and --env required (or INFISICAL_PROJECT_ID / INFISICAL_ENV)" >&2
  exit 1
fi

expected_len=${#VALUE}
echo "→ Setting $NAME (len=$expected_len) in project=$PROJECT_ID env=$ENV_SLUG"

# Set silently. Note: we don't capture or print the CLI's output ever — even
# its error messages on stderr could echo back the value if the CLI ever
# decides to be "helpful" about what failed.
if ! infisical secrets set "$NAME=$VALUE" --projectId="$PROJECT_ID" --env="$ENV_SLUG" >/dev/null 2>&1; then
  echo "ERROR: infisical secrets set returned non-zero. Re-run manually for debug output," >&2
  echo "but BE AWARE the CLI will echo the value if you do." >&2
  exit 2
fi

# Verify via readback (length only — never print the actual value)
actual_len=$(infisical secrets get "$NAME" --projectId="$PROJECT_ID" --env="$ENV_SLUG" --plain --silent 2>/dev/null | wc -c | tr -d ' ')
# Subtract trailing newline that `infisical secrets get` adds
actual_len=$((actual_len - 1))

if [ "$actual_len" -ne "$expected_len" ]; then
  echo "WARN: readback length ($actual_len) != sent length ($expected_len) — verify manually" >&2
  exit 3
fi

echo "✓ Set + readback-verified ($expected_len bytes)"
