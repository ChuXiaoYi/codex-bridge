#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${RELAY_URL:?Set RELAY_URL to your public Relay URL, for example https://relay.example.com}"
: "${RELAY_BRIDGE_TOKEN:?Set RELAY_BRIDGE_TOKEN to the same value used by the Relay}"

BRIDGE_HOST="${BRIDGE_HOST:-127.0.0.1}"
BRIDGE_PORT="${BRIDGE_PORT:-8787}"
BRIDGE_URL="${BRIDGE_URL:-http://${BRIDGE_HOST}:${BRIDGE_PORT}}"

node "$SCRIPT_DIR/bridge.mjs" --host "$BRIDGE_HOST" --port "$BRIDGE_PORT" &
BRIDGE_PID=$!
CLIENT_PID=""

cleanup() {
  if [[ -n "$CLIENT_PID" ]]; then
    kill "$CLIENT_PID" >/dev/null 2>&1 || true
    wait "$CLIENT_PID" >/dev/null 2>&1 || true
  fi
  kill "$BRIDGE_PID" >/dev/null 2>&1 || true
  wait "$BRIDGE_PID" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

bridge_health() {
  if [[ -n "${BRIDGE_TOKEN:-}" ]]; then
    curl -fsS -H "authorization: Bearer ${BRIDGE_TOKEN}" "$BRIDGE_URL/health" >/dev/null 2>&1
  else
    curl -fsS "$BRIDGE_URL/health" >/dev/null 2>&1
  fi
}

BRIDGE_READY=0
for _ in $(seq 1 50); do
  if ! kill -0 "$BRIDGE_PID" >/dev/null 2>&1; then
    echo "Home Mac Bridge exited before it became ready." >&2
    exit 1
  fi
  if bridge_health; then
    BRIDGE_READY=1
    break
  fi
  sleep 0.2
done

if [[ "$BRIDGE_READY" != "1" ]]; then
  echo "Timed out waiting for Home Mac Bridge at $BRIDGE_URL." >&2
  exit 1
fi

node "$SCRIPT_DIR/relay-client.mjs" --relay "$RELAY_URL" --bridge "$BRIDGE_URL" &
CLIENT_PID=$!
wait "$CLIENT_PID"
