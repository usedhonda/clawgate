#!/bin/bash
# Host A (OpenClaw + LINE) -> Host B (ClawGateRelay + CC/tmux) runbook check
#
# Validates:
# 1) Relay health/auth
# 2) Federation connected (Relay -> Host A ClawGate)
# 3) tmux route (Host A -> Host B local tmux)
# 4) line route (Host A -> Host B Relay -> Host A ClawGate via federation)
#
# Usage:
#   ./scripts/host-a-host-b-e2e.sh \
#     --relay-url http://HOST_B_IP:8765 \
#     --gateway-token GATEWAY_TOKEN \
#     --tmux-project your-project \
#     --line-hint "Your Contact"

set -euo pipefail

RELAY_URL="http://127.0.0.1:8765"
GATEWAY_TOKEN=""
TMUX_PROJECT=""
LINE_HINT=""
TIMEOUT=12
STRICT_ROLE_CHECK=true
STRICT_DELIVERY=false

PASS=0
FAIL=0
TOTAL=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${CYAN}[A-B E2E]${NC} $1"; }
pass() { PASS=$((PASS + 1)); TOTAL=$((TOTAL + 1)); echo -e "  ${GREEN}PASS${NC} $1"; }
fail() { FAIL=$((FAIL + 1)); TOTAL=$((TOTAL + 1)); echo -e "  ${RED}FAIL${NC} $1: $2"; }
warn() { echo -e "  ${YELLOW}WARN${NC} $1"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --relay-url)
      RELAY_URL="$2"; shift 2 ;;
    --gateway-token)
      GATEWAY_TOKEN="$2"; shift 2 ;;
    --tmux-project)
      TMUX_PROJECT="$2"; shift 2 ;;
    --line-hint)
      LINE_HINT="$2"; shift 2 ;;
    --timeout)
      TIMEOUT="$2"; shift 2 ;;
    --no-strict-role-check)
      STRICT_ROLE_CHECK=false; shift ;;
    --strict)
      STRICT_DELIVERY=true; shift ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2 ;;
  esac
done

if [[ -z "$GATEWAY_TOKEN" ]]; then
  echo "--gateway-token is required" >&2
  exit 2
fi
if [[ -z "$TMUX_PROJECT" ]]; then
  echo "--tmux-project is required" >&2
  exit 2
fi
if [[ -z "$LINE_HINT" ]]; then
  echo "--line-hint is required" >&2
  exit 2
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

api() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  local args=( -s -m "$TIMEOUT" -X "$method" -H "Authorization: Bearer $GATEWAY_TOKEN" -H "Content-Type: application/json" )
  if [[ -n "$body" ]]; then
    args+=( -d "$body" )
  fi
  args+=( "$RELAY_URL$path" )
  curl "${args[@]}" 2>/dev/null
}

log "T1 health"
HEALTH=$(curl -s -m "$TIMEOUT" "$RELAY_URL/v1/health" 2>/dev/null || true)
if [[ -z "$HEALTH" ]]; then
  fail "T1 health" "no response from relay"
  echo -e "${RED}Relay is unreachable.${NC}"
  exit 1
fi
if [[ "$(json_field "d.get('ok')" "$HEALTH")" == "True" ]]; then
  pass "T1 health"
else
  fail "T1 health" "invalid health response"
fi

if [[ "$STRICT_ROLE_CHECK" == "true" ]]; then
  log "T1.5 role check"
  LOCAL_CFG=$(curl -s -m "$TIMEOUT" "http://127.0.0.1:8765/v1/config" 2>/dev/null || true)
  LOCAL_ROLE=$(json_field "d.get('result',{}).get('remote',{}).get('node_role')" "$LOCAL_CFG")
  REMOTE_ROLE=$(json_field "d.get('node_role')" "$HEALTH")
  if [[ "$LOCAL_ROLE" == "server" && "$REMOTE_ROLE" == "client" ]]; then
    pass "T1.5 role check"
  else
    fail "T1.5 role check" "expected hostA=server hostB=client, got hostA=$LOCAL_ROLE hostB=$REMOTE_ROLE"
  fi
