#!/usr/bin/env bash
# Host tests for patch 0003's session route: the unit test, then real bounded
# health checks against a local fake Leaf health service. The fake listens on
# an ephemeral port; the device path always uses 127.0.0.1:8080.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="${FLYCAST_SOURCE_DIR:-$ROOT_DIR/workdir/mlp1/flycast}"
BUILD_DIR="$ROOT_DIR/output/host-tests"
CXX="${CXX:-c++}"

if [ ! -f "$SOURCE_DIR/core/achievements/ra_route.cpp" ]; then
    echo "missing patched upstream source: $SOURCE_DIR/core/achievements/ra_route.cpp" >&2
    echo "run make fetch-upstream first" >&2
    exit 1
fi
mkdir -p "$BUILD_DIR"
"$CXX" -std=c++17 -Wall -Wextra -Werror -O1 \
    -I "$SOURCE_DIR/core" \
    -o "$BUILD_DIR/ra_route_test" \
    "$ROOT_DIR/tests/ra_route_test.cpp" \
    "$SOURCE_DIR/core/achievements/ra_route.cpp"
"$BUILD_DIR/ra_route_test"

# The unit test above proves decide() answers NoAuth when the settings are not
# known. That rule only means something if the emulator feeds it: the input
# must come from the configuration store's own verdict on emu.cfg
# (config::isEstablished(), exercised against real unreadable files by
# ra-account-fault-test), and an unknown configuration must stop the client
# before any login. Check the patched source says exactly that.
ACHIEVEMENTS_SOURCE="$SOURCE_DIR/core/achievements/achievements.cpp"
for wiring in \
    'in.settingsKnown = config::isEstablished();' \
    'if (routeHandoff() && !config::isEstablished())'; do
    if ! grep -F "$wiring" "$ACHIEVEMENTS_SOURCE" >/dev/null; then
        echo "FAIL route wiring: achievements.cpp lacks: $wiring" >&2
        exit 1
    fi
done
if [ "$(grep -c 'settingsKnown' "$ACHIEVEMENTS_SOURCE")" -ne 2 ]; then
    echo "FAIL route wiring: settingsKnown must be set once and reported once" >&2
    exit 1
fi
echo "route wiring: settingsKnown comes from the configuration store"

# The session's status ("Achievements unavailable. Unlocks will not be
# queued.", "... Unlocks are not being queued.") belongs in the achievements
# list view too, not only under Settings > General. An unavailable session has
# no running client, so the pause menu must still open the list when there is
# a status to show, and the list must not ask a missing client for entries.
# (ImGui does not run on the host; the MLP1 build compiles this code.)
LIST_SOURCE="$SOURCE_DIR/core/ui/gui_achievements.cpp"
MENU_SOURCE="$SOURCE_DIR/core/ui/gui.cpp"
list_view="$(awk '/^void achievementList\(\)/,/^}/' "$LIST_SOURCE")"
for wiring in \
    'const std::string routeStatus = routeStatusLine();' \
    'ImGui::TextWrapped("%s", routeStatus.c_str());' \
    'if (!isActive()) {'; do
    if ! printf '%s\n' "$list_view" | grep -F "$wiring" >/dev/null; then
        echo "FAIL achievements list: achievementList() lacks: $wiring" >&2
        exit 1
    fi
done
if ! grep -F -A1 'const bool achievementsView = achievements::isActive()' "$MENU_SOURCE" |
        grep -F '|| !achievements::routeStatusLine().empty();' >/dev/null ||
   ! grep -F 'DisabledScope _{!achievementsView};' "$MENU_SOURCE" >/dev/null; then
    echo "FAIL achievements list: the pause menu does not open the list for a route status" >&2
    exit 1
fi
echo "route status: shown in the achievements list view"

# Run the real notifier transitions without an ImGui renderer. Startup
# progress/login messages must not erase the mandatory Hardcore-host notice.
python3 "$ROOT_DIR/tests/achievement-notice-test.py"
python3 "$ROOT_DIR/tests/ra-session-login-test.py"

