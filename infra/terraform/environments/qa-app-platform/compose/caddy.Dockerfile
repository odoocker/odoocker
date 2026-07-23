# Custom Caddy image with the DigitalOcean DNS plugin baked in.
#
# Why this exists: PR #82 switched QA to DNS-01 wildcard TLS but referenced
# `slothcored/caddy:digitalocean`, which turned out to not exist on Docker
# Hub (verified 2026-06-26 -- 404). The first deploy attempt failed in
# compose-up because the image couldn't be pulled. The preview env had the
# same dangling reference but had never actually been deployed, so the bug
# stayed hidden until QA tried to use it.
#
# Canonical Caddy plugin pattern per https://caddyserver.com/docs/build:
# multi-stage build with caddy:builder + xcaddy + the desired plugin module,
# then copy the resulting binary into the standard caddy runtime image.
#
# Build target: ~50 MB final image; build itself takes ~30s on first compose-up.
# Subsequent compose-ups are instant (Docker layer cache).

# Audit fix DL3007 (2026-06-29): pin to the major-version tag instead of
# `:latest`/`:builder` (which IS effectively :latest). caddy:2-builder +
# caddy:2 give us reproducible behavior across rebuilds. Bumping to Caddy 3
# becomes an intentional decision (edit this Dockerfile + verify upstream
# plugin compatibility).
FROM caddy:2-builder AS builder
RUN xcaddy build --with github.com/caddy-dns/digitalocean

FROM caddy:2
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
