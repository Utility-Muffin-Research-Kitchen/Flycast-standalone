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
    FLYCAST_UI_ROTATE_90 UMRK_RA_ACCOUNT_VERSION UMRK_RA_ACCOUNT_STATE \
    UMRK_RA_ACCOUNT_USERNAME UMRK_RA_ACCOUNT_PASSWORD UMRK_RA_ACCOUNT_REVISION; do
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
    bios_path="${1:-$BIOS_PATH_TEST}"
    env -u UMRK_ENV_FILE \
        PLATFORM=mlp1 \
        SDCARD_PATH="$SDCARD_PATH_TEST" \
        USERDATA_PATH="$USERDATA_PATH_TEST" \
        BIOS_PATH="$bios_path" \
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
grep -F "config:Dreamcast.BiosPath=$BIOS_PATH_TEST/dc" "$LOG_FILE" >/dev/null
if grep -F "$BIOS_PATH_TEST/dc;$BIOS_PATH_TEST" "$LOG_FILE" >/dev/null; then
    echo "launch wrapper retained the legacy BIOS root fallback" >&2
    exit 1
fi
grep -F "config:Dreamcast.VMUPath=$SAVES_PATH_TEST/Flycast" "$LOG_FILE" >/dev/null
grep -F "config:Dreamcast.SavestatePath=$STATES_PATH_TEST/Flycast" "$LOG_FILE" >/dev/null
grep -F 'input:maple_sdl_joystick_0=-1' "$LOG_FILE" >/dev/null
grep -F 'input:maple_sdl_joystick_1=0' "$LOG_FILE" >/dev/null
grep -F 'config:pvr.rend=0' "$LOG_FILE" >/dev/null
grep -F 'config:pvr.AutoSkipFrame=2' "$LOG_FILE" >/dev/null
grep -F "arg_2=<$ROM_PATH>" "$LOG_FILE" >/dev/null
grep -Fx 'Dreamcast.Cable = 0' "$CONFIG_DIR/emu.cfg" >/dev/null

assert_current_mapping() {
    for expected in \
        'bind0 = 1:btn_a' \
        'bind1 = 0:btn_b' \
        'bind2 = 2:btn_x' \
        'bind3 = 3:btn_y' \
        'bind4 = 6:btn_trigger_left' \
        'bind5 = 7:btn_trigger_right' \
        'bind6 = 9:btn_start' \
        'bind8 = 8:btn_d' \
        'bind13 = 4:btn_c' \
        'bind14 = 5:btn_z'; do
        grep -F "$expected" \
            "$CONFIG_DIR/mappings/SDL_Loong Gamepad.cfg" >/dev/null
    done
    grep -Fx '7' "$CONFIG_DIR/.umrk-defaults-version" >/dev/null
    grep -Fx 'PerGameVmu = no' "$CONFIG_DIR/emu.cfg" >/dev/null
}

assert_current_mapping

# Recreate the shipped version-1 state and prove the migrations run: version 2
# moves the Menu button from Exit to Flycast's native menu, version 3 attaches
# the Jump Pack, version 4 maps Select to Coin, and version 5 maps L1 to
# Atomiswave arcade button 3. Version 6 separates the Dreamcast triggers onto
# L2/R2 and covers arcade button 6 on R1.
sed -e 's/10:btn_menu/10:btn_escape/' \
    -e '/^bind8 = 8:btn_d$/d' \
    -e '/^bind13 = 4:btn_c$/d' \
    -e '/^bind14 = 5:btn_z$/d' \
    -e 's/^bind4 = 6:/bind4 = 4:/' \
    -e 's/^bind5 = 7:/bind5 = 5:/' \
    -e 's/^bind9 = 256:/bind8 = 256:/' \
    -e 's/^bind10 = 257:/bind9 = 257:/' \
    -e 's/^bind11 = 258:/bind10 = 258:/' \
    -e 's/^bind12 = 259:/bind11 = 259:/' \
    "$PACKAGE_DIR/defaults/SDL_Loong Gamepad.cfg" \
    >"$CONFIG_DIR/mappings/SDL_Loong Gamepad.cfg"
