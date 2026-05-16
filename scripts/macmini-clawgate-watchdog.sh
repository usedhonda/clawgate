#!/bin/bash
# macmini ClawGate watchdog
# Invoked every 60s by ai.clawgate.watchdog LaunchAgent.
# If ClawGate.app process is not running, restart via canonical path then
# re-run /v1/doctor for sanity verification.

set -u

PROJECT_PATH="$HOME/projects/ios/clawgate"
APP_BIN_PAT="clawgate/ClawGate.app/Contents/MacOS/ClawGate"
LOG_DIR="$HOME/.openclaw/logs"
LOG="$LOG_DIR/clawgate-watchdog.log"
HEALTH_URL="http://127.0.0.1:8765/v1/health"
DOCTOR_URL="http://127.0.0.1:8765/v1/doctor"

mkdir -p "$LOG_DIR"

ts() { date +"%Y-%m-%dT%H:%M:%S%z"; }
log() { echo "$(ts) $*" >> "$LOG"; }

if pgrep -f "$APP_BIN_PAT" >/dev/null 2>&1; then
  if ! curl -s -m 3 "$HEALTH_URL" | grep -q '"ok":true'; then
    log "WARN process up but /v1/health not ok, leaving alone (single tick)"
  fi
  exit 0
fi

log "WARN ClawGate process not found, restarting via canonical path"

cd "$PROJECT_PATH" || { log "ERROR cd $PROJECT_PATH failed"; exit 1; }

RESTART_OUT="$(./scripts/restart-local-clawgate.sh --skip-build --skip-sync --skip-sign 2>&1)"
RESTART_RC=$?
log "INFO restart-local-clawgate rc=$RESTART_RC"
echo "$RESTART_OUT" | tail -20 >> "$LOG"

sleep 3

if pgrep -f "$APP_BIN_PAT" >/dev/null 2>&1; then
  log "INFO ClawGate process up after restart"
else
  log "ERROR ClawGate still not running after restart"
  exit 1
fi

DOCTOR_JSON="$(curl -s -m 5 "$DOCTOR_URL" 2>/dev/null || echo '')"
if [ -z "$DOCTOR_JSON" ]; then
  log "ERROR /v1/doctor returned empty"
  exit 1
fi

FAIL_COUNT="$(printf '%s' "$DOCTOR_JSON" | python3 -c 'import sys,json
try:
  d=json.load(sys.stdin)
  print(sum(1 for c in d.get("checks",[]) if c.get("status")!="ok"))
except Exception:
  print(-1)
' 2>/dev/null)"

log "INFO doctor non_ok_count=$FAIL_COUNT"
exit 0
