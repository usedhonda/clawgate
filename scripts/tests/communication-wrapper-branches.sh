#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
candidate_stage=""
trap 'rm -rf "$tmp"; [[ -z "${candidate_stage:-}" ]] || rm -rf "$candidate_stage"; rm -f "$ROOT/.runtime/communication-wrapper-candidate.json"' EXIT
project="$tmp/project"
mkdir -p "$project/scripts" "$project/.runtime"
for file in lib-communication-restart.sh lib-ops-log.sh; do ln -s "$ROOT/scripts/$file" "$project/scripts/$file"; done
cat > "$project/scripts/restart-local-clawgate.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 755 "$project/scripts/restart-local-clawgate.sh"
cat > "$tmp/bin-defaults" <<'EOF'
#!/usr/bin/env bash
printf '0\n'
EOF
cat > "$tmp/bin-curl" <<'EOF'
#!/usr/bin/env bash
printf '{"ok":true}\n'
EOF
cat > "$tmp/bin-ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
shift
command="$*"
printf '%s\n' "$command" >> "$COMMUNICATION_WRAPPER_COMMANDS"
if [[ "$command" == bash\ -s* ]]; then
  bash -c "$command"
fi
exit 0
EOF
cat > "$tmp/bin-rsync" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
files_from=""
for arg in "$@"; do [[ "$arg" == --files-from=* ]] && files_from="${arg#--files-from=}"; done
dest="${@: -1}"; stage="${dest#*:}"; stage="${stage%/}"
while IFS= read -r rel; do [[ -n "$rel" ]] || continue; mkdir -p "$stage/$(dirname "$rel")"; cp "$COMMUNICATION_WRAPPER_ROOT/$rel" "$stage/$rel"; done < "$files_from"
EOF
mkdir -p "$tmp/bin"
mv "$tmp/bin-defaults" "$tmp/bin/defaults"
mv "$tmp/bin-curl" "$tmp/bin/curl"
mv "$tmp/bin-ssh" "$tmp/bin/ssh"
mv "$tmp/bin-rsync" "$tmp/bin/rsync"
chmod 755 "$tmp/bin/"*

# Normal build path: inherited stage is ignored without admission and the
# remote command captures mode 0 plus the live project signing script.
(
  export PATH="$tmp/bin:$PATH"
  export COMMUNICATION_WRAPPER_COMMANDS="$tmp/commands"
  export CLAWGATE_COMMUNICATION_SOURCE_STAGE="$tmp/stale-stage"
  cd "$tmp"
  "$ROOT/scripts/post-task-restart.sh" --remote-host fake --project-path "$project" --skip-sync --build-hosta
) >/dev/null 2>&1
grep -Fq "CLAWGATE_COMMUNICATION_STAGED_BUILD=0" "$tmp/commands"
grep -Fq "$project/scripts/macmini-local-sign-and-restart.sh" "$tmp/commands"
if grep -Fq "$tmp/stale-stage/scripts/macmini-local-sign-and-restart.sh" "$tmp/commands"; then
  echo 'normal path selected inherited stage' >&2
  exit 1
fi
echo 'communication wrapper normal branch: PASS'

