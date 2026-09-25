#!/usr/bin/env bash
set -euo pipefail

# The package version gate in verify-mlp1-package.sh, against copies of the
# assembled payload (make package-mlp1 first). The unmodified copy must pass;
# every manifest whose package_version is missing, suffixed, short, padded,
# different from upstream.env, off the upstream tag, or disagreeing with the
# packaged build provenance must be refused.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="${1:-$ROOT_DIR/output/mlp1/flycast}"
VERIFY="$ROOT_DIR/scripts/verify-mlp1-package.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

if [ ! -f "$PACKAGE_DIR/manifest.json" ]; then
    echo "no assembled package at $PACKAGE_DIR; run make package-mlp1 first" >&2
    exit 1
fi

# shellcheck source=../upstream.env
. "$ROOT_DIR/upstream.env"

failures=0
fresh() {
    rm -rf "$TMP_ROOT/package"
    cp -Rp "$PACKAGE_DIR" "$TMP_ROOT/package"
}
set_version() {
    jq --arg v "$1" '.package_version = $v' "$TMP_ROOT/package/manifest.json" \
        >"$TMP_ROOT/manifest.json"
    mv "$TMP_ROOT/manifest.json" "$TMP_ROOT/package/manifest.json"
}
expect_refused() {
    if "$VERIFY" "$TMP_ROOT/package" >"$TMP_ROOT/out" 2>&1; then
        printf 'FAIL %s (accepted)\n' "$1" >&2
        failures=$((failures + 1))
    elif grep -q 'package_version' "$TMP_ROOT/out"; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s (refused for another reason)\n' "$1" >&2
        cat "$TMP_ROOT/out" >&2
        failures=$((failures + 1))
    fi
}

fresh
if ! "$VERIFY" "$TMP_ROOT/package" >"$TMP_ROOT/out" 2>&1; then
    cat "$TMP_ROOT/out" >&2
    echo "FAIL the assembled package does not verify" >&2
    exit 1
fi
actual="$(jq -r '.package_version' "$TMP_ROOT/package/manifest.json")"
if [ "$actual" != "$FLYCAST_PACKAGE_VERSION" ]; then
    echo "FAIL manifest package_version '$actual', upstream.env '$FLYCAST_PACKAGE_VERSION'" >&2
    exit 1
fi
printf 'ok   the assembled package verifies as %s\n' "$actual"

fresh
jq 'del(.package_version)' "$TMP_ROOT/package/manifest.json" >"$TMP_ROOT/manifest.json"
mv "$TMP_ROOT/manifest.json" "$TMP_ROOT/package/manifest.json"
expect_refused "missing package_version"

major_minor="${FLYCAST_UPSTREAM_TAG#v}"
for bad in \
    "$FLYCAST_PACKAGE_VERSION-umrk1" \
    "$FLYCAST_PACKAGE_VERSION.1" \
    "$major_minor" \
    "v$FLYCAST_PACKAGE_VERSION" \
    "0$FLYCAST_PACKAGE_VERSION" \
    "$major_minor.99" \
    "9.9.0"; do
    fresh
    set_version "$bad"
    expect_refused "package_version '$bad'"
done

# The manifest agrees with upstream.env but the packaged provenance does not.
fresh
provenance="$TMP_ROOT/package/provenance/build-manifest.json"
jq '.package_version = "0.0.1"' "$provenance" >"$TMP_ROOT/provenance.json"
mv "$TMP_ROOT/provenance.json" "$provenance"
new_sha="$(shasum -a 256 "$provenance" | awk '{print $1}')"
jq --arg sha "$new_sha" \
    '(.files[] | select(.path == "provenance/build-manifest.json") | .sha256) = $sha' \
    "$TMP_ROOT/package/manifest.json" >"$TMP_ROOT/manifest.json"
mv "$TMP_ROOT/manifest.json" "$TMP_ROOT/package/manifest.json"
expect_refused "provenance package_version disagrees with the manifest"

if [ "$failures" -ne 0 ]; then
    echo "package version checks: $failures failure(s)" >&2
    exit 1
fi
echo "package version checks passed"
