#!/usr/bin/env bash
set -euo pipefail

# Apply/rollback the ClawGate plugin while the canonical Gateway restart has it
# stopped. This script is intentionally inert unless invoked by gateway-restart.

mode="${1:-apply}"
project_path="${CLAWGATE_COMMUNICATION_PROJECT_PATH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
plugin_src="$project_path/extensions/openclaw-plugin"
plugin_dst="${HOME}/.openclaw/extensions/clawgate"
plugin_client_only="${CLAWGATE_COMMUNICATION_PLUGIN_CLIENT_ONLY:-0}"
state_dir="${CLAWGATE_COMMUNICATION_BACKUP_DIR:-${TMPDIR:-/tmp}/clawgate-communication-maintenance}"
state_file="$state_dir/backup-path"

case "$mode" in
  apply)
    [[ -d "$plugin_src" && ! -L "$plugin_src" ]] || { echo "Missing plugin source: $plugin_src" >&2; exit 1; }
    mkdir -p "$state_dir"
    backup_path="$(mktemp -d "$state_dir/backup.XXXXXX")"
    if [[ -d "$plugin_dst" && ! -L "$plugin_dst" ]]; then
      rsync -a "$plugin_dst/" "$backup_path/"
    fi
    printf '%s\n' "$backup_path" > "$state_file"
    mkdir -p "$plugin_dst"
    if [[ "$plugin_client_only" == "1" ]]; then
      [[ -f "$plugin_src/src/client.js" && -f "$plugin_dst/src/client.js" ]] || {
        echo "Plugin client source/destination is missing." >&2
        exit 1
      }
      cp "$plugin_src/src/client.js" "$plugin_dst/src/client.js"
    else
      rsync -a --delete "$plugin_src/" "$plugin_dst/"
    fi
    restart_args=(--project-path "$project_path" --skip-build --skip-sync --skip-plugin-sync)
    "$project_path/scripts/restart-local-clawgate.sh" "${restart_args[@]}"
    ;;
  rollback)
    [[ -f "$state_file" ]] || { echo "No communication maintenance backup found." >&2; exit 1; }
    backup_path="$(<"$state_file")"
    [[ -d "$backup_path" ]] || { echo "Communication maintenance backup is missing: $backup_path" >&2; exit 1; }
    mkdir -p "$plugin_dst"
    rsync -a --delete "$backup_path/" "$plugin_dst/"
    ;;
  *)
    echo "Usage: $0 [apply|rollback]" >&2
    exit 2
    ;;
esac
