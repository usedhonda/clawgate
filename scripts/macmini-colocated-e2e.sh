#!/bin/bash
# Strict E2E for colocated mode:
# OpenClaw + ClawGate + LINE are all on remote macmini.
#
# Usage:
#   ./scripts/macmini-colocated-e2e.sh --line-hint "Test User"
#   ./scripts/macmini-colocated-e2e.sh --remote-host macmini --line-hint "自分メモ" --tmux-project test

set -euo pipefail

REMOTE_HOST="macmini"
LINE_HINT=""
TMUX_PROJECT=""
TIMEOUT=12

PASS=0
FAIL=0

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${CYAN}[colocated-e2e]${NC} $1"; }
pass() { PASS=$((PASS + 1)); echo -e "  ${GREEN}PASS${NC} $1"; }
fail() { FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${NC} $1: $2"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote-host)
      REMOTE_HOST="$2"; shift 2 ;;
    --line-hint)
      LINE_HINT="$2"; shift 2 ;;
    --tmux-project)
      TMUX_PROJECT="$2"; shift 2 ;;
    --timeout)
      TIMEOUT="$2"; shift 2 ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2 ;;
  esac
done

if [[ -z "$LINE_HINT" ]]; then
  echo "--line-hint is required" >&2
  exit 2
fi

if ! ssh -o ConnectTimeout=8 "$REMOTE_HOST" "echo ok" >/dev/null 2>&1; then
  echo "Cannot SSH to '$REMOTE_HOST'" >&2
  exit 1
fi

json_field() {
  local expr="$1"
  local json_input="${2:-}"
  python3 - "$expr" "$json_input" <<'PY'
import json,sys
expr = sys.argv[1]
try:
    d = json.loads(sys.argv[2])
    print(eval(expr, {"__builtins__": {}}, {"d": d}))
except Exception:
    print("")
PY
}

remote_curl() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  local cmd="curl -s -m '$TIMEOUT' -X '$method' -H 'Content-Type: application/json'"
  if [[ -n "$body" ]]; then
    cmd="$cmd -d '$body'"
  fi
  cmd="$cmd 'http://127.0.0.1:8765$path'"
  ssh "$REMOTE_HOST" "$cmd" 2>/dev/null || true
}

log "T1 health"
HEALTH="$(remote_curl GET /v1/health)"
if [[ "$(json_field "d.get('ok')" "$HEALTH")" == "True" ]]; then
  pass "T1 health"
else
  fail "T1 health" "no or invalid response"
fi

log "T2 role/server check"
CFG="$(remote_curl GET /v1/config)"
ROLE="$(json_field "d.get('result',{}).get('remote',{}).get('node_role')" "$CFG")"
if [[ "$ROLE" == "server" ]]; then
  pass "T2 node_role=server"
else
  fail "T2 node_role" "expected server, got '$ROLE'"
fi

log "T3 relay not occupying 8765"
REMOTE_LISTEN="$(ssh "$REMOTE_HOST" "lsof -nP -iTCP:8765 -sTCP:LISTEN 2>/dev/null | tail -n +2" || true)"
if echo "$REMOTE_LISTEN" | grep -q "ClawGate"; then
  pass "T3 port 8765 owned by ClawGate"
else
  fail "T3 port 8765 owner" "expected ClawGate LISTEN on 127.0.0.1:8765"
fi

log "T4 line send (strict)"
LINE_TEXT="colocated-e2e line $(date +%s)"
LINE_PAYLOAD=$(cat <<JSON
{"adapter":"line","action":"send_message","payload":{"conversation_hint":"$LINE_HINT","text":"$LINE_TEXT","enter_to_send":true}}
JSON
)
LINE_RES="$(remote_curl POST /v1/send "$LINE_PAYLOAD")"
LINE_ERR="$(json_field "d.get('error',{}).get('code')" "$LINE_RES")"
if [[ -z "$LINE_ERR" || "$LINE_ERR" == "None" || "$LINE_ERR" == "null" ]]; then
  pass "T4 line send(strict)"
else
  fail "T4 line send(strict)" "error=$LINE_ERR"
  if [[ "$LINE_ERR" == "ax_permission_missing" ]]; then
    echo "  hint: grant Accessibility to ClawGate.app on remote host:"
    echo "        System Settings > Privacy & Security > Accessibility"
  fi
fi

if [[ -n "$TMUX_PROJECT" ]]; then
  log "T5 tmux send (strict)"
  TMUX_TEXT="colocated-e2e tmux $(date +%s)"
  TMUX_PAYLOAD=$(cat <<JSON
{"adapter":"tmux","action":"send_message","payload":{"conversation_hint":"$TMUX_PROJECT","text":"$TMUX_TEXT","enter_to_send":true}}
JSON
)
  TMUX_RES="$(remote_curl POST /v1/send "$TMUX_PAYLOAD")"
  TMUX_ERR="$(json_field "d.get('error',{}).get('code')" "$TMUX_RES")"
  if [[ -z "$TMUX_ERR" || "$TMUX_ERR" == "None" || "$TMUX_ERR" == "null" ]]; then
    pass "T5 tmux send(strict)"
  else
    fail "T5 tmux send(strict)" "error=$TMUX_ERR"
  fi
fi

echo ""
echo "PASS=$PASS FAIL=$FAIL"
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
