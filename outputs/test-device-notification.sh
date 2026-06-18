#!/usr/bin/env bash
set -euo pipefail

OUTPUT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${CODEX_REMOTE_ENV_FILE:-$HOME/.codex-remote-home-mac.env}"
TIMEOUT_SECONDS="${CODEX_REMOTE_DEVICE_TEST_TIMEOUT_SECONDS:-240}"

usage() {
  cat <<'EOF'
Usage:
  test-device-notification.sh [--env FILE] [--timeout SECONDS]

Creates one temporary GitHub issue through the installed Home Mac service so you
can confirm GitHub Mobile push delivery on iPhone and Apple Watch.

Before running, unlock GitHub Mobile once, make sure the private repo is not
muted, then lock the iPhone or wear the Watch.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)
      ENV_FILE="${2:?Missing value for --env}"
      shift 2
      ;;
    --timeout)
      TIMEOUT_SECONDS="${2:?Missing value for --timeout}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
else
  echo "Env file not found: $ENV_FILE" >&2
  exit 1
fi

: "${GITHUB_OWNER:?Set GITHUB_OWNER in $ENV_FILE}"
: "${GITHUB_REPO:?Set GITHUB_REPO in $ENV_FILE}"

TASK_LABEL="${GITHUB_TASK_LABEL:-codex-remote}"
DONE_LABEL="${GITHUB_DONE_LABEL:-codex-done}"
NOTIFY_USERNAME="${GITHUB_NOTIFY_USERNAME:-}"
NOTIFY_ASSIGNEES="${GITHUB_NOTIFY_ASSIGNEES:-}"

echo "Device notification test for ${GITHUB_OWNER}/${GITHUB_REPO}"
echo "Task label: ${TASK_LABEL}"
echo "Done label: ${DONE_LABEL}"
if [[ -n "$NOTIFY_USERNAME" ]]; then
  echo "Completion comment will mention: @${NOTIFY_USERNAME}"
fi
if [[ -n "$NOTIFY_ASSIGNEES" ]]; then
  echo "Completion issue will assign: ${NOTIFY_ASSIGNEES}"
fi
cat <<'EOF'

Watch your iPhone or Apple Watch for a GitHub Mobile notification whose issue
title is "Codex Remote device notification test".

EOF

CODEX_REMOTE_SERVICE_SMOKE_TITLE="${CODEX_REMOTE_SERVICE_SMOKE_TITLE:-Codex Remote device notification test}" \
CODEX_REMOTE_SERVICE_SMOKE_TEXT="${CODEX_REMOTE_SERVICE_SMOKE_TEXT:-Reply exactly: CODEX_REMOTE_DEVICE_NOTIFY_OK}" \
CODEX_REMOTE_SERVICE_SMOKE_EXPECTED="${CODEX_REMOTE_SERVICE_SMOKE_EXPECTED:-CODEX_REMOTE_DEVICE_NOTIFY_OK}" \
  "$OUTPUT_DIR/smoke-github-inbox-service.sh" --env "$ENV_FILE" --timeout "$TIMEOUT_SECONDS"

cat <<'EOF'

Server-side notification path passed.

If GitHub Mobile also appeared on iPhone or Apple Watch, the no-server remote
office notification chain is confirmed end to end. If it did not appear, check:
GitHub Mobile login, repo notification mute state, iOS notification permission,
Focus mode, and Watch notification mirroring.
EOF
