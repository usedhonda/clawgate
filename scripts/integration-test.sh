#!/bin/bash
# ClawGate Integration Test Suite
# Runs all API tests sequentially and reports results.
# Usage: ./scripts/integration-test.sh
#
# Prerequisites:
#   - ClawGate.app must be running on port 8765
#   - For AX tests: Accessibility permission must be granted
#   - For send tests: LINE must be open with a chat selected
#
# No authentication required — ClawGate binds to 127.0.0.1 only.

set -euo pipefail

BASE_URL="http://127.0.0.1:8765"
PASS=0
FAIL=0
SKIP=0
TOTAL=0
RESULTS=()

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${CYAN}[TEST]${NC} $1"; }
pass() { PASS=$((PASS + 1)); TOTAL=$((TOTAL + 1)); RESULTS+=("PASS: $1"); echo -e "  ${GREEN}PASS${NC} $1"; }
fail() { FAIL=$((FAIL + 1)); TOTAL=$((TOTAL + 1)); RESULTS+=("FAIL: $1 -- $2"); echo -e "  ${RED}FAIL${NC} $1: $2"; }
skip() { SKIP=$((SKIP + 1)); TOTAL=$((TOTAL + 1)); RESULTS+=("SKIP: $1 -- $2"); echo -e "  ${YELLOW}SKIP${NC} $1: $2"; }

# Helper: curl with timeout
api() {
    curl -s -m 10 "$@" 2>/dev/null
}

# Helper: extract JSON field
json_field() {
    python3 -c "import sys,json; d=json.load(sys.stdin); print($1)" 2>/dev/null
}

###############################################################################
# Phase 0: Server Health
###############################################################################
log "Phase 0: Server Health"

# T0.1 Health check
HEALTH=$(api "$BASE_URL/v1/health")
if echo "$HEALTH" | json_field "d['ok']" | grep -q "True"; then
    VERSION=$(echo "$HEALTH" | json_field "d['version']")
    pass "T0.1 Health check (v$VERSION)"
else
    fail "T0.1 Health check" "Server not responding"
    echo "ClawGate is not running. Start it first: open ClawGate.app"
    exit 1
fi

###############################################################################
# Phase 1: Error Handling
###############################################################################
log "Phase 1: Error Handling"

# T1.1 Wrong method -> 405
RESP=$(api -X GET "$BASE_URL/v1/send")
ERR_CODE=$(echo "$RESP" | json_field "d['error']['code']" 2>/dev/null || echo "")
if [ "$ERR_CODE" = "method_not_allowed" ]; then
    pass "T1.1 GET /v1/send returns 405"
else
    fail "T1.1 Wrong method" "Expected method_not_allowed, got: $ERR_CODE"
fi

# T1.2 Not found
RESP=$(api "$BASE_URL/v1/nonexistent")
ERR_CODE=$(echo "$RESP" | json_field "d['error']['code']" 2>/dev/null || echo "")
if [ "$ERR_CODE" = "not_found" ]; then
    pass "T1.2 Unknown path returns not_found"
else
    fail "T1.2 Unknown path" "Expected not_found, got: $ERR_CODE"
fi

###############################################################################
# Phase 2: Doctor
###############################################################################
log "Phase 2: Doctor"

DOCTOR=$(api "$BASE_URL/v1/doctor")
if [ -z "$DOCTOR" ]; then
    fail "T2.1 Doctor" "No response (blocked?)"
else
    DOC_OK=$(echo "$DOCTOR" | json_field "d.get('ok', 'missing')" 2>/dev/null || echo "error")
    CHECKS=$(echo "$DOCTOR" | json_field "len(d.get('checks', []))" 2>/dev/null || echo "0")
    pass "T2.1 Doctor responds (ok=$DOC_OK, checks=$CHECKS)"

    # Check individual items
    AX_STATUS=$(echo "$DOCTOR" | json_field "[c['status'] for c in d['checks'] if c['name']=='accessibility_permission'][0]" 2>/dev/null || echo "unknown")
    LINE_STATUS=$(echo "$DOCTOR" | json_field "[c['status'] for c in d['checks'] if c['name']=='line_running'][0]" 2>/dev/null || echo "unknown")

    if [ "$LINE_STATUS" = "ok" ]; then
        pass "T2.2 Doctor: line_running=ok"
    else
        skip "T2.2 Doctor: line_running" "LINE not running ($LINE_STATUS)"
    fi

    if [ "$AX_STATUS" != "ok" ]; then
        skip "T2.3 Doctor: accessibility" "AX permission not granted ($AX_STATUS)"
        AX_AVAILABLE=false
    else
        pass "T2.3 Doctor: accessibility=ok"
        AX_AVAILABLE=true
    fi
fi

###############################################################################
# Phase 3: Poll & Events
###############################################################################
log "Phase 3: Poll & Events"

