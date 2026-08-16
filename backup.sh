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
borg create --stats --compression zstd "$BORG_REPO::{now:%Y-%m-%d_%H-%M}" /export

echo "[$(date -Is)] borg prune"
borg prune --keep-daily=7 --keep-weekly=4 --keep-monthly=6 "$BORG_REPO"

echo "[$(date -Is)] done"
