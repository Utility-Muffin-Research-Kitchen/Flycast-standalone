#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PACKAGE_DIR="$TMP_ROOT/package with spaces"
SDCARD_PATH_TEST="$TMP_ROOT/sd card's root"
USERDATA_PATH_TEST="$SDCARD_PATH_TEST/.userdata/mlp1"
BIOS_PATH_TEST="$SDCARD_PATH_TEST/BIOS"
SAVES_PATH_TEST="$SDCARD_PATH_TEST/Saves"
STATES_PATH_TEST="$SDCARD_PATH_TEST/States"
CHEATS_PATH_TEST="$SDCARD_PATH_TEST/Cheats"
LOGS_PATH_TEST="$USERDATA_PATH_TEST/logs"
RUNTIME_PATH_TEST="$TMP_ROOT/runtime root"
ROM_DIR="$SDCARD_PATH_TEST/Roms/DC"
ROM_NAME="Crazy Taxi's \${cash}; [USA], v1.chd"
ROM_PATH="$ROM_DIR/$ROM_NAME"

mkdir -p "$PACKAGE_DIR/bin" "$PACKAGE_DIR/defaults" "$ROM_DIR" \
    "$SAVES_PATH_TEST/Flycast" "$STATES_PATH_TEST/Flycast"
cp "$ROOT_DIR/config/mlp1/launch.sh" "$PACKAGE_DIR/launch.sh"
cp "$ROOT_DIR/config/mlp1/emu.cfg" "$PACKAGE_DIR/defaults/emu.cfg"
cp "$ROOT_DIR/config/mlp1/config.version" "$PACKAGE_DIR/defaults/config.version"
cp "$ROOT_DIR/config/mlp1/SDL_Loong Gamepad.cfg" \
    "$PACKAGE_DIR/defaults/SDL_Loong Gamepad.cfg"
touch "$ROM_PATH"

cat >"$PACKAGE_DIR/bin/flycast" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
for name in HOME XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME \
    XDG_RUNTIME_DIR TMPDIR SDL_VIDEODRIVER SDL_AUDIODRIVER PULSE_SERVER \
    FLYCAST_UI_ROTATE_90; do
    printf '%s=<%s>\n' "$name" "${!name-}"
done
index=0
for argument in "$@"; do
    printf 'arg_%d=<%s>\n' "$index" "$argument"
    index=$((index + 1))
done
EOF
chmod 0755 "$PACKAGE_DIR/bin/flycast" "$PACKAGE_DIR/launch.sh"

run_wrapper() {
    env -u UMRK_ENV_FILE \
        PLATFORM=mlp1 \
        SDCARD_PATH="$SDCARD_PATH_TEST" \
        USERDATA_PATH="$USERDATA_PATH_TEST" \
        BIOS_PATH="$BIOS_PATH_TEST" \
        SAVES_PATH="$SAVES_PATH_TEST" \
        STATES_PATH="$STATES_PATH_TEST" \
        CHEATS_PATH="$CHEATS_PATH_TEST" \
        LOGS_PATH="$LOGS_PATH_TEST" \
        UMRK_RUNTIME_PATH="$RUNTIME_PATH_TEST" \
        JAWAKA_RETROARCH_JOYPAD_INDEX=1 \
        FLYCAST_CONFIG_OVERRIDES='config:pvr.AutoSkipFrame=2' \
        "$PACKAGE_DIR/launch.sh" "$ROM_PATH"
}

run_wrapper

CONFIG_DIR="$USERDATA_PATH_TEST/flycast/config/flycast"
LOG_FILE="$LOGS_PATH_TEST/flycast/flycast.log"
for seeded_path in \
    "$CONFIG_DIR/emu.cfg" \
    "$CONFIG_DIR/.umrk-defaults-version" \
    "$CONFIG_DIR/mappings/SDL_Loong Gamepad.cfg" \
    "$LOG_FILE"; do
    if [ ! -f "$seeded_path" ]; then
        echo "launch wrapper did not create expected path: $seeded_path" >&2
        exit 1
    fi
done

grep -F "XDG_CONFIG_HOME=<$USERDATA_PATH_TEST/flycast/config>" "$LOG_FILE" >/dev/null
grep -F "XDG_DATA_HOME=<$SAVES_PATH_TEST/Flycast/xdg>" "$LOG_FILE" >/dev/null
grep -F "XDG_RUNTIME_DIR=<$RUNTIME_PATH_TEST/flycast>" "$LOG_FILE" >/dev/null
grep -F 'SDL_VIDEODRIVER=<kmsdrm>' "$LOG_FILE" >/dev/null
grep -F 'SDL_AUDIODRIVER=<pulseaudio>' "$LOG_FILE" >/dev/null
grep -F 'FLYCAST_UI_ROTATE_90=<1>' "$LOG_FILE" >/dev/null
grep -F 'arg_0=<-config>' "$LOG_FILE" >/dev/null
grep -F "config:Dreamcast.BiosPath=$BIOS_PATH_TEST" "$LOG_FILE" >/dev/null
grep -F "config:Dreamcast.VMUPath=$SAVES_PATH_TEST/Flycast" "$LOG_FILE" >/dev/null
grep -F "config:Dreamcast.SavestatePath=$STATES_PATH_TEST/Flycast" "$LOG_FILE" >/dev/null
grep -F 'input:maple_sdl_joystick_0=-1' "$LOG_FILE" >/dev/null
grep -F 'input:maple_sdl_joystick_1=0' "$LOG_FILE" >/dev/null
grep -F 'config:pvr.rend=0' "$LOG_FILE" >/dev/null
grep -F 'config:pvr.AutoSkipFrame=2' "$LOG_FILE" >/dev/null
grep -F "arg_2=<$ROM_PATH>" "$LOG_FILE" >/dev/null