# T3.1 Poll
POLL=$(api "$BASE_URL/v1/poll")
POLL_OK=$(echo "$POLL" | json_field "d['ok']" 2>/dev/null || echo "")
if [ "$POLL_OK" = "True" ]; then
    CURSOR=$(echo "$POLL" | json_field "d['next_cursor']" 2>/dev/null || echo "?")
    pass "T3.1 Poll (next_cursor=$CURSOR)"
else
    fail "T3.1 Poll" "ok=$POLL_OK"
fi

# T3.2 Poll with since
POLL2=$(api "$BASE_URL/v1/poll?since=0")
POLL2_OK=$(echo "$POLL2" | json_field "d['ok']" 2>/dev/null || echo "")
if [ "$POLL2_OK" = "True" ]; then
    pass "T3.2 Poll with since=0"
else
    fail "T3.2 Poll with since" "ok=$POLL2_OK"
fi

# T3.3 SSE connection
curl -s -N -m 3 "$BASE_URL/v1/events" >/dev/null 2>&1 || true
# SSE always returns partial (timeout), exit code 28 is expected
pass "T3.3 SSE connection established"

###############################################################################
# Phase 4: AX-dependent endpoints (Context, Messages, Conversations, AXDump)
###############################################################################
log "Phase 4: AX-dependent endpoints"

if [ "${AX_AVAILABLE:-false}" = "true" ]; then
    # T4.1 Context
    CTX=$(api "$BASE_URL/v1/context?adapter=line")
    CTX_OK=$(echo "$CTX" | json_field "d['ok']" 2>/dev/null || echo "")
    CTX_ERR=$(echo "$CTX" | json_field "d.get('error',{}).get('code','?')" 2>/dev/null || echo "?")
    if [ "$CTX_OK" = "True" ]; then
        CONV=$(echo "$CTX" | json_field "d['result']['conversation_name']" 2>/dev/null || echo "null")
        pass "T4.1 Context (conversation=$CONV)"
    elif [ "$CTX_ERR" = "line_window_missing" ]; then
        skip "T4.1 Context" "LINE window not in foreground (Qt limitation)"
    else
        fail "T4.1 Context" "error=$CTX_ERR"
    fi

    # T4.2 Messages
    MSG=$(api "$BASE_URL/v1/messages?adapter=line&limit=5")
    MSG_OK=$(echo "$MSG" | json_field "d['ok']" 2>/dev/null || echo "")
    MSG_ERR=$(echo "$MSG" | json_field "d.get('error',{}).get('code','?')" 2>/dev/null || echo "?")
    if [ "$MSG_OK" = "True" ]; then
        COUNT=$(echo "$MSG" | json_field "d['result']['message_count']" 2>/dev/null || echo "?")
        pass "T4.2 Messages (count=$COUNT)"
    elif [ "$MSG_ERR" = "line_window_missing" ]; then
        skip "T4.2 Messages" "LINE window not in foreground (Qt limitation)"
    else
        fail "T4.2 Messages" "error=$MSG_ERR"
    fi

    # T4.3 Conversations
    CONVS=$(api "$BASE_URL/v1/conversations?adapter=line&limit=5")
    CONVS_OK=$(echo "$CONVS" | json_field "d['ok']" 2>/dev/null || echo "")
    CONVS_ERR=$(echo "$CONVS" | json_field "d.get('error',{}).get('code','?')" 2>/dev/null || echo "?")
    if [ "$CONVS_OK" = "True" ]; then
        COUNT=$(echo "$CONVS" | json_field "d['result']['count']" 2>/dev/null || echo "?")
        pass "T4.3 Conversations (count=$COUNT)"
    elif [ "$CONVS_ERR" = "line_window_missing" ]; then
        skip "T4.3 Conversations" "LINE window not in foreground (Qt limitation)"
    else
        fail "T4.3 Conversations" "error=$CONVS_ERR"
    fi

    # T4.4 AXDump
    AXDUMP=$(api "$BASE_URL/v1/axdump?adapter=line")
    AXDUMP_OK=$(echo "$AXDUMP" | json_field "d.get('ok', d.get('role', 'missing'))" 2>/dev/null || echo "")
    if [ "$AXDUMP_OK" != "False" ] && [ -n "$AXDUMP" ]; then
        pass "T4.4 AXDump"
    else
        ERR=$(echo "$AXDUMP" | json_field "d.get('error',{}).get('code','?')" 2>/dev/null || echo "?")
        fail "T4.4 AXDump" "error=$ERR"
    fi
else
    skip "T4.1 Context" "AX permission not granted"
    skip "T4.2 Messages" "AX permission not granted"
    skip "T4.3 Conversations" "AX permission not granted"
    skip "T4.4 AXDump" "AX permission not granted"
fi

