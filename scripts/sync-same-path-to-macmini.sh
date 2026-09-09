#!/bin/bash
# Sync current repository to the exact same absolute path on host "macmini".
#
# Usage:
#   ./scripts/sync-same-path-to-macmini.sh
#   ./scripts/sync-same-path-to-macmini.sh --remote-host macmini --dry-run
#   ./scripts/sync-same-path-to-macmini.sh --files-from .local/sync-files.txt

set -euo pipefail

DRY_RUN=false
FILES_FROM=""
LOCAL_PATH="$(pwd)"
REMOTE_HOST="macmini"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --files-from)
      FILES_FROM="$2"
      shift 2
      ;;
    --remote-host)
      REMOTE_HOST="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ "$LOCAL_PATH" != /Users/* ]]; then
  echo "Expected local path under /Users/*, got: $LOCAL_PATH" >&2
  exit 2
fi

echo "Sync source: $LOCAL_PATH"
echo "Sync target: $REMOTE_HOST:$LOCAL_PATH"

SSH_CMD=(ssh "$REMOTE_HOST")
if [[ -n "$FILES_FROM" ]]; then
  if [[ ! -f "$FILES_FROM" ]]; then
    echo "Files-from list must be an existing regular file: $FILES_FROM" >&2
    exit 2
  fi

  while IFS= read -r entry || [[ -n "$entry" ]]; do
    [[ -z "$entry" ]] && continue
    if [[ "$entry" == /* || "$entry" =~ (^|/)\.\.(\/|$) || "$entry" =~ (^|/)\.git(\/|$) || "$entry" =~ (^|/)\.local/secrets(\/|$) ]]; then
      echo "Invalid files-from entry: $entry" >&2
      exit 2
    fi
    if [[ ! -f "$LOCAL_PATH/$entry" || -L "$LOCAL_PATH/$entry" ]]; then
      echo "Files-from entry must be an existing regular file: $entry" >&2
      exit 2
    fi
  done < "$FILES_FROM"

  RSYNC_CMD=(rsync -az --files-from="$FILES_FROM")
else
  RSYNC_CMD=(rsync -az --delete)
fi

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
  # App bundles are architecture-specific; remote host must keep its own built app.
  --exclude ClawGate.app/
  "$LOCAL_PATH/"
  "$REMOTE_HOST:$LOCAL_PATH/"
)

"${SSH_CMD[@]}" "mkdir -p '$LOCAL_PATH'"
"${RSYNC_CMD[@]}"

echo "Done."
