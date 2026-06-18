#!/usr/bin/env bash
set -euo pipefail

OUTPUT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${CODEX_REMOTE_ENV_FILE:-$HOME/.codex-remote-home-mac.env}"
RUN_REAL_SMOKE=0
RUN_SERVICE_SMOKE=0
RUN_MOBILE_CONTRACT=0
RUN_APP_BUILDS=0
STRICT=0
FAILURES=0
WARNINGS=0

usage() {
  cat <<'EOF'
Usage:
  doctor-remote-office.sh [--env FILE] [--real-smoke] [--service-smoke] [--mobile-contract] [--build-apps] [--strict]
  doctor-remote-office.sh [--env FILE] --ready

Checks the Codex Remote Office setup without installing background services.

Options:
  --env FILE     Home Mac env file. Defaults to ~/.codex-remote-home-mac.env
  --real-smoke   Run the real GitHub inbox smoke that creates and closes a test issue
  --service-smoke Run a real GitHub smoke through the installed Home Mac service
  --mobile-contract Run a GitHub create/list/comment smoke matching the mobile app contract
  --build-apps   Build the iPhone and watchOS targets with CODE_SIGNING_ALLOWED=NO
  --strict       Exit non-zero when any warnings remain
  --ready        Full readiness gate: --service-smoke --mobile-contract --build-apps --strict
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
    --service-smoke)
      RUN_SERVICE_SMOKE=1
      shift
      ;;
    --mobile-contract)
      RUN_MOBILE_CONTRACT=1
      shift
      ;;
    --build-apps)
      RUN_APP_BUILDS=1
      shift
      ;;
    --strict)
      STRICT=1
      shift
      ;;
    --ready)
      RUN_SERVICE_SMOKE=1
      RUN_MOBILE_CONTRACT=1
      RUN_APP_BUILDS=1
      STRICT=1
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

count_pending_github_tasks() {
  local file="$1"
  local done_label="$2"
  node - "$file" "$done_label" <<'NODE'
const fs = require("fs");
const [, , file, doneLabel] = process.argv;
const issues = JSON.parse(fs.readFileSync(file, "utf8"));
let pending = 0;
let completedOpen = 0;
for (const issue of Array.isArray(issues) ? issues : []) {
  const labels = new Set((issue.labels || []).map((label) => label.name));
  if (doneLabel && labels.has(doneLabel)) completedOpen += 1;
  else pending += 1;
}
console.log(`${pending} ${completedOpen}`);
NODE
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

  local owner repo task_label done_label owner_path repo_path label_path tmp_body code counts pending_count completed_open_count
  owner="${GITHUB_OWNER:-}"
  repo="${GITHUB_REPO:-}"
  task_label="${GITHUB_TASK_LABEL:-codex-remote}"
  done_label="${GITHUB_DONE_LABEL:-codex-done}"
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
    counts="$(count_pending_github_tasks "$tmp_body" "$done_label")"
    pending_count="${counts%% *}"
    completed_open_count="${counts##* }"
    pass "Open pending '${task_label}' tasks: ${pending_count}"
    if [[ "$completed_open_count" != "0" ]]; then
      note "Open completed '${task_label}' issues with '${done_label}': ${completed_open_count}"
    fi
  else
    fail "Could not list open GitHub inbox tasks, HTTP ${code}"
    sed -n '1,20p' "$tmp_body"
  fi
  rm -f "$tmp_body"
}

