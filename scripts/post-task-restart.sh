#!/usr/bin/env bash
set -euo pipefail

# Canonical post-task restart/verification.
# Run this at the end of implementation tasks without waiting for manual confirmation.

REMOTE_HOST="macmini"
SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
PROJECT_PATH="${PROJECT_PATH:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SKIP_SYNC=false
SKIP_REMOTE_BUILD=true
REQUIRE_HOSTA_LOCAL_SIGN=false

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
      shift ;;  # deprecated: relay removed, kept for backward compat
    --require-hosta-local-sign)
      REQUIRE_HOSTA_LOCAL_SIGN=true; shift ;;
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
echo "Require HostA local sign: $REQUIRE_HOSTA_LOCAL_SIGN"

STACK_ARGS=(--remote-host "$REMOTE_HOST" --project-path "$PROJECT_PATH" --skip-local-relay)
if [[ "$SKIP_SYNC" == "true" ]]; then
  STACK_ARGS+=(--skip-sync)
fi
if [[ "$SKIP_REMOTE_BUILD" == "true" ]]; then
  STACK_ARGS+=(--skip-remote-build)
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

echo "[verify] Host A health"
ssh "$REMOTE_HOST" "curl -fsS -m 3 http://127.0.0.1:8765/v1/health >/dev/null"
echo "ok"

echo "[verify] Host A gateway"
ssh "$REMOTE_HOST" "launchctl list | grep ai.openclaw.gateway >/dev/null"
echo "ok"

if [[ "$REQUIRE_HOSTA_LOCAL_SIGN" == "true" ]]; then
  echo "[verify] Host A local-sign stamp"
  REMOTE_HEAD="$(ssh "$REMOTE_HOST" "cd '$PROJECT_PATH' && git rev-parse HEAD 2>/dev/null || echo unknown" | tr -d '\r')"
  STAMP_COMMIT="$(ssh "$REMOTE_HOST" "sed -n 's/^commit=//p' '$PROJECT_PATH/.runtime/hosta-local-sign.stamp' 2>/dev/null | head -n 1" | tr -d '\r')"
  STAMP_TS="$(ssh "$REMOTE_HOST" "sed -n 's/^ts=//p' '$PROJECT_PATH/.runtime/hosta-local-sign.stamp' 2>/dev/null | head -n 1" | tr -d '\r')"
  if [[ -z "$STAMP_COMMIT" || "$STAMP_COMMIT" != "$REMOTE_HEAD" ]]; then
    echo "WARN: Host A local-sign stamp is missing or stale." >&2
    echo "  remote_head: $REMOTE_HEAD" >&2
    echo "  stamp_head : ${STAMP_COMMIT:-<none>}" >&2
    echo "  suggestion : KEYCHAIN_PASSWORD='***' ./scripts/macmini-local-sign-and-restart.sh --project-path $PROJECT_PATH" >&2
  else
    echo "ok (commit=$STAMP_COMMIT ts=$STAMP_TS)"
  fi
fi

echo "Done."
