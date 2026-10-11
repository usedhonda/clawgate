#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"; rm -f "$ROOT/.runtime/communication-residual-manifest.json" "$ROOT/.runtime/communication-residual-stale.json"; [[ -z "${RESIDUAL_STAGE:-}" ]] || rm -rf "$RESIDUAL_STAGE"' EXIT

for script in stage-communication-candidate.sh lib-communication-restart.sh \
  restart-macmini-openclaw.sh post-task-restart.sh \
  macmini-local-sign-and-restart.sh communication-maintenance.sh; do
  bash -n "$ROOT/scripts/$script"
done

# Source-only guards are intentionally checked with fake tools/text: this batch
# must not SSH, build, sign, or restart a host.
grep -Fq 'rsync -az --files-from=' "$ROOT/scripts/stage-communication-candidate.sh"
grep -Fq '/bin/bash -s' "$ROOT/scripts/restart-macmini-openclaw.sh"
grep -Fq 'staged_build=0' "$ROOT/scripts/post-task-restart.sh"
grep -Fq 'CLAWGATE_COMMUNICATION_BACKUP_DIR' "$ROOT/scripts/lib-communication-restart.sh"

# Execute the real staging wrapper with local fake ssh/rsync tools. A symlinked
# destination is rejected before rsync; the CLI manifest wins over stale env.
manifest="$ROOT/.runtime/communication-residual-manifest.json"
stale="$ROOT/.runtime/communication-residual-stale.json"
python3 - "$ROOT" "$manifest" "$stale" <<'PY'
import hashlib, json, pathlib, subprocess, sys
root = pathlib.Path(sys.argv[1])
required = [
    "scripts/lib-ops-log.sh", "scripts/lib-communication-restart.sh",
    "scripts/communication-candidate.py", "scripts/communication-maintenance.sh",
    "scripts/communication-maintenance-apply.sh", "scripts/communication-maintenance-rollback.sh",
    "scripts/restart-local-clawgate.sh", "scripts/macmini-local-sign-and-restart.sh",
]
data = {"version": 2, "source_revision": subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip(),
        "target_base_revision": subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip(),
        "files": [{"path": p, "sha256": hashlib.sha256((root / p).read_bytes()).hexdigest()} for p in required]}
pathlib.Path(sys.argv[2]).write_text(json.dumps(data))
bad = dict(data); bad["source_revision"] = "stale"
pathlib.Path(sys.argv[3]).write_text(json.dumps(bad))
PY
candidate_id="$(shasum -a 256 "$manifest" | awk '{print substr($1,1,16)}')"
RESIDUAL_STAGE="$ROOT/.runtime/communication-candidate-$candidate_id"
rm -rf "$RESIDUAL_STAGE"
mkdir -p "$tmp/bin"
cat > "$tmp/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
host="$1"; shift
bash -c "$*"
EOF
cat > "$tmp/bin/rsync" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
files_from=""
for arg in "$@"; do [[ "$arg" == --files-from=* ]] && files_from="${arg#--files-from=}"; done
dest="${@: -1}"; stage="${dest#*:}"; stage="${stage%/}"
while IFS= read -r rel; do [[ -n "$rel" ]] || continue; mkdir -p "$stage/$(dirname "$rel")"; cp "$ROOT/$rel" "$stage/$rel"; done < "$files_from"
echo rsync >> "$COMMUNICATION_RESIDUAL_EVENTS"
EOF
chmod 755 "$tmp/bin/ssh" "$tmp/bin/rsync"
ln -s "$tmp/redirect" "$RESIDUAL_STAGE"
if PATH="$tmp/bin:$PATH" COMMUNICATION_RESIDUAL_EVENTS="$tmp/events" ROOT="$ROOT" \
   "$ROOT/scripts/stage-communication-candidate.sh" --remote-host fake --manifest "$manifest" >/dev/null 2>&1; then
  echo 'symlink stage destination was accepted' >&2; exit 1
fi
[[ ! -e "$tmp/events" ]]
rm "$RESIDUAL_STAGE"
PATH="$tmp/bin:$PATH" COMMUNICATION_RESIDUAL_EVENTS="$tmp/events" ROOT="$ROOT" \
  CLAWGATE_COMMUNICATION_CANDIDATE_MANIFEST="$stale" \
  "$ROOT/scripts/stage-communication-candidate.sh" --remote-host fake --manifest "$manifest" >/dev/null
[[ "$(<"$tmp/events")" == rsync ]]

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
CLAWGATE_COMMUNICATION_PROJECT_PATH="$project" \
CLAWGATE_COMMUNICATION_BACKUP_DIR="$prior/fresh" \
  "$ROOT/scripts/communication-maintenance.sh" rollback >/dev/null
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
