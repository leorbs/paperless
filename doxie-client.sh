#!/bin/sh
# Doxie scanner client.
#
# Periodically polls a Doxie Q / Doxie Go SE Wi-Fi scanner for new scans,
# downloads them into a private work dir, preprocesses the images (see
# `preprocess`) and drops the finished files into the paperless consume dir,
# then deletes the originals from the scanner via the bulk-delete endpoint.
#
# File types:
#   * JPG/JPEG -> normalized with ImageMagick: 300 dpi kept as-is, 600 dpi
#                 downscaled to 300 dpi (white-balance, level, sharpen).
#                 The output is wrapped in a single-page PDF.
#   * PDF      -> passed straight through to paperless (no preprocessing).
#
# All downloading and preprocessing happens in WORK_DIR, so the consume dir
# only ever receives complete, finished files. The container runs as root and
# chowns each finished file to CONSUME_OWNER (paperless' uid:gid) so paperless
# can read and delete it.
#
# Energy efficiency:
#   * Every probe request carries a very short timeout, so the container only
#     wakes for a moment to check whether the scanner is reachable.
#   * Between polls the process does nothing but `sleep`.
#
# Environment variables:
#   DOXIE_IP                 scanner address (default 10.10.100.1 = AP mode)
#   DOXIE_POLL_INTERVAL      seconds between polls (default 300)
#   DOXIE_PASSWORD           scanner password, only needed if auth is enabled
#   DOXIE_TIMEOUT            seconds allowed per probe request (default 3)
#   DOXIE_DOWNLOAD_TIMEOUT   seconds allowed per scan download (default 120)
#   CONSUME_DIR              directory finished scans are placed in (default /consume)
#   CONSUME_OWNER            uid:gid given to finished files (default 999:995)
#   WORK_DIR                 private staging directory (default /tmp/doxie)
#   DPI_THRESHOLD            dpi above which JPGs are downscaled (default 300)
#
# Auth is detected from /hello.json: if hasPassword is true, all further
# requests use HTTP Basic auth with username "doxie".

set -u

DOXIE_IP="${DOXIE_IP:-10.10.100.1}"
POLL_INTERVAL="${DOXIE_POLL_INTERVAL:-300}"
DOXIE_PASSWORD="${DOXIE_PASSWORD:-}"
PROBE_TIMEOUT="${DOXIE_TIMEOUT:-3}"
DOWNLOAD_TIMEOUT="${DOXIE_DOWNLOAD_TIMEOUT:-120}"
CONSUME_DIR="${CONSUME_DIR:-/consume}"
CONSUME_OWNER="${CONSUME_OWNER:-999:995}"
WORK_DIR="${WORK_DIR:-/tmp/doxie}"
export DPI_THRESHOLD="${DPI_THRESHOLD:-300}"

BASE="http://${DOXIE_IP}"
AUTH=0

mkdir -p "$CONSUME_DIR" "$WORK_DIR" 2>/dev/null || true

log() { echo "[$(date -Is)] $*"; }

lower() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }

# GET an API endpoint, printing the body on stdout. Auth-aware; transport
# errors are silenced so offline periods don't spam the log.
api_get() {
  if [ "$AUTH" -eq 1 ]; then
    curl -s --connect-timeout "$PROBE_TIMEOUT" -m "$PROBE_TIMEOUT" \
      -u "doxie:${DOXIE_PASSWORD}" "$1" 2>/dev/null
  else
    curl -s --connect-timeout "$PROBE_TIMEOUT" -m "$PROBE_TIMEOUT" "$1" 2>/dev/null
  fi
}

# Download a scan file (auth-aware).
download() {
  if [ "$AUTH" -eq 1 ]; then
    curl -sS --connect-timeout 5 -m "$DOWNLOAD_TIMEOUT" \
      -u "doxie:${DOXIE_PASSWORD}" "$1" -o "$2"
  else
    curl -sS --connect-timeout 5 -m "$DOWNLOAD_TIMEOUT" "$1" -o "$2"
  fi
}

