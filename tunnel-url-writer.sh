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
# A Realtime Database secret. The shipped firebase-rules.json allows anonymous
# reads but requires `auth != null` to write, so publishing the URL needs this:
# the PUT below is sent with "?auth=<secret>" once it is set. The secret is also
# the fallback if the database is switched back to ".write": false.
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
            # Only once: this is retried on every poll, and repeating the same
            # six lines every ${POLL_INTERVAL}s buries everything else in the log.
            if [ "${auth_hint_shown}" -eq 0 ]; then
                auth_hint_shown=1
                log "Firebase refused the write (HTTP ${status}) — ${FIREBASE_TUNNEL_PATH} is read-only for this request."
                if [ -z "${FIREBASE_DB_SECRET}" ]; then
                    log "  No credential was supplied. firebase-rules.json reads \"auth != null\" for writes, so set"
                    log "  FIREBASE_DB_SECRET to a database secret (Firebase console -> Project settings ->"
                    log "  Service accounts -> Database secrets) and restart the service."
                else
                    log "  A credential was supplied but rejected — FIREBASE_DB_SECRET is wrong, revoked, or not"
                    log "  a Realtime Database secret."
                fi
                log "  This is not fatal: the URL is still on the [tunnel] line above and in /run/tunnel-url."
                log "  Only the Firebase lookup goes stale."
            fi
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
auth_hint_shown=0
mirror_warned=0

while true; do
    url="$(fetch_public_url)"

    if [ -z "${url}" ]; then
        sleep "${POLL_INTERVAL}"
        continue
    fi

    now="$(date +%s)"

    if [ "${url}" != "${last_url}" ]; then
        log "ngrok public URL: ${url}"
        # Mirror for `cat /run/tunnel-url` inside the container. root owns /run,
        # so this only fails if the image changed the layout — say so once
        # rather than claiming the file is there when it is not.
        # Subshell: a redirection failure is reported by bash itself, so the
        # 2>/dev/null only takes effect if it applies to the whole command.
        if ! ( printf '%s\n' "${url}" >/run/tunnel-url ) 2>/dev/null; then
            if [ "${mirror_warned}" -eq 0 ]; then
                mirror_warned=1
                log "  note: cannot write /run/tunnel-url (not root?); read the URL from the line above"
            fi
        fi
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
