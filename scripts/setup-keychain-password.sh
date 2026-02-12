#!/usr/bin/env bash
set -euo pipefail
# Create .local/secrets/keychain-password for macmini SSH signing.
# Usage: ./scripts/setup-keychain-password.sh

PROJECT_PATH="$(cd "$(dirname "$0")/.." && pwd)"
SECRET_DIR="$PROJECT_PATH/.local/secrets"
SECRET_FILE="$SECRET_DIR/keychain-password"

if [ -f "$SECRET_FILE" ]; then
  echo "Already exists: $SECRET_FILE"
  exit 0
fi

mkdir -p "$SECRET_DIR"
printf "Enter macmini login password: "
read -rs PASSWORD
echo

printf "%s" "$PASSWORD" > "$SECRET_FILE"
chmod 600 "$SECRET_FILE"
echo "Saved to $SECRET_FILE"