check_github_notifications() {
  section "GitHub Mobile Notification Path"
  if [[ "${CODEX_REMOTE_BACKEND:-}" != "github" ]]; then
    note "Skipped; CODEX_REMOTE_BACKEND is not github"
    return
  fi

  if ! resolve_github_token; then
    fail "Could not resolve GitHub token for notification checks"
    return
  fi

  local tmp_body code actor actor_key targets_count same_actor_count different_actor_count target target_key username
  tmp_body="$(mktemp)"
  code="$(github_request GET "/user" "$tmp_body")"
  if [[ "$code" =~ ^2 ]]; then
    actor="$(json_value "$tmp_body" login)"
    pass "GitHub token actor: ${actor}"
  else
    fail "Could not identify GitHub token actor, HTTP ${code}"
    sed -n '1,20p' "$tmp_body"
    rm -f "$tmp_body"
    return
  fi
  rm -f "$tmp_body"

  actor_key="$(normalize_login "$actor")"
  targets_count=0
  same_actor_count=0
  different_actor_count=0

  if [[ -n "${GITHUB_NOTIFY_USERNAME:-}" ]]; then
    targets_count=$((targets_count + 1))
    target_key="$(normalize_login "$GITHUB_NOTIFY_USERNAME")"
    if [[ "$target_key" == "$actor_key" ]]; then
      same_actor_count=$((same_actor_count + 1))
    else
      different_actor_count=$((different_actor_count + 1))
    fi
  fi

  if [[ -n "${GITHUB_NOTIFY_ASSIGNEES:-}" ]]; then
    IFS=',' read -r -a notify_assignees <<<"$GITHUB_NOTIFY_ASSIGNEES"
    for username in "${notify_assignees[@]}"; do
      target="$(printf '%s' "$username" | xargs)"
      if [[ -z "$target" ]]; then
        continue
      fi
      targets_count=$((targets_count + 1))
      target_key="$(normalize_login "$target")"
      if [[ "$target_key" == "$actor_key" ]]; then
        same_actor_count=$((same_actor_count + 1))
      else
        different_actor_count=$((different_actor_count + 1))
      fi
    done
  fi

  if [[ "$targets_count" == "0" ]]; then
    warn "No GITHUB_NOTIFY_USERNAME or GITHUB_NOTIFY_ASSIGNEES set; completion comments may not alert GitHub Mobile"
  elif [[ "$different_actor_count" == "0" && "$same_actor_count" -gt "0" ]]; then
    warn "GitHub notify target is the same account as the token actor; GitHub Mobile may suppress self-triggered notifications"
    note "For reliable alerts, use a bot/secondary token on the Mac and set notify username/assignees to your main account"
  else
    pass "At least one notify target differs from the token actor"
  fi

  note "This Mac cannot inspect iPhone/Watch GitHub Mobile notification settings; confirm them on device"
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

check_service_smoke() {
  section "Installed Service Smoke"
  if [[ "$RUN_SERVICE_SMOKE" != "1" ]]; then
    note "Skipped service smoke; pass --service-smoke to test the installed Home Mac service"
    return
  fi

  if CODEX_REMOTE_ENV_FILE="$ENV_FILE" "$OUTPUT_DIR/smoke-github-inbox-service.sh"; then
    pass "Installed service smoke passed"
  else
    fail "Installed service smoke failed"
  fi
}

check_mobile_contract() {
  section "Mobile GitHub Contract Smoke"
  if [[ "$RUN_MOBILE_CONTRACT" != "1" ]]; then
    note "Skipped mobile contract smoke; pass --mobile-contract to test create/list/comment via GitHub"
    return
  fi

  if CODEX_REMOTE_ENV_FILE="$ENV_FILE" "$OUTPUT_DIR/smoke-mobile-github-contract.sh"; then
    pass "Mobile GitHub contract smoke passed"
  else
    fail "Mobile GitHub contract smoke failed"
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
check_github_notifications
check_launch_agent
check_processes
check_real_smoke
check_service_smoke
check_mobile_contract
check_app_builds

section "Summary"
EXIT_STATUS=0
if [[ "$FAILURES" == "0" ]]; then
  if [[ "$WARNINGS" == "0" ]]; then
    pass "Remote office checks passed"
  elif [[ "$STRICT" == "1" ]]; then
    printf 'FAIL Remote office strict readiness failed with %s warning(s)\n' "$WARNINGS"
    EXIT_STATUS=1
  else
    printf 'WARN Remote office checks passed with %s warning(s)\n' "$WARNINGS"
  fi
else
  printf 'FAIL Remote office checks failed with %s failure(s) and %s warning(s)\n' "$FAILURES" "$WARNINGS"
  EXIT_STATUS=1
fi

exit "$EXIT_STATUS"
