#!/usr/bin/env bash
set -euo pipefail

# Canonical post-task restart/verification.
# Run this at the end of implementation tasks without waiting for manual confirmation.

REMOTE_HOST="macmini"
PROJECT_PATH="/Users/usedhonda/projects/ios/clawgate"
SKIP_SYNC=false
SKIP_REMOTE_BUILD=true
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

cd "$PROJECT_PATH"

echo "== post-task-restart =="
echo "Remote host : $REMOTE_HOST"
echo "Project path: $PROJECT_PATH"
echo "Skip sync   : $SKIP_SYNC"
echo "Skip build  : $SKIP_REMOTE_BUILD"
echo "Skip relay  : $SKIP_LOCAL_RELAY"

STACK_ARGS=(--remote-host "$REMOTE_HOST" --project-path "$PROJECT_PATH")
if [[ "$SKIP_SYNC" == "true" ]]; then
  STACK_ARGS+=(--skip-sync)
fi
if [[ "$SKIP_REMOTE_BUILD" == "true" ]]; then
  STACK_ARGS+=(--skip-remote-build)
fi
if [[ "$SKIP_LOCAL_RELAY" == "true" ]]; then
  STACK_ARGS+=(--skip-local-relay)
fi

if ! ./scripts/restart-hostab-stack.sh "${STACK_ARGS[@]}"; then
  echo
  echo "[fallback] Host A signing/restart may require local desktop session on macmini."
  echo "[fallback] Run on macmini:"
  echo "  KEYCHAIN_PASSWORD='***' ./scripts/macmini-local-sign-and-restart.sh --project-path $PROJECT_PATH"
  echo "[fallback] Then rerun:"
  echo "  ./scripts/post-task-restart.sh --remote-host $REMOTE_HOST --project-path $PROJECT_PATH --skip-sync --skip-remote-build"
  exit 1
fi

echo
echo "[verify] Host B health"
curl -fsS -m 3 http://127.0.0.1:8765/v1/health >/dev/null
echo "ok"

echo "[verify] Host B relay health"
curl -fsS -m 3 http://127.0.0.1:9765/v1/health >/dev/null
echo "ok"

echo "[verify] Host A health"
ssh "$REMOTE_HOST" "curl -fsS -m 3 http://127.0.0.1:8765/v1/health >/dev/null"
echo "ok"

echo "[verify] Host A gateway"
ssh "$REMOTE_HOST" "launchctl list | grep ai.openclaw.gateway >/dev/null"
echo "ok"

echo "Done."
