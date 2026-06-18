#!/usr/bin/env bash
set -euo pipefail

OUTPUT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${CODEX_REMOTE_ENV_FILE:-$HOME/.codex-remote-home-mac.env}"
TIMEOUT_SECONDS="${CODEX_REMOTE_SMOKE_TIMEOUT_SECONDS:-180}"
SMOKE_BRIDGE_PORT="${CODEX_REMOTE_SMOKE_BRIDGE_PORT:-18787}"
SMOKE_BRIDGE_HOST="${CODEX_REMOTE_SMOKE_BRIDGE_HOST:-127.0.0.1}"
RUN_ID="$(date +%Y%m%d%H%M%S)"
SMOKE_LABEL="${CODEX_REMOTE_SMOKE_LABEL:-codex-remote-smoke-${RUN_ID}}"
SMOKE_TEXT="${CODEX_REMOTE_SMOKE_TEXT:-Reply exactly: CODEX_REMOTE_GITHUB_SMOKE_OK}"
ISSUE_NUMBER=""
STARTER_PID=""

usage() {
  cat <<'EOF'
Usage:
  smoke-github-inbox-real.sh [--env FILE] [--timeout SECONDS]

Runs a real end-to-end GitHub inbox smoke:
  private GitHub issue -> Home Mac Bridge -> Codex -> GitHub completion comment.

The script uses a temporary label so existing codex-remote issues are not touched.
It closes the smoke issue when the test finishes.
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
DONE_LABEL="${GITHUB_DONE_LABEL-codex-done}"
NOTIFY_ASSIGNEES="${GITHUB_NOTIFY_ASSIGNEES:-}"

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
  echo "Set GITHUB_TOKEN, GITHUB_TOKEN_COMMAND, or install/login GitHub CLI." >&2
  exit 1
}

resolve_github_token
BRIDGE_HOST="$SMOKE_BRIDGE_HOST"
BRIDGE_PORT="$SMOKE_BRIDGE_PORT"
BRIDGE_URL="http://${BRIDGE_HOST}:${BRIDGE_PORT}"

api_url() {
  local api="${GITHUB_API_URL:-https://api.github.com}"
  api="${api%/}"
  printf '%s' "$api"
}

urlencode() {
  node -e 'console.log(encodeURIComponent(process.argv[1]))' "$1"
}

github_request() {
  local method="$1"
  local path="$2"
  local output_file="$3"
  local body="${4:-}"
  local args=(
    -sS
    --retry 3
    --retry-delay 1
    --retry-all-errors
    -o "$output_file"
    -w "%{http_code}"
    -X "$method"
    -H "Accept: application/vnd.github+json"
    -H "Authorization: Bearer ${GITHUB_TOKEN}"
    -H "X-GitHub-Api-Version: 2022-11-28"
  )
  if [[ -n "$body" ]]; then
    args+=(-H "Content-Type: application/json" -d "$body")
  fi
  curl "${args[@]}" "$(api_url)${path}"
}

json_value() {
  local file="$1"
  local expression="$2"
  node - "$file" "$expression" <<'NODE'
const fs = require("fs");
const [, , file, expression] = process.argv;
const data = JSON.parse(fs.readFileSync(file, "utf8"));
const fn = new Function("data", `return ${expression}`);
const value = fn(data);
if (value !== undefined && value !== null) console.log(String(value));
NODE
}

check_response() {
  local code="$1"
  local file="$2"
  local label="$3"
  if [[ "$code" =~ ^2 ]]; then
    return 0
  fi
  echo "$label failed with HTTP $code." >&2
  sed -n '1,16p' "$file" >&2
  return 1
}

cleanup() {
  if [[ -n "$STARTER_PID" ]]; then
    kill "$STARTER_PID" >/dev/null 2>&1 || true
    wait "$STARTER_PID" >/dev/null 2>&1 || true
  fi

  local tmp_body
  tmp_body="$(mktemp)"
  if [[ -n "${BASE_PATH:-}" && -n "$ISSUE_NUMBER" ]]; then
    local close_body
    close_body="$(node -e 'console.log(JSON.stringify({state:"closed", state_reason:"completed"}))')"
    github_request PATCH "$BASE_PATH/issues/$ISSUE_NUMBER" "$tmp_body" "$close_body" >/dev/null || true
  fi
  if [[ -n "${BASE_PATH:-}" ]]; then
    github_request DELETE "$BASE_PATH/labels/$(urlencode "$SMOKE_LABEL")" "$tmp_body" >/dev/null || true
  fi
  rm -f "$tmp_body"
}

OWNER_PATH="$(urlencode "$GITHUB_OWNER")"
REPO_PATH="$(urlencode "$GITHUB_REPO")"
BASE_PATH="/repos/${OWNER_PATH}/${REPO_PATH}"
TMP_BODY="$(mktemp)"
trap 'rm -f "$TMP_BODY"; cleanup' EXIT INT TERM

