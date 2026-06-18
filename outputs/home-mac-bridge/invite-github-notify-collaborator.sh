#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${CODEX_REMOTE_ENV_FILE:-$HOME/.codex-remote-home-mac.env}"
APPLY=0

usage() {
  cat <<'EOF'
Usage:
  invite-github-notify-collaborator.sh [--env FILE] [--apply]

Checks or sends GitHub collaborator invitations for GITHUB_NOTIFY_USERNAME and
GITHUB_NOTIFY_ASSIGNEES. Without --apply, this is a dry run and prints what
would be invited. With --apply, it calls the GitHub Collaborators API.

The GitHub token must have permission to manage collaborators on the private repo.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)
      ENV_FILE="${2:?Missing value for --env}"
      shift 2
      ;;
    --apply)
      APPLY=1
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
  exit 1
fi

: "${GITHUB_OWNER:?Set GITHUB_OWNER in $ENV_FILE}"
: "${GITHUB_REPO:?Set GITHUB_REPO in $ENV_FILE}"

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

urlencode() {
  node -e 'console.log(encodeURIComponent(process.argv[1]))' "$1"
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

add_unique_target() {
  local username="$1"
  username="$(echo "$username" | xargs)"
  if [[ -z "$username" ]]; then
    return
  fi
  TARGETS+=("$username")
}

resolve_github_token

TARGETS=()
if [[ -n "${GITHUB_NOTIFY_USERNAME:-}" ]]; then
  add_unique_target "$GITHUB_NOTIFY_USERNAME"
fi
if [[ -n "${GITHUB_NOTIFY_ASSIGNEES:-}" ]]; then
  IFS=',' read -r -a notify_assignees <<<"$GITHUB_NOTIFY_ASSIGNEES"
  for username in "${notify_assignees[@]}"; do
    add_unique_target "$username"
  done
fi

if [[ "${#TARGETS[@]}" == "0" ]]; then
  echo "No notify targets configured. Set GITHUB_NOTIFY_USERNAME or GITHUB_NOTIFY_ASSIGNEES first." >&2
  exit 1
fi

PERMISSION="${GITHUB_NOTIFY_COLLABORATOR_PERMISSION:-push}"
OWNER_PATH="$(urlencode "$GITHUB_OWNER")"
REPO_PATH="$(urlencode "$GITHUB_REPO")"
BASE_PATH="/repos/${OWNER_PATH}/${REPO_PATH}"
TMP_BODY="$(mktemp)"
trap 'rm -f "$TMP_BODY"' EXIT

echo "Repository: ${GITHUB_OWNER}/${GITHUB_REPO}"
echo "Permission to request: ${PERMISSION}"

seen=""
for username in "${TARGETS[@]}"; do
  username="$(echo "$username" | xargs)"
  if [[ ",$seen," == *",$username,"* ]]; then
    continue
  fi
  seen="${seen},${username}"

  USER_PATH="$(urlencode "$username")"
  code="$(github_request GET "/users/${USER_PATH}" "$TMP_BODY")"
  if [[ ! "$code" =~ ^2 ]]; then
    echo "GitHub user '${username}' is not readable, HTTP ${code}." >&2
    sed -n '1,12p' "$TMP_BODY" >&2
    exit 1
  fi

  code="$(github_request GET "${BASE_PATH}/collaborators/${USER_PATH}" "$TMP_BODY")"
  if [[ "$code" == "204" || "$code" =~ ^2 ]]; then
    echo "Already collaborator: ${username}"
    continue
  fi

  if [[ "$APPLY" != "1" ]]; then
    echo "Would invite collaborator: ${username}"
    continue
  fi

  data="$(node -e 'console.log(JSON.stringify({permission: process.argv[1]}))' "$PERMISSION")"
  code="$(github_request PUT "${BASE_PATH}/collaborators/${USER_PATH}" "$TMP_BODY" "$data")"
  case "$code" in
    201)
      echo "Invitation created: ${username}"
      ;;
    204)
      echo "Already collaborator: ${username}"
      ;;
    *)
      echo "Collaborator invitation failed for '${username}', HTTP ${code}." >&2
      sed -n '1,16p' "$TMP_BODY" >&2
      exit 1
      ;;
  esac
done

if [[ "$APPLY" != "1" ]]; then
  cat <<EOF

Dry run only. To send invitations:
  CODEX_REMOTE_ENV_FILE="$ENV_FILE" "$SCRIPT_DIR/invite-github-notify-collaborator.sh" --apply

After the main account accepts the invitation, rerun:
  CODEX_REMOTE_ENV_FILE="$ENV_FILE" "$SCRIPT_DIR/doctor-github-inbox.sh"
EOF
fi
