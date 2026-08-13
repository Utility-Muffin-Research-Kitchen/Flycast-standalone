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
LEGACY_V1_MAPPING_SHA256="f3ccd1c95c184463964299cc2803b3b8455d7a706b42492bb0a747747ad01e6f"

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
fi
if [ ! -f "$CONFIG_DIR/mappings/SDL_Loong Gamepad.cfg" ]; then
    cp "$ROOT_DIR/defaults/SDL_Loong Gamepad.cfg" \
        "$CONFIG_DIR/mappings/SDL_Loong Gamepad.cfg"
fi

INSTALLED_VERSION=0
if [ -f "$INSTALLED_VERSION_FILE" ]; then
    INSTALLED_VERSION="$(tr -d '[:space:]' <"$INSTALLED_VERSION_FILE")"
    case "$INSTALLED_VERSION" in
        ''|*[!0-9]*)
            echo "invalid installed Flycast defaults version: $INSTALLED_VERSION" >&2
            exit 1
            ;;
    esac
fi

if [ "$INSTALLED_VERSION" -lt "$DEFAULTS_VERSION" ]; then
    # Version 2 changes the MLP1 Menu binding from Flycast's Exit action to its
    # native menu. Replace only the byte-identical version-1 mapping so user
    # controller customizations remain untouched.
    if [ "$INSTALLED_VERSION" -lt 2 ]; then
        mapping_file="$CONFIG_DIR/mappings/SDL_Loong Gamepad.cfg"
        mapping_sha="$(sha256sum "$mapping_file" | awk '{print $1}')"
        if [ "$mapping_sha" = "$LEGACY_V1_MAPPING_SHA256" ]; then
            cp "$ROOT_DIR/defaults/SDL_Loong Gamepad.cfg" "$mapping_file"
        fi
    fi
    # Version 3 attaches the Jump Pack (Purupuru) to controller 1's second
    # expansion slot so Dreamcast games can rumble; slot 1 keeps its VMU, which
    # is how the hardware was normally used. emu.cfg is only seeded on a fresh
    # install, so without this an existing install would never gain rumble.
    #
    # Unlike the v2 mapping migration this cannot checksum the file -- Flycast
    # rewrites emu.cfg on exit, so it never matches a shipped hash. It therefore
    # rewrites the slot only when it still holds the old default (a VMU), and
    # cannot distinguish that from a user who deliberately chose a second VMU.
    # Anyone who wants two back can set it in Flycast's own Controls settings.
    if [ "$INSTALLED_VERSION" -lt 3 ] && [ -f "$CONFIG_DIR/emu.cfg" ]; then
        if grep -q '^device1.2 = 1$' "$CONFIG_DIR/emu.cfg"; then
            # Write-and-rename rather than sed -i: the in-place flag is not
            # portable (BSD sed needs a suffix argument), and this wrapper is
            # exercised on the host by the launch smoke test.
            emu_cfg_new="$CONFIG_DIR/emu.cfg.umrk-new"
            if sed 's/^device1.2 = 1$/device1.2 = 3/' \
                    "$CONFIG_DIR/emu.cfg" >"$emu_cfg_new"; then
                mv "$emu_cfg_new" "$CONFIG_DIR/emu.cfg"
            else
                rm -f "$emu_cfg_new"
            fi
        fi
    fi
    printf '%s\n' "$DEFAULTS_VERSION" >"$INSTALLED_VERSION_FILE"
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
export FLYCAST_UI_ROTATE_90=1

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

# Jawaka freezes a controller roster for each launch and exports it in
# SDL_JOYSTICK_DEVICE as colon-separated event paths in player order --
# wireless pads first, the calibrated virtual Loong last -- backed by a private
# /dev/input holding exactly those devices. Roster slot N is SDL joystick N, so
# bind them straight through to Dreamcast ports 0-3. The calibrated pad is only
# index 0 when no wireless controller is connected, so it must not be assumed.
# Everything at or beyond the roster count is detached, leaving unused Maple
# ports empty rather than letting a stray device acquire one.
roster_count=""
if [ -n "${SDL_JOYSTICK_DEVICE:-}" ]; then
    roster_count="$(printf '%s' "$SDL_JOYSTICK_DEVICE" | awk -F: '{ print NF }')"
elif [ -n "${JAWAKA_INPUT_ROSTER_COUNT:-}" ]; then
    roster_count="$JAWAKA_INPUT_ROSTER_COUNT"
fi

if [ -n "$roster_count" ]; then
    case "$roster_count" in
        ''|*[!0-9]*)
            echo "invalid Jawaka input roster count: $roster_count" >&2
            exit 1
            ;;
    esac
    if [ "$roster_count" -lt 1 ]; then
        echo "empty Jawaka input roster" >&2
        exit 1
    fi
    if [ "$roster_count" -gt 4 ]; then
        roster_count=4
    fi
    joystick_index=0
    while [ "$joystick_index" -lt 16 ]; do
        if [ "$joystick_index" -lt "$roster_count" ]; then
            append_override "input:maple_sdl_joystick_${joystick_index}=${joystick_index}"
        else
            append_override "input:maple_sdl_joystick_${joystick_index}=-1"
        fi
        joystick_index=$((joystick_index + 1))
    done
elif [ -n "${JAWAKA_RETROARCH_JOYPAD_INDEX:-}" ]; then
    case "$JAWAKA_RETROARCH_JOYPAD_INDEX" in
        *[!0-9]*)
            echo "invalid Jawaka virtual joypad index: $JAWAKA_RETROARCH_JOYPAD_INDEX" >&2
            exit 1
            ;;
    esac
    if [ "$JAWAKA_RETROARCH_JOYPAD_INDEX" -gt 15 ]; then
        echo "Jawaka virtual joypad index is out of range: $JAWAKA_RETROARCH_JOYPAD_INDEX" >&2
        exit 1
    fi
    joystick_index=0
    while [ "$joystick_index" -lt "$JAWAKA_RETROARCH_JOYPAD_INDEX" ]; do
        append_override "input:maple_sdl_joystick_${joystick_index}=-1"
        joystick_index=$((joystick_index + 1))
    done
    append_override "input:maple_sdl_joystick_${JAWAKA_RETROARCH_JOYPAD_INDEX}=0"
fi

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
