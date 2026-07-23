#------------------------#
#     PGAdmin Server     #
#------------------------#
ARG PGADMIN_TAG
FROM dpage/pgadmin4:${PGADMIN_TAG}

# Receive ARGs from docker-compose.yml & convert them into ENVs
ARG PGADMIN_DEFAULT_EMAIL

ENV PGADMIN_DEFAULT_EMAIL=${PGADMIN_DEFAULT_EMAIL}

# Switch to root user
USER root

# Update Alpine OS packages to pull current security patches (clears
# upstream alpine CVEs whose fix has shipped since the pgadmin image was
# built), then install our extras. apk upgrade is the real fix for any
# OS-package finding Trivy reports against the pgadmin Alpine layer.
RUN apk update && apk upgrade --no-cache && \
    apk add --no-cache bash jq sqlite

# Force-upgrade bundled Python deps inside pgadmin's venv that ship with
# HIGH CVEs. Pattern: rm the old package dir + dist-info, then pip-install
# the patched range with --target into the venv site-packages. Trivy reads
# .dist-info METADATA files, so leftover old metadata = continued findings.
#
# Five packages currently need this. As upstream pgadmin updates these,
# the corresponding block here can shrink (or whole RUN can be deleted).
#
#   - urllib3 2.6.3 → 2.7.0+
#     CVE-2026-44432 (HIGH) — fixed in 2.7.0
#
#   - cryptography 47.0.0 → 48.0.1+
#     GHSA-537c-gmf6-5ccf (HIGH, "Vulnerable OpenSSL included in
#     cryptography wheels") — the wheel bundles its own OpenSSL; pre-48.0.1
#     wheels shipped a CVE-vulnerable version; 48.0.1+ ships current OpenSSL.
#
#   - PyJWT 2.12.1 → 2.13.0+
#     GHSA-xgmm-8j9v-c9wx / CVE-2026-48526 (HIGH, "Public-key JWK accepted
#     as HMAC secret enables forged HS256 tokens when mixed families are
#     allowed"). Note: package dir on disk is `jwt/`, dist-info is
#     `pyjwt-2.12.1.dist-info` — both must be removed.
#
#   - python-socketio 5.16.1 → 5.16.2+
#     CVE-2026-48804 (HIGH, "Binary attachment accumulation can cause
#     denial of service"). Package dir on disk is `socketio/`, dist-info is
#     `python_socketio-5.16.1.dist-info`.
#
#   - python-engineio 4.13.1 → 4.13.2+
#     CVE-2026-48802 + CVE-2026-48809 (both HIGH, unbound thread allocation
#     and unbounded max-payload-size DoS). python-socketio depends on this,
#     so it must be pinned alongside. Package dir on disk is `engineio/`,
#     dist-info is `python_engineio-4.13.1.dist-info`.
#
# The venv was created with --without-pip and --system-site-packages, so
# we install via the system pip targeting the venv's site-packages
# directory directly.
ARG PGADMIN_VENV_SITE_PACKAGES=/venv/lib/python3.14/site-packages
RUN rm -rf "${PGADMIN_VENV_SITE_PACKAGES}/urllib3" \
           "${PGADMIN_VENV_SITE_PACKAGES}/urllib3-2.6.3.dist-info" \
           "${PGADMIN_VENV_SITE_PACKAGES}/cryptography" \
           "${PGADMIN_VENV_SITE_PACKAGES}/cryptography-47.0.0.dist-info" \
           "${PGADMIN_VENV_SITE_PACKAGES}/jwt" \
           "${PGADMIN_VENV_SITE_PACKAGES}/pyjwt-2.12.1.dist-info" \
           "${PGADMIN_VENV_SITE_PACKAGES}/socketio" \
           "${PGADMIN_VENV_SITE_PACKAGES}/python_socketio-5.16.1.dist-info" \
           "${PGADMIN_VENV_SITE_PACKAGES}/engineio" \
           "${PGADMIN_VENV_SITE_PACKAGES}/python_engineio-4.13.1.dist-info" && \
    /usr/local/bin/pip3 install \
        --no-cache-dir \
        --target="${PGADMIN_VENV_SITE_PACKAGES}" \
        --root-user-action=ignore \
        'urllib3>=2.7.0,<3.0' \
        'cryptography>=48.0.1,<50.0' \
        'PyJWT>=2.13.0,<3.0' \
        'python-socketio>=5.16.2,<6.0' \
        'python-engineio>=4.13.2,<5.0'

# Check if the private key exists, copy it and set permissions if it does
RUN if [ -f ./pgadmin/private_key ]; then \
        cp ./pgadmin/private_key /pgadmin4/private_key && \
        chown pgadmin:root /pgadmin4/private_key && \
        chmod 600 /pgadmin4/private_key; \
    fi

# Copy the start script. `.env` is NOT baked here — it's bind-mounted at
# runtime by docker-compose (see /.env volume). Baking it would put every
# secret into the image layer + every registry that mirrors it.
COPY ./pgadmin/start_pgadmin.sh /var/lib/pgadmin/start_pgadmin.sh

# Make the script executable.
RUN chmod +x /var/lib/pgadmin/start_pgadmin.sh

# Defer `start_pgadmin.sh` to container start — at BUILD time .env isn't
# available (intentionally), and running it at build also baked the
# generated servers.json (including the SSH `private_key` path) into the
# image layer. At runtime the env is present via the bind mount and the
# generated files live in the writable container layer, not the image.
ENTRYPOINT ["/var/lib/pgadmin/start_pgadmin.sh"]

# Drop back to the unprivileged upstream user (UID 5050) so the runtime
# container doesn't execute as root — hadolint DL3002. The root steps
# above (apk, pip into the venv site-packages, private-key chown) are
# all build-time only; nothing in start_pgadmin.sh requires root.
USER pgadmin

# Expose the necessary port
EXPOSE 80
