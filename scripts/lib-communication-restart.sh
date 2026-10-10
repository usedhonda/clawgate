#!/usr/bin/env bash

# Shared Gateway communication admission wrapper.
# The canonical interface is owned by oc-general/scripts/gateway-restart.

communication_admission_requested() {
  [[ -n "${GATEWAY_RESTART_COMMUNICATION_MANIFEST:-}" || -n "${GATEWAY_RESTART_COMMUNICATION_CURRENT:-}" ]]
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
  GATEWAY_RESTART_COMMUNICATION_MANIFEST="${GATEWAY_RESTART_COMMUNICATION_MANIFEST:-}" \
  GATEWAY_RESTART_COMMUNICATION_CURRENT="${GATEWAY_RESTART_COMMUNICATION_CURRENT:-}" \
  GATEWAY_RESTART_MAINTENANCE_HOOK="$maintenance_hook" \
  GATEWAY_RESTART_MAINTENANCE_ROLLBACK_HOOK="$rollback_hook" \
    "$gateway_restart"
}
