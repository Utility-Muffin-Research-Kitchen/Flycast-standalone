#!/usr/bin/env bash
# Fetch the lock-verified build flags for the MLP1 toolchain. Output:
# workdir/build-inputs/flags/, verified against locks/build-inputs.lock.json
# (archive bytes and the two flag files themselves). The build mounts this
# directory, never an arbitrary sibling checkout.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="$ROOT_DIR/locks/build-inputs.lock.json"
SOURCES_DIR="${1:-$ROOT_DIR/workdir/sources}"
OUT_DIR="$ROOT_DIR/workdir/build-inputs"

# The two hash-locked flag files are included in the source distribution.
if [ -f "$ROOT_DIR/corresponding-source.json" ]; then
    python3 "$ROOT_DIR/scripts/dist-source.py" verify
    exit 0
fi

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

size_of() {
    if stat -f %z "$1" >/dev/null 2>&1; then stat -f %z "$1"; else stat -c %s "$1"; fi
}

read -r filename expected_size expected_sha url < <(python3 - "$LOCK" <<'PY'
import json
import sys
archive = json.load(open(sys.argv[1], encoding="utf-8"))["flags"]["archive"]
print(archive["filename"], archive["size"], archive["sha256"], archive["url"])
PY
)

mkdir -p "$SOURCES_DIR"
archive="$SOURCES_DIR/$filename"
need_download=1
if [ -f "$archive" ] && \
   [ "$(size_of "$archive")" = "$expected_size" ] && \
   [ "$(sha256_of "$archive")" = "$expected_sha" ]; then
    need_download=0
fi
# The CONTENT check below pins the flag files themselves; the archive bytes
# are only a receipt, because GitHub tarballs are re-encoded occasionally
# (observed 2026-09-20: 12095 bytes via the API, 12081 via the web URL,
# identical extracted contents). Never let the receipt alone block a build.
if [ "$need_download" -eq 1 ]; then
    tmp="$SOURCES_DIR/.download-$filename"
    rm -f "$tmp"
    curl -fL --retry 3 --output "$tmp" "$url"
    actual_size="$(size_of "$tmp")"
    actual_sha="$(sha256_of "$tmp")"
    if [ "$actual_size" = "$expected_size" ] && [ "$actual_sha" = "$expected_sha" ]; then
        mv -f "$tmp" "$archive"
    else
        echo "archive receipt drifted (expected $expected_size/$expected_sha," >&2
        echo "got $actual_size/$actual_sha); extracted file hashes remain authoritative" >&2
        mv -f "$tmp" "$archive"
    fi
fi
echo "OK $filename"

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
tar -xzf "$archive" -C "$OUT_DIR" --strip-components=1
if [ ! -d "$OUT_DIR/flags" ]; then
    echo "flags/ missing in the extracted archive" >&2
    exit 1
fi

# Verify the two flag files byte-for-byte, independently of the archive hash.
python3 - "$LOCK" "$OUT_DIR" <<'PY'
import hashlib
import json
import os
import sys

lock = json.load(open(sys.argv[1], encoding="utf-8"))
root = sys.argv[2]
for entry in lock["flags"]["files"]:
    path = os.path.join(root, entry["path"])
    if not os.path.isfile(path):
        raise SystemExit(f"locked flag file missing after extract: {entry['path']}")
    actual = hashlib.sha256(open(path, "rb").read()).hexdigest()
    if actual != entry["sha256"]:
        raise SystemExit(
            f"flag file {entry['path']} mismatch: expected {entry['sha256']} got {actual}"
        )
print("flags files verified:", ", ".join(e["path"] for e in lock["flags"]["files"]))
PY

echo "build inputs ready: $OUT_DIR/flags"
