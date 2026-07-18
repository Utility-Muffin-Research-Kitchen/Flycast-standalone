#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -n "${UMRK_ENV_FILE:-}" ] && [ -f "$UMRK_ENV_FILE" ]; then
    # shellcheck source=/dev/null
    . "$UMRK_ENV_FILE"
elif [ -n "${SDCARD_PATH:-}" ] && [ -n "${PLATFORM:-}" ] &&
     [ -f "$SDCARD_PATH/.system/leaf/platforms/$PLATFORM/launcher/env.sh" ]; then
    # shellcheck source=/dev/null
    . "$SDCARD_PATH/.system/leaf/platforms/$PLATFORM/launcher/env.sh"
fi

if [ "$#" -ne 1 ]; then
    echo "usage: $0 ROM" >&2
    exit 2
fi

ROM_PATH="$1"
if [ ! -f "$ROM_PATH" ]; then
    echo "Flycast ROM not found: $ROM_PATH" >&2
    exit 1
fi

: "${PLATFORM:=mlp1}"
: "${USERDATA_PATH:=${SDCARD_PATH:-/mnt/sdcard}/.userdata/$PLATFORM}"
: "${LOGS_PATH:=$USERDATA_PATH/logs}"
: "${UMRK_RUNTIME_PATH:=${TMPDIR:-/tmp}/jawaka-runtime}"

STATE_ROOT="$USERDATA_PATH/flycast"
CONFIG_HOME="$STATE_ROOT/config"
DATA_HOME="$STATE_ROOT/data"
CACHE_HOME="$STATE_ROOT/cache"
HOME_DIR="$STATE_ROOT/home"
CONFIG_DIR="$CONFIG_HOME/flycast"
DATA_DIR="$DATA_HOME/flycast"
LOG_FILE="$LOGS_PATH/flycast.log"

mkdir -p "$CONFIG_DIR/mappings" "$DATA_DIR" "$CACHE_HOME" "$HOME_DIR" \
    "$LOGS_PATH" "$UMRK_RUNTIME_PATH/flycast"

if [ ! -f "$CONFIG_DIR/emu.cfg" ]; then
    cp "$ROOT_DIR/defaults/emu.cfg" "$CONFIG_DIR/emu.cfg"
fi
if [ ! -f "$CONFIG_DIR/mappings/SDL_Loong Gamepad.cfg" ]; then
    cp "$ROOT_DIR/defaults/SDL_Loong Gamepad.cfg" \
        "$CONFIG_DIR/mappings/SDL_Loong Gamepad.cfg"
fi

export HOME="$HOME_DIR"
export XDG_CONFIG_HOME="$CONFIG_HOME"
export XDG_DATA_HOME="$DATA_HOME"
export XDG_CACHE_HOME="$CACHE_HOME"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/var/run}"
export FLYCAST_BIOS_PATH="${BIOS_PATHS:-${BIOS_PATH:-}}"

export SDL_VIDEODRIVER=kmsdrm
export SDL_KMSDRM_REQUIRE_DRM_MASTER=1
export SDL_AUDIODRIVER=pulseaudio
export PULSE_SERVER="${PULSE_SERVER:-unix:/tmp/pulse-socket}"

config_override="config:rend.ShowFPS=no"
if [ "${FLYCAST_PROBE:-0}" = "1" ]; then
    config_override="config:rend.ShowFPS=yes"
fi
if [ -n "${FLYCAST_CONFIG_OVERRIDES:-}" ]; then
    config_override="$config_override,$FLYCAST_CONFIG_OVERRIDES"
fi

cd "$ROOT_DIR"
: >"$LOG_FILE"
exec "$ROOT_DIR/bin/flycast" \
    -config "$config_override" \
    "$ROM_PATH" >>"$LOG_FILE" 2>&1
