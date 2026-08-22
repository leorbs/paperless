#!/bin/sh
# Doxie scanner client.
#
# Periodically checks a Doxie Q / Doxie Go SE Wi-Fi scanner for new scans,
# downloads them, preprocesses the images (see `preprocess`) and drops the
# results into the paperless consume directory, then deletes the originals
# from the scanner via the bulk-delete endpoint.
#
# File types:
#   * JPG/JPEG -> normalized with ImageMagick: 300 dpi kept as-is, 600 dpi
#                 downscaled to 300 dpi (white-balance, level, sharpen).
#                 The output stays a JPEG.
#   * PDF      -> passed straight through to paperless (no preprocessing).
#
# The container runs as root and chowns each file it drops into the consume
# dir to CONSUME_OWNER (paperless' uid:gid) so paperless can read and delete
# them.
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
export DPI_THRESHOLD="${DPI_THRESHOLD:-300}"

BASE="http://${DOXIE_IP}"
AUTH=0

mkdir -p "$CONSUME_DIR" 2>/dev/null || true

log() { echo "[$(date -Is)] $*"; }

# Lower-case a string (busybox-safe).
lower() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }

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

  idx=0
  while IFS= read -r path; do
    [ -z "$path" ] && continue
    idx=$((idx + 1))

    name=$(basename "$path")
    ext=$(lower "${name##*.}")
    stem="${name%.*}"

    case "$ext" in
      jpg|jpeg) out_name="$(lower "$stem").jpg" ;;
      *)        out_name="$name" ;;
    esac

    # Stage in the consume dir on the same filesystem so the final `mv` is an
    # atomic rename. The leading dot keeps paperless from picking up partial
    # files while we work.
    tmp="${CONSUME_DIR}/.doxie-ingest-${stem}.partial"
    processed="${CONSUME_DIR}/.doxie-ingest-${stem}.jpg"

    # Unique destination: Doxie reuses IMG_xxxx names (and the lowest free
    # number), so always prefix with a timestamp + running index.
    stamp=$(date +%Y%m%dT%H%M%S)
    dest="${CONSUME_DIR}/${stamp}-${idx}-${out_name}"
    while [ -e "$dest" ]; do
      idx=$((idx + 1))
      dest="${CONSUME_DIR}/${stamp}-${idx}-${out_name}"
    done

    ok=0
    case "$ext" in
      jpg|jpeg)
        if download "$BASE/scans$path" "$tmp"; then
          if preprocess "$tmp" "$processed"; then
            rm -f "$tmp"
            chown "$CONSUME_OWNER" "$processed" 2>/dev/null || true
            mv "$processed" "$dest"
            ok=1
            log "processed ${name} -> ${out_name}"
          else
            rm -f "$tmp" "$processed"
            log "preprocessing failed for ${name}; leaving it on the scanner"
          fi
        else
          rm -f "$tmp"
          log "download failed for ${name}; leaving it on the scanner"
        fi
        ;;
      *)
        # PDF (and anything else): pass through untouched.
        if download "$BASE/scans$path" "$tmp"; then
          chown "$CONSUME_OWNER" "$tmp" 2>/dev/null || true
          mv "$tmp" "$dest"
          ok=1
          log "downloaded ${name}"
        else
          rm -f "$tmp"
          log "download failed for ${name}; leaving it on the scanner"
        fi
        ;;
    esac

    [ "$ok" -eq 1 ] && printf '%s\n' "$path" >> "$done_file"
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
