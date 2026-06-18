#!/usr/bin/env bash
set -euo pipefail

OUTPUT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${CODEX_REMOTE_ENV_FILE:-$HOME/.codex-remote-home-mac.env}"
RUN_REAL_SMOKE=0
RUN_APP_BUILDS=0
FAILURES=0
WARNINGS=0

usage() {
  cat <<'EOF'
Usage:
  doctor-remote-office.sh [--env FILE] [--real-smoke] [--build-apps]

Checks the Codex Remote Office setup without installing background services.

Options:
  --env FILE     Home Mac env file. Defaults to ~/.codex-remote-home-mac.env
  --real-smoke   Run the real GitHub inbox smoke that creates and closes a test issue
  --build-apps   Build the iPhone and watchOS targets with CODE_SIGNING_ALLOWED=NO
  -h, --help    Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)
      ENV_FILE="${2:?Missing value for --env}"
      shift 2
      ;;
    --real-smoke)
      RUN_REAL_SMOKE=1
      shift
      ;;
    --build-apps)
      RUN_APP_BUILDS=1
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

pass() {
  printf 'PASS %s\n' "$1"
}

warn() {
  WARNINGS=$((WARNINGS + 1))
  printf 'WARN %s\n' "$1"
}

note() {
  printf 'NOTE %s\n' "$1"
}

fail() {
  FAILURES=$((FAILURES + 1))
  printf 'FAIL %s\n' "$1"
}

section() {
  printf '\n== %s ==\n' "$1"
}

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
  return 1
}

urlencode() {
  node -e 'console.log(encodeURIComponent(process.argv[1]))' "$1"
}

github_request() {
  local method="$1"
  local path="$2"
  local output_file="$3"
  local api_url="${GITHUB_API_URL:-https://api.github.com}"
  api_url="${api_url%/}"
  curl -sS \
    --retry 3 \
    --retry-delay 1 \
    --retry-all-errors \
    -o "$output_file" \
    -w "%{http_code}" \
    -X "$method" \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${api_url}${path}"
}

count_json_array() {
  node -e 'const fs=require("fs"); const data=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); console.log(Array.isArray(data) ? data.length : 0);' "$1"
}

load_env() {
  section "Environment"
  if [[ ! -f "$ENV_FILE" ]]; then
    fail "Env file missing: $ENV_FILE"
    return
  fi

  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
  pass "Loaded $ENV_FILE"

  if [[ "${CODEX_REMOTE_BACKEND:-}" == "github" ]]; then
    pass "Backend is github"
  else
    warn "CODEX_REMOTE_BACKEND is '${CODEX_REMOTE_BACKEND:-unset}', expected github for no-server mode"
  fi
}

check_github_preflight() {
  section "GitHub Inbox"
  if CODEX_REMOTE_ENV_FILE="$ENV_FILE" "$OUTPUT_DIR/home-mac-bridge/doctor-github-inbox.sh" >/tmp/codex-remote-doctor-github.out 2>&1; then
    pass "GitHub inbox preflight passed"
  else
    fail "GitHub inbox preflight failed"
    sed -n '1,80p' /tmp/codex-remote-doctor-github.out
    return
  fi

  if ! resolve_github_token; then
    fail "Could not resolve GitHub token"
    return
  fi

  local owner repo task_label owner_path repo_path label_path tmp_body code open_count
  owner="${GITHUB_OWNER:-}"
  repo="${GITHUB_REPO:-}"
  task_label="${GITHUB_TASK_LABEL:-codex-remote}"
  if [[ -z "$owner" || -z "$repo" ]]; then
    fail "GITHUB_OWNER or GITHUB_REPO is missing"
    return
  fi

  owner_path="$(urlencode "$owner")"
  repo_path="$(urlencode "$repo")"
  label_path="$(urlencode "$task_label")"
  tmp_body="$(mktemp)"
  code="$(github_request GET "/repos/${owner_path}/${repo_path}/issues?state=open&labels=${label_path}&per_page=30" "$tmp_body")"
  if [[ "$code" =~ ^2 ]]; then
    open_count="$(count_json_array "$tmp_body")"
    pass "Open '${task_label}' tasks: ${open_count}"
  else
    fail "Could not list open GitHub inbox tasks, HTTP ${code}"
    sed -n '1,20p' "$tmp_body"
  fi
  rm -f "$tmp_body"
}

check_launch_agent() {
  section "Home Mac Service"
  local label plist
  label="com.codex.remote.home-mac"
  plist="$HOME/Library/LaunchAgents/${label}.plist"
  if [[ ! -f "$plist" ]]; then
    warn "$label is not installed"
    return
  fi

  if launchctl print "gui/$(id -u)/$label" >/tmp/codex-remote-launch-agent.out 2>&1; then
    pass "$label is loaded"
  else
    fail "$label is installed but not loaded"
    sed -n '1,80p' /tmp/codex-remote-launch-agent.out
  fi
}

check_processes() {
  section "Processes"
  local matches
  matches="$(pgrep -af 'github-issues-client|relay-client|bridge.mjs|start-home-mac' || true)"
  if [[ -n "$matches" ]]; then
    pass "Connector or bridge process is running"
    printf '%s\n' "$matches"
  else
    warn "No Home Mac connector process is currently running"
  fi
}

check_real_smoke() {
  section "Real End-to-End Smoke"
  if [[ "$RUN_REAL_SMOKE" != "1" ]]; then
    note "Skipped real smoke; pass --real-smoke to create and close a temporary GitHub issue"
    return
  fi

  if CODEX_REMOTE_ENV_FILE="$ENV_FILE" "$OUTPUT_DIR/smoke-github-inbox-real.sh"; then
    pass "Real GitHub inbox smoke passed"
  else
    fail "Real GitHub inbox smoke failed"
  fi
}

check_app_builds() {
  section "Mobile Builds"
  if [[ "$RUN_APP_BUILDS" != "1" ]]; then
    note "Skipped iPhone/watchOS builds; pass --build-apps to run xcodebuild"
    return
  fi

  if xcodebuild -project "$OUTPUT_DIR/apps/CodexRemote/CodexRemote.xcodeproj" \
    -scheme CodexRemote \
    -destination 'platform=iOS Simulator,name=iPhone 17' \
    CODE_SIGNING_ALLOWED=NO \
    build >/tmp/codex-remote-ios-build.out 2>&1; then
    pass "iPhone target builds"
  else
    fail "iPhone target build failed"
    tail -n 80 /tmp/codex-remote-ios-build.out
  fi

  if xcodebuild -project "$OUTPUT_DIR/apps/CodexRemote/CodexRemote.xcodeproj" \
    -scheme CodexRemoteWatch \
    -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)' \
    CODE_SIGNING_ALLOWED=NO \
    build >/tmp/codex-remote-watch-build.out 2>&1; then
    pass "watchOS target builds"
  else
    fail "watchOS target build failed"
    tail -n 80 /tmp/codex-remote-watch-build.out
  fi
}

load_env
check_github_preflight
check_launch_agent
check_processes
check_real_smoke
check_app_builds

section "Summary"
if [[ "$FAILURES" == "0" ]]; then
  if [[ "$WARNINGS" == "0" ]]; then
    pass "Remote office checks passed"
  else
    printf 'WARN Remote office checks passed with %s warning(s)\n' "$WARNINGS"
  fi
else
  printf 'FAIL Remote office checks failed with %s failure(s) and %s warning(s)\n' "$FAILURES" "$WARNINGS"
fi

if [[ "$FAILURES" != "0" ]]; then
  exit 1
fi