# POST a JSON body read from a file (auth-aware), silencing the response.
api_post() {
  if [ "$AUTH" -eq 1 ]; then
    curl -s --connect-timeout "$PROBE_TIMEOUT" -m "$PROBE_TIMEOUT" \
      -u "doxie:${DOXIE_PASSWORD}" -X POST -H 'Content-Type: application/json' \
      --data-binary @"$1" "$2"
  else
    curl -s --connect-timeout "$PROBE_TIMEOUT" -m "$PROBE_TIMEOUT" \
      -X POST -H 'Content-Type: application/json' \
      --data-binary @"$1" "$2"
  fi
}

# Fetch one scan, preprocess images, and move the finished file into the
# consume dir. Returns 0 on success so the caller can mark it for deletion.
ingest() {
  local path name ext stem raw out final final_name

  path="$1"
  name=$(basename "$path")
  ext=$(lower "${name##*.}")
  stem="${name%.*}"

  case "$ext" in
    jpg|jpeg)
      final_name="$(lower "$stem").pdf"
      raw="$WORK_DIR/${stem}.jpg"
      ;;
    *)
      final_name="$name"
      raw="$WORK_DIR/${stem}.download"
      ;;
  esac

  final="$CONSUME_DIR/$(date +%Y%m%dT%H%M%S)-${final_name}"

  if ! download "$BASE/scans$path" "$raw"; then
    rm -f "$raw"
    log "download failed for ${name}; leaving it on the scanner"
    return 1
  fi

  if [ "$ext" = "jpg" ] || [ "$ext" = "jpeg" ]; then
    out="$WORK_DIR/${stem}.processed.pdf"
    if ! preprocess "$raw" "$out"; then
      rm -f "$raw" "$out"
      log "preprocessing failed for ${name}; leaving it on the scanner"
      return 1
    fi
    rm -f "$raw"
    mv "$out" "$final"
    log "processed ${name} -> ${final_name}"
  else
    # PDF (and anything else): pass through untouched.
    mv "$raw" "$final"
    log "downloaded ${name}"
  fi

  chown "$CONSUME_OWNER" "$final" 2>/dev/null || true
  return 0
}

while :; do
  # --- probe: is the scanner there at all? --------------------------------
  hello=$(api_get "$BASE/hello.json")
  if [ -z "$hello" ]; then
    log "doxie not reachable at ${DOXIE_IP}; sleeping ${POLL_INTERVAL}s"
    sleep "$POLL_INTERVAL"
    continue
  fi

  # --- decide whether to authenticate -------------------------------------
  if printf '%s' "$hello" | jq -e '.hasPassword == true' >/dev/null 2>&1; then
    AUTH=1
  else
    AUTH=0
  fi

  # --- list scans currently on the scanner --------------------------------
  scans=$(api_get "$BASE/scans.json")
  if [ -z "$scans" ]; then
    log "scanner is up but returned no scan list (busy?); sleeping ${POLL_INTERVAL}s"
    sleep "$POLL_INTERVAL"
    continue
  fi

  paths_file=/tmp/doxie-paths
  done_file=/tmp/doxie-done
  printf '%s\n' "$scans" | jq -r '.[]?.name // empty' > "$paths_file" 2>/dev/null

  if [ ! -s "$paths_file" ]; then
    log "no new scans; sleeping ${POLL_INTERVAL}s"
    sleep "$POLL_INTERVAL"
    continue
  fi

  total=$(wc -l < "$paths_file" | tr -d ' ')
  log "found ${total} scan(s); downloading"

  : > "$done_file"
  while IFS= read -r path; do
    [ -z "$path" ] && continue
    if ingest "$path"; then
      printf '%s\n' "$path" >> "$done_file"
    fi
  done < "$paths_file"

  # --- delete successfully ingested scans from the scanner ----------------
  if [ -s "$done_file" ]; then
    jq -Rn '[inputs]' "$done_file" > /tmp/doxie-delete.json 2>/dev/null
    if [ -s /tmp/doxie-delete.json ]; then
      api_post /tmp/doxie-delete.json "$BASE/scans/delete.json" >/dev/null 2>&1 \
        || log "bulk delete failed"
      log "deleted $(wc -l < "$done_file" | tr -d ' ') scan(s) from doxie"
    fi
  fi

  sleep "$POLL_INTERVAL"
done
