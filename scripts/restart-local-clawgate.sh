#!/usr/bin/env bash
set -euo pipefail

# Canonical local restart entrypoint for ClawGate.app.
# Always use this script instead of manually opening ClawGate.app.
#
# Usage:
#   ./scripts/restart-local-clawgate.sh
#   ./scripts/restart-local-clawgate.sh --skip-build
#   ./scripts/restart-local-clawgate.sh --project-path /Users/usedhonda/projects/ios/clawgate

PROJECT_PATH="/Users/usedhonda/projects/ios/clawgate"
SKIP_BUILD=false
SKIP_SYNC=false
SKIP_SIGN=false
WAIT_SECONDS=8
CLAWGATE_ROLE="host_b_client"
OPS_SCRIPT_NAME="restart-local-clawgate.sh"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-path)
      PROJECT_PATH="$2"; shift 2 ;;
    --skip-build)
      SKIP_BUILD=true; shift ;;
    --skip-sync)
      SKIP_SYNC=true; shift ;;
    --skip-sign)
      SKIP_SIGN=true; shift ;;
    --wait-seconds)
      WAIT_SECONDS="$2"; shift 2 ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 2 ;;
  esac
done

source "$PROJECT_PATH/scripts/lib-ops-log.sh"
ops_log info "restart_begin" "local restart started (skip_build=$SKIP_BUILD skip_sync=$SKIP_SYNC skip_sign=$SKIP_SIGN)"
trap 'ops_log error "restart_failed" "local restart failed (line=$LINENO exit=$?)"' ERR

APP_PATH="$PROJECT_PATH/ClawGate.app"
APP_BIN="$APP_PATH/Contents/MacOS/ClawGate"
BUILD_BIN="$PROJECT_PATH/.build/debug/ClawGate"

cd "$PROJECT_PATH"

echo "== restart-local-clawgate =="
echo "Project path: $PROJECT_PATH"
echo "Skip build  : $SKIP_BUILD"
echo "Skip sync   : $SKIP_SYNC"
echo "Skip sign   : $SKIP_SIGN"

if [[ "$SKIP_BUILD" != "true" ]]; then
  echo "[1/4] Build"
  swift build
fi

if [[ "$SKIP_SYNC" != "true" ]]; then
  echo "[2/4] Sync app binary"
  if [[ ! -f "$BUILD_BIN" ]]; then
    echo "Missing build output: $BUILD_BIN" >&2
    exit 1
  fi
  cp "$BUILD_BIN" "$APP_BIN"
  # Copy app icon
  if [[ -f "$PROJECT_PATH/resources/AppIcon.icns" ]]; then
    cp "$PROJECT_PATH/resources/AppIcon.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"
  fi
else
  echo "[2/4] Skip sync (by option)"
fi

if [[ "$SKIP_SIGN" != "true" ]]; then
  if security find-identity -v -p codesigning 2>/dev/null | grep -q "ClawGate Dev"; then
    echo "[3/4] Codesign (ClawGate Dev)"
    codesign --force --deep --options runtime \
      --identifier com.clawgate.app \
      --entitlements ClawGate.entitlements \
      --sign "ClawGate Dev" "$APP_PATH"
  else
    echo "[3/4] Skip codesign (ClawGate Dev not found)"
  fi
else
  echo "[3/4] Skip codesign (by option)"
fi

echo "[4/4] Restart app"
pkill -f "/Users/usedhonda/projects/Mac/clawgate/ClawGate.app/Contents/MacOS/ClawGate" >/dev/null 2>&1 || true
pkill -f "/Users/usedhonda/projects/ios/clawgate/ClawGate.app/Contents/MacOS/ClawGate" >/dev/null 2>&1 || true

# Wait for old process to fully exit (up to 5s, then SIGKILL)
for ((w=1; w<=5; w++)); do
  if ! pgrep -f "clawgate/ClawGate.app/Contents/MacOS/ClawGate" >/dev/null 2>&1; then
    break
  fi
  if [[ $w -eq 5 ]]; then
    echo "Old process still alive after 5s, sending SIGKILL"
    pkill -9 -f "clawgate/ClawGate.app/Contents/MacOS/ClawGate" >/dev/null 2>&1 || true
    sleep 1
  fi
  sleep 1
done

open -na "$APP_PATH"
sleep 2

echo "Process:"
ps aux | grep "/Users/usedhonda/projects/ios/clawgate/ClawGate.app/Contents/MacOS/ClawGate" | grep -v grep || true

echo "Binary marker:"
strings "$APP_BIN" | egrep -n "Apply Recommended|Refresh Hosts|Manual \\(select server\\)" | head -n 5 || true

echo "Health:"
for ((i=1; i<=WAIT_SECONDS; i++)); do
  if curl -fsS -m 2 http://127.0.0.1:8765/v1/health >/dev/null 2>&1; then
    curl -sS -m 2 http://127.0.0.1:8765/v1/health || true
    echo
    ops_log info "restart_ok" "local health check succeeded"
    exit 0
  fi
  sleep 1
done
echo "health check timeout (${WAIT_SECONDS}s)" >&2
ops_log error "restart_timeout" "local health check timeout (${WAIT_SECONDS}s)"
exit 1
