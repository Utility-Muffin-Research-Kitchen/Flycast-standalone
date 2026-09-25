#!/usr/bin/env python3
"""Achievements teardown must not wait on the network or deadlock.

Compiles the patched WorkerThread and the real curl client section of
http_client.cpp on the host, then checks:

- a task that queues a follow-up while stop() is joining it (an rcheevos
  callback calling asyncTask during unloadGame) lets stop() return, and the
  follow-up never runs; other threads' run() still waits and then runs;
- a request inside a CancelScope stops soon after the flag is set, even when
  the server accepted the connection and never answers;
- the same stalled request without the flag fails after StallSeconds;
- a request outside any scope keeps upstream behavior (still waiting).

Every wait is bounded by a watchdog, so the original deadlock reports FAIL
instead of hanging the job.
"""
import os
import pathlib
import subprocess
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parent.parent
source = pathlib.Path(os.environ.get("FLYCAST_SOURCE_DIR", root / "workdir/mlp1/flycast"))
cxx = os.environ.get("CXX", "c++")

impl = (source / "core/oslib/http_client.cpp").read_text()
# The curl client: the branch after the Windows implementation.
curl_start = impl.index("#else\n#include <curl/curl.h>")
curl_end = impl.index("#endif\t// !_WIN32")
curl_section = impl[curl_start + len("#else\n"):curl_end]

achievements = (source / "core/achievements/achievements.cpp").read_text()
stop_threads = achievements[achievements.index("void Achievements::stopThreads()"):]
stop_threads = stop_threads[:stop_threads.index("\n}\n")]
async_task = achievements[achievements.index("void Achievements::asyncTask("):]
async_task = async_task[:async_task.index("\n}\n")]
for needle, text, where in (
        ("http::CancelScope scope(&cancelRequests);", async_task, "asyncTask()"),
        ("cancelRequests = true;", stop_threads, "stopThreads()"),
        ("cancelRequests = false;", stop_threads, "stopThreads()")):
    if needle not in text:
        sys.exit(f"FAIL teardown wiring: {where} lacks: {needle}")
order = [stop_threads.index(s) for s in (
    "cancelRequests = true;", "idleThread.stop();", "taskThread.stop();", "cancelRequests = false;")]
if order != sorted(order):
    sys.exit("FAIL teardown wiring: stopThreads() must cancel, stop idle, drain tasks, then reset")
print("teardown wiring: RA tasks run in a cancel scope; stopThreads() cancels before draining")

