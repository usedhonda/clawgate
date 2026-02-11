#!/usr/bin/env bash
set -euo pipefail

# Lightweight watcher for tmux observe/autonomous flow.
# - Watches local ClawGate health/config/poll
# - Optionally watches relay health and auto-restarts it
#
# Usage:
#   ./scripts/watch-observe.sh
#   ./scripts/watch-observe.sh --duration 120 --interval 2
#   ./scripts/watch-observe.sh --auto-restart-relay

INTERVAL=2
DURATION=0
AUTO_RESTART_RELAY=false
APP_API="http://127.0.0.1:8765"
RELAY_API="http://127.0.0.1:9765"
LOG_FILE="/tmp/clawgate-observe-watch.log"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --interval)
      INTERVAL="$2"; shift 2 ;;
    --duration)
      DURATION="$2"; shift 2 ;;
    --auto-restart-relay)
      AUTO_RESTART_RELAY=true; shift ;;
    --app-api)
      APP_API="$2"; shift 2 ;;
    --relay-api)
      RELAY_API="$2"; shift 2 ;;
    --log-file)
      LOG_FILE="$2"; shift 2 ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 2 ;;
  esac
done

echo "== watch-observe ==" | tee -a "$LOG_FILE"
echo "app_api=$APP_API relay_api=$RELAY_API interval=${INTERVAL}s duration=${DURATION}s auto_restart_relay=$AUTO_RESTART_RELAY" | tee -a "$LOG_FILE"

start_ts="$(date +%s)"
last_cursor=0
last_tmux_total=-1
relay_fail_streak=0
poll_fail_streak=0

while true; do
  now_human="$(date '+%Y-%m-%d %H:%M:%S')"
  now_ts="$(date +%s)"

  app_health="$(curl -fsS -m 2 "$APP_API/v1/health" 2>/dev/null || true)"
  app_ok=false
  if [[ "$app_health" == *'"ok":true'* || "$app_health" == *'"ok": true'* ]]; then
    app_ok=true
  fi

  cfg="$(curl -fsS -m 2 "$APP_API/v1/config" 2>/dev/null || true)"
  mode_line="$(echo "$cfg" | tr -d '\n' | sed -n 's/.*"sessionModes":{\([^}]*\)}.*/\1/p')"
  observe_count="$(awk -v s="$mode_line" 'BEGIN { print gsub(/"observe"/, "", s) }')"
  auto_count="$(awk -v s="$mode_line" 'BEGIN { print gsub(/"auto"/, "", s) }')"
  autonomous_count="$(awk -v s="$mode_line" 'BEGIN { print gsub(/"autonomous"/, "", s) }')"

  stats="$(curl -fsS -m 2 "$APP_API/v1/stats" 2>/dev/null || true)"
  tmux_sent="$(echo "$stats" | tr -d '\n' | sed -n 's/.*"tmux_sent":\([0-9]*\).*/\1/p')"
  tmux_completion="$(echo "$stats" | tr -d '\n' | sed -n 's/.*"tmux_completion":\([0-9]*\).*/\1/p')"
  tmux_total=0
  if [[ -n "$tmux_sent" && -n "$tmux_completion" ]]; then
    tmux_total=$((tmux_sent + tmux_completion))
  fi

  poll="$(curl -fsS -m 2 "$APP_API/v1/poll?since=$last_cursor" 2>/dev/null || true)"
  if [[ -n "$poll" ]]; then
    poll_fail_streak=0
    next_cursor="$(echo "$poll" | tr -d '\n' | sed -n 's/.*"next_cursor":\([0-9]*\).*/\1/p')"
    if [[ -n "$next_cursor" ]]; then
      last_cursor="$next_cursor"
    fi
    event_count="$(awk -v s="$poll" 'BEGIN { print gsub(/"id":/, "", s) }')"
  else
    poll_fail_streak=$((poll_fail_streak + 1))
    event_count=0
  fi

  relay_health="$(curl -fsS -m 2 "$RELAY_API/v1/health" 2>/dev/null || true)"
  relay_ok=false
  if [[ "$relay_health" == *'"ok":true'* || "$relay_health" == *'"ok": true'* ]]; then
    relay_ok=true
    relay_fail_streak=0
  else
    relay_fail_streak=$((relay_fail_streak + 1))
  fi

  line="[$now_human] app_ok=$app_ok relay_ok=$relay_ok observe=$observe_count auto=$auto_count autonomous=$autonomous_count tmux_total=$tmux_total new_events=$event_count poll_fail_streak=$poll_fail_streak relay_fail_streak=$relay_fail_streak cursor=$last_cursor"
  echo "$line" | tee -a "$LOG_FILE"

  if [[ "$last_tmux_total" -ge 0 && "$tmux_total" -ne "$last_tmux_total" ]]; then
    echo "[$now_human] tmux_total changed: $last_tmux_total -> $tmux_total" | tee -a "$LOG_FILE"
  fi
  last_tmux_total="$tmux_total"

  if [[ "$AUTO_RESTART_RELAY" == "true" && "$relay_fail_streak" -ge 2 ]]; then
    echo "[$now_human] relay unhealthy twice, restarting..." | tee -a "$LOG_FILE"
    ./scripts/restart-hostb-relay.sh >/tmp/watch-observe-relay-restart.log 2>&1 || true
    relay_fail_streak=0
  fi

  if [[ "$DURATION" -gt 0 ]]; then
    elapsed=$((now_ts - start_ts))
    if [[ "$elapsed" -ge "$DURATION" ]]; then
      echo "done: duration ${DURATION}s reached" | tee -a "$LOG_FILE"
      exit 0
    fi
  fi

  sleep "$INTERVAL"
done
