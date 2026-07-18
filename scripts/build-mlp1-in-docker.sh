#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR=/build/workdir/mlp1/flycast
BUILD_DIR=/build/output/mlp1/cmake
ARTIFACT_DIR=/build/output/mlp1/build

# shellcheck source=/dev/null
. /umrk-flags/mlp1-build-flags.env

jobs="${BUILD_JOBS:-}"
if [ -z "$jobs" ]; then
    jobs="$(nproc)"
fi

mkdir -p "$BUILD_DIR" "$ARTIFACT_DIR/bin" "$ARTIFACT_DIR/provenance"

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
EOF
