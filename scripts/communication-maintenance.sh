#!/usr/bin/env bash
set -euo pipefail

# Apply/rollback the ClawGate plugin while the canonical Gateway restart has it
# stopped. This script is intentionally inert unless invoked by gateway-restart.

mode="${1:-apply}"
project_path="${CLAWGATE_COMMUNICATION_PROJECT_PATH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
script_root="${CLAWGATE_COMMUNICATION_SCRIPT_ROOT:-$project_path/scripts}"
plugin_src="$project_path/extensions/openclaw-plugin"
plugin_src="${CLAWGATE_COMMUNICATION_PLUGIN_SOURCE:-$plugin_src}"
plugin_dst="${CLAWGATE_COMMUNICATION_PLUGIN_DEST:-${HOME}/.openclaw/extensions/clawgate}"
plugin_client_only="${CLAWGATE_COMMUNICATION_PLUGIN_CLIENT_ONLY:-0}"
skip_plugin_sync="${CLAWGATE_COMMUNICATION_SKIP_PLUGIN_SYNC:-0}"
candidate_files="${CLAWGATE_COMMUNICATION_CANDIDATE_FILES:-}"
candidate_root="${CLAWGATE_COMMUNICATION_CANDIDATE_ROOT:-$project_path}"
candidate_manifest="${CLAWGATE_COMMUNICATION_CANDIDATE_MANIFEST:-}"
staged_app="${CLAWGATE_COMMUNICATION_STAGED_APP:-}"
operation_id="${CLAWGATE_COMMUNICATION_OPERATION_ID:-}"
[[ "$operation_id" =~ ^[0-9a-f]{32}$ ]] || { echo "Missing or invalid communication invocation identity." >&2; exit 1; }
expected_state_dir="$project_path/.runtime/communication-maintenance/$operation_id"
state_dir="${CLAWGATE_COMMUNICATION_BACKUP_DIR:-$expected_state_dir}"
[[ "$state_dir" == "$expected_state_dir" ]] || { echo "Communication state does not match this invocation." >&2; exit 1; }
state_file="$state_dir/current-op"
case "$mode" in apply|rollback) ;; *) echo "Invalid communication maintenance mode." >&2; exit 2 ;; esac
for state_component in "$project_path/.runtime" "$project_path/.runtime/communication-maintenance" "$state_dir" "$state_file"; do
  [[ ! -L "$state_component" ]] || { echo "Symlinked communication invocation state." >&2; exit 1; }
done
# This invocation has not started any apply work. In particular, do not inspect
# a prior invocation's current-op when validation failed before state creation.
if [[ "$mode" == "rollback" && ! -e "$state_file" ]]; then
  echo "No apply state for this invocation; rollback is a no-op." >&2
  exit 0
fi

assert_no_symlink_components() {
  local base="$1" rel="$2" cursor component
  cursor="$base"
  IFS='/' read -r -a components <<< "$rel"
  for component in "${components[@]}"; do
    [[ -n "$component" && "$component" != "." && "$component" != ".." ]] || continue
    cursor="$cursor/$component"
    [[ ! -L "$cursor" ]] || { echo "Refusing symlink path component: $cursor" >&2; return 1; }
  done
}

candidate_manifest_rel=""
if [[ -n "$candidate_manifest" ]]; then
  candidate_manifest_rel="$(python3 - "$candidate_root" "$candidate_manifest" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1]).resolve()
path = pathlib.Path(sys.argv[2]).resolve()
print(path.relative_to(root))
PY
)"
fi

