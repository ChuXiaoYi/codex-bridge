#!/usr/bin/env bash
set -euo pipefail

LABEL="com.codex.remote.home-mac"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"

if [[ ! -f "$PLIST" ]]; then
  echo "$LABEL is not installed."
  exit 0
fi

launchctl print "gui/$(id -u)/$LABEL" || {
  echo "$LABEL is installed but not loaded."
  exit 1
}
