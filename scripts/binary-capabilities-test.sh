#!/usr/bin/env bash
set -euo pipefail

# check-binary-capabilities.py against synthetic binaries and record
# directories: the complete set passes; a binary missing any marker a record
# promises, a missing record, or a record naming the wrong capability fails.
# verify-mlp1-binary.sh and verify-mlp1-package.sh run the same checker on the
# real binary.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT_DIR/scripts/check-binary-capabilities.py"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

MARKERS=(retroachievements.org UMRK_RA_ACCOUNT_VERSION UMRK_RA_ACCOUNT_PASSWORD
    umrk-ra-account UMRK_FLYCAST_RA_ROUTE /leaf/health http://127.0.0.1:8080)

failures=0
make_binary() { # markers to leave out...
    local out="$TMP_ROOT/flycast" marker skip
    printf '\177ELF' >"$out"
    for marker in "${MARKERS[@]}"; do
        for skip in "$@"; do
            [ "$marker" = "$skip" ] && continue 2
        done
        printf '\0%s\0' "$marker" >>"$out"
    done
}
make_records() {
    rm -rf "$TMP_ROOT/records"
    mkdir -p "$TMP_ROOT/records"
    printf 'standalone-ra-account-v1\n' >"$TMP_ROOT/records/ra-account-v1"
    printf 'umrk-flycast-ra-route-v1\n' >"$TMP_ROOT/records/ra-route-v1"
}
expect() { # pass|fail, name
    local want="$1" name="$2" got
    if python3 "$CHECK" "$TMP_ROOT/flycast" "$TMP_ROOT/records" >"$TMP_ROOT/out" 2>&1; then
        got=pass
    else
        got=fail
    fi
    if [ "$got" = "$want" ]; then
        printf 'ok   %s\n' "$name"
    else
        printf 'FAIL %s (%s, wanted %s)\n' "$name" "$got" "$want" >&2
        cat "$TMP_ROOT/out" >&2
        failures=$((failures + 1))
    fi
}

make_binary
make_records
expect pass "a binary with every marker and both records"
python3 "$CHECK" "$TMP_ROOT/flycast" "$ROOT_DIR/config/mlp1" >/dev/null
printf 'ok   the repository records name their capabilities\n'

for marker in "${MARKERS[@]}"; do
    make_binary "$marker"
    make_records
    expect fail "binary without $marker"
done

make_binary
make_records
rm "$TMP_ROOT/records/ra-route-v1"
expect fail "ra-route-v1 record missing"

make_records
printf 'standalone-ra-account-v2\n' >"$TMP_ROOT/records/ra-account-v1"
expect fail "ra-account-v1 naming another contract"

make_records
printf 'umrk-flycast-ra-route-v2\n' >"$TMP_ROOT/records/ra-route-v1"
expect fail "ra-route-v1 naming another capability"

if [ "$failures" -ne 0 ]; then
    echo "binary capability checks: $failures failure(s)" >&2
    exit 1
fi
echo "binary capability checks passed"
