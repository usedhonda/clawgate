#!/usr/bin/env bash
set -euo pipefail

root="$(cd -- "$(dirname -- "$0")/../.." && pwd)"
cd "$root"
scratch="$(mktemp -d .local/restart-skip-plugin-sync.XXXXXX)"
trap 'rm -r "$scratch"' EXIT

cat > "$scratch/ssh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CAPTURED_SSH"
SH
chmod +x "$scratch/ssh"

export CAPTURED_SSH="$scratch/ssh-calls"
export OPS_LOG_DIR="$scratch/logs"
PATH="$scratch:$PATH" "$root/scripts/restart-macmini-openclaw.sh" \
  --project-path "$root" --skip-plugin-sync >/dev/null

if ! grep -q "SKIP_PLUGIN_SYNC_FLAG='1'" "$CAPTURED_SSH"; then
  echo 'Host A skip-plugin-sync was not forwarded' >&2
  exit 1
fi
if ! grep -q 'LOCAL_RESTART_ARGS+=(--skip-plugin-sync)' "$CAPTURED_SSH"; then
  echo 'Host A local restart does not honor skip-plugin-sync' >&2
  exit 1
fi

echo 'skip-plugin-sync forwarding: pass'
