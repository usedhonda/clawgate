#!/bin/bash
# Provision the clawgate-diarizer helper binary (speaker diarization for the
# Ambient Context Stream). Mirrors the whisper-cli provisioning pattern:
# build out-of-app, install under Application Support, sign with the
# canonical Developer ID, pre-download models, smoke-check.
#
# The helper requires macOS 14+/Apple Silicon; the main app does not depend
# on it (absent helper = speaker labels off).
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
PKG_DIR="$REPO_ROOT/tools/diarizer"
DEST_ROOT="$HOME/Library/Application Support/ClawGate/diarizer"
DEST_BIN="$DEST_ROOT/bin/clawgate-diarizer"

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "skip: diarizer requires Apple Silicon (this host: $(uname -m))"
  exit 0
fi

echo "[1/4] Build (release)"
cd "$PKG_DIR"
swift build -c release
BUILT="$PKG_DIR/.build/release/clawgate-diarizer"
[[ -x "$BUILT" ]] || { echo "build product missing: $BUILT" >&2; exit 1; }

echo "[2/4] Install"
mkdir -p "$DEST_ROOT/bin"
cp -f "$BUILT" "$DEST_BIN"

echo "[3/4] Codesign"
SIGNING_ID=""
if [[ -f "$REPO_ROOT/.local/secrets/release.env" ]]; then
  # shellcheck disable=SC1091
  source "$REPO_ROOT/.local/secrets/release.env"
fi
if [[ -n "${SIGNING_ID:-}" ]]; then
  codesign --force --options runtime --sign "$SIGNING_ID" "$DEST_BIN"
  codesign --verify "$DEST_BIN" && echo "signed: $SIGNING_ID"
else
  echo "warn: SIGNING_ID not found; leaving build signature as-is"
fi

echo "[4/4] Warmup (model download) + smoke check"
"$DEST_BIN" --help
"$DEST_BIN" warmup
echo "diarizer provisioned: $DEST_BIN"
