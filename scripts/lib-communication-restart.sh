#!/usr/bin/env bash

# Shared Gateway communication admission wrapper.
# The canonical interface is owned by oc-general/scripts/gateway-restart.

communication_admission_requested() {
  [[ -n "${GATEWAY_RESTART_COMMUNICATION_MANIFEST:-}" || -n "${GATEWAY_RESTART_COMMUNICATION_CURRENT:-}" ]]
}

communication_validate_candidate() {
  local communication_candidate_manifest="${CLAWGATE_COMMUNICATION_CANDIDATE_MANIFEST:-}"
  [[ -n "$communication_candidate_manifest" ]] || {
    echo "Communication candidate manifest is required for staged apply." >&2
    return 1
  }
  [[ -f "$communication_candidate_manifest" && ! -L "$communication_candidate_manifest" ]] || {
    echo "Communication candidate manifest is missing or symlinked: $communication_candidate_manifest" >&2
    return 1
  }
  python3 - "${CLAWGATE_COMMUNICATION_CANDIDATE_ROOT:-$PWD}" "$communication_candidate_manifest" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1]).resolve()
path = pathlib.Path(sys.argv[2]).resolve()
if not path.is_relative_to(root):
    raise SystemExit("candidate manifest must be inside the project")
PY
  local candidate_root="${CLAWGATE_COMMUNICATION_CANDIDATE_ROOT:-$PWD}"
  python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/communication-candidate.py" --manifest "$communication_candidate_manifest" --root "$candidate_root" >/dev/null
}

communication_candidate_files_from() {
  local communication_candidate_manifest="${CLAWGATE_COMMUNICATION_CANDIDATE_MANIFEST:-}"
  communication_validate_candidate
  local candidate_root="${CLAWGATE_COMMUNICATION_CANDIDATE_ROOT:-$PWD}"
  python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/communication-candidate.py" --manifest "$communication_candidate_manifest" --root "$candidate_root"
  python3 - "$PWD" "$communication_candidate_manifest" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1]).resolve()
print(pathlib.Path(sys.argv[2]).resolve().relative_to(root))
PY
}

communication_require_admission() {
  local manifest="${GATEWAY_RESTART_COMMUNICATION_MANIFEST:-}"
  local current="${GATEWAY_RESTART_COMMUNICATION_CURRENT:-}"
  if [[ -n "$manifest" || -n "$current" ]]; then
    if [[ -z "$manifest" || -z "$current" ]]; then
      echo "Communication admission requires both GATEWAY_RESTART_COMMUNICATION_MANIFEST and GATEWAY_RESTART_COMMUNICATION_CURRENT." >&2
      return 1
    fi
  fi
}

communication_preflight() {
  communication_require_admission
  communication_admission_requested || return 0
  local gateway_restart="${CLAWGATE_GATEWAY_RESTART_SCRIPT:-$HOME/projects/openclaw/oc-general/scripts/gateway-restart}"
  local check_script="${CLAWGATE_COMMUNICATION_CHECK_SCRIPT:-$(cd "$(dirname "$gateway_restart")" 2>/dev/null && pwd)/check-communication-change}"
  if [[ ! -f "$check_script" ]]; then
    echo "Canonical communication check is unavailable: $check_script" >&2
    return 1
  fi
  python3 "$check_script" \
    --manifest "$GATEWAY_RESTART_COMMUNICATION_MANIFEST" \
    --current "$GATEWAY_RESTART_COMMUNICATION_CURRENT"
}

communication_gateway_restart() {
  communication_require_admission
  local gateway_restart="${CLAWGATE_GATEWAY_RESTART_SCRIPT:-$HOME/projects/openclaw/oc-general/scripts/gateway-restart}"
  local project_path="${CLAWGATE_COMMUNICATION_PROJECT_PATH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  local maintenance_hook="${CLAWGATE_COMMUNICATION_MAINTENANCE_HOOK:-$project_path/scripts/communication-maintenance-apply.sh}"
  local rollback_hook="${CLAWGATE_COMMUNICATION_ROLLBACK_HOOK:-$project_path/scripts/communication-maintenance-rollback.sh}"
  if [[ ! -x "$gateway_restart" ]]; then
    echo "Canonical gateway-restart is unavailable or not executable: $gateway_restart" >&2
    return 1
  fi
  if [[ -n "$maintenance_hook" && -z "$rollback_hook" ]]; then
    echo "Communication maintenance requires a paired rollback hook." >&2
    return 1
  fi
  local operation_id="${CLAWGATE_COMMUNICATION_OPERATION_ID:-}"
  if [[ -z "$operation_id" ]]; then
    operation_id="$(printf '%s\n' "${GATEWAY_RESTART_COMMUNICATION_MANIFEST:-}" "${GATEWAY_RESTART_COMMUNICATION_CURRENT:-}" "$$" "$(date +%s%N 2>/dev/null || date +%s)" | shasum -a 256 | awk '{print substr($1,1,24)}')"
  fi
  [[ "$operation_id" =~ ^[A-Za-z0-9._-]+$ ]] || {
    echo "Invalid communication operation id: $operation_id" >&2
    return 1
  }
  local backup_dir="${CLAWGATE_COMMUNICATION_BACKUP_DIR:-$project_path/.runtime/communication-maintenance/$operation_id}"
  GATEWAY_RESTART_COMMUNICATION_MANIFEST="${GATEWAY_RESTART_COMMUNICATION_MANIFEST:-}" \
  GATEWAY_RESTART_COMMUNICATION_CURRENT="${GATEWAY_RESTART_COMMUNICATION_CURRENT:-}" \
  CLAWGATE_COMMUNICATION_OPERATION_ID="$operation_id" \
  CLAWGATE_COMMUNICATION_BACKUP_DIR="$backup_dir" \
  GATEWAY_RESTART_MAINTENANCE_HOOK="$maintenance_hook" \
  GATEWAY_RESTART_MAINTENANCE_ROLLBACK_HOOK="$rollback_hook" \
    "$gateway_restart"
}
