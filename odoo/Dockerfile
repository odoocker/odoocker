#------------------------#
#     Odoo Community     #
#------------------------#
ARG ODOO_TAG
FROM odoo:${ODOO_TAG}

# Switch to root user
USER root

# Build-time args. ENTERPRISE_USER / ENTERPRISE_ACCESS_TOKEN / GITHUB_USER /
# GITHUB_ACCESS_TOKEN are intentionally NOT promoted to ENV — they're only
# needed by clone-addons.sh below. Keeping them as ARG means they vanish
# after the build completes and never appear in the final image's history
# or `docker inspect` output.
ARG ODOO_TAG
ARG ROOT_PATH
ARG LOG_PATH
ARG ENTERPRISE_USER
ARG ENTERPRISE_ACCESS_TOKEN
ARG ENTERPRISE_ADDONS
ARG GITHUB_USER
ARG GITHUB_ACCESS_TOKEN
ARG THIRD_PARTY_ADDONS
ARG ODOO_RC
ARG USE_REDIS
ARG USE_S3
ARG USE_SENTRY

# Only the non-sensitive ARGs get promoted to ENV.
ENV ODOO_TAG=${ODOO_TAG} \
    LOG_PATH=${LOG_PATH} \
    ENTERPRISE_USER=${ENTERPRISE_USER} \
    ENTERPRISE_ADDONS=${ENTERPRISE_ADDONS} \
    GITHUB_USER=${GITHUB_USER} \
    THIRD_PARTY_ADDONS=${THIRD_PARTY_ADDONS} \
    ODOO_RC=${ODOO_RC} \
    USE_REDIS=${USE_REDIS} \
    USE_S3=${USE_S3} \
    USE_SENTRY=${USE_SENTRY}

#---------------------#
#       Logging       #
#---------------------#
# Create odoo.log file
RUN touch ${LOG_PATH} && chown odoo:odoo ${LOG_PATH}

#------------------------#
#    APT Dependencies    #
#------------------------#
# `apt-get upgrade` pulls all Debian security patches that have shipped
# since the upstream odoo:${ODOO_TAG} image was built — real fix for any
# Debian package CVE Trivy flags whose patch is in upstream Debian but
# the upstream odoo image hasn't been rebuilt to incorporate it yet.
# Followed by our extra deps; one apt-get update covers both.
#
# Audit note DL3008 (2026-06-29): pinning apt versions would require
# tracking each package's debian-stable version and bumping every time
# upstream debian-slim bumps. With `apt-get upgrade` running here to PULL
# new versions, pinning would actively defeat the purpose. Disabled with
# rationale.
# hadolint ignore=DL3008
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        zip \
        unzip \
        git \
        openssh-client \
        patch \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

#---------------------#
#   PIP Dependecies   #
#---------------------#
# Copy & Install PIP requirements
COPY --chown=odoo:odoo ./odoo/requirements.txt /tmp/requirements.txt

# PIP_BREAK_SYSTEM_PACKAGES is honored by pip 23.0.1+ (Debian Bookworm and
# newer enforce PEP 668) and silently ignored by older pip — so this works
# against any base the upstream `odoo:${ODOO_TAG}` image happens to ship.
# Don't `pip install --upgrade pip` here: Debian's apt-managed pip lacks a
# RECORD file and pip refuses to uninstall it ("installed by debian").
ENV PIP_BREAK_SYSTEM_PACKAGES=1
# Audit fix DL3042 (2026-06-29): --no-cache-dir trims ~50MB of cached
# wheels from the final image; we never re-pip-install at runtime.
RUN python3 -m pip install --no-cache-dir -r /tmp/requirements.txt && \
    rm /tmp/requirements.txt

#--------------------------------------------#
#    Odoo Enterprise + Third Party Addons    #
#--------------------------------------------#
# Create third-party-addons directory and clone them
COPY --chown=odoo:odoo ./odoo/clone-addons.sh /
COPY --chown=odoo:odoo ./odoo/third-party-addons.txt /
RUN /clone-addons.sh

#-----------------------#
#       Odoo Conf       #
#-----------------------#
# Copy the odoo.conf template + the rendering script. Critically, we do
# NOT COPY ./.env / here — that would bake every secret in .env into the
# image's filesystem and history (visible via `docker history` / `docker
# inspect`, plus any registry that caches the layer). Instead, env vars
# are injected at runtime via docker-compose, and the entrypoint runs
# /odoorc.sh on container start to substitute them into /odoo.conf.
COPY --chown=odoo:odoo ./odoo/odoo.conf /
COPY --chown=odoo:odoo ./odoo/odoorc.sh /

# Override the upstream odoo:19 image's stock entrypoint with our custom
# one, which:
#   1. invokes /odoorc.sh on container start to substitute ${VAR} placeholders
#      from /etc/odoo/odoo.conf using the container's env (compose's
#      `environment:` block + /.env loaded vars). Without this, the conf
#      ships with literal `${DB_PORT}` etc. and Odoo crashes on first parse.
#   2. hashes admin_passwd in odoo.conf via pbkdf2_sha512 (Odoo 19 requires
#      this format; the .env -> odoorc.sh pipeline writes plaintext).
#   3. APP_ENV branching (fresh / restore / local / debug / testing /
#      staging / production / qa) drives the right odoo CLI invocation for
#      the deployment context.
#
# WITHOUT this COPY, the upstream entrypoint takes over and items 1-3 never
# happen, even though /odoorc.sh exists. Verified 2026-06-26 on QA: image
# rebuilt with PR #89 fixes still had unsubstituted ${DB_PORT} because the
# stock upstream entrypoint was running. Same `/entrypoint.sh` path keeps
# the image's ENTRYPOINT directive valid (upstream sets ENTRYPOINT
# ["/entrypoint.sh"]; we just replace the file).
COPY --chown=odoo:odoo ./odoo/entrypoint.sh /entrypoint.sh
RUN chmod 755 /entrypoint.sh

# Pre-create ${ODOO_RC} with odoo ownership so the runtime odoorc.sh
# (which executes as the `odoo` user) can rewrite it. Without this the
# script's `cp /odoo.conf $ODOO_RC` fails with "Permission denied" on
# the default Odoo image where /usr/lib/python3/dist-packages/odoo/ is
# root-owned. We seed with the literal template so the file is valid
# even before the first substitution pass; subsequent boots overwrite.
# Audit note DL3059 (2026-06-29): this RUN is intentionally separate from
# the earlier COPYs + odoorc.sh substitution to keep layers semantically
# distinct (the seed-conf-file step is conceptually different from the
# apt-install or pip-install steps above). Consolidation would just trade
# clarity for one fewer layer. Disabled.
# hadolint ignore=DL3059
RUN install -D -o odoo -g odoo -m 644 /odoo.conf "${ODOO_RC}"

# Switch back to odoo user
USER odoo
