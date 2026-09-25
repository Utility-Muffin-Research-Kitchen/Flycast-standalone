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
    '

# Achievements compiled in, and the binary and its capability records in
# agreement: the account bridge (contract variables, marker) behind
# ra-account-v1, the session route (UMRK_FLYCAST_RA_ROUTE, the fixed
# /leaf/health endpoint and session host) behind ra-route-v1. Checked against
# the records the package is built from and, once assembled, the package's own.
record_dirs=("$ROOT_DIR/config/mlp1")
if [ -f "$ROOT_DIR/output/mlp1/flycast/manifest.json" ]; then
    record_dirs+=("$ROOT_DIR/output/mlp1/flycast")
fi
python3 "$ROOT_DIR/scripts/check-binary-capabilities.py" "$BINARY" "${record_dirs[@]}"

# The on-device ABI check writes to and runs on a real device, so it happens
# only on request: VERIFY_ON_DEVICE=1, against ADB_SERIAL or else the first
# online device. Without it the script is host-only even when adb is installed
# and a device is connected.
case "${VERIFY_ON_DEVICE:-0}" in
    0 | "") exit 0 ;;
    1) ;;
    *)
        echo "VERIFY_ON_DEVICE must be 0 or 1, not '$VERIFY_ON_DEVICE'" >&2
        exit 1
        ;;
esac

if ! command -v adb >/dev/null 2>&1; then
    echo "VERIFY_ON_DEVICE=1 but adb is not installed" >&2
    exit 1
fi
if [ -n "${ADB_SERIAL:-}" ]; then
    serial="$ADB_SERIAL"
else
    serial="$(adb devices | awk 'NR > 1 && $2 == "device" { print $1; exit }')"
fi
if [ -z "$serial" ]; then
    echo "VERIFY_ON_DEVICE=1 but no adb device is online" >&2
    exit 1
fi

remote=/tmp/umrk-flycast-abi-check
adb -s "$serial" push "$BINARY" "$remote" >/dev/null
adb -s "$serial" shell "chmod 755 '$remote' && LD_TRACE_LOADED_OBJECTS=1 '$remote'"
adb -s "$serial" shell "rm -f '$remote'"
