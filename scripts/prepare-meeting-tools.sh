#!/usr/bin/env bash
set -euo pipefail
# Application-private, pinned read-only Google Docs client. Does not replace
# the user's gog installation or access credentials during preparation.
project="$(cd "$(dirname "$0")/.." && pwd)"
version="0.42.0"
architectures=()
if [[ "${1:-}" == "--universal" ]]; then
  architectures=(arm64 amd64)
else
  case "$(uname -m)" in
    arm64) architectures=(arm64) ;;
    x86_64) architectures=(amd64) ;;
    *) echo "Unsupported architecture" >&2; exit 1 ;;
  esac
fi
binaries=()
for arch in "${architectures[@]}"; do
  case "$arch" in
    arm64) expected=6a92b35473ed057c55677c2ba7d5af8e154d1bad23fa35e74994bc2f3bce4672 ;;
    amd64) expected=f28d7f64fb85d726e4757261a02879f35968ad7096fe00761cd9eda8e9f6d2dd ;;
  esac
  tools_dir="$project/.local/tools/gog-v$version/$arch"
  archive="$tools_dir/gogcli_${version}_darwin_${arch}.tar.gz"
  mkdir -p "$tools_dir"
  if [[ ! -f "$archive" ]]; then
    curl --fail --location --retry 2 --output "$archive" \
      "https://github.com/steipete/gogcli/releases/download/v$version/gogcli_${version}_darwin_${arch}.tar.gz"
  fi
  actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || { echo "Meeting tools checksum mismatch" >&2; exit 1; }
  tar -xzf "$archive" -C "$tools_dir" ./gog
  binaries+=("$tools_dir/gog")
done
smoke_index=0
if [[ "$(uname -m)" == "x86_64" && ${#binaries[@]} -gt 1 ]]; then smoke_index=1; fi
"${binaries[$smoke_index]}" docs raw --help >/dev/null
mkdir -p "$project/ClawGate.app/Contents/Resources/licenses"
cp "$project/resources/licenses/gogcli-LICENSE" "$project/ClawGate.app/Contents/Resources/licenses/gogcli-LICENSE"
if [[ ${#binaries[@]} -gt 1 ]]; then
  lipo -create "${binaries[@]}" -output "$project/ClawGate.app/Contents/Resources/gog"
else
  cp "${binaries[0]}" "$project/ClawGate.app/Contents/Resources/gog"
fi
