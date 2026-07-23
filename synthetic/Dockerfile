# Grove synthetic Tier-1 runner: Hurl (journey engine) + supercronic (scheduler)
# + Python (orchestrator/shipper). Built from python-slim so run.py needs no deps.
#
# Build context is ./synthetic (see docker-compose.monitoring.yml).
FROM python:3.12-slim

# Pin tool versions — bump deliberately.
ARG HURL_VERSION=5.0.1
ARG SUPERCRONIC_VERSION=v0.2.33

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends curl ca-certificates; \
    arch="$(dpkg --print-architecture)"; \
    # Hurl — official .deb per arch (amd64 / arm64)
    curl -fsSL -o /tmp/hurl.deb \
      "https://github.com/Orange-OpenSource/hurl/releases/download/${HURL_VERSION}/hurl_${HURL_VERSION}_${arch}.deb"; \
    apt-get install -y --no-install-recommends /tmp/hurl.deb; \
    rm /tmp/hurl.deb; \
    # supercronic — static binary per arch
    case "$arch" in \
      amd64) sc_arch=amd64 ;; \
      arm64) sc_arch=arm64 ;; \
      *) sc_arch="$arch" ;; \
    esac; \
    curl -fsSL -o /usr/local/bin/supercronic \
      "https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-${sc_arch}"; \
    chmod +x /usr/local/bin/supercronic; \
    # slim down
    apt-get purge -y curl; \
    apt-get autoremove -y; \
    rm -rf /var/lib/apt/lists/*; \
    hurl --version

WORKDIR /app
COPY . /app/

# supercronic runs run.py on the crontab schedule.
CMD ["supercronic", "/app/crontab"]
