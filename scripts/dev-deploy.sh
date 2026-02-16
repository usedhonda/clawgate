#!/bin/bash
# ClawGate Dev Deploy — one-shot build, deploy, and verify
# Usage: ./scripts/dev-deploy.sh [--skip-plugin] [--skip-test]
#
# Steps:
#   1. swift build
#   2. Kill running ClawGate, copy binary, re-sign, launch
#   3. Poll /v1/health until ready (max 30s)
#   4. Sync OpenClaw plugin (unless --skip-plugin)
#   5. Run smoke-test.sh (unless --skip-test)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

SKIP_PLUGIN=false
SKIP_TEST=false
SMOKE_ARGS=""

for arg in "$@"; do
    case "$arg" in
        --skip-plugin) SKIP_PLUGIN=true ;;
        --skip-test)   SKIP_TEST=true ;;
    esac
done

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

step() { echo -e "\n${BOLD}${CYAN}==>${NC}${BOLD} $1${NC}"; }
ok()   { echo -e "  ${GREEN}OK${NC} $1"; }
err()  { echo -e "  ${RED}ERROR${NC} $1"; }
warn() { echo -e "  ${YELLOW}WARN${NC} $1"; }

###############################################################################
# Step 1: Build
###############################################################################
step "Building ClawGate..."
if swift build 2>&1; then
    ok "swift build succeeded"
else
    err "swift build failed"
    exit 1
fi

###############################################################################
# Step 2: Kill, copy, sign, launch
###############################################################################
step "Deploying binary..."

# Kill existing
pkill -f ClawGate.app 2>/dev/null || true
sleep 1

# Copy binary
cp .build/debug/ClawGate ClawGate.app/Contents/MacOS/ClawGate
# Copy app icon
if [[ -f "$PROJECT_DIR/resources/AppIcon.icns" ]]; then
    cp "$PROJECT_DIR/resources/AppIcon.icns" ClawGate.app/Contents/Resources/AppIcon.icns
fi
# Copy privacy manifest
if [[ -f "$PROJECT_DIR/resources/PrivacyInfo.xcprivacy" ]]; then
    cp "$PROJECT_DIR/resources/PrivacyInfo.xcprivacy" ClawGate.app/Contents/Resources/PrivacyInfo.xcprivacy
fi
ok "Binary copied"

# Sign with stable cert (not ad-hoc)
if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "ClawGate Dev"; then
    err "'ClawGate Dev' certificate not found. Run ./scripts/setup-cert.sh once."
    exit 1
fi
codesign --force --deep --options runtime \
    --identifier com.clawgate.app \
    --entitlements ClawGate.entitlements \
    --sign "ClawGate Dev" ClawGate.app
ok "Code signed (ClawGate Dev)"

# Launch
open ClawGate.app
ok "App launched"

###############################################################################
# Step 3: Wait for health
###############################################################################
step "Waiting for ClawGate to start..."

BASE_URL="http://127.0.0.1:8765"
MAX_WAIT=30
ELAPSED=0

while [ $ELAPSED -lt $MAX_WAIT ]; do
    HEALTH=$(curl -s -m 2 "$BASE_URL/v1/health" 2>/dev/null || echo "")
    if echo "$HEALTH" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if d.get('ok') else 1)" 2>/dev/null; then
        VERSION=$(echo "$HEALTH" | python3 -c "import sys,json; print(json.load(sys.stdin).get('version','?'))" 2>/dev/null)
        ok "Health OK (v$VERSION) after ${ELAPSED}s"
        break
    fi
    sleep 2
    ELAPSED=$((ELAPSED + 2))
done

if [ $ELAPSED -ge $MAX_WAIT ]; then
    err "ClawGate did not become healthy within ${MAX_WAIT}s"
    exit 1
fi

###############################################################################
# Step 4: Sync OpenClaw plugins
###############################################################################
GATEWAY_RESTARTED=false

if [ "$SKIP_PLUGIN" = "false" ]; then
    step "Syncing OpenClaw plugins..."

    ANY_PLUGIN_SYNCED=false

    # Sync each plugin: source_dir -> dest_dir
    sync_plugin() {
        local src="$1"
        local dst="$2"
        local name="$3"

        if [ ! -d "$src" ]; then
            warn "$name source not found at $src — skipping"
            return
        fi

        local needs_sync=false
        if [ ! -d "$dst" ]; then
            needs_sync=true
        elif ! diff -rq "$src" "$dst" >/dev/null 2>&1; then
            needs_sync=true
        fi

        if [ "$needs_sync" = "true" ]; then
            mkdir -p "$dst"
            cp -R "$src/" "$dst/"
            ok "$name synced to $dst"
            ANY_PLUGIN_SYNCED=true
        else
            ok "$name unchanged — no sync needed"
        fi
    }

    sync_plugin "$PROJECT_DIR/extensions/openclaw-plugin" "$HOME/.openclaw/extensions/clawgate" "clawgate"
    sync_plugin "$PROJECT_DIR/extensions/vibeterm-telemetry" "$HOME/.openclaw/extensions/vibeterm-telemetry" "vibeterm-telemetry"

    # Restart gateway once if any plugin changed
    if [ "$ANY_PLUGIN_SYNCED" = "true" ]; then
        if launchctl list 2>/dev/null | grep -q 'openclaw\.gateway'; then
            launchctl stop ai.openclaw.gateway && sleep 2 && launchctl start ai.openclaw.gateway
            ok "Gateway restarted via launchctl"
            GATEWAY_RESTARTED=true
            sleep 5
        else
            warn "Gateway not registered in launchd — skipping restart"
        fi
    fi

    SMOKE_ARGS="--with-openclaw"
else
    step "Skipping OpenClaw plugin sync (--skip-plugin)"
fi

###############################################################################
# Step 4.5: Restart Gateway (if not already restarted by plugin sync)
###############################################################################
if [ "$GATEWAY_RESTARTED" = "false" ]; then
    step "Restarting OpenClaw Gateway (ClawGate connection reset)..."
    if launchctl list 2>/dev/null | grep -q 'openclaw\.gateway'; then
        launchctl stop ai.openclaw.gateway && sleep 2 && launchctl start ai.openclaw.gateway
        ok "Gateway restarted via launchctl"
        sleep 5
    else
        warn "Gateway not registered in launchd — skipping restart"
    fi
fi

###############################################################################
# Step 5: Smoke test
###############################################################################
if [ "$SKIP_TEST" = "false" ]; then
    step "Running smoke tests..."
    "$SCRIPT_DIR/smoke-test.sh" $SMOKE_ARGS
else
    step "Skipping smoke tests (--skip-test)"
fi

echo ""
echo -e "${GREEN}${BOLD}Deploy complete!${NC}"
