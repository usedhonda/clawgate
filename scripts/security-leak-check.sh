#!/usr/bin/env bash
#
# Leak guard for private persona files and secret-like tokens.
#
# Usage:
#   ./scripts/security-leak-check.sh --staged   # default, pre-commit mode
#   ./scripts/security-leak-check.sh --all      # CI mode (scan tracked files)
#   ./scripts/security-leak-check.sh --self-test  # deterministic self-check

set -euo pipefail

MODE="staged"
if [[ "${1:-}" == "--self-test" ]]; then
  MODE="self-test"
elif [[ "${1:-}" == "--all" ]]; then
  MODE="all"
elif [[ "${1:-}" == "--staged" || -z "${1:-}" ]]; then
  MODE="staged"
else
  echo "Usage: $0 [--staged|--all|--self-test]" >&2
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
  '(^|/)CLAUDE\.local\.md$'
  '(^|/)\.codex/config\.toml$'
  '(^|/)\.local/'
  '(^|/)\.runtime/'
  '(^|/)\.env($|\.)'
  '\.(pem|p12|key|keychain|keychain-db)$'
)

SECRET_PATTERNS=(
  '[a-z]{4}(-[a-z]{4}){3}' # Apple app-specific password format
  'ghp_[A-Za-z0-9]{20,}'
  'github_pat_[A-Za-z0-9_]{20,}'
  '-----BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----'
  'sk-(proj-|ant-)?[A-Za-z0-9_-]{32,}'
  'xox[baprs]-[A-Za-z0-9-]{20,}'
  'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}' # JWT-like token
  '(remoteaccesstoken|federationtoken|bridgetoken|clawgatetoken)[[:space:]]*[:=][[:space:]]*["'"'"'\''][A-Za-z0-9._-]*[0-9][A-Za-z0-9._-]{15,}["'"'"'\'']'
  '((messenger|chat|im|line|slack|discord|telegram|signal|whatsapp)[ _-]?(access|channel|notify|api|auth)?[ _-]?token)[[:space:]]*[:=][[:space:]]*["'"'"'\''][A-Za-z0-9._-]*[0-9][A-Za-z0-9._-]{15,}["'"'"'\'']'
  'authorization[[:space:]]*[:=][[:space:]]*["'"'"'\'']?bearer[[:space:]]+[A-Za-z0-9._-]*[0-9][A-Za-z0-9._-]{11,}'
)

# Match shapes, not the maintainer's actual identity: the guard is public too.
# Explicit example home directories and tailnets are allowed below; arbitrary
# local accounts, real signing identities and tailnet names are not.
PERSONAL_PATTERNS=(
  '/Users/[A-Za-z0-9_.-]+(/|$)'
  '(Developer ID Application|Apple Development):.*\([A-Z0-9]{10}\)'
  '[A-Za-z0-9.-]+\.ts\.net'
)

contains_blocked_path() {
  local path="$1"
  local pattern

  case "$path" in
    AGENTS.md|./AGENTS.md|CLAUDE.md|./CLAUDE.md|.env.example|*/.env.example|.env.sample|*/.env.sample|.env.template|*/.env.template)
      return 1
      ;;
  esac

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
  local pattern=""
  local line_number

  printf -v pattern '%s|' "${SECRET_PATTERNS[@]}"
  line_number="$(printf '%s' "$content" | grep -aEnim1 -- "${pattern%|}" | cut -d: -f1 || true)"
  if [[ -n "$line_number" ]]; then
    # Never echo the matching line: public Actions logs would republish it.
    echo "[leak-guard] potential secret pattern in: $path:$line_number (content redacted)"
    return 1
  fi

  return 0
}

scan_file_for_violations() {
  local path="$1"
  local content="$2"
  local has_violation=0

  if contains_blocked_path "$path"; then
    return 1
  fi

  if [[ -z "$content" ]]; then
    return 0
  fi

  if ! scan_content_for_secret "$path" "$content"; then
    has_violation=1
  fi

  if ! scan_content_for_personal "$path" "$content"; then
    has_violation=1
  fi

  if [[ "$has_violation" -eq 1 ]]; then
    return 1
  fi

  return 0
}

run_self_test_case() {
  local label="$1"
  local expected="$2"
  local path="$3"
  local content="$4"

  if scan_file_for_violations "$path" "$content"; then
    local actual="pass"
  else
    local actual="fail"
  fi

  if [[ "$actual" == "$expected" ]]; then
    echo "[leak-guard:self-test] ok: $label"
    return 0
  fi

  echo "[leak-guard:self-test] FAIL: $label (expected $expected, got $actual)"
  return 1
}

