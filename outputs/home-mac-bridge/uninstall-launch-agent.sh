#!/usr/bin/env bash
set -euo pipefail

LABEL="com.codex.remote.home-mac"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"

launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true
rm -f "$PLIST"

echo "Uninstalled $LABEL."
