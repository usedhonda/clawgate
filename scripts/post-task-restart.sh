#!/usr/bin/env bash
set -euo pipefail

# Canonical post-task restart/verification.
# Run this at the end of implementation tasks without waiting for manual confirmation.
#
# Steps:
#   1) (optional) Sync repo to Host A (macmini)
#   2) Restart Host A ClawGate + OpenClaw Gateway via SSH (no build/codesign here)
#   3) Restart Host B ClawGate locally
#   4) Verify health, gateway, LINE conversation
#
# By default Host A build/codesign is NOT performed here (restart-only). Pass
# --build-hosta to build + codesign + restart Host A via SSH using the canonical
# macmini-local-sign-and-restart.sh with an explicit keychain unlock (verified
# working over SSH — see memory/deployment.md §2). Without --build-hosta a fresh
# Swift binary will NOT reach macmini; only source is synced and the existing
# bundle is restarted.
#   ./scripts/post-task-restart.sh --build-hosta

REMOTE_HOST="macmini"
SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
PROJECT_PATH="${PROJECT_PATH:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SKIP_SYNC=false
REQUIRE_HOSTA_LOCAL_SIGN=false
BUILD_HOSTA=false
CLAWGATE_ROLE="host_b_client"
OPS_SCRIPT_NAME="post-task-restart.sh"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote-host)
      REMOTE_HOST="$2"; shift 2 ;;
    --project-path)
      PROJECT_PATH="$2"; shift 2 ;;
    --skip-sync)
      SKIP_SYNC=true; shift ;;
    --skip-remote-build)
      shift ;;  # deprecated: remote build path was removed (kept for backward compat)
    --skip-local-relay)
      shift ;;  # deprecated: relay removed (kept for backward compat)
    --require-hosta-local-sign)
      REQUIRE_HOSTA_LOCAL_SIGN=true; shift ;;
    --build-hosta)
      BUILD_HOSTA=true; shift ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 2 ;;
  esac
done

cd "$PROJECT_PATH"

ambient_status_json() {
  curl -fsS -m 5 http://127.0.0.1:8765/v1/ambient/status 2>/dev/null || true
}

ambient_extract_field() {
  local field="$1"
  python3 -c 'import json, sys
field = sys.argv[1]
try:
    data = json.load(sys.stdin)
    result = data.get("result") or {}
    value = result.get(field, None)
    if value is None:
        print("")
    elif isinstance(value, bool):
        print("true" if value else "false")
    else:
        print(value)
except Exception:
    print("")
' "$field"
}

ambient_response_ok() {
  python3 -c 'import json, sys
try:
    data = json.load(sys.stdin)
    print("true" if data.get("ok") is True else "false")
except Exception:
    print("false")
'
}

ambient_verify_chunks_after_restart() {
  echo "[verify] Host B ambient capture liveness"
  local status start_result before after liveness streaming
  status="$(ambient_status_json)"
  if [[ -z "$status" ]]; then
    echo "WARN: ambient status unavailable, skipping ambient verify" >&2
    return 0
  fi
  if [[ "$(printf '%s' "$status" | ambient_extract_field available)" != "true" ]]; then
    echo "skip (ambient unavailable on this host)"
    return 0
  fi

  start_result="$(curl -fsS -m 30 -X POST http://127.0.0.1:8765/v1/ambient/stream/start 2>/dev/null || true)"
  if [[ -z "$start_result" ]]; then
    echo "FAIL: ambient stream start returned empty response" >&2
    return 1
  fi
  if [[ "$(printf '%s' "$start_result" | ambient_response_ok)" != "true" ]]; then
    echo "FAIL: ambient stream start failed: $start_result" >&2
    return 1
  fi

  before="$(printf '%s' "$start_result" | ambient_extract_field chunksSurfaced)"
  [[ "$before" =~ ^-?[0-9]+$ ]] || before="$(printf '%s' "$start_result" | ambient_extract_field chunks_surfaced)"
  [[ "$before" =~ ^-?[0-9]+$ ]] || before=0
  liveness="$(printf '%s' "$start_result" | ambient_extract_field captureLiveness)"
  streaming="$(printf '%s' "$start_result" | ambient_extract_field streaming)"
  echo "ambient start ok (streaming=$streaming liveness=${liveness:-unknown} chunksSurfaced=$before)"

  sleep 35
  status="$(ambient_status_json)"
  after="$(printf '%s' "$status" | ambient_extract_field chunksSurfaced)"
  [[ "$after" =~ ^-?[0-9]+$ ]] || after="$(printf '%s' "$status" | ambient_extract_field chunks_surfaced)"
  [[ "$after" =~ ^-?[0-9]+$ ]] || after=0
  liveness="$(printf '%s' "$status" | ambient_extract_field captureLiveness)"
  if (( after > before )); then
    echo "ok (chunksSurfaced $before -> $after, liveness=${liveness:-unknown})"
    return 0
  fi

  echo "FAIL: ambient chunksSurfaced did not increase after restart ($before -> $after, liveness=${liveness:-unknown}); attempting one hard recover" >&2
  curl -fsS -m 30 -X POST http://127.0.0.1:8765/v1/ambient/capture/recover >/dev/null 2>&1 || true
  sleep 35
  status="$(ambient_status_json)"
  after="$(printf '%s' "$status" | ambient_extract_field chunksSurfaced)"
  [[ "$after" =~ ^-?[0-9]+$ ]] || after="$(printf '%s' "$status" | ambient_extract_field chunks_surfaced)"
  [[ "$after" =~ ^-?[0-9]+$ ]] || after=0
  liveness="$(printf '%s' "$status" | ambient_extract_field captureLiveness)"
  if (( after > before )); then
    echo "ok after recover (chunksSurfaced $before -> $after, liveness=${liveness:-unknown})"
    return 0
  fi
  echo "FAIL: ambient capture did not surface chunks after recover ($before -> $after, liveness=${liveness:-unknown})" >&2
  return 1
}