echo "Preflighting ${GITHUB_OWNER}/${GITHUB_REPO}..."
CODEX_REMOTE_ENV_FILE="$ENV_FILE" "$OUTPUT_DIR/home-mac-bridge/doctor-github-inbox.sh" >/dev/null

echo "Creating temporary smoke label ${SMOKE_LABEL}..."
LABEL_BODY="$(node -e 'console.log(JSON.stringify({name: process.argv[1], color: "0E8A16", description: "Temporary Codex Remote smoke label"}))' "$SMOKE_LABEL")"
CODE="$(github_request POST "${BASE_PATH}/labels" "$TMP_BODY" "$LABEL_BODY")"
if [[ "$CODE" == "422" ]]; then
  CODE="$(github_request GET "${BASE_PATH}/labels/$(urlencode "$SMOKE_LABEL")" "$TMP_BODY")"
fi
check_response "$CODE" "$TMP_BODY" "Smoke label setup"

echo "Starting temporary Home Mac GitHub connector on ${BRIDGE_URL}..."
CODEX_REMOTE_BACKEND=github \
GITHUB_TASK_LABEL="$SMOKE_LABEL" \
BRIDGE_HOST="$BRIDGE_HOST" \
BRIDGE_PORT="$BRIDGE_PORT" \
BRIDGE_URL="$BRIDGE_URL" \
"$OUTPUT_DIR/home-mac-bridge/start-home-mac-github.sh" >"/tmp/codex-remote-github-smoke-${RUN_ID}.log" 2>&1 &
STARTER_PID=$!

for _ in $(seq 1 80); do
  if ! kill -0 "$STARTER_PID" >/dev/null 2>&1; then
    echo "Connector exited before it became ready." >&2
    sed -n '1,80p' "/tmp/codex-remote-github-smoke-${RUN_ID}.log" >&2
    exit 1
  fi
  if curl -fsS "${BRIDGE_URL}/health" >/dev/null 2>&1; then
    break
  fi
  sleep 0.25
done

if ! curl -fsS "${BRIDGE_URL}/health" >/dev/null 2>&1; then
  echo "Bridge did not become healthy at ${BRIDGE_URL}." >&2
  sed -n '1,80p' "/tmp/codex-remote-github-smoke-${RUN_ID}.log" >&2
  exit 1
fi

echo "Creating smoke issue..."
ISSUE_BODY="$(node -e 'console.log(JSON.stringify({title: "Codex Remote real inbox smoke", body: process.argv[1], labels: [process.argv[2]]}))' "$SMOKE_TEXT" "$SMOKE_LABEL")"
CODE="$(github_request POST "${BASE_PATH}/issues" "$TMP_BODY" "$ISSUE_BODY")"
check_response "$CODE" "$TMP_BODY" "Smoke issue creation"
ISSUE_NUMBER="$(json_value "$TMP_BODY" "data.number")"
ISSUE_URL="$(json_value "$TMP_BODY" "data.html_url")"
echo "Smoke issue: ${ISSUE_URL}"

echo "Waiting for Codex completion comment..."
deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  CODE="$(github_request GET "${BASE_PATH}/issues/${ISSUE_NUMBER}/comments?per_page=100" "$TMP_BODY")"
  check_response "$CODE" "$TMP_BODY" "Smoke issue comments"
  if node - "$TMP_BODY" <<'NODE'
const fs = require("fs");
const comments = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
process.exit(comments.some((comment) =>
  String(comment.body || "").includes("codex-remote-completed:") &&
  String(comment.body || "").includes("CODEX_REMOTE_GITHUB_SMOKE_OK")
) ? 0 : 1);
NODE
  then
    CODE="$(github_request GET "${BASE_PATH}/issues/${ISSUE_NUMBER}" "$TMP_BODY")"
    check_response "$CODE" "$TMP_BODY" "Smoke issue lookup"
    if node - "$TMP_BODY" "$DONE_LABEL" "$NOTIFY_ASSIGNEES" <<'NODE'
const fs = require("fs");
const [, , file, doneLabel, assigneesRaw] = process.argv;
const issue = JSON.parse(fs.readFileSync(file, "utf8"));
const labels = new Set((issue.labels || []).map((label) => label.name));
const assignees = new Set((issue.assignees || []).map((assignee) => assignee.login));
const expectedAssignees = assigneesRaw.split(",").map((value) => value.trim()).filter(Boolean);
const hasDoneLabel = !doneLabel || labels.has(doneLabel);
const hasAssignees = expectedAssignees.every((login) => assignees.has(login));
process.exit(hasDoneLabel && hasAssignees ? 0 : 1);
NODE
    then
      echo "Real GitHub inbox smoke passed: Codex completed, commented back, and marked the issue done."
      exit 0
    fi
  fi
  sleep 3
done

echo "Timed out waiting for completion comment on ${ISSUE_URL}." >&2
echo "Connector log:" >&2
sed -n '1,160p' "/tmp/codex-remote-github-smoke-${RUN_ID}.log" >&2
exit 1