# Recreate the shipped version-1 state and prove the migrations run: version 2
# moves the Menu button from Exit to Flycast's native menu, version 3 attaches
# the Jump Pack to controller 1's second expansion slot so games can rumble.
sed 's/10:btn_menu/10:btn_escape/' \
    "$PACKAGE_DIR/defaults/SDL_Loong Gamepad.cfg" \
    >"$CONFIG_DIR/mappings/SDL_Loong Gamepad.cfg"
sed -i.bak 's/^device1.2 = 3$/device1.2 = 1/' "$CONFIG_DIR/emu.cfg"
rm -f "$CONFIG_DIR/emu.cfg.bak"
printf '1\n' >"$CONFIG_DIR/.umrk-defaults-version"
run_wrapper
grep -F 'bind7 = 10:btn_menu' \
    "$CONFIG_DIR/mappings/SDL_Loong Gamepad.cfg" >/dev/null
grep -Fx 'device1.2 = 3' "$CONFIG_DIR/emu.cfg" >/dev/null
grep -Fx '3' "$CONFIG_DIR/.umrk-defaults-version" >/dev/null

printf '\n[user]\ncustom = preserved\n' >>"$CONFIG_DIR/emu.cfg"
printf '\n# user mapping edit\n' >>"$CONFIG_DIR/mappings/SDL_Loong Gamepad.cfg"
config_sha_before="$(shasum -a 256 "$CONFIG_DIR/emu.cfg" | awk '{print $1}')"
mapping_sha_before="$(
    shasum -a 256 "$CONFIG_DIR/mappings/SDL_Loong Gamepad.cfg" |
        awk '{print $1}'
)"

run_wrapper

config_sha_after="$(shasum -a 256 "$CONFIG_DIR/emu.cfg" | awk '{print $1}')"
mapping_sha_after="$(
    shasum -a 256 "$CONFIG_DIR/mappings/SDL_Loong Gamepad.cfg" |
        awk '{print $1}'
)"
if [ "$config_sha_before" != "$config_sha_after" ] ||
   [ "$mapping_sha_before" != "$mapping_sha_after" ]; then
    echo "launch wrapper overwrote durable user configuration" >&2
    exit 1
fi

if "$PACKAGE_DIR/launch.sh" "$TMP_ROOT/missing.chd" >/dev/null 2>&1; then
    echo "launch wrapper accepted a missing ROM" >&2
    exit 1
fi

# A Jawaka launch publishes the frozen controller roster in player order, so
# roster slot N must reach Dreamcast port N whatever the calibrated pad's index
# is, and every slot past the roster must stay detached.
run_wrapper_roster() {
    env -u UMRK_ENV_FILE \
        PLATFORM=mlp1 \
        SDCARD_PATH="$SDCARD_PATH_TEST" \
        USERDATA_PATH="$USERDATA_PATH_TEST" \
        BIOS_PATH="$BIOS_PATH_TEST" \
        SAVES_PATH="$SAVES_PATH_TEST" \
        STATES_PATH="$STATES_PATH_TEST" \
        CHEATS_PATH="$CHEATS_PATH_TEST" \
        LOGS_PATH="$LOGS_PATH_TEST" \
        UMRK_RUNTIME_PATH="$RUNTIME_PATH_TEST" \
        JAWAKA_RETROARCH_JOYPAD_INDEX=1 \
        SDL_JOYSTICK_DEVICE="$1" \
        "$PACKAGE_DIR/launch.sh" "$ROM_PATH"
}

# Two controllers: wireless P1 then the calibrated virtual pad as P2.
run_wrapper_roster '/dev/input/event6:/dev/input/event5'
for expected in \
    'input:maple_sdl_joystick_0=0' \
    'input:maple_sdl_joystick_1=1' \
    'input:maple_sdl_joystick_2=-1' \
    'input:maple_sdl_joystick_3=-1'; do
    if ! grep -F "$expected" "$LOG_FILE" >/dev/null; then
        echo "two-controller roster did not produce $expected" >&2
        exit 1
    fi
done
if grep -F 'input:maple_sdl_joystick_1=0' "$LOG_FILE" >/dev/null; then
    echo "roster launch still pinned the calibrated pad to port 0" >&2
    exit 1
fi

# No wireless controller: the calibrated virtual pad is the only roster member
# and owns port 0, with every other port left empty.
run_wrapper_roster '/dev/input/event5'
for expected in \
    'input:maple_sdl_joystick_0=0' \
    'input:maple_sdl_joystick_1=-1'; do
    if ! grep -F "$expected" "$LOG_FILE" >/dev/null; then
        echo "single-controller roster did not produce $expected" >&2
        exit 1
    fi
done

# A fourth external is dropped from the roster, so only four ports are bound.
run_wrapper_roster '/dev/input/event6:/dev/input/event7:/dev/input/event8:/dev/input/event5'
for expected in \
    'input:maple_sdl_joystick_3=3' \
    'input:maple_sdl_joystick_4=-1'; do
    if ! grep -F "$expected" "$LOG_FILE" >/dev/null; then
        echo "four-controller roster did not produce $expected" >&2
        exit 1
    fi
done

printf 'Verified launch wrapper paths, quoting, seed policy, and user-config preservation\n'
