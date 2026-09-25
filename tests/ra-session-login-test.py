#!/usr/bin/env python3
"""Run the real login entry/callback methods with a fake rcheevos transport."""
import os
import pathlib
import re
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parent.parent
source = pathlib.Path(os.environ.get("FLYCAST_SOURCE_DIR", root / "workdir/mlp1/flycast"))
text = (source / "core/achievements/achievements.cpp").read_text()
names = ["init", "clientLoginWithTokenCallback", "clientManagedLoginCallback",
         "startProxyLogin", "startSessionLogin", "verifyManagedCredentials",
         "startSessionTokenLogin", "clientBootstrapLoginCallback", "clientSessionLoginCallback"]
methods = []
for name in names:
    match = re.search(r"^(?:bool|void) Achievements::" + name + r"\(.*?^}", text, re.M | re.S)
    if match:
        methods.append(match.group())
program = r'''
#include <cassert>
#include <functional>
#include <string>
#include <strings.h>
#include <utility>
#include <vector>
#include "achievements/ra_route.h"
#include "cfg/option.h"
#define INFO_LOG(...) ((void)0)
#define WARN_LOG(...) ((void)0)
constexpr int RC_OK = 0;
namespace i18n { std::string Ts(const char *s) { return s; } }
namespace config {
Option<bool> EnableAchievements(true);
Option<std::string> AchievementsUserName("managed-user"), AchievementsToken("old-token"), AchievementsHostUrl("");
bool isEstablished() { return true; }
}
namespace achievements {
enum class SessionLogin { Idle, InProgress, Ready, Failed };
namespace ra_account {
bool managed = true, pending = true, retry = false, saveOk = true;
bool isManaged() { return managed; }
bool isTokenLoginAllowed() { return !pending; }
std::string managedAccount() { return "managed-user"; }
bool take(bool &flag, std::string &user, std::string &password) {
    if (!flag) return false;
    flag = false; user = "managed-user"; password = "synthetic-password"; return true;
}
bool takePendingLogin(std::string &u, std::string &p) { return take(pending, u, p); }
bool takeTokenRetry(std::string &u, std::string &p) { return take(retry, u, p); }
void reportLoginFailure(const std::string &, const std::string &) {}
bool commitLogin(const std::string &token) {
    if (saveOk) config::AchievementsToken = token;
    return saveOk;
}
}
struct rc_client_user_t { const char *username = "managed-user"; const char *token = "verified-token"; };
struct rc_client_t { void *data; std::string host; rc_client_user_t user; };
using Callback = void(*)(int, const char *, rc_client_t *, void *);
struct Request { bool password; std::string host; Callback callback; };
std::vector<Request> requests;
bool inCallback = false;
void rc_client_set_host(rc_client_t *client, const char *host) {
    assert(!inCallback); // never race rcheevos' global host from its callback
    client->host = host ? host : "";
}
void rc_client_set_event_handler(rc_client_t *, void(*)()) {}
void rc_client_set_hardcore_enabled(rc_client_t *, int) {}
void rc_client_logout(rc_client_t *) {}
void *rc_client_get_userdata(rc_client_t *c) { return c->data; }
const rc_client_user_t *rc_client_get_user_info(rc_client_t *c) { return &c->user; }
const char *rc_error_str(int) { return "synthetic rejection"; }
void rc_client_begin_login_with_password(rc_client_t *c, const char *, const char *, Callback cb, void *) {
    requests.push_back({true, c->host, cb});
}
void rc_client_begin_login_with_token(rc_client_t *c, const char *, const char *, Callback cb, void *) {
    requests.push_back({false, c->host, cb});
}
struct Notification { enum { Login }; void notify(int, const char *, const std::string &, const char *) {} } notifier;
class Achievements {
public:
    rc_client_t client{this, "", {}};
    rc_client_t *rc_client = nullptr;
    bool proxySession = false, routeResolved = true, hostOverrideActive = false;
    ra_route::Intent routeIntent = ra_route::Intent::ServiceLive;
    ra_route::Route route = ra_route::Route::Direct;
    SessionLogin sessionLogin = SessionLogin::Idle;
    int successes = 0, failures = 0;
    std::string status;
    std::vector<std::function<void()>> tasks;
    bool routeHandoff() { return routeIntent != ra_route::Intent::Absent; }
    bool createClient() {
        rc_client = &client;
        client.host = route == ra_route::Route::CustomHost ? config::AchievementsHostUrl.get() : "";
        return true;
    }
    void loadCache() {}
    void asyncTask(std::function<void()> task) { tasks.push_back(std::move(task)); }
    void drain() {
        while (!tasks.empty()) { auto batch = std::move(tasks); tasks.clear(); for (auto &f : batch) f(); }
    }
    void authenticationSuccess(const rc_client_user_t *) { successes++; }
    void sessionFailed(const std::string &) { failures++; sessionLogin = SessionLogin::Failed; }
    void setRouteStatus(const std::string &s) { status = s; }
    static void clientEventHandler() {}
    bool init();
    void startProxyLogin();
    void startSessionLogin();
    void verifyManagedCredentials(std::string user, std::string password);
    void startSessionTokenLogin();
    static void clientLoginWithTokenCallback(int, const char *, rc_client_t *, void *);
    static void clientManagedLoginCallback(int, const char *, rc_client_t *, void *);
    static void clientBootstrapLoginCallback(int, const char *, rc_client_t *, void *);
    static void clientSessionLoginCallback(int, const char *, rc_client_t *, void *);
    void answer(size_t index, int result) {
        Callback callback = requests.at(index).callback;
        inCallback = true; callback(result, "synthetic rejection", rc_client, nullptr); inCallback = false;
        drain();
    }
};
''' + '\n'.join(methods) + r'''
}
int main() {
    using namespace achievements;
    using R = ra_route::Route;
    for (R route : {R::CustomHost, R::ProxyCheck, R::Direct}) {
        for (bool rejectedToken : {false, true}) {
            for (bool secondRejection : {false, true}) {
                requests.clear(); ra_account::managed = true; ra_account::saveOk = true;
                ra_account::pending = !rejectedToken; ra_account::retry = rejectedToken;
                config::AchievementsHostUrl = std::string("http://custom.invalid");
                config::AchievementsToken = std::string("old-token");
                Achievements a; a.route = route; a.proxySession = route == R::ProxyCheck;
                assert(a.init()); a.drain();
                const std::string selected = route == R::ProxyCheck ? ra_route::kSessionHost : route == R::CustomHost ? "http://custom.invalid" : "";
                size_t bootstrap = 0;
                if (rejectedToken) {
                    assert(requests.size() == 1 && !requests[0].password && requests[0].host == selected);
                    a.answer(0, -1); bootstrap = 1;
                }
                assert(requests.size() == bootstrap + 1);
                assert(requests[bootstrap].password && requests[bootstrap].host.empty());
                assert(a.successes == 0); // verification alone is not a gameplay session
                a.answer(bootstrap, RC_OK);
                assert(requests.size() == bootstrap + 2);
                assert(!requests.back().password && requests.back().host == selected);
                a.answer(bootstrap + 1, secondRejection ? -1 : RC_OK);
                assert(a.successes == (secondRejection ? 0 : 1));
                assert(a.failures == (secondRejection ? 1 : 0));
                assert(requests.size() == bootstrap + 2); // no password retry loop
                assert(config::AchievementsHostUrl.get() == "http://custom.invalid");
                if (route != R::ProxyCheck) assert(a.status != "Signed in through Leaf's offline service");
            }
        }
    }
    for (bool failedSave : {false, true}) {
        requests.clear(); ra_account::pending = true; ra_account::retry = false; ra_account::saveOk = !failedSave;
        Achievements a; a.route = R::CustomHost; a.init(); a.drain();
        a.answer(0, failedSave ? RC_OK : -1);
        assert(requests.size() == 1 && a.failures == 1 && a.successes == 0);
    }
    // A missing route handoff does not authorize sending a managed password
    // to the saved native host; the selected token host is still preserved.
    requests.clear(); ra_account::pending = true; ra_account::saveOk = true;
    Achievements absent; absent.route = R::CustomHost; absent.routeIntent = ra_route::Intent::Absent;
    absent.init(); absent.drain();
    assert(requests[0].password && requests[0].host.empty());
    absent.answer(0, RC_OK);
    assert(!requests[1].password && requests[1].host == "http://custom.invalid");
    absent.client.user.username = "different-account";
    absent.answer(1, RC_OK);
    assert(absent.successes == 0 && absent.failures == 1);
    // The legacy/native token callback (also used by native host edits) must
    // take the same direct retry path, after returning from the callback.
    requests.clear(); ra_account::pending = false; ra_account::retry = true;
    Achievements legacy; legacy.route = R::CustomHost; legacy.createClient();
    inCallback = true;
    Achievements::clientLoginWithTokenCallback(-1, "expired", legacy.rc_client, nullptr);
    inCallback = false; legacy.drain();
    assert(requests.size() == 1 && requests[0].password && requests[0].host.empty());
    legacy.answer(0, RC_OK);
    assert(requests.size() == 2 && requests[1].host == "http://custom.invalid");
    requests.clear(); ra_account::managed = false; ra_account::pending = false; ra_account::retry = false;
    Achievements native; native.route = R::CustomHost; native.init(); native.drain();
    assert(requests.size() == 1 && !requests[0].password && requests[0].host == "http://custom.invalid");
}
'''
with tempfile.TemporaryDirectory(prefix="flycast-session-login-") as work:
    cpp = pathlib.Path(work) / "session.cpp"
    binary = pathlib.Path(work) / "session-test"
    cpp.write_text(program)
    subprocess.run([os.environ.get("CXX", "c++"), "-std=c++17", "-Wall", "-Wextra",
                    "-Werror", "-Wno-unused-parameter", "-I", str(root / "tests/host-stubs"),
                    "-I", str(source / "core"), str(cpp), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
print("session login: managed passwords always verify directly before the selected token session")
