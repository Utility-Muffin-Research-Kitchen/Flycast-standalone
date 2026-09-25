#!/usr/bin/env bash
set -euo pipefail

# Host checks for the standalone-ra-account-v1 consumer.
#
# Both binaries compile the exact file the MLP1 build compiles, out of the
# patched upstream tree, so a change to the emulator's classifier or state
# machine is caught here rather than on the device:
#
#   1. the shared leaf-contracts fixtures, replayed through the emulator's
#      own classifier at the revision pinned in locks/contracts.lock.json;
#   2. the marker, the transitions, and what each write failure must NOT do.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="${FLYCAST_SOURCE_DIR:-$ROOT_DIR/workdir/mlp1/flycast}"
FIXTURES_DIR="${CONTRACT_FIXTURES_DIR:-$ROOT_DIR/workdir/contracts}"
BUILD_DIR="${RA_ACCOUNT_TEST_DIR:-$ROOT_DIR/output/host/ra-account}"
CXX="${CXX:-c++}"

CONTRACT_SOURCE="$SOURCE_DIR/core/achievements/ra_account_contract.cpp"
if [ ! -f "$CONTRACT_SOURCE" ]; then
    echo "missing patched upstream source: $CONTRACT_SOURCE" >&2
    echo "run make fetch-upstream first" >&2
    exit 1
fi

"$ROOT_DIR/scripts/fetch-contract-fixtures.sh"

mkdir -p "$BUILD_DIR"

# -I core only: the contract half of the bridge must not acquire a Flycast
# dependency, and this compile is what keeps that true.
"$CXX" -std=c++17 -Wall -Wextra -Werror -O1 \
    -I "$SOURCE_DIR/core" \
    -o "$BUILD_DIR/ra_account_state_test" \
    "$ROOT_DIR/tests/ra_account_state_test.cpp" \
    "$CONTRACT_SOURCE"

"$CXX" -std=c++17 -Wall -Wextra -Werror -O1 \
    -I "$SOURCE_DIR/core" \
    -o "$BUILD_DIR/ra_account_probe" \
    "$ROOT_DIR/tests/ra_account_probe.cpp" \
    "$CONTRACT_SOURCE"

"$BUILD_DIR/ra_account_state_test"

python3 "$ROOT_DIR/tests/run-contract-fixtures.py" \
    "$BUILD_DIR/ra_account_probe" \
    "$FIXTURES_DIR/fixtures.json"
