#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TRACE_ID="${1:-}"
NOW_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
OUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/clawgate-support.XXXXXX")"
OUT_FILE="${OUT_DIR}/diagnostics.txt"

latest_ops_log() {
  ls -1t "$PROJECT_DIR"/docs/log/ops/*-ops.log 2>/dev/null | head -n 1 || true
}

append() {
  printf '%s\n' "$1" >> "$OUT_FILE"
}

append "# ClawGate Diagnostics"
append "generated_at_utc: ${NOW_UTC}"
append "project_dir: ${PROJECT_DIR}"
append "trace_id: ${TRACE_ID:-<none>}"
append ""

append "## Binary"
if [[ -x "$PROJECT_DIR/ClawGate.app/Contents/MacOS/ClawGate" ]]; then
  file "$PROJECT_DIR/ClawGate.app/Contents/MacOS/ClawGate" >> "$OUT_FILE" 2>&1 || true
  append ""
  append "codesign_authority:"
  codesign -dv --verbose=4 "$PROJECT_DIR/ClawGate.app" >> "$OUT_FILE" 2>&1 || true
else
  append "ClawGate.app binary not found"
fi
append ""

append "## Local API"
for path in /v1/health /v1/doctor /v1/stats; do
  append "### GET ${path}"
  curl --silent --show-error --connect-timeout 2 --max-time 10 \
    "http://127.0.0.1:8765${path}" >> "$OUT_FILE" 2>&1 || append "curl_failed"
  append ""
done

OPS_LOG="$(latest_ops_log)"
append "## Ops log"
append "latest_log: ${OPS_LOG:-<none>}"
append ""

if [[ -n "$OPS_LOG" && -f "$OPS_LOG" ]]; then
  append "### Last 120 lines"
  tail -n 120 "$OPS_LOG" >> "$OUT_FILE" || true
  append ""

  if [[ -n "$TRACE_ID" ]]; then
    append "### Trace filter (${TRACE_ID})"
    grep -r -n -F -- "$TRACE_ID" "$PROJECT_DIR/docs/log/ops" >> "$OUT_FILE" || append "trace_not_found"
    append ""
  fi
fi

append "## Process"
# Command arguments can contain credentials or message text. Collect only the
# executable names and process IDs, never the full argv or environment.
ps -axo pid=,ppid=,comm= | grep -E 'ClawGate|openclaw|gateway' >> "$OUT_FILE" || append "no_matching_process"
append ""

echo "$OUT_FILE"
