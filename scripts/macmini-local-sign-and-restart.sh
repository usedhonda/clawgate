#!/usr/bin/env bash
set -euo pipefail

# Run this script ON macmini local login session (not via SSH) to fix signing and restart.
#
# Usage:
#   KEYCHAIN_PASSWORD='your-login-password' ./scripts/macmini-local-sign-and-restart.sh
#   ./scripts/macmini-local-sign-and-restart.sh --keychain-password 'your-login-password'

PROJECT_PATH="/Users/usedhonda/projects/ios/clawgate"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
KEYCHAIN_PASSWORD="${KEYCHAIN_PASSWORD:-}"
CERT_NAME="ClawGate Dev"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-path)
      PROJECT_PATH="$2"; shift 2 ;;
    --keychain-password)
      KEYCHAIN_PASSWORD="$2"; shift 2 ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 2 ;;
  esac
done

if [[ -z "$KEYCHAIN_PASSWORD" ]]; then
  echo "KEYCHAIN_PASSWORD is required." >&2
  exit 1
fi

cd "$PROJECT_PATH"

echo "[1/6] Verify signing identity"
security find-identity -v -p codesigning | grep "$CERT_NAME" >/dev/null

echo "[2/6] Unlock keychain"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"

echo "[3/6] Configure key partition list"
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null

echo "[4/6] Build"
swift build
cp .build/debug/ClawGate ClawGate.app/Contents/MacOS/ClawGate
# Copy app icon
if [[ -f "$PROJECT_PATH/resources/AppIcon.icns" ]]; then
  cp "$PROJECT_PATH/resources/AppIcon.icns" ClawGate.app/Contents/Resources/AppIcon.icns
fi

echo "[5/6] Sign with $CERT_NAME"
codesign --force --deep --options runtime \
  --identifier com.clawgate.app \
  --entitlements ClawGate.entitlements \
  --sign "$CERT_NAME" ClawGate.app

echo "[6/6] Restart ClawGate + OpenClaw gateway"
./scripts/restart-local-clawgate.sh --skip-build --skip-sync --skip-sign
sleep 2
launchctl stop ai.openclaw.gateway >/dev/null 2>&1 || true
sleep 1
launchctl start ai.openclaw.gateway >/dev/null 2>&1 || true
sleep 2

mkdir -p "$PROJECT_PATH/.runtime"
STAMP_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
STAMP_COMMIT="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
cat > "$PROJECT_PATH/.runtime/hosta-local-sign.stamp" <<STAMP

ts=$STAMP_TS
commit=$STAMP_COMMIT
host=$(hostname)
STAMP

echo "Health:"
curl -sS -m 5 http://127.0.0.1:8765/v1/health
echo
echo "Doctor:"
curl -sS -m 5 http://127.0.0.1:8765/v1/doctor
echo
echo "Done."
