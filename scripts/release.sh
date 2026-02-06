#!/bin/bash
# ClawGate Release Script
#
# Usage:
#   ./scripts/release.sh          # Build and notarize only
#   ./scripts/release.sh --publish # Build, notarize, and create GitHub release
#
# Prerequisites:
#   - Xcode Command Line Tools
#   - Developer ID certificate
#   - gh CLI (for GitHub release)

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="ClawGate"
DMG_PATH="/tmp/${APP_NAME}.dmg"
DMG_STAGING="/tmp/dmg-contents"

# Apple credentials (from .local/release.md or environment)
APPLE_ID="${APPLE_ID:-honda@ofinventi.one}"
TEAM_ID="${TEAM_ID:-F588423ZWS}"
APP_PASSWORD="${APP_PASSWORD:-}"
SIGNING_ID="Developer ID Application: Yuzuru Honda (${TEAM_ID})"

cd "$PROJECT_DIR"

echo -e "${GREEN}=== ClawGate Release ===${NC}"
echo ""

# Check for app password
if [[ -z "$APP_PASSWORD" ]]; then
  if [[ -f ".local/release.md" ]]; then
    # Try to extract from .local/release.md (expects line: APP_PASSWORD=xxxx-xxxx-xxxx-xxxx)
    APP_PASSWORD=$(grep -E "^APP_PASSWORD=" .local/release.md 2>/dev/null | cut -d= -f2 | tr -d ' ' || true)
  fi
  if [[ -z "$APP_PASSWORD" ]]; then
    echo -e "${RED}Error: APP_PASSWORD not set${NC}"
    echo "Set via environment variable or create .local/release.md with:"
    echo "  APP_PASSWORD=xxxx-xxxx-xxxx-xxxx"
    exit 1
  fi
fi

# Get version from Info.plist
VERSION=$(plutil -extract CFBundleShortVersionString raw "${APP_NAME}.app/Contents/Info.plist")
echo -e "Version: ${YELLOW}${VERSION}${NC}"
echo ""

# Step 1: Run tests
echo -e "${GREEN}[1/7] Running tests...${NC}"
swift test --quiet
echo -e "${GREEN}Tests passed${NC}"
echo ""

# Step 2: Release build (Universal Binary)
echo -e "${GREEN}[2/7] Building release (Universal Binary)...${NC}"
swift build -c release --arch arm64 --arch x86_64 --quiet
echo -e "${GREEN}Build complete${NC}"
echo ""

# Step 3: Copy to app bundle
echo -e "${GREEN}[3/7] Updating app bundle...${NC}"
cp .build/apple/Products/Release/${APP_NAME} ${APP_NAME}.app/Contents/MacOS/
echo "Architecture: $(lipo -info ${APP_NAME}.app/Contents/MacOS/${APP_NAME})"
echo -e "${GREEN}App bundle updated${NC}"
echo ""

# Step 4: Sign app
echo -e "${GREEN}[4/7] Signing app...${NC}"
codesign --force --deep --options runtime \
  --entitlements "${APP_NAME}.entitlements" \
  --sign "${SIGNING_ID}" \
  ${APP_NAME}.app
echo -e "${GREEN}App signed${NC}"
echo ""

# Step 5: Create DMG
echo -e "${GREEN}[5/7] Creating DMG...${NC}"
rm -rf "${DMG_STAGING}"
mkdir -p "${DMG_STAGING}"
cp -R ${APP_NAME}.app "${DMG_STAGING}/"
ln -s /Applications "${DMG_STAGING}/Applications"
hdiutil create -volname "${APP_NAME}" -srcfolder "${DMG_STAGING}" -ov -format UDZO "${DMG_PATH}"
codesign --force --sign "${SIGNING_ID}" "${DMG_PATH}"
echo -e "${GREEN}DMG created: ${DMG_PATH}${NC}"
echo ""

# Step 6: Notarize
echo -e "${GREEN}[6/7] Notarizing DMG (this may take a few minutes)...${NC}"
xcrun notarytool submit "${DMG_PATH}" \
  --apple-id "${APPLE_ID}" \
  --team-id "${TEAM_ID}" \
  --password "${APP_PASSWORD}" \
  --wait
echo -e "${GREEN}Notarization complete${NC}"
echo ""

# Step 7: Staple
echo -e "${GREEN}[7/7] Stapling notarization...${NC}"
xcrun stapler staple "${DMG_PATH}"
echo -e "${GREEN}Stapling complete${NC}"
echo ""

# Summary
echo -e "${GREEN}=== Build Complete ===${NC}"
echo ""
echo "Release artifact:"
echo "  - ${DMG_PATH}"
echo ""

# Publish to GitHub if --publish flag is set
if [[ "$1" == "--publish" ]]; then
  echo -e "${GREEN}=== Publishing to GitHub ===${NC}"
  echo ""

  # Check if tag exists
  if git rev-parse "v${VERSION}" >/dev/null 2>&1; then
    echo -e "${RED}Error: Tag v${VERSION} already exists${NC}"
    echo "Please bump the version in Info.plist first."
    exit 1
  fi

  # Create release
  gh release create "v${VERSION}" \
    "${DMG_PATH}" \
    --title "v${VERSION}" \
    --notes "## Download

- **ClawGate.dmg** - Mac app (notarized, Universal Binary)

## What's New

(Add release notes here)

## Installation

1. Download ClawGate.dmg
2. Open the DMG and drag ClawGate to Applications
3. Launch ClawGate (menu bar icon: 🦀)
4. Grant Accessibility permission when prompted
5. Generate a pairing code and configure your client"

  echo ""
  echo -e "${GREEN}Release published: v${VERSION}${NC}"
else
  echo "To publish to GitHub:"
  echo "  ./scripts/release.sh --publish"
  echo ""
  echo "Or manually:"
  echo "  gh release create v${VERSION} ${DMG_PATH} --title \"v${VERSION}\" --notes \"Release notes\""
fi