sed -i.bak 's/^device1.2 = 3$/device1.2 = 1/' "$CONFIG_DIR/emu.cfg"
rm -f "$CONFIG_DIR/emu.cfg.bak"
printf '1\n' >"$CONFIG_DIR/.umrk-defaults-version"
run_wrapper
assert_current_mapping
grep -F 'bind7 = 10:btn_menu' \
    "$CONFIG_DIR/mappings/SDL_Loong Gamepad.cfg" >/dev/null
grep -Fx 'device1.2 = 3' "$CONFIG_DIR/emu.cfg" >/dev/null

# A byte-identical v3 mapping gains Coin without requiring a fresh install.
sed -e '/^bind8 = 8:btn_d$/d' \
    -e '/^bind13 = 4:btn_c$/d' \
    -e '/^bind14 = 5:btn_z$/d' \
    -e 's/^bind4 = 6:/bind4 = 4:/' \
    -e 's/^bind5 = 7:/bind5 = 5:/' \
    -e 's/^bind9 = 256:/bind8 = 256:/' \
    -e 's/^bind10 = 257:/bind9 = 257:/' \
    -e 's/^bind11 = 258:/bind10 = 258:/' \
    -e 's/^bind12 = 259:/bind11 = 259:/' \
    "$PACKAGE_DIR/defaults/SDL_Loong Gamepad.cfg" \
    >"$CONFIG_DIR/mappings/SDL_Loong Gamepad.cfg"
printf '3\n' >"$CONFIG_DIR/.umrk-defaults-version"
run_wrapper
assert_current_mapping

# A byte-identical v4 mapping gains arcade Button 3.
sed -e '/^bind13 = 4:btn_c$/d' \
    -e '/^bind14 = 5:btn_z$/d' \
    -e 's/^bind4 = 6:/bind4 = 4:/' \
    -e 's/^bind5 = 7:/bind5 = 5:/' \
    "$PACKAGE_DIR/defaults/SDL_Loong Gamepad.cfg" \
    >"$CONFIG_DIR/mappings/SDL_Loong Gamepad.cfg"
printf '4\n' >"$CONFIG_DIR/.umrk-defaults-version"
run_wrapper
assert_current_mapping

# A byte-identical v5 mapping gains separate triggers and arcade Button 6.
sed -e '/^bind14 = 5:btn_z$/d' \
    -e 's/^bind4 = 6:/bind4 = 4:/' \
    -e 's/^bind5 = 7:/bind5 = 5:/' \
    "$PACKAGE_DIR/defaults/SDL_Loong Gamepad.cfg" \
    >"$CONFIG_DIR/mappings/SDL_Loong Gamepad.cfg"
printf '5\n' >"$CONFIG_DIR/.umrk-defaults-version"
run_wrapper
assert_current_mapping

# A v6 install upgraded to v2.7 keeps its shared VMUs: the missing
# PerGameVmu line is pinned to the v2.6 default under [config] ...
grep -v '^PerGameVmu = ' "$CONFIG_DIR/emu.cfg" >"$CONFIG_DIR/emu.cfg.tmp"
mv "$CONFIG_DIR/emu.cfg.tmp" "$CONFIG_DIR/emu.cfg"
printf '6\n' >"$CONFIG_DIR/.umrk-defaults-version"
run_wrapper
assert_current_mapping
[ "$(grep -c '^PerGameVmu = ' "$CONFIG_DIR/emu.cfg")" = 1 ]
awk '/^\[/ { section = $0 } /^PerGameVmu = / { print section }' \
    "$CONFIG_DIR/emu.cfg" | grep -Fx '[config]' >/dev/null

