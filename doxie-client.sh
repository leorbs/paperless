#!/bin/sh
# Doxie scanner client.
#
# Periodically checks a Doxie Q / Doxie Go SE Wi-Fi scanner for new scans,
# downloads them into the paperless consume directory and then deletes them
# from the scanner (via the bulk-delete endpoint).
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
#   CONSUME_DIR              directory scans are placed in (default /consume)
#   CONSUME_OWNER            uid:gid given to downloaded files (default 999:995)
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

BASE="http://${DOXIE_IP}"
AUTH=0

mkdir -p "$CONSUME_DIR"

log() { echo "[$(date -Is)] $*"; }

# GET an API endpoint, printing the body on stdout. Auth-aware; transport
# errors are silenced so offline periods don't spam the log.
api_get() {
  if [ "$AUTH" -eq 1 ]; then
    curl -s --connect-timeout "$PROBE_TIMEOUT" -m "$PROBE_TIMEOUT" \
      -u "doxie:${DOXIE_PASSWORD}" "$1" 2>/dev/null
  else
    curl -s --connect-timeout "$PROBE_TIMEOUT" -m "$PROBE_TIMEOUT" \
      "$1" 2>/dev/null
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
  : > "$paths_file"
  : > "$done_file"

  printf '%s\n' "$scans" | jq -r '.[]?.name // empty' > "$paths_file" 2>/dev/null

  if [ ! -s "$paths_file" ]; then
    log "no new scans; sleeping ${POLL_INTERVAL}s"
    sleep "$POLL_INTERVAL"
    continue
  fi

  total=$(wc -l < "$paths_file" | tr -d ' ')
  log "found ${total} scan(s); downloading"

  while IFS= read -r path; do
    [ -z "$path" ] && continue

    name=$(basename "$path")
    tmp="${CONSUME_DIR}/.doxie-ingest-${name}"
    dest="${CONSUME_DIR}/${name}"

    # Never overwrite an existing file in the consume dir.
    if [ -e "$dest" ]; then
      dest="${CONSUME_DIR}/$(date +%Y%m%dT%H%M%S)-${name}"
    fi

    if download "$BASE/scans$path" "$tmp"; then
      # Let paperless read and remove the file (see CONSUME_OWNER).
      chown "$CONSUME_OWNER" "$tmp" 2>/dev/null || true
      mv "$tmp" "$dest"
      log "downloaded ${name}"
      printf '%s\n' "$path" >> "$done_file"
    else
      rm -f "$tmp"
      log "download failed for ${name}; leaving it on the scanner"
    fi
  done < "$paths_file"

  # --- delete successfully downloaded scans from the scanner ---------------
  if [ -s "$done_file" ]; then
    jq -Rn '[inputs]' "$done_file" > /tmp/doxie-delete.json 2>/dev/null
    if [ -s /tmp/doxie-delete.json ]; then
      if [ "$AUTH" -eq 1 ]; then
        curl -s --connect-timeout "$PROBE_TIMEOUT" -m "$PROBE_TIMEOUT" \
          -u "doxie:${DOXIE_PASSWORD}" \
          -X POST -H 'Content-Type: application/json' \
          --data-binary @/tmp/doxie-delete.json \
          "$BASE/scans/delete.json" >/dev/null 2>&1 || log "bulk delete failed"
      else
        curl -s --connect-timeout "$PROBE_TIMEOUT" -m "$PROBE_TIMEOUT" \
          -X POST -H 'Content-Type: application/json' \
          --data-binary @/tmp/doxie-delete.json \
          "$BASE/scans/delete.json" >/dev/null 2>&1 || log "bulk delete failed"
      fi
      log "deleted $(wc -l < "$done_file" | tr -d ' ') scan(s) from doxie"
    fi
  fi

  sleep "$POLL_INTERVAL"
done
