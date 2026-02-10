#!/bin/bash
# Rebuild and restart ClawGate + OpenClaw Gateway on remote Intel Mac mini.
#
# Usage:
#   ./scripts/restart-macmini-openclaw.sh
#   ./scripts/restart-macmini-openclaw.sh --remote-host macmini --project-path /Users/usedhonda/projects/ios/clawgate

set -euo pipefail

REMOTE_HOST="macmini"
PROJECT_PATH="/Users/usedhonda/projects/ios/clawgate"
SKIP_BUILD=false
STOP_RELAY=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote-host)
      REMOTE_HOST="$2"; shift 2 ;;
    --project-path)
      PROJECT_PATH="$2"; shift 2 ;;
    --skip-build)
      SKIP_BUILD=true; shift ;;
    --keep-relay)
      STOP_RELAY=false; shift ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2 ;;
  esac
done

echo "Remote host: $REMOTE_HOST"
echo "Project path: $PROJECT_PATH"
echo "Stop relay: $STOP_RELAY"

if ! ssh -o ConnectTimeout=8 "$REMOTE_HOST" "echo ok" >/dev/null 2>&1; then
  echo "Cannot SSH to '$REMOTE_HOST'" >&2
  exit 1
fi

BUILD_FLAG="1"
if [[ "$SKIP_BUILD" == "true" ]]; then
  BUILD_FLAG="0"
fi
STOP_RELAY_FLAG="1"
if [[ "$STOP_RELAY" != "true" ]]; then
  STOP_RELAY_FLAG="0"
fi

ssh "$REMOTE_HOST" "PROJECT_PATH='$PROJECT_PATH' BUILD_FLAG='$BUILD_FLAG' STOP_RELAY_FLAG='$STOP_RELAY_FLAG' /bin/zsh -lc '
set -euo pipefail
cd \"\$PROJECT_PATH\"

if [[ \"\$BUILD_FLAG\" == \"1\" ]]; then
  echo \"[remote] swift build (Intel)\"
  swift build
fi

if [[ ! -f .build/debug/ClawGate ]]; then
  echo \"[remote] missing .build/debug/ClawGate\" >&2
  exit 1
fi

cp .build/debug/ClawGate ClawGate.app/Contents/MacOS/ClawGate
# Prefer stable dev identity to reduce TCC permission churn.
if security find-identity -v -p codesigning 2>/dev/null | grep -q \"ClawGate Dev\"; then
  codesign --force --deep --options runtime \
    --entitlements ClawGate.entitlements \
    --sign \"ClawGate Dev\" ClawGate.app >/dev/null 2>&1 || true
else
  codesign --force --deep --sign - ClawGate.app >/dev/null 2>&1 || true
fi

# Stop old app from both historical and current paths, then launch current one.
pkill -f \"/Users/usedhonda/projects/Mac/clawgate/ClawGate.app/Contents/MacOS/ClawGate\" >/dev/null 2>&1 || true
pkill -f \"/Users/usedhonda/projects/ios/clawgate/ClawGate.app/Contents/MacOS/ClawGate\" >/dev/null 2>&1 || true
sleep 1
open -na /Users/usedhonda/projects/ios/clawgate/ClawGate.app
sleep 2

launchctl stop ai.openclaw.gateway >/dev/null 2>&1 || true
sleep 2
launchctl start ai.openclaw.gateway >/dev/null 2>&1 || true
sleep 2

if [[ \"\$STOP_RELAY_FLAG\" == \"1\" ]]; then
  pkill -f \"ClawGateRelay --host\" >/dev/null 2>&1 || true
  pkill -f \"swift run ClawGateRelay\" >/dev/null 2>&1 || true
  sleep 1
fi

echo \"[remote] app process:\"
ps aux | grep \"/Users/usedhonda/projects/ios/clawgate/ClawGate.app/Contents/MacOS/ClawGate\" | grep -v grep || true
echo \"[remote] app binary arch:\"
file /Users/usedhonda/projects/ios/clawgate/ClawGate.app/Contents/MacOS/ClawGate || true
echo \"[remote] gateway launchctl:\"
launchctl list | grep ai.openclaw.gateway || true
echo \"[remote] health:\"
curl -sS http://127.0.0.1:8765/v1/health || true
'"

echo "Done."
