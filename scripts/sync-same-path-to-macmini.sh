#!/bin/bash
# Sync current repository to the exact same absolute path on host "macmini".
#
# Usage:
#   ./scripts/sync-same-path-to-macmini.sh
#   ./scripts/sync-same-path-to-macmini.sh --dry-run

set -euo pipefail

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
fi

LOCAL_PATH="$(pwd)"
REMOTE_HOST="macmini"

if [[ "$LOCAL_PATH" != /Users/* ]]; then
  echo "Expected local path under /Users/*, got: $LOCAL_PATH" >&2
  exit 2
fi

echo "Sync source: $LOCAL_PATH"
echo "Sync target: $REMOTE_HOST:$LOCAL_PATH"

SSH_CMD=(ssh "$REMOTE_HOST")
RSYNC_CMD=(rsync -az --delete)

if [[ "$DRY_RUN" == "true" ]]; then
  RSYNC_CMD+=(--dry-run)
fi

RSYNC_CMD+=(
  --exclude .git/
  --exclude .build/
  --exclude .swiftpm/
  --exclude DerivedData/
  --exclude '*.xcuserstate'
  --exclude '*.xcuserdata/'
  --exclude docs/log/
  "$LOCAL_PATH/"
  "$REMOTE_HOST:$LOCAL_PATH/"
)

"${SSH_CMD[@]}" "mkdir -p '$LOCAL_PATH'"
"${RSYNC_CMD[@]}"

echo "Done."
