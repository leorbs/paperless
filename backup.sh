#!/bin/sh
# Nightly paperless backup, run from cron inside the `backup` sidecar
# (see docker-compose.paperless.yml). Two steps:
#   1. Ask the running paperless container to refresh its document-exporter
#      snapshot (a full, re-importable copy of documents + metadata).
#   2. Push that snapshot to the Storage Box with borg.
# Database backup is intentionally skipped — the export IS the backup;
# paperless can rebuild its database from an export via document_importer.
set -e

echo "[$(date -Is)] exporting documents from paperless"
docker exec "$EXPORT_CONTAINER" document_exporter ../export --no-progress-bar -d

echo "[$(date -Is)] checking backup repo"
borg info "$BORG_REPO" >/dev/null 2>&1 || borg init --encryption=repokey-blake2 "$BORG_REPO"

echo "[$(date -Is)] borg create"
BORG_STATS=$(borg create --stats --compression zstd "$BORG_REPO::{now:%Y-%m-%d_%H-%M}" /export 2>&1)
printf '%s\n' "$BORG_STATS"

echo "[$(date -Is)] borg prune"
borg prune --keep-daily=7 --keep-weekly=4 --keep-monthly=6 "$BORG_REPO"

echo "[$(date -Is)] done"

# Stamp a canary file so the health endpoint can report UP. Only reached
# when the whole run succeeded (set -e above). Format:
#   line 1: ISO-8601 date of this successful run
#   line 2: same instant as unix epoch (for cheap age checks)
#   line 3: size of the exported snapshot, in KiB
#   line 4+: borg create --stats output (metadata for the health endpoint)
HEALTH_DIR="${HEALTH_DIR:-/health}"
mkdir -p "$HEALTH_DIR"
{
  date -Is
  date +%s
  du -sk /export | cut -f1
  printf '%s\n' "$BORG_STATS"
} > "$HEALTH_DIR/last-backup.tmp"
mv "$HEALTH_DIR/last-backup.tmp" "$HEALTH_DIR/last-backup"
