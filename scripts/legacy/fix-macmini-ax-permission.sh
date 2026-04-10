#!/bin/bash
# Help recover Accessibility permission for ClawGate on remote macmini.
#
# Usage:
#   ./scripts/fix-macmini-ax-permission.sh
#   ./scripts/fix-macmini-ax-permission.sh --remote-host macmini --wait-seconds 120
#   ./scripts/fix-macmini-ax-permission.sh --force-reset

set -euo pipefail

REMOTE_HOST="macmini"
WAIT_SECONDS=120
BUNDLE_ID="com.clawgate.app"
SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
PROJECT_PATH="${PROJECT_PATH:-$(cd "$SCRIPT_DIR/.." && pwd)}"
APP_PATH="$PROJECT_PATH/ClawGate.app"
FORCE_RESET=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote-host)
      REMOTE_HOST="$2"; shift 2 ;;
    --wait-seconds)
      WAIT_SECONDS="$2"; shift 2 ;;
    --bundle-id)
      BUNDLE_ID="$2"; shift 2 ;;
    --app-path)
      APP_PATH="$2"; shift 2 ;;
    --force-reset)
      FORCE_RESET=true; shift ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2 ;;
  esac
done

echo "Remote host: $REMOTE_HOST"
echo "Bundle ID: $BUNDLE_ID"
echo "App path: $APP_PATH"
echo "Force reset: $FORCE_RESET"

if ! ssh -o ConnectTimeout=8 "$REMOTE_HOST" "echo ok" >/dev/null 2>&1; then
  echo "Cannot SSH to '$REMOTE_HOST'" >&2
  exit 1
fi

ssh "$REMOTE_HOST" "FORCE_RESET='$FORCE_RESET' /bin/zsh -lc '
set -euo pipefail

if [[ \"$FORCE_RESET\" == \"true\" ]]; then
  tccutil reset Accessibility \"$BUNDLE_ID\" >/dev/null 2>&1 || true
fi

open \"$APP_PATH\" >/dev/null 2>&1 || true
open \"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility\" >/dev/null 2>&1 || true
osascript -e \"tell application \\\"System Settings\\\" to activate\" >/dev/null 2>&1 || true

echo \"Opened System Settings > Privacy > Accessibility on remote host.\"
echo \"Please enable ClawGate.app, then return here.\"
'"

echo "Waiting up to ${WAIT_SECONDS}s for Accessibility permission..."
for ((i=1; i<=WAIT_SECONDS; i++)); do
  DOCTOR_JSON="$(ssh "$REMOTE_HOST" "curl -sS http://127.0.0.1:8765/v1/doctor" 2>/dev/null || true)"
  ACCESS_STATUS="$(python3 - "$DOCTOR_JSON" <<'PY'
import json,sys
raw = sys.argv[1]
try:
    d = json.loads(raw)
    checks = d.get("checks", [])
    target = [c for c in checks if c.get("name") == "accessibility_permission"]
    if not target:
        print("")
    else:
        print(target[0].get("status",""))
except Exception:
    print("")
PY
)"
  if [[ "$ACCESS_STATUS" == "ok" ]]; then
    echo "Accessibility permission is now granted."
    exit 0
  fi
  sleep 1
done

echo "Timed out waiting for Accessibility permission."
echo "Verify manually on remote host: System Settings > Privacy & Security > Accessibility"
exit 1
