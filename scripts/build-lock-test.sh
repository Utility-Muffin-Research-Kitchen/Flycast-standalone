#!/usr/bin/env bash
set -euo pipefail

# Host checks for locks/build-inputs.lock.json enforcement. No network, no
# Docker, no upstream checkout: every case runs against copies of this
# repository's own lock and patches, or against synthetic inputs.
#
#   1. check-build-lock.py accepts the real inputs and rejects each kind of
#      drift (patch edited, added, removed, renamed; submodule moved, missing,
#      extra or not checked out; foreign toolchain platform or triple);
#   2. fetch-upstream.sh runs the patch check before it touches anything, so
#      a drifted series never reaches the source tree;
#   3. build-mlp1.sh refuses a toolchain image of another platform before it
#      fetches or builds.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="$ROOT_DIR/locks/build-inputs.lock.json"
CHECK="$ROOT_DIR/scripts/check-build-lock.py"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

failures=0
pass() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; failures=$((failures + 1)); }

expect_ok() {
    local name="$1"
    shift
    if "$@" >"$TMP_ROOT/out" 2>&1; then pass "$name"; else bad "$name"; cat "$TMP_ROOT/out" >&2; fi
}

expect_refused() {
    local name="$1"
    shift
    if "$@" >"$TMP_ROOT/out" 2>&1; then
        bad "$name (accepted)"
        cat "$TMP_ROOT/out" >&2
    elif grep -q 'build lock mismatch' "$TMP_ROOT/out"; then
        pass "$name"
    else
        bad "$name (failed for another reason)"
        cat "$TMP_ROOT/out" >&2
    fi
}

fresh_patches() {
    rm -rf "$TMP_ROOT/patches"
    cp -R "$ROOT_DIR/patches" "$TMP_ROOT/patches"
}

# --- patch series -----------------------------------------------------------
fresh_patches
expect_ok "patches: the committed series matches the lock" \
    python3 "$CHECK" patches "$LOCK" "$TMP_ROOT/patches"

first_patch="$(find "$TMP_ROOT/patches" -name '*.patch' | LC_ALL=C sort | head -1)"
printf '\n' >>"$first_patch"
expect_refused "patches: an edited patch" \
    python3 "$CHECK" patches "$LOCK" "$TMP_ROOT/patches"

fresh_patches
printf 'diff --git a/x b/x\n' >"$TMP_ROOT/patches/9999-unrecorded.patch"
expect_refused "patches: an unrecorded extra patch" \
    python3 "$CHECK" patches "$LOCK" "$TMP_ROOT/patches"

fresh_patches
rm -f "$(find "$TMP_ROOT/patches" -name '*.patch' | LC_ALL=C sort | tail -1)"
expect_refused "patches: a locked patch removed" \
    python3 "$CHECK" patches "$LOCK" "$TMP_ROOT/patches"

fresh_patches
first_patch="$(find "$TMP_ROOT/patches" -name '*.patch' | LC_ALL=C sort | head -1)"
mv "$first_patch" "$TMP_ROOT/patches/zz-$(basename "$first_patch")"
expect_refused "patches: a patch renamed out of its locked position" \
    python3 "$CHECK" patches "$LOCK" "$TMP_ROOT/patches"

# --- submodules -------------------------------------------------------------
python3 - "$LOCK" "$TMP_ROOT/submodules.good" <<'PY'
import json, sys
lock = json.load(open(sys.argv[1]))
with open(sys.argv[2], "w") as out:
    for row in lock["submodules"]["entries"]:
        out.write(f" {row['sha']} {row['path']} (heads/main)\n")
PY
expect_ok "submodules: the locked set" \
    python3 "$CHECK" submodules "$LOCK" "$TMP_ROOT/submodules.good"

sed '1s/^ \([0-9a-f]\)[0-9a-f]/ \10/' "$TMP_ROOT/submodules.good" >"$TMP_ROOT/submodules.moved"
if cmp -s "$TMP_ROOT/submodules.good" "$TMP_ROOT/submodules.moved"; then
    sed '1s/^ \([0-9a-f]\)[0-9a-f]/ \11/' "$TMP_ROOT/submodules.good" >"$TMP_ROOT/submodules.moved"
