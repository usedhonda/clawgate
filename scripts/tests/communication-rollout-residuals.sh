#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

for script in stage-communication-candidate.sh lib-communication-restart.sh \
  restart-macmini-openclaw.sh post-task-restart.sh \
  macmini-local-sign-and-restart.sh communication-maintenance.sh; do
  bash -n "$ROOT/scripts/$script"
done

# Source-only guards are intentionally checked with fake tools/text: this batch
# must not SSH, build, sign, or restart a host.
grep -Fq 'rsync -azs' "$ROOT/scripts/stage-communication-candidate.sh"
grep -Fq '/bin/bash -s' "$ROOT/scripts/restart-macmini-openclaw.sh"
grep -Fq 'staged_build=0' "$ROOT/scripts/post-task-restart.sh"
grep -Fq 'CLAWGATE_COMMUNICATION_BACKUP_DIR' "$ROOT/scripts/lib-communication-restart.sh"

project="$tmp/project"
mkdir -p "$project/scripts" "$project/extensions/openclaw-plugin" "$project/.runtime"
printf '#!/usr/bin/env bash\nexit 0\n' > "$project/scripts/restart-local-clawgate.sh"
chmod 755 "$project/scripts/restart-local-clawgate.sh"
state="$tmp/state"

# A scripts-only admitted operation works without a plugin source.
CLAWGATE_COMMUNICATION_PROJECT_PATH="$project" \
CLAWGATE_COMMUNICATION_BACKUP_DIR="$state/one" \
CLAWGATE_COMMUNICATION_PLUGIN_SOURCE="$tmp/missing-plugin" \
CLAWGATE_COMMUNICATION_PLUGIN_DEST="$tmp/plugin" \
CLAWGATE_COMMUNICATION_TEST_MODE=1 \
CLAWGATE_COMMUNICATION_SKIP_PLUGIN_SYNC=1 \
  "$ROOT/scripts/communication-maintenance.sh" apply >/dev/null

# A failed preflight cannot consume an earlier successful operation.
prior="$state/prior"
mkdir -p "$prior/op.old"
printf '%s\n' "$prior/op.old" > "$prior/current-op"
if CLAWGATE_COMMUNICATION_PROJECT_PATH="$project" \
   CLAWGATE_COMMUNICATION_BACKUP_DIR="$prior" \
   CLAWGATE_COMMUNICATION_PLUGIN_SOURCE="$tmp/missing-plugin" \
   CLAWGATE_COMMUNICATION_PLUGIN_DEST="$tmp/plugin" \
   CLAWGATE_COMMUNICATION_TEST_MODE=1 \
   "$ROOT/scripts/communication-maintenance.sh" apply >/dev/null 2>&1; then
  echo 'expected missing plugin preflight failure' >&2
  exit 1
fi
[[ "$(<"$prior/current-op")" == "$prior/op.old" ]]

# The canonical wrapper receives one isolated operation root for apply/rollback.
gateway="$tmp/gateway"
cat > "$gateway" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${CLAWGATE_COMMUNICATION_BACKUP_DIR:-}" > "$COMMUNICATION_TEST_OPERATION"
EOF
chmod 755 "$gateway"
COMMUNICATION_TEST_OPERATION="$tmp/operation" \
CLAWGATE_GATEWAY_RESTART_SCRIPT="$gateway" \
GATEWAY_RESTART_COMMUNICATION_MANIFEST="$tmp/manifest" \
GATEWAY_RESTART_COMMUNICATION_CURRENT="$tmp/current" \
CLAWGATE_COMMUNICATION_PROJECT_PATH="$project" \
  bash -c 'source "$1/scripts/lib-communication-restart.sh"; communication_gateway_restart' _ "$ROOT"
[[ "$(<"$tmp/operation")" == "$project/.runtime/communication-maintenance/"* ]]

echo 'communication rollout residuals: PASS'
