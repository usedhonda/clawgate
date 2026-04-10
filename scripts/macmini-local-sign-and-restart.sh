#!/usr/bin/env bash
set -euo pipefail

# Run this script ON macmini local login session (not via SSH) to fix signing and restart.
#
# Usage:
#   KEYCHAIN_PASSWORD='your-login-password' ./scripts/macmini-local-sign-and-restart.sh
#   ./scripts/macmini-local-sign-and-restart.sh --keychain-password 'your-login-password'

SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
PROJECT_PATH="${PROJECT_PATH:-$(cd "$SCRIPT_DIR/.." && pwd)}"
KEYCHAIN_PASSWORD="${KEYCHAIN_PASSWORD:-}"

# Pull in SIGNING_ID from release.env if present. Preferred signing identity
# is Developer ID Application (stable TCC binding across rebuilds via Team ID).
# Legacy self-signed "ClawGate Dev" is kept as a fallback for older macmini
# setups that were never migrated.
if [[ -f "$PROJECT_PATH/.local/secrets/release.env" ]]; then
  # shellcheck disable=SC1091
  set -a; source "$PROJECT_PATH/.local/secrets/release.env"; set +a
fi
DEFAULT_DEVID="Developer ID Application: Yuzuru Honda (F588423ZWS)"
PREFERRED_SIGNING_ID="${SIGNING_ID:-$DEFAULT_DEVID}"
LEGACY_CERT_NAME="ClawGate Dev"

# Candidate keychains that may hold a usable signing identity. Order matters:
# the primary login keychain is preferred (Developer ID lives there after the
# 2026-04-10 migration); login_renamed_1 is kept as a fallback because the
# legacy ClawGate Dev self-signed cert still lives there.
KEYCHAIN_CANDIDATES=(
  "$HOME/Library/Keychains/login.keychain-db"
  "$HOME/Library/Keychains/login_renamed_1.keychain-db"
)

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

echo "[1/6] Locate signing keychain"
SIGNING_KEYCHAIN=""
RESOLVED_SIGNING_ID=""
# Unlock every candidate keychain so find-identity can see it, and prefer
# the Developer ID identity. Fall back to the legacy self-signed cert.
for kc in "${KEYCHAIN_CANDIDATES[@]}"; do
  [[ -f "$kc" ]] || continue
  security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$kc" >/dev/null 2>&1 || {
    echo "  - unlock failed: $kc" >&2
    continue
  }
done
for kc in "${KEYCHAIN_CANDIDATES[@]}"; do
  [[ -f "$kc" ]] || continue
  if security find-identity -v -p codesigning "$kc" 2>/dev/null | grep -qF "$PREFERRED_SIGNING_ID"; then
    SIGNING_KEYCHAIN="$kc"
    RESOLVED_SIGNING_ID="$PREFERRED_SIGNING_ID"
    echo "  - Developer ID identity found in: $kc"
    break
  fi
done
if [[ -z "$SIGNING_KEYCHAIN" ]]; then
  for kc in "${KEYCHAIN_CANDIDATES[@]}"; do
    [[ -f "$kc" ]] || continue
    if security find-identity -v -p codesigning "$kc" 2>/dev/null | grep -q "$LEGACY_CERT_NAME"; then
      SIGNING_KEYCHAIN="$kc"
      RESOLVED_SIGNING_ID="$LEGACY_CERT_NAME"
      echo "  - legacy '$LEGACY_CERT_NAME' identity found in: $kc"
      break
    fi
  done
fi
if [[ -z "$SIGNING_KEYCHAIN" ]]; then
  echo "ERROR: no usable signing identity found." >&2
  echo "  Wanted: '$PREFERRED_SIGNING_ID' (preferred) or '$LEGACY_CERT_NAME' (fallback)" >&2
  echo "  Checked:" >&2
  printf '    - %s\n' "${KEYCHAIN_CANDIDATES[@]}" >&2
  exit 1
fi

echo "[2/6] Ensure signing keychain is in the search list (cleans stale /tmp entries)"
security list-keychains -d user -s \
  "$SIGNING_KEYCHAIN" \
  "$HOME/Library/Keychains/login.keychain-db" \
  /Library/Keychains/System.keychain >/dev/null

echo "[3/6] Configure key partition list on signing keychain"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$SIGNING_KEYCHAIN" >/dev/null

echo "[4/6] Build"
swift build
cp .build/debug/ClawGate ClawGate.app/Contents/MacOS/ClawGate
# Copy app icon
if [[ -f "$PROJECT_PATH/resources/AppIcon.icns" ]]; then
  cp "$PROJECT_PATH/resources/AppIcon.icns" ClawGate.app/Contents/Resources/AppIcon.icns
fi
# Copy SwiftPM resource bundle (Characters, menubar-claw.png, etc.)
# memory/MEMORY.md L155: "deploy 時は .build/debug/ClawGate_ClawGate.bundle を
# ClawGate.app/Contents/Resources/ にコピー必須"
BUILD_BUNDLE="$PROJECT_PATH/.build/debug/ClawGate_ClawGate.bundle"
if [[ -d "$BUILD_BUNDLE" ]]; then
  DEST_BUNDLE="ClawGate.app/Contents/Resources/ClawGate_ClawGate.bundle"
  rm -rf "$DEST_BUNDLE"
  cp -R "$BUILD_BUNDLE" "$DEST_BUNDLE"
fi

echo "[5/6] Sign with $RESOLVED_SIGNING_ID (keychain: $SIGNING_KEYCHAIN)"
codesign --force --deep --options runtime \
  --identifier com.clawgate.app \
  --entitlements ClawGate.entitlements \
  --keychain "$SIGNING_KEYCHAIN" \
  --sign "$RESOLVED_SIGNING_ID" ClawGate.app

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
