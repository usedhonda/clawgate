#!/usr/bin/env bash
set -euo pipefail

# Apply/rollback the ClawGate plugin while the canonical Gateway restart has it
# stopped. This script is intentionally inert unless invoked by gateway-restart.

mode="${1:-apply}"
project_path="${CLAWGATE_COMMUNICATION_PROJECT_PATH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
plugin_src="$project_path/extensions/openclaw-plugin"
plugin_dst="${HOME}/.openclaw/extensions/clawgate"
plugin_client_only="${CLAWGATE_COMMUNICATION_PLUGIN_CLIENT_ONLY:-0}"
skip_plugin_sync="${CLAWGATE_COMMUNICATION_SKIP_PLUGIN_SYNC:-0}"
state_dir="${CLAWGATE_COMMUNICATION_BACKUP_DIR:-$project_path/.runtime/communication-maintenance}"
state_file="$state_dir/current-op"

[[ "$plugin_dst" == "$HOME/.openclaw/extensions/clawgate" ]] || {
  echo "Refusing unexpected plugin destination: $plugin_dst" >&2
  exit 1
}

case "$mode" in
  apply)
    [[ -d "$plugin_src" && ! -L "$plugin_src" ]] || { echo "Missing plugin source: $plugin_src" >&2; exit 1; }
    [[ ! -L "$state_dir" ]] || { echo "Communication maintenance state directory is symlinked: $state_dir" >&2; exit 1; }
    mkdir -p "$state_dir"
    [[ ! -L "$state_file" ]] || { echo "Communication maintenance state file is symlinked: $state_file" >&2; exit 1; }
    backup_path="$(mktemp -d "$state_dir/op.XXXXXX")"
    files_file="$backup_path/changed-files"
    printf '%s\n' "$backup_path" > "$state_file"
    [[ ! -L "$plugin_dst" ]] || { echo "Plugin destination is symlinked: $plugin_dst" >&2; exit 1; }
    if [[ -d "$plugin_dst" ]] && find "$plugin_dst" -type l -print -quit | grep -q .; then
      echo "Refusing plugin destination containing symlinks: $plugin_dst" >&2
      exit 1
    fi
    : > "$files_file"
    if [[ "$skip_plugin_sync" != "1" ]]; then
      rels=()
      if [[ "$plugin_client_only" == "1" ]]; then
        rels=(src/client.js)
      else
        while IFS= read -r rel; do
          [[ -n "$rel" ]] && rels+=("$rel")
        done < <(cd "$plugin_src" && find . -type f -print | sed 's#^./##')
      fi
      for rel in "${rels[@]}"; do
        [[ -n "$rel" ]] || continue
        [[ "$rel" != /* && "$rel" != ../* && "$rel" != */../* ]] || { echo "Invalid plugin relative path: $rel" >&2; exit 1; }
        src="$plugin_src/$rel"
        dst="$plugin_dst/$rel"
        backup="$backup_path/$rel"
        if [[ -L "$dst" ]]; then
          echo "Refusing symlinked plugin file: $dst" >&2
          exit 1
        fi
        if [[ -f "$dst" ]]; then
          mkdir -p "$(dirname "$backup")"
          cp "$dst" "$backup"
          printf 'restore\t%s\n' "$rel" >> "$files_file"
        else
          printf 'remove\t%s\n' "$rel" >> "$files_file"
        fi
        mkdir -p "$(dirname "$dst")"
        cp "$src" "$dst"
      done
    fi
    restart_args=(--project-path "$project_path" --skip-build --skip-sync --skip-plugin-sync)
    restart_args+=(--skip-sign)
    "$project_path/scripts/restart-local-clawgate.sh" "${restart_args[@]}"
    ;;
  rollback)
    [[ -f "$state_file" ]] || { echo "No communication maintenance backup found." >&2; exit 1; }
    [[ ! -L "$state_file" ]] || { echo "Communication maintenance state file is symlinked: $state_file" >&2; exit 1; }
    backup_path="$(<"$state_file")"
    files_file="$backup_path/changed-files"
    [[ -d "$backup_path" ]] || { echo "Communication maintenance backup is missing: $backup_path" >&2; exit 1; }
    [[ -f "$files_file" ]] || { echo "Communication maintenance changed-file manifest is missing." >&2; exit 1; }
    while IFS=$'\t' read -r action rel; do
      [[ -n "$rel" ]] || continue
      [[ "$rel" != /* && "$rel" != ../* && "$rel" != */../* ]] || { echo "Invalid rollback relative path: $rel" >&2; exit 1; }
      dst="$plugin_dst/$rel"
      case "$action" in
        restore)
          mkdir -p "$(dirname "$dst")"
          cp "$backup_path/$rel" "$dst"
          ;;
        remove)
          [[ ! -L "$dst" ]] || { echo "Refusing symlinked rollback file: $dst" >&2; exit 1; }
          rm -f "$dst"
          ;;
        *) echo "Unknown changed-file action: $action" >&2; exit 1 ;;
      esac
    done < "$files_file"
    ;;
  *)
    echo "Usage: $0 [apply|rollback]" >&2
    exit 2
    ;;
esac
