#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Exercise the actual signed-bundle caller from an isolated working directory.
mkdir -p "$tmp/project/scripts" "$tmp/bin"
ln -s "$ROOT/scripts/lib-communication-restart.sh" "$tmp/project/scripts/lib-communication-restart.sh"
ln -s "$ROOT/scripts/lib-ops-log.sh" "$tmp/project/scripts/lib-ops-log.sh"
cat > "$tmp/project/scripts/restart-local-clawgate.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$SIGNED_CALL"
EOF
cat > "$tmp/project/scripts/deploy-signed-bundle.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$DEPLOY_CALL"
EOF
chmod 755 "$tmp/project/scripts/"*.sh
cat > "$tmp/bin/defaults" <<'EOF'
#!/usr/bin/env bash
printf '0\n'
EOF
cat > "$tmp/bin/ssh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"ok":true}\n'
EOF
chmod 755 "$tmp/bin/"*
(
  export PATH="$tmp/bin:$PATH" SIGNED_CALL="$tmp/signed-call" DEPLOY_CALL="$tmp/deploy-call"
  cd "$tmp"
  "$ROOT/scripts/post-task-restart.sh" --remote-host fake --project-path "$tmp/project" --signed-bundle --skip-sync --skip-plugin-sync
) >"$tmp/caller.log" 2>&1 || { cat "$tmp/caller.log" >&2; exit 1; }
[[ "$(<"$tmp/signed-call")" == '--skip-build --skip-sync --skip-plugin-sync --skip-sign' ]]
[[ "$(<"$tmp/deploy-call")" == '--remote-host fake' ]]
echo 'signed-bundle caller flags: PASS'

# Execute the actual restart helper against a prepared app. Build, sync,
# signing, and plugin paths are fake-command guarded and must remain untouched.
app="$tmp/prepared"
mkdir -p "$app/scripts" "$app/ClawGate.app/Contents/MacOS" "$app/ClawGate.app/Contents/Resources" "$app/extensions/openclaw-plugin"
ln -s "$ROOT/scripts/lib-ops-log.sh" "$app/scripts/lib-ops-log.sh"
cp "$ROOT/scripts/restart-local-clawgate.sh" "$app/scripts/restart-local-clawgate.sh"
chmod 755 "$app/scripts/restart-local-clawgate.sh"
printf 'prepared-binary\n' > "$app/ClawGate.app/Contents/MacOS/ClawGate"
printf 'prepared-resource\n' > "$app/ClawGate.app/Contents/Resources/marker"
printf 'different-build\n' > "$app/.build-debug-marker"
cat > "$tmp/bin/pkill" <<'EOF'
#!/usr/bin/env bash
printf 'pkill\n' >> "$FORBIDDEN_CALLS"
exit 0
EOF
cat > "$tmp/bin/pgrep" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
cat > "$tmp/bin/open" <<'EOF'
#!/usr/bin/env bash
printf 'open\n' >> "$FORBIDDEN_CALLS"
exit 0
EOF
cat > "$tmp/bin/launchctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$tmp/bin/ps" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$tmp/bin/strings" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$tmp/bin/swift" <<'EOF'
#!/usr/bin/env bash
printf 'swift\n' >> "$FORBIDDEN_CALLS"
exit 99
EOF
cat > "$tmp/bin/codesign" <<'EOF'
#!/usr/bin/env bash
printf 'codesign\n' >> "$FORBIDDEN_CALLS"
exit 99
EOF
cat > "$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"ok":true}\n'
EOF
chmod 755 "$tmp/bin/"*
before_bin="$(shasum -a 256 "$app/ClawGate.app/Contents/MacOS/ClawGate")"
before_resource="$(shasum -a 256 "$app/ClawGate.app/Contents/Resources/marker")"
PATH="$tmp/bin:$PATH" FORBIDDEN_CALLS="$tmp/forbidden" \
  "$app/scripts/restart-local-clawgate.sh" --project-path "$app" --skip-build --skip-sync --skip-plugin-sync --skip-sign --wait-seconds 1 >/dev/null
[[ "$before_bin" == "$(shasum -a 256 "$app/ClawGate.app/Contents/MacOS/ClawGate")" ]]
[[ "$before_resource" == "$(shasum -a 256 "$app/ClawGate.app/Contents/Resources/marker")" ]]
if [[ -e "$tmp/forbidden" ]]; then
  ! grep -Eq 'swift|codesign' "$tmp/forbidden"
fi
echo 'signed-bundle prepared bytes: PASS'
