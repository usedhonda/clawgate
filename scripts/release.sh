#!/usr/bin/env bash
# ClawGate Release Script
#
# Usage:
#   ./scripts/release.sh
#   ./scripts/release.sh --publish --notes-file docs/release/release-notes.md
#
# Required env vars:
#   APPLE_ID
#   APPLE_TEAM_ID
#   APPLE_ID_PASSWORD
#   SIGNING_ID

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="ClawGate"
APP_BUNDLE="${PROJECT_DIR}/${APP_NAME}.app"
APP_BINARY="${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
ENTITLEMENTS_PATH="${PROJECT_DIR}/${APP_NAME}.entitlements"
DEFAULT_RELEASE_ROOT="/tmp/clawgate-release"
RELEASE_ROOT="${RELEASE_ROOT:-$DEFAULT_RELEASE_ROOT}"

PUBLISH=false
RELEASE_NOTES_FILE="${RELEASE_NOTES_FILE:-docs/release/release-notes.md}"

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/release.sh
  ./scripts/release.sh --publish --notes-file docs/release/release-notes.md

Options:
  --publish                Create GitHub release after successful notarization
  --notes-file <path>      Markdown release notes file (required for --publish)
  -h, --help               Show this help

Required environment variables:
  APPLE_ID
  APPLE_TEAM_ID
  APPLE_ID_PASSWORD
  SIGNING_ID
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --publish)
      PUBLISH=true
      shift
      ;;
    --notes-file)
      if [[ $# -lt 2 ]]; then
        echo -e "${RED}Error: --notes-file requires a path${NC}" >&2
        exit 1
      fi
      RELEASE_NOTES_FILE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo -e "${RED}Error: Unknown argument: $1${NC}" >&2
      usage
      exit 1
      ;;
  esac
done

require_command() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo -e "${RED}Error: required command not found: $cmd${NC}" >&2
    exit 1
  fi
}

require_env() {
  local key="$1"
  if [[ -z "${!key:-}" ]]; then
    echo -e "${RED}Error: required env var missing: $key${NC}" >&2
    exit 1
  fi
}

validate_release_notes() {
  local notes_file="$1"
  local sections=(
    "## Summary"
    "## Breaking Changes"
    "## Permissions / Re-auth"
    "## Known Issues"
    "## Rollback"
    "## Support"
  )

  if [[ ! -f "$notes_file" ]]; then
    echo -e "${RED}Error: release notes not found: $notes_file${NC}" >&2
    echo "Hint: cp docs/release/release-notes-template.md docs/release/release-notes.md" >&2
    exit 1
  fi

  for section in "${sections[@]}"; do
    if ! grep -Fq "$section" "$notes_file"; then
      echo -e "${RED}Error: release notes missing section: $section${NC}" >&2
      exit 1
    fi
  done

  if grep -Fq "REPLACE_BEFORE_RELEASE" "$notes_file"; then
    echo -e "${RED}Error: release notes still contain placeholder token REPLACE_BEFORE_RELEASE${NC}" >&2
    exit 1
  fi
}

require_clean_worktree() {
  if [[ -n "$(git status --porcelain)" ]]; then
    echo -e "${RED}Error: git worktree is dirty. Commit or stash before --publish.${NC}" >&2
    git status --short >&2
    exit 1
  fi
}

cd "$PROJECT_DIR"

require_command swift
require_command xcrun
require_command codesign
require_command hdiutil
require_command plutil
require_command shasum
require_command python3
require_command lipo
if [[ "$PUBLISH" == "true" ]]; then
  require_command gh
fi

require_env APPLE_ID
require_env APPLE_TEAM_ID
require_env APPLE_ID_PASSWORD
require_env SIGNING_ID

if [[ "$PUBLISH" == "true" ]]; then
  validate_release_notes "$RELEASE_NOTES_FILE"
  require_clean_worktree
fi

BUILD_STAMP="$(date +%Y%m%d-%H%M%S)"
WORK_DIR="${RELEASE_ROOT}/${BUILD_STAMP}"
DMG_PATH="${WORK_DIR}/${APP_NAME}.dmg"
DMG_STAGING="${WORK_DIR}/dmg-contents"
DMG_MOUNT="${WORK_DIR}/dmg-mount"
NOTARY_JSON="${WORK_DIR}/notary-submit.json"
MANIFEST_PATH="${WORK_DIR}/${APP_NAME}-release-manifest.json"
ENTITLEMENTS_EXTRACT="${WORK_DIR}/entitlements.plist"

mkdir -p "$WORK_DIR"

VERSION="$(plutil -extract CFBundleShortVersionString raw "${APP_BUNDLE}/Contents/Info.plist")"
GIT_SHA="$(git rev-parse HEAD)"
GIT_REF="$(git rev-parse --abbrev-ref HEAD)"

echo -e "${GREEN}=== ClawGate Release ===${NC}"
echo "Version: ${YELLOW}${VERSION}${NC}"
echo "Git SHA: ${YELLOW}${GIT_SHA}${NC}"
echo "Artifacts: ${YELLOW}${WORK_DIR}${NC}"
echo

echo -e "${GREEN}[1/9] Running tests...${NC}"
swift test --quiet
echo -e "${GREEN}Tests passed${NC}"
echo

echo -e "${GREEN}[2/9] Building release (universal)...${NC}"
swift build -c release --arch arm64 --arch x86_64 --quiet
echo -e "${GREEN}Build complete${NC}"
echo

echo -e "${GREEN}[3/9] Updating app bundle...${NC}"
cp ".build/apple/Products/Release/${APP_NAME}" "$APP_BINARY"
if [[ -f "$PROJECT_DIR/resources/AppIcon.icns" ]]; then
  cp "$PROJECT_DIR/resources/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
fi
if [[ -f "$PROJECT_DIR/resources/PrivacyInfo.xcprivacy" ]]; then
  cp "$PROJECT_DIR/resources/PrivacyInfo.xcprivacy" "${APP_BUNDLE}/Contents/Resources/PrivacyInfo.xcprivacy"
fi
APP_ARCHS="$(lipo -archs "$APP_BINARY")"
echo "Binary arch: ${APP_ARCHS}"
echo -e "${GREEN}App bundle updated${NC}"
echo

echo -e "${GREEN}[4/9] Signing and verifying app...${NC}"
codesign --force --deep --options runtime \
  --identifier com.clawgate.app \
  --entitlements "$ENTITLEMENTS_PATH" \
  --sign "$SIGNING_ID" \
  "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
SIGN_AUTHORITY="$(codesign -dv --verbose=4 "$APP_BUNDLE" 2>&1 | awk -F= '/^Authority=/{print $2; exit}')"
if [[ -z "$SIGN_AUTHORITY" ]]; then
  SIGN_AUTHORITY="$SIGNING_ID"
fi
codesign -d --entitlements :- "$APP_BUNDLE" > "$ENTITLEMENTS_EXTRACT" 2>/dev/null || cp "$ENTITLEMENTS_PATH" "$ENTITLEMENTS_EXTRACT"
APP_SHA256="$(shasum -a 256 "$APP_BINARY" | awk '{print $1}')"
ENTITLEMENTS_SHA256="$(shasum -a 256 "$ENTITLEMENTS_EXTRACT" | awk '{print $1}')"
echo -e "${GREEN}App signing verified${NC}"
echo

echo -e "${GREEN}[5/9] Creating and verifying DMG...${NC}"
rm -rf "$DMG_STAGING" "$DMG_MOUNT"
mkdir -p "$DMG_STAGING" "$DMG_MOUNT"
cp -R "$APP_BUNDLE" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGING" -ov -format UDZO "$DMG_PATH" >/dev/null
codesign --force --sign "$SIGNING_ID" "$DMG_PATH"
codesign --verify --verbose=2 "$DMG_PATH"

hdiutil attach "$DMG_PATH" -readonly -nobrowse -mountpoint "$DMG_MOUNT" >/dev/null
DMG_APP_BINARY="${DMG_MOUNT}/${APP_NAME}.app/Contents/MacOS/${APP_NAME}"
if [[ ! -f "$DMG_APP_BINARY" ]]; then
  echo -e "${RED}Error: DMG payload missing app binary: $DMG_APP_BINARY${NC}" >&2
  hdiutil detach "$DMG_MOUNT" -quiet >/dev/null 2>&1 || true
  exit 1
fi
DMG_APP_SHA256="$(shasum -a 256 "$DMG_APP_BINARY" | awk '{print $1}')"
hdiutil detach "$DMG_MOUNT" -quiet >/dev/null

if [[ "$APP_SHA256" != "$DMG_APP_SHA256" ]]; then
  echo -e "${RED}Error: DMG payload mismatch. Tested app and packaged app differ.${NC}" >&2
  echo "App SHA256: $APP_SHA256" >&2
  echo "DMG SHA256: $DMG_APP_SHA256" >&2
  exit 1
fi

echo -e "${GREEN}DMG payload matches app bundle${NC}"
echo

echo -e "${GREEN}[6/9] Submitting DMG to notarization...${NC}"
xcrun notarytool submit "$DMG_PATH" \
  --apple-id "$APPLE_ID" \
  --team-id "$APPLE_TEAM_ID" \
  --password "$APPLE_ID_PASSWORD" \
  --wait \
  --output-format json > "$NOTARY_JSON"

read -r NOTARY_ID NOTARY_STATUS < <(python3 - "$NOTARY_JSON" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, 'r', encoding='utf-8') as f:
    data = json.load(f)
print(data.get('id', ''), data.get('status', ''))
PY
)

