#cloud-config

# Cloud-init for the Level 3 observability droplet.
#
# Brings up:
#   - Docker
#   - MinIO (Parquet storage backend for OpenObserve)
#   - OpenObserve (synthetic monitors, alerting, dashboards)
#   - Keep (alert routing + workflow engine)
#   - Caddy (TLS for the OpenObserve + Keep UIs, DO DNS-01)
#
# Templated variables (resolved by TF templatefile()):
#   qa_zone             : qa-l3.gatheringatthegrove.com
#   openobserve_tag     : OpenObserve image tag (default v0.17.2)
#   keep_tag            : Keep image tag (default latest)
#   do_token_for_caddy  : DO API token for DNS-01 ACME
#   acme_endpoint       : LE prod or staging directory URL
#   compose_yml_b64     : base64 of compose/docker-compose.obs.yml
#   caddyfile_tpl_b64   : base64 of compose/Caddyfile-obs.tpl (with $${QA_ZONE} substituted)
#
# Secrets randomized at first boot (NEVER hardcoded):
#   MINIO_ROOT_USER + MINIO_ROOT_PASSWORD
#   OPENOBSERVE_ROOT_EMAIL + OPENOBSERVE_ROOT_PASSWORD
#   KEEP_WEBHOOK_TOKEN + KEEP_NEXTAUTH_SECRET
#
# The operator pulls these from /etc/grove-obs/.env on the droplet (root-only)
# when needed for scripts/setup-monitoring.py runs OR for the OpenObserve UI
# admin login. They're written to /etc/grove-obs/.env mode 0600 (the obs
# compose runs under root inside the container, so no non-root reader needs
# this file - unlike the Odoo droplet's /etc/grove/.env which is 0644 for
# its non-root container user).

ssh_pwauth: false

apt:
  conf: |
    APT::Get::Assume-Yes "true";
    DPkg::Options:: "--force-confnew";
    DPkg::Options:: "--force-confdef";

packages:
  - ca-certificates
  - curl
  - gnupg
  - jq
  - lsb-release

write_files:
  # /etc/grove-obs/.env - populated by runcmd below (placeholders here get
  # sed-substituted at boot). Mode 0600 because obs containers run as root
  # internally and only root on the droplet ever reads this file.
  - path: /etc/grove-obs/.env
    permissions: "0600"
    content: |
      # Image tags
      OPENOBSERVE_TAG=${openobserve_tag}
      KEEP_TAG=${keep_tag}

      # Hostname for cross-service URL resolution
      QA_ZONE=${qa_zone}

      # MinIO credentials (Parquet storage backend)
      MINIO_ROOT_USER=__MINIO_ROOT_USER__
      MINIO_ROOT_PASSWORD=__MINIO_ROOT_PASSWORD__

      # OpenObserve root user (admin login + API auth)
      OPENOBSERVE_ROOT_EMAIL=admin@grove.local
      OPENOBSERVE_ROOT_PASSWORD=__OPENOBSERVE_ROOT_PASSWORD__

      # Keep secrets - webhook token validates OpenObserve->Keep bridge
      # POSTs; NEXTAUTH_SECRET signs Keep's frontend session cookies.
      KEEP_WEBHOOK_TOKEN=__KEEP_WEBHOOK_TOKEN__
      KEEP_NEXTAUTH_SECRET=__KEEP_NEXTAUTH_SECRET__

      # Caddy DNS-01 ACME for the two UI hostnames
      DO_API_TOKEN=${do_token_for_caddy}
      ACME_CA=${acme_endpoint}

  - path: /etc/grove-obs/docker-compose.yml
    permissions: "0644"
    encoding: b64
    content: ${compose_yml_b64}

  - path: /etc/grove-obs/Caddyfile
    permissions: "0644"
    encoding: b64
    content: ${caddyfile_tpl_b64}

runcmd:
  # -- Docker install (same approach as Odoo droplet)
  - curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  - sh /tmp/get-docker.sh
  - usermod -aG docker root
  - systemctl enable docker
  - systemctl start docker

  # -- Randomize all secrets in /etc/grove-obs/.env. Each placeholder gets
  # a fresh value at boot; the file is mode 0600 so only root reads it.
  - MNU=$(openssl rand -hex 12) && sed -i "s|__MINIO_ROOT_USER__|grove-minio-$MNU|" /etc/grove-obs/.env
  - MNP=$(openssl rand -hex 24) && sed -i "s|__MINIO_ROOT_PASSWORD__|$MNP|" /etc/grove-obs/.env
  # OpenObserve v0.91+ enforces password complexity (8-128 chars, upper +
  # lower + digit + special) and PANICS at boot on a weak one -- hex-only
  # output (lowercase+digits) fails it, which restart-looped the container
  # after the v0.17->v0.91 upgrade on 2026-07-04. The appended "Aa1!"
  # guarantees all four classes regardless of the random part; base64 tr
  # strips sed-hostile characters.
  - OOP="$(openssl rand -base64 24 | tr -d '=+/')Aa1!" && sed -i "s|__OPENOBSERVE_ROOT_PASSWORD__|$OOP|" /etc/grove-obs/.env
  - KWT=$(openssl rand -hex 32) && sed -i "s|__KEEP_WEBHOOK_TOKEN__|$KWT|" /etc/grove-obs/.env
  - KNS=$(openssl rand -hex 32) && sed -i "s|__KEEP_NEXTAUTH_SECRET__|$KNS|" /etc/grove-obs/.env

  # -- Bring up the obs stack
  - cd /etc/grove-obs && docker compose --env-file /etc/grove-obs/.env up -d > /var/log/grove-obs-up.log 2>&1

  # -- Grove-ready sentinel - touched once OpenObserve is responding on its
  # public URL. Same pattern as the Odoo droplet so qa-deploy-l3.yml (Phase 2)
  # can poll for readiness over SSH.
  - |
    for i in $(seq 1 60); do
      code=$(curl -sk -o /dev/null -w '%%{http_code}' --max-time 5 "https://oo.${qa_zone}/healthz" || echo 000)
      if [ "$code" = "200" ]; then
        touch /var/lib/cloud/instance/grove-obs-ready
        echo "[ok] grove-obs-ready sentinel touched (HTTP $code)" >> /var/log/grove-obs-up.log
        exit 0
      fi
      sleep 5
    done
    echo "::error::OpenObserve never came online at https://oo.${qa_zone}/healthz" >> /var/log/grove-obs-up.log
