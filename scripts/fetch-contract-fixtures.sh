#!/usr/bin/env bash
set -euo pipefail

# Fetch the shared leaf-contracts fixtures this consumer is tested against, at
# the revision pinned in locks/contracts.lock.json. The contract lives in the
# public leaf-contracts repository; nothing here depends on a private
# workspace checkout or on a sibling clone.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="$ROOT_DIR/locks/contracts.lock.json"
DEST_DIR="${CONTRACT_FIXTURES_DIR:-$ROOT_DIR/workdir/contracts}"

read_lock() {
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["leaf_contracts"][sys.argv[2]])' \
        "$LOCK" "$1"
}

commit="$(read_lock commit)"
prefix="$(read_lock raw_url_prefix)"

file_count="$(
    python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["leaf_contracts"]["files"]))' \
        "$LOCK"
)"

mkdir -p "$DEST_DIR"

index=0
while [ "$index" -lt "$file_count" ]; do
    path="$(
        python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["leaf_contracts"]["files"][int(sys.argv[2])]["path"])' \
            "$LOCK" "$index"
    )"
    expected_sha="$(
        python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["leaf_contracts"]["files"][int(sys.argv[2])]["sha256"])' \
            "$LOCK" "$index"
    )"
    destination="$DEST_DIR/$(basename "$path")"

    # A verified copy from an earlier run is reused, so the checks run offline.
    if [ -f "$destination" ] &&
       [ "$(shasum -a 256 "$destination" | awk '{print $1}')" = "$expected_sha" ]; then
        index=$((index + 1))
        continue
    fi

    url="$prefix/$commit/$path"
    if ! curl -fsSL --max-time 60 -o "$destination.download" "$url"; then
        echo "could not fetch the pinned contract fixture: $url" >&2
        rm -f "$destination.download"
        exit 1
    fi
    actual_sha="$(shasum -a 256 "$destination.download" | awk '{print $1}')"
    if [ "$actual_sha" != "$expected_sha" ]; then
        echo "contract fixture hash mismatch: $path" >&2
        echo "expected: $expected_sha" >&2
        echo "actual:   $actual_sha" >&2
        rm -f "$destination.download"
        exit 1
    fi
    mv "$destination.download" "$destination"
    index=$((index + 1))
done

printf 'leaf-contracts fixtures ready at %s (%s file%s)\n' \
    "$commit" "$file_count" "$([ "$file_count" -eq 1 ] || printf 's')"
