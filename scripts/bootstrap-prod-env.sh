#!/usr/bin/env bash
#
# Generate strong random values for the fields .env.example deliberately
# ships empty (ADMIN_PASSWD, DB_PASSWORD, AWS_ACCESS_KEY_ID,
# AWS_SECRET_ACCESS_KEY, REDIS_PASSWORD, PGADMIN_DEFAULT_PASSWORD) and
# splice them into the operator's `.env` in place.
#
# Designed to run ON THE PRODUCTION DROPLET — never on a developer
# machine or CI runner — so the generated secrets never traverse a
# different filesystem, registry, or session. Idempotent: refuses to
# overwrite a field that's already non-empty.
#
# Usage (from the odoocker repo root on the droplet):
#   cp .env.example .env
#   bash scripts/bootstrap-prod-env.sh .env
#
# Or to operate on the current dir's .env:
#   bash scripts/bootstrap-prod-env.sh

set -euo pipefail

ENV_FILE="${1:-.env}"

if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: $ENV_FILE does not exist. Run \`cp .env.example $ENV_FILE\` first." >&2
    exit 1
fi

# Fields that ship empty in .env.example AND must be set in production.
# Format: VAR_NAME:generator. Generators are bash command lines that
# produce one line of stdout — captured into the variable's value.
FIELDS=(
    "ADMIN_PASSWD:openssl rand -base64 32 | tr -d '/+=' | cut -c1-32"
    "DB_PASSWORD:openssl rand -base64 32 | tr -d '/+=' | cut -c1-32"
    "AWS_ACCESS_KEY_ID:openssl rand -hex 12"
    "AWS_SECRET_ACCESS_KEY:openssl rand -base64 48 | tr -d '/+=' | cut -c1-40"
    "REDIS_PASSWORD:openssl rand -base64 32 | tr -d '/+=' | cut -c1-32"
    "PGADMIN_DEFAULT_PASSWORD:openssl rand -base64 32 | tr -d '/+=' | cut -c1-32"
    "MINIO_ROOT_USER:openssl rand -hex 12"
    "MINIO_ROOT_PASSWORD:openssl rand -base64 48 | tr -d '/+=' | cut -c1-40"
)

filled=()
skipped=()

for entry in "${FIELDS[@]}"; do
    var="${entry%%:*}"
    generator="${entry#*:}"

    # Does the variable exist in .env?
    if ! grep -qE "^${var}=" "$ENV_FILE"; then
        echo "WARN: $var not present in $ENV_FILE — skipping." >&2
        skipped+=("$var (not in file)")
        continue
    fi

    # Is it already set?
    current=$(grep -E "^${var}=" "$ENV_FILE" | head -1 | cut -d= -f2-)
    if [ -n "$current" ]; then
        skipped+=("$var (already set)")
        continue
    fi

    # Generate and splice.
    value=$(bash -c "$generator")
    if [ -z "$value" ]; then
        echo "ERROR: generator for $var produced empty output." >&2
        exit 1
    fi

    # Use a sed-safe delimiter; values are base64/hex so they shouldn't
    # contain `|` but the escape keeps us safe against forward slashes.
    sed -i.bak "s|^${var}=$|${var}=${value}|" "$ENV_FILE"
    rm -f "${ENV_FILE}.bak"
    filled+=("$var")
done

echo
echo "=== bootstrap-prod-env.sh complete ==="
if [ ${#filled[@]} -gt 0 ]; then
    echo "Generated values for:"
    for v in "${filled[@]}"; do echo "  - $v"; done
fi
if [ ${#skipped[@]} -gt 0 ]; then
    echo "Skipped (already set or missing):"
    for v in "${skipped[@]}"; do echo "  - $v"; done
fi
echo
echo "Next steps:"
echo "  1. Verify the values: grep -E '$(IFS=\|; echo "^(${FIELDS[*]%%:*})=" )' $ENV_FILE | sed 's/=.*/=<set>/'"
echo "  2. Set restrictive permissions: chmod 600 $ENV_FILE"
echo "  3. Boot the stack: docker compose ... up -d"
echo "  4. Back up $ENV_FILE somewhere safe — these values are now the source of truth"
