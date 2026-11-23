#!/usr/bin/env bash
# PostgreSQL restore script for Open.News (Kamal 2 / Docker VPS).
# Verifies SHA-256 checksum (if .sha256 exists) and restores a custom-format dump.
#
# Usage:
#   Restore drill into a scratch DB (safe on live server):
#     TARGET_DB=opendotnews_restore_drill ./script/restore_postgres.sh /var/lib/opendotnews/backups/opendotnews_production_20261123T033000Z.dump
#
#   Full production restore (stop web & worker containers first!):
#     CONFIRM_PRODUCTION_RESTORE=yes ./script/restore_postgres.sh /path/to/backup.dump

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 /path/to/backup.dump" >&2
  exit 1
fi

DUMP_FILE="$1"
CONTAINER="${POSTGRES_CONTAINER:-opendotnews-postgres}"
PG_USER="${POSTGRES_USER:-opendotnews}"
TARGET_DB="${TARGET_DB:-opendotnews_production}"

if [[ ! -f "${DUMP_FILE}" ]]; then
  echo "Error: dump file not found: ${DUMP_FILE}" >&2
  exit 1
fi

if [[ -f "${DUMP_FILE}.sha256" ]]; then
  echo "Verifying SHA-256 checksum..."
  (cd "$(dirname "${DUMP_FILE}")" && sha256sum -c "$(basename "${DUMP_FILE}.sha256")")
fi

if [[ "${TARGET_DB}" == "opendotnews_production" && "${CONFIRM_PRODUCTION_RESTORE:-}" != "yes" ]]; then
  echo "Refusing to overwrite opendotnews_production without CONFIRM_PRODUCTION_RESTORE=yes." >&2
  echo "Stop web/worker containers first, or pass TARGET_DB=opendotnews_restore_drill for a safe drill." >&2
  exit 1
fi

echo "Ensuring target database ${TARGET_DB} exists..."
docker exec "${CONTAINER}" psql -U "${PG_USER}" -d postgres -tc "SELECT 1 FROM pg_database WHERE datname = '${TARGET_DB}'" | grep -q 1 \
  || docker exec "${CONTAINER}" createdb -U "${PG_USER}" "${TARGET_DB}"

echo "Restoring ${DUMP_FILE} into ${TARGET_DB}..."
docker exec -i "${CONTAINER}" pg_restore \
  -U "${PG_USER}" \
  -d "${TARGET_DB}" \
  --clean \
  --if-exists \
  --no-owner \
  --no-acl \
  --exit-on-error < "${DUMP_FILE}"

echo "Verifying restored row counts:"
docker exec "${CONTAINER}" psql -U "${PG_USER}" -d "${TARGET_DB}" -c \
  "SELECT 'users' AS tbl, count(*) FROM users
   UNION ALL SELECT 'feeds', count(*) FROM feeds
   UNION ALL SELECT 'feed_items', count(*) FROM feed_items
   UNION ALL SELECT 'user_feed_subscriptions', count(*) FROM user_feed_subscriptions
   UNION ALL SELECT 'user_inbox_events', count(*) FROM user_inbox_events;"

echo "Restore into ${TARGET_DB} completed successfully."
