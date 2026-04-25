#!/bin/bash
# Restart ClawGate.app + OpenClaw Gateway on remote Intel Mac mini.
#
# IMPORTANT: This script no longer builds or codesigns. The previous SSH-driven
# codesign path was unreliable (errSecInternalComponent on remote keychain
# unlock) and silently rolled back the app bundle, leaving ClawGate.app running
# unsigned. That broke TCC and took LINE down repeatedly.
#
# Build/sign flow is now exclusive to macmini-local-sign-and-restart.sh, which
# must be run on the macmini local desktop session (NOT via SSH).
#
# Usage (restart-only, no build, no codesign):
#   ./scripts/restart-macmini-openclaw.sh
#   ./scripts/restart-macmini-openclaw.sh --remote-host macmini
#
# Build/sign on remote: NOT SUPPORTED. Run on macmini local desktop:
#   ssh macmini   # then in the desktop Terminal:
#   KEYCHAIN_PASSWORD='...' ./scripts/macmini-local-sign-and-restart.sh

set -euo pipefail

REMOTE_HOST="macmini"
SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
PROJECT_PATH="${PROJECT_PATH:-$(cd "$SCRIPT_DIR/.." && pwd)}"
STOP_RELAY=false
CLAWGATE_ROLE="host_b_client"
OPS_SCRIPT_NAME="restart-macmini-openclaw.sh"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote-host)
      REMOTE_HOST="$2"; shift 2 ;;
    --project-path)
      PROJECT_PATH="$2"; shift 2 ;;
    --skip-build)
      # Accepted for backward-compat with callers (e.g. post-task-restart.sh).
      # Build is always skipped now; this flag is a no-op.
      shift ;;
    --stop-relay)
      STOP_RELAY=true; shift ;;
    --keep-relay)
      STOP_RELAY=false; shift ;;
    --help|-h)
      sed -n '1,20p' "$0"
      exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Build/sign on remote is no longer supported. See header for guidance." >&2
      exit 2 ;;
  esac
done

source "$PROJECT_PATH/scripts/lib-ops-log.sh"
ops_log info "remote_restart_begin" "server restart requested (remote_host=$REMOTE_HOST stop_relay=$STOP_RELAY restart_only)"
trap 'ops_log error "remote_restart_failed" "server restart failed (line=$LINENO exit=$?)"' ERR

echo "Remote host: $REMOTE_HOST"
echo "Project path: $PROJECT_PATH"
echo "Stop relay: $STOP_RELAY"
echo "Mode: restart-only (build/codesign delegated to macmini-local-sign-and-restart.sh)"

if ! ssh -o ConnectTimeout=8 "$REMOTE_HOST" "echo ok" >/dev/null 2>&1; then
  echo "Cannot SSH to '$REMOTE_HOST'" >&2
  exit 1
fi

STOP_RELAY_FLAG="0"
if [[ "$STOP_RELAY" == "true" ]]; then
  STOP_RELAY_FLAG="1"
fi

ssh "$REMOTE_HOST" "PROJECT_PATH='$PROJECT_PATH' STOP_RELAY_FLAG='$STOP_RELAY_FLAG' /bin/zsh -lc '
set -euo pipefail
CLAWGATE_ROLE=\"host_a_server\"
OPS_SCRIPT_NAME=\"restart-macmini-openclaw.remote\"
source \"\$PROJECT_PATH/scripts/lib-ops-log.sh\"
ops_log info \"remote_begin\" \"remote restart started (restart_only stop_relay=\$STOP_RELAY_FLAG)\"
trap '\''ops_log error \"remote_failed\" \"remote restart failed (line=\$LINENO exit=\$?)\"'\'' ERR
cd \"\$PROJECT_PATH\"
APP_PATH=\"\$PROJECT_PATH/ClawGate.app\"
APP_BIN=\"\$APP_PATH/Contents/MacOS/ClawGate\"

# Verify the app is signed with the canonical Developer ID Application identity.
# If signature is missing or wrong, fail fast with a clear remediation pointer
# (do NOT proceed with restart on an unsigned bundle — that path silently breaks
# TCC and we have memory feedback_tcc_stable_signing.md for the incident).
CURRENT_AUTH=\$(codesign -dv --verbose=4 \"\$APP_PATH\" 2>&1 | sed -n \"s/^Authority=//p\" | head -n 1 || true)
case \"\$CURRENT_AUTH\" in
  Developer\\ ID\\ Application*)
    echo \"[remote] signature OK: \$CURRENT_AUTH\"
    ;;
  ClawGate\\ Dev)
    echo \"[remote] WARN: legacy ClawGate Dev signature in use (Developer ID preferred for stable TCC binding)\" >&2
    ;;
  *)
    echo \"[remote] ERROR: ClawGate.app signature is missing or invalid (Authority=\\\"\$CURRENT_AUTH\\\").\" >&2
    echo \"[remote]\" >&2
    echo \"[remote] Cannot restart safely — running an unsigned bundle breaks TCC (Screen Recording / Accessibility),\" >&2
    echo \"[remote] which previously took LINE down for hours. See memory/feedback_tcc_stable_signing.md.\" >&2
    echo \"[remote]\" >&2
    echo \"[remote] To fix, run on macmini LOCAL desktop session (NOT via SSH):\" >&2
    echo \"[remote]   KEYCHAIN_PASSWORD=\\\"...\\\" ./scripts/macmini-local-sign-and-restart.sh\" >&2
    exit 1
    ;;
esac

# Canonical local restart path (single source of truth, no build/sign here).
./scripts/restart-local-clawgate.sh --skip-build --skip-sync --skip-sign
sleep 1

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
ps aux | grep \"\$APP_BIN\" | grep -v grep || true
echo \"[remote] app binary arch:\"
file \"\$APP_BIN\" || true
echo \"[remote] app signature authority:\"
codesign -dv --verbose=4 \"\$APP_PATH\" 2>&1 | sed -n \"s/^Authority=//p\" | head -n 1 || true
echo \"[remote] gateway launchctl:\"
launchctl list | grep ai.openclaw.gateway || true
echo \"[remote] health:\"
curl -sS http://127.0.0.1:8765/v1/health || true
ops_log info \"remote_ok\" \"remote restart finished\"
'"

echo "Done."
ops_log info "remote_restart_ok" "server restart finished"
