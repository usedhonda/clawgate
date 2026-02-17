#!/usr/bin/env bash
#
# Install repo-local pre-commit hooks for leak guard.
#
# Usage:
#   ./scripts/setup-git-hooks.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
HOOKS_DIR="$PROJECT_DIR/.git/hooks"
HOOK_PATH="$HOOKS_DIR/pre-commit"

if [[ ! -d "$PROJECT_DIR/.git" ]]; then
  echo "ERROR: .git directory not found at $PROJECT_DIR" >&2
  exit 1
fi

mkdir -p "$HOOKS_DIR"

cat > "$HOOK_PATH" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
"$ROOT/scripts/security-leak-check.sh" --staged
EOF

chmod +x "$HOOK_PATH"
echo "Installed pre-commit hook: $HOOK_PATH"
