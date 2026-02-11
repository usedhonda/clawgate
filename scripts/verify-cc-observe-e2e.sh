#!/usr/bin/env bash
set -euo pipefail

# Verify Host B -> Host A -> Gateway delivery for CC observe path.
#
# Flow:
# 1) Check local relay health (Host B)
# 2) Inject dummy tmux completion into local relay
# 3) Wait until Host A ops log contains the injected project id
# 4) Verify Host A messages/conversations API includes the project
# 5) Verify Host A gateway log saw the completion
#
# Usage:
#   ./scripts/verify-cc-observe-e2e.sh
#   ./scripts/verify-cc-observe-e2e.sh --remote-host macmini --wait-seconds 20

REMOTE_HOST="macmini"
WAIT_SECONDS=20
PROJECT="dummy-e2e-$(date +%H%M%S)"
TEXT_PREFIX="dummy completion from verify script"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote-host)
      REMOTE_HOST="$2"; shift 2 ;;
    --wait-seconds)
      WAIT_SECONDS="$2"; shift 2 ;;
    --project)
      PROJECT="$2"; shift 2 ;;
    --text-prefix)
      TEXT_PREFIX="$2"; shift 2 ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 2 ;;
  esac
done

TEXT="${TEXT_PREFIX} ${PROJECT}"

echo "== verify-cc-observe-e2e =="
echo "Remote host : $REMOTE_HOST"
echo "Project     : $PROJECT"
echo "Wait seconds: $WAIT_SECONDS"

echo "[1/5] Check Host B relay health"
RELAY_HEALTH="$(curl -fsS -m 3 http://127.0.0.1:9765/v1/health || true)"
if [[ "$RELAY_HEALTH" != *'"ok":true'* ]]; then
  echo "FAIL: Host B relay health is not ok" >&2
  echo "$RELAY_HEALTH" >&2
  exit 1
fi
echo "$RELAY_HEALTH"

RELAY_TOKEN="$(defaults read com.clawgate.app clawgate.federationToken 2>/dev/null || defaults read ClawGate clawgate.federationToken 2>/dev/null || true)"
if [[ -z "$RELAY_TOKEN" ]]; then
  echo "FAIL: federation token not found in defaults" >&2
  exit 1
fi

echo "[2/5] Inject dummy completion event"
INJECT_RESP="$(
  curl -fsS -X POST http://127.0.0.1:9765/v1/debug/inject-tmux-completion \
    -H "Authorization: Bearer ${RELAY_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"project\":\"${PROJECT}\",\"text\":\"${TEXT}\",\"source\":\"completion\"}"
)"
echo "$INJECT_RESP"

echo "[3/5] Wait Host A ops log delivery"
DELIVERED=false
for ((i=1; i<=WAIT_SECONDS; i++)); do
  if ssh "$REMOTE_HOST" "curl -fsS 'http://127.0.0.1:8765/v1/ops/logs?limit=120'" | grep -q "$PROJECT"; then
    DELIVERED=true
    echo "Delivered on try=$i"
    break
  fi
  sleep 1
done
if [[ "$DELIVERED" != "true" ]]; then
  echo "FAIL: Host A ops log did not include project=$PROJECT within ${WAIT_SECONDS}s" >&2
  exit 1
fi

echo "[4/5] Verify Host A messages/conversations"
MSG_RESP="$(ssh "$REMOTE_HOST" "curl -fsS 'http://127.0.0.1:8765/v1/messages?adapter=tmux&limit=20'")"
CONV_RESP="$(ssh "$REMOTE_HOST" "curl -fsS 'http://127.0.0.1:8765/v1/conversations?adapter=tmux&limit=20'")"
echo "$MSG_RESP" | head -c 500; echo
echo "$CONV_RESP" | head -c 500; echo

if [[ "$MSG_RESP" != *"$PROJECT"* ]]; then
  echo "FAIL: Host A messages API did not include project=$PROJECT" >&2
  exit 1
fi
if [[ "$CONV_RESP" != *"$PROJECT"* ]]; then
  echo "FAIL: Host A conversations API did not include project=$PROJECT" >&2
  exit 1
fi

echo "[5/5] Verify Host A gateway log"
GATEWAY_SEEN=false
for ((i=1; i<=WAIT_SECONDS; i++)); do
  if ssh "$REMOTE_HOST" "tail -n 240 ~/.openclaw/logs/gateway.log" | grep -q "$PROJECT"; then
    GATEWAY_SEEN=true
    echo "Gateway observed on try=$i"
    break
  fi
  sleep 1
done
if [[ "$GATEWAY_SEEN" != "true" ]]; then
  echo "FAIL: gateway.log did not include project=$PROJECT within ${WAIT_SECONDS}s" >&2
  exit 1
fi
ssh "$REMOTE_HOST" "tail -n 240 ~/.openclaw/logs/gateway.log" | grep "$PROJECT" | tail -n 3

echo "PASS: CC observe e2e delivery confirmed for project=$PROJECT"
