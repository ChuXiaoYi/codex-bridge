#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${RELAY_CLIENT_TOKEN:?Set RELAY_CLIENT_TOKEN for iPhone/watch clients}"
: "${RELAY_BRIDGE_TOKEN:?Set RELAY_BRIDGE_TOKEN for the Home Mac connector}"

RELAY_HOST="${RELAY_HOST:-0.0.0.0}"
RELAY_PORT="${RELAY_PORT:-8788}"

exec node "$SCRIPT_DIR/relay.mjs" --host "$RELAY_HOST" --port "$RELAY_PORT"