program = r'''
// The real curl section relies on includes upstream gets from its own headers.
#include <cctype>
#include <cstring>
#include "oslib/http_client.h"
#include "util/worker_thread.h"
#include <arpa/inet.h>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <netinet/in.h>
#include <sys/socket.h>
#include <thread>
#include <unistd.h>

static std::string trim_ws(const std::string& s, const std::string& ws = " \t\r\n") {
    size_t b = s.find_first_not_of(ws);
    if (b == std::string::npos)
        return "";
    return s.substr(b, s.find_last_not_of(ws) - b + 1);
}
static void string_tolower(std::string& s) {
    for (char& c : s)
        c = (char)std::tolower((unsigned char)c);
}
''' + curl_section + r'''
using Clock = std::chrono::steady_clock;
static double since(Clock::time_point t0) {
    return std::chrono::duration<double>(Clock::now() - t0).count();
}
static void fail(const char *what) {
    std::printf("FAIL %s\n", what);
    std::fflush(stdout);
    std::_Exit(1);
}
// A deadlock cannot be joined; report it and exit instead.
static void watchdog(std::atomic_bool& done, double seconds, const char *what) {
    std::thread([&done, seconds, what]() {
        auto t0 = Clock::now();
        while (!done && since(t0) < seconds)
            std::this_thread::sleep_for(std::chrono::milliseconds(20));
        if (!done)
            fail(what);
    }).detach();
}

// Accepts connections and reads requests, never answers.
static int stalledServer() {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    sockaddr_in addr {};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(fd, (sockaddr *)&addr, sizeof(addr)) != 0 || listen(fd, 8) != 0)
        fail("stalled server");
    socklen_t len = sizeof(addr);
    getsockname(fd, (sockaddr *)&addr, &len);
    std::thread([fd]() {
        for (;;) {
            int c = accept(fd, nullptr, nullptr);
            if (c < 0)
                return;
            std::thread([c]() {
                char buf[4096];
                while (read(c, buf, sizeof(buf)) > 0)
                    ;
                close(c);
            }).detach();
        }
    }).detach();
    return ntohs(addr.sin_port);
}

static void workerStopWithFollowUp() {
    WorkerThread worker("teardown-test");
    std::atomic_bool started {false}, followUpRan {false}, stopReturned {false};
    worker.run([&]() {
        started = true;
        // Let stop() start joining, then queue a follow-up like a callback.
        std::this_thread::sleep_for(std::chrono::milliseconds(300));
        worker.run([&]() { followUpRan = true; });
    });
    while (!started)
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    watchdog(stopReturned, 5, "WorkerThread::stop() deadlocked on a task queued while joining");
    worker.stop();
    stopReturned = true;
    if (followUpRan)
        fail("a follow-up queued while stopping ran");
    std::atomic_bool again {false};
    worker.run([&]() { again = true; });
    worker.stop();
    if (!again)
        fail("run() after stop() did not start a new thread");
    std::printf("worker: stop() returns while a task queues its follow-up; follow-up discarded\n");
}

static void workerOtherThreadWaits() {
    WorkerThread worker("teardown-test");
    std::atomic_bool started {false}, release {false}, otherRan {false}, done {false};
    worker.run([&]() {
        started = true;
        while (!release)
            std::this_thread::sleep_for(std::chrono::milliseconds(5));
    });
    while (!started)
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    watchdog(done, 5, "stop() / run() from another thread did not complete");
    std::thread stopper([&]() { worker.stop(); });
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
    std::thread other([&]() { worker.run([&]() { otherRan = true; }); });
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
    release = true;
    stopper.join();
    other.join();
    worker.stop();
    done = true;
    if (!otherRan)
        fail("another thread's run() during stop() was lost");
    std::printf("worker: another thread's run() waits for the stop, then runs\n");
}

static void cancelStalledRequest(int port) {
    std::string url = "http://127.0.0.1:" + std::to_string(port) + "/dorequest.php";
    std::atomic_bool cancel {false}, done {false};
    int rc = 0;
    double elapsed = 0;
    watchdog(done, 10, "a cancelled request kept waiting on a stalled server");
    std::thread requester([&]() {
        http::CancelScope scope(&cancel);
        std::vector<u8> reply;
        auto t0 = Clock::now();
        rc = http::post(url, "r=login2", "application/x-www-form-urlencoded", reply);
        elapsed = since(t0);
    });
    std::this_thread::sleep_for(std::chrono::milliseconds(500));
    cancel = true;
    requester.join();
    done = true;
    if (http::success(rc) || elapsed > 3.0)
        fail("cancelled request did not stop promptly");
    std::printf("http: cancelled stalled request returned %d after %.1f s\n", rc, elapsed);
}

static void stallBound(int port) {
    std::string url = "http://127.0.0.1:" + std::to_string(port) + "/dorequest.php";
    std::atomic_bool cancel {false}, done {false};
    watchdog(done, http::CancelScope::StallSeconds + 15, "a stalled request inside a scope was not bounded");
    http::CancelScope scope(&cancel);
    std::vector<u8> reply;
    auto t0 = Clock::now();
    int rc = http::post(url, "r=login2", "application/x-www-form-urlencoded", reply);
    double elapsed = since(t0);
    done = true;
    if (http::success(rc) || elapsed < http::CancelScope::StallSeconds - 1)
        fail("stalled request ended for another reason");
    std::printf("http: stalled request failed after %.1f s (bound %ld s)\n", elapsed, http::CancelScope::StallSeconds);
}

static void unscopedUnchanged(int port) {
    std::string url = "http://127.0.0.1:" + std::to_string(port) + "/dorequest.php";
    std::atomic_bool finished {false};
    std::thread([&finished, url]() {
        std::vector<u8> reply;
        http::post(url, "r=login2", "application/x-www-form-urlencoded", reply);
        finished = true;
    }).detach();
    std::this_thread::sleep_for(std::chrono::seconds(2));
    if (finished)
        fail("a request outside any scope changed behavior");
    std::printf("http: requests outside a scope keep upstream behavior\n");
}

int main() {
    http::init();
    workerStopWithFollowUp();
    workerOtherThreadWaits();
    int port = stalledServer();
    cancelStalledRequest(port);
    unscopedUnchanged(port);
    if (!std::getenv("RA_TEARDOWN_SKIP_STALL"))
        stallBound(port);
    std::printf("ra-teardown-test: passed\n");
    std::fflush(stdout);
    std::_Exit(0);   // the unscoped request thread is still (correctly) waiting
}
'''

with tempfile.TemporaryDirectory() as tmp:
    tmp = pathlib.Path(tmp)
    stubs = tmp / "stubs"
    stubs.mkdir()
    (stubs / "types.h").write_text("#pragma once\n#include <cstdint>\ntypedef uint8_t u8;\n")
    (stubs / "version.h").write_text('#pragma once\n#define GIT_VERSION "v2.7"\n')
    (stubs / "oslib").mkdir()
    (stubs / "oslib/oslib.h").write_text(
        "#pragma once\nstruct ThreadName { ThreadName(const char *) {} };\n")
    (stubs / "oslib/http_client.h").write_text((source / "core/oslib/http_client.h").read_text())
    (stubs / "util").mkdir()
    for name in ("worker_thread.h", "tsqueue.h"):
        (stubs / "util" / name).write_text((source / "core/util" / name).read_text())
    src = tmp / "teardown.cpp"
    src.write_text(program)
    exe = tmp / "teardown"
    subprocess.run([cxx, "-std=c++17", "-Wall", "-Wextra", "-Wno-unused-parameter", "-O1", "-pthread",
                    "-I", str(stubs), "-I", str(stubs / "util"), "-o", str(exe), str(src), "-lcurl"],
                   check=True)
    subprocess.run([str(exe)], check=True, timeout=120)
