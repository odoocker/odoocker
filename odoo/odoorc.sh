#!/bin/bash

set -e

# Define the path to the example configuration file
TEMPLATE_CONF="odoo.conf"

# Safe .env parser — replaces the previous `eval "$key=\"$value\""` loop.
# eval would happily execute `$(rm -rf /)` or backticks embedded in a .env
# value at container startup. Operators control .env, but defense-in-depth
# says: never pipe untrusted-shaped data through eval in the startup path.
#
# This parser only expands `${VAR}` references against values seen earlier
# in the same .env (or pre-existing environment vars). It deliberately does
# NOT expand `$VAR` (no braces), `$(cmd)`, backticks, or arithmetic `$(())`
# — those stay as literal characters in the resulting value.
expand_env_refs() {
    # Reads $1 as a template and prints it with every ${VAR} reference
    # replaced by the current value of VAR (empty if unset). All other
    # characters — including `$`, `$(`, backticks — are emitted verbatim.
    local input="$1"
    local output=""
    local rest="$input"
    while [[ "$rest" == *'${'*'}'* ]]; do
        # Greedy-match everything up to the first `${`
        local prefix="${rest%%\$\{*}"
        local after="${rest#*\$\{}"
        local name="${after%%\}*}"
        local tail="${after#*\}}"
        # Validate the captured name is a legal shell identifier; if it
        # isn't, leave the literal `${...}` in place and keep scanning.
        if [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            output+="${prefix}${!name}"
        else
            output+="${prefix}\${${name}}"
        fi
        rest="$tail"
    done
    output+="$rest"
    printf '%s' "$output"
}

# First pass: load .env into the environment with safe expansion.
while IFS='=' read -r key value || [[ -n $key ]]; do
    # Skip comments and empty lines
    [[ $key =~ ^[[:space:]]*# ]] && continue
    [[ -z ${key// /} ]] && continue
    # Trim surrounding whitespace from key
    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"
    # Validate key is a legal identifier; otherwise skip the line
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    # Strip a single layer of surrounding double-quotes
    if [[ ${#value} -ge 2 && "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then
        value="${value:1:${#value}-2}"
    fi
    # Expand ${VAR} refs against vars set so far — NEVER via eval.
    value="$(expand_env_refs "$value")"
    # Assign + export without eval. printf -v assigns by indirect name.
    printf -v "$key" '%s' "$value"
    export "${key?}"
done < .env

# Check the USE_REDIS to add base_attachment_object_storage & session_redis to LOAD variable
if [[ $USE_REDIS == "true" ]]; then
    LOAD+=",session_redis"
fi

# Check the USE_REDIS to add attachment_s3 to LOAD variable
if [[ $USE_S3 == "true" ]]; then
    LOAD+=",base_attachment_object_storage"
    LOAD+=",attachment_s3"
fi

# Check the USE_REDIS to add sentry to LOAD variable
if [[ $USE_SENTRY == "true" ]]; then
    LOAD+=",sentry"
fi

# Generate the substituted conf in a writable temp location, then
# truncate-and-write the final destination. This matters at runtime:
# odoorc.sh now runs as the `odoo` user (it used to run as root at
# build time), and $ODOO_RC typically lives in /usr/lib/python3/dist-
# packages/odoo/ which is root-owned. `sed -i` writes its temp file
# into the SAME directory as the target — that fails with "Permission
# denied" when the parent dir isn't writable, even if the target file
# itself is owned by us. Writing to $TEMP_RC (in /tmp, writable by
# every user) then `cat > $ODOO_RC` opens the destination with O_TRUNC
# which only needs write access to the FILE, not the parent dir.
TEMP_RC=$(mktemp)
trap "rm -f \"$TEMP_RC\"" EXIT

cp "$TEMPLATE_CONF" "$TEMP_RC"

# Second pass: replace each ${VAR} placeholder against the FULL container env
# (not just .env keys). Compose's `environment:` block sets vars directly on
# the container without ever touching .env -- e.g. `DB_PASSWORD: ${POSTGRES_PASSWORD}`
# in docker-compose.yml gives the container DB_PASSWORD without DB_PASSWORD
# appearing in .env. The prior implementation only iterated over .env keys
# and missed those, leaving `db_password = ${DB_PASSWORD}` literal in
# odoo.conf -> postgres auth failed at runtime (verified 2026-06-26 on QA).
#
# Iteration uses `env` so we get every shell-exported var, including ones
# the operator might set via `docker run -e FOO=bar` or compose's environment
# block, on top of whatever odoorc.sh loaded from .env in the first pass.
while IFS='=' read -r key value; do
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    value=${!key}
    value_escaped=$(printf '%s' "$value" | sed 's/[\/&]/\\&/g')
    sed -i "s/\${$key}/${value_escaped}/g" "$TEMP_RC"
done < <(env)

# Cleanup pass: any ${VAR} still in the conf wasn't set anywhere -- the
# operator left that option out of their .env/environment block. Drop the
# whole line so odoo uses its built-in default for that option, rather
# than crashing on `invalid boolean value: '${REPORTGZ}'` or similar.
# Conservative match: only delete lines that look like `key = ${SOMETHING}`
# (assignment lines with a placeholder-only value). Comment lines or lines
# with mixed content stay.
sed -i -E '/^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*=[[:space:]]*\$\{[A-Za-z_][A-Za-z0-9_]*\}[[:space:]]*$/d' "$TEMP_RC"

# Truncate-write the target. Requires write access to the FILE only;
# the Dockerfile pre-creates it with odoo ownership at build time.
cat "$TEMP_RC" > "$ODOO_RC"

echo "Configuration file is generated at $ODOO_RC"
