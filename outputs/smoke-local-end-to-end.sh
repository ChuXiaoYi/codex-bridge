#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_DIR="$(mktemp -d)"
RELAY_PORT="${RELAY_PORT:-8798}"
BRIDGE_PORT="${BRIDGE_PORT:-8797}"
CLIENT_TOKEN="${RELAY_CLIENT_TOKEN:-client-smoke}"
BRIDGE_TOKEN="${RELAY_BRIDGE_TOKEN:-bridge-smoke}"
RELAY_URL="http://127.0.0.1:${RELAY_PORT}"
BRIDGE_URL="http://127.0.0.1:${BRIDGE_PORT}"
EVENT_LOG="$TMP_DIR/events.log"
RELAY_PID=""
HOME_PID=""
EVENT_PID=""

cleanup() {
  if [[ -n "$EVENT_PID" ]]; then
    kill "$EVENT_PID" >/dev/null 2>&1 || true
    wait "$EVENT_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$HOME_PID" ]]; then
    kill "$HOME_PID" >/dev/null 2>&1 || true
    wait "$HOME_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$RELAY_PID" ]]; then
    kill "$RELAY_PID" >/dev/null 2>&1 || true
    wait "$RELAY_PID" >/dev/null 2>&1 || true
  fi
  if [[ "${KEEP_SMOKE_LOGS:-0}" != "1" ]]; then
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT INT TERM

wait_for_url() {
  local url="$1"
  local header="${2:-}"
  for _ in $(seq 1 80); do
    if [[ -n "$HOME_PID" ]] && ! kill -0 "$HOME_PID" >/dev/null 2>&1; then
      echo "Home Mac process exited while waiting for $url." >&2
      echo "Logs kept in $TMP_DIR" >&2
      KEEP_SMOKE_LOGS=1
      return 1
    fi
    if [[ -n "$header" ]]; then
      if curl --max-time 5 -fsS -H "$header" "$url" >/dev/null 2>&1; then
        return 0
      fi
    elif curl --max-time 5 -fsS "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.25
  done
  echo "Timed out waiting for $url" >&2
  return 1
}

echo "Starting local Relay on $RELAY_URL"
RELAY_CLIENT_TOKEN="$CLIENT_TOKEN" \
RELAY_BRIDGE_TOKEN="$BRIDGE_TOKEN" \
RELAY_HOST=127.0.0.1 \
RELAY_PORT="$RELAY_PORT" \
"$ROOT_DIR/relay/start-relay.sh" >"$TMP_DIR/relay.log" 2>&1 &
RELAY_PID=$!
wait_for_url "$RELAY_URL/health"

echo "Starting Home Mac Bridge and connector on $BRIDGE_URL"
RELAY_URL="$RELAY_URL" \
RELAY_BRIDGE_TOKEN="$BRIDGE_TOKEN" \
BRIDGE_PORT="$BRIDGE_PORT" \
"$ROOT_DIR/home-mac-bridge/start-home-mac.sh" >"$TMP_DIR/home-mac.log" 2>&1 &
HOME_PID=$!
wait_for_url "$BRIDGE_URL/health"

curl -fsS -N -H "authorization: Bearer $CLIENT_TOKEN" "$RELAY_URL/events" >"$EVENT_LOG" 2>/dev/null &
EVENT_PID=$!

echo "Checking /threads through Relay"
wait_for_url "$RELAY_URL/threads?limit=1" "authorization: Bearer $CLIENT_TOKEN"

echo "Checking completion notification event"
curl -fsS -X POST \
  -H "authorization: Bearer $CLIENT_TOKEN" \
  -H "content-type: application/json" \
  -d '{"token":"fake-device-token","platform":"ios"}' \
  "$RELAY_URL/devices" >/dev/null
curl -fsS -X POST \
  -H "authorization: Bearer $BRIDGE_TOKEN" \
  -H "content-type: application/json" \
  -d '{"type":"turn/completed","threadId":"thread-smoke","turnId":"turn-smoke","summary":"Smoke turn finished"}' \
  "$RELAY_URL/bridge/events" >/dev/null
sleep 0.8

if ! grep -q '"type":"notification_ready"' "$EVENT_LOG"; then
  echo "Did not observe notification_ready in Relay events." >&2
  echo "Relay log: $TMP_DIR/relay.log" >&2
  echo "Home Mac log: $TMP_DIR/home-mac.log" >&2
  exit 1
fi

echo "Smoke passed: Relay commands, Home Mac connector, and notification event are working."
