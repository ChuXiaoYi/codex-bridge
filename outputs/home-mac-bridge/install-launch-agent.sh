#!/usr/bin/env bash
set -euo pipefail

LABEL="com.codex.remote.home-mac"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${CODEX_REMOTE_ENV_FILE:-$HOME/.codex-remote-home-mac.env}"
SUPPORT_DIR="$HOME/Library/Application Support/CodexRemote"
LOG_DIR="$HOME/Library/Logs"
RUNNER="$SUPPORT_DIR/run-home-mac.sh"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"

mkdir -p "$SUPPORT_DIR" "$HOME/Library/LaunchAgents" "$LOG_DIR"

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
START_SCRIPT="$SCRIPT_DIR/start-home-mac.sh"

if [[ "$BACKEND" == "github" ]]; then
  START_SCRIPT="$SCRIPT_DIR/start-home-mac-github.sh"
  if [[ -z "${GITHUB_TOKEN:-}" || "$GITHUB_TOKEN" == "github_pat_replace_me" ]]; then
    echo "Set GITHUB_TOKEN in $ENV_FILE before installing the LaunchAgent." >&2
    exit 1
  fi
  if [[ -z "${GITHUB_OWNER:-}" || -z "${GITHUB_REPO:-}" ]]; then
    echo "Set GITHUB_OWNER and GITHUB_REPO in $ENV_FILE before installing the LaunchAgent." >&2
    exit 1
  fi
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

cat >"$RUNNER" <<EOF
#!/usr/bin/env bash
set -euo pipefail
set -a
source "$ENV_FILE"
set +a
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
  <string>$SCRIPT_DIR</string>
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
