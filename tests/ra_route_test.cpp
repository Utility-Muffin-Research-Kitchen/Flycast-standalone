// Host tests for the per-session RetroAchievements route (patch 0003):
// handoff parsing, the precedence table and the health acceptance rule.
// With "health <port> <path>" it instead runs one real bounded health check
// and prints "<result> <elapsed_ms>", which scripts/ra-route-test.sh drives
// against a local fake service.
#include "achievements/ra_route.h"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

using namespace achievements::ra_route;

static int failures;

static void expect(bool ok, const std::string& what)
{
	if (!ok) {
		std::fprintf(stderr, "ra-route-test: %s\n", what.c_str());
		failures++;
	}
}

static void testIntent()
{
	expect(parseIntent(nullptr) == Intent::Absent, "missing handoff is absent");
	expect(parseIntent("service-live") == Intent::ServiceLive, "service-live");
	expect(parseIntent("native") == Intent::Native, "native");
	for (const char *bad : { "", "SERVICE-LIVE", "service-live ", " native", "live",
			"http://127.0.0.1:8080", "1" })
		expect(parseIntent(bad) == Intent::Invalid, std::string("invalid intent: [") + bad + "]");

	setenv(kEnv, "service-live", 1);
	expect(consumeHandoff() == Intent::ServiceLive, "consume reads the handoff");
	expect(std::getenv(kEnv) == nullptr, "consume removes the handoff");
	expect(consumeHandoff() == Intent::Absent, "a consumed handoff is gone");
}

// Every combination, checked against the table written out independently.
static void testDecide()
{
	const Intent intents[] = { Intent::Absent, Intent::Native, Intent::ServiceLive, Intent::Invalid };
	int combos = 0;
	for (Intent intent : intents)
	for (int known = 0; known < 2; known++)
	for (int enabled = 0; enabled < 2; enabled++)
	for (int account = 0; account < 2; account++)
	for (int hardcore = 0; hardcore < 2; hardcore++)
	for (int custom = 0; custom < 2; custom++)
	{
		Inputs in;
		in.intent = intent;
		in.settingsKnown = known;
		in.enabled = enabled;
		in.accountUsable = account;
		in.hardcore = hardcore;
		in.customHost = custom;
		Decision d = decide(in);
		combos++;

		Route want;
		if (!known || !enabled || !account)
			want = Route::NoAuth;
		else if (hardcore)
			want = Route::Direct;
		else if (custom)
			want = Route::CustomHost;
		else if (intent == Intent::ServiceLive)
			want = Route::ProxyCheck;
		else
			want = Route::Direct;

		char what[160];
		std::snprintf(what, sizeof(what),
				"decide(intent=%s known=%d enabled=%d account=%d hardcore=%d custom=%d) = %s",
				intentName(intent), known, enabled, account, hardcore, custom, routeName(d.route));
		expect(d.route == want, what);
		expect(d.customHostIgnoredForHardcore == (want == Route::Direct && hardcore && custom),
				std::string("custom-host notice: ") + what);
		// The proxy is reachable only through a live-service intent, casual
		// play and no custom host.
		if (d.route == Route::ProxyCheck)
			expect(intent == Intent::ServiceLive && !hardcore && !custom, std::string("proxy leak: ") + what);
	}
	expect(combos == 128, "all combinations covered");
}

static void testHealthRule()
{
	const std::string body = "{\"service\":\"org.umrk.raofflineproxy\",\"protocol\":\"leaf-health-1\",\"ready\":true}";
	const std::string head = "Content-Type: application/json\r\n\r\n";
	expect(healthResponseReady("HTTP/1.0 200 OK\r\n" + head + body), "HTTP/1.0 ready");
	expect(healthResponseReady("HTTP/1.1 200 OK\r\n" + head + body), "HTTP/1.1 ready");
	expect(healthResponseReady("HTTP/1.1 200 OK\r\n\r\n{ \"service\": \"org.umrk.raofflineproxy\",\n"
			" \"protocol\": \"leaf-health-1\", \"ready\": true }"), "whitespace tolerated");
	expect(!healthResponseReady("HTTP/1.1 302 Found\r\nLocation: http://evil/\r\n\r\n" + body), "redirect is not ready");
	expect(!healthResponseReady("HTTP/1.1 503 X\r\n\r\nHTTP/1.1 200 OK\r\n\r\n" + body), "200 must be the status line");
	expect(!healthResponseReady("HTTP/1.1 200 OK\r\n\r\n{\"service\":\"org.umrk.raofflineproxy\",\"protocol\":\"leaf-health-1\",\"ready\":false}"), "not ready");
	expect(!healthResponseReady("HTTP/1.1 200 OK\r\n\r\n{\"service\":\"other\",\"protocol\":\"leaf-health-1\",\"ready\":true}"), "wrong service");
	expect(!healthResponseReady("HTTP/1.1 200 OK\r\n\r\n{\"service\":\"org.umrk.raofflineproxy\",\"protocol\":\"leaf-health-2\",\"ready\":true}"), "wrong protocol");
	expect(!healthResponseReady("HTTP/1.1 200 OK\r\n" + body), "no header terminator");
	expect(!healthResponseReady(""), "empty");
}

int main(int argc, char **argv)
{
	if (argc == 4 && std::strcmp(argv[1], "health") == 0)
	{
		auto start = std::chrono::steady_clock::now();
		Health h = checkHealth(kHealthAddress, std::atoi(argv[2]), argv[3], kHealthBudgetMs);
		long long ms = std::chrono::duration_cast<std::chrono::milliseconds>(
				std::chrono::steady_clock::now() - start).count();
		std::printf("%s %lld\n", healthName(h), ms);
		return 0;
	}
	testIntent();
	testDecide();
	testHealthRule();
	if (failures) {
		std::fprintf(stderr, "ra-route-test: %d FAILURE(S)\n", failures);
		return 1;
	}
	std::printf("ra-route-test: intent, 128 route combinations and health rule ok\n");
	return 0;
}
