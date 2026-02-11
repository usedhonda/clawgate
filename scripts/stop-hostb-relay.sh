#!/usr/bin/env bash
set -euo pipefail

LABEL="com.clawgate.relay"
PLIST_PATH="$HOME/Library/LaunchAgents/${LABEL}.plist"
TMUX_SESSION="clawgate-relay"

launchctl bootout "gui/$UID/$LABEL" >/dev/null 2>&1 || true
launchctl bootout "gui/$UID" "$PLIST_PATH" >/dev/null 2>&1 || true
launchctl disable "gui/$UID/$LABEL" >/dev/null 2>&1 || true

tmux kill-session -t "$TMUX_SESSION" >/dev/null 2>&1 || true
pkill -f 'ClawGateRelay --host' >/dev/null 2>&1 || true
pkill -f 'swift run ClawGateRelay' >/dev/null 2>&1 || true

echo "Relay stopped."
