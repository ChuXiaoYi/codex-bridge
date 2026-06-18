#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${GITHUB_OWNER:?Set GITHUB_OWNER to the repo owner}"
: "${GITHUB_REPO:?Set GITHUB_REPO to the repo name}"

resolve_github_token() {
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    return 0
  fi

  if [[ -n "${GITHUB_TOKEN_COMMAND:-}" ]]; then
    GITHUB_TOKEN="$(eval "$GITHUB_TOKEN_COMMAND")"
    export GITHUB_TOKEN
    return 0
  fi

  for gh_bin in "${GH_BIN:-}" /opt/homebrew/bin/gh /usr/local/bin/gh /usr/bin/gh gh; do
    if [[ -z "$gh_bin" ]]; then
      continue
    fi
    if command -v "$gh_bin" >/dev/null 2>&1; then
      GITHUB_TOKEN="$("$gh_bin" auth token)"
      export GITHUB_TOKEN
      return 0
    fi
  done

  echo "Set GITHUB_TOKEN, GITHUB_TOKEN_COMMAND, or install/login GitHub CLI with gh auth login." >&2
  exit 1
}

resolve_github_token

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

node "$SCRIPT_DIR/github-issues-client.mjs" --bridge "$BRIDGE_URL" &
CLIENT_PID=$!
wait "$CLIENT_PID"