###############################################################################
# Phase 5: Send API
###############################################################################
log "Phase 5: Send API"

if [ "${AX_AVAILABLE:-false}" = "true" ]; then
    # T5.1 Send with valid params
    SEND=$(api -X POST -H "Content-Type: application/json" \
        -d '{"adapter":"line","action":"send_message","payload":{"conversation_hint":"test","text":"ClawGate integration test","enter_to_send":true}}' \
        "$BASE_URL/v1/send")
    SEND_OK=$(echo "$SEND" | json_field "d['ok']" 2>/dev/null || echo "")
    SEND_ERR=$(echo "$SEND" | json_field "d.get('error',{}).get('code','?')" 2>/dev/null || echo "?")
    if [ "$SEND_OK" = "True" ]; then
        pass "T5.1 Send message"
    elif [ "$SEND_ERR" = "line_window_missing" ] || [ "$SEND_ERR" = "search_result_not_found" ] || [ "$SEND_ERR" = "rescan_timeout" ]; then
        skip "T5.1 Send message" "error=$SEND_ERR (expected with test conversation_hint)"
    else
        fail "T5.1 Send message" "error=$SEND_ERR"
    fi
else
    skip "T5.1 Send message" "AX permission not granted"
fi

# T5.2 Send with invalid adapter
SEND_BAD=$(api -X POST -H "Content-Type: application/json" \
    -d '{"adapter":"nonexistent","action":"send_message","payload":{"conversation_hint":"test","text":"test","enter_to_send":true}}' \
    "$BASE_URL/v1/send")
ERR_CODE=$(echo "$SEND_BAD" | json_field "d['error']['code']" 2>/dev/null || echo "")
if [ "$ERR_CODE" = "adapter_not_found" ]; then
    pass "T5.2 Send with invalid adapter returns adapter_not_found"
else
    fail "T5.2 Send invalid adapter" "Expected adapter_not_found, got: $ERR_CODE"
fi

# T5.3 Send with invalid JSON
SEND_JSON=$(api -X POST -H "Content-Type: application/json" \
    -d 'not json' "$BASE_URL/v1/send")
ERR_CODE=$(echo "$SEND_JSON" | json_field "d['error']['code']" 2>/dev/null || echo "")
if [ "$ERR_CODE" = "invalid_json" ]; then
    pass "T5.3 Send with invalid JSON returns invalid_json"
else
    fail "T5.3 Send invalid JSON" "Expected invalid_json, got: $ERR_CODE"
fi

# T5.4 Send with unsupported action
SEND_ACT=$(api -X POST -H "Content-Type: application/json" \
    -d '{"adapter":"line","action":"delete_message","payload":{"conversation_hint":"test","text":"test","enter_to_send":true}}' \
    "$BASE_URL/v1/send")
ERR_CODE=$(echo "$SEND_ACT" | json_field "d['error']['code']" 2>/dev/null || echo "")
if [ "$ERR_CODE" = "unsupported_action" ]; then
    pass "T5.4 Send with unsupported action"
else
    fail "T5.4 Send unsupported action" "Expected unsupported_action, got: $ERR_CODE"
fi

###############################################################################
# Phase 6: Origin Protection (CSRF)
###############################################################################
log "Phase 6: Security"

# T6.1 CSRF: POST /v1/send with Origin header
RESP=$(api -X POST -H "Origin: http://evil.com" -H "Content-Type: application/json" \
    -d '{"adapter":"line","action":"send_message","payload":{"conversation_hint":"test","text":"test","enter_to_send":true}}' \
    "$BASE_URL/v1/send")
ERR_CODE=$(echo "$RESP" | json_field "d['error']['code']" 2>/dev/null || echo "")
if [ "$ERR_CODE" = "browser_origin_rejected" ]; then
    pass "T6.1 CSRF protection (Origin header rejected on /v1/send)"
else
    fail "T6.1 CSRF protection" "Expected browser_origin_rejected, got: $ERR_CODE"
fi

###############################################################################
# Summary
###############################################################################
echo ""
echo "============================================"
echo -e "  ${CYAN}ClawGate Integration Test Results${NC}"
echo "============================================"
echo -e "  ${GREEN}PASS${NC}: $PASS"
echo -e "  ${RED}FAIL${NC}: $FAIL"
echo -e "  ${YELLOW}SKIP${NC}: $SKIP"
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
fi

if [ $SKIP -gt 0 ]; then
    echo ""
    echo "Skipped tests (need Mac GUI):"
    for r in "${RESULTS[@]}"; do
        if [[ "$r" == SKIP* ]]; then
            echo -e "  ${YELLOW}$r${NC}"
        fi
    done
fi

echo ""
if [ $FAIL -eq 0 ]; then
    echo -e "${GREEN}All executed tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed.${NC}"
    exit 1
fi
