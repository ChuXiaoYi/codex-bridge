#!/usr/bin/env bash
set -euo pipefail

OUTPUT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${CODEX_REMOTE_ENV_FILE:-$HOME/.codex-remote-home-mac.env}"
TIMEOUT_SECONDS="${CODEX_REMOTE_SERVICE_SMOKE_TIMEOUT_SECONDS:-240}"
SMOKE_TEXT="${CODEX_REMOTE_SERVICE_SMOKE_TEXT:-Reply exactly: CODEX_REMOTE_SERVICE_OK}"
EXPECTED_TEXT="${CODEX_REMOTE_SERVICE_SMOKE_EXPECTED:-CODEX_REMOTE_SERVICE_OK}"
ISSUE_NUMBER=""

usage() {
  cat <<'EOF'
Usage:
  smoke-github-inbox-service.sh [--env FILE] [--timeout SECONDS]

Runs a real end-to-end smoke through the installed Home Mac service:
  private GitHub issue with GITHUB_TASK_LABEL -> LaunchAgent service -> Codex -> GitHub completion comment.

The script closes the smoke issue when the test finishes.
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
DONE_LABEL="${GITHUB_DONE_LABEL-codex-done}"
NOTIFY_ASSIGNEES="${GITHUB_NOTIFY_ASSIGNEES:-}"
BRIDGE_HOST="${BRIDGE_HOST:-127.0.0.1}"
BRIDGE_PORT="${BRIDGE_PORT:-8787}"
BRIDGE_URL="${BRIDGE_URL:-http://${BRIDGE_HOST}:${BRIDGE_PORT}}"

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
  local tmp_body
  tmp_body="$(mktemp)"
  if [[ -n "${BASE_PATH:-}" && -n "$ISSUE_NUMBER" ]]; then
    local close_body
    close_body="$(node -e 'console.log(JSON.stringify({state:"closed", state_reason:"completed"}))')"
    github_request PATCH "$BASE_PATH/issues/$ISSUE_NUMBER" "$tmp_body" "$close_body" >/dev/null || true
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

if ! curl -fsS "${BRIDGE_URL%/}/health" >/dev/null; then
  echo "Installed Home Mac service is not healthy at ${BRIDGE_URL%/}/health." >&2
  exit 1
fi

echo "Creating service smoke issue with label ${TASK_LABEL}..."
ISSUE_BODY="$(node -e 'console.log(JSON.stringify({title: "Codex Remote service smoke", body: process.argv[1], labels: [process.argv[2]]}))' "$SMOKE_TEXT" "$TASK_LABEL")"
CODE="$(github_request POST "${BASE_PATH}/issues" "$TMP_BODY" "$ISSUE_BODY")"
check_response "$CODE" "$TMP_BODY" "Service smoke issue creation"
ISSUE_NUMBER="$(json_value "$TMP_BODY" "data.number")"
ISSUE_URL="$(json_value "$TMP_BODY" "data.html_url")"
echo "Service smoke issue: ${ISSUE_URL}"

echo "Waiting for installed service completion comment..."
deadline=$((SECONDS + TIMEOUT_SECONDS))
COMPLETION_SEEN=0
LAST_METADATA_STATUS=""
while (( SECONDS < deadline )); do
  CODE="$(github_request GET "${BASE_PATH}/issues/${ISSUE_NUMBER}/comments?per_page=100" "$TMP_BODY")"
  check_response "$CODE" "$TMP_BODY" "Service smoke issue comments"
  if node - "$TMP_BODY" "$EXPECTED_TEXT" <<'NODE'
const fs = require("fs");
const [, , file, expected] = process.argv;
const comments = JSON.parse(fs.readFileSync(file, "utf8"));
process.exit(comments.some((comment) =>
  String(comment.body || "").includes("codex-remote-completed:") &&
  String(comment.body || "").includes(expected)
) ? 0 : 1);
NODE
  then
    COMPLETION_SEEN=1
    CODE="$(github_request GET "${BASE_PATH}/issues/${ISSUE_NUMBER}" "$TMP_BODY")"
    check_response "$CODE" "$TMP_BODY" "Service smoke issue lookup"
    if LAST_METADATA_STATUS="$(node - "$TMP_BODY" "$DONE_LABEL" "$NOTIFY_ASSIGNEES" <<'NODE'
const fs = require("fs");
const [, , file, doneLabel, assigneesRaw] = process.argv;
const issue = JSON.parse(fs.readFileSync(file, "utf8"));
const labels = new Set((issue.labels || []).map((label) => label.name));
const assignees = new Set((issue.assignees || []).map((assignee) => assignee.login));
const expectedAssignees = assigneesRaw.split(",").map((value) => value.trim()).filter(Boolean);
const hasDoneLabel = !doneLabel || labels.has(doneLabel);
const hasAssignees = expectedAssignees.every((login) => assignees.has(login));
const missing = [];
if (!hasDoneLabel) missing.push(`missing done label '${doneLabel}'`);
const missingAssignees = expectedAssignees.filter((login) => !assignees.has(login));
if (missingAssignees.length) missing.push(`missing assignees ${missingAssignees.join(", ")}`);
if (missing.length) {
  console.log(missing.join("; "));
  process.exit(1);
}
console.log("metadata ok");
NODE
    )"; then
      echo "Installed service smoke passed: Codex completed, commented back, and marked the issue done."
      exit 0
    fi
  fi
  sleep 3
done

if [[ "$COMPLETION_SEEN" == "1" ]]; then
  echo "Timed out after Codex completion while waiting for issue metadata: ${LAST_METADATA_STATUS:-unknown metadata mismatch}." >&2
else
  echo "Timed out waiting for installed service completion comment on ${ISSUE_URL}." >&2
fi
exit 1
