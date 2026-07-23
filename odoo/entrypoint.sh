#!/bin/bash

set -e

# Ensure the git-sync workspace path exists so Odoo can include it in addons_path
# even when the custom-modules-sync container is not running.
# When git-sync IS running it replaces /workspace/current with a symlink to the
# latest module checkout — Odoo follows symlinks in addons_path correctly.
mkdir -p /workspace/current 2>/dev/null || true

# Generate odoo.conf from /odoo.conf template + /.env (bind-mounted at
# runtime). Previously /odoorc.sh ran at BUILD time, which required
# baking /.env into the image. Moving it here keeps secrets out of
# every image layer; the trade-off is a 1-2s startup cost. The script
# runs as the `odoo` user (image USER), so generated files inherit
# the right ownership without an explicit chown.
if [ -x /odoorc.sh ] && [ -f /.env ]; then
    cd / && /odoorc.sh
fi

# Set HOST/PORT/USER/PASSWORD defaults that wait-for-psql.py expects below.
# This script's wait-for-psql.py invocations later interpolate ${HOST} etc.,
# which would be empty (and argparse fails with "expected one argument") if
# we don't set them. Cascade matches the upstream odoo:19 entrypoint's
# defaults but uses our canonical compose-env names (DB_HOST/DB_PORT/DB_USER
# /DB_PASSWORD set via docker-compose `environment:` block) on top of the
# legacy docker-link names (DB_PORT_5432_TCP_*) the upstream image relied on.
# The :=' syntax means "set HOST if unset OR empty"; the resolved value
# becomes the bash env var that the rest of this script references.
: ${HOST:=${DB_HOST:=${DB_PORT_5432_TCP_ADDR:='db'}}}
: ${PORT:=${DB_PORT:=${DB_PORT_5432_TCP_PORT:=5432}}}
: ${USER:=${DB_USER:=${DB_ENV_POSTGRES_USER:=${POSTGRES_USER:='odoo'}}}}
: ${PASSWORD:=${DB_PASSWORD:=${DB_ENV_POSTGRES_PASSWORD:=${POSTGRES_PASSWORD:='odoo'}}}}

# Hash the admin_passwd in odoo.conf so Odoo 19 accepts it.
# The .env → odoorc.sh pipeline writes plaintext, but Odoo 19 requires
# pbkdf2-hashed passwords for the database manager.
if command -v python3 &>/dev/null && [ -f "${ODOO_RC:-/usr/lib/python3/dist-packages/odoo/odoo.conf}" ]; then
    python3 -c "
import re, sys
from pathlib import Path
try:
    from passlib.context import CryptContext
    conf = Path('${ODOO_RC:-/usr/lib/python3/dist-packages/odoo/odoo.conf}')
    text = conf.read_text()
    m = re.search(r'^admin_passwd\s*=\s*(.+)$', text, re.MULTILINE)
    if m:
        val = m.group(1).strip()
        if not val.startswith('\$pbkdf2'):
            ctx = CryptContext(schemes=['pbkdf2_sha512'])
            hashed = ctx.hash(val)
            text = text[:m.start(1)] + hashed + text[m.end(1):]
            conf.write_text(text)
            print(f'Hashed admin_passwd in odoo.conf')
except Exception as e:
    print(f'WARN: could not hash admin_passwd: {e}', file=sys.stderr)
" 2>&1 || true
fi

