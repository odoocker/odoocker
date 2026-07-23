#!/usr/bin/env bash
# Grove Preview — nightly sanitize-and-upload orchestrator.
# Runs on the prod droplet via systemd timer.
#
# Env (sourced from /etc/grove/sanitize.env):
#   PG_HOST, PG_PORT, PG_USER, PG_PASSWORD, PG_DB         — prod Postgres
#   FILESTORE_PATH                                        — /var/lib/odoo/filestore/<db>
#   SPACES_ACCESS_KEY, SPACES_SECRET_KEY                  — grove-preview-data RW creds
#   SPACES_ENDPOINT                                       — https://nyc3.digitaloceanspaces.com
#   SPACES_BUCKET                                         — grove-preview-data
#   SLACK_OPS_WEBHOOK                                     — failure notifications

set -euo pipefail
trap 'on_error $LINENO' ERR

on_error() {
  local line=$1
  # Audit fix SC2155 (2026-06-29): declare + assign separately so a hostname(1)
  # failure surfaces instead of being masked by `local`'s own success.
  local host msg
  host=$(hostname)
  msg="grove-sanitize FAILED at line ${line} on ${host}"
  echo "ERROR: ${msg}" >&2
  if [[ -n "${SLACK_OPS_WEBHOOK:-}" ]]; then
    curl -s -X POST -H 'Content-type: application/json' \
      --data "{\"text\":\":rotating_light: ${msg}\"}" \
      "$SLACK_OPS_WEBHOOK" || true
  fi
  exit 1
}

source /etc/grove/sanitize.env

DATE=$(date -u +%Y-%m-%d)
WORK=/var/tmp/grove-sanitize-${DATE}
mkdir -p "$WORK"
cd "$WORK"

echo "[1/5] pg_dump → sanitize → zstd"
PGPASSWORD="$PG_PASSWORD" pg_dump \
  -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" \
  --format=plain --no-owner --no-privileges \
  | python3 /opt/grove/scripts/sanitize_dump.py \
  | zstd -19 -T0 -o "snapshot-${DATE}.sql.zst"

echo "[2/5] tar + zstd filestore"
tar -C "$(dirname "$FILESTORE_PATH")" -cf - "$(basename "$FILESTORE_PATH")" \
  | zstd -19 -T0 -o "filestore-${DATE}.tar.zst"

echo "[3/5] upload snapshot"
AWS_ACCESS_KEY_ID="$SPACES_ACCESS_KEY" AWS_SECRET_ACCESS_KEY="$SPACES_SECRET_KEY" \
  aws --endpoint-url "$SPACES_ENDPOINT" s3 cp \
  "snapshot-${DATE}.sql.zst" \
  "s3://${SPACES_BUCKET}/snapshots/prod-sanitized-${DATE}.sql.zst" \
  --no-progress

echo "[4/5] upload filestore"
AWS_ACCESS_KEY_ID="$SPACES_ACCESS_KEY" AWS_SECRET_ACCESS_KEY="$SPACES_SECRET_KEY" \
  aws --endpoint-url "$SPACES_ENDPOINT" s3 cp \
  "filestore-${DATE}.tar.zst" \
  "s3://${SPACES_BUCKET}/filestore/prod-sanitized-${DATE}.tar.zst" \
  --no-progress

echo "[5/5] heartbeat + cleanup"
echo "$DATE" > heartbeat.txt
AWS_ACCESS_KEY_ID="$SPACES_ACCESS_KEY" AWS_SECRET_ACCESS_KEY="$SPACES_SECRET_KEY" \
  aws --endpoint-url "$SPACES_ENDPOINT" s3 cp \
  heartbeat.txt "s3://${SPACES_BUCKET}/heartbeat.txt" --no-progress

cd /
rm -rf "$WORK"

echo "grove-sanitize OK ${DATE}"
