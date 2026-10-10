#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/scripts/lib-communication-restart.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
events="$tmp/events"
canonical="$tmp/gateway-restart"
apply="$tmp/apply"
rollback="$tmp/rollback"
check="$tmp/check-communication-change"
candidate="$tmp/candidate.json"

cat > "$canonical" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ -n "${GATEWAY_RESTART_COMMUNICATION_MANIFEST:-}" ]]
[[ -n "${GATEWAY_RESTART_COMMUNICATION_CURRENT:-}" ]]
echo check >> "$COMMUNICATION_TEST_EVENTS"
echo stop >> "$COMMUNICATION_TEST_EVENTS"
"${GATEWAY_RESTART_MAINTENANCE_HOOK}"
echo start >> "$COMMUNICATION_TEST_EVENTS"
EOF
cat > "$apply" <<'EOF'
#!/usr/bin/env bash
echo apply >> "$COMMUNICATION_TEST_EVENTS"
EOF
cat > "$rollback" <<'EOF'
#!/usr/bin/env bash
echo rollback >> "$COMMUNICATION_TEST_EVENTS"
EOF
chmod 755 "$canonical" "$apply" "$rollback"
cat > "$check" <<'EOF'
#!/usr/bin/env python3
import pathlib
import sys
args = sys.argv[1:]
assert args[0] == "--manifest" and args[2] == "--current"
assert pathlib.Path(args[1]).is_file() and pathlib.Path(args[3]).is_file()
EOF
chmod 755 "$check"

