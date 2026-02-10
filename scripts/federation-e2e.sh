#!/bin/bash
# Federation E2E test for ClawGate + ClawGateRelay
#
# Validates routing and connectivity in Phase 3 setup:
# - Remote health and federation status
# - Optional remote bearer auth
# - adapter=line requests are forwarded through federation
# - adapter=tmux requests are handled locally on remote
#
# Usage:
#   ./scripts/federation-e2e.sh \
#     --remote-url http://127.0.0.1:8765 \
#     --remote-token YOUR_GATEWAY_TOKEN

set -euo pipefail

REMOTE_URL="http://127.0.0.1:8765"
REMOTE_TOKEN=""
LINE_HINT="FederationTest"
TMUX_PROJECT="project-a"
TIMEOUT=10
REQUIRE_FEDERATION=true

PASS=0
FAIL=0
TOTAL=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${CYAN}[FED-E2E]${NC} $1"; }
pass() { PASS=$((PASS + 1)); TOTAL=$((TOTAL + 1)); echo -e "  ${GREEN}PASS${NC} $1"; }
fail() { FAIL=$((FAIL + 1)); TOTAL=$((TOTAL + 1)); echo -e "  ${RED}FAIL${NC} $1: $2"; }
warn() { echo -e "  ${YELLOW}WARN${NC} $1"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote-url)
      REMOTE_URL="$2"; shift 2 ;;
    --remote-token)
      REMOTE_TOKEN="$2"; shift 2 ;;
    --line-hint)
      LINE_HINT="$2"; shift 2 ;;
    --tmux-project)
      TMUX_PROJECT="$2"; shift 2 ;;
    --timeout)
      TIMEOUT="$2"; shift 2 ;;
    --require-federation)
      v="$(printf "%s" "$2" | tr '[:upper:]' '[:lower:]')"
      if [[ "$v" == "true" || "$v" == "1" || "$v" == "yes" || "$v" == "on" ]]; then
        REQUIRE_FEDERATION=true
      else
        REQUIRE_FEDERATION=false
      fi
      shift 2 ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2 ;;
  esac
done

api() {
  local method="$1"
  local path="$2"
  local body="${3:-}"

  local args=( -s -m "$TIMEOUT" -X "$method" )
  if [[ -n "$REMOTE_TOKEN" ]]; then
    args+=( -H "Authorization: Bearer $REMOTE_TOKEN" )
  fi
  args+=( -H "Content-Type: application/json" )
  if [[ -n "$body" ]]; then
    args+=( -d "$body" )
  fi
  args+=( "$REMOTE_URL$path" )

  curl "${args[@]}" 2>/dev/null
}

json_field() {
  local expr="$1"
  python3 - "$expr" <<'PY'
import json,sys
expr = sys.argv[1]
try:
    d = json.load(sys.stdin)
    print(eval(expr, {"__builtins__": {}}, {"d": d}))
except Exception:
    print("")
PY
}

log "R1: remote health"
HEALTH=$(curl -s -m "$TIMEOUT" "$REMOTE_URL/v1/health" 2>/dev/null || true)
if [[ -z "$HEALTH" ]]; then
  fail "R1 health" "no response from $REMOTE_URL"
  echo -e "${RED}Remote relay is not reachable.${NC}"
  exit 1
fi

HEALTH_OK=$(echo "$HEALTH" | json_field "d.get('ok')")
FED_CONNECTED=$(echo "$HEALTH" | json_field "d.get('federation_connected')")
if [[ "$HEALTH_OK" == "True" ]]; then
  pass "R1 health"
else
  fail "R1 health" "ok=$HEALTH_OK"
fi

if [[ "$FED_CONNECTED" == "True" ]]; then
  pass "R2 federation connected"
else
  if [[ "$REQUIRE_FEDERATION" == "true" ]]; then
    fail "R2 federation connected" "federation_connected=$FED_CONNECTED"
  else
    warn "R2 federation connected (skipped): federation not required in this topology"
    TOTAL=$((TOTAL + 1))
  fi
fi

if [[ -n "$REMOTE_TOKEN" ]]; then
  log "R3: remote auth check"
  NOAUTH=$(curl -s -m "$TIMEOUT" -H "Content-Type: application/json" "$REMOTE_URL/v1/poll" 2>/dev/null || true)
  NOAUTH_CODE=$(echo "$NOAUTH" | json_field "d.get('error',{}).get('code')")
  if [[ "$NOAUTH_CODE" == "unauthorized" ]]; then
    pass "R3 unauthorized without bearer"
  else
    fail "R3 unauthorized without bearer" "error.code=$NOAUTH_CODE"
  fi
fi

log "R4: poll with auth"
POLL=$(api GET "/v1/poll")
POLL_OK=$(echo "$POLL" | json_field "d.get('ok')")
if [[ "$POLL_OK" == "True" ]]; then
  pass "R4 poll"
else
  fail "R4 poll" "ok=$POLL_OK"
fi

log "R5: line route (must be forwarded, not federation_unavailable)"
LINE_BODY=$(cat <<JSON
{"adapter":"line","action":"send_message","payload":{"conversation_hint":"$LINE_HINT","text":"federation e2e $(date +%s)","enter_to_send":true}}
JSON
)
LINE_RESP=$(api POST "/v1/send" "$LINE_BODY")
LINE_ERR=$(echo "$LINE_RESP" | json_field "d.get('error',{}).get('code')")
if [[ "$LINE_ERR" == "federation_unavailable" ]]; then
  fail "R5 line forwarding" "error.code=federation_unavailable"
else
  pass "R5 line forwarding path"
  if [[ -n "$LINE_ERR" ]]; then
    warn "line returned domain error (forward path OK): $LINE_ERR"
  fi
fi

log "R6: tmux route (must be local, not federation_unavailable)"
TMUX_BODY=$(cat <<JSON
{"adapter":"tmux","action":"send_message","payload":{"conversation_hint":"$TMUX_PROJECT","text":"relay tmux test $(date +%s)","enter_to_send":true}}
JSON
)
TMUX_RESP=$(api POST "/v1/send" "$TMUX_BODY")
TMUX_ERR=$(echo "$TMUX_RESP" | json_field "d.get('error',{}).get('code')")
if [[ "$TMUX_ERR" == "federation_unavailable" ]]; then
  fail "R6 tmux local route" "error.code=federation_unavailable"
else
  pass "R6 tmux local route"
  if [[ -n "$TMUX_ERR" ]]; then
    warn "tmux returned domain error (local path OK): $TMUX_ERR"
  fi
fi

echo ""
echo "============================================"
echo -e "  ${CYAN}Federation E2E Result${NC}"
echo "============================================"
echo -e "  ${GREEN}PASS${NC}: $PASS"
echo -e "  ${RED}FAIL${NC}: $FAIL"
echo "  TOTAL: $TOTAL"
echo "============================================"

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
