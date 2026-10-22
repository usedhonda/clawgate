#!/usr/bin/env bash
set -euo pipefail

# Canonical local restart entrypoint for ClawGate.app.
# Always use this script instead of manually opening ClawGate.app.
#
# Usage:
#   ./scripts/restart-local-clawgate.sh
#   ./scripts/restart-local-clawgate.sh --skip-build
#   ./scripts/restart-local-clawgate.sh --skip-plugin-sync
#   ./scripts/restart-local-clawgate.sh --plugin-client-only
#   ./scripts/restart-local-clawgate.sh --project-path "$(pwd)"
#   ./scripts/restart-local-clawgate.sh --recover-ambient-state-file .local/before.json

SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
PROJECT_PATH="${PROJECT_PATH:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SKIP_BUILD=false
SKIP_SYNC=false
SKIP_PLUGIN_SYNC=false
PLUGIN_CLIENT_ONLY=false
SKIP_SIGN=false
STAGE_ONLY=false
WAIT_SECONDS=8
AMBIENT_RECOVERY_FILE=""
export CLAWGATE_ROLE="host_b_client"
export OPS_SCRIPT_NAME="restart-local-clawgate.sh"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-path)
      PROJECT_PATH="$2"; shift 2 ;;
    --skip-build)
      SKIP_BUILD=true; shift ;;
    --skip-sync)
      SKIP_SYNC=true; shift ;;
    --skip-plugin-sync)
      SKIP_PLUGIN_SYNC=true; shift ;;
    --plugin-client-only)
      PLUGIN_CLIENT_ONLY=true; shift ;;
    --skip-sign)
      SKIP_SIGN=true; shift ;;
    --stage-only)
      STAGE_ONLY=true; shift ;;
    --wait-seconds)
      WAIT_SECONDS="$2"; shift 2 ;;
    --recover-ambient-state-file)
      AMBIENT_RECOVERY_FILE="$2"; shift 2 ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 2 ;;
  esac
done

if [[ "$PLUGIN_CLIENT_ONLY" == "true" && "$SKIP_PLUGIN_SYNC" == "true" ]]; then
  echo "--plugin-client-only cannot be combined with --skip-plugin-sync" >&2
  exit 2
fi

if [[ "$STAGE_ONLY" == "true" ]] && {
  [[ "$SKIP_BUILD" != "true" || "$SKIP_SYNC" != "true" || "$SKIP_PLUGIN_SYNC" != "true" ]] ||
  [[ "$SKIP_SIGN" == "true" || "$PLUGIN_CLIENT_ONLY" == "true" ]];
}; then
  echo "--stage-only requires --skip-build --skip-sync --skip-plugin-sync and signing." >&2
  exit 2
fi

source "$PROJECT_PATH/scripts/lib-ops-log.sh"
ops_log info "restart_begin" "local restart started (skip_build=$SKIP_BUILD skip_sync=$SKIP_SYNC skip_plugin_sync=$SKIP_PLUGIN_SYNC plugin_client_only=$PLUGIN_CLIENT_ONLY skip_sign=$SKIP_SIGN)"
trap 'ops_log error "restart_failed" "local restart failed (line=$LINENO exit=$?)"' ERR

APP_PATH="$PROJECT_PATH/ClawGate.app"
APP_BIN="$APP_PATH/Contents/MacOS/ClawGate"
BUILD_BIN="$PROJECT_PATH/.build/debug/ClawGate"
PLUGIN_CLAWGATE_SRC="$PROJECT_PATH/extensions/openclaw-plugin"
PLUGIN_CLAWGATE_DST="$HOME/.openclaw/extensions/clawgate"

if [[ "$PLUGIN_CLIENT_ONLY" == "true" ]]; then
  PLUGIN_CLIENT_SRC="$PLUGIN_CLAWGATE_SRC/src/client.js"
  PLUGIN_CLIENT_DST="$PLUGIN_CLAWGATE_DST/src/client.js"
  if [[ ! -f "$PLUGIN_CLIENT_SRC" || -L "$PLUGIN_CLIENT_SRC" ]]; then
    echo "Missing or symlinked plugin client source: $PLUGIN_CLIENT_SRC" >&2
    exit 1
  fi
  if [[ ! -d "$PLUGIN_CLAWGATE_DST/src" || -L "$PLUGIN_CLAWGATE_DST/src" ]]; then
    echo "Missing or symlinked plugin destination directory: $PLUGIN_CLAWGATE_DST/src" >&2
    exit 1
  fi
  if [[ ! -f "$PLUGIN_CLIENT_DST" || -L "$PLUGIN_CLIENT_DST" ]]; then
    echo "Plugin client destination is not a regular file: $PLUGIN_CLIENT_DST" >&2
    exit 1
  fi
