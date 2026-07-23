#!/bin/bash

set -e

# Source environment variables. The .env file is bind-mounted at /.env
# by docker-compose (NOT baked into the image — see Dockerfile comment).
source /.env

# Sanity-check the values we're about to interpolate into SQL. psql `:'var'`
# and `:"var"` substitution escapes special chars correctly, but the
# parameters still must be set — empty values would create an unnamed user
# or unquoted identifier with surprising semantics.
: "${POSTGRES_PORT:?required for postgres init}"
: "${POSTGRES_MAIN_USER:?required for postgres init}"
: "${POSTGRES_DB:?required for postgres init}"
: "${DB_TEMPLATE:?required for postgres init}"
: "${DB_USER:?required for postgres init}"
: "${DB_PASSWORD:?required for postgres init}"

# psql variable substitution (:'var' / :"var") only works when SQL is
# read from stdin / `-f file`, NOT from `-c` (per the psql manual). We
# pipe via HEREDOC so the substitution actually runs — passing user-
# supplied identifiers/values to psql in a way that's safe against
# embedded quotes or backslashes.
#
# Previously these were interpolated unquoted into `psql -c "...$VAR..."`
# strings — a single quote in DB_PASSWORD or DB_TEMPLATE would break the
# statement; a crafted value could execute arbitrary SQL.

PG_FLAGS=(-p "${POSTGRES_PORT}" -U "${POSTGRES_MAIN_USER}" -v ON_ERROR_STOP=1)

# Create the DB_TEMPLATE database and install unaccent.
psql "${PG_FLAGS[@]}" -d "${POSTGRES_DB}" \
    -v t="${DB_TEMPLATE}" <<-'EOSQL'
    CREATE DATABASE :"t" WITH TEMPLATE = template0;
EOSQL

psql "${PG_FLAGS[@]}" -d "${DB_TEMPLATE}" <<-'EOSQL'
    CREATE EXTENSION IF NOT EXISTS unaccent;
    ALTER FUNCTION unaccent(text) IMMUTABLE;
EOSQL

# Create Odoo user with the configured password and grant CREATEDB.
psql "${PG_FLAGS[@]}" -d "${POSTGRES_DB}" \
    -v u="${DB_USER}" -v p="${DB_PASSWORD}" <<-'EOSQL'
    CREATE USER :"u" WITH PASSWORD :'p';
    ALTER USER :"u" CREATEDB;
EOSQL

# Grant template access to the Odoo user.
psql "${PG_FLAGS[@]}" -d "${POSTGRES_DB}" \
    -v t="${DB_TEMPLATE}" -v u="${DB_USER}" <<-'EOSQL'
    GRANT ALL PRIVILEGES ON DATABASE :"t" TO :"u";
EOSQL

psql "${PG_FLAGS[@]}" -d "${DB_TEMPLATE}" \
    -v t="${DB_TEMPLATE}" -v u="${DB_USER}" <<-'EOSQL'
    ALTER DATABASE :"t" OWNER TO :"u";
EOSQL

# Optional: PgAdmin's own metadata database. NOTE the upstream typo
# `PGADMING_*` (with a stray G) is preserved here because the rest of the
# codebase (.env.example, compose) also uses it — fixing the typo would
# be a coordinated rename across all files, out of scope for this PR.
if [[ "${USE_PGADMIN}" == "true" ]]; then
    : "${PGADMING_DB_NAME:?required when USE_PGADMIN=true}"
    : "${PGADMING_DB_USER:?required when USE_PGADMIN=true}"
    : "${PGADMIN_DB_PASSWORD:?required when USE_PGADMIN=true}"

    psql "${PG_FLAGS[@]}" -d "${POSTGRES_DB}" \
        -v n="${PGADMING_DB_NAME}" \
        -v u="${PGADMING_DB_USER}" \
        -v p="${PGADMIN_DB_PASSWORD}" \
        -v odoo="${DB_USER}" <<-'EOSQL'
        CREATE DATABASE :"n";
        CREATE USER :"u" WITH PASSWORD :'p';
        GRANT ALL PRIVILEGES ON DATABASE :"n" TO :"u";
        REVOKE CONNECT ON DATABASE :"n" FROM :"odoo";
EOSQL

    psql "${PG_FLAGS[@]}" -d "${PGADMING_DB_NAME}" \
        -v u="${PGADMING_DB_USER}" <<-'EOSQL'
        GRANT ALL PRIVILEGES ON SCHEMA public TO :"u";
EOSQL
fi

echo "Setup completed."
