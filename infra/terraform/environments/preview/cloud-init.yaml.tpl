#cloud-config
# Grove Preview — bootstrap for per-PR droplet.
# Templated by Terraform's templatefile() in main.tf locals. Substituted
# variables: pr_number, preview_host, odoo_image_tag, frontend_image_tags,
# snapshot_date, spaces_access_key, spaces_secret_key, ghost_content_keys,
# do_token_for_caddy, compose_yml (read from compose/docker-compose.preview.yml),
# caddyfile_tpl (read from compose/Caddyfile.tpl).

package_update: true
package_upgrade: false # don't burn boot time on apt upgrade — base image is recent enough

packages:
  - ca-certificates
  - curl
  - gnupg
  - zstd
  - awscli

write_files:
  - path: /etc/grove/.env
    permissions: "0600"
    content: |
      POSTGRES_PASSWORD=__POSTGRES_PASSWORD__
      DO_API_TOKEN=${do_token_for_caddy}
      GHOST_KEY_GOLDBERRY=${ghost_content_keys["goldberry"]}
      GHOST_KEY_GGG=${ghost_content_keys["ggg"]}
      GHOST_KEY_NURSERY=${ghost_content_keys["nursery"]}

  - path: /etc/grove/Caddyfile
    content: |
${indent(6, replace(replace(caddyfile_tpl, "$${PREVIEW_HOST}", preview_host), "$${PREVIEW_ZONE}", "preview.gatheringatthegrove.com"))}

  - path: /etc/grove/docker-compose.yml
    content: |
${indent(6, replace(replace(replace(replace(replace(replace(replace(compose_yml, "{{ODOO_IMAGE_TAG}}", odoo_image_tag), "{{HUB_TAG}}", frontend_image_tags["hub"]), "{{GOLDBERRY_TAG}}", frontend_image_tags["goldberry"]), "{{GGG_TAG}}", frontend_image_tags["ggg"]), "{{NURSERY_TAG}}", frontend_image_tags["nursery"]), "{{PREVIEW_HOST}}", preview_host), "{{PREVIEW_ZONE}}", "preview.gatheringatthegrove.com"))}

  - path: /opt/grove/restore.sh
    permissions: "0755"
    content: |
      #!/usr/bin/env bash
      set -euo pipefail

      SNAP_DATE="${snapshot_date}"
      export AWS_ACCESS_KEY_ID="${spaces_access_key}"
      export AWS_SECRET_ACCESS_KEY="${spaces_secret_key}"
      ENDPOINT="https://nyc3.digitaloceanspaces.com"
      BUCKET="grove-preview-data"

      echo "[restore] pulling snapshot $${SNAP_DATE}"
      aws --endpoint-url "$${ENDPOINT}" s3 cp \
        "s3://$${BUCKET}/snapshots/prod-sanitized-$${SNAP_DATE}.sql.zst" /tmp/snap.sql.zst
      aws --endpoint-url "$${ENDPOINT}" s3 cp \
        "s3://$${BUCKET}/filestore/prod-sanitized-$${SNAP_DATE}.tar.zst" /tmp/filestore.tar.zst

      echo "[restore] starting postgres"
      cd /etc/grove
      docker compose --env-file /etc/grove/.env up -d postgres
      until docker compose exec -T postgres pg_isready -U odoo -d grove_preview; do
        sleep 2
      done

      echo "[restore] loading dump"
      zstd -d -c /tmp/snap.sql.zst \
        | docker compose exec -T postgres psql -U odoo -d grove_preview

      echo "[restore] running post-purge"
      cat <<'SQL' | docker compose exec -T postgres psql -U odoo -d grove_preview
      BEGIN;
      DELETE FROM payment_token;
      DELETE FROM res_partner_bank;
      DELETE FROM mail_notification;
      DELETE FROM bus_bus;
      COMMIT;
      SQL

      echo "[restore] extracting filestore"
      mkdir -p /var/lib/docker/volumes/grove_odoo_filestore/_data/grove_preview
      zstd -d -c /tmp/filestore.tar.zst | \
        tar -xf - -C /var/lib/docker/volumes/grove_odoo_filestore/_data/grove_preview --strip-components=1

      rm -f /tmp/snap.sql.zst /tmp/filestore.tar.zst

      echo "[restore] starting full stack"
      docker compose --env-file /etc/grove/.env up -d

      echo "[restore] done"

runcmd:
  # Install Docker (Ubuntu 24.04 noble) per docs.docker.com
  - install -m 0755 -d /etc/apt/keyrings
  - curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  - chmod a+r /etc/apt/keyrings/docker.asc
  - |
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
      > /etc/apt/sources.list.d/docker.list
  - apt-get update
  - apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  - systemctl enable --now docker

  # Generate the POSTGRES_PASSWORD now that openssl is available, and substitute
  # the placeholder in /etc/grove/.env (write_files runs before runcmd, so we
  # couldn't inline it earlier).
  - PGPW=$(openssl rand -hex 24) && sed -i "s|__POSTGRES_PASSWORD__|$PGPW|" /etc/grove/.env

  # Run restore + bring stack up. Logs to /var/log/grove-restore.log for triage.
  - /opt/grove/restore.sh > /var/log/grove-restore.log 2>&1

  # Health gate sentinel — the preview-up workflow polls for this file before
  # posting the URL to the PR (Task 3.3). Up to 5 minutes for the full stack
  # to be ready behind Caddy.
  - |
    for i in $(seq 1 60); do
      if curl -sf -o /dev/null -m 5 -k https://localhost/; then
        touch /var/lib/cloud/instance/grove-ready
        break
      fi
      sleep 5
    done
