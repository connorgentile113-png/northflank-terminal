#!/usr/bin/env bash
# =============================================================================
#  tunnel-url-writer.sh — server-side only.
#
#  1. polls the ngrok agent's local API (http://localhost:4040/api/tunnels)
#  2. extracts the public https URL of the tunnel
#  3. PUTs it to the Firebase Realtime Database with plain curl:
#
#        curl -X PUT \
#          "https://vps-server-2bcbd-default-rtdb.firebaseio.com/tunnel/url.json" \
#          -d '"https://xxxx.ngrok-free.app"'
#
#  No Firebase JS SDK, no CLI, no browser involvement — just a JSON PUT. The
#  URL is also mirrored to /run/tunnel-url so it can be read from the terminal:
#
#        cat /run/tunnel-url
# =============================================================================
set -uo pipefail

NGROK_API="${NGROK_API:-http://127.0.0.1:4040/api/tunnels}"
FIREBASE_DATABASE_URL="${FIREBASE_DATABASE_URL:-https://vps-server-2bcbd-default-rtdb.firebaseio.com}"
FIREBASE_TUNNEL_PATH="${FIREBASE_TUNNEL_PATH:-/tunnel/url.json}"
# Optional: a Realtime Database secret, for when the rules are tightened from
# "open mode" to ".write": false / authenticated writes.
FIREBASE_DB_SECRET="${FIREBASE_DB_SECRET:-}"
POLL_INTERVAL="${TUNNEL_POLL_INTERVAL:-20}"
REFRESH_INTERVAL="${TUNNEL_REFRESH_INTERVAL:-600}"
CURL_TIMEOUT="${TUNNEL_CURL_TIMEOUT:-15}"

log() { printf '[tunnel] %s %s\n' "$(date -u +%FT%TZ)" "$*"; }

# --- helpers -----------------------------------------------------------------
firebase_endpoint() {
    local base="${FIREBASE_DATABASE_URL%/}" path="${FIREBASE_TUNNEL_PATH}"
    case "${path}" in /*) ;; *) path="/${path}" ;; esac
    case "${path}" in *.json) ;; *) path="${path}.json" ;; esac
    printf '%s%s' "${base}" "${path}"
}

# Prints the public https URL of the tunnel, or nothing while ngrok is starting.
fetch_public_url() {
    curl -fsS -m "${CURL_TIMEOUT}" "${NGROK_API}" 2>/dev/null | python3 -c '
import json, sys

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)

tunnels = data.get("tunnels") or []

def pick(proto):
    for tunnel in tunnels:
        url = tunnel.get("public_url") or ""
        if tunnel.get("proto") == proto and url.startswith(proto + "://"):
            return url
    return ""

print(pick("https") or pick("http"))' 2>/dev/null || true
}

publish() {
    local url="$1" endpoint status
    endpoint="$(firebase_endpoint)"
    if [ -n "${FIREBASE_DB_SECRET}" ]; then
        endpoint="${endpoint}?auth=${FIREBASE_DB_SECRET}"
    fi

    status="$(curl -sS -m "${CURL_TIMEOUT}" -o /tmp/fb-write.body -w '%{http_code}' \
        -X PUT -H 'Content-Type: application/json' \
        -d "\"${url}\"" "${endpoint}" 2>/tmp/fb-write.err || echo 000)"

    case "${status}" in
        200|204)
            log "published ${url} -> ${FIREBASE_DATABASE_URL}${FIREBASE_TUNNEL_PATH}"
            rm -f /tmp/fb-write.body /tmp/fb-write.err
            return 0
            ;;
        401|403)
            log "Firebase refused the write (HTTP ${status}) — the rules are locked to read-only."
            log "  Fix: keep ${FIREBASE_TUNNEL_PATH} writable in the database rules (see firebase-rules.json),"
            log "  or set FIREBASE_DB_SECRET to a database secret so the PUT authenticates."
            ;;
        000)
            log "Firebase unreachable (curl: $(tr -d '\n' < /tmp/fb-write.err 2>/dev/null | tail -c 200))"
            ;;
        *)
            log "Firebase write failed (HTTP ${status}) $(tr -d '\n' < /tmp/fb-write.body 2>/dev/null | head -c 200)"
            ;;
    esac
    rm -f /tmp/fb-write.body /tmp/fb-write.err
    return 1
}

# --- main loop ----------------------------------------------------------------
log "watching ${NGROK_API}"
log "publishing to $(firebase_endpoint)"

last_url=""
last_publish=0

while true; do
    url="$(fetch_public_url)"

    if [ -z "${url}" ]; then
        sleep "${POLL_INTERVAL}"
        continue
    fi

    now="$(date +%s)"

    if [ "${url}" != "${last_url}" ]; then
        log "ngrok public URL: ${url}"
        printf '%s\n' "${url}" >/run/tunnel-url 2>/dev/null || true
        if publish "${url}"; then
            last_url="${url}"
            last_publish="${now}"
        fi
    elif [ "$(( now - last_publish ))" -ge "${REFRESH_INTERVAL}" ]; then
        # Re-publish periodically: databases get reset, and a deleted key means
        # the browser-side lookup would go blank.
        if publish "${url}"; then
            last_publish="${now}"
        else
            last_url=""
        fi
    fi

    sleep "${POLL_INTERVAL}"
done
