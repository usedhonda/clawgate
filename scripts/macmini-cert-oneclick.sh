#!/usr/bin/env bash
set -euo pipefail

# One-click recovery for Host A (macmini) certificate/trust/sign/restart flow.
# Run this on macmini local login session.

PROJECT_PATH="/Users/usedhonda/projects/ios/clawgate"
KEYCHAIN_PASSWORD="${KEYCHAIN_PASSWORD:-REDACTED}"
CERT_NAME="ClawGate Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "ERROR: macOS only" >&2
  exit 1
fi

cd "$PROJECT_PATH"

echo "[1/7] Reset and recreate certificate"
./scripts/setup-cert.sh --reset --non-interactive --keychain-password "$KEYCHAIN_PASSWORD" || true

echo "[2/7] Open required GUI panes"
open -a "Keychain Access" || true
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" || true
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture" || true
open "$PROJECT_PATH/ClawGate.app" || true

echo
echo "Manual steps (once):"
echo "  1) Keychain Access -> '$CERT_NAME' -> Trust -> Code Signing = Always Trust"
echo "  2) Privacy > Accessibility -> ClawGate ON"
echo "  3) Privacy > Screen Recording -> ClawGate ON"
read -r -p "Press Enter after completing the GUI steps... " _

echo "[3/7] Verify identity"
security find-identity -v -p codesigning | grep "$CERT_NAME"

echo "[4/7] Local sign and restart"
KEYCHAIN_PASSWORD="$KEYCHAIN_PASSWORD" ./scripts/macmini-local-sign-and-restart.sh --keychain-password "$KEYCHAIN_PASSWORD"

echo "[5/7] Restart OpenClaw gateway"
launchctl stop ai.openclaw.gateway >/dev/null 2>&1 || true
sleep 1
launchctl start ai.openclaw.gateway >/dev/null 2>&1 || true
sleep 2

echo "[6/7] Health"
curl -fsS -m 5 http://127.0.0.1:8765/v1/health

echo "[7/7] Doctor"
curl -sS -m 5 http://127.0.0.1:8765/v1/doctor

echo "Done."