fi

cd "$PROJECT_PATH"

echo "== restart-local-clawgate =="
echo "Project path: $PROJECT_PATH"
echo "Skip build  : $SKIP_BUILD"
echo "Skip sync   : $SKIP_SYNC"
echo "Skip plugins: $SKIP_PLUGIN_SYNC"
echo "Client only : $PLUGIN_CLIENT_ONLY"
echo "Skip sign   : $SKIP_SIGN"

if [[ "$SKIP_BUILD" != "true" ]]; then
  echo "[1/5] Build"
  swift build
fi

# Stop before replacing or signing mapped executable pages. Modifying a live
# bundle can terminate the old process with CODESIGNING Invalid Page.
APP_PROCESS_PAT="/ClawGate\\.app/Contents/MacOS/ClawGate$"
AMBIENT_RESTART_STATE="null"
if [[ "$STAGE_ONLY" != "true" ]] && { [[ -n "$AMBIENT_RECOVERY_FILE" ]] || pgrep -f "$APP_PROCESS_PAT" >/dev/null 2>&1; }; then
  # Read immediately before stopping, not before the build: retain a user's
  # latest microphone/transcription choice, including capture without a stream.
  if [[ -n "$AMBIENT_RECOVERY_FILE" ]]; then
    AMBIENT_RESTART_STATE="$(python3 "$SCRIPT_DIR/ambient-restart-state.py" snapshot --recovery-file "$AMBIENT_RECOVERY_FILE")"
  else
    AMBIENT_RESTART_STATE="$(python3 "$SCRIPT_DIR/ambient-restart-state.py" snapshot)"
  fi
fi
if [[ "$STAGE_ONLY" != "true" ]]; then
pkill -f "$APP_PROCESS_PAT" >/dev/null 2>&1 || true

# Wait for old process to fully exit (up to 5s, then SIGKILL)
for ((w=1; w<=5; w++)); do
  if ! pgrep -f "$APP_PROCESS_PAT" >/dev/null 2>&1; then
    break
  fi
  if [[ $w -eq 5 ]]; then
    echo "Old process still alive after 5s, sending SIGKILL"
    pkill -9 -f "$APP_PROCESS_PAT" >/dev/null 2>&1 || true
    sleep 1
  fi
  sleep 1
done
fi

STAGE_TEAM=""
if [[ "$STAGE_ONLY" == "true" ]]; then
  [[ -f "$APP_BIN" && ! -L "$APP_BIN" ]] || { echo "Missing staged executable." >&2; exit 1; }
  if pgrep -f "$APP_BIN" >/dev/null 2>&1; then
    echo "Refusing to sign a running staged app." >&2
    exit 1
  fi
  STAGE_TEMPLATE="$PROJECT_PATH/ClawGate.template.app"
  [[ -d "$STAGE_TEMPLATE" && ! -L "$STAGE_TEMPLATE" ]] || { echo "Missing original signed template." >&2; exit 1; }
  codesign --verify --deep --strict "$STAGE_TEMPLATE"
  STAGE_TEAM="$(codesign -dv --verbose=4 "$STAGE_TEMPLATE" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
  [[ -n "$STAGE_TEAM" && "$STAGE_TEAM" != "not set" ]] || { echo "Missing original signing team." >&2; exit 1; }
fi


