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
source "$PROJECT_PATH/scripts/lib-communication-restart.sh"
CLAWGATE_COMMUNICATION_CANDIDATE_MANIFEST="$MANIFEST" communication_validate_candidate
files_from="$(mktemp)"
trap 'rm -f "$files_from"' EXIT
CLAWGATE_COMMUNICATION_CANDIDATE_MANIFEST="$MANIFEST" communication_candidate_files_from > "$files_from"
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
ssh "$REMOTE_HOST" "mkdir -p '$remote_stage'"
rsync -az --files-from="$files_from" --exclude .git/ --exclude .local/secrets/ "$PROJECT_PATH/" "$REMOTE_HOST:$remote_stage/"
ssh "$REMOTE_HOST" "for f in ${required_scripts[*]}; do test -f \"$remote_stage/\$f\" || { echo missing-staged-script:\$f >&2; exit 1; }; done"
printf '%s\n' "$remote_stage"
