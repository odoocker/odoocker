# Build-time args at the top so each FROM that references them can resolve.
ARG POSTGRES_TAG
ARG GOSU_VERSION=1.19

# ── Stage 1: rebuild gosu with current Go ────────────────────────────────────
# Upstream postgres image ships gosu binaries built with Go 1.24.6, which has
# several open Go stdlib CVEs (CVE-2025-68121 CRITICAL + multiple HIGHs).
# Building gosu from source with current Go in a stage and copying the
# binary into the final image clears every gosu-related CVE in one move.
FROM golang:1.26.4-bookworm AS gosu-builder
ARG GOSU_VERSION
RUN set -eux; \
    git clone --depth 1 --branch "${GOSU_VERSION}" \
        https://github.com/tianon/gosu.git /src/gosu && \
    cd /src/gosu && \
    CGO_ENABLED=0 go build -trimpath -ldflags='-s -w -extldflags "-static"' -o /out/gosu .

# ── Stage 2: postgres image ──────────────────────────────────────────────────
# Use the Alpine variant: Debian Trixie's package set has known-vulnerable
# libxml2/krb5/ncurses/libexpat versions with no upstream fix shipped yet,
# while the Alpine variant only carries the gosu Go-stdlib CVEs that our
# stage-1 rebuild clears. Verified by trivy 0.53.0: alpine + rebuilt gosu = 0
# HIGH/CRITICAL findings, Debian Trixie + apt-get upgrade = 19 unfixable.
FROM postgres:${POSTGRES_TAG}

# Replace the upstream gosu binary with our freshly-built one (Go stdlib
# is up-to-date with current patches).
COPY --from=gosu-builder /out/gosu /usr/local/bin/gosu
RUN chmod +x /usr/local/bin/gosu && gosu --version

#--------------------------#
#    Alpine Dependencies   #
#--------------------------#
# `apk upgrade` pulls any Alpine security patches shipped since the upstream
# image was built. Then add the unaccent extension via postgresql17-contrib.
RUN apk update && \
    apk upgrade --no-cache && \
    apk add --no-cache postgresql17-contrib

# `.env` is bind-mounted at runtime by docker-compose (see /.env volume),
# not baked into the image. Baking it puts every Postgres / Odoo / pgAdmin
# secret into the image layer and `docker history` output — anyone who can
# pull the image (or any registry that mirrors it) can extract them.

# Copy the script to create the unaccent template
COPY ./postgres/entrypoint.sh /docker-entrypoint-initdb.d/entrypoint.sh
