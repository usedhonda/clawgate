#!/usr/bin/env bash
set -euo pipefail

# Restart local ClawGateRelay on Host B and wait for health.
#
# Usage:
#   ./scripts/restart-hostb-relay.sh
#   ./scripts/restart-hostb-relay.sh --token <gateway_token> --federation-token <federation_token>

PORT="9765"
FEDERATION_PORT="8766"
HOST="0.0.0.0"
CC_STATUS_URL="ws://localhost:8080/ws/sessions"
TOKEN="${RELAY_TOKEN:-}"
FEDERATION_TOKEN="${FEDERATION_TOKEN:-}"
WAIT_SECONDS=20

while [[ $# -gt 0 ]]; do
  case "$1" in
    --token)
      TOKEN="$2"; shift 2 ;;
    --federation-token)
      FEDERATION_TOKEN="$2"; shift 2 ;;
    --port)
      PORT="$2"; shift 2 ;;
    --federation-port)
      FEDERATION_PORT="$2"; shift 2 ;;
    --wait-seconds)
      WAIT_SECONDS="$2"; shift 2 ;;
    --cc-status-url)
      CC_STATUS_URL="$2"; shift 2 ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 2 ;;
  esac
done

if [[ -z "$TOKEN" ]]; then
  TOKEN="$(defaults read com.clawgate.app clawgate.federationToken 2>/dev/null || true)"
fi
if [[ -z "$TOKEN" ]]; then
  TOKEN="$(defaults read ClawGate clawgate.federationToken 2>/dev/null || true)"
fi
if [[ -z "$TOKEN" ]]; then
  TOKEN="$(defaults read com.clawgate.app clawgate.remoteAccessToken 2>/dev/null || true)"
fi
if [[ -z "$TOKEN" ]]; then
  TOKEN="$(defaults read ClawGate clawgate.remoteAccessToken 2>/dev/null || true)"
fi
if [[ -z "$TOKEN" ]]; then
  TOKEN="$(ps aux | awk '
    /ClawGateRelay/ && /--token/ {
      for (i = 1; i <= NF; i++) {
        if ($i == \"--token\" && (i + 1) <= NF) {
          print $(i + 1);
          exit;
        }
      }
    }' || true)"
fi

if [[ -z "$FEDERATION_TOKEN" ]]; then
  FEDERATION_TOKEN="$TOKEN"
fi

if [[ -z "$TOKEN" ]]; then
  echo "Relay token is empty. Pass --token or export RELAY_TOKEN." >&2
  exit 1
fi

echo "Restarting local relay (port=$PORT, federation_port=$FEDERATION_PORT)"
echo "Using token: ${TOKEN:0:4}***"

if [[ ! -x ".build/arm64-apple-macosx/debug/ClawGateRelay" ]]; then
  echo "Building ClawGateRelay..."
  swift build --product ClawGateRelay
fi

pkill -f 'ClawGateRelay --host' >/dev/null 2>&1 || true
pkill -f 'swift run ClawGateRelay' >/dev/null 2>&1 || true
sleep 1

nohup ./.build/arm64-apple-macosx/debug/ClawGateRelay \
  --host "$HOST" \
  --port "$PORT" \
  --federation-port "$FEDERATION_PORT" \
  --token "$TOKEN" \
  --federation-token "$FEDERATION_TOKEN" \
  --cc-status-url "$CC_STATUS_URL" \
  > /tmp/clawgate-relay-local.log 2>&1 < /dev/null &

for ((i=1; i<=WAIT_SECONDS; i++)); do
  if curl -fsS -m 2 "http://127.0.0.1:${PORT}/v1/health" >/dev/null 2>&1; then
    echo "Relay healthy."
    curl -sS -m 2 "http://127.0.0.1:${PORT}/v1/health" || true
    echo
    exit 0
  fi
  sleep 1
done

echo "Relay did not become healthy in ${WAIT_SECONDS}s." >&2
echo "Recent relay log:" >&2
tail -n 120 /tmp/clawgate-relay-local.log >&2 || true
exit 1
