#!/bin/bash
# Configure Host A/B roles and federation settings.
#
# Host A (local): ClawGate server role + federation client settings
# Host B (remote): client role marker (for consistency) via defaults
#
# Usage:
#   ./scripts/configure-host-a-host-b.sh \
#     --remote-host macmini \
#     --federation-token YOUR_TOKEN
#
# Optional:
#   --relay-port 8765
#   --federation-port 8766
#   --no-restart-app
#   --no-remote-role

set -euo pipefail

REMOTE_HOST="macmini"
RELAY_PORT=8765
FEDERATION_PORT=8766
FEDERATION_TOKEN=""
RESTART_APP=true
SET_REMOTE_ROLE=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote-host)
      REMOTE_HOST="$2"; shift 2 ;;
    --relay-port)
      RELAY_PORT="$2"; shift 2 ;;
    --federation-port)
      FEDERATION_PORT="$2"; shift 2 ;;
    --federation-token)
      FEDERATION_TOKEN="$2"; shift 2 ;;
    --no-restart-app)
      RESTART_APP=false; shift ;;
    --no-remote-role)
      SET_REMOTE_ROLE=false; shift ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2 ;;
  esac
done

if [[ -z "$FEDERATION_TOKEN" ]]; then
  echo "--federation-token is required" >&2
  exit 2
fi

REMOTE_IP="$(ssh -G "$REMOTE_HOST" | awk '/^hostname / { print $2; exit }')"
if [[ -z "$REMOTE_IP" ]]; then
  echo "Failed to resolve remote host '$REMOTE_HOST'" >&2
  exit 1
fi

if ! ssh -o ConnectTimeout=8 "$REMOTE_HOST" "echo ok" >/dev/null 2>&1; then
  echo "Cannot reach remote host '$REMOTE_HOST'" >&2
  exit 1
fi

FED_URL="ws://$REMOTE_IP:$FEDERATION_PORT/federation"

echo "Configuring Host A (local) as server role..."
defaults write com.clawgate.app 'clawgate.nodeRole' -string 'server'
defaults write com.clawgate.app 'clawgate.federationEnabled' -bool true
defaults write com.clawgate.app 'clawgate.federationURL' -string "$FED_URL"
defaults write com.clawgate.app 'clawgate.federationToken' -string "$FEDERATION_TOKEN"

# Keep swift-run domain consistent for local validation flows.
defaults write ClawGate 'clawgate.nodeRole' -string 'server'
defaults write ClawGate 'clawgate.federationEnabled' -bool true
defaults write ClawGate 'clawgate.federationURL' -string "$FED_URL"
defaults write ClawGate 'clawgate.federationToken' -string "$FEDERATION_TOKEN"

if [[ "$SET_REMOTE_ROLE" == "true" ]]; then
  echo "Configuring Host B (remote) as client role marker..."
  ssh "$REMOTE_HOST" "defaults write com.clawgate.app 'clawgate.nodeRole' -string 'client' || true; defaults write ClawGate 'clawgate.nodeRole' -string 'client' || true"
fi

if [[ "$RESTART_APP" == "true" ]]; then
  echo "Restarting Host A ClawGate.app..."
  pkill -f '/Users/usedhonda/projects/ios/clawgate/ClawGate.app/Contents/MacOS/ClawGate' >/dev/null 2>&1 || true
  sleep 1
  open '/Users/usedhonda/projects/ios/clawgate/ClawGate.app'
fi

echo ""
echo "Done."
echo "Host A federation URL: $FED_URL"
echo "Verify:"
echo "  curl -s http://127.0.0.1:8765/v1/config | python3 -m json.tool"
echo "  curl -s http://$REMOTE_IP:$RELAY_PORT/v1/health | python3 -m json.tool"
