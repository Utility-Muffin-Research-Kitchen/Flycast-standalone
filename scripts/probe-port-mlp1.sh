#!/usr/bin/env bash
set -euo pipefail

# This marker asks jawakad to perform its production direct-DRM handoff.
# LEAF_PM_RUNTIME_COMPAT_GOTHIC_MACHISMO_VULKAN_ROTATE=1

PROBE_ROOT="${SDCARD_PATH:-/mnt/sdcard}/.userdata/${PLATFORM:-mlp1}/flycast-probe-v2.6"
ROM_PATH="${FLYCAST_PROBE_ROM:-}"

if [ -z "$ROM_PATH" ]; then
    rom_roots="${ROMS_PATHS:-${ROMS_PATH:-${SDCARD_PATH:-/mnt/sdcard}/Roms}}"
    old_ifs="$IFS"
    IFS=:
    for rom_root in $rom_roots; do
        for candidate in \
            "$rom_root/DC/Crazy Taxi (USA).chd" \
            "$rom_root/DC/Crazy Taxi (USA).gdi" \
            "$rom_root/DC/Crazy Taxi (USA).cdi"; do
            if [ -f "$candidate" ]; then
                ROM_PATH="$candidate"
                break 2
            fi
        done
    done
    IFS="$old_ifs"
fi

if [ -z "$ROM_PATH" ] || [ ! -f "$ROM_PATH" ]; then
    echo "Crazy Taxi probe ROM not found in ROMS_PATHS: ${ROMS_PATHS:-unset}" >&2
    exit 1
fi

# PortMaster may prepare its DRM rotation shim after detecting the marker.
# Standalone Flycast performs the MLP1 rotation itself.
unset LD_PRELOAD
export LEAF_PM_RUNTIME_COMPAT_GOTHIC_MACHISMO_VULKAN_ROTATE=0

export FLYCAST_PROBE=1
export USERDATA_PATH="$PROBE_ROOT/userdata"
export LOGS_PATH="$PROBE_ROOT/logs"
export UMRK_RUNTIME_PATH="$PROBE_ROOT/runtime"

override_file="$PROBE_ROOT/probe-overrides.txt"
if [ -f "$override_file" ]; then
    IFS= read -r FLYCAST_CONFIG_OVERRIDES <"$override_file" || true
    export FLYCAST_CONFIG_OVERRIDES
fi

if [ "${FLYCAST_PROBE_PREFLIGHT:-0}" = "1" ]; then
    test -x "$PROBE_ROOT/bin/flycast"
    test -x "$PROBE_ROOT/launch.sh"
    printf 'probe_root=%s\nrom=%s\noverrides=%s\n' \
        "$PROBE_ROOT" "$ROM_PATH" "${FLYCAST_CONFIG_OVERRIDES:-none}"
    exit 0
fi

exec timeout 600 "$PROBE_ROOT/launch.sh" "$ROM_PATH"
