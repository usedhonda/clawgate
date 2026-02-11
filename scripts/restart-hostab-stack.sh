#!/usr/bin/env bash
set -euo pipefail

# Restart Host A + Host B stack in a fixed order.
# 1) Sync repo to Host A (macmini)
# 2) Restart Host A ClawGate + OpenClaw Gateway
# 3) Restart Host B ClawGate + ClawGateRelay
# 4) Print health + doctor summary
#
# Usage:
#   ./scripts/restart-hostab-stack.sh
#   ./scripts/restart-hostab-stack.sh --remote-host macmini --project-path /Users/usedhonda/projects/ios/clawgate

REMOTE_HOST="macmini"
PROJECT_PATH="/Users/usedhonda/projects/ios/clawgate"
SKIP_SYNC=false
SKIP_REMOTE_BUILD=false
SKIP_LOCAL_RELAY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote-host)
      REMOTE_HOST="$2"; shift 2 ;;
    --project-path)
      PROJECT_PATH="$2"; shift 2 ;;
    --skip-sync)
      SKIP_SYNC=true; shift ;;
    --skip-remote-build)
      SKIP_REMOTE_BUILD=true; shift ;;
    --skip-local-relay)
      SKIP_LOCAL_RELAY=true; shift ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 2 ;;
  esac
done

echo "== restart-hostab-stack =="
echo "Remote host : $REMOTE_HOST"
echo "Project path: $PROJECT_PATH"
echo "Skip sync   : $SKIP_SYNC"
echo "Skip build  : $SKIP_REMOTE_BUILD"
echo "Skip relay  : $SKIP_LOCAL_RELAY"

# Keep federation token aligned with relay default behavior:
# ClawGateRelay uses gateway token for federation auth unless explicitly overridden.
# Set FEDERATION_TOKEN in the shell before running this script to keep both sides in sync.
if [[ -n "${FEDERATION_TOKEN:-}" ]]; then
  ssh "$REMOTE_HOST" "defaults write com.clawgate.app clawgate.federationToken -string '$FEDERATION_TOKEN' || true; defaults write ClawGate clawgate.federationToken -string '$FEDERATION_TOKEN' || true" >/dev/null 2>&1 || true
fi

if [[ "$SKIP_SYNC" != "true" ]]; then
  ./scripts/sync-same-path-to-macmini.sh --remote-host "$REMOTE_HOST"
fi

if [[ "$SKIP_REMOTE_BUILD" == "true" ]]; then
  ./scripts/restart-macmini-openclaw.sh \
    --remote-host "$REMOTE_HOST" \
    --project-path "$PROJECT_PATH" \
    --skip-build
else
  ./scripts/restart-macmini-openclaw.sh \
    --remote-host "$REMOTE_HOST" \
    --project-path "$PROJECT_PATH"
fi

echo "[local] Restart Host B ClawGate.app"
pkill -f '/Users/usedhonda/projects/ios/clawgate/ClawGate.app/Contents/MacOS/ClawGate' >/dev/null 2>&1 || true
sleep 1
open -na /Users/usedhonda/projects/ios/clawgate/ClawGate.app
sleep 2

if [[ "$SKIP_LOCAL_RELAY" != "true" ]]; then
  echo "[local] Restart Host B ClawGateRelay"
  EFFECTIVE_FED_TOKEN="${FEDERATION_TOKEN:-}"
  if [[ -z "$EFFECTIVE_FED_TOKEN" ]]; then
    EFFECTIVE_FED_TOKEN="$(ssh "$REMOTE_HOST" "defaults read com.clawgate.app clawgate.federationToken 2>/dev/null || defaults read ClawGate clawgate.federationToken 2>/dev/null || true" | tr -d '\r')"
  fi
  if [[ -n "$EFFECTIVE_FED_TOKEN" ]]; then
    RELAY_TOKEN="$EFFECTIVE_FED_TOKEN" FEDERATION_TOKEN="$EFFECTIVE_FED_TOKEN" ./scripts/restart-hostb-relay.sh
  else
    ./scripts/restart-hostb-relay.sh
  fi
fi

echo "[local] health:"
curl -sS -m 3 http://127.0.0.1:8765/v1/health || true
echo
echo "[local] relay health:"
curl -sS -m 3 http://127.0.0.1:9765/v1/health || true
echo
echo "[local] doctor:"
curl -sS -m 3 http://127.0.0.1:8765/v1/doctor || true
echo

echo "[remote] health + gateway:"
ssh "$REMOTE_HOST" "launchctl list | grep ai.openclaw.gateway || true; curl -sS -m 3 http://127.0.0.1:8765/v1/health || true; echo; curl -sS -m 3 http://127.0.0.1:8765/v1/doctor || true"
echo

echo "Done."
