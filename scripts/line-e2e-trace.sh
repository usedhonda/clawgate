#!/usr/bin/env bash
set -euo pipefail

# Trace LINE inbound path end-to-end on Host A:
# 1) ClawGate /v1/health, /v1/doctor
# 2) /v1/poll inbound_message (adapter=line)
# 3) OpenClaw gateway.log inbound from ...
# 4) Optional: sending reply ...
#
# Usage:
#   ./scripts/line-e2e-trace.sh --remote-host macmini
#   ./scripts/line-e2e-trace.sh --remote-host macmini --expect-text "hello"
#   ./scripts/line-e2e-trace.sh --remote-host macmini --require-reply

REMOTE_HOST="macmini"
WAIT_SECONDS=90
POLL_INTERVAL=2
EXPECT_TEXT=""
REQUIRE_REPLY=false
SINCE_CURSOR=""
SHOW_LOG_LINES=300

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${CYAN}[LINE TRACE]${NC} $1"; }
pass() { echo -e "  ${GREEN}PASS${NC} $1"; }
warn() { echo -e "  ${YELLOW}WARN${NC} $1"; }
fail() { echo -e "  ${RED}FAIL${NC} $1"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote-host)
      REMOTE_HOST="$2"; shift 2 ;;
    --wait-seconds)
      WAIT_SECONDS="$2"; shift 2 ;;
    --poll-interval)
      POLL_INTERVAL="$2"; shift 2 ;;
    --expect-text)
      EXPECT_TEXT="$2"; shift 2 ;;
    --require-reply)
      REQUIRE_REPLY=true; shift ;;
    --since)
      SINCE_CURSOR="$2"; shift 2 ;;
    --show-log-lines)
      SHOW_LOG_LINES="$2"; shift 2 ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 2 ;;
  esac
done

START_TS="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

remote_curl() {
  local path="$1"
  ssh "$REMOTE_HOST" "curl -sS -m 5 'http://127.0.0.1:8765$path'"
}

json_get() {
  local expr="$1"
  local raw="${2:-}"
python3 - "$expr" "$raw" <<'PY'
import json,sys
expr=sys.argv[1]
raw=sys.argv[2]
try:
    d=json.loads(raw)
    print(eval(expr, {"__builtins__": {}}, {"d": d}))
except Exception:
    print("")
PY
}

log "Remote host: $REMOTE_HOST"
log "Start: $START_TS"

log "S1 health"
HEALTH="$(remote_curl "/v1/health" || true)"
if [[ -z "$HEALTH" ]]; then
  fail "health unavailable"
  exit 1
fi
HEALTH_OK="$(json_get "d.get('ok')" "$HEALTH" | tr -d '\r\n[:space:]')"
if [[ "$HEALTH_OK" == "True" ]]; then
  pass "health ok"
else
  fail "health invalid: $HEALTH"
  exit 1
fi

log "S2 doctor"
DOCTOR="$(remote_curl "/v1/doctor" || true)"
if [[ -n "$DOCTOR" ]]; then
  DOC_OK="$(json_get "d.get('ok')" "$DOCTOR" | tr -d '\r\n[:space:]')"
  if [[ "$DOC_OK" == "True" ]]; then
    pass "doctor ok"
  else
    warn "doctor not ok"
    echo "$DOCTOR"
  fi
else
  warn "doctor unavailable"
fi