[[ "$plugin_dst" == /* && "$plugin_dst" != */.. && "$plugin_dst" != */../* ]] || {
  echo "Refusing unexpected plugin destination: $plugin_dst" >&2
  exit 1
}
if [[ -n "${CLAWGATE_COMMUNICATION_PLUGIN_DEST:-}" && "${CLAWGATE_COMMUNICATION_TEST_MODE:-0}" != "1" ]]; then
  echo "Plugin destination override is test-only." >&2
  exit 1
fi

case "$mode" in
  apply)
    if [[ "$skip_plugin_sync" != "1" ]]; then
      [[ -d "$plugin_src" && ! -L "$plugin_src" ]] || { echo "Missing plugin source: $plugin_src" >&2; exit 1; }
    fi
    [[ ! -L "$state_dir" ]] || { echo "Communication maintenance state directory is symlinked: $state_dir" >&2; exit 1; }
    mkdir -p "$(dirname "$state_dir")"
    mkdir "$state_dir" || { echo "Communication invocation state already exists; refusing reuse." >&2; exit 1; }
    [[ ! -L "$state_file" ]] || { echo "Communication maintenance state file is symlinked: $state_file" >&2; exit 1; }
    # Mark this invocation before path/source validation so a canonical
    # rollback cannot consume a previous successful current-op after apply
    # fails. The marker is replaced with the new backup path once preflight is
    # complete.
    printf 'in-progress\n' > "$state_file"
    backup_path="$(mktemp -d "$state_dir/op.XXXXXX")"
    files_file="$backup_path/changed-files"
    app_backup="$backup_path/ClawGate.app.previous"
    app_marker="$backup_path/app-changed"
    [[ ! -L "$plugin_dst" ]] || { echo "Plugin destination is symlinked: $plugin_dst" >&2; exit 1; }
    if [[ -d "$plugin_dst" ]] && find "$plugin_dst" -type l -print -quit | grep -q .; then
      echo "Refusing plugin destination containing symlinks: $plugin_dst" >&2
      exit 1
    fi
    if [[ -n "$candidate_files" && "$candidate_root" != "$project_path" ]]; then
      while IFS= read -r rel; do
        [[ -n "$rel" && "$rel" != "$candidate_manifest_rel" ]] || continue
        src="$candidate_root/$rel"
        dst="$project_path/$rel"
        assert_no_symlink_components "$candidate_root" "$rel"
        assert_no_symlink_components "$project_path" "$rel"
        [[ -f "$src" && ! -L "$src" ]] || { echo "Missing source candidate: $src" >&2; exit 1; }
        [[ ! -d "$dst" ]] || { echo "Refusing directory source destination: $dst" >&2; exit 1; }
        [[ ! -L "$dst" ]] || { echo "Refusing symlink source destination: $dst" >&2; exit 1; }
      done <<< "$candidate_files"
    fi
    # Publish current-op only after all admission/path checks pass. A failed
    # preflight must not leave rollback pointing at an older successful op.
    printf '%s\n' "$backup_path" > "$state_file"
    : > "$files_file"
    if [[ -n "$staged_app" ]]; then
      app_target="$project_path/ClawGate.app"
      [[ "$staged_app" == "$project_path/.runtime/"* ]] || { echo "Staged app must be under project runtime staging." >&2; exit 1; }
      [[ -d "$staged_app" && ! -L "$staged_app" ]] || { echo "Staged app is missing or symlinked: $staged_app" >&2; exit 1; }
      [[ ! -L "$app_target" ]] || { echo "Live app bundle is symlinked: $app_target" >&2; exit 1; }
      [[ -d "$app_target" ]] || { echo "Live app bundle is missing: $app_target" >&2; exit 1; }
      pkill -f "$app_target/Contents/MacOS/ClawGate" >/dev/null 2>&1 || true
      for ((wait=1; wait<=10; wait++)); do
        pgrep -f "$app_target/Contents/MacOS/ClawGate" >/dev/null 2>&1 || break
        sleep 1
      done
      if pgrep -f "$app_target/Contents/MacOS/ClawGate" >/dev/null 2>&1; then
        echo "ClawGate.app did not stop before staged swap." >&2
        exit 1
      fi
      mv "$app_target" "$app_backup"
      : > "$app_marker"
      cp -R "$staged_app" "$app_target"
    fi
    if [[ -n "$candidate_files" ]]; then
      rels=()
      while IFS= read -r rel; do
        [[ -n "$rel" && "$rel" != "$candidate_manifest_rel" ]] || continue
        # Reflect every declared source file into the checkout; plugin sync
        # flags control only the installed plugin, not source reflection.
        if [[ "$candidate_root" != "$project_path" ]]; then
          src="$candidate_root/$rel"
          dst="$project_path/$rel"
          assert_no_symlink_components "$candidate_root" "$rel"
          assert_no_symlink_components "$project_path" "$rel"
          [[ -f "$src" && ! -L "$src" ]] || { echo "Missing source candidate: $src" >&2; exit 1; }
          [[ ! -d "$dst" ]] || { echo "Refusing directory source destination: $dst" >&2; exit 1; }
          backup="$backup_path/source/$rel"
          if [[ -e "$dst" || -L "$dst" ]]; then
            [[ ! -L "$dst" ]] || { echo "Refusing symlink source destination: $dst" >&2; exit 1; }
            mkdir -p "$(dirname "$backup")"
            cp -p "$dst" "$backup"
            printf 'restore-source\t%s\n' "$rel" >> "$files_file"
          else
            printf 'remove-source\t%s\n' "$rel" >> "$files_file"
          fi
          mkdir -p "$(dirname "$dst")"
          cp -p "$src" "$dst"
        fi
        [[ "$rel" == extensions/openclaw-plugin/* ]] || continue
        [[ "$skip_plugin_sync" != "1" ]] || continue
        rel="${rel#extensions/openclaw-plugin/}"
        [[ "$plugin_client_only" != "1" || "$rel" == src/client.js ]] || continue
        rels+=("$rel")
      done <<< "$candidate_files"
      for rel in "${rels[@]}"; do
        [[ -n "$rel" ]] || continue
        [[ "$rel" != /* && "$rel" != ../* && "$rel" != */../* ]] || { echo "Invalid plugin relative path: $rel" >&2; exit 1; }
        src="$plugin_src/$rel"
        dst="$plugin_dst/$rel"
        backup="$backup_path/$rel"
        assert_no_symlink_components "$plugin_dst" "$rel"
        if [[ -L "$dst" ]]; then
          echo "Refusing symlinked plugin file: $dst" >&2
          exit 1
        fi
        if [[ -f "$dst" ]]; then
          mkdir -p "$(dirname "$backup")"
          cp -p "$dst" "$backup"
          printf 'restore\t%s\n' "$rel" >> "$files_file"
        else
          printf 'remove\t%s\n' "$rel" >> "$files_file"
        fi
        mkdir -p "$(dirname "$dst")"
        cp -p "$src" "$dst"
      done
    fi
    restart_args=(--project-path "$project_path" --skip-build --skip-sync --skip-plugin-sync)
    restart_args+=(--skip-sign)
    "$script_root/restart-local-clawgate.sh" "${restart_args[@]}"
    ;;
  rollback)
    [[ -f "$state_file" ]] || { echo "No communication maintenance backup for this invocation; rollback is a no-op." >&2; exit 0; }
    [[ ! -L "$state_file" ]] || { echo "Communication maintenance state file is symlinked: $state_file" >&2; exit 1; }
    backup_path="$(<"$state_file")"
    if [[ "$backup_path" == "in-progress" ]]; then
      echo "No completed communication maintenance operation to roll back." >&2
      exit 0
    fi
    [[ "$backup_path" == "$state_dir"/op.* && "${backup_path#"$state_dir"/}" != */* && ! -L "$backup_path" ]] || {
      echo "Rollback backup is not owned by this invocation." >&2
      exit 1
    }
    files_file="$backup_path/changed-files"
    [[ -d "$backup_path" ]] || { echo "Communication maintenance backup is missing: $backup_path" >&2; exit 1; }
    [[ -f "$files_file" ]] || { echo "Communication maintenance changed-file manifest is missing." >&2; exit 1; }
    if [[ -f "$backup_path/app-changed" ]]; then
      app_target="$project_path/ClawGate.app"
      [[ ! -L "$app_target" ]] || { echo "Live app bundle is symlinked: $app_target" >&2; exit 1; }
      [[ -d "$backup_path/ClawGate.app.previous" ]] || { echo "App rollback backup is missing." >&2; exit 1; }
      pkill -f "$app_target/Contents/MacOS/ClawGate" >/dev/null 2>&1 || true
      for ((wait=1; wait<=10; wait++)); do
        pgrep -f "$app_target/Contents/MacOS/ClawGate" >/dev/null 2>&1 || break
        sleep 1
      done
      if pgrep -f "$app_target/Contents/MacOS/ClawGate" >/dev/null 2>&1; then
        echo "ClawGate.app did not stop before rollback." >&2
        exit 1
      fi
      if [[ -e "$app_target" ]]; then
        mv "$app_target" "$backup_path/ClawGate.app.failed"
      fi
      mv "$backup_path/ClawGate.app.previous" "$app_target"
    fi
    while IFS=$'\t' read -r action rel; do
      [[ -n "$rel" ]] || continue
      [[ "$rel" != /* && "$rel" != ../* && "$rel" != */../* ]] || { echo "Invalid rollback relative path: $rel" >&2; exit 1; }
      dst="$plugin_dst/$rel"
      case "$action" in
        restore)
          assert_no_symlink_components "$plugin_dst" "$rel"
          mkdir -p "$(dirname "$dst")"
          cp -p "$backup_path/$rel" "$dst"
          ;;
        remove)
          assert_no_symlink_components "$plugin_dst" "$rel"
          [[ ! -L "$dst" ]] || { echo "Refusing symlinked rollback file: $dst" >&2; exit 1; }
          rm -f "$dst"
          ;;
        restore-source)
          dst="$project_path/$rel"
          assert_no_symlink_components "$project_path" "$rel"
          mkdir -p "$(dirname "$dst")"
          cp -p "$backup_path/source/$rel" "$dst"
          ;;
        remove-source)
          dst="$project_path/$rel"
          assert_no_symlink_components "$project_path" "$rel"
          [[ ! -L "$dst" ]] || { echo "Refusing symlink rollback file: $dst" >&2; exit 1; }
          rm -f "$dst"
          ;;
        *) echo "Unknown changed-file action: $action" >&2; exit 1 ;;
      esac
    done < "$files_file"
    restart_args=(--project-path "$project_path" --skip-build --skip-sync --skip-plugin-sync --skip-sign)
    "$script_root/restart-local-clawgate.sh" "${restart_args[@]}"
    ;;
  *)
    echo "Usage: $0 [apply|rollback]" >&2
    exit 2
    ;;
esac
