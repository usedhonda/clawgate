#!/usr/bin/env bash
set -euo pipefail

# Generate AppIcon.icns from a source PNG.
# Usage: ./scripts/generate-icon.sh [source.png]
# Output: resources/AppIcon.icns

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE="${1:-$HOME/Downloads/clawgate_logo.png}"
OUTPUT="$PROJECT_DIR/resources/AppIcon.icns"
ICONSET="$PROJECT_DIR/resources/AppIcon.iconset"

if [[ ! -f "$SOURCE" ]]; then
    echo "Source image not found: $SOURCE" >&2
    exit 1
fi

echo "Source: $SOURCE"

# Get source dimensions
SRC_W=$(sips -g pixelWidth "$SOURCE" | awk '/pixelWidth/{print $2}')
SRC_H=$(sips -g pixelHeight "$SOURCE" | awk '/pixelHeight/{print $2}')
echo "Source size: ${SRC_W}x${SRC_H}"

# Make it square (use the larger dimension)
SRC_MAX=$((SRC_W > SRC_H ? SRC_W : SRC_H))
echo "Square canvas: ${SRC_MAX}x${SRC_MAX}"

# Create square version with transparent padding using Python (sips can't do transparent padding)
SQUARE_PNG="/tmp/clawgate_icon_square.png"
python3 - "$SOURCE" "$SQUARE_PNG" "$SRC_MAX" <<'PYEOF'
import sys
try:
    from PIL import Image
except ImportError:
    # Fallback: use Pillow from system or pip
    import subprocess
    subprocess.check_call([sys.executable, "-m", "pip", "install", "--quiet", "Pillow"])
    from PIL import Image

src_path = sys.argv[1]
dst_path = sys.argv[2]
canvas_size = int(sys.argv[3])

img = Image.open(src_path).convert("RGBA")
canvas = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
x = (canvas_size - img.width) // 2
y = (canvas_size - img.height) // 2
canvas.paste(img, (x, y), img if img.mode == "RGBA" else None)
canvas.save(dst_path, "PNG")
print(f"Square image saved: {dst_path} ({canvas_size}x{canvas_size})")
PYEOF

# Create iconset directory
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

# Required sizes for macOS .icns
declare -a SIZES=(
    "icon_16x16.png:16"
    "icon_16x16@2x.png:32"
    "icon_32x32.png:32"
    "icon_32x32@2x.png:64"
    "icon_128x128.png:128"
    "icon_128x128@2x.png:256"
    "icon_256x256.png:256"
    "icon_256x256@2x.png:512"
    "icon_512x512.png:512"
    "icon_512x512@2x.png:1024"
)

echo "Generating icon sizes..."
for entry in "${SIZES[@]}"; do
    name="${entry%%:*}"
    size="${entry##*:}"
    sips -z "$size" "$size" "$SQUARE_PNG" --out "$ICONSET/$name" >/dev/null 2>&1
    echo "  $name (${size}x${size})"
done

# Convert iconset to icns
echo "Converting to .icns..."
iconutil -c icns "$ICONSET" -o "$OUTPUT"

# Clean up
rm -rf "$ICONSET" "$SQUARE_PNG"

echo "Done: $OUTPUT"
ls -la "$OUTPUT"
