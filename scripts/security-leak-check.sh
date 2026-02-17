#!/usr/bin/env bash
#
# Leak guard for private persona files and secret-like tokens.
#
# Usage:
#   ./scripts/security-leak-check.sh --staged   # default, pre-commit mode
#   ./scripts/security-leak-check.sh --all      # CI mode (scan tracked files)

set -euo pipefail

MODE="staged"
if [[ "${1:-}" == "--all" ]]; then
  MODE="all"
elif [[ "${1:-}" == "--staged" || -z "${1:-}" ]]; then
  MODE="staged"
else
  echo "Usage: $0 [--staged|--all]" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

BLOCKED_PATH_PATTERNS=(
  '(^|/)SOUL\.md$'
  '(^|/)[^/]+\.soul\.md$'
  '(^|/)prompts-private\.js$'
  '(^|/)prompts-local\.js$'
  '(^|/)AGENTS\.md$'
  '(^|/)CLAUDE\.md$'
  '(^|/)\.codex/config\.toml$'
  '(^|/)\.local/'
)

SECRET_PATTERNS=(
  '[a-z]{4}(-[a-z]{4}){3}' # Apple app-specific password format
  'ghp_[A-Za-z0-9]{20,}'
  'github_pat_[A-Za-z0-9_]{20,}'
  'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}' # JWT-like token
  '(remoteaccesstoken|federationtoken|bridgetoken|clawgatetoken)[[:space:]]*[:=][[:space:]]*["'"'"'\''][A-Za-z0-9._-]*[0-9][A-Za-z0-9._-]{15,}["'"'"'\'']'
  '((messenger|chat|im|line|slack|discord|telegram|signal|whatsapp)[ _-]?(access|channel|notify|api|auth)?[ _-]?token)[[:space:]]*[:=][[:space:]]*["'"'"'\''][A-Za-z0-9._-]*[0-9][A-Za-z0-9._-]{15,}["'"'"'\'']'
  'authorization[[:space:]]*[:=][[:space:]]*["'"'"'\'']?bearer[[:space:]]+[A-Za-z0-9._-]*[0-9][A-Za-z0-9._-]{11,}'
)

FILES=()
if [[ "$MODE" == "all" ]]; then
  while IFS= read -r -d '' file; do
    FILES+=("$file")
  done < <(git ls-files -z)
else
  while IFS= read -r -d '' file; do
    FILES+=("$file")
  done < <(git diff --cached --name-only --diff-filter=ACMR -z)
fi

if [[ "${#FILES[@]}" -eq 0 ]]; then
  exit 0
fi

violations=0

contains_blocked_path() {
  local path="$1"
  local pattern
  for pattern in "${BLOCKED_PATH_PATTERNS[@]}"; do
    if [[ "$path" =~ $pattern ]]; then
      return 0
    fi
  done
  return 1
}

scan_content_for_secret() {
  local path="$1"
  local content="$2"
  local pattern
  local match

  for pattern in "${SECRET_PATTERNS[@]}"; do
    match="$(printf '%s' "$content" | grep -aEni -- "$pattern" | head -n 1 || true)"
    if [[ -n "$match" ]]; then
      echo "[leak-guard] potential secret pattern in: $path"
      echo "  $match"
      return 1
    fi
  done

  return 0
}

for file in "${FILES[@]}"; do
  if contains_blocked_path "$file"; then
    echo "[leak-guard] blocked private path detected: $file"
    violations=$((violations + 1))
    continue
  fi

  content=""
  if [[ "$MODE" == "all" ]]; then
    if [[ ! -f "$file" ]]; then
      continue
    fi
    content="$(cat "$file" 2>/dev/null || true)"
  else
    content="$(git show ":$file" 2>/dev/null || true)"
  fi

  if [[ -z "$content" ]]; then
    continue
  fi

  if ! scan_content_for_secret "$file" "$content"; then
    violations=$((violations + 1))
  fi
done

if [[ "$violations" -gt 0 ]]; then
  cat >&2 <<'EOF'
[leak-guard] failed.
Remove private persona/secret data from staged files and retry.
EOF
  exit 1
fi

echo "[leak-guard] passed ($MODE)"
