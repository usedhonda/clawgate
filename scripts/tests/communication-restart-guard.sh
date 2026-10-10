#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/scripts/lib-communication-restart.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
events="$tmp/events"
canonical="$tmp/gateway-restart"
apply="$tmp/apply"
rollback="$tmp/rollback"
check="$tmp/check-communication-change"

cat > "$canonical" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ -n "${GATEWAY_RESTART_COMMUNICATION_MANIFEST:-}" ]]
[[ -n "${GATEWAY_RESTART_COMMUNICATION_CURRENT:-}" ]]
echo check >> "$COMMUNICATION_TEST_EVENTS"
echo stop >> "$COMMUNICATION_TEST_EVENTS"
"${GATEWAY_RESTART_MAINTENANCE_HOOK}"
echo start >> "$COMMUNICATION_TEST_EVENTS"
EOF
cat > "$apply" <<'EOF'
#!/usr/bin/env bash
echo apply >> "$COMMUNICATION_TEST_EVENTS"
EOF
cat > "$rollback" <<'EOF'
#!/usr/bin/env bash
echo rollback >> "$COMMUNICATION_TEST_EVENTS"
EOF
chmod 755 "$canonical" "$apply" "$rollback"
cat > "$check" <<'EOF'
#!/usr/bin/env python3
import pathlib
import sys
args = sys.argv[1:]
assert args[0] == "--manifest" and args[2] == "--current"
assert pathlib.Path(args[1]).is_file() and pathlib.Path(args[3]).is_file()
EOF
chmod 755 "$check"

if GATEWAY_RESTART_COMMUNICATION_MANIFEST="$tmp/manifest" \
   GATEWAY_RESTART_COMMUNICATION_CURRENT="" \
   communication_require_admission 2>/dev/null; then
  echo "FAIL: partial admission was accepted" >&2
  exit 1
fi
[[ ! -s "$events" ]] || { echo "FAIL: rejected admission produced effects" >&2; exit 1; }

touch "$tmp/manifest" "$tmp/current"
export COMMUNICATION_TEST_EVENTS="$events"
export GATEWAY_RESTART_COMMUNICATION_MANIFEST="$tmp/manifest"
export GATEWAY_RESTART_COMMUNICATION_CURRENT="$tmp/current"
export CLAWGATE_GATEWAY_RESTART_SCRIPT="$canonical"
export CLAWGATE_COMMUNICATION_CHECK_SCRIPT="$check"
export CLAWGATE_COMMUNICATION_MAINTENANCE_HOOK="$apply"
export CLAWGATE_COMMUNICATION_ROLLBACK_HOOK="$rollback"
communication_preflight
communication_gateway_restart
expected=$'check\nstop\napply\nstart'
actual="$(<"$events")"
[[ "$actual" == "$expected" ]] || { printf 'FAIL: order was:\n%s\n' "$actual" >&2; exit 1; }
echo "communication restart guard: PASS (reject-before-effects, check-stop-apply-start)"
