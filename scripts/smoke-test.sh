#!/bin/bash
# ClawGate Smoke Test — lightweight E2E check (~5 seconds)
# Usage: ./scripts/smoke-test.sh [--with-openclaw]
#
# Runs 4 core API tests (+ 1 optional OpenClaw check).
# For full test suite, use ./scripts/integration-test.sh
#
# No authentication required — ClawGate binds to 127.0.0.1 only.

set -euo pipefail

BASE_URL="http://127.0.0.1:8765"
PASS=0
FAIL=0
TOTAL=0
RESULTS=()
WITH_OPENCLAW=false

for arg in "$@"; do
    case "$arg" in
        --with-openclaw) WITH_OPENCLAW=true ;;
    esac
done

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${CYAN}[SMOKE]${NC} $1"; }
pass() { PASS=$((PASS + 1)); TOTAL=$((TOTAL + 1)); RESULTS+=("PASS: $1"); echo -e "  ${GREEN}PASS${NC} $1"; }
fail() { FAIL=$((FAIL + 1)); TOTAL=$((TOTAL + 1)); RESULTS+=("FAIL: $1 -- $2"); echo -e "  ${RED}FAIL${NC} $1: $2"; }

api() {
    curl -s -m 10 "$@" 2>/dev/null
}

json_field() {
    python3 -c "import sys,json; d=json.load(sys.stdin); print($1)" 2>/dev/null
}

###############################################################################
# S1: Health
###############################################################################
log "S1: Health check"
HEALTH=$(api "$BASE_URL/v1/health")
if echo "$HEALTH" | json_field "d['ok']" | grep -q "True"; then
    VERSION=$(echo "$HEALTH" | json_field "d['version']")
    pass "S1 Health (v$VERSION)"
else
    fail "S1 Health" "Server not responding"
    echo -e "${RED}ClawGate is not running. Aborting.${NC}"
    exit 1
fi

###############################################################################
# S2: Doctor
###############################################################################
log "S2: Doctor"
DOCTOR=$(api "$BASE_URL/v1/doctor")
DOC_OK=$(echo "$DOCTOR" | json_field "d.get('ok', False)" 2>/dev/null || echo "False")
if [ "$DOC_OK" = "True" ]; then
    pass "S2 Doctor (ok=true)"
else
    fail "S2 Doctor" "ok=$DOC_OK"
fi

###############################################################################
# S3: Poll
###############################################################################
log "S3: Poll"
POLL=$(api "$BASE_URL/v1/poll")
POLL_OK=$(echo "$POLL" | json_field "d['ok']" 2>/dev/null || echo "")
if [ "$POLL_OK" = "True" ]; then
    CURSOR=$(echo "$POLL" | json_field "d['next_cursor']" 2>/dev/null || echo "?")
    pass "S3 Poll (cursor=$CURSOR)"
else
    fail "S3 Poll" "ok=$POLL_OK"
fi

###############################################################################
# S4: Send dry-run (invalid adapter -> 400)
###############################################################################
log "S4: Send dry-run"
SEND_BAD=$(api -X POST -H "Content-Type: application/json" \
    -d '{"adapter":"nonexistent","action":"send_message","payload":{"conversation_hint":"test","text":"test","enter_to_send":true}}' \
    "$BASE_URL/v1/send")
ERR_CODE=$(echo "$SEND_BAD" | json_field "d['error']['code']" 2>/dev/null || echo "")
if [ "$ERR_CODE" = "adapter_not_found" ]; then
    pass "S4 Send dry-run (adapter_not_found)"
else
    fail "S4 Send dry-run" "Expected adapter_not_found, got: $ERR_CODE"
fi

###############################################################################
# S5: OpenClaw plugin (optional)
###############################################################################
if [ "$WITH_OPENCLAW" = "true" ]; then
    log "S5: OpenClaw plugin"

    # Find gateway log
    OC_LOG="$HOME/.openclaw/logs/gateway.log"
    if [ ! -f "$OC_LOG" ]; then
        # Try alternate location
        OC_LOG="$HOME/Library/Logs/openclaw/gateway.log"
    fi

    if [ -f "$OC_LOG" ]; then
        # Check for recent successful doctor + cursor
        DOCTOR_OK=$(tail -100 "$OC_LOG" | grep -c "doctor OK" 2>/dev/null | tr -d '[:space:]' || echo "0")
        CURSOR=$(tail -100 "$OC_LOG" | grep -c "initial cursor" 2>/dev/null | tr -d '[:space:]' || echo "0")

        if [ "$DOCTOR_OK" -gt 0 ] && [ "$CURSOR" -gt 0 ]; then
            pass "S5 OpenClaw plugin (doctor OK + polling)"
        elif [ "$DOCTOR_OK" -gt 0 ]; then
            pass "S5 OpenClaw plugin (doctor OK, cursor check inconclusive)"
        else
            fail "S5 OpenClaw plugin" "No recent 'doctor OK' in log"
        fi
    else
        fail "S5 OpenClaw plugin" "Gateway log not found at $OC_LOG"
    fi
fi

###############################################################################
# Summary
###############################################################################
echo ""
echo "============================================"
echo -e "  ${CYAN}ClawGate Smoke Test Results${NC}"
echo "============================================"
echo -e "  ${GREEN}PASS${NC}: $PASS"
echo -e "  ${RED}FAIL${NC}: $FAIL"
echo "  TOTAL: $TOTAL"
echo "============================================"

if [ $FAIL -gt 0 ]; then
    echo ""
    echo "Failed tests:"
    for r in "${RESULTS[@]}"; do
        if [[ "$r" == FAIL* ]]; then
            echo -e "  ${RED}$r${NC}"
        fi
    done
    echo ""
    exit 1
else
    echo ""
    echo -e "${GREEN}All smoke tests passed!${NC}"
    exit 0
fi