# Admitted path: run the real post-task staging entry with fake SSH/rsync and
# capture the remote sign command. The canonical preflight checker is a stub;
# no host command or build is executed.
manifest="$ROOT/.runtime/communication-wrapper-candidate.json"
python3 - "$ROOT" "$manifest" <<'PY'
import hashlib, json, pathlib, subprocess, sys
root = pathlib.Path(sys.argv[1])
files = ["scripts/lib-ops-log.sh", "scripts/lib-communication-restart.sh", "scripts/communication-candidate.py", "scripts/communication-maintenance.sh", "scripts/communication-maintenance-apply.sh", "scripts/communication-maintenance-rollback.sh", "scripts/restart-local-clawgate.sh", "scripts/macmini-local-sign-and-restart.sh"]
head = subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip()
data = {"version": 2, "source_revision": head, "target_base_revision": head, "files": [{"path": p, "sha256": hashlib.sha256((root / p).read_bytes()).hexdigest()} for p in files]}
pathlib.Path(sys.argv[2]).write_text(json.dumps(data))
PY
candidate_id="$(shasum -a 256 "$manifest" | awk '{print substr($1,1,16)}')"
candidate_stage="$ROOT/.runtime/communication-candidate-$candidate_id"
[[ ! -e "$candidate_stage" && ! -L "$candidate_stage" ]] || { echo 'candidate stage already exists' >&2; exit 1; }
printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/check"
chmod 755 "$tmp/check"
mkdir -p "$tmp/scripts"
ln -sf "$ROOT/scripts/stage-communication-candidate.sh" "$tmp/scripts/stage-communication-candidate.sh"
cat > "$tmp/scripts/restart-local-clawgate.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 755 "$tmp/scripts/restart-local-clawgate.sh"
touch "$tmp/manifest" "$tmp/current"
(
  export PATH="$tmp/bin:$PATH" COMMUNICATION_WRAPPER_COMMANDS="$tmp/admitted-commands" COMMUNICATION_WRAPPER_ROOT="$ROOT"
  cd "$tmp"
  GATEWAY_RESTART_COMMUNICATION_MANIFEST="$tmp/manifest" \
  GATEWAY_RESTART_COMMUNICATION_CURRENT="$tmp/current" \
  CLAWGATE_COMMUNICATION_CANDIDATE_MANIFEST="$manifest" \
  CLAWGATE_COMMUNICATION_REMOTE_CHECK_SCRIPT="$tmp/check" \
    "$ROOT/scripts/post-task-restart.sh" --remote-host fake --project-path "$ROOT" --build-hosta
) >/dev/null 2>&1
grep -Fq "CLAWGATE_COMMUNICATION_STAGED_BUILD=1" "$tmp/admitted-commands"
grep -Fq "$candidate_stage/scripts/macmini-local-sign-and-restart.sh" "$tmp/admitted-commands"
rm -f "$manifest"
echo 'communication wrapper admitted branch: PASS'

# Staged signing preference: release.env is read from the selected live
# project while the source stage supplies the build payload. Fake keychain,
# Swift, codesign, Gateway, and curl tools stop before any real operation.
live="$tmp/sign-live"
stage="$tmp/sign-stage"
keychain_fixture="$tmp/keychains"
mkdir -p "$live/.local/secrets" "$live/ClawGate.app/Contents/MacOS" "$stage/scripts" "$keychain_fixture"
printf 'SIGNING_ID=LiveSynthetic\n' > "$live/.local/secrets/release.env"
printf 'entitlements\n' > "$stage/ClawGate.entitlements"
printf 'binary\n' > "$live/ClawGate.app/Contents/MacOS/ClawGate"
touch "$keychain_fixture/login.keychain-db" "$keychain_fixture/login_renamed_1.keychain-db"
cat > "$tmp/bin/security" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  unlock-keychain|list-keychains|set-key-partition-list) exit 0 ;;
  find-identity) printf '  1) ABC "LiveSynthetic"\n  2) DEF "ClawGate Dev"\n' ;;
esac
EOF
cat > "$tmp/bin/swift" <<'EOF'
#!/usr/bin/env bash
mkdir -p .build/debug
printf 'built\n' > .build/debug/ClawGate
EOF
cat > "$tmp/bin/codesign" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SIGNING_COMMANDS"
EOF
cat > "$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"ok":true}\n'
EOF
cat > "$tmp/bin/gateway" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 755 "$tmp/bin/security" "$tmp/bin/swift" "$tmp/bin/codesign" "$tmp/bin/curl" "$tmp/bin/gateway"
ln -sf "$ROOT/scripts/lib-communication-restart.sh" "$stage/scripts/lib-communication-restart.sh"
sed "s|\"\$HOME/Library/Keychains/|\"\$KEYCHAIN_FIXTURE/|g" "$ROOT/scripts/macmini-local-sign-and-restart.sh" > "$stage/scripts/macmini-local-sign-and-restart.sh"
chmod 755 "$stage/scripts/macmini-local-sign-and-restart.sh"
(
  export PATH="$tmp/bin:$PATH" SIGNING_COMMANDS="$tmp/signing-commands" KEYCHAIN_FIXTURE="$keychain_fixture"
  export KEYCHAIN_PASSWORD=synthetic CLAWGATE_COMMUNICATION_STAGED_BUILD=1
  export CLAWGATE_COMMUNICATION_SOURCE_STAGE="$stage" CLAWGATE_COMMUNICATION_PROJECT_PATH="$live"
  export CLAWGATE_GATEWAY_RESTART_SCRIPT="$tmp/bin/gateway"
  cd "$live"
  "$stage/scripts/macmini-local-sign-and-restart.sh" --project-path "$live"
) >/dev/null 2>&1
grep -Fq -- '--sign LiveSynthetic' "$tmp/signing-commands"
echo 'communication staged signing preference: PASS'
