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
    XDG_RUNTIME_DIR TMPDIR SDL_VIDEODRIVER SDL_AUDIODRIVER PULSE_SERVER; do
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
grep -F 'arg_0=<-config>' "$LOG_FILE" >/dev/null
grep -F "config:Dreamcast.BiosPath=$BIOS_PATH_TEST" "$LOG_FILE" >/dev/null
grep -F "config:Dreamcast.VMUPath=$SAVES_PATH_TEST/Flycast" "$LOG_FILE" >/dev/null
grep -F "config:Dreamcast.SavestatePath=$STATES_PATH_TEST/Flycast" "$LOG_FILE" >/dev/null
grep -F 'config:pvr.rend=0' "$LOG_FILE" >/dev/null
grep -F 'config:pvr.AutoSkipFrame=2' "$LOG_FILE" >/dev/null
grep -F "arg_2=<$ROM_PATH>" "$LOG_FILE" >/dev/null

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

printf 'Verified launch wrapper paths, quoting, seed policy, and user-config preservation\n'