python3 - "$ROOT" "$candidate" <<'PY'
import hashlib, json, pathlib, subprocess, sys
root = pathlib.Path(sys.argv[1])
path = root / "scripts/lib-communication-restart.sh"
manifest = {
    "version": 2,
    "source_revision": subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip(),
    "target_base_revision": subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip(),
    "files": [{"path": "scripts/lib-communication-restart.sh", "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}],
}
pathlib.Path(sys.argv[2]).write_text(json.dumps(manifest))
PY
python3 "$ROOT/scripts/communication-candidate.py" --manifest "$candidate" >/dev/null
sed 's/"source_revision": "[^"]*"/"source_revision": "invalid"/' "$candidate" > "$tmp/candidate-invalid.json"
if python3 "$ROOT/scripts/communication-candidate.py" --manifest "$tmp/candidate-invalid.json" >/dev/null 2>&1; then
  echo "FAIL: basehash mismatch was accepted" >&2
  exit 1
fi

ignored_key="$ROOT/.runtime/communication-test-ignored-key"
mkdir -p "$ROOT/.runtime"
printf 'test-key\n' > "$ignored_key"
python3 - "$ROOT" "$tmp/candidate-ignored.json" "$ignored_key" <<'PY'
import hashlib, json, pathlib, subprocess, sys
root = pathlib.Path(sys.argv[1])
path = pathlib.Path(sys.argv[3])
manifest = {
    "version": 2,
    "source_revision": subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip(),
    "target_base_revision": subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip(),
    "files": [{"path": str(path.relative_to(root)), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}],
}
pathlib.Path(sys.argv[2]).write_text(json.dumps(manifest))
PY
if python3 "$ROOT/scripts/communication-candidate.py" --manifest "$tmp/candidate-ignored.json" >/dev/null 2>&1; then
  echo "FAIL: ignored/untracked candidate was accepted" >&2
  exit 1
fi
unlink "$ignored_key"

if GATEWAY_RESTART_COMMUNICATION_MANIFEST="$tmp/manifest" \
   GATEWAY_RESTART_COMMUNICATION_CURRENT="" \
   communication_require_admission 2>/dev/null; then
  echo "FAIL: partial admission was accepted" >&2
  exit 1
fi
[[ ! -s "$events" ]] || { echo "FAIL: rejected admission produced effects" >&2; exit 1; }

touch "$tmp/manifest" "$tmp/current"
export COMMUNICATION_TEST_EVENTS="$events"
export GATEWAY_RESTART_COMMUNICATION_MANIFEST="$tmp/manifest"
export GATEWAY_RESTART_COMMUNICATION_CURRENT="$tmp/current"
export CLAWGATE_GATEWAY_RESTART_SCRIPT="$canonical"
export CLAWGATE_COMMUNICATION_CHECK_SCRIPT="$check"
export CLAWGATE_COMMUNICATION_MAINTENANCE_HOOK="$apply"
export CLAWGATE_COMMUNICATION_ROLLBACK_HOOK="$rollback"
communication_preflight
communication_gateway_restart
expected=$'check\nstop\napply\nstart'
actual="$(<"$events")"
[[ "$actual" == "$expected" ]] || { printf 'FAIL: order was:\n%s\n' "$actual" >&2; exit 1; }
echo "communication restart guard: PASS (reject-before-effects, check-stop-apply-start)"

# Wrapper rejection: unsupported preguard branches must not reach ssh/sync/deploy.
spy_bin="$tmp/bin"
mkdir -p "$spy_bin"
for spy in ssh rsync scp defaults curl open swift codesign; do
  cat > "$spy_bin/$spy" <<EOF
#!/usr/bin/env bash
echo $spy >> "\$COMMUNICATION_TEST_EVENTS"
exit 99
EOF
  chmod 755 "$spy_bin/$spy"
done
if PATH="$spy_bin:$PATH" \
   GATEWAY_RESTART_COMMUNICATION_MANIFEST="$tmp/manifest" \
   GATEWAY_RESTART_COMMUNICATION_CURRENT="$tmp/current" \
   COMMUNICATION_TEST_EVENTS="$events" \
   "$ROOT/scripts/post-task-restart.sh" --remote-host fake --skip-plugin-sync >/dev/null 2>&1; then
  echo "FAIL: preguard sync branch was accepted" >&2
  exit 1
fi
[[ "$(<"$events")" == "$expected" ]] || { echo "FAIL: rejected wrapper reached an external effect" >&2; exit 1; }

# Signed-bundle communication admission performs the remote canonical check
# before local restart/build/deploy side effects.
signed_candidate="$ROOT/.runtime/communication-test-candidate.json"
mkdir -p "$ROOT/.runtime"
cp "$candidate" "$signed_candidate"
if PATH="$spy_bin:$PATH" \
   GATEWAY_RESTART_COMMUNICATION_MANIFEST="$tmp/manifest" \
   GATEWAY_RESTART_COMMUNICATION_CURRENT="$tmp/current" \
   CLAWGATE_COMMUNICATION_CANDIDATE_MANIFEST="$signed_candidate" \
   CLAWGATE_COMMUNICATION_REMOTE_CHECK_SCRIPT="$check" \
   COMMUNICATION_TEST_EVENTS="$events" \
   "$ROOT/scripts/post-task-restart.sh" --remote-host fake --signed-bundle --skip-sync --skip-plugin-sync >/dev/null 2>&1; then
  echo "FAIL: signed-bundle remote preflight rejection was accepted" >&2
  exit 1
fi
[[ "$(<"$events")" == "$expected
ssh" ]] || { printf 'FAIL: signed-bundle rejection reached local effects (%q)\n' "$(<"$events")" >&2; exit 1; }
unlink "$signed_candidate"

# Exact-file apply/rollback: preserve unrelated installed helpers and restore
# only files touched by this operation.
maintenance_project="$tmp/project"
mkdir -p "$maintenance_project/extensions/openclaw-plugin/src" "$maintenance_project/scripts"
mkdir -p "$maintenance_project/ClawGate.app/Contents" "$maintenance_project/.runtime/staged-app/Contents"
printf 'old-app\n' > "$maintenance_project/ClawGate.app/Contents/marker"
printf 'new-app\n' > "$maintenance_project/.runtime/staged-app/Contents/marker"
cp "$ROOT/scripts/communication-maintenance.sh" "$maintenance_project/scripts/communication-maintenance.sh"
cat > "$maintenance_project/scripts/restart-local-clawgate.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 755 "$maintenance_project/scripts/restart-local-clawgate.sh"
printf 'new\n' > "$maintenance_project/extensions/openclaw-plugin/src/client.js"
printf 'old\n' > "$tmp/home-client.js"
plugin_dest="$tmp/home/.openclaw/extensions/clawgate"
mkdir -p "$plugin_dest/src"
cp "$tmp/home-client.js" "$plugin_dest/src/client.js"
printf 'keep\n' > "$plugin_dest/third-party-helper.js"
CLAWGATE_COMMUNICATION_PROJECT_PATH="$maintenance_project" \
CLAWGATE_COMMUNICATION_BACKUP_DIR="$tmp/state" \
CLAWGATE_COMMUNICATION_PLUGIN_DEST="$plugin_dest" \
CLAWGATE_COMMUNICATION_TEST_MODE=1 \
CLAWGATE_COMMUNICATION_CANDIDATE_FILES="extensions/openclaw-plugin/src/client.js" \
CLAWGATE_COMMUNICATION_STAGED_APP="$maintenance_project/.runtime/staged-app" \
  "$ROOT/scripts/communication-maintenance.sh" apply
[[ "$(<"$plugin_dest/src/client.js")" == "new" ]] || { echo "FAIL: apply did not update owned file" >&2; exit 1; }
[[ -f "$plugin_dest/third-party-helper.js" ]] || { echo "FAIL: apply removed unrelated helper" >&2; exit 1; }
[[ "$(<"$maintenance_project/ClawGate.app/Contents/marker")" == "new-app" ]] || { echo "FAIL: staged app was not applied" >&2; exit 1; }
CLAWGATE_COMMUNICATION_PROJECT_PATH="$maintenance_project" \
CLAWGATE_COMMUNICATION_BACKUP_DIR="$tmp/state" \
CLAWGATE_COMMUNICATION_PLUGIN_DEST="$plugin_dest" \
CLAWGATE_COMMUNICATION_TEST_MODE=1 \
CLAWGATE_COMMUNICATION_CANDIDATE_FILES="extensions/openclaw-plugin/src/client.js" \
CLAWGATE_COMMUNICATION_STAGED_APP="$maintenance_project/.runtime/staged-app" \
  "$ROOT/scripts/communication-maintenance.sh" rollback
[[ "$(<"$plugin_dest/src/client.js")" == "old" ]] || { echo "FAIL: rollback did not restore owned file" >&2; exit 1; }
[[ -f "$plugin_dest/third-party-helper.js" ]] || { echo "FAIL: rollback removed unrelated helper" >&2; exit 1; }
[[ "$(<"$maintenance_project/ClawGate.app/Contents/marker")" == "old-app" ]] || { echo "FAIL: rollback did not restore app" >&2; exit 1; }
CLAWGATE_COMMUNICATION_PROJECT_PATH="$maintenance_project" \
CLAWGATE_COMMUNICATION_BACKUP_DIR="$tmp/state-skip" \
CLAWGATE_COMMUNICATION_PLUGIN_DEST="$plugin_dest" \
CLAWGATE_COMMUNICATION_TEST_MODE=1 \
CLAWGATE_COMMUNICATION_SKIP_PLUGIN_SYNC=1 \
  "$ROOT/scripts/communication-maintenance.sh" apply
[[ "$(<"$plugin_dest/src/client.js")" == "old" ]] || { echo "FAIL: skip-plugin-sync was ignored" >&2; exit 1; }
echo "maintenance exact-file apply/rollback: PASS"
