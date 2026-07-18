#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${MLP1_ARTIFACT_DIR:-$ROOT_DIR/output/mlp1/build}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/output/mlp1/flycast}"
SOURCE_DIR="${FLYCAST_SOURCE_DIR:-$ROOT_DIR/workdir/mlp1/flycast}"

for path in \
    "$BUILD_DIR/bin/flycast" \
    "$BUILD_DIR/build-manifest.json" \
    "$SOURCE_DIR/LICENSE" \
    "$ROOT_DIR/config/mlp1/launch.sh" \
    "$ROOT_DIR/config/mlp1/emu.cfg" \
    "$ROOT_DIR/config/mlp1/SDL_Loong Gamepad.cfg"; do
    if [ ! -f "$path" ]; then
        echo "missing required package input: $path" >&2
        exit 1
    fi
done

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/bin" "$OUTPUT_DIR/defaults" "$OUTPUT_DIR/licenses" \
    "$OUTPUT_DIR/provenance"

install -m 0755 "$BUILD_DIR/bin/flycast" "$OUTPUT_DIR/bin/flycast"
install -m 0755 "$ROOT_DIR/config/mlp1/launch.sh" "$OUTPUT_DIR/launch.sh"
install -m 0644 "$ROOT_DIR/config/mlp1/emu.cfg" "$OUTPUT_DIR/defaults/emu.cfg"
install -m 0644 "$ROOT_DIR/config/mlp1/SDL_Loong Gamepad.cfg" \
    "$OUTPUT_DIR/defaults/SDL_Loong Gamepad.cfg"
install -m 0644 "$SOURCE_DIR/LICENSE" \
    "$OUTPUT_DIR/licenses/Flycast-GPL-2.0.txt"
install -m 0644 "$BUILD_DIR/build-manifest.json" "$OUTPUT_DIR/manifest.json"
cp -R "$BUILD_DIR/provenance/." "$OUTPUT_DIR/provenance/"

cat >"$OUTPUT_DIR/README.txt" <<'EOF'
Flycast standalone for Leaf on Miniloong Pocket 1.

Launch through Jawaka with a Dreamcast .chd, .gdi, .cdi, or .cue image.
The package contains no BIOS or game content. Runtime configuration and VMU
data are stored under USERDATA_PATH/flycast.

This initial package uses the performance-parity probe configuration. The
RetroArch Flycast cores remain available as fallbacks.
EOF

find "$OUTPUT_DIR" -maxdepth 3 -type f | sort
