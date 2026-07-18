#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="${FLYCAST_SOURCE_DIR:-$ROOT_DIR/workdir/mlp1/flycast}"

# shellcheck source=../upstream.env
. "$ROOT_DIR/upstream.env"

mkdir -p "$(dirname "$SOURCE_DIR")"

if [ ! -d "$SOURCE_DIR/.git" ]; then
    git clone --filter=blob:none "$FLYCAST_UPSTREAM_URL" "$SOURCE_DIR"
fi

git -C "$SOURCE_DIR" fetch --force origin \
    "refs/tags/$FLYCAST_UPSTREAM_TAG:refs/tags/$FLYCAST_UPSTREAM_TAG"

tag_sha="$(git -C "$SOURCE_DIR" rev-parse "$FLYCAST_UPSTREAM_TAG^{commit}")"
if [ "$tag_sha" != "$FLYCAST_UPSTREAM_SHA" ]; then
    echo "Flycast tag mismatch: $FLYCAST_UPSTREAM_TAG" >&2
    echo "expected: $FLYCAST_UPSTREAM_SHA" >&2
    echo "actual:   $tag_sha" >&2
    exit 1
fi

# Recover a clone interrupted before its initial checkout. A normal edited
# checkout is still rejected below.
if [ ! -f "$SOURCE_DIR/CMakeLists.txt" ]; then
    git -C "$SOURCE_DIR" checkout --detach "$FLYCAST_UPSTREAM_SHA"
fi

if [ -n "$(git -C "$SOURCE_DIR" status --short --untracked-files=no)" ]; then
    echo "Flycast source checkout has tracked changes: $SOURCE_DIR" >&2
    echo "Refusing to overwrite an edited source tree." >&2
    exit 1
fi

git -C "$SOURCE_DIR" checkout --detach "$FLYCAST_UPSTREAM_SHA"
git -C "$SOURCE_DIR" submodule sync --recursive
git -C "$SOURCE_DIR" submodule update --init --recursive --depth 1

actual_sha="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
if [ "$actual_sha" != "$FLYCAST_UPSTREAM_SHA" ]; then
    echo "Flycast checkout mismatch after checkout: $actual_sha" >&2
    exit 1
fi

printf 'Flycast source ready: %s (%s)\n' \
    "$FLYCAST_UPSTREAM_TAG" "$actual_sha"