if [[ "$SKIP_SYNC" != "true" ]]; then
  echo "[2/5] Sync app binary"
  bash "$PROJECT_PATH/scripts/prepare-meeting-tools.sh"
  if [[ ! -f "$BUILD_BIN" ]]; then
    echo "Missing build output: $BUILD_BIN" >&2
    exit 1
  fi
  cp "$BUILD_BIN" "$APP_BIN"
  # Copy app icon
  if [[ -f "$PROJECT_PATH/resources/AppIcon.icns" ]]; then
    cp "$PROJECT_PATH/resources/AppIcon.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"
  fi
  # Copy SwiftPM resource bundle (Characters, etc.)
  BUILD_BUNDLE="$PROJECT_PATH/.build/debug/ClawGate_ClawGate.bundle"
  if [[ -d "$BUILD_BUNDLE" ]]; then
    DEST_BUNDLE="$APP_PATH/Contents/Resources/ClawGate_ClawGate.bundle"
    rm -rf "$DEST_BUNDLE"
    cp -R "$BUILD_BUNDLE" "$DEST_BUNDLE"
  fi
  # Sync Chrome extension into app Resources so the bundled-path loader
  # stays in step with extensions/clawgate-chrome/ (dev path always wins
  # if Chrome is pointed there, but keeping the bundled copy current
  # avoids a stale version when someone reinstalls via Settings).
  EXT_SRC="$PROJECT_PATH/extensions/clawgate-chrome"
  EXT_DST="$APP_PATH/Contents/Resources/clawgate-chrome"
  if [[ -d "$EXT_SRC" ]]; then
    mkdir -p "$(dirname "$EXT_DST")"
    if command -v rsync >/dev/null 2>&1; then
      rsync -a --delete "$EXT_SRC/" "$EXT_DST/"
    else
      rm -rf "$EXT_DST"
      mkdir -p "$EXT_DST"
      cp -R "$EXT_SRC/." "$EXT_DST/"
    fi
  fi
else
  echo "[2/5] Skip app-binary sync (by option)"
fi

if [[ "$PLUGIN_CLIENT_ONLY" == "true" ]]; then
  echo "[3/5] Sync OpenClaw plugin client.js only"
  PLUGIN_CLIENT_TMP="$(mktemp "$PLUGIN_CLAWGATE_DST/src/.client.js.tmp.XXXXXX")"
  cp "$PLUGIN_CLIENT_SRC" "$PLUGIN_CLIENT_TMP"
  mv -f "$PLUGIN_CLIENT_TMP" "$PLUGIN_CLAWGATE_DST/src/client.js"
elif [[ "$SKIP_PLUGIN_SYNC" != "true" ]]; then
  echo "[3/5] Sync OpenClaw plugins"
  sync_plugin_dir() {
    local src="$1"
    local dst="$2"
    local label="$3"
    if [[ ! -d "$src" ]]; then
      echo "  - skip $label (missing source: $src)"
      return
    fi
    mkdir -p "$dst"
    if command -v rsync >/dev/null 2>&1; then
      rsync -a --delete "$src/" "$dst/"
    else
      rm -rf "$dst"
      mkdir -p "$dst"
      cp -R "$src/." "$dst/"
    fi
    echo "  - synced $label -> $dst"
  }
  sync_plugin_dir "$PLUGIN_CLAWGATE_SRC" "$PLUGIN_CLAWGATE_DST" "clawgate"
  # DISABLED: vibeterm-telemetry is a 4-route bundle managed by oc-general, not clawgate.
  # sync_plugin_dir "$PLUGIN_TELEMETRY_SRC" "$PLUGIN_TELEMETRY_DST" "vibeterm-telemetry"
else
  echo "[3/5] Skip OpenClaw plugin sync (by option)"
fi

if [[ "$SKIP_SIGN" != "true" ]]; then
  # Prefer Developer ID Application (stable TCC binding across rebuilds).
  # Fall back to self-signed "ClawGate Dev", then ad-hoc as last resort.
  if [[ -f "$PROJECT_PATH/.local/secrets/release.env" ]]; then
    # shellcheck disable=SC1091
    set -a; source "$PROJECT_PATH/.local/secrets/release.env"; set +a
  fi
  # Keep the real signing identity out of the public source tree: set SIGNING_ID
  # (preferred) or CLAWGATE_DEFAULT_DEVID in .local/secrets/release.env.
  DEFAULT_DEVID="${CLAWGATE_DEFAULT_DEVID:-}"
  RESOLVED_SIGNING_ID=""
  if [[ -n "${SIGNING_ID:-}" ]] && /usr/bin/security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGNING_ID"; then
    RESOLVED_SIGNING_ID="$SIGNING_ID"
  elif [[ -n "$DEFAULT_DEVID" ]] && /usr/bin/security find-identity -v -p codesigning 2>/dev/null | grep -qF "$DEFAULT_DEVID"; then
    RESOLVED_SIGNING_ID="$DEFAULT_DEVID"
  elif /usr/bin/security find-identity -v -p codesigning 2>/dev/null | grep -q "ClawGate Dev"; then
    RESOLVED_SIGNING_ID="ClawGate Dev"
  fi
  if [[ "$STAGE_ONLY" == "true" ]]; then
    [[ -n "$RESOLVED_SIGNING_ID" ]] || { echo "Staging requires the existing Developer ID identity." >&2; exit 1; }
    STAGE_IDENTITY="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null | grep -F "$RESOLVED_SIGNING_ID" | head -n 1)"
    [[ "$STAGE_IDENTITY" == *"Developer ID Application:"* && "$STAGE_IDENTITY" == *"($STAGE_TEAM)"* ]] || {
      echo "Staging requires a Developer ID identity from the original team." >&2; exit 1;
    }
  fi
  if [[ -n "$RESOLVED_SIGNING_ID" ]]; then
    echo "[4/5] Codesign ($RESOLVED_SIGNING_ID)"
    codesign --force --deep --options runtime \
      --identifier com.clawgate.app \
      --entitlements ClawGate.entitlements \
      --sign "$RESOLVED_SIGNING_ID" "$APP_PATH"
  else
    echo "[4/5] Codesign (ad-hoc, preserves TCC permissions)"
    codesign --force --deep \
      --identifier com.clawgate.app \
      --sign - "$APP_PATH"
  fi
