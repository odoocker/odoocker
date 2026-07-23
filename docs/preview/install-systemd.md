# Install sanitize cron on prod droplet

Run as root on the prod droplet.

```bash
mkdir -p /opt/grove/scripts /etc/grove
cp scripts/preview/sanitize_dump.py        /opt/grove/scripts/
cp scripts/preview/sanitize-and-upload.sh  /opt/grove/scripts/
chmod +x /opt/grove/scripts/sanitize-and-upload.sh

# Write /etc/grove/sanitize.env (chmod 600); template:
cat > /etc/grove/sanitize.env <<'EOF'
PG_HOST=postgres
PG_PORT=5432
PG_USER=odoo
PG_PASSWORD=<from existing odoocker .env>
PG_DB=grove_production
FILESTORE_PATH=/var/lib/odoo/filestore/grove_production
SPACES_ENDPOINT=https://nyc3.digitaloceanspaces.com
SPACES_BUCKET=grove-preview-data
SPACES_ACCESS_KEY=<from P2>
SPACES_SECRET_KEY=<from P2>
SLACK_OPS_WEBHOOK=<from P6>
EOF
chmod 600 /etc/grove/sanitize.env

cp systemd/grove-sanitize.service /etc/systemd/system/
cp systemd/grove-sanitize.timer   /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now grove-sanitize.timer
systemctl list-timers grove-sanitize.timer
```

Verify next-run time. Manually trigger once with `systemctl start grove-sanitize.service` and tail `journalctl -u grove-sanitize -f`.

The `<...>` placeholders correspond to pre-flight steps P1–P6 in `docs/superpowers/plans/2026-06-01-grove-preview-environments.md`.