if [[ -z "$NOTARY_ID" || -z "$NOTARY_STATUS" ]]; then
  echo -e "${RED}Error: failed to parse notarization response: $NOTARY_JSON${NC}" >&2
  exit 1
fi

if [[ "$NOTARY_STATUS" != "Accepted" ]]; then
  echo -e "${RED}Error: notarization status is $NOTARY_STATUS (expected Accepted).${NC}" >&2
  echo "See: $NOTARY_JSON" >&2
  exit 1
fi

echo "Notary submission ID: $NOTARY_ID"
echo -e "${GREEN}Notarization accepted${NC}"
echo

echo -e "${GREEN}[7/9] Stapling and Gatekeeper assess...${NC}"
xcrun stapler staple "$DMG_PATH"
spctl --assess --verbose=4 --type install "$DMG_PATH"
echo -e "${GREEN}Staple + spctl assess passed${NC}"
echo

echo -e "${GREEN}[8/9] Writing release manifest...${NC}"
DMG_SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
CREATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
export APP_NAME VERSION APP_BUNDLE APP_ARCHS APP_SHA256 SIGN_AUTHORITY
export ENTITLEMENTS_SHA256 DMG_PATH DMG_SHA256 NOTARY_ID NOTARY_STATUS NOTARY_JSON
export GIT_SHA GIT_REF CREATED_AT