run_self_test() {
  local failures=0
  local home_prefix="/Users"
  local personal_path="${home_prefix}/private-account/dev/project"
  local token_prefix="ghp_"
  local secret_token
  secret_token="${token_prefix}$(printf 'x%.0s' {1..21})"

  run_self_test_case "root_AGENTS_allowed" "pass" "AGENTS.md" "# public shared contract\n@notes" || failures=$((failures + 1))
  run_self_test_case "root_CLAUDE_allowed" "pass" "CLAUDE.md" "# public shared contract\n@AGENTS.md" || failures=$((failures + 1))
  run_self_test_case "claude_local_blocked" "fail" "CLAUDE.local.md" "local override" || failures=$((failures + 1))
  run_self_test_case "dotlocal_blocked" "fail" ".local/secret.txt" "local file" || failures=$((failures + 1))
  run_self_test_case "runtime_backup_blocked" "fail" ".runtime/backup.json" "" || failures=$((failures + 1))
  run_self_test_case "codex_config_blocked" "fail" ".codex/config.toml" "codex config" || failures=$((failures + 1))
  run_self_test_case "empty_claude_local_blocked" "fail" "CLAUDE.local.md" "" || failures=$((failures + 1))
  run_self_test_case "empty_dotlocal_blocked" "fail" ".local/secret.txt" "" || failures=$((failures + 1))
  run_self_test_case "empty_codex_config_blocked" "fail" ".codex/config.toml" "" || failures=$((failures + 1))
  run_self_test_case "env_blocked" "fail" ".env.production" "" || failures=$((failures + 1))
  run_self_test_case "env_example_allowed" "pass" ".env.example" "TOKEN=<token>" || failures=$((failures + 1))
  run_self_test_case "private_key_path_blocked" "fail" "keys/device.pem" "" || failures=$((failures + 1))
  run_self_test_case "personal_path_content_blocked" "fail" "notes.md" "$personal_path" || failures=$((failures + 1))
  run_self_test_case "example_home_allowed" "pass" "notes.md" "${home_prefix}/YOUR_USERNAME/projects" || failures=$((failures + 1))
  run_self_test_case "example_tailnet_allowed" "pass" "notes.md" "my-host.example-tailnet.ts.net" || failures=$((failures + 1))
  local tailnet_suffix="ts.net"
  run_self_test_case "personal_tailnet_blocked" "fail" "notes.md" "host-a.private-network.${tailnet_suffix}" || failures=$((failures + 1))
  run_self_test_case "secret_token_content_blocked" "fail" "notes.md" "$secret_token" || failures=$((failures + 1))

  local diagnostic
  diagnostic="$(scan_file_for_violations "notes.md" "$secret_token" || true)"
  if [[ "$diagnostic" == *"$secret_token"* ]]; then
    echo "[leak-guard:self-test] FAIL: secret diagnostic is not redacted"
    failures=$((failures + 1))
  else
    echo "[leak-guard:self-test] ok: secret diagnostic is redacted"
  fi

  if [[ "$failures" -gt 0 ]]; then
    echo "[leak-guard:self-test] FAILED with $failures failing case(s)"
    return 1
  fi

  echo "[leak-guard:self-test] PASSED"
  return 0
}

scan_content_for_personal() {
  local path="$1"
  local content="$2"
  local pattern=""
  local line_number
  local filtered

  # Keep the allowlist exact, so a real value beside an example is still found.
  filtered="$(printf '%s' "$content" | sed -E \
    -e 's@/Users/(YOUR_USERNAME|USERNAME|yourname|username|user|you|test|testuser|test-user|test_user|Shared)/@/Users/<example>/@g' \
    -e 's@([A-Za-z0-9-]+\.)*(example-tailnet|example)\.ts\.net@<example-tailnet>@g')"

  printf -v pattern '%s|' "${PERSONAL_PATTERNS[@]}"
  line_number="$(printf '%s' "$filtered" | grep -aEnm1 -- "${pattern%|}" | cut -d: -f1 || true)"
  if [[ -n "$line_number" ]]; then
    echo "[leak-guard] personal/local identifier in: $path:$line_number (content redacted)"
    return 1
  fi

  return 0
}

if [[ "$MODE" == "self-test" ]]; then
  run_self_test
  exit $?
fi

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

for file in "${FILES[@]}"; do
  content=""
  if [[ "$MODE" == "all" ]]; then
    if [[ ! -f "$file" ]]; then
      continue
    fi
    # Do not load image/font binaries into shell variables (NUL truncation).
    # Blocked credential paths are still rejected, even with empty content.
    content="$(grep -I '' -- "$file" 2>/dev/null || true)"
  else
    content="$(git show ":$file" 2>/dev/null | grep -I '' || true)"
  fi

  if ! scan_file_for_violations "$file" "$content"; then
    echo "[leak-guard] blocked private path or personal/secrets in: $file"
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