fi
expect_refused "submodules: one at another commit" \
    python3 "$CHECK" submodules "$LOCK" "$TMP_ROOT/submodules.moved"

sed '1s/^ /+/' "$TMP_ROOT/submodules.good" >"$TMP_ROOT/submodules.dirty"
expect_refused "submodules: one checked out away from its recorded commit" \
    python3 "$CHECK" submodules "$LOCK" "$TMP_ROOT/submodules.dirty"

sed '1s/^ /-/' "$TMP_ROOT/submodules.good" >"$TMP_ROOT/submodules.uninit"
expect_refused "submodules: one not initialized" \
    python3 "$CHECK" submodules "$LOCK" "$TMP_ROOT/submodules.uninit"

sed '1d' "$TMP_ROOT/submodules.good" >"$TMP_ROOT/submodules.missing"
expect_refused "submodules: one missing" \
    python3 "$CHECK" submodules "$LOCK" "$TMP_ROOT/submodules.missing"

cp "$TMP_ROOT/submodules.good" "$TMP_ROOT/submodules.extra"
printf ' %s core/deps/unlocked (heads/main)\n' "$(printf '%040d' 0)" >>"$TMP_ROOT/submodules.extra"
expect_refused "submodules: an unlocked extra" \
    python3 "$CHECK" submodules "$LOCK" "$TMP_ROOT/submodules.extra"

# --- toolchain --------------------------------------------------------------
locked_platform="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["toolchain"]["platform"])' "$LOCK")"
locked_triple="$(python3 "$CHECK" cross-triple "$LOCK")"
expect_ok "toolchain: the locked platform and triple" \
    python3 "$CHECK" toolchain "$LOCK" "$locked_platform" "$locked_triple"
expect_refused "toolchain: another platform" \
    python3 "$CHECK" toolchain "$LOCK" linux/amd64
expect_refused "toolchain: another cross triple" \
    python3 "$CHECK" toolchain "$LOCK" "$locked_platform" x86_64-linux-gnu

# --- wiring: the build scripts actually run the checks ----------------------
# A copy of the repository whose patch series has drifted. fetch-upstream.sh
# must stop at the lock check, before it clones or edits the source tree.
REPO_COPY="$TMP_ROOT/repo"
mkdir -p "$REPO_COPY"
cp -R "$ROOT_DIR/scripts" "$ROOT_DIR/locks" "$ROOT_DIR/patches" "$ROOT_DIR/upstream.env" \
    "$ROOT_DIR/build-mlp1.sh" "$REPO_COPY/"
printf '\n' >>"$(find "$REPO_COPY/patches" -name '*.patch' | LC_ALL=C sort | head -1)"
expect_refused "fetch-upstream.sh: refuses a drifted series before touching the source" \
    env FLYCAST_SOURCE_DIR="$TMP_ROOT/never-created/flycast" \
    "$REPO_COPY/scripts/fetch-upstream.sh"
if [ -e "$TMP_ROOT/never-created" ]; then
    bad "fetch-upstream.sh: created the source directory despite the lock mismatch"
fi

rm -rf "$REPO_COPY/patches"
cp -R "$ROOT_DIR/patches" "$REPO_COPY/patches"

# build-mlp1.sh with an image that reports another platform. The fake docker
# answers inspect only; any other call (a pull, a run) would be a failure.
FAKE_DOCKER="$TMP_ROOT/fake-docker"
cat >"$FAKE_DOCKER" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = image ] && [ "$2" = inspect ]; then
    case " $* " in
        *" --format "*) printf 'linux/amd64\n' ;;
    esac
    exit 0
fi
echo "fake docker: unexpected call: $*" >&2
exit 97
EOF
chmod 0755 "$FAKE_DOCKER"
expect_refused "build-mlp1.sh: refuses a toolchain image of another platform" \
    env DOCKER="$FAKE_DOCKER" FLYCAST_SOURCE_DIR="$TMP_ROOT/never-created/flycast" \
    "$REPO_COPY/build-mlp1.sh"
if [ -e "$TMP_ROOT/never-created" ]; then
    bad "build-mlp1.sh: fetched source despite the platform mismatch"
fi

if [ "$failures" -ne 0 ]; then
    echo "build lock checks: $failures failure(s)" >&2
    exit 1
fi
echo "build lock checks passed"