source "$PROJECT_PATH/scripts/lib-ops-log.sh"
ops_log info "post_task_begin" "post-task restart begin (remote_host=$REMOTE_HOST skip_sync=$SKIP_SYNC)"
trap 'ops_log error "post_task_failed" "post-task restart failed (line=$LINENO exit=$?)"' ERR

echo "== post-task-restart =="
echo "Remote host : $REMOTE_HOST"
echo "Project path: $PROJECT_PATH"
echo "Skip sync   : $SKIP_SYNC"
echo "Require HostA local sign: $REQUIRE_HOSTA_LOCAL_SIGN"
echo "Build HostA (SSH sign)  : $BUILD_HOSTA"

# Keep federation token aligned if explicitly provided in environment.
if [[ -n "${FEDERATION_TOKEN:-}" ]]; then
  ssh "$REMOTE_HOST" "defaults write com.clawgate.app clawgate.federationToken -string '$FEDERATION_TOKEN' || true; defaults write ClawGate clawgate.federationToken -string '$FEDERATION_TOKEN' || true" >/dev/null 2>&1 || true
fi

if [[ "$SKIP_SYNC" != "true" ]]; then
  ./scripts/sync-same-path-to-macmini.sh --remote-host "$REMOTE_HOST"
fi

if [[ "$BUILD_HOSTA" == "true" ]]; then
  # Host A build + codesign + restart via the canonical macmini-local-sign path,
  # invoked over SSH with an explicit keychain unlock (the script unlocks the
  # keychain itself, which is what makes SSH codesign reliable — deployment.md §2).
  # This is the only path that lands a fresh Swift binary on macmini, and it
  # writes .runtime/hosta-local-sign.stamp so the verify step below can confirm.
  echo "[hostA] build + codesign + restart via macmini-local-sign-and-restart.sh (SSH)"
  if ! ssh "$REMOTE_HOST" "KEYCHAIN_PASSWORD=\"\$(cat \"\$HOME/.local/secrets/keychain-password\")\" \"$PROJECT_PATH/scripts/macmini-local-sign-and-restart.sh\" --project-path \"$PROJECT_PATH\""; then
    echo
    echo "[fallback] Host A build/sign over SSH failed. Run on macmini local desktop session:"
    echo "  KEYCHAIN_PASSWORD='***' ./scripts/macmini-local-sign-and-restart.sh --project-path $PROJECT_PATH"
    exit 1
  fi
else
  # Host A restart (no build/codesign — see header).
  if ! ./scripts/restart-macmini-openclaw.sh \
      --remote-host "$REMOTE_HOST" \
      --project-path "$PROJECT_PATH" \
      --skip-build; then
    echo
    echo "[fallback] Host A signing/restart may require local desktop session on macmini."
    echo "[fallback] Run on macmini:"
    echo "  KEYCHAIN_PASSWORD='***' ./scripts/macmini-local-sign-and-restart.sh --project-path $PROJECT_PATH"
    echo "[fallback] Then rerun:"
    echo "  ./scripts/post-task-restart.sh --remote-host $REMOTE_HOST --project-path $PROJECT_PATH --skip-sync"
    exit 1
  fi
fi

# Host B restart (canonical local path).
echo "[local] Restart Host B ClawGate.app"
./scripts/restart-local-clawgate.sh

echo
echo "[verify] Host B health"
curl -fsS -m 3 http://127.0.0.1:8765/v1/health >/dev/null
echo "ok"

ambient_verify_chunks_after_restart

echo "[verify] Host A health"
ssh "$REMOTE_HOST" "curl -fsS -m 3 http://127.0.0.1:8765/v1/health >/dev/null"
echo "ok"

echo "[verify] Host A gateway"
ssh "$REMOTE_HOST" "launchctl list | grep ai.openclaw.gateway >/dev/null"
echo "ok"

echo "[verify] Host A LINE conversation"
LINE_CONV=$(ssh "$REMOTE_HOST" "curl -fsS -m 3 http://127.0.0.1:8765/v1/config 2>/dev/null" | python3 -c "import sys,json; print(json.load(sys.stdin).get('result',{}).get('line',{}).get('default_conversation',''))" 2>/dev/null || true)
if [[ -n "$LINE_CONV" ]]; then
  ENSURE_RESULT=$(ssh "$REMOTE_HOST" "curl -fsS -m 10 -X POST http://127.0.0.1:8765/v1/line/ensure-conversation -H 'Content-Type: application/json' -d '{\"conversation\":\"$LINE_CONV\"}'" 2>/dev/null || true)
  ENSURE_OK=$(echo "$ENSURE_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('ok',False))" 2>/dev/null || echo "False")
  if [[ "$ENSURE_OK" == "True" ]]; then
    echo "ok (navigated to '$LINE_CONV')"
  else
    echo "WARN: LINE conversation navigation failed: $ENSURE_RESULT" >&2
  fi
else
  echo "WARN: defaultConversation not configured, skipping LINE nav" >&2
fi

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
ops_log info "post_task_ok" "post-task restart finished"
