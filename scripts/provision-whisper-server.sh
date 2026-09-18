#!/usr/bin/env bash
# Build and install a resident whisper.cpp `whisper-server` for ambient STT.
#
# Installs into ~/Library/Application Support/ClawGate/whisper/server/{bin,lib}
# with its own dylibs, apart from whisper-cli's lib/ (their ggml versions differ).
#
# Local patch: with `-l auto` and Silero VAD, a chunk in which VAD finds no
# speech leaves no language id, whisper_lang_str_full() returns NULL, and the
# server crashes building its JSON reply (seen on v1.8.6 and v1.9.4). Ambient
# sends many such chunks, so the reply falls back to "unknown" instead.
set -euo pipefail

TAG="${WHISPER_CPP_TAG:-v1.9.4}"
DEST="$HOME/Library/Application Support/ClawGate/whisper/server"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

git clone -q --depth 1 --branch "$TAG" https://github.com/ggml-org/whisper.cpp.git "$WORK/src"
SERVER="$WORK/src/examples/server/server.cpp"
grep -q "whisper_lang_str_full(" "$SERVER" || { echo "patch target not found in $TAG" >&2; exit 1; }
sed -i '' 's/whisper_lang_str_full(/clawgate_lang_str_full(/g' "$SERVER"
{
  printf '%s\n' '#include "whisper.h"'
  printf '%s\n' 'static const char * clawgate_lang_str_full(int id) {'
  printf '%s\n' '    const char * s = whisper_lang_str_full(id);'
  printf '%s\n' '    return s ? s : "unknown";'
  printf '%s\n' '}'
  cat "$SERVER"
} > "$SERVER.patched"
mv "$SERVER.patched" "$SERVER"

cmake -S "$WORK/src" -B "$WORK/build" -DCMAKE_BUILD_TYPE=Release -DGGML_METAL=ON \
  -DWHISPER_BUILD_EXAMPLES=ON -DWHISPER_BUILD_SERVER=ON \
  -DCMAKE_INSTALL_RPATH="@executable_path/../lib" -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON >/dev/null
cmake --build "$WORK/build" --target whisper-server -j 8 >/dev/null

mkdir -p "$DEST/bin" "$DEST/lib"
cp "$WORK/build/bin/whisper-server" "$DEST/bin/whisper-server"
find "$WORK/build" -name "*.dylib" -exec cp -a {} "$DEST/lib/" \;
echo "installed whisper-server $TAG (patched) -> $DEST"
