#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
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
printf '%s\n' "$*" >> "$COMMUNICATION_WRAPPER_COMMANDS"
exit 0
EOF
mkdir -p "$tmp/bin"
mv "$tmp/bin-defaults" "$tmp/bin/defaults"
mv "$tmp/bin-curl" "$tmp/bin/curl"
mv "$tmp/bin-ssh" "$tmp/bin/ssh"
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
