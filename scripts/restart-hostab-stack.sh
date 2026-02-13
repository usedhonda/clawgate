#!/usr/bin/env bash
set -euo pipefail

# Restart Host A + Host B stack in a fixed order.
# 1) Sync repo to Host A (macmini)
# 2) Restart Host A ClawGate + OpenClaw Gateway
# 3) Restart Host B ClawGate
# 4) Print health + doctor summary
#
# Usage:
#   ./scripts/restart-hostab-stack.sh
#   ./scripts/restart-hostab-stack.sh --remote-host macmini --project-path /Users/usedhonda/projects/ios/clawgate

REMOTE_HOST="macmini"
PROJECT_PATH="/Users/usedhonda/projects/ios/clawgate"
SKIP_SYNC=false
SKIP_REMOTE_BUILD=true
SKIP_LOCAL_RELAY=false
ALLOW_REMOTE_BUILD=false
CLAWGATE_ROLE="host_b_client"
OPS_SCRIPT_NAME="restart-hostab-stack.sh"

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
    --allow-remote-build)
      ALLOW_REMOTE_BUILD=true; SKIP_REMOTE_BUILD=false; shift ;;
    --skip-local-relay)
      SKIP_LOCAL_RELAY=true; shift ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 2 ;;
  esac
done

source "$PROJECT_PATH/scripts/lib-ops-log.sh"
ops_log info "stack_restart_begin" "stack restart begin (remote_host=$REMOTE_HOST skip_sync=$SKIP_SYNC skip_remote_build=$SKIP_REMOTE_BUILD skip_local_relay=$SKIP_LOCAL_RELAY)"
trap 'ops_log error "stack_restart_failed" "stack restart failed (line=$LINENO exit=$?)"' ERR

echo "== restart-hostab-stack =="
echo "Remote host : $REMOTE_HOST"
echo "Project path: $PROJECT_PATH"
echo "Skip sync   : $SKIP_SYNC"
echo "Skip build  : $SKIP_REMOTE_BUILD"
echo "Skip relay  : $SKIP_LOCAL_RELAY"

# Safety rule: Host A (macmini) build/update must be performed by the
# local desktop script to avoid intermittent SSH codesign rollback.
# If you really need remote build here, pass --allow-remote-build explicitly.
if [[ "$ALLOW_REMOTE_BUILD" != "true" ]]; then
  echo "[policy] Host A remote build is disabled by default."
  echo "[policy] Run on macmini local session first:"
  echo "         KEYCHAIN_PASSWORD='...' ./scripts/macmini-local-sign-and-restart.sh"
  SKIP_REMOTE_BUILD=true
fi

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

echo "[local] Restart Host B ClawGate.app (canonical path)"
./scripts/restart-local-clawgate.sh

echo "[local] health:"
curl -sS -m 3 http://127.0.0.1:8765/v1/health || true
echo
echo "[local] doctor:"
curl -sS -m 3 http://127.0.0.1:8765/v1/doctor || true
echo

echo "[remote] health + gateway:"
ssh "$REMOTE_HOST" "launchctl list | grep ai.openclaw.gateway || true; curl -sS -m 3 http://127.0.0.1:8765/v1/health || true; echo; curl -sS -m 3 http://127.0.0.1:8765/v1/doctor || true"
echo

echo "Done."
ops_log info "stack_restart_ok" "stack restart finished"
