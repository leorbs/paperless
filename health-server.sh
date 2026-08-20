#!/bin/sh
# Health endpoint for the paperless backup sidecar.
#
# Run per-connection by busybox `nc -lk -p 1337 -e ...`; the socket is
# stdin/stdout. It reads the request, then answers with a small, generic
# "job health" JSON document in Spring Boot Actuator style (a top-level
# status plus a `components` map keyed by job name):
#
#   {
#     "status": "UP",
#     "components": {
#       "paperless-backup": {
#         "status": "UP",
#         "details": {
#           "lastSuccess": "2026-08-20T03:00:01+02:00",
#           "ageSeconds": 12,
#           "sizeKb": 123456,
#           "borgStats": "..."
#         }
#       }
#     }
#   }
#
# UP means the canary file stamped by the last successful backup.sh run
# exists and is younger than HEALTH_MAX_AGE_SECONDS.

HEALTH_DIR="${HEALTH_DIR:-/health}"
CANARY="$HEALTH_DIR/last-backup"
JOB_NAME="${HEALTH_JOB_NAME:-paperless-backup}"
MAX_AGE="${HEALTH_MAX_AGE_SECONDS:-93600}"   # 26h; backup runs daily at 03:00

cr=$(printf '\r')

# Consume the incoming request (request line + headers) so the client has
# finished sending before we write the response.
IFS= read -r _request || exit 0
while IFS= read -r _line || break; do
  _line="${_line%"$cr"}"
  [ -z "$_line" ] && break
done

# --- evaluate the canary file ------------------------------------------------
up=0
reason=""
last_iso=""
last_epoch=""
size_kb=""
stats=""
age=""

if [ -f "$CANARY" ]; then
  exec 3<"$CANARY"
  IFS= read -r last_iso <&3 || true
  IFS= read -r last_epoch <&3 || true
  IFS= read -r size_kb <&3 || true
  sep=""
  while IFS= read -r line <&3; do
    esc=$(printf '%s' "$line" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
    stats="${stats}${sep}${esc}"
    sep='\n'
  done
  exec 3<&-

  case "$last_epoch" in
    ''|*[!0-9]*) last_epoch="" ;;
  esac
  case "$size_kb" in
    ''|*[!0-9]*) size_kb="" ;;
  esac

  if [ -n "$last_epoch" ]; then
    now_epoch=$(date +%s)
    age=$(( now_epoch - last_epoch ))
    if [ "$age" -le "$MAX_AGE" ]; then
      up=1
    else
      reason="last successful backup is older than ${MAX_AGE}s"
    fi
  else
    reason="canary file is malformed"
  fi
else
  reason="no successful backup recorded yet"
fi

# JSON-encode the ISO date (or null) once.
last_iso_json="null"
[ -n "$last_iso" ] && last_iso_json="\"$last_iso\""

[ -n "$size_kb" ] || size_kb="null"

# --- emit the response -------------------------------------------------------
# Spring Boot Actuator-style payload: a top-level status plus a
# `components` map keyed by job name, so it's easy to parse with the same
# tooling that reads /actuator/health.
if [ "$up" -eq 1 ]; then
  code="200 OK"
  body=$(printf '{"status":"UP","components":{"%s":{"status":"UP","details":{"lastSuccess":%s,"ageSeconds":%s,"sizeKb":%s,"borgStats":"%s"}}}}' \
    "$JOB_NAME" "$last_iso_json" "$age" "$size_kb" "$stats")
else
  code="503 Service Unavailable"
  body=$(printf '{"status":"DOWN","components":{"%s":{"status":"DOWN","details":{"lastSuccess":%s,"reason":"%s"}}}}' \
    "$JOB_NAME" "$last_iso_json" "$reason")
fi

length=${#body}

printf 'HTTP/1.1 %s\r\nContent-Type: application/json\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s' \
  "$code" "$length" "$body"
