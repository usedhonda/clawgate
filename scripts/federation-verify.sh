#!/usr/bin/env bash
set -euo pipefail

# Verify Host B relay/federation path separately from LINE-core recovery.
#
# Usage:
#   ./scripts/federation-verify.sh
#   ./scripts/federation-verify.sh --wait-seconds 20

WAIT_SECONDS=20

while [[ $# -gt 0 ]]; do
  case "$1" in
    --wait-seconds)
      WAIT_SECONDS="$2"; shift 2 ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 2 ;;
  esac
done

echo "== federation-verify =="
echo "wait-seconds: $WAIT_SECONDS"

HEALTH=""
for _ in $(seq 1 "$WAIT_SECONDS"); do
  HEALTH="$(curl -sS -m 3 http://127.0.0.1:9765/v1/health || true)"
  if [[ -n "$HEALTH" ]]; then
    break
  fi
  sleep 1
done

if [[ -z "$HEALTH" ]]; then
  echo "ERROR: relay health endpoint is unavailable (127.0.0.1:9765)." >&2
  exit 1
fi

echo "$HEALTH"

FED_CONNECTED="$(python3 - "$HEALTH" <<'PY'
import json, sys
try:
    d = json.loads(sys.argv[1])
    print("1" if d.get("federation_connected") is True else "0")
except Exception:
    print("0")
PY
)"

if [[ "$FED_CONNECTED" != "1" ]]; then
  echo "ERROR: federation_connected=false" >&2
  exit 1
fi

echo "OK: federation path is connected."
