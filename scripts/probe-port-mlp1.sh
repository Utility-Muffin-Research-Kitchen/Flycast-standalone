#!/usr/bin/env bash
set -euo pipefail

# This marker asks jawakad to perform its production direct-DRM handoff.
# LEAF_PM_RUNTIME_COMPAT_GOTHIC_MACHISMO_VULKAN_ROTATE=1

PROBE_ROOT="${SDCARD_PATH:-/mnt/sdcard}/.userdata/${PLATFORM:-mlp1}/flycast-probe-v2.6"
ROM_PATH="${FLYCAST_PROBE_ROM:-/mnt/sdcard/Roms/DC/Crazy Taxi (USA).chd}"

# PortMaster may prepare its DRM rotation shim after detecting the marker.
# Standalone Flycast performs the MLP1 rotation itself.
unset LD_PRELOAD
export LEAF_PM_RUNTIME_COMPAT_GOTHIC_MACHISMO_VULKAN_ROTATE=0

export FLYCAST_PROBE=1
export USERDATA_PATH="$PROBE_ROOT/userdata"
export LOGS_PATH="$PROBE_ROOT/logs"
export UMRK_RUNTIME_PATH="$PROBE_ROOT/runtime"

exec timeout 600 "$PROBE_ROOT/launch.sh" "$ROM_PATH"
