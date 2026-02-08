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
ok "Binary copied"

# Sign with stable cert (not ad-hoc)
codesign --force --deep --options runtime \
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
# Step 4: Sync OpenClaw plugin
###############################################################################
if [ "$SKIP_PLUGIN" = "false" ]; then
    step "Syncing OpenClaw plugin..."

    PLUGIN_SRC="$PROJECT_DIR/extensions/openclaw-plugin"
    PLUGIN_DST="$HOME/.openclaw/extensions/clawgate"

    if [ ! -d "$PLUGIN_SRC" ]; then
        warn "Plugin source not found at $PLUGIN_SRC — skipping"
    else
        # Check if plugin files changed
        NEEDS_SYNC=false
        if [ ! -d "$PLUGIN_DST" ]; then
            NEEDS_SYNC=true
        elif ! diff -rq "$PLUGIN_SRC" "$PLUGIN_DST" >/dev/null 2>&1; then
            NEEDS_SYNC=true
        fi

        if [ "$NEEDS_SYNC" = "true" ]; then
            mkdir -p "$PLUGIN_DST"
            cp -R "$PLUGIN_SRC/" "$PLUGIN_DST/"
            ok "Plugin synced to $PLUGIN_DST"

            # Restart gateway (KeepAlive will auto-restart it)
            if pgrep -f "openclaw.*gateway" >/dev/null 2>&1; then
                pkill -f "openclaw.*gateway" 2>/dev/null || true
                ok "Gateway killed (KeepAlive will restart)"
                sleep 5
            else
                warn "Gateway not running — skipping restart"
            fi
        else
            ok "Plugin unchanged — no sync needed"
        fi

        SMOKE_ARGS="--with-openclaw"
    fi
else
    step "Skipping OpenClaw plugin sync (--skip-plugin)"
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
