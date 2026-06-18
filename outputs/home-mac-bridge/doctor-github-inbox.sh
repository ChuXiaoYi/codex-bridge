#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${CODEX_REMOTE_ENV_FILE:-$HOME/.codex-remote-home-mac.env}"
CHECK_BRIDGE=0
CREATE_LABEL=0

usage() {
  cat <<'EOF'
Usage:
  doctor-github-inbox.sh [--env FILE] [--check-bridge] [--create-label]

Checks the GitHub Issues no-server inbox configuration without printing tokens.

Options:
  --env FILE       Load a Home Mac env file. Defaults to ~/.codex-remote-home-mac.env
  --check-bridge  Also check BRIDGE_URL /health
  --create-label  Create GITHUB_TASK_LABEL and GITHUB_DONE_LABEL when missing
  -h, --help      Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)
      ENV_FILE="${2:?Missing value for --env}"
      shift 2
      ;;
    --check-bridge)
      CHECK_BRIDGE=1
      shift
      ;;
    --create-label)
      CREATE_LABEL=1
      shift
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
  echo "Create it with: cp $SCRIPT_DIR/home-mac.env.example $ENV_FILE" >&2
fi

need() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Missing $name." >&2
    exit 1
  fi
}

resolve_github_token() {
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    if [[ "$GITHUB_TOKEN" == "github_pat_replace_me" ]]; then
      echo "GITHUB_TOKEN is still the placeholder value." >&2
      exit 1
    fi
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

  echo "Missing GitHub auth. Set GITHUB_TOKEN, set GITHUB_TOKEN_COMMAND, or run gh auth login." >&2
  exit 1
}

need_node() {
  if ! command -v node >/dev/null 2>&1; then
    echo "node is required for this checker." >&2
    exit 1
  fi
}

urlencode() {
  node -e 'console.log(encodeURIComponent(process.argv[1]))' "$1"
}

json_value() {
  local file="$1"
  local key="$2"
  node - "$file" "$key" <<'NODE'
const fs = require("fs");
const [, , file, key] = process.argv;
const data = JSON.parse(fs.readFileSync(file, "utf8"));
const value = data[key];
if (typeof value === "boolean") {
  console.log(value ? "true" : "false");
} else if (value !== null && value !== undefined) {
  console.log(String(value));
}
NODE
}

normalize_login() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

github_request() {
  local method="$1"
  local path="$2"
  local output_file="$3"
  local data="${4:-}"
  local api_url="${GITHUB_API_URL:-https://api.github.com}"
  api_url="${api_url%/}"

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
  if [[ -n "$data" ]]; then
    args+=(-H "Content-Type: application/json" -d "$data")
  fi

  curl "${args[@]}" "${api_url}${path}"
}

check_response() {
  local code="$1"
  local file="$2"
  local label="$3"
  if [[ "$code" =~ ^2 ]]; then
    return 0
  fi
  echo "$label failed with HTTP $code." >&2
  sed -n '1,12p' "$file" >&2
  return 1
}

need_node
need GITHUB_OWNER
need GITHUB_REPO
resolve_github_token

TASK_LABEL="${GITHUB_TASK_LABEL:-codex-remote}"
DONE_LABEL="${GITHUB_DONE_LABEL-codex-done}"
ALLOW_PUBLIC="${GITHUB_ALLOW_PUBLIC_REPO:-0}"
TMP_BODY="$(mktemp)"
trap 'rm -f "$TMP_BODY"' EXIT

OWNER_PATH="$(urlencode "$GITHUB_OWNER")"
REPO_PATH="$(urlencode "$GITHUB_REPO")"
BASE_PATH="/repos/${OWNER_PATH}/${REPO_PATH}"

echo "Checking GitHub inbox ${GITHUB_OWNER}/${GITHUB_REPO} label '${TASK_LABEL}'..."

CODE="$(github_request GET "$BASE_PATH" "$TMP_BODY")"
check_response "$CODE" "$TMP_BODY" "Repository lookup"

FULL_NAME="$(json_value "$TMP_BODY" full_name)"
PRIVATE_VALUE="$(json_value "$TMP_BODY" private)"
HAS_ISSUES="$(json_value "$TMP_BODY" has_issues)"

echo "Repository: ${FULL_NAME:-${GITHUB_OWNER}/${GITHUB_REPO}}"

if [[ "$PRIVATE_VALUE" != "true" && "$ALLOW_PUBLIC" != "1" ]]; then
  echo "Repository is public. Use a private repo for real Codex tasks, or set GITHUB_ALLOW_PUBLIC_REPO=1 intentionally." >&2
  exit 1
fi
if [[ "$PRIVATE_VALUE" != "true" ]]; then
  echo "Warning: repository is public because GITHUB_ALLOW_PUBLIC_REPO=1 is set." >&2
fi

if [[ "$HAS_ISSUES" == "false" ]]; then
  echo "GitHub Issues are disabled for this repository." >&2
  exit 1
fi
echo "Issues: enabled"

ensure_label() {
  local name="$1"
  local color="$2"
  local description="$3"
  local encoded
  encoded="$(urlencode "$name")"
  CODE="$(github_request GET "${BASE_PATH}/labels/${encoded}" "$TMP_BODY")"
  if [[ "$CODE" =~ ^2 ]]; then
    echo "Label: ${name}"
    return
  fi
  if [[ "$CODE" == "404" && "$CREATE_LABEL" == "1" ]]; then
    DATA="$(node -e 'console.log(JSON.stringify({name: process.argv[1], color: process.argv[2], description: process.argv[3]}))' "$name" "$color" "$description")"
    CODE="$(github_request POST "${BASE_PATH}/labels" "$TMP_BODY" "$DATA")"
    check_response "$CODE" "$TMP_BODY" "Label creation"
    echo "Label created: ${name}"
    return
  fi
  echo "Label '${name}' is missing or not readable." >&2
  echo "Create it with: gh label create ${name} --repo ${GITHUB_OWNER}/${GITHUB_REPO} --color ${color} --description '${description}'" >&2
  exit 1
}

