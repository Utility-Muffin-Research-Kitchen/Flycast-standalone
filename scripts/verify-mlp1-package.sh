#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="${1:-$ROOT_DIR/output/mlp1/flycast}"
MANIFEST="$PACKAGE_DIR/manifest.json"

for command_name in jq shasum file; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "missing package verification command: $command_name" >&2
        exit 1
    fi
done

for path in \
    "$PACKAGE_DIR/bin/flycast" \
    "$PACKAGE_DIR/launch.sh" \
    "$PACKAGE_DIR/defaults/emu.cfg" \
    "$PACKAGE_DIR/defaults/config.version" \
    "$PACKAGE_DIR/defaults/SDL_Loong Gamepad.cfg" \
    "$PACKAGE_DIR/licenses/Flycast-GPL-2.0.txt" \
    "$PACKAGE_DIR/licenses/THIRD-PARTY-NOTICES.txt" \
    "$PACKAGE_DIR/provenance/build-manifest.json" \
    "$PACKAGE_DIR/provenance/build-flags.env" \
    "$PACKAGE_DIR/provenance/elf-dynamic.txt" \
    "$PACKAGE_DIR/provenance/patches.sha256" \
    "$PACKAGE_DIR/provenance/submodules.txt" \
    "$MANIFEST"; do
    if [ ! -f "$path" ]; then
        echo "missing required Flycast package file: $path" >&2
        exit 1
    fi
done

if [ ! -x "$PACKAGE_DIR/bin/flycast" ] || [ ! -x "$PACKAGE_DIR/launch.sh" ]; then
    echo "Flycast binary and launch.sh must be executable" >&2
    exit 1
fi

if find "$PACKAGE_DIR" -type l -print -quit | grep -q .; then
    echo "Flycast package must be FAT32-safe and contain no symlinks" >&2
    exit 1
fi

bash -n "$PACKAGE_DIR/launch.sh"
jq -e '
    .id == "flycast_standalone" and
    .platform == "mlp1" and
    .kind == "standalone-emulator" and
    .package_schema_version == 1 and
    (.config_schema_version | type == "number") and
    (.dynamic_dependencies | type == "array" and length > 0) and
    (.files | type == "array" and length > 0)
' "$MANIFEST" >/dev/null

# shellcheck source=../upstream.env
. "$ROOT_DIR/upstream.env"
manifest_tag="$(jq -r '.upstream_tag' "$MANIFEST")"
manifest_sha="$(jq -r '.upstream_sha' "$MANIFEST")"
if [ "$manifest_tag" != "$FLYCAST_UPSTREAM_TAG" ] ||
   [ "$manifest_sha" != "$FLYCAST_UPSTREAM_SHA" ]; then
    echo "manifest upstream identity does not match upstream.env" >&2
    exit 1
fi

config_version="$(tr -d '[:space:]' <"$PACKAGE_DIR/defaults/config.version")"
manifest_config_version="$(jq -r '.config_schema_version' "$MANIFEST")"
if [ "$config_version" != "$manifest_config_version" ]; then
    echo "manifest config schema version does not match packaged default" >&2
    exit 1
fi

binary_sha="$(shasum -a 256 "$PACKAGE_DIR/bin/flycast" | awk '{print $1}')"
manifest_binary_sha="$(jq -r '.binary_sha256' "$MANIFEST")"
if [ "$binary_sha" != "$manifest_binary_sha" ]; then
    echo "packaged Flycast binary checksum does not match manifest" >&2
    exit 1
fi

expected_files="$(mktemp)"
actual_files="$(mktemp)"
trap 'rm -f "$expected_files" "$actual_files"' EXIT

jq -r '.files[].path' "$MANIFEST" | LC_ALL=C sort >"$expected_files"
(
    cd "$PACKAGE_DIR"
    find . -type f ! -path './manifest.json' -print |
        sed 's#^\./##' |
        LC_ALL=C sort
) >"$actual_files"

if ! diff -u "$expected_files" "$actual_files"; then
    echo "manifest file inventory does not match package contents" >&2
    exit 1
fi

while IFS=$'\t' read -r expected_sha relative_path; do
    actual_sha="$(shasum -a 256 "$PACKAGE_DIR/$relative_path" | awk '{print $1}')"
    if [ "$actual_sha" != "$expected_sha" ]; then
        echo "package checksum mismatch: $relative_path" >&2
        exit 1
    fi
done < <(jq -r '.files[] | [.sha256, .path] | @tsv' "$MANIFEST")

file "$PACKAGE_DIR/bin/flycast" |
    grep -q 'ELF 64-bit LSB.*ARM aarch64'

for forbidden in BIOS Roms Saves States userdata flycast.log emu.cfg.save; do
    if find "$PACKAGE_DIR" -mindepth 1 \
        \( -name "$forbidden" -o -name "$forbidden.*" \) -print -quit |
        grep -q .; then
        echo "mutable or user-provided content found in package: $forbidden" >&2
        exit 1
    fi
done

printf 'Verified Flycast MLP1 package: %s files, binary %s\n' \
    "$(jq '.files | length' "$MANIFEST")" "$binary_sha"
