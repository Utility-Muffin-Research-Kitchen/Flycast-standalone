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
: "${SDCARD_PATH:=/mnt/sdcard}"
: "${USERDATA_PATH:=$SDCARD_PATH/.userdata/$PLATFORM}"
: "${LOGS_PATH:=$USERDATA_PATH/logs}"
: "${BIOS_PATH:=$SDCARD_PATH/BIOS}"
: "${SAVES_PATH:=$SDCARD_PATH/Saves}"
: "${STATES_PATH:=$SDCARD_PATH/States}"
: "${CHEATS_PATH:=$SDCARD_PATH/Cheats}"
: "${UMRK_RUNTIME_PATH:=${TMPDIR:-/tmp}/jawaka-runtime}"

APP_STATE_ROOT="$USERDATA_PATH/flycast"
CONFIG_HOME="$APP_STATE_ROOT/config"
CACHE_HOME="$APP_STATE_ROOT/cache"
HOME_DIR="$APP_STATE_ROOT/home"
CONFIG_DIR="$CONFIG_HOME/flycast"
# Keep the established emulator-directory casing. The MLP1 SD card is FAT32:
# creating "flycast" fails when the existing "Flycast" directory is present,
# while Linux path lookup on the mount still requires the displayed casing.
SAVE_ROOT="$SAVES_PATH/Flycast"
STATE_SAVE_ROOT="$STATES_PATH/Flycast"
DATA_HOME="$SAVE_ROOT/xdg"
DATA_DIR="$DATA_HOME/flycast"
LOG_DIR="$LOGS_PATH/flycast"
LOG_FILE="$LOG_DIR/flycast.log"
RUNTIME_DIR="$UMRK_RUNTIME_PATH/flycast"
DEFAULTS_VERSION_FILE="$ROOT_DIR/defaults/config.version"
INSTALLED_VERSION_FILE="$CONFIG_DIR/.umrk-defaults-version"

if [ ! -f "$DEFAULTS_VERSION_FILE" ]; then
    echo "Flycast package is missing defaults/config.version" >&2
    exit 1
fi
DEFAULTS_VERSION="$(tr -d '[:space:]' <"$DEFAULTS_VERSION_FILE")"
case "$DEFAULTS_VERSION" in
    ''|*[!0-9]*)
        echo "invalid Flycast defaults version: $DEFAULTS_VERSION" >&2
        exit 1
        ;;
esac

mkdir -p "$CONFIG_DIR/mappings" "$DATA_DIR" "$CACHE_HOME" "$HOME_DIR" \
    "$SAVE_ROOT" "$STATE_SAVE_ROOT" "$LOG_DIR" "$RUNTIME_DIR"

if [ ! -f "$CONFIG_DIR/emu.cfg" ]; then
    cp "$ROOT_DIR/defaults/emu.cfg" "$CONFIG_DIR/emu.cfg"
    printf '%s\n' "$DEFAULTS_VERSION" >"$INSTALLED_VERSION_FILE"
elif [ ! -f "$INSTALLED_VERSION_FILE" ]; then
    # Version 1 has no destructive migration. Existing user choices are kept,
    # while device/storage invariants below are applied as virtual options.
    printf '%s\n' "$DEFAULTS_VERSION" >"$INSTALLED_VERSION_FILE"
fi
if [ ! -f "$CONFIG_DIR/mappings/SDL_Loong Gamepad.cfg" ]; then
    cp "$ROOT_DIR/defaults/SDL_Loong Gamepad.cfg" \
        "$CONFIG_DIR/mappings/SDL_Loong Gamepad.cfg"
fi

export HOME="$HOME_DIR"
export XDG_CONFIG_HOME="$CONFIG_HOME"
export XDG_DATA_HOME="$DATA_HOME"
export XDG_CACHE_HOME="$CACHE_HOME"
export XDG_RUNTIME_DIR="$RUNTIME_DIR"
export TMPDIR="$RUNTIME_DIR"

export SDL_VIDEODRIVER=kmsdrm
export SDL_KMSDRM_REQUIRE_DRM_MASTER=1
export SDL_AUDIODRIVER=pulseaudio
export PULSE_SERVER="${PULSE_SERVER:-unix:/tmp/pulse-socket}"

validate_virtual_path() {
    case "$2" in
        *','*|*';'*|*$'\n'*)
            echo "Flycast $1 path contains an unsupported config delimiter: $2" >&2
            exit 1
            ;;
    esac
}

validate_virtual_path BIOS_PATH "$BIOS_PATH"
validate_virtual_path SAVES_PATH "$SAVE_ROOT"
validate_virtual_path STATES_PATH "$STATE_SAVE_ROOT"
validate_virtual_path CHEATS_PATH "$CHEATS_PATH"
validate_virtual_path CONFIG_DIR "$CONFIG_DIR"

config_override=""
append_override() {
    if [ -n "$config_override" ]; then
        config_override="$config_override,$1"
    else
        config_override="$1"
    fi
}

# These are MLP1 safety/runtime invariants. Performance choices such as
# AutoSkipFrame and audio buffer size remain user/per-game configurable.
append_override "audio:backend=sdl2"
append_override "config:pvr.rend=0"
append_override "config:rend.PerStripSorting=yes"
append_override "config:rend.Resolution=480"
append_override "config:rend.Rotate90=yes"
append_override "config:rend.ThreadedRendering=yes"
append_override "config:rend.vsync=yes"
append_override "config:Dreamcast.BiosPath=$BIOS_PATH"
append_override "config:Dreamcast.VMUPath=$SAVE_ROOT"
append_override "config:Dreamcast.SavePath=$SAVE_ROOT"
append_override "config:Dreamcast.SavestatePath=$STATE_SAVE_ROOT"
append_override "config:Dreamcast.MappingsPath=$CONFIG_DIR/mappings"
append_override "config:Dreamcast.CheatPath=$CHEATS_PATH"
append_override "config:rend.ShowFPS=no"

if [ "${FLYCAST_PROBE:-0}" = "1" ]; then
    append_override "config:rend.ShowFPS=yes"
fi
if [ -n "${FLYCAST_CONFIG_OVERRIDES:-}" ]; then
    append_override "$FLYCAST_CONFIG_OVERRIDES"
fi

cd "$ROOT_DIR"
: >"$LOG_FILE"
exec "$ROOT_DIR/bin/flycast" \
    -config "$config_override" \
    "$ROM_PATH" >>"$LOG_FILE" 2>&1
