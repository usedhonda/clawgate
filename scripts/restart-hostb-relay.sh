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
TMUX_MODE_ARGS=()

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

load_tmux_mode_args() {
  local mode_blob json_blob
  mode_blob="$(defaults read com.clawgate.app clawgate.tmuxSessionModes 2>/dev/null || true)"
  if [[ -z "$mode_blob" ]]; then
    mode_blob="$(defaults read ClawGate clawgate.tmuxSessionModes 2>/dev/null || true)"
  fi
  [[ -z "$mode_blob" ]] && return 0

  # Stored as a JSON string in defaults (e.g. {"general":"observe","tproj":"observe"}).
  # Try raw value first, then fallback to unescaped variant.
  json_blob="$mode_blob"
  if ! python3 -c 'import json,sys; json.loads(sys.stdin.read())' <<< "$json_blob" >/dev/null 2>&1; then
    json_blob="$(printf '%b' "$mode_blob")"
  fi

  while IFS= read -r pair; do
    local key value
    key="${pair%%$'\t'*}"
    value="${pair#*$'\t'}"
    if [[ "$value" == "ignore" || "$value" == "observe" || "$value" == "auto" || "$value" == "autonomous" ]]; then
      TMUX_MODE_ARGS+=(--tmux-mode "$key=$value")
    fi
  done < <(python3 - <<'PY' "$json_blob"
import json, sys
raw = sys.argv[1]
try:
    obj = json.loads(raw)
except Exception:
    obj = {}
if isinstance(obj, dict):
    for k, v in obj.items():
        print(f"{k}\t{v}")
PY
)
}

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
load_tmux_mode_args
echo "Loaded tmux modes: ${#TMUX_MODE_ARGS[@]}"

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
  mode_args_str=""
  if (( ${#TMUX_MODE_ARGS[@]} > 0 )); then
    for (( idx=0; idx<${#TMUX_MODE_ARGS[@]}; idx+=2 )); do
      mode_args_str+=" ${TMUX_MODE_ARGS[$idx]} '${TMUX_MODE_ARGS[$((idx+1))]}'"
    done
  fi
  RELAY_CMD="'$BINARY_PATH' --host '$HOST' --port '$PORT' --federation-port '$FEDERATION_PORT' --token '$TOKEN' --federation-token '$FEDERATION_TOKEN' --cc-status-url '$CC_STATUS_URL'${mode_args_str} >> /tmp/clawgate-relay-local.log 2>&1"
  tmux new-session -d -s "$TMUX_SESSION" "cd '$REPO_DIR' && $RELAY_CMD"
else
  mkdir -p "$HOME/Library/LaunchAgents"
  # Generate a launchd job so relay survives shell/session lifecycle.
  {
  cat <<EOF
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
EOF
    if (( ${#TMUX_MODE_ARGS[@]} > 0 )); then
      for (( idx=0; idx<${#TMUX_MODE_ARGS[@]}; idx+=2 )); do
        echo "    <string>${TMUX_MODE_ARGS[$idx]}</string>"
        echo "    <string>${TMUX_MODE_ARGS[$((idx+1))]}</string>"
      done
    fi
  cat <<EOF
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
  } > "$PLIST_PATH"

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
      "${TMUX_MODE_ARGS[@]}" \
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
