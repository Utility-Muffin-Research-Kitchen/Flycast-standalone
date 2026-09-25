#!/usr/bin/env python3
"""Exercise the patched notifier's real state transitions without an ImGui renderer."""
import os
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parent.parent
source = pathlib.Path(os.environ.get("FLYCAST_SOURCE_DIR", root / "workdir/mlp1/flycast"))
header = (source / "core/ui/gui_achievements.h").read_text()
header = header.replace('#include "types.h"', '').replace('#include "gui_util.h"', '')
header = header.replace('private:', 'public:')
impl = (source / "core/ui/gui_achievements.cpp").read_text()
notify = impl[impl.index('void Notification::notify('):impl.index('void Notification::showChallenge(')]
# The draw prologue owns timing/expiry; omit only the ImGui drawing commands.
draw = impl[impl.index('bool Notification::draw()'):impl.index('\tfloat alpha = 1.f;')]
draw += '\treturn true;\n}\n'
constants = impl[impl.index('static constexpr u64 DISPLAY_TIME'):impl.index('void Notification::notify(')]
program = r'''
#include <cassert>
#include <cstdint>
#include <string>
using u64 = uint64_t;
using u32 = uint32_t;
static u64 clockMs;
u64 getTimeMs() { return clockMs; }
#define verify assert
struct ImguiFileTexture { std::string path; };
''' + header + '\nnamespace achievements {\n' + constants + notify + draw + r'''
}
int main() {
    (void)achievements::START_ANIM_TIME;
    using N = achievements::Notification;
    N notice;
    notice.notify(N::Error, "", "Hardcore uses RetroAchievements directly");
    // The loader clears progress and finishes login before the first game frame.
    clockMs = 20;
    notice.notify(N::Progress, "", "");
    assert(notice.type == N::Error);
    clockMs = 10000;
    notice.notify(N::Login, "", "Authenticated");
    notice.notify(N::GameLoaded, "", "Achievements active");
    assert(notice.type == N::Error);
    assert(notice.draw());
    assert(notice.startTime == 10000 && notice.endTime == 15000);
    clockMs = 14000;
    notice.notify(N::Login, "", "Late image callback");
    assert(notice.type == N::Error && notice.draw());
    assert(notice.endTime == 15000); // drawing must not keep extending the notice
    clockMs = 15001;
    notice.notify(N::Login, "", "Next login");
    assert(notice.type == N::Login);
    notice.notify(N::Error, "", "Connection failed");
    notice.notify(N::Error, "", "Current error");
    assert(notice.text[0] == "Current error");
    // Earned unlocks still replace a notice; only routine startup messages wait.
    notice.notify(N::Unlocked, "", "Earned achievement");
    assert(notice.type == N::Unlocked);
}
'''
with tempfile.TemporaryDirectory(prefix="flycast-notice-") as work:
    cpp = pathlib.Path(work) / "notice.cpp"
    binary = pathlib.Path(work) / "notice-test"
    cpp.write_text(program)
    subprocess.run([os.environ.get("CXX", "c++"), "-std=c++17", "-Wall", "-Wextra",
                    "-Werror", str(cpp), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
print("achievement notices: startup progress/login cannot hide an unread error")
