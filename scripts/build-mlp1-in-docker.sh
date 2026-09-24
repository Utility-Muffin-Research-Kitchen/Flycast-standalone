#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR=/build/workdir/mlp1/flycast
BUILD_DIR=/build/output/mlp1/cmake
ARTIFACT_DIR=/build/output/mlp1/build

# shellcheck source=/dev/null
. /umrk-flags/mlp1-build-flags.env

# build-mlp1.sh passes the triple the lock records; the image exports its own.
if [ -z "${UMRK_LOCKED_CROSS_TRIPLE:-}" ] ||
   [ "${CROSS_TRIPLE:-}" != "$UMRK_LOCKED_CROSS_TRIPLE" ]; then
    echo "build lock mismatch: toolchain cross triple '${CROSS_TRIPLE:-}'," \
        "locked '${UMRK_LOCKED_CROSS_TRIPLE:-}'" >&2
    exit 1
fi

jobs="${BUILD_JOBS:-}"
if [ -z "$jobs" ]; then
    jobs="$(nproc)"
fi

# The source tree is bind-mounted from the host, so its ownership does not match
# the container user and git refuses to read it without this exception.
git config --global --add safe.directory "$SOURCE_DIR"

SOURCE_DATE_EPOCH="$(git -C "$SOURCE_DIR" show -s --format=%ct HEAD)"
export SOURCE_DATE_EPOCH

mkdir -p "$BUILD_DIR" "$ARTIFACT_DIR/bin" "$ARTIFACT_DIR/provenance"

# Build from scratch every time. cmake --fresh regenerates the build system but
# leaves object files, so an earlier build with a different toolchain image can
# be relinked into the distributable binary. That is not hypothetical: a stale
# object compiled with the locally tagged image left a second GCC identifier in
# .comment. A clean tree is what "two clean builds must match" means.
rm -rf "$BUILD_DIR"

# Flycast's ENABLE_LOG emits high-frequency SH4/REIOS debug events. On the
# MLP1, redirecting that stream to the SD card is enough to disrupt audio.
cmake -S "$SOURCE_DIR" -B "$BUILD_DIR" --fresh \
    -DCMAKE_TOOLCHAIN_FILE="$CMAKE_TOOLCHAIN_FILE" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_FLAGS_RELEASE="$UMRK_MLP1_PROFILE_CFLAGS" \
    -DCMAKE_CXX_FLAGS_RELEASE="$UMRK_MLP1_PROFILE_CXXFLAGS" \
    -DCMAKE_EXE_LINKER_FLAGS="$UMRK_MLP1_PROFILE_LDFLAGS" \
    -DLIBRETRO=OFF \
    -DENABLE_CTEST=OFF \
    -DTEST_AUTOMATION=OFF \
    -DENABLE_LOG=OFF \
    -DUSE_GLES=ON \
    -DUSE_GLES2=OFF \
    -DUSE_OPENGL=ON \
    -DUSE_VULKAN=OFF \
    -DUSE_DX9=OFF \
    -DUSE_DX11=OFF \
    -DUSE_HOST_SDL=ON \
    -DUSE_HOST_LIBZIP=OFF \
    -DUSE_OPENMP=ON \
    -DUSE_DISCORD=OFF \
    -DLIBUSB_ENABLE_UDEV=OFF

cmake --build "$BUILD_DIR" --parallel "$jobs"

install -m 0755 "$BUILD_DIR/flycast" "$ARTIFACT_DIR/bin/flycast"

cmake -LAH -N "$BUILD_DIR" >"$ARTIFACT_DIR/provenance/cmake-cache.txt"
git -C "$SOURCE_DIR" submodule status --recursive \
    >"$ARTIFACT_DIR/provenance/submodules.txt"
find /build/patches -maxdepth 1 -type f -name '*.patch' -print0 |
    LC_ALL=C sort -z |
    while IFS= read -r -d '' patch; do
        printf '%s  %s\n' \
            "$(sha256sum "$patch" | awk '{print $1}')" \
            "${patch#/build/}"
    done >"$ARTIFACT_DIR/provenance/patches.sha256"
"$CC" --version >"$ARTIFACT_DIR/provenance/cc-version.txt"
"$CXX" --version >"$ARTIFACT_DIR/provenance/cxx-version.txt"
cmake --version >"$ARTIFACT_DIR/provenance/cmake-version.txt"
"$CROSS_TRIPLE-readelf" -d "$ARTIFACT_DIR/bin/flycast" \
    >"$ARTIFACT_DIR/provenance/elf-dynamic.txt"
"$CROSS_TRIPLE-readelf" --version-info "$ARTIFACT_DIR/bin/flycast" \
    >"$ARTIFACT_DIR/provenance/elf-version-info.txt"

cat >"$ARTIFACT_DIR/provenance/build-flags.env" <<EOF
UMRK_MLP1_BUILD_PROFILE=$UMRK_MLP1_BUILD_PROFILE
UMRK_MLP1_TARGET_SOC=$UMRK_MLP1_TARGET_SOC
UMRK_MLP1_TARGET_CPU=$UMRK_MLP1_TARGET_CPU
UMRK_MLP1_PROFILE_CFLAGS=$UMRK_MLP1_PROFILE_CFLAGS
UMRK_MLP1_PROFILE_CXXFLAGS=$UMRK_MLP1_PROFILE_CXXFLAGS
UMRK_MLP1_PROFILE_LDFLAGS=$UMRK_MLP1_PROFILE_LDFLAGS
SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH
EOF
