#!/bin/bash
# Start ClawGateRelay on remote host "macmini" and run Host A/B E2E from local host.
#
# Usage:
#   ./scripts/run-macmini-relay-and-e2e.sh \
#     --gateway-token GATEWAY_TOKEN \
#     --federation-token FED_TOKEN \
#     --federation-port 8766 \
#     --tmux-project your-project \
#     --line-hint "Your Contact"

set -euo pipefail

REMOTE_HOST="macmini"
PORT=8765
FEDERATION_PORT=8766
GATEWAY_TOKEN=""
FEDERATION_TOKEN=""
CC_STATUS_URL="ws://localhost:8080/ws/sessions"
TMUX_PROJECT=""
LINE_HINT=""
TMUX_MODE="autonomous"
SKIP_START=false
BOOT_TIMEOUT=40
FEDERATION_WAIT_TIMEOUT=45
RESTART_GATEWAY=true
STRICT_E2E=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote-host)
      REMOTE_HOST="$2"; shift 2 ;;
    --port)
      PORT="$2"; shift 2 ;;
    --federation-port)
      FEDERATION_PORT="$2"; shift 2 ;;
    --gateway-token)
      GATEWAY_TOKEN="$2"; shift 2 ;;
    --federation-token)
      FEDERATION_TOKEN="$2"; shift 2 ;;
    --cc-status-url)
      CC_STATUS_URL="$2"; shift 2 ;;
    --tmux-project)
      TMUX_PROJECT="$2"; shift 2 ;;
    --line-hint)
      LINE_HINT="$2"; shift 2 ;;
    --tmux-mode)
      TMUX_MODE="$2"; shift 2 ;;
    --skip-start)
      SKIP_START=true; shift ;;
    --no-restart-gateway)
      RESTART_GATEWAY=false; shift ;;
    --strict)
      STRICT_E2E=true; shift ;;
    --boot-timeout)
      BOOT_TIMEOUT="$2"; shift 2 ;;
    --federation-wait-timeout)
      FEDERATION_WAIT_TIMEOUT="$2"; shift 2 ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2 ;;
  esac
done

if [[ -z "$GATEWAY_TOKEN" ]]; then
  echo "--gateway-token is required" >&2
  exit 2
fi
if [[ -z "$FEDERATION_TOKEN" ]]; then
  FEDERATION_TOKEN="$GATEWAY_TOKEN"
fi
if [[ -z "$TMUX_PROJECT" ]]; then
  echo "--tmux-project is required" >&2
  exit 2
fi
if [[ -z "$LINE_HINT" ]]; then
  echo "--line-hint is required" >&2
  exit 2
fi

LOCAL_PATH="$(pwd)"
REMOTE_IP="$(ssh -G "$REMOTE_HOST" | awk '/^hostname / { print $2; exit }')"
if [[ -z "$REMOTE_IP" ]]; then
  echo "Failed to resolve remote host '$REMOTE_HOST' via ssh config" >&2
  exit 1
fi

echo "Remote host: $REMOTE_HOST ($REMOTE_IP)"
echo "Remote path: $LOCAL_PATH"

if ! ssh -o ConnectTimeout=8 "$REMOTE_HOST" "echo ok" >/dev/null 2>&1; then
  echo "Cannot SSH to '$REMOTE_HOST' ($REMOTE_IP)." >&2
  echo "Verify network reachability and SSH access from this machine." >&2
  exit 1
fi

if [[ "$RESTART_GATEWAY" == "true" ]]; then
  echo "Restarting OpenClaw Gateway on Host A (best-effort) ..."
  if launchctl list 2>/dev/null | grep -q 'openclaw\.gateway'; then
    launchctl stop ai.openclaw.gateway >/dev/null 2>&1 || true
    sleep 2
    launchctl start ai.openclaw.gateway >/dev/null 2>&1 || true
    sleep 4
    echo "Gateway restart attempted via launchctl."
  else
    echo "Gateway launchctl service not found; skipping restart."
    echo "Hint: launchctl stop ai.openclaw.gateway && sleep 2 && launchctl start ai.openclaw.gateway"
  fi
fi

if [[ "$SKIP_START" != "true" ]]; then
  echo "Starting ClawGateRelay on $REMOTE_HOST ..."
  ssh "$REMOTE_HOST" "cd '$LOCAL_PATH' && \
    pkill -f 'swift run ClawGateRelay' >/dev/null 2>&1 || true; \
    pkill -f 'ClawGateRelay' >/dev/null 2>&1 || true; \
    nohup swift run ClawGateRelay \
      --host 0.0.0.0 \
      --port '$PORT' \
      --federation-port '$FEDERATION_PORT' \
      --token '$GATEWAY_TOKEN' \
      --federation-token '$FEDERATION_TOKEN' \
      --cc-status-url '$CC_STATUS_URL' \
      --tmux-mode '$TMUX_PROJECT=$TMUX_MODE' \
      > /tmp/clawgate-relay.log 2>&1 < /dev/null & \
    echo \$! > /tmp/clawgate-relay.pid"

  echo "Waiting for relay boot..."
  RELAY_URL="http://$REMOTE_IP:$PORT/v1/health"
  STARTED=false
  for ((i=1; i<=BOOT_TIMEOUT; i++)); do
    if curl -fsS -m 2 "$RELAY_URL" >/dev/null 2>&1; then
      STARTED=true
      break
    fi
    sleep 1
  done
  if [[ "$STARTED" != "true" ]]; then
    echo "Relay did not become healthy within ${BOOT_TIMEOUT}s: $RELAY_URL" >&2
    ssh "$REMOTE_HOST" "tail -n 120 /tmp/clawgate-relay.log" || true
    exit 1
  fi
fi

echo "Host A federation URL should be: ws://$REMOTE_IP:$FEDERATION_PORT/federation"
echo "Waiting for Host A federation client to connect (timeout: ${FEDERATION_WAIT_TIMEOUT}s) ..."
FED_READY=false
for ((i=1; i<=FEDERATION_WAIT_TIMEOUT; i++)); do
  HEALTH_JSON="$(curl -fsS -m 2 "http://$REMOTE_IP:$PORT/v1/health" 2>/dev/null || true)"
  if [[ -n "$HEALTH_JSON" ]] && echo "$HEALTH_JSON" | grep -q '"federation_connected":true'; then
    FED_READY=true
    break
  fi
  sleep 1
done
if [[ "$FED_READY" != "true" ]]; then
  echo "Federation did not become connected within ${FEDERATION_WAIT_TIMEOUT}s." >&2
  echo "Ensure Host A ClawGate federationURL/token match this relay:" >&2
  echo "  ws://$REMOTE_IP:$FEDERATION_PORT/federation" >&2
  ssh "$REMOTE_HOST" "tail -n 120 /tmp/clawgate-relay.log" || true
  exit 1
fi

echo "Running Host A/B E2E from local host ..."
E2E_ARGS=(
  --relay-url "http://$REMOTE_IP:$PORT"
  --gateway-token "$GATEWAY_TOKEN"
  --tmux-project "$TMUX_PROJECT"
  --line-hint "$LINE_HINT"
)
if [[ "$STRICT_E2E" == "true" ]]; then
  E2E_ARGS+=(--strict)
fi
./scripts/host-a-host-b-e2e.sh "${E2E_ARGS[@]}"

echo "Done."
echo "Remote relay log: ssh $REMOTE_HOST 'tail -n 120 /tmp/clawgate-relay.log'"
