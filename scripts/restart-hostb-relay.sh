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
LABEL="com.clawgate.relay"
TMUX_SESSION="clawgate-relay"
USE_TMUX=true

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
    --no-tmux)
      USE_TMUX=false; shift ;;
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

REPO_DIR="$(pwd)"
BINARY_PATH="$REPO_DIR/.build/arm64-apple-macosx/debug/ClawGateRelay"
PLIST_PATH="$HOME/Library/LaunchAgents/${LABEL}.plist"

if [[ ! -x "$BINARY_PATH" ]]; then
  echo "Building ClawGateRelay..."
  swift build --product ClawGateRelay
fi

# Best effort codesign to reduce firewall/re-auth churn on incoming tailscale connections.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "ClawGate Dev"; then
  codesign --force --options runtime --sign "ClawGate Dev" "$BINARY_PATH" >/dev/null 2>&1 || true
fi

tmux kill-session -t "$TMUX_SESSION" >/dev/null 2>&1 || true
pkill -f 'ClawGateRelay --host' >/dev/null 2>&1 || true
pkill -f 'swift run ClawGateRelay' >/dev/null 2>&1 || true
sleep 1

if [[ "$USE_TMUX" == "true" ]] && command -v tmux >/dev/null 2>&1; then
  RELAY_CMD="'$BINARY_PATH' --host '$HOST' --port '$PORT' --federation-port '$FEDERATION_PORT' --token '$TOKEN' --federation-token '$FEDERATION_TOKEN' --cc-status-url '$CC_STATUS_URL' >> /tmp/clawgate-relay-local.log 2>&1"
  tmux new-session -d -s "$TMUX_SESSION" "cd '$REPO_DIR' && $RELAY_CMD"
else
  mkdir -p "$HOME/Library/LaunchAgents"
  # Generate a launchd job so relay survives shell/session lifecycle.
  cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${BINARY_PATH}</string>
    <string>--host</string>
    <string>${HOST}</string>
    <string>--port</string>
    <string>${PORT}</string>
    <string>--federation-port</string>
    <string>${FEDERATION_PORT}</string>
    <string>--token</string>
    <string>${TOKEN}</string>
    <string>--federation-token</string>
    <string>${FEDERATION_TOKEN}</string>
    <string>--cc-status-url</string>
    <string>${CC_STATUS_URL}</string>
  </array>
  <key>WorkingDirectory</key>
  <string>${REPO_DIR}</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/tmp/clawgate-relay-local.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/clawgate-relay-local.log</string>
</dict>
</plist>
EOF

  launchctl bootout "gui/$UID/$LABEL" >/dev/null 2>&1 || true
  launchctl bootout "gui/$UID" "$PLIST_PATH" >/dev/null 2>&1 || true

  if launchctl bootstrap "gui/$UID" "$PLIST_PATH" >/dev/null 2>&1; then
    launchctl enable "gui/$UID/$LABEL" >/dev/null 2>&1 || true
    launchctl kickstart -k "gui/$UID/$LABEL" >/dev/null 2>&1 || true
  else
    echo "WARN: launchd bootstrap failed; falling back to direct relay process start."
    nohup "$BINARY_PATH" \
      --host "$HOST" \
      --port "$PORT" \
      --federation-port "$FEDERATION_PORT" \
      --token "$TOKEN" \
      --federation-token "$FEDERATION_TOKEN" \
      --cc-status-url "$CC_STATUS_URL" \
      > /tmp/clawgate-relay-local.log 2>&1 < /dev/null &
  fi
fi

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
