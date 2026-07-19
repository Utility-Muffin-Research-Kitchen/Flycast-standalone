#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER="${DOCKER:-docker}"
TOOLCHAIN_IMAGE="${TOOLCHAIN_IMAGE:-ghcr.io/utility-muffin-research-kitchen/mlp1-toolchain:local}"
BUILD_JOBS="${BUILD_JOBS:-}"
MLP1_BUILD_PROFILE="${MLP1_BUILD_PROFILE:-perf}"
SOURCE_DIR="${FLYCAST_SOURCE_DIR:-$ROOT_DIR/workdir/mlp1/flycast}"
BUILD_DIR="${MLP1_BUILD_DIR:-$ROOT_DIR/output/mlp1/cmake}"
ARTIFACT_DIR="${MLP1_ARTIFACT_DIR:-$ROOT_DIR/output/mlp1/build}"

if ! "$DOCKER" image inspect "$TOOLCHAIN_IMAGE" >/dev/null 2>&1; then
    echo "missing Docker image: $TOOLCHAIN_IMAGE" >&2
    echo "build it with: make -C ../mlp1-toolchain image" >&2
    exit 1
fi

"$ROOT_DIR/scripts/fetch-upstream.sh"

mkdir -p "$BUILD_DIR" "$ARTIFACT_DIR"

"$DOCKER" run --rm \
    -v "$ROOT_DIR":/build \
    -v "$ROOT_DIR/../mlp1-toolchain/flags":/umrk-flags:ro \
    -w /build \
    -e BUILD_JOBS="$BUILD_JOBS" \
    -e MLP1_BUILD_PROFILE="$MLP1_BUILD_PROFILE" \
    "$TOOLCHAIN_IMAGE" \
    bash /build/scripts/build-mlp1-in-docker.sh

image_id="$("$DOCKER" image inspect "$TOOLCHAIN_IMAGE" --format '{{.Id}}')"
binary_sha="$(shasum -a 256 "$ARTIFACT_DIR/bin/flycast" | awk '{print $1}')"
source_sha="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
source_date_epoch="$(git -C "$SOURCE_DIR" show -s --format=%ct HEAD)"
dynamic_dependencies="$(
    awk -F'[][]' '
        /Shared library:/ {
            if (count++ > 0) {
                printf ", "
            }
            printf "\"%s\"", $2
        }
        END {
            if (count == 0) {
                printf ""
            }
        }
    ' "$ARTIFACT_DIR/provenance/elf-dynamic.txt"
)"

# shellcheck source=upstream.env
. "$ROOT_DIR/upstream.env"

cat >"$ARTIFACT_DIR/build-manifest.json" <<EOF
{
  "id": "flycast_standalone",
  "name": "Flycast Standalone",
  "platform": "mlp1",
  "kind": "standalone-emulator",
  "upstream_url": "$FLYCAST_UPSTREAM_URL",
  "upstream_tag": "$FLYCAST_UPSTREAM_TAG",
  "upstream_sha": "$source_sha",
  "source_date_epoch": $source_date_epoch,
  "toolchain_image": "$TOOLCHAIN_IMAGE",
  "toolchain_image_id": "$image_id",
  "target_soc": "rk3566",
  "target_cpu": "cortex-a55",
  "build_profile": "$MLP1_BUILD_PROFILE",
  "frontend": "standalone-sdl2",
  "renderer": "opengles",
  "debug_logging": false,
  "host_sdl": true,
  "vulkan": false,
  "binary": "bin/flycast",
  "binary_sha256": "$binary_sha",
  "dynamic_dependencies": [$dynamic_dependencies],
  "patches_inventory": "provenance/patches.sha256",
  "submodules_inventory": "provenance/submodules.txt",
  "build_flags_inventory": "provenance/build-flags.env",
  "elf_dependencies_inventory": "provenance/elf-dynamic.txt"
}
EOF

printf 'Built Flycast %s for MLP1: %s\n' \
    "$FLYCAST_UPSTREAM_TAG" "$binary_sha"