python3 - "$MANIFEST_PATH" <<'PY'
import json
import os
import sys

manifest_path = sys.argv[1]
manifest = {
    "app": {
        "name": os.environ["APP_NAME"],
        "version": os.environ["VERSION"],
        "bundle": os.environ["APP_BUNDLE"],
        "binary_arch": os.environ["APP_ARCHS"],
        "binary_sha256": os.environ["APP_SHA256"],
        "signing_authority": os.environ["SIGN_AUTHORITY"],
        "entitlements_sha256": os.environ["ENTITLEMENTS_SHA256"],
    },
    "dmg": {
        "path": os.environ["DMG_PATH"],
        "sha256": os.environ["DMG_SHA256"],
    },
    "notarization": {
        "submission_id": os.environ["NOTARY_ID"],
        "status": os.environ["NOTARY_STATUS"],
        "result_json": os.environ["NOTARY_JSON"],
    },
    "source": {
        "git_sha": os.environ["GIT_SHA"],
        "git_ref": os.environ["GIT_REF"],
    },
    "created_at": os.environ["CREATED_AT"],
}
with open(manifest_path, "w", encoding="utf-8") as f:
    json.dump(manifest, f, indent=2)
    f.write("\n")
PY

echo "Manifest: $MANIFEST_PATH"
echo -e "${GREEN}Manifest created${NC}"
echo

if [[ "$PUBLISH" == "true" ]]; then
  echo -e "${GREEN}[9/9] Publishing GitHub release...${NC}"
  if git rev-parse "v${VERSION}" >/dev/null 2>&1; then
    echo -e "${RED}Error: tag v${VERSION} already exists${NC}" >&2
    exit 1
  fi

  gh release create "v${VERSION}" \
    "$DMG_PATH" \
    "$MANIFEST_PATH" \
    --title "v${VERSION}" \
    --notes-file "$RELEASE_NOTES_FILE"

  echo -e "${GREEN}Published release: v${VERSION}${NC}"
else
  echo -e "${GREEN}[9/9] Publish skipped${NC}"
  echo "To publish:"
  echo "  ./scripts/release.sh --publish --notes-file ${RELEASE_NOTES_FILE}"
fi

echo
echo -e "${GREEN}=== Release Complete ===${NC}"
echo "Artifacts:"
echo "  DMG:      $DMG_PATH"
echo "  Notary:   $NOTARY_JSON"
echo "  Manifest: $MANIFEST_PATH"
