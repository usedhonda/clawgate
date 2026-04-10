#!/usr/bin/env bash
set -euo pipefail

# Bootstrap ClawGate Dev signing cert on remote macmini.
#
# Usage:
#   KEYCHAIN_PASSWORD='your-login-password' ./scripts/setup-cert-macmini.sh
#   KEYCHAIN_PASSWORD='...' ./scripts/setup-cert-macmini.sh --remote-host macmini --project-path "$(pwd)"
#
# Notes:
# - KEYCHAIN_PASSWORD is required for non-interactive keychain unlock/partition setup.
# - This script does not modify host app binaries; it only prepares certificate/trust.

REMOTE_HOST="macmini"
SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
PROJECT_PATH="${PROJECT_PATH:-$(cd "$SCRIPT_DIR/.." && pwd)}"
RESET=false
KEYCHAIN_PASSWORD="${KEYCHAIN_PASSWORD:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --remote-host)
      REMOTE_HOST="$2"; shift 2 ;;
    --project-path)
      PROJECT_PATH="$2"; shift 2 ;;
    --reset)
      RESET=true; shift ;;
    --keychain-password)
      KEYCHAIN_PASSWORD="$2"; shift 2 ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 2 ;;
  esac
done

if [[ -z "$KEYCHAIN_PASSWORD" ]]; then
  echo "KEYCHAIN_PASSWORD is required. Export it or pass --keychain-password." >&2
  exit 1
fi

RESET_ARG=""
if [[ "$RESET" == "true" ]]; then
  RESET_ARG="1"
fi

echo "Remote host: $REMOTE_HOST"
echo "Project path: $PROJECT_PATH"

echo "Sync latest setup-cert.sh to remote"
ssh "$REMOTE_HOST" "mkdir -p '$PROJECT_PATH/scripts'"
scp ./scripts/setup-cert.sh "$REMOTE_HOST:$PROJECT_PATH/scripts/setup-cert.sh" >/dev/null
ssh "$REMOTE_HOST" "chmod +x '$PROJECT_PATH/scripts/setup-cert.sh'"

ssh "$REMOTE_HOST" /bin/zsh -s -- "$PROJECT_PATH" "$KEYCHAIN_PASSWORD" "$RESET_ARG" <<'EOF'
set -euo pipefail

PROJECT_PATH="$1"
KEYCHAIN_PASSWORD="$2"
RESET_FLAG="${3:-0}"

cd "$PROJECT_PATH"
supports_non_interactive=0
if ./scripts/setup-cert.sh --help 2>&1 | grep -q "non-interactive"; then
  supports_non_interactive=1
fi
if [[ "$RESET_FLAG" == "1" ]]; then
  if [[ "$supports_non_interactive" == "1" ]]; then
    ./scripts/setup-cert.sh --reset --non-interactive --keychain-password "$KEYCHAIN_PASSWORD"
  else
    ./scripts/setup-cert.sh --reset
  fi
else
  if [[ "$supports_non_interactive" == "1" ]]; then
    ./scripts/setup-cert.sh --non-interactive --keychain-password "$KEYCHAIN_PASSWORD"
  else
    ./scripts/setup-cert.sh
  fi
fi
security find-identity -v -p codesigning | grep "ClawGate Dev" || true
EOF

echo "Done."
