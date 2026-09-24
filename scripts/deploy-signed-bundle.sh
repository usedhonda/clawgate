#!/usr/bin/env bash
# Transfer a locally signed ClawGate.app to a remote desktop host without
# invoking codesign in an SSH session. Keeps the previous bundle for rollback.
set -euo pipefail

if [[ $# -ne 2 || "$1" != "--remote-host" || -z "$2" ]]; then
  echo "Usage: $0 --remote-host <ssh-alias>" >&2
  exit 2
fi
remote_host="$2"
project_path="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_path"

app="ClawGate.app"
codesign --verify --deep --strict "$app"
authority="$(codesign -dv --verbose=4 "$app" 2>&1 | sed -n 's/^Authority=//p' | head -n 1)"
case "$authority" in
  Developer\ ID\ Application*) ;;
  *) echo "Refusing to deploy bundle without Developer ID signature" >&2; exit 1 ;;
esac
expected_hash="$(shasum -a 256 "$app/Contents/MacOS/ClawGate" | awk '{print $1}')"
archive=".local/clawgate-signed-$$.tgz"
remote_archive="/tmp/clawgate-signed-$$.tgz"
tar -czf "$archive" "$app"
scp -q "$archive" "$remote_host:$remote_archive"

ssh "$remote_host" /bin/bash -s -- "$remote_archive" "$expected_hash" <<'REMOTE'
set -euo pipefail
archive="$1"
expected_hash="$2"
project="$HOME/projects/ios/clawgate"
stage="$project/.runtime/deploy-stage-$$"
backup="$project/.runtime/ClawGate.app.pre-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$stage"
tar -xzf "$archive" -C "$stage"
codesign --verify --deep --strict "$stage/ClawGate.app"
authority="$(codesign -dv --verbose=4 "$stage/ClawGate.app" 2>&1 | sed -n 's/^Authority=//p' | head -n 1)"
case "$authority" in
  Developer\ ID\ Application*) ;;
  *) echo "Transferred bundle is not Developer ID signed" >&2; exit 1 ;;
esac
actual_hash="$(shasum -a 256 "$stage/ClawGate.app/Contents/MacOS/ClawGate" | awk '{print $1}')"
[[ "$actual_hash" == "$expected_hash" ]] || { echo "Transferred binary hash mismatch" >&2; exit 1; }

rollback() {
  if [[ -d "$backup" ]]; then
    mv "$project/ClawGate.app" "$project/.runtime/ClawGate.app.failed-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
    mv "$backup" "$project/ClawGate.app"
    open "$project/ClawGate.app" || true
  fi
}
success=false
trap 'if [[ "$success" != true ]]; then rollback; fi' EXIT
pkill -f "$project/ClawGate.app/Contents/MacOS/ClawGate" 2>/dev/null || true
for ((i=0; i<10; i++)); do
  if ! pgrep -f "$project/ClawGate.app/Contents/MacOS/ClawGate" >/dev/null; then
    break
  fi
  sleep 1
done
if pgrep -f "$project/ClawGate.app/Contents/MacOS/ClawGate" >/dev/null; then
  echo "Previous app did not exit; leaving bundle untouched" >&2
  exit 1
fi
mv "$project/ClawGate.app" "$backup"
mv "$stage/ClawGate.app" "$project/ClawGate.app"
open "$project/ClawGate.app"
healthy=false
for ((i=0; i<15; i++)); do
  if curl -fsS -m 2 http://127.0.0.1:8765/v1/health >/dev/null 2>&1; then
    healthy=true
    break
  fi
  sleep 1
done
[[ "$healthy" == true ]] || { echo "Deployed app did not become healthy" >&2; exit 1; }
codesign --verify --deep --strict "$project/ClawGate.app"
success=true
echo "Signed bundle deployed; previous bundle retained under .runtime"
REMOTE
