#!/usr/bin/env bash
set -euo pipefail

OUTPUT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${CODEX_REMOTE_ENV_FILE:-$HOME/.codex-remote-home-mac.env}"
TIMEOUT_SECONDS="${CODEX_REMOTE_MOBILE_CONTRACT_TIMEOUT_SECONDS:-300}"
TASK_TEXT="${CODEX_REMOTE_MOBILE_CONTRACT_TASK_TEXT:-Codex Remote mobile contract test

Reply exactly: CODEX_REMOTE_MOBILE_FIRST_OK}"
COMMENT_TEXT="${CODEX_REMOTE_MOBILE_CONTRACT_COMMENT_TEXT:-Reply exactly: CODEX_REMOTE_MOBILE_COMMENT_OK}"
EXPECTED_COMMENT_TEXT="${CODEX_REMOTE_MOBILE_CONTRACT_EXPECTED_COMMENT:-CODEX_REMOTE_MOBILE_COMMENT_OK}"
ISSUE_NUMBER=""

usage() {
  cat <<'EOF'
Usage:
  smoke-mobile-github-contract.sh [--env FILE] [--timeout SECONDS]

Runs a real GitHub contract smoke that mirrors the iPhone/watchOS app backend:
  create issue with GITHUB_TASK_LABEL -> list open issues -> add comment ->
  installed Home Mac service -> Codex completion comment -> done label/assignee.

The script closes the temporary issue when the test finishes.
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
      if GITHUB_TOKEN="$("$gh_bin" auth token 2>/dev/null)" && [[ -n "$GITHUB_TOKEN" ]]; then
        export GITHUB_TOKEN
        return 0
      fi
    fi
  done
  echo "Set GITHUB_TOKEN, GITHUB_TOKEN_COMMAND, or install/login GitHub CLI." >&2
  exit 1
}

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

issue_title_from_text() {
  node - "$TASK_TEXT" <<'NODE'
const text = process.argv[2] || "";
const firstLine = text.split(/\r?\n/).find((line) => line.trim().length > 0)?.trim() || "Codex task";
console.log(firstLine.length > 80 ? `${firstLine.slice(0, 77)}...` : firstLine);
NODE
}

list_contains_issue() {
  local file="$1"
  local issue_number="$2"
  node - "$file" "$issue_number" <<'NODE'
const fs = require("fs");
const [, , file, issueNumber] = process.argv;
const issues = JSON.parse(fs.readFileSync(file, "utf8"));
if (!Array.isArray(issues) || !issues.some((issue) => String(issue.number) === String(issueNumber))) {
  process.exit(1);
}
NODE
}

comments_include() {
  local file="$1"
  local expected="$2"
  node - "$file" "$expected" <<'NODE'
const fs = require("fs");
const [, , file, expected] = process.argv;
const comments = JSON.parse(fs.readFileSync(file, "utf8"));
process.exit(Array.isArray(comments) && comments.some((comment) => String(comment.body || "").includes(expected)) ? 0 : 1);
NODE
}

completion_contains_expected() {
  local file="$1"
  local expected="$2"
  node - "$file" "$expected" <<'NODE'
const fs = require("fs");
const [, , file, expected] = process.argv;
const comments = JSON.parse(fs.readFileSync(file, "utf8"));
process.exit(Array.isArray(comments) && comments.some((comment) =>
  String(comment.body || "").includes("codex-remote-completed:") &&
  String(comment.body || "").includes(expected)
) ? 0 : 1);
NODE
}

metadata_ok() {
  local file="$1"
  node - "$file" "$DONE_LABEL" "$NOTIFY_ASSIGNEES" <<'NODE'
const fs = require("fs");
const [, , file, doneLabel, assigneesRaw] = process.argv;
const issue = JSON.parse(fs.readFileSync(file, "utf8"));
const labels = new Set((issue.labels || []).map((label) => label.name));
const assignees = new Set((issue.assignees || []).map((assignee) => assignee.login));
const expectedAssignees = assigneesRaw.split(",").map((value) => value.trim()).filter(Boolean);
const missing = [];
if (doneLabel && !labels.has(doneLabel)) missing.push(`missing done label '${doneLabel}'`);
const missingAssignees = expectedAssignees.filter((login) => !assignees.has(login));
if (missingAssignees.length) missing.push(`missing assignees ${missingAssignees.join(", ")}`);
if (missing.length) {
  console.error(missing.join("; "));
  process.exit(1);
}
NODE
}

resolve_github_token

OWNER_PATH="$(urlencode "$GITHUB_OWNER")"
REPO_PATH="$(urlencode "$GITHUB_REPO")"
LABEL_PATH="$(urlencode "$TASK_LABEL")"
BASE_PATH="/repos/${OWNER_PATH}/${REPO_PATH}"
TMP_BODY="$(mktemp)"
trap 'rm -f "$TMP_BODY"; cleanup' EXIT INT TERM

