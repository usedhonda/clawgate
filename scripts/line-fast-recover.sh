#!/usr/bin/env bash
set -euo pipefail

# Fast recovery path for LINE-core operations (Host A only):
# - Restart OpenClaw gateway by default.
# - Host A app restart is opt-in (to avoid triggering macOS re-authorization loops).
# - Verify Host A readiness (health/doctor/poll).
# - Never depend on Host B relay/federation in this script.
#
# Usage:
#   ./scripts/line-fast-recover.sh
#   ./scripts/line-fast-recover.sh --remote-host macmini
#   ./scripts/line-fast-recover.sh --restart-hosta-app
#   KEYCHAIN_PASSWORD='...' ./scripts/line-fast-recover.sh --setup-cert

REMOTE_HOST="macmini"
SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
PROJECT_PATH="${PROJECT_PATH:-$(cd "$SCRIPT_DIR/.." && pwd)}"
RESTART_GATEWAY=true
RESTART_HOSTA_APP=false
RUN_CERT_SETUP=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote-host)
      REMOTE_HOST="$2"; shift 2 ;;
    --project-path)
      PROJECT_PATH="$2"; shift 2 ;;
    --restart-gateway)
      RESTART_GATEWAY=true; shift ;;
    --no-restart-gateway)
      RESTART_GATEWAY=false; shift ;;
    --restart-hosta-app)
      RESTART_HOSTA_APP=true; shift ;;
    --no-restart-hosta-app)
      RESTART_HOSTA_APP=false; shift ;;
    --setup-cert)
      RUN_CERT_SETUP=true; shift ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 2 ;;
  esac
done

echo "== line-fast-recover =="
echo "Remote host: $REMOTE_HOST"
echo "Project path: $PROJECT_PATH"
echo "Restart gateway: $RESTART_GATEWAY"
echo "Restart hostA app: $RESTART_HOSTA_APP"
echo "Run cert setup: $RUN_CERT_SETUP"

if [[ "$RESTART_HOSTA_APP" != "true" ]]; then
  echo "Policy: Host A app restart is disabled by default to avoid permission re-prompts."
fi

if [[ "$RESTART_GATEWAY" != "true" ]]; then
  echo "ERROR: --no-restart-gateway is not allowed for LINE fast recovery." >&2
  echo "       Use this script with gateway restart enabled." >&2
  exit 2
fi

if [[ "$RUN_CERT_SETUP" == "true" ]]; then
  if [[ -z "${KEYCHAIN_PASSWORD:-}" ]]; then
    echo "ERROR: --setup-cert requires KEYCHAIN_PASSWORD env." >&2
    exit 1
  fi
  ./scripts/setup-cert-macmini.sh \
    --remote-host "$REMOTE_HOST" \
    --project-path "$PROJECT_PATH" \
    --keychain-password "$KEYCHAIN_PASSWORD"
fi

if [[ "$RESTART_HOSTA_APP" == "true" ]]; then
  echo "[remote] Restart Host A ClawGate app"
  ssh "$REMOTE_HOST" "pkill -f '$PROJECT_PATH/ClawGate.app/Contents/MacOS/ClawGate' >/dev/null 2>&1 || true; sleep 1; open -na '$PROJECT_PATH/ClawGate.app'; sleep 2"
fi

echo "[remote] Restart OpenClaw gateway"
OLD_GATEWAY_PID="$(ssh "$REMOTE_HOST" "launchctl list | awk '\$3==\"ai.openclaw.gateway\" {print \$1}' | head -n1" | tr -d '\r')"
ssh "$REMOTE_HOST" "launchctl stop ai.openclaw.gateway >/dev/null 2>&1 || true; sleep 1; launchctl start ai.openclaw.gateway >/dev/null 2>&1 || true; sleep 2"
NEW_GATEWAY_PID="$(ssh "$REMOTE_HOST" "launchctl list | awk '\$3==\"ai.openclaw.gateway\" {print \$1}' | head -n1" | tr -d '\r')"

if [[ -z "$NEW_GATEWAY_PID" || "$NEW_GATEWAY_PID" == "-" ]]; then
  echo "ERROR: OpenClaw gateway is not running after restart." >&2
  exit 1
fi
if [[ -n "$OLD_GATEWAY_PID" && "$OLD_GATEWAY_PID" != "-" && "$OLD_GATEWAY_PID" == "$NEW_GATEWAY_PID" ]]; then
  echo "WARN: Gateway PID did not change ($NEW_GATEWAY_PID). Service may have reused process." >&2
fi
echo "[remote] Gateway PID: ${OLD_GATEWAY_PID:-none} -> $NEW_GATEWAY_PID"

echo "[remote] Host A health:"
ssh "$REMOTE_HOST" "curl -sS -m 5 http://127.0.0.1:8765/v1/health"
echo

echo "[remote] Host A doctor:"
DOCTOR_JSON="$(ssh "$REMOTE_HOST" "curl -sS -m 5 http://127.0.0.1:8765/v1/doctor")"
echo "$DOCTOR_JSON"
echo

CHECK_STATUS="$(python3 - "$DOCTOR_JSON" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
checks = {c.get("name"): c.get("status") for c in d.get("checks", [])}
print("|".join([
    checks.get("app_signature", ""),
    checks.get("accessibility_permission", ""),
    checks.get("screen_recording_permission", ""),
]))
PY
)"

SIG_STATUS="$(echo "$CHECK_STATUS" | cut -d'|' -f1)"
ACCESS_STATUS="$(echo "$CHECK_STATUS" | cut -d'|' -f2)"
SCREEN_STATUS="$(echo "$CHECK_STATUS" | cut -d'|' -f3)"

if [[ -z "$SIG_STATUS" ]]; then
  echo "[remote] doctor has no app_signature; falling back to codesign authority check"
  REMOTE_AUTH="$(ssh "$REMOTE_HOST" "codesign -dv --verbose=4 '$PROJECT_PATH/ClawGate.app' 2>&1 | sed -n 's/^Authority=//p' | head -n 1 || true" | tr -d '\r')"
  if [[ "$REMOTE_AUTH" == "ClawGate Dev" ]]; then
    SIG_STATUS="ok"
  else
    echo "ERROR: Host A signature authority is '$REMOTE_AUTH' (expected ClawGate Dev)." >&2
    exit 1
  fi
fi

if [[ "$SIG_STATUS" != "ok" ]]; then
  echo "ERROR: Host A app signature is not ClawGate Dev. Re-sign on Host A local session." >&2
  exit 1
fi

if [[ "$ACCESS_STATUS" != "ok" ]]; then
  echo "ERROR: Host A accessibility is not granted. Fix in GUI first." >&2
  exit 1
fi

if [[ "$SCREEN_STATUS" != "ok" ]]; then
  echo "ERROR: Host A screen recording is not granted. OCR-based inbound cannot run." >&2
  exit 1
fi

echo "[remote] Poll smoke:"
POLL_JSON="$(ssh "$REMOTE_HOST" "curl -sS -m 5 'http://127.0.0.1:8765/v1/poll?since=0'")"
echo "$POLL_JSON"
echo

echo "Done. LINE core is ready on Host A."