ensure_label "$TASK_LABEL" "0969DA" "Codex Remote task inbox"
if [[ -n "$DONE_LABEL" ]]; then
  ensure_label "$DONE_LABEL" "0E8A16" "Codex Remote completed task"
fi

ensure_user() {
  local username="$1"
  CODE="$(github_request GET "/users/$(urlencode "$username")" "$TMP_BODY")"
  check_response "$CODE" "$TMP_BODY" "GitHub user lookup"
}

ensure_collaborator() {
  local username="$1"
  CODE="$(github_request GET "${BASE_PATH}/collaborators/$(urlencode "$username")" "$TMP_BODY")"
  if [[ "$CODE" == "204" || "$CODE" =~ ^2 ]]; then
    return
  fi
  echo "Notify user '${username}' cannot access ${GITHUB_OWNER}/${GITHUB_REPO}." >&2
  echo "Add that account as a repository collaborator so GitHub Mobile can receive private repo notifications." >&2
  exit 1
}

if [[ -n "${GITHUB_NOTIFY_USERNAME:-}" ]]; then
  ensure_user "$GITHUB_NOTIFY_USERNAME"
  ensure_collaborator "$GITHUB_NOTIFY_USERNAME"
  echo "Notify mention target: ${GITHUB_NOTIFY_USERNAME}"
fi

if [[ -n "${GITHUB_NOTIFY_ASSIGNEES:-}" ]]; then
  IFS=',' read -r -a notify_assignees <<<"$GITHUB_NOTIFY_ASSIGNEES"
  for username in "${notify_assignees[@]}"; do
    username="$(echo "$username" | xargs)"
    if [[ -z "$username" ]]; then
      continue
    fi
    ensure_user "$username"
    ensure_collaborator "$username"
    CODE="$(github_request GET "${BASE_PATH}/assignees/$(urlencode "$username")" "$TMP_BODY")"
    if [[ "$CODE" == "204" || "$CODE" =~ ^2 ]]; then
      echo "Notify assignee: ${username}"
    else
      echo "Notify assignee '${username}' is not assignable in ${GITHUB_OWNER}/${GITHUB_REPO}." >&2
      echo "Add that account as a repository collaborator, or remove it from GITHUB_NOTIFY_ASSIGNEES and rely on GITHUB_NOTIFY_USERNAME mentions." >&2
      exit 1
    fi
  done
fi

CODE="$(github_request GET "/user" "$TMP_BODY")"
check_response "$CODE" "$TMP_BODY" "Authenticated user lookup"
TOKEN_ACTOR="$(json_value "$TMP_BODY" login)"
echo "GitHub token actor: ${TOKEN_ACTOR}"

NOTIFY_TARGETS=()
if [[ -n "${GITHUB_NOTIFY_USERNAME:-}" ]]; then
  NOTIFY_TARGETS+=("$GITHUB_NOTIFY_USERNAME")
fi
if [[ -n "${GITHUB_NOTIFY_ASSIGNEES:-}" ]]; then
  IFS=',' read -r -a notify_assignees <<<"$GITHUB_NOTIFY_ASSIGNEES"
  for username in "${notify_assignees[@]}"; do
    username="$(echo "$username" | xargs)"
    if [[ -n "$username" ]]; then
      NOTIFY_TARGETS+=("$username")
    fi
  done
fi

if [[ "${#NOTIFY_TARGETS[@]}" == "0" ]]; then
  echo "Warning: no GITHUB_NOTIFY_USERNAME or GITHUB_NOTIFY_ASSIGNEES set; completion comments may not alert GitHub Mobile." >&2
else
  TOKEN_ACTOR_KEY="$(normalize_login "$TOKEN_ACTOR")"
  DIFFERENT_NOTIFY_TARGET=0
  for username in "${NOTIFY_TARGETS[@]}"; do
    if [[ "$(normalize_login "$username")" != "$TOKEN_ACTOR_KEY" ]]; then
      DIFFERENT_NOTIFY_TARGET=1
      break
    fi
  done
  if [[ "$DIFFERENT_NOTIFY_TARGET" != "1" ]]; then
    echo "Warning: notify targets match the token actor. GitHub Mobile may suppress self-triggered notifications; use a bot/secondary token on the Mac for more reliable alerts." >&2
  fi
fi

if [[ ! -x /Applications/Codex.app/Contents/Resources/codex ]]; then
  echo "Warning: /Applications/Codex.app/Contents/Resources/codex was not found. Install Codex Desktop on this Mac before starting the bridge." >&2
else
  echo "Codex Desktop CLI: found"
fi

if [[ "$CHECK_BRIDGE" == "1" ]]; then
  BRIDGE_HOST="${BRIDGE_HOST:-127.0.0.1}"
  BRIDGE_PORT="${BRIDGE_PORT:-8787}"
  BRIDGE_URL="${BRIDGE_URL:-http://${BRIDGE_HOST}:${BRIDGE_PORT}}"
  BRIDGE_URL="${BRIDGE_URL%/}"
  CURL_ARGS=(-fsS)
  if [[ -n "${BRIDGE_TOKEN:-}" ]]; then
    CURL_ARGS+=(-H "authorization: Bearer ${BRIDGE_TOKEN}")
  fi
  curl "${CURL_ARGS[@]}" "${BRIDGE_URL}/health" >/dev/null
  echo "Bridge health: ok at ${BRIDGE_URL}"
fi

echo "GitHub inbox check passed."
