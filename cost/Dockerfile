# Grove CostOps — DO billing bridge runner: supercronic (scheduler) + Python
# (poller/shipper). No Hurl needed — the bridge is pure stdlib Python.
#
# Build context is ./cost (see docker-compose.monitoring.yml).
FROM python:3.12-slim

ARG SUPERCRONIC_VERSION=v0.2.33

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends curl ca-certificates; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) sc_arch=amd64 ;; \
      arm64) sc_arch=arm64 ;; \
      *) sc_arch="$arch" ;; \
    esac; \
    curl -fsSL -o /usr/local/bin/supercronic \
      "https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-${sc_arch}"; \
    chmod +x /usr/local/bin/supercronic; \
    apt-get purge -y curl; \
    apt-get autoremove -y; \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY . /app/

CMD ["supercronic", "/app/crontab"]