fi

log "T2 auth required"
NOAUTH=$(curl -s -m "$TIMEOUT" "$RELAY_URL/v1/poll" 2>/dev/null || true)
NOAUTH_CODE=$(json_field "d.get('error',{}).get('code')" "$NOAUTH")
if [[ "$NOAUTH_CODE" == "unauthorized" ]]; then
  pass "T2 auth"
else
  fail "T2 auth" "expected unauthorized, got: $NOAUTH_CODE"
fi

log "T3 federation connected"
FED=$(json_field "d.get('federation_connected')" "$HEALTH")
if [[ "$FED" == "True" ]]; then
  pass "T3 federation connected"
else
  fail "T3 federation connected" "federation_connected=$FED"
fi

log "T4 poll with auth"
POLL=$(api GET "/v1/poll")
if [[ "$(json_field "d.get('ok')" "$POLL")" == "True" ]]; then
  pass "T4 poll"
else
  fail "T4 poll" "poll failed"
fi

log "T5 tmux send (Host B local CC)"
TMUX_PAYLOAD=$(cat <<JSON
{"adapter":"tmux","action":"send_message","payload":{"conversation_hint":"$TMUX_PROJECT","text":"ab-e2e tmux $(date +%s)","enter_to_send":true}}
JSON
)
TMUX_RES=$(api POST "/v1/send" "$TMUX_PAYLOAD")
TMUX_ERR=$(json_field "d.get('error',{}).get('code')" "$TMUX_RES")
if [[ "$STRICT_DELIVERY" == "true" ]]; then
  if [[ -z "$TMUX_ERR" ]]; then
    pass "T5 tmux send(strict)"
  else
    fail "T5 tmux send(strict)" "error: $TMUX_ERR"
  fi
elif [[ -z "$TMUX_ERR" ]]; then
  pass "T5 tmux send"
elif [[ "$TMUX_ERR" == "session_busy" || "$TMUX_ERR" == "session_not_found" || "$TMUX_ERR" == "session_not_allowed" || "$TMUX_ERR" == "session_read_only" || "$TMUX_ERR" == "tmux_command_failed" ]]; then
  pass "T5 tmux route"
  warn "tmux domain status: $TMUX_ERR"
else
  fail "T5 tmux route" "unexpected error: $TMUX_ERR"
fi

log "T6 line send (Relay -> Federation -> Host A ClawGate)"
LINE_PAYLOAD=$(cat <<JSON
{"adapter":"line","action":"send_message","payload":{"conversation_hint":"$LINE_HINT","text":"ab-e2e line $(date +%s)","enter_to_send":true}}
JSON
)
LINE_RES=$(api POST "/v1/send" "$LINE_PAYLOAD")
LINE_ERR=$(json_field "d.get('error',{}).get('code')" "$LINE_RES")
if [[ "$STRICT_DELIVERY" == "true" ]]; then
  if [[ -z "$LINE_ERR" ]]; then
    pass "T6 line send(strict)"
  else
    fail "T6 line send(strict)" "error: $LINE_ERR"
  fi
elif [[ -z "$LINE_ERR" ]]; then
  pass "T6 line send"
elif [[ "$LINE_ERR" == "federation_unavailable" ]]; then
  fail "T6 line route" "federation unavailable"
else
  pass "T6 line route"
  warn "line domain status: $LINE_ERR"
fi

echo ""
echo "============================================"
echo -e "  ${CYAN}Host A/B E2E Result${NC}"
echo "============================================"
echo -e "  ${GREEN}PASS${NC}: $PASS"
echo -e "  ${RED}FAIL${NC}: $FAIL"
echo "  TOTAL: $TOTAL"
echo "============================================"

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
