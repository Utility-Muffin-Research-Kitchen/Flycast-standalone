#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${MLP1_ARTIFACT_DIR:-$ROOT_DIR/output/mlp1/build}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/output/mlp1/flycast}"
SOURCE_DIR="${FLYCAST_SOURCE_DIR:-$ROOT_DIR/workdir/mlp1/flycast}"

if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required to build the Flycast package manifest" >&2
    exit 1
fi

for path in \
    "$BUILD_DIR/bin/flycast" \
    "$BUILD_DIR/build-manifest.json" \
    "$SOURCE_DIR/LICENSE" \
    "$ROOT_DIR/config/mlp1/launch.sh" \
    "$ROOT_DIR/config/mlp1/emu.cfg" \
    "$ROOT_DIR/config/mlp1/config.version" \
    "$ROOT_DIR/config/mlp1/SDL_Loong Gamepad.cfg" \
    "$ROOT_DIR/licenses/THIRD-PARTY-NOTICES.txt"; do
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
install -m 0644 "$ROOT_DIR/config/mlp1/config.version" \
    "$OUTPUT_DIR/defaults/config.version"
install -m 0644 "$ROOT_DIR/config/mlp1/SDL_Loong Gamepad.cfg" \
    "$OUTPUT_DIR/defaults/SDL_Loong Gamepad.cfg"
install -m 0644 "$SOURCE_DIR/LICENSE" \
    "$OUTPUT_DIR/licenses/Flycast-GPL-2.0.txt"
install -m 0644 "$ROOT_DIR/licenses/THIRD-PARTY-NOTICES.txt" \
    "$OUTPUT_DIR/licenses/THIRD-PARTY-NOTICES.txt"
install -m 0644 "$BUILD_DIR/build-manifest.json" \
    "$OUTPUT_DIR/provenance/build-manifest.json"
cp -R "$BUILD_DIR/provenance/." "$OUTPUT_DIR/provenance/"

install_license() {
    local source_path="$1"
    local output_name="$2"
    if [ ! -f "$source_path" ]; then
        echo "missing required third-party license: $source_path" >&2
        exit 1
    fi
    install -m 0644 "$source_path" "$OUTPUT_DIR/licenses/$output_name"
}

install_license "$SOURCE_DIR/core/deps/breakpad/LICENSE" "Breakpad-BSD-3-Clause.txt"
install_license "$SOURCE_DIR/core/deps/DreamPicoPort-API/LICENSE" "DreamPicoPort-MIT.txt"
install_license "$SOURCE_DIR/core/deps/libusb-cmake/libusb/COPYING" "libusb-LGPL-2.1.txt"
install_license "$SOURCE_DIR/core/deps/xxHash/LICENSE" "xxHash-BSD-2-Clause.txt"
install_license "$SOURCE_DIR/core/deps/glm/copying.txt" "GLM-License.txt"
install_license "$SOURCE_DIR/core/deps/libchdr/LICENSE.txt" "libchdr-BSD-3-Clause.txt"
install_license "$SOURCE_DIR/core/deps/libchdr/deps/zstd-1.5.6/LICENSE" \
    "Zstandard-BSD-3-Clause.txt"
install_license "$SOURCE_DIR/core/deps/libzip/LICENSE" "libzip-BSD-3-Clause.txt"
install_license "$SOURCE_DIR/core/deps/libjuice/LICENSE" "libjuice-MPL-2.0.txt"
install_license "$SOURCE_DIR/core/deps/websocketpp/COPYING" "WebSocketpp-BSD-3-Clause.txt"
install_license "$SOURCE_DIR/core/deps/picotcp/COPYING" "picoTCP-GPL-2.0.txt"
install_license "$SOURCE_DIR/core/deps/nowide/LICENSE" "Boost-Nowide-BSL-1.0.txt"
install_license "$SOURCE_DIR/core/deps/rcheevos/LICENSE" "rcheevos-MIT.txt"
install_license "$SOURCE_DIR/core/deps/xbrz/License.txt" "xBRZ-GPL-3.0.txt"
install_license "$SOURCE_DIR/core/deps/miniupnpc/LICENSE" "miniupnpc-BSD-3-Clause.txt"

cat >"$OUTPUT_DIR/README.txt" <<'EOF'
Flycast standalone for Leaf on Miniloong Pocket 1.

Launch through Jawaka with a Dreamcast .chd, .gdi, .cdi, or .cue image.
The package contains no BIOS or game content.

Runtime layout:

- Config and cache: USERDATA_PATH/flycast
- BIOS: BIOS_PATH selected by Jawaka for the ROM source
- Dreamcast data and VMUs: SAVES_PATH/Flycast
- Save states: STATES_PATH/Flycast
- Logs: LOGS_PATH/flycast
- Scratch: UMRK_RUNTIME_PATH/flycast

The initial config uses the validated performance profile. Flycast stores
native per-game settings as sections in the same durable emu.cfg; the package
does not duplicate the global config. MLP1 renderer, rotation, output, mapping,
and storage paths are launch-time safety invariants.

The RetroArch Flycast cores remain available as fallbacks.
EOF

config_version="$(tr -d '[:space:]' <"$ROOT_DIR/config/mlp1/config.version")"
checksums_file="$(mktemp)"
trap 'rm -f "$checksums_file"' EXIT

(
    cd "$OUTPUT_DIR"
    find . -type f ! -path './manifest.json' -print |
        LC_ALL=C sort |
        while IFS= read -r relative_path; do
            relative_path="${relative_path#./}"
            checksum="$(shasum -a 256 "$relative_path" | awk '{print $1}')"
            printf '%s\t%s\n' "$checksum" "$relative_path"
        done
) >"$checksums_file"

files_json="$(
    jq -Rn \
        '[inputs | split("\t") | {sha256: .[0], path: .[1]}]' \
        <"$checksums_file"
)"

jq \
    --argjson package_schema_version 1 \
    --argjson config_schema_version "$config_version" \
    --argjson files "$files_json" \
    '. + {
        package_schema_version: $package_schema_version,
        config_schema_version: $config_schema_version,
        files: $files
    }' \
    "$BUILD_DIR/build-manifest.json" >"$OUTPUT_DIR/manifest.json"

"$ROOT_DIR/scripts/verify-mlp1-package.sh" "$OUTPUT_DIR"

find "$OUTPUT_DIR" -maxdepth 3 -type f | sort