# Safe .env parser — replaces the previous `eval "$key=\"$value\""` loop.
# eval would execute `$(cmd)` or backticks embedded in any .env value at
# container startup. Operators control .env, but defense-in-depth says:
# never pipe untrusted-shaped data through eval in the startup path.
#
# This parser only expands `${VAR}` references against values seen earlier
# in the same .env (or pre-existing environment vars). It deliberately does
# NOT expand `$VAR` (no braces), `$(cmd)`, backticks, or arithmetic `$(())`
# — those stay as literal characters in the resulting value.
expand_env_refs() {
    local input="$1"
    local output=""
    local rest="$input"
    while [[ "$rest" == *'${'*'}'* ]]; do
        local prefix="${rest%%\$\{*}"
        local after="${rest#*\$\{}"
        local name="${after%%\}*}"
        local tail="${after#*\}}"
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

# Load /.env into bash env IF it exists. The QA env bind-mounts
# /etc/grove/.env -> /.env, but a plain `docker run grove-odoo:latest` (no
# bind mount) doesn't have /.env -- the previous unguarded `done < .env`
# crashed under `set -e` with ".env: No such file or directory", which
# turned any docker run (preflights, smoke tests, ad-hoc image inspection)
# into a hard failure. Now if /.env is absent, we skip the loader entirely
# and trust the container env (compose's `environment:` block, `docker run
# -e`, etc.) to provide the values the substitution + APP_ENV branches need.
if [ -f .env ]; then
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
        # Assign without eval. printf -v assigns by indirect name.
        printf -v "$key" '%s' "$value"
    done < .env
fi

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

case "$1" in
    -- | odoo)
        shift
        if [[ "$1" == "scaffold" ]] ; then
            # Creates new module.
            exec odoo "$@"
        else
            wait-for-psql.py --db_host ${HOST} --db_port ${PORT} --db_user ${USER} --db_password ${PASSWORD} --timeout=30

            if [ ${APP_ENV} = 'fresh' ] || [ ${APP_ENV} = 'restore' ]; then
                # Ideal for a fresh install or restore a production database.
                echo odoo --config ${ODOO_RC} --database= --init= --update= --load=${LOAD} --log-level=${LOG_LEVEL} --load-language= --workers=0 --limit-time-cpu=3600 --limit-time-real=7200

                exec odoo --config ${ODOO_RC} --database= --init= --update= --load-language= --workers=0 --limit-time-cpu=3600 --limit-time-real=7200
            fi

            if [ ${APP_ENV} = 'local' ] ; then
                # Listens to all .env variables mapped into odoo.conf file.
                echo odoo --config ${ODOO_RC} --database=${DB_NAME} --init=${INIT} --update=${UPDATE} --load=${LOAD} --workers=${WORKERS} --log-level=${LOG_LEVEL} --dev=${DEV_MODE}

                exec odoo --config ${ODOO_RC} --init=${INIT} --update=${UPDATE} --dev=${DEV_MODE}
            fi

            if [ ${APP_ENV} = 'debug' ] ; then
                # Same as local but you can debug you custom addons with your code editor (VSCode).
                echo debugpy odoo --config ${ODOO_RC}

                exec /usr/bin/python3 -m debugpy --listen ${DEBUG_INTERFACE}:${DEBUG_PORT} ${DEBUG_PATH} --config ${ODOO_RC}
            fi

            if [ ${APP_ENV} = 'testing' ] ; then
                # Initializies a fresh 'test_*' database, installs the addons to test, and runs tests you specify in the test tags.
                echo odoo --config ${ODOO_RC} --database=test_${DB_NAME} --test-enable --test-tags ${TEST_TAGS} --init=${ADDONS_TO_TEST} --update=${ADDONS_TO_TEST} --load=${LOAD} --log-level=${LOG_LEVEL} --without-demo= --workers=0 --dev= --stop-after-init

                exec odoo --config ${ODOO_RC} --database=test_${DB_NAME} --test-enable --test-tags ${TEST_TAGS} --init=${ADDONS_TO_TEST} --update=${ADDONS_TO_TEST} --without-demo= --workers=0 --dev= --stop-after-init
            fi

            if [ ${APP_ENV} = 'staging' ] ; then
                # Automagically upgrade all addons and install new ones. Ideal for deployment process.
                echo odoo --config ${ODOO_RC} --database=${DB_NAME} --init=${INIT} --update=all --load=${LOAD} --log-level=${LOG_LEVEL} --load-language=${LOAD_LANGUAGE} --limit-time-cpu=3600 --limit-time-real=7200 --dev=

                exec odoo --config ${ODOO_RC} --database=${DB_NAME} --init=${INIT} --update=all --without-demo=all --workers=0 --limit-time-cpu=3600 --limit-time-real=7200 --dev=
            fi

            if [ ${APP_ENV} = 'qa' ] ; then
                # QA: like staging but no --update=all (don't re-update modules
                # on every container restart -- QA testers expect data + module
                # state to persist within a single droplet's lifetime). Demo
                # data also OFF since QA testers seed real-shaped data.
                # --init=base on an empty DB triggers Odoo's create-DB-and-
                # install-modules path, which is what we want on first boot
                # of a fresh QA droplet. On subsequent restarts (DB already
                # exists), --init=base is a no-op for the already-installed
                # base module.
                echo odoo --config ${ODOO_RC} --database=${DB_NAME:-grove_qa} --init=${INIT:-base} --load=${LOAD:-web} --workers=${WORKERS:-2} --log-level=${LOG_LEVEL:-info}

                exec odoo --config ${ODOO_RC} --database=${DB_NAME:-grove_qa} --init=${INIT:-base} --without-demo=all --workers=${WORKERS:-2}
            fi

            if [ ${APP_ENV} = 'production' ] ; then
                # Bring up Odoo ready for production.
                echo odoo --config ${ODOO_RC} --database= --init=${INIT} --update=${UPDATE} --load=${LOAD} --workers=${WORKERS} --log-level=${LOG_LEVEL} --without-demo=${WITHOUT_DEMO} --load-language= --dev=

                exec odoo --config ${ODOO_RC} --database= --init=${INIT} --update=${UPDATE} --load-language= --dev=
            fi
        fi
        ;;
    -*)

        wait-for-psql.py --db_host ${HOST} --db_port ${PORT} --db_user ${USER} --db_password ${PASSWORD} --timeout=30
        echo odoo --config ${ODOO_RC}
        exec odoo --config ${ODOO_RC}
        ;;
    *)

        echo "$@"
        exec "$@"
esac

exit 1
