#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCK="$ROOT_DIR/locks/build-inputs.lock.json"
DOCKER="${DOCKER:-docker}"
TOOLCHAIN_IMAGE="${TOOLCHAIN_IMAGE:-$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["mlp1_toolchain_image"])' "$LOCK")}"
BUILD_JOBS="${BUILD_JOBS:-}"
MLP1_BUILD_PROFILE="${MLP1_BUILD_PROFILE:-perf}"
SOURCE_DIR="${FLYCAST_SOURCE_DIR:-$ROOT_DIR/workdir/mlp1/flycast}"
BUILD_DIR="${MLP1_BUILD_DIR:-$ROOT_DIR/output/mlp1/cmake}"
ARTIFACT_DIR="${MLP1_ARTIFACT_DIR:-$ROOT_DIR/output/mlp1/build}"

if ! "$DOCKER" image inspect "$TOOLCHAIN_IMAGE" >/dev/null 2>&1; then
    # A clean clone starts without the lock-recorded image. The digest is
    # immutable and public, so pulling it is a documented pinned input, not a
    # moving dependency. A failed pull (for example a development image that was
    # never built) still stops the build with the explicit remedy.
    echo "pulling Docker image: $TOOLCHAIN_IMAGE" >&2
    if ! "$DOCKER" pull "$TOOLCHAIN_IMAGE"; then
        echo "could not obtain Docker image: $TOOLCHAIN_IMAGE" >&2
        echo "pull the lock-recorded published image, or build a development image" >&2
        echo "with make -C ../mlp1-toolchain image and pass TOOLCHAIN_IMAGE explicitly" >&2
        exit 1
    fi
fi

# The lock fixes the toolchain platform and cross triple, not just the image
# digest: an override image for toolchain development must still build for the
# same target, or the build stops here.
image_platform="$("$DOCKER" image inspect "$TOOLCHAIN_IMAGE" --format '{{.Os}}/{{.Architecture}}')"
python3 "$ROOT_DIR/scripts/check-build-lock.py" toolchain "$LOCK" "$image_platform"
locked_cross_triple="$(python3 "$ROOT_DIR/scripts/check-build-lock.py" cross-triple "$LOCK")"

# shellcheck source=upstream.env
. "$ROOT_DIR/upstream.env"
# The package version is declared once, in upstream.env. Pak Rat and the
# release trigger accept exactly three numeric components, so anything else
# (a suffix, a missing component) stops the build before it starts.
if ! [[ "${FLYCAST_PACKAGE_VERSION:-}" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    echo "FLYCAST_PACKAGE_VERSION must be MAJOR.MINOR.PATCH: '${FLYCAST_PACKAGE_VERSION:-}'" >&2
    exit 1
fi

"$ROOT_DIR/scripts/fetch-upstream.sh"
"$ROOT_DIR/scripts/fetch-build-inputs.sh"

mkdir -p "$BUILD_DIR" "$ARTIFACT_DIR"

"$DOCKER" run --rm \
    --network=none \
    -v "$ROOT_DIR":/build \
    -v "$ROOT_DIR/workdir/build-inputs/flags":/umrk-flags:ro \
    -w /build \
    -e BUILD_JOBS="$BUILD_JOBS" \
    -e MLP1_BUILD_PROFILE="$MLP1_BUILD_PROFILE" \
    -e UMRK_LOCKED_CROSS_TRIPLE="$locked_cross_triple" \
    "$TOOLCHAIN_IMAGE" \
    bash /build/scripts/build-mlp1-in-docker.sh

# Record the digest the lock pins, not the host's runtime image id. Docker's
# .Id is a per-host config digest and can differ between an arm64 macOS Docker
# and a GitHub arm64 runner even for the same image, which would put a
# machine-specific value into the packaged provenance. A dev build by tag has
# no digest, so fall back to the local id there.
if [[ "$TOOLCHAIN_IMAGE" == *@sha256:* ]]; then
    image_id="sha256:${TOOLCHAIN_IMAGE##*@sha256:}"
else
    image_id="$("$DOCKER" image inspect "$TOOLCHAIN_IMAGE" --format '{{.Id}}')"
fi
binary_sha="$(shasum -a 256 "$ARTIFACT_DIR/bin/flycast" | awk '{print $1}')"
source_sha="$FLYCAST_UPSTREAM_SHA"
source_date_epoch="$FLYCAST_SOURCE_DATE_EPOCH"
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

cat >"$ARTIFACT_DIR/build-manifest.json" <<EOF
{
  "id": "flycast_standalone",
  "name": "Flycast Standalone",
  "platform": "mlp1",
  "kind": "standalone-emulator",
  "package_version": "$FLYCAST_PACKAGE_VERSION",
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

printf 'Built Flycast %s (package %s) for MLP1: %s\n' \
    "$FLYCAST_UPSTREAM_TAG" "$FLYCAST_PACKAGE_VERSION" "$binary_sha"
