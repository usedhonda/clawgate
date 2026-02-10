#!/bin/bash
# User-side proxy runner for environments where the agent cannot open SSH itself.
#
# This script runs the remote relay + E2E workflow from your local terminal,
# then stores all outputs under docs/tmp/remote-run/ so the agent can read them.
#
# Usage:
#   ./scripts/proxy-macmini-e2e.sh \
#     --gateway-token GATEWAY_TOKEN \
#     --federation-token FED_TOKEN \
#     --tmux-project your-project \
#     --line-hint "Your Contact"

set -euo pipefail

OUT_DIR="docs/tmp/remote-run"
TS="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="$OUT_DIR/$TS"
LATEST_LINK="$OUT_DIR/latest"

mkdir -p "$RUN_DIR"

CMD=(./scripts/run-macmini-relay-and-e2e.sh "$@")

{
  echo "timestamp=$TS"
  echo "pwd=$(pwd)"
  echo "command=${CMD[*]}"
} > "$RUN_DIR/meta.env"

set +e
"${CMD[@]}" > "$RUN_DIR/stdout.log" 2> "$RUN_DIR/stderr.log"
STATUS=$?
set -e

echo "$STATUS" > "$RUN_DIR/exit_code.txt"

# Snapshot remote relay logs if SSH works from user terminal.
if ssh -o ConnectTimeout=8 macmini 'echo ok' >/dev/null 2>&1; then
  ssh macmini 'tail -n 200 /tmp/clawgate-relay.log' > "$RUN_DIR/relay.log" 2>/dev/null || true
  ssh macmini 'tail -n 200 ~/.openclaw/logs/gateway.log' > "$RUN_DIR/openclaw-gateway.log" 2>/dev/null || true
fi

rm -f "$LATEST_LINK"
ln -s "$TS" "$LATEST_LINK"

cat > "$RUN_DIR/summary.txt" <<SUM
run_dir=$RUN_DIR
exit_code=$STATUS
stdout=$RUN_DIR/stdout.log
stderr=$RUN_DIR/stderr.log
relay_log=$RUN_DIR/relay.log
openclaw_gateway_log=$RUN_DIR/openclaw-gateway.log
SUM

cat "$RUN_DIR/summary.txt"
exit "$STATUS"
