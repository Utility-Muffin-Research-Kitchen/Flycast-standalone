#!/usr/bin/env bash
set -euo pipefail

# verify-mlp1-binary.sh with a stub adb on PATH that lists an online device.
# Without VERIFY_ON_DEVICE=1 the script must never push to or run anything on
# the device, whatever ADB_SERIAL says; with it, the ABI check must reach the
# listed device, or ADB_SERIAL's when set. A bad value, or an opt-in with no
# device, must fail. docker and file are stubbed too, so this needs no build,
# toolchain image or device.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFY="$ROOT_DIR/scripts/verify-mlp1-binary.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

STUB_BIN="$TMP_ROOT/bin"
ADB_LOG="$TMP_ROOT/adb.log"
mkdir -p "$STUB_BIN"

cat >"$STUB_BIN/adb" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$ADB_LOG"
if [ "${1:-}" = devices ]; then
    printf 'List of devices attached\n'
    if [ -n "${STUB_ADB_DEVICE:-}" ]; then
        printf '%s\tdevice\n' "$STUB_ADB_DEVICE"
    fi
fi
exit 0
EOF
cat >"$STUB_BIN/docker" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$STUB_BIN/file" <<'EOF'
#!/usr/bin/env bash
printf '%s: ELF 64-bit LSB executable, ARM aarch64, version 1 (SYSV)\n' "$1"
EOF
chmod 755 "$STUB_BIN/adb" "$STUB_BIN/docker" "$STUB_BIN/file"

# A binary carrying every capability marker, so the host checks pass.
BINARY="$TMP_ROOT/flycast"
printf '\177ELF' >"$BINARY"
for marker in retroachievements.org UMRK_RA_ACCOUNT_VERSION \
    UMRK_RA_ACCOUNT_PASSWORD umrk-ra-account UMRK_FLYCAST_RA_ROUTE \
    /leaf/health http://127.0.0.1:8080; do
    printf '\0%s\0' "$marker" >>"$BINARY"
done
chmod 755 "$BINARY"

failures=0
run() { # pass|fail, name, then VAR=value... for the environment
    local want="$1" name="$2" got
    shift 2
    : >"$ADB_LOG"
    if env -u VERIFY_ON_DEVICE -u ADB_SERIAL \
        PATH="$STUB_BIN:$PATH" ADB_LOG="$ADB_LOG" STUB_ADB_DEVICE=stub-mlp1 \
        DOCKER="$STUB_BIN/docker" TOOLCHAIN_IMAGE=stub MLP1_BINARY="$BINARY" \
        "$@" "$VERIFY" >"$TMP_ROOT/out" 2>&1; then
        got=pass
    else
        got=fail
    fi
    if [ "$got" != "$want" ]; then
        printf 'FAIL %s (%s, wanted %s)\n' "$name" "$got" "$want" >&2
        cat "$TMP_ROOT/out" >&2
        failures=$((failures + 1))
        return 1
    fi
}
expect_untouched() { # name, then VAR=value...
    local name="$1"
    shift
    run pass "$name" "$@" || return 0
    # Stricter than no push or shell: adb is not run at all.
    if [ -s "$ADB_LOG" ]; then
        printf 'FAIL %s (adb was run)\n' "$name" >&2
        cat "$ADB_LOG" >&2
        failures=$((failures + 1))
    else
        printf 'ok   %s\n' "$name"
    fi
}
expect_checked() { # name, serial, then VAR=value...
    local name="$1" serial="$2"
    shift 2
    run pass "$name" "$@" || return 0
    if grep -qxF -e "-s $serial push $BINARY /tmp/umrk-flycast-abi-check" "$ADB_LOG" &&
        grep -q -e "^-s $serial shell .*LD_TRACE_LOADED_OBJECTS=1" "$ADB_LOG" &&
        ! grep -Eq "(push|shell)" <(grep -v "^-s $serial " "$ADB_LOG"); then
        printf 'ok   %s\n' "$name"
    else
        printf 'FAIL %s (ABI check did not reach %s alone)\n' "$name" "$serial" >&2
        cat "$ADB_LOG" >&2
        failures=$((failures + 1))
    fi
}
expect_refused() { # name, then VAR=value...
    local name="$1"
    shift
    run fail "$name" "$@" || return 0
    if grep -Eq '(^| )(push|shell)( |$)' "$ADB_LOG"; then
        printf 'FAIL %s (refused, but touched the device)\n' "$name" >&2
        cat "$ADB_LOG" >&2
        failures=$((failures + 1))
    else
        printf 'ok   %s\n' "$name"
    fi
}

expect_untouched "no opt-in, a device online"
expect_untouched "no opt-in, ADB_SERIAL set" ADB_SERIAL=picked-mlp1
expect_untouched "VERIFY_ON_DEVICE=0" VERIFY_ON_DEVICE=0 ADB_SERIAL=picked-mlp1
expect_untouched "VERIFY_ON_DEVICE empty" VERIFY_ON_DEVICE=
expect_checked "VERIFY_ON_DEVICE=1, first online device" stub-mlp1 \
    VERIFY_ON_DEVICE=1
expect_checked "VERIFY_ON_DEVICE=1 honors ADB_SERIAL" picked-mlp1 \
    VERIFY_ON_DEVICE=1 ADB_SERIAL=picked-mlp1
expect_refused "VERIFY_ON_DEVICE=yes" VERIFY_ON_DEVICE=yes
expect_refused "VERIFY_ON_DEVICE=1, no device online" \
    VERIFY_ON_DEVICE=1 STUB_ADB_DEVICE=

if [ "$failures" -ne 0 ]; then
    echo "device check opt-in: $failures failure(s)" >&2
    exit 1
fi
echo "device check opt-in checks passed"