# Request URLs from the pinned rcheevos for the session host. gnu99, not c99:
# rcheevos uses POSIX strdup/strncasecmp, which strict C99 hides on glibc.
# No -Werror here: most of what this compiles is third-party rcheevos.
RC_DIR="$SOURCE_DIR/core/deps/rcheevos"
"${CC:-cc}" -std=gnu99 \
    -I "$RC_DIR/include" -I "$RC_DIR/src" \
    -o "$BUILD_DIR/ra_route_urls_test" \
    "$ROOT_DIR/tests/ra_route_urls_test.c" \
    "$RC_DIR/src/rapi/rc_api_common.c" "$RC_DIR/src/rapi/rc_api_user.c" \
    "$RC_DIR/src/rc_compat.c" "$RC_DIR/src/rc_util.c" "$RC_DIR/src/rhash/md5.c"
"$BUILD_DIR/ra_route_urls_test"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ra-route-health.XXXXXX")"
SERVER_PID=""
cleanup() {
    [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

cat >"$TMP_DIR/fake.py" <<'PY'
import socket, sys, threading, time

READY = b'{"service":"org.umrk.raofflineproxy","protocol":"leaf-health-1","ready":true}'

def answer(path):
    if path == "/ready":
        return b"HTTP/1.0 200 OK\r\nContent-Type: application/json\r\n\r\n" + READY
    if path == "/not-ready":
        return b'HTTP/1.0 200 OK\r\n\r\n{"service":"org.umrk.raofflineproxy","protocol":"leaf-health-1","ready":false}'
    if path == "/redirect":
        return b"HTTP/1.0 302 Found\r\nLocation: http://127.0.0.1:1/leaf/health\r\n\r\n" + READY
    if path == "/huge":
        return b"HTTP/1.0 200 OK\r\n\r\n" + READY + b" " * 65536
    if path == "/wrong-service":
        return b'HTTP/1.0 200 OK\r\n\r\n{"service":"elsewhere","protocol":"leaf-health-1","ready":true}'
    return b"HTTP/1.0 404 Not Found\r\n\r\n"

def serve(conn):
    try:
        data = b""
        while b"\r\n\r\n" not in data:
            chunk = conn.recv(1024)
            if not chunk:
                return
            data += chunk
        path = data.split(b" ", 2)[1].decode()
        if path == "/slow":
            time.sleep(2)
            conn.sendall(b"HTTP/1.0 200 OK\r\n\r\n" + READY)
            return
        if path == "/silent":
            time.sleep(2)
            return
        conn.sendall(answer(path))
    except OSError:
        pass
    finally:
        conn.close()

listener = socket.socket()
listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
listener.bind(("127.0.0.1", 0))
listener.listen(16)
with open(sys.argv[1], "w") as f:
    f.write(str(listener.getsockname()[1]))
while True:
    conn, _ = listener.accept()
    threading.Thread(target=serve, args=(conn,), daemon=True).start()
PY
python3 "$TMP_DIR/fake.py" "$TMP_DIR/port" &
SERVER_PID=$!
for _ in $(seq 1 100); do
    [ -s "$TMP_DIR/port" ] && break
    sleep 0.05
done
PORT="$(cat "$TMP_DIR/port")"

# A port nothing listens on: bind and release one.
CLOSED_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"

failures=0
check() { # port, path, expected result
    local out result ms
    out="$("$BUILD_DIR/ra_route_test" health "$1" "$2")"
    result="${out% *}"
    ms="${out#* }"
    if [ "$result" != "$3" ]; then
        echo "FAIL health $2: got $result, want $3" >&2
        failures=$((failures + 1))
    fi
    # One total budget: never meaningfully past 500 ms, whatever the server does.
    if [ "$ms" -gt 650 ]; then
        echo "FAIL health $2: took ${ms} ms, over the 500 ms budget" >&2
        failures=$((failures + 1))
    fi
    echo "health $2 -> $result in ${ms} ms"
}

check "$PORT" /ready ready
check "$PORT" /not-ready not-ready
check "$PORT" /redirect not-ready
check "$PORT" /huge not-ready
check "$PORT" /wrong-service not-ready
check "$PORT" /missing not-ready
check "$PORT" /slow timeout
check "$PORT" /silent timeout
check "$CLOSED_PORT" /ready unreachable

if [ "$failures" -ne 0 ]; then
    echo "ra-route-test: $failures health check failure(s)" >&2
    exit 1
fi
echo "ra-route-test: bounded health checks ok"
