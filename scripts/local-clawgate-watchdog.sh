#!/bin/bash
# Local (Host B / M5HND) ClawGate watchdog
# Invoked every 60s by ai.clawgate.watchdog.local LaunchAgent.
#
# Two-tier liveness check:
#   1. pgrep ClawGate.app process (catches SIGKILL / crash)
#   2. /v1/doctor non_ok_count + grace period (catches silent-stuck, optional)
#
# WATCHDOG_FUNCTIONAL_CHECK=1 environment variable enables tier 2.
# Default is tier 1 only (least invasive, no false-positive restart risk).

set -u

PROJECT_PATH="$HOME/projects/ios/clawgate"
APP_BIN_PAT="clawgate/ClawGate.app/Contents/MacOS/ClawGate"
LOG_DIR="$HOME/.clawgate/logs"
LOG="$LOG_DIR/watchdog.log"
HEALTH_URL="http://127.0.0.1:8765/v1/health"
DOCTOR_URL="http://127.0.0.1:8765/v1/doctor"
FAIL_STATE="$LOG_DIR/watchdog-consecutive-fail.txt"
FAIL_THRESHOLD="${WATCHDOG_CONSECUTIVE_FAIL_THRESHOLD:-3}"
FUNCTIONAL_CHECK="${WATCHDOG_FUNCTIONAL_CHECK:-0}"

mkdir -p "$LOG_DIR"

ts() { date +"%Y-%m-%dT%H:%M:%S%z"; }
log() { echo "$(ts) $*" >> "$LOG"; }

reset_fail_state() {
  echo "0" > "$FAIL_STATE" 2>/dev/null || true
}

increment_fail_state() {
  local cur=0
  [ -f "$FAIL_STATE" ] && cur="$(cat "$FAIL_STATE" 2>/dev/null || echo 0)"
  [[ "$cur" =~ ^[0-9]+$ ]] || cur=0
  cur=$((cur + 1))
  echo "$cur" > "$FAIL_STATE"
  echo "$cur"
}

do_restart() {
  log "INFO triggering canonical restart"
  cd "$PROJECT_PATH" || { log "ERROR cd $PROJECT_PATH failed"; exit 1; }
  RESTART_OUT="$(./scripts/restart-local-clawgate.sh --skip-build --skip-sync --skip-sign 2>&1)"
  RESTART_RC=$?
  log "INFO restart-local-clawgate rc=$RESTART_RC"
  echo "$RESTART_OUT" | tail -20 >> "$LOG"
  sleep 3
  if pgrep -f "$APP_BIN_PAT" >/dev/null 2>&1; then
    log "INFO ClawGate process up after restart"
    reset_fail_state
  else
    log "ERROR ClawGate still not running after restart"
    return 1
  fi
}

# Tier 1: process liveness
if ! pgrep -f "$APP_BIN_PAT" >/dev/null 2>&1; then
  log "WARN ClawGate process not found, restarting"
  do_restart
  exit $?
fi

# Tier 1.5: HTTP /v1/health probe (process up but server stuck)
if ! curl -s -m 3 "$HEALTH_URL" | grep -q '"ok":true'; then
  log "WARN process up but /v1/health not ok, leaving alone (single tick)"
  exit 0
fi

# Tier 2: functional doctor check (gated by env)
if [ "$FUNCTIONAL_CHECK" = "1" ]; then
  DOCTOR_JSON="$(curl -s -m 5 "$DOCTOR_URL" 2>/dev/null || echo '')"
  if [ -z "$DOCTOR_JSON" ]; then
    log "WARN /v1/doctor returned empty (functional check)"
    exit 0
  fi
  FAIL_COUNT="$(printf '%s' "$DOCTOR_JSON" | python3 -c 'import sys,json
try:
  d=json.load(sys.stdin)
  print(sum(1 for c in d.get("checks",[]) if c.get("status") not in ("ok","warning")))
except Exception:
  print(-1)
' 2>/dev/null)"
  if [ "$FAIL_COUNT" = "0" ]; then
    reset_fail_state
    exit 0
  fi
  if [ "$FAIL_COUNT" = "-1" ]; then
    log "WARN doctor parse failed"
    exit 0
  fi
  CUR_FAILS="$(increment_fail_state)"
  log "WARN doctor non_ok_count=$FAIL_COUNT consecutive=$CUR_FAILS threshold=$FAIL_THRESHOLD"
  if [ "$CUR_FAILS" -ge "$FAIL_THRESHOLD" ]; then
    log "WARN consecutive functional fails crossed threshold, restarting"
    do_restart
    exit $?
  fi
fi

exit 0
