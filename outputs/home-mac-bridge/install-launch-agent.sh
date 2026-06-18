#!/usr/bin/env bash
set -euo pipefail

LABEL="com.codex.remote.home-mac"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_BRIDGE_CWD="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="${CODEX_REMOTE_ENV_FILE:-$HOME/.codex-remote-home-mac.env}"
SUPPORT_DIR="$HOME/Library/Application Support/CodexRemote"
BUNDLE_DIR="$SUPPORT_DIR/home-mac-bridge"
LOG_DIR="$HOME/Library/Logs"
RUNNER="$SUPPORT_DIR/run-home-mac.sh"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"

mkdir -p "$SUPPORT_DIR" "$BUNDLE_DIR" "$HOME/Library/LaunchAgents" "$LOG_DIR"

if [[ ! -f "$ENV_FILE" ]]; then
  cp "$SCRIPT_DIR/home-mac.env.example" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  echo "Created $ENV_FILE. Edit it with your RELAY_URL and RELAY_BRIDGE_TOKEN, then run this installer again." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

BACKEND="${CODEX_REMOTE_BACKEND:-http}"
START_SCRIPT="$BUNDLE_DIR/start-home-mac.sh"

if [[ "$BACKEND" == "github" ]]; then
  START_SCRIPT="$BUNDLE_DIR/start-home-mac-github.sh"
  if [[ -z "${GITHUB_TOKEN:-}" && -z "${GITHUB_TOKEN_COMMAND:-}" ]] \
    && ! command -v gh >/dev/null 2>&1 \
    && [[ ! -x /opt/homebrew/bin/gh ]] \
    && [[ ! -x /usr/local/bin/gh ]]; then
    echo "Set GITHUB_TOKEN or GITHUB_TOKEN_COMMAND in $ENV_FILE, or install/login GitHub CLI before installing the LaunchAgent." >&2
    exit 1
  fi
  if [[ "${GITHUB_TOKEN:-}" == "github_pat_replace_me" ]]; then
    echo "Replace the placeholder GITHUB_TOKEN in $ENV_FILE before installing the LaunchAgent." >&2
    exit 1
  fi
  if [[ -z "${GITHUB_OWNER:-}" || -z "${GITHUB_REPO:-}" ]]; then
    echo "Set GITHUB_OWNER and GITHUB_REPO in $ENV_FILE before installing the LaunchAgent." >&2
    exit 1
  fi
  CODEX_REMOTE_ENV_FILE="$ENV_FILE" "$SCRIPT_DIR/doctor-github-inbox.sh"
else
  if [[ -z "${RELAY_URL:-}" || "$RELAY_URL" == "https://your-relay.example.com" ]]; then
    echo "Set RELAY_URL in $ENV_FILE before installing the LaunchAgent." >&2
    exit 1
  fi
  if [[ -z "${RELAY_BRIDGE_TOKEN:-}" || "$RELAY_BRIDGE_TOKEN" == "replace-with-a-long-random-token" ]]; then
    echo "Set RELAY_BRIDGE_TOKEN in $ENV_FILE before installing the LaunchAgent." >&2
    exit 1
  fi
fi

cp "$SCRIPT_DIR/bridge.mjs" \
  "$SCRIPT_DIR/github-issues-client.mjs" \
  "$SCRIPT_DIR/relay-client.mjs" \
  "$SCRIPT_DIR/start-home-mac.sh" \
  "$SCRIPT_DIR/start-home-mac-github.sh" \
  "$BUNDLE_DIR/"
chmod 700 "$BUNDLE_DIR/start-home-mac.sh" "$BUNDLE_DIR/start-home-mac-github.sh"

cat >"$RUNNER" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:\${PATH:-}"
set -a
source "$ENV_FILE"
set +a
if [[ -z "\${BRIDGE_CWD:-}" ]]; then
  export BRIDGE_CWD="$DEFAULT_BRIDGE_CWD"
fi
cd "$SUPPORT_DIR"
exec "$START_SCRIPT"
EOF
chmod 700 "$RUNNER"

cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$RUNNER</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$LOG_DIR/codex-remote-home-mac.out.log</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR/codex-remote-home-mac.err.log</string>
  <key>WorkingDirectory</key>
  <string>$SUPPORT_DIR</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl kickstart -k "gui/$(id -u)/$LABEL"

echo "Installed and started $LABEL."
echo "Logs:"
echo "  $LOG_DIR/codex-remote-home-mac.out.log"
echo "  $LOG_DIR/codex-remote-home-mac.err.log"