echo "Preflighting ${GITHUB_OWNER}/${GITHUB_REPO}..."
CODEX_REMOTE_ENV_FILE="$ENV_FILE" "$OUTPUT_DIR/home-mac-bridge/doctor-github-inbox.sh" >/dev/null

if ! curl -fsS "${BRIDGE_URL%/}/health" >/dev/null; then
  echo "Installed Home Mac service is not healthy at ${BRIDGE_URL%/}/health." >&2
  exit 1
fi

ISSUE_TITLE="$(issue_title_from_text)"
echo "Creating mobile-style issue with label ${TASK_LABEL}..."
ISSUE_BODY="$(node -e 'console.log(JSON.stringify({title: process.argv[1], body: process.argv[2], labels: [process.argv[3]]}))' "$ISSUE_TITLE" "$TASK_TEXT" "$TASK_LABEL")"
CODE="$(github_request POST "${BASE_PATH}/issues" "$TMP_BODY" "$ISSUE_BODY")"
check_response "$CODE" "$TMP_BODY" "Mobile-style issue creation"
ISSUE_NUMBER="$(json_value "$TMP_BODY" "data.number")"
ISSUE_URL="$(json_value "$TMP_BODY" "data.html_url")"
echo "Mobile-style issue: ${ISSUE_URL}"

echo "Verifying mobile-style issue listing..."
list_deadline=$((SECONDS + 60))
LIST_SEEN=0
while (( SECONDS < list_deadline )); do
  CODE="$(github_request GET "${BASE_PATH}/issues?state=open&labels=${LABEL_PATH}&sort=updated&direction=desc&per_page=20" "$TMP_BODY")"
  check_response "$CODE" "$TMP_BODY" "Mobile-style issue listing"
  if list_contains_issue "$TMP_BODY" "$ISSUE_NUMBER"; then
    LIST_SEEN=1
    break
  fi
  sleep 2
done
if [[ "$LIST_SEEN" != "1" ]]; then
  echo "Open issue list did not include #${ISSUE_NUMBER} after waiting for GitHub label indexing." >&2
  exit 1
fi

echo "Waiting for Home Mac service to start a Codex thread..."
deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  CODE="$(github_request GET "${BASE_PATH}/issues/${ISSUE_NUMBER}/comments?per_page=100" "$TMP_BODY")"
  check_response "$CODE" "$TMP_BODY" "Mobile contract comments"
  if comments_include "$TMP_BODY" "Started Codex thread"; then
    break
  fi
  sleep 3
done
if (( SECONDS >= deadline )); then
  echo "Timed out waiting for Home Mac service to start a Codex thread on ${ISSUE_URL}." >&2
  exit 1
fi

echo "Adding mobile-style follow-up comment..."
COMMENT_BODY="$(node -e 'console.log(JSON.stringify({body: process.argv[1]}))' "$COMMENT_TEXT")"
CODE="$(github_request POST "${BASE_PATH}/issues/${ISSUE_NUMBER}/comments" "$TMP_BODY" "$COMMENT_BODY")"
check_response "$CODE" "$TMP_BODY" "Mobile-style comment creation"

echo "Waiting for comment forwarding and Codex completion..."
COMMENT_ACK_SEEN=0
COMPLETION_SEEN=0
LAST_METADATA_STATUS=""
deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  CODE="$(github_request GET "${BASE_PATH}/issues/${ISSUE_NUMBER}/comments?per_page=100" "$TMP_BODY")"
  check_response "$CODE" "$TMP_BODY" "Mobile contract comments"
  if comments_include "$TMP_BODY" "Sent to Codex thread"; then
    COMMENT_ACK_SEEN=1
  fi
  if completion_contains_expected "$TMP_BODY" "$EXPECTED_COMMENT_TEXT"; then
    COMPLETION_SEEN=1
    CODE="$(github_request GET "${BASE_PATH}/issues/${ISSUE_NUMBER}" "$TMP_BODY")"
    check_response "$CODE" "$TMP_BODY" "Mobile contract issue lookup"
    if LAST_METADATA_STATUS="$(metadata_ok "$TMP_BODY" 2>&1)"; then
      echo "Mobile GitHub contract smoke passed: create, list, comment, completion, done label, and assignee are working."
      exit 0
    fi
  fi
  sleep 3
done

if [[ "$COMMENT_ACK_SEEN" != "1" ]]; then
  echo "Timed out waiting for Home Mac service to acknowledge the mobile-style comment on ${ISSUE_URL}." >&2
elif [[ "$COMPLETION_SEEN" != "1" ]]; then
  echo "Timed out waiting for Codex completion containing ${EXPECTED_COMMENT_TEXT} on ${ISSUE_URL}." >&2
else
  echo "Timed out waiting for issue metadata: ${LAST_METADATA_STATUS:-unknown metadata mismatch}." >&2
fi
exit 1
