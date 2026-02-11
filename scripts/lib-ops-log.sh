#!/usr/bin/env bash
set -euo pipefail

# Lightweight operational logger shared by restart/watch scripts.
# Appends newline-delimited JSON records to docs/log/ops.

ops_log_dir_default() {
  local root="${PROJECT_PATH:-$(pwd)}"
  printf '%s/docs/log/ops' "$root"
}

ops_log_file_default() {
  local dir
  dir="$(ops_log_dir_default)"
  printf '%s/%s-ops.log' "$dir" "$(date +%Y%m%d)"
}

ops_log_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

ops_log() {
  local level="${1:-info}"
  local event="${2:-event}"
  local message="${3:-}"

  local role="${CLAWGATE_ROLE:-unknown}"
  local script_name="${OPS_SCRIPT_NAME:-$(basename "$0")}"
  local host_name
  host_name="$(hostname -s 2>/dev/null || hostname)"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local log_dir="${OPS_LOG_DIR:-$(ops_log_dir_default)}"
  local log_file="${OPS_LOG_FILE:-$(ops_log_file_default)}"
  mkdir -p "$log_dir"

  local level_e event_e msg_e role_e script_e host_e
  level_e="$(ops_log_json_escape "$level")"
  event_e="$(ops_log_json_escape "$event")"
  msg_e="$(ops_log_json_escape "$message")"
  role_e="$(ops_log_json_escape "$role")"
  script_e="$(ops_log_json_escape "$script_name")"
  host_e="$(ops_log_json_escape "$host_name")"

  printf '{"ts":"%s","level":"%s","event":"%s","role":"%s","host":"%s","script":"%s","message":"%s"}\n' \
    "$ts" "$level_e" "$event_e" "$role_e" "$host_e" "$script_e" "$msg_e" >> "$log_file"
}
