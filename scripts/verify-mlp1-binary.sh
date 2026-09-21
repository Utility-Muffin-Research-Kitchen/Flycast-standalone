#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCKER="${DOCKER:-docker}"
TOOLCHAIN_IMAGE="${TOOLCHAIN_IMAGE:-$(python3 -c 'import json; print(json.load(open("'"$ROOT_DIR"'/locks/build-inputs.lock.json"))["mlp1_toolchain_image"])')}"
BINARY="${MLP1_BINARY:-$ROOT_DIR/output/mlp1/build/bin/flycast}"

if [ ! -x "$BINARY" ]; then
    echo "missing MLP1 Flycast binary: $BINARY" >&2
    exit 1
fi

file "$BINARY"
file "$BINARY" | grep -q 'ELF 64-bit LSB.*ARM aarch64'

"$DOCKER" run --rm \
    -v "$ROOT_DIR":/build:ro \
    "$TOOLCHAIN_IMAGE" \
    bash -lc '
        set -euo pipefail
        binary=/build/output/mlp1/build/bin/flycast
        "$CROSS_TRIPLE-readelf" -d "$binary"
        "$CROSS_TRIPLE-readelf" --version-info "$binary"

        # RetroAchievements needs real HTTPS, not just a curl symbol: the
        # dynamic loader has to find libcurl, and the device resolves its TLS
        # libraries through it (checked below against the real device).
        "$CROSS_TRIPLE-readelf" -d "$binary" |
            grep -F "Shared library: [libcurl.so.4]" >/dev/null

        # Achievements compiled in, not merely available upstream.
        "$CROSS_TRIPLE-strings" -a "$binary" | grep -F "retroachievements.org" >/dev/null

        # The Leaf account bridge: the contract variables it reads and the
        # marker it writes beside emu.cfg.
        "$CROSS_TRIPLE-strings" -a "$binary" | grep -F "UMRK_RA_ACCOUNT_VERSION" >/dev/null
        "$CROSS_TRIPLE-strings" -a "$binary" | grep -F "UMRK_RA_ACCOUNT_PASSWORD" >/dev/null
        "$CROSS_TRIPLE-strings" -a "$binary" | grep -F "umrk-ra-account" >/dev/null
    '

if command -v adb >/dev/null 2>&1; then
    if [ -n "${ADB_SERIAL:-}" ]; then
        serial="$ADB_SERIAL"
    else
        serial="$(adb devices | awk 'NR > 1 && $2 == "device" { print $1; exit }')"
    fi

    if [ -n "$serial" ]; then
        remote=/tmp/umrk-flycast-abi-check
        adb -s "$serial" push "$BINARY" "$remote" >/dev/null
        adb -s "$serial" shell "chmod 755 '$remote' && LD_TRACE_LOADED_OBJECTS=1 '$remote'"
        adb -s "$serial" shell "rm -f '$remote'"
    fi
fi