# ... while a player who chose per-game VMUs keeps that choice.
sed 's/^PerGameVmu = no$/PerGameVmu = yes/' "$CONFIG_DIR/emu.cfg" \
    >"$CONFIG_DIR/emu.cfg.tmp"
mv "$CONFIG_DIR/emu.cfg.tmp" "$CONFIG_DIR/emu.cfg"
printf '6\n' >"$CONFIG_DIR/.umrk-defaults-version"
run_wrapper
grep -Fx 'PerGameVmu = yes' "$CONFIG_DIR/emu.cfg" >/dev/null
sed 's/^PerGameVmu = yes$/PerGameVmu = no/' "$CONFIG_DIR/emu.cfg" \
    >"$CONFIG_DIR/emu.cfg.tmp"
mv "$CONFIG_DIR/emu.cfg.tmp" "$CONFIG_DIR/emu.cfg"

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

if run_wrapper "$BIOS_PATH_TEST;untrusted" >/dev/null 2>&1; then
    echo "launch wrapper accepted a BIOS path containing a config delimiter" >&2
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

# standalone-ra-account-v1. The snapshot must reach the emulator itself and
# nothing else: the wrapper's own helpers run before the exec and inherit this
# process's environment, so it is scrubbed on entry and restored only for the
# final exec. Prove both halves at once by shadowing the helper the defaults
# migration runs (sha256sum) with one that records what it inherited.
SPY_DIR="$TMP_ROOT/spy"
SPY_LOG="$TMP_ROOT/spy.log"
mkdir -p "$SPY_DIR"
REAL_SHA256SUM="$(command -v sha256sum)"
if [ -z "$REAL_SHA256SUM" ]; then
    echo "sha256sum is required by the launch wrapper smoke test" >&2
    exit 1
fi
cat >"$SPY_DIR/sha256sum" <<EOF
#!/usr/bin/env bash
for name in UMRK_RA_ACCOUNT_VERSION UMRK_RA_ACCOUNT_STATE \\
    UMRK_RA_ACCOUNT_USERNAME UMRK_RA_ACCOUNT_PASSWORD UMRK_RA_ACCOUNT_REVISION; do
    printf 'helper %s=<%s>\\n' "\$name" "\${!name-}" >>"$SPY_LOG"
done
exec "$REAL_SHA256SUM" "\$@"
EOF
chmod 0755 "$SPY_DIR/sha256sum"

RA_USERNAME="o'hara \"junior\""
RA_PASSWORD='p@$$ w0rd; |, >&`~*?[]{}^%\!'

run_wrapper_account() {
    env -u UMRK_ENV_FILE \
        PATH="$SPY_DIR:$PATH" \
        PLATFORM=mlp1 \
        SDCARD_PATH="$SDCARD_PATH_TEST" \
        USERDATA_PATH="$USERDATA_PATH_TEST" \
        BIOS_PATH="$BIOS_PATH_TEST" \
        SAVES_PATH="$SAVES_PATH_TEST" \
        STATES_PATH="$STATES_PATH_TEST" \
        CHEATS_PATH="$CHEATS_PATH_TEST" \
        LOGS_PATH="$LOGS_PATH_TEST" \
        UMRK_RUNTIME_PATH="$RUNTIME_PATH_TEST" \
        UMRK_RA_ACCOUNT_VERSION=1 \
        UMRK_RA_ACCOUNT_STATE=configured \
        UMRK_RA_ACCOUNT_USERNAME="$RA_USERNAME" \
        UMRK_RA_ACCOUNT_PASSWORD="$RA_PASSWORD" \
        UMRK_RA_ACCOUNT_REVISION=42 \
        "$PACKAGE_DIR/launch.sh" "$ROM_PATH"
}

# Force the migration path so the shadowed helper actually runs this launch.
printf '1\n' >"$CONFIG_DIR/.umrk-defaults-version"
run_wrapper_account