log "S2.5 OCR artifact (binary check)"
LATEST_META="$(ssh "$REMOTE_HOST" "ls -t /tmp/clawgate-ocr-debug/*/meta.json 2>/dev/null | head -1 | xargs cat 2>/dev/null" || true)"
if [[ -n "$LATEST_META" ]]; then
  SEP_METHOD="$(json_get "d.get('separator_method','')" "$LATEST_META" | tr -d '\r\n[:space:]')"
  LINE_FOUND="$(json_get "d.get('line_found','')" "$LATEST_META" | tr -d '\r\n[:space:]')"
  if [[ "$SEP_METHOD" == "fixed-ratio" ]]; then
    pass "separator_method=fixed-ratio (new binary)"
  else
    warn "separator_method=$SEP_METHOD (old binary?)"
  fi
  if [[ "$LINE_FOUND" == "1" ]]; then
    pass "line_found=1"
  else
    warn "line_found=$LINE_FOUND"
  fi
else
  warn "no OCR debug artifacts found"
fi

if [[ -z "$SINCE_CURSOR" ]]; then
  BASE_POLL="$(remote_curl "/v1/poll?since=0" || true)"
  SINCE_CURSOR="$(json_get "d.get('next_cursor',0)" "$BASE_POLL")"
fi
SINCE_CURSOR="$(echo "$SINCE_CURSOR" | tr -cd '0-9')"
[[ -z "$SINCE_CURSOR" ]] && SINCE_CURSOR="0"

log "Base cursor: $SINCE_CURSOR"
if [[ -n "$EXPECT_TEXT" ]]; then
  log "Expect text contains: $EXPECT_TEXT"
fi

log "Now send a LINE message to Host A conversation. Waiting up to ${WAIT_SECONDS}s..."

FOUND_EVENT=""
CURRENT_CURSOR="$SINCE_CURSOR"
DEADLINE=$(( $(date +%s) + WAIT_SECONDS ))

while [[ $(date +%s) -lt $DEADLINE ]]; do
  POLL_JSON="$(remote_curl "/v1/poll?since=$CURRENT_CURSOR" || true)"
  NEXT_CURSOR="$(json_get "d.get('next_cursor',$CURRENT_CURSOR)" "$POLL_JSON")"
  NEXT_CURSOR="$(echo "$NEXT_CURSOR" | tr -cd '0-9')"
  [[ -n "$NEXT_CURSOR" ]] && CURRENT_CURSOR="$NEXT_CURSOR"

  CANDIDATE="$(python3 -c '
import json,sys
expect=sys.argv[1]
raw=sys.stdin.read()
try:
    d=json.loads(raw)
except Exception:
    print("")
    raise SystemExit
for ev in d.get("events", []):
    if ev.get("type") != "inbound_message":
        continue
    if ev.get("adapter") != "line":
        continue
    payload = ev.get("payload", {})
    text = str(payload.get("text", ""))
    if expect and expect not in text:
        continue
    print(json.dumps(ev, ensure_ascii=False))
    break
' "$EXPECT_TEXT" <<<"$POLL_JSON")"

  if [[ -n "$CANDIDATE" ]]; then
    FOUND_EVENT="$CANDIDATE"
    break
  fi

  sleep "$POLL_INTERVAL"
done

if [[ -z "$FOUND_EVENT" ]]; then
  fail "no line inbound_message detected within ${WAIT_SECONDS}s"
  log "S4.5 pipeline result (on failure)"
  PIPELINE="$(ssh "$REMOTE_HOST" "cat /tmp/clawgate-ocr-debug/latest-pipeline.json 2>/dev/null" || true)"
  if [[ -n "$PIPELINE" ]]; then
    P_SCORE="$(json_get "d.get('fusion_score','')" "$PIPELINE" | tr -d '\r\n[:space:]')"
    P_THRESH="$(json_get "d.get('fusion_threshold','')" "$PIPELINE" | tr -d '\r\n[:space:]')"
    P_EMIT="$(json_get "d.get('fusion_should_emit','')" "$PIPELINE" | tr -d '\r\n[:space:]')"
    P_SANITIZED="$(json_get "d.get('sanitized_text','')" "$PIPELINE" | tr -d '\r\n')"
    P_DEDUP="$(json_get "d.get('dedup_result','')" "$PIPELINE" | tr -d '\r\n[:space:]')"
    P_EMITTED="$(json_get "d.get('emitted','')" "$PIPELINE" | tr -d '\r\n[:space:]')"
    P_SIGNALS="$(json_get "d.get('fusion_signals','')" "$PIPELINE" | tr -d '\r\n')"
    echo "  score=$P_SCORE threshold=$P_THRESH should_emit=$P_EMIT"
    echo "  signals=$P_SIGNALS"
    echo "  sanitized_text=$P_SANITIZED"
    echo "  dedup=$P_DEDUP emitted=$P_EMITTED"
  else
    warn "pipeline result not found (debug logging disabled?)"
  fi
  exit 1
fi

pass "line inbound_message detected"
echo "$FOUND_EVENT"

log "S4.5 pipeline result"
PIPELINE="$(ssh "$REMOTE_HOST" "cat /tmp/clawgate-ocr-debug/latest-pipeline.json 2>/dev/null" || true)"
if [[ -n "$PIPELINE" ]]; then
  P_SCORE="$(json_get "d.get('fusion_score','')" "$PIPELINE" | tr -d '\r\n[:space:]')"
  P_THRESH="$(json_get "d.get('fusion_threshold','')" "$PIPELINE" | tr -d '\r\n[:space:]')"
  P_EMIT="$(json_get "d.get('fusion_should_emit','')" "$PIPELINE" | tr -d '\r\n[:space:]')"
  P_SANITIZED="$(json_get "d.get('sanitized_text','')" "$PIPELINE" | tr -d '\r\n')"
  P_DEDUP="$(json_get "d.get('dedup_result','')" "$PIPELINE" | tr -d '\r\n[:space:]')"
  P_EMITTED="$(json_get "d.get('emitted','')" "$PIPELINE" | tr -d '\r\n[:space:]')"
  P_SIGNALS="$(json_get "d.get('fusion_signals','')" "$PIPELINE" | tr -d '\r\n')"

  echo "  score=$P_SCORE threshold=$P_THRESH should_emit=$P_EMIT"
  echo "  signals=$P_SIGNALS"
  echo "  sanitized_text=$P_SANITIZED"
  echo "  dedup=$P_DEDUP emitted=$P_EMITTED"

  if [[ "$P_EMITTED" == "true" ]]; then
    pass "pipeline: emitted=true"
  else
    fail "pipeline: emitted=false (score=$P_SCORE, dedup=$P_DEDUP)"
  fi
else
  warn "pipeline result not found (debug logging disabled?)"
fi

log "S5 OpenClaw log trace"
REMOTE_LOG="$(ssh "$REMOTE_HOST" "tail -n $SHOW_LOG_LINES ~/.openclaw/logs/gateway.log 2>/dev/null || tail -n $SHOW_LOG_LINES ~/Library/Logs/openclaw/gateway.log 2>/dev/null || true")"
if [[ -z "$REMOTE_LOG" ]]; then
  fail "gateway log not found"
  exit 1
fi

TRACE_RESULT="$(python3 -c '
import sys
start=sys.argv[1]
log=sys.stdin.read().splitlines()
inbound=[]
reply=[]
for line in log:
    if len(line) < 20:
        continue
    ts=line[:20]
    if ts < start[:20]:
        continue
    if "[clawgate]" not in line:
        continue
    if "inbound from" in line:
        inbound.append(line)
    if "sending reply to" in line:
        reply.append(line)
print("INBOUND=" + str(len(inbound)))
print("REPLY=" + str(len(reply)))
if inbound:
    print("LAST_INBOUND=" + inbound[-1])
if reply:
    print("LAST_REPLY=" + reply[-1])
' "$START_TS" <<<"$REMOTE_LOG")"

echo "$TRACE_RESULT"
INBOUND_COUNT="$(echo "$TRACE_RESULT" | awk -F= '/^INBOUND=/{print $2}')"
REPLY_COUNT="$(echo "$TRACE_RESULT" | awk -F= '/^REPLY=/{print $2}')"

if [[ "${INBOUND_COUNT:-0}" -gt 0 ]]; then
  pass "gateway log inbound detected"
else
  fail "gateway log inbound not detected after start timestamp"
  exit 1
fi

if [[ "$REQUIRE_REPLY" == "true" ]]; then
  if [[ "${REPLY_COUNT:-0}" -gt 0 ]]; then
    pass "gateway reply detected"
  else
    fail "gateway reply not detected"
    exit 1
  fi
else
  if [[ "${REPLY_COUNT:-0}" -gt 0 ]]; then
    pass "gateway reply detected"
  else
    warn "gateway reply not detected (use --require-reply to enforce)"
  fi
fi

log "Done"