else
  echo "[4/5] Skip codesign (by option)"
fi

if [[ "$STAGE_ONLY" == "true" ]]; then
  codesign --verify --deep --strict "$APP_PATH"
  VERIFIED_TEAM="$(codesign -dv --verbose=4 "$APP_PATH" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
  [[ "$VERIFIED_TEAM" == "$STAGE_TEAM" ]] || { echo "Staged signing team changed." >&2; exit 1; }
  echo "Staged app signed and verified; no process or Gateway operation performed."
  exit 0
fi

echo "[5/5] Restart app + local gateway"

STARTUP_LOG="$PROJECT_PATH/.local/logs/clawgate-startup.log"
mkdir -p "$(dirname "$STARTUP_LOG")"
touch "$STARTUP_LOG"
chmod 600 "$STARTUP_LOG"
open -na "$APP_PATH" --stdout "$STARTUP_LOG" --stderr "$STARTUP_LOG" --env NSUnbufferedIO=YES
sleep 2

GATEWAY_LABEL="ai.openclaw.gateway"

# PID column of the gateway's launchd job, or empty when it is not running.
gateway_job_pid() {
  launchctl list 2>/dev/null \
    | awk -v label="$GATEWAY_LABEL" '$3 == label && $1 != "-" { print $1 }'
}

if [[ "$SKIP_PLUGIN_SYNC" != "true" ]] && launchctl list 2>/dev/null | grep -q 'ai\.openclaw\.gateway'; then
  # Wait for the old instance to actually exit before starting a new one.
  # launchctl stop only sends SIGTERM and returns immediately; a gateway
  # holding many listeners does not always finish shutting down within a
  # second. Starting on top of it leaves the old process running with no
  # launchd job owning it, and those orphans accumulate one per restart,
  # each still holding its ports. Mirrors the app handling above.
  GATEWAY_OLD_PID="$(gateway_job_pid)"
  launchctl stop "$GATEWAY_LABEL" >/dev/null 2>&1 || true
  if [[ -n "$GATEWAY_OLD_PID" ]]; then
    for ((w=1; w<=5; w++)); do
      if ! kill -0 "$GATEWAY_OLD_PID" 2>/dev/null; then
        break
      fi
      if [[ $w -eq 5 ]]; then
        echo "Old gateway (pid $GATEWAY_OLD_PID) still alive after 5s, sending SIGKILL"
        kill -9 "$GATEWAY_OLD_PID" >/dev/null 2>&1 || true
        sleep 1
      fi
      sleep 1
    done
  else
    sleep 1
  fi
  launchctl start "$GATEWAY_LABEL" >/dev/null 2>&1 || true
  sleep 1
fi

echo "Process:"
ps aux | grep "$APP_BIN" | grep -v grep || true

echo "Binary marker:"
strings "$APP_BIN" | egrep -n "Apply Recommended|Refresh Hosts|Manual \\(select server\\)" | head -n 5 || true

echo "Health:"
for ((i=1; i<=WAIT_SECONDS; i++)); do
  if curl -fsS -m 2 http://127.0.0.1:8765/v1/health >/dev/null 2>&1; then
    curl -sS -m 2 http://127.0.0.1:8765/v1/health || true
    echo
    python3 "$SCRIPT_DIR/ambient-restart-state.py" restore "$AMBIENT_RESTART_STATE"
    ops_log info "restart_ok" "local health and ambient restoration succeeded"
    exit 0
  fi
  sleep 1
done
echo "health check timeout (${WAIT_SECONDS}s)" >&2
ops_log error "restart_timeout" "local health check timeout (${WAIT_SECONDS}s)"
exit 1