if [ ! -s "$SPY_LOG" ]; then
    echo "account smoke did not exercise a wrapper helper" >&2
    exit 1
fi
if grep -v '=<>$' "$SPY_LOG" >/dev/null; then
    echo "launch wrapper leaked the account snapshot to a helper process" >&2
    exit 1
fi

for expected in \
    'UMRK_RA_ACCOUNT_VERSION=<1>' \
    'UMRK_RA_ACCOUNT_STATE=<configured>' \
    "UMRK_RA_ACCOUNT_USERNAME=<$RA_USERNAME>" \
    "UMRK_RA_ACCOUNT_PASSWORD=<$RA_PASSWORD>" \
    'UMRK_RA_ACCOUNT_REVISION=<42>'; do
    if ! grep -F "$expected" "$LOG_FILE" >/dev/null; then
        echo "launch wrapper did not hand the emulator $expected" >&2
        exit 1
    fi
done

# Nothing about the snapshot belongs in argv: it would be world-readable in
# /proc for the life of the process.
if grep -E '^arg_[0-9]+=.*UMRK_RA_ACCOUNT' "$LOG_FILE" >/dev/null; then
    echo "launch wrapper put account data in the emulator argv" >&2
    exit 1
fi
if grep -F "$RA_PASSWORD" "$LOG_FILE" | grep -v 'UMRK_RA_ACCOUNT_PASSWORD=<' >/dev/null; then
    echo "launch wrapper logged the account password" >&2
    exit 1
fi

# An unauthorized launch carries no snapshot, and the wrapper must not invent
# one or leave a stale value behind.
run_wrapper
for name in UMRK_RA_ACCOUNT_VERSION UMRK_RA_ACCOUNT_STATE \
    UMRK_RA_ACCOUNT_USERNAME UMRK_RA_ACCOUNT_PASSWORD UMRK_RA_ACCOUNT_REVISION; do
    if ! grep -F "$name=<>" "$LOG_FILE" >/dev/null; then
        echo "launch wrapper produced $name without a handoff" >&2
        exit 1
    fi
done

# env.sh is durable environment, never a credential source: a value that shows
# up there is dropped rather than handed to the emulator.
ENV_FILE="$TMP_ROOT/env.sh"
cat >"$ENV_FILE" <<'EOF'
export UMRK_RA_ACCOUNT_VERSION=1
export UMRK_RA_ACCOUNT_STATE=configured
export UMRK_RA_ACCOUNT_USERNAME=from-env-sh
export UMRK_RA_ACCOUNT_PASSWORD=from-env-sh
export UMRK_RA_ACCOUNT_REVISION=9
EOF
env -u UMRK_RA_ACCOUNT_VERSION -u UMRK_RA_ACCOUNT_STATE \
    -u UMRK_RA_ACCOUNT_USERNAME -u UMRK_RA_ACCOUNT_PASSWORD \
    -u UMRK_RA_ACCOUNT_REVISION \
    UMRK_ENV_FILE="$ENV_FILE" \
    PLATFORM=mlp1 \
    SDCARD_PATH="$SDCARD_PATH_TEST" \
    USERDATA_PATH="$USERDATA_PATH_TEST" \
    BIOS_PATH="$BIOS_PATH_TEST" \
    SAVES_PATH="$SAVES_PATH_TEST" \
    STATES_PATH="$STATES_PATH_TEST" \
    CHEATS_PATH="$CHEATS_PATH_TEST" \
    LOGS_PATH="$LOGS_PATH_TEST" \
    UMRK_RUNTIME_PATH="$RUNTIME_PATH_TEST" \
    "$PACKAGE_DIR/launch.sh" "$ROM_PATH"
if grep -F 'from-env-sh' "$LOG_FILE" >/dev/null; then
    echo "launch wrapper handed the emulator credentials from env.sh" >&2
    exit 1
fi

printf 'Verified launch wrapper paths, quoting, seed policy, account handoff, and user-config preservation\n'
