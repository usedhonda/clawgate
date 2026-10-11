#!/usr/bin/env bash
set -euo pipefail

REMOTE_HOST=""
PROJECT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote-host) REMOTE_HOST="$2"; shift 2 ;;
    --project-path) PROJECT_PATH="$2"; shift 2 ;;
    --manifest) MANIFEST="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$REMOTE_HOST" && -n "$MANIFEST" ]] || { echo "--remote-host and --manifest are required" >&2; exit 2; }
cd "$PROJECT_PATH"
export CLAWGATE_COMMUNICATION_CANDIDATE_MANIFEST="$MANIFEST"
export CLAWGATE_COMMUNICATION_CANDIDATE_ROOT="$PROJECT_PATH"
source "$PROJECT_PATH/scripts/lib-communication-restart.sh"
communication_validate_candidate
files_from="$(mktemp)"
trap 'rm -f "$files_from"' EXIT
communication_candidate_files_from > "$files_from"
candidate_id="$(shasum -a 256 "$MANIFEST" | awk '{print substr($1,1,16)}')"
remote_stage="$PROJECT_PATH/.runtime/communication-candidate-$candidate_id"
required_scripts=(
  scripts/lib-ops-log.sh scripts/lib-communication-restart.sh
  scripts/communication-candidate.py
  scripts/communication-maintenance.sh scripts/communication-maintenance-apply.sh
  scripts/communication-maintenance-rollback.sh scripts/restart-local-clawgate.sh
  scripts/macmini-local-sign-and-restart.sh
)
for required in "${required_scripts[@]}"; do
  grep -Fxq "$required" "$files_from" || { echo "candidate manifest must declare $required" >&2; exit 1; }
done
printf -v project_path_q '%q' "$PROJECT_PATH"
printf -v remote_stage_q '%q' "$remote_stage"
ssh "$REMOTE_HOST" "bash -s -- $project_path_q $remote_stage_q" <<'REMOTE_STAGE_GUARD'
set -euo pipefail
project_path="$1"
remote_stage="$2"
python3 - "$project_path" "$remote_stage" <<'PY'
import pathlib, sys
project = pathlib.Path(sys.argv[1]).resolve()
stage = pathlib.Path(sys.argv[2])
if stage.is_symlink():
    raise SystemExit(f"refusing symlink stage destination: {stage}")
parent = stage.parent
if parent.is_symlink():
    raise SystemExit(f"refusing symlink stage parent: {parent}")
parent_resolved = parent.resolve()
if not parent_resolved.is_relative_to(project):
    raise SystemExit(f"stage destination escapes project: {stage}")
if parent_resolved != parent:
    raise SystemExit(f"refusing symlink stage component: {parent}")
parent.mkdir(parents=True, exist_ok=True)
if stage.exists() and not stage.is_dir():
    raise SystemExit(f"stage destination is not a directory: {stage}")
stage.mkdir(exist_ok=True)
if stage.resolve() != stage:
    raise SystemExit(f"stage destination resolved unexpectedly: {stage}")
PY
REMOTE_STAGE_GUARD
printf -v remote_stage_rsync_q '%q' "$remote_stage"
rsync -az --files-from="$files_from" --exclude .git/ --exclude .local/secrets/ "$PROJECT_PATH/" "$REMOTE_HOST:$remote_stage_rsync_q/"
printf -v remote_stage_q '%q' "$remote_stage"
verify_command="bash -s -- $remote_stage_q"
for required in "${required_scripts[@]}"; do
  printf -v required_q '%q' "$required"
  verify_command+=" $required_q"
done
ssh "$REMOTE_HOST" "$verify_command" <<'REMOTE_STAGE_VERIFY'
set -euo pipefail
stage="$1"
shift
[[ -d "$stage" && ! -L "$stage" ]] || { echo "staged destination changed during transfer" >&2; exit 1; }
for f in "$@"; do
  [[ -f "$stage/$f" && ! -L "$stage/$f" ]] || { echo "missing-staged-script:$f" >&2; exit 1; }
done
REMOTE_STAGE_VERIFY
printf '%s\n' "$remote_stage"
