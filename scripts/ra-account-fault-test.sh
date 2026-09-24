#!/usr/bin/env bash
set -euo pipefail

# Host fault injection for the Leaf account import (the "Host fault
# injection" row of the account plan). Compiles the REAL bridge, contract and
# configuration store out of the patched upstream tree against minimal host
# stand-ins for the rest of Flycast (tests/host-stubs), links them with an
# in-executable fopen/fwrite/fflush/fsync/fclose/rename shim
# (tests/fault_shim.c), and replays the launch sequences in
# tests/run-ra-account-faults.py. Runs the same on Linux and macOS; no root,
# tmpfs or Docker needed.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="${FLYCAST_SOURCE_DIR:-$ROOT_DIR/workdir/mlp1/flycast}"
BUILD_DIR="${RA_ACCOUNT_FAULT_TEST_DIR:-$ROOT_DIR/output/host/ra-account-faults}"
CC="${CC:-cc}"
CXX="${CXX:-c++}"
CORE="$SOURCE_DIR/core"

for required in \
    "$CORE/achievements/ra_account_bridge.cpp" \
    "$CORE/achievements/ra_account_contract.cpp" \
    "$CORE/cfg/cfg.cpp" \
    "$CORE/cfg/ini.cpp"; do
    if [ ! -f "$required" ]; then
        echo "missing patched upstream source: $required" >&2
        echo "run make fetch-upstream first" >&2
        exit 1
    fi
done

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

includes=(-I "$ROOT_DIR/tests/host-stubs" -I "$CORE" -I "$CORE/achievements"
    -I "$CORE/deps/nowide/include")
cxxflags=(-std=c++17 -O1 -DUSE_RACHIEVEMENTS -Wall)

"$CC" -std=c99 -Wall -Wextra -Werror -O1 -c "$ROOT_DIR/tests/fault_shim.c" \
    -o "$BUILD_DIR/fault_shim.o"

# Upstream's own files: compiled as they are, warnings not fatal.
for source in "$CORE/cfg/cfg.cpp" "$CORE/cfg/ini.cpp"; do
    "$CXX" "${cxxflags[@]}" "${includes[@]}" -c "$source" \
        -o "$BUILD_DIR/$(basename "$source" .cpp).o"
done

# The UMRK files and the harness: warnings are errors.
for source in \
    "$CORE/achievements/ra_account_bridge.cpp" \
    "$CORE/achievements/ra_account_contract.cpp" \
    "$ROOT_DIR/tests/host-stubs/host_stubs.cpp" \
    "$ROOT_DIR/tests/ra_account_fault_probe.cpp"; do
    "$CXX" "${cxxflags[@]}" -Wextra -Wno-unused-parameter -Werror "${includes[@]}" \
        -c "$source" -o "$BUILD_DIR/$(basename "$source" .cpp).o"
done

libs=()
if [ "$(uname -s)" = Linux ]; then
    libs+=(-ldl)
fi
"$CXX" -o "$BUILD_DIR/ra_account_fault_probe" "$BUILD_DIR"/*.o "${libs[@]}"

python3 "$ROOT_DIR/tests/run-ra-account-faults.py" "$BUILD_DIR/ra_account_fault_probe"
