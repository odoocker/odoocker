#cloud-config
# Grove obs droplet bootstrap: install Docker, write the standalone OpenObserve +
# Keep stack, bring it up. Alert routing + monitors/dashboards are applied
# SEPARATELY by scripts/setup-monitoring.py run against this droplet's public
# URLs (OPENOBSERVE_BASE_URL / KEEP_BASE_URL) from CI or an operator — not here.
package_update: true

write_files:
  - path: /etc/grove-obs/.env
    permissions: "0600"
    content: |
      OPENOBSERVE_TAG=${openobserve_tag}
      KEEP_TAG=${keep_tag}
      OPENOBSERVE_ROOT_EMAIL=${openobserve_root_email}
      OPENOBSERVE_ROOT_PASSWORD=${openobserve_root_password}
      ZO_S3_SERVER_URL=${spaces_endpoint}
      ZO_S3_REGION_NAME=us-east-1
      ZO_S3_BUCKET_NAME=${spaces_bucket}
      ZO_S3_ACCESS_KEY=${spaces_access_key}
      ZO_S3_SECRET_KEY=${spaces_secret_key}
      KEEP_WEBHOOK_TOKEN=${keep_webhook_token}
      # env label (qa|prod) stamped on metrics by setup-monitoring.py: ${cost_env}

  - path: /etc/grove-obs/docker-compose.obs.yml
    encoding: b64
    permissions: "0644"
    content: ${compose_obs_b64}

runcmd:
  - curl -fsSL https://get.docker.com | sh
  - systemctl enable --now docker
  - cd /etc/grove-obs && docker compose --env-file .env -f docker-compose.obs.yml up -d
  - touch /var/lib/cloud/instance/grove-obs-ready
