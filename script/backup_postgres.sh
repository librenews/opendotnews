#!/usr/bin/env bash
# Automated PostgreSQL backup script for Open.News (Kamal 2 / Docker VPS).
# Creates a custom-format pg_dump + SHA-256 checksum and optionally uploads off-host
# via rclone (S3, Backblaze B2, Cloudflare R2, DigitalOcean Spaces) or AWS CLI.
#
# Example cron entry (daily at 03:30 UTC):
#   30 3 * * * BACKUP_REMOTE="s3:open-news-backups/postgres" /opt/opendotnews/backup_postgres.sh >> /var/log/opendotnews-backup.log 2>&1

set -euo pipefail

CONTAINER="${POSTGRES_CONTAINER:-opendotnews-postgres}"
PG_USER="${POSTGRES_USER:-opendotnews}"
PG_DB="${POSTGRES_DB:-opendotnews_production}"
BACKUP_DIR="${BACKUP_DIR:-/var/lib/opendotnews/backups}"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"
BACKUP_REMOTE="${BACKUP_REMOTE:-}" # e.g. "r2:open-news-backups/postgres" (rclone) or "s3://bucket/prefix" (aws cli)

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
FILENAME="${PG_DB}_${TIMESTAMP}.dump"
FILEPATH="${BACKUP_DIR}/${FILENAME}"

mkdir -p "${BACKUP_DIR}"
chmod 700 "${BACKUP_DIR}"

echo "[$(date -u +%FT%TZ)] Starting pg_dump from container ${CONTAINER} (${PG_DB})..."
docker exec "${CONTAINER}" pg_dump -U "${PG_USER}" -Fc --no-owner --no-acl "${PG_DB}" > "${FILEPATH}.tmp"
mv "${FILEPATH}.tmp" "${FILEPATH}"
chmod 600 "${FILEPATH}"

sha256sum "${FILEPATH}" > "${FILEPATH}.sha256"
echo "[$(date -u +%FT%TZ)] Created ${FILEPATH} ($(du -h "${FILEPATH}" | cut -f1))"

if [[ -n "${BACKUP_REMOTE}" ]]; then
  if [[ "${BACKUP_REMOTE}" == s3://* ]]; then
    echo "[$(date -u +%FT%TZ)] Uploading to ${BACKUP_REMOTE} via aws s3..."
    aws s3 cp "${FILEPATH}" "${BACKUP_REMOTE}/${FILENAME}" --only-show-errors
    aws s3 cp "${FILEPATH}.sha256" "${BACKUP_REMOTE}/${FILENAME}.sha256" --only-show-errors
  else
    echo "[$(date -u +%FT%TZ)] Uploading to ${BACKUP_REMOTE} via rclone..."
    rclone copyto "${FILEPATH}" "${BACKUP_REMOTE}/${FILENAME}"
    rclone copyto "${FILEPATH}.sha256" "${BACKUP_REMOTE}/${FILENAME}.sha256"
  fi
  echo "[$(date -u +%FT%TZ)] Off-host upload complete."
else
  echo "[$(date -u +%FT%TZ)] WARNING: BACKUP_REMOTE not set; backup stored locally only."
fi

# Prune local backups older than RETENTION_DAYS
find "${BACKUP_DIR}" -type f \( -name "${PG_DB}_*.dump" -o -name "${PG_DB}_*.dump.sha256" \) -mtime "+${RETENTION_DAYS}" -delete
echo "[$(date -u +%FT%TZ)] Backup finished cleanly."
