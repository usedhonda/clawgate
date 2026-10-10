#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
project="$tmp/project"
stage="$project/.runtime/stage"
plugin="$tmp/plugin"
mkdir -p "$project/scripts" "$project/ClawGate.app/Contents" "$stage/ClawGate.app/Contents" "$stage/extensions/openclaw-plugin/src" "$plugin/src" "$tmp/bin"
printf 'old\n' > "$project/ClawGate.app/Contents/marker"
printf 'new\n' > "$stage/ClawGate.app/Contents/marker"
printf 'new\n' > "$stage/extensions/openclaw-plugin/src/client.js"
printf 'old\n' > "$plugin/src/client.js"
export ORDER_EVENTS="$tmp/events" ORDER_PROJECT="$project" ORDER_PLUGIN="$plugin"
cat > "$tmp/bin/pkill" <<'EOF'
#!/usr/bin/env bash
echo stop >> "$ORDER_EVENTS"
EOF
cat > "$tmp/bin/pgrep" <<'EOF'
#!/usr/bin/env bash
[[ "${ORDER_STILL_RUNNING:-0}" == 1 ]]
EOF
cat > "$tmp/bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$tmp/bin/mv" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "$ORDER_PROJECT/ClawGate.app" ]]; then
  [[ "$(tail -n 1 "$ORDER_EVENTS")" == stop ]] || exit 99
  echo swap >> "$ORDER_EVENTS"
fi
/bin/mv "$@"
EOF
cat > "$project/scripts/restart-local-clawgate.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$(cat "$ORDER_PROJECT/ClawGate.app/Contents/marker")" == "$ORDER_EXPECTED" ]]
[[ "$(cat "$ORDER_PLUGIN/src/client.js")" == "$ORDER_EXPECTED" ]]
echo restart >> "$ORDER_EVENTS"
EOF
chmod 755 "$tmp/bin/"* "$project/scripts/restart-local-clawgate.sh"
export PATH="$tmp/bin:$PATH"
export CLAWGATE_COMMUNICATION_PROJECT_PATH="$project"
export CLAWGATE_COMMUNICATION_BACKUP_DIR="$tmp/state"
export CLAWGATE_COMMUNICATION_PLUGIN_SOURCE="$stage/extensions/openclaw-plugin"
export CLAWGATE_COMMUNICATION_PLUGIN_DEST="$plugin" CLAWGATE_COMMUNICATION_TEST_MODE=1
export CLAWGATE_COMMUNICATION_CANDIDATE_FILES="extensions/openclaw-plugin/src/client.js"
export CLAWGATE_COMMUNICATION_STAGED_APP="$stage/ClawGate.app"
ORDER_STILL_RUNNING=1 ORDER_EXPECTED=new bash "$ROOT/scripts/communication-maintenance.sh" apply >/dev/null 2>&1 && exit 99
[[ "$(cat "$project/ClawGate.app/Contents/marker")" == old ]]
[[ "$(cat "$plugin/src/client.js")" == old ]]
[[ "$(cat "$ORDER_EVENTS")" == stop ]]
: > "$ORDER_EVENTS"
ORDER_EXPECTED=new bash "$ROOT/scripts/communication-maintenance.sh" apply
ORDER_EXPECTED=old bash "$ROOT/scripts/communication-maintenance.sh" rollback
[[ "$(cat "$ORDER_EVENTS")" == $'stop\nswap\nrestart\nstop\nswap\nrestart' ]]
echo "maintenance stop/swap/restore/restart order: PASS (fake process tools only)"
