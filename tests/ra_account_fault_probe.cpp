// One Flycast launch, as far as the Leaf account is concerned, on the host:
// the REAL configuration store (core/cfg/cfg.cpp, ini.cpp), the REAL account
// bridge and contract (ra_account_bridge.cpp, ra_account_contract.cpp), and
// fault injection under all of them (tests/fault_shim.c).
//
// The sequence is the device's: open emu.cfg, load the achievement options,
// ra_account::import(), then the login Achievements::init() would start and
// the callback path its result takes (clientManagedLoginCallback,
// clientLoginWithTokenCallback). The network is simulated by the command
// line: --login / --token-login / --retry-login choose each answer.
//
// Output is secret-free KEY=VALUE lines. Tokens are shown only as a short
// fingerprint; passwords never.
#include "ra_account.h"
#include "cfg/cfg.h"
#include "cfg/option.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <string>
#include <vector>

extern std::string umrk_test_config_dir;
extern std::vector<std::string> umrk_test_notifications;

namespace ra = achievements::ra_account;

namespace
{

std::string fingerprint(const std::string& token)
{
	// FNV-1a, enough to tell synthetic tokens apart without printing one.
	unsigned long long hash = 1469598103934665603ULL;
	for (unsigned char c : token)
		hash = (hash ^ c) * 1099511628211ULL;
	char out[32];
	snprintf(out, sizeof(out), "%016llx", hash);
	return token.empty() ? std::string("none") : std::string(out);
}

const char *arg(int argc, char **argv, const char *name, const char *def)
{
	for (int i = 1; i + 1 < argc; i++)
		if (strcmp(argv[i], name) == 0)
			return argv[i + 1];
	return def;
}

// What achievements.cpp does with a password login result.
void passwordResult(const std::string& answer, const std::string& serverToken)
{
	if (answer == "ok") {
		if (ra::commitLogin(serverToken))
			printf("authenticated=yes\n");
		else
			printf("authenticated=no\n");
	}
	else if (answer == "no-token") {
		ra::reportLoginFailure("no-user-token", "");
		printf("authenticated=no\n");
	}
	else {
		ra::reportLoginFailure("RC_INVALID_CREDENTIALS", "Invalid user/password combination.");
		printf("authenticated=no\n");
	}
}

} // namespace

int main(int argc, char **argv)
{
	const char *dir = arg(argc, argv, "--config-dir", nullptr);
	if (dir == nullptr) {
		fprintf(stderr, "usage: ra_account_fault_probe --config-dir DIR [--login ok|reject|no-token]"
				" [--token-login ok|reject] [--retry-login ok|reject] [--server-token T]\n");
		return 2;
	}
	umrk_test_config_dir = dir;
	const std::string login = arg(argc, argv, "--login", "ok");
	const std::string tokenLogin = arg(argc, argv, "--token-login", "ok");
	const std::string retryLogin = arg(argc, argv, "--retry-login", "ok");
	const std::string serverToken = arg(argc, argv, "--server-token", "synthetic-server-token");

	// flycast_init(): the configuration, then the options, then the import.
	printf("config_open=%s\n", config::open() ? "yes" : "no");
	config::loadAchievementOptions();

	ra::import();

	// The contract's first rule: nothing this process spawns may inherit the
	// snapshot, whatever the verdict was.
	bool scrubbed = true;
	for (const char *name : { "UMRK_RA_ACCOUNT_VERSION", "UMRK_RA_ACCOUNT_STATE",
			"UMRK_RA_ACCOUNT_USERNAME", "UMRK_RA_ACCOUNT_PASSWORD", "UMRK_RA_ACCOUNT_REVISION",
			"JAWAKA_CHEEVOS_USERNAME", "JAWAKA_CHEEVOS_PASSWORD" })
		if (getenv(name) != nullptr)
			scrubbed = false;
	printf("env_scrubbed=%s\n", scrubbed ? "yes" : "no");

	// Achievements::init(): the imported password login first, else the
	// stored token when the bridge allows it.
	std::string user;
	std::string password;
	if (ra::takePendingLogin(user, password))
	{
		printf("login=password user=%s\n", user.c_str());
		std::string again_user, again_password;
		printf("pending_one_shot=%s\n", ra::takePendingLogin(again_user, again_password) ? "no" : "yes");
		passwordResult(login, serverToken);
	}
	else if (ra::isTokenLoginAllowed() && !config::AchievementsUserName.get().empty()
			&& !config::AchievementsToken.get().empty())
	{
		printf("login=token user=%s token=%s\n", config::AchievementsUserName.get().c_str(),
				fingerprint(config::AchievementsToken.get()).c_str());
		if (tokenLogin == "ok")
			printf("authenticated=yes\n");
		else if (ra::takeTokenRetry(user, password))
		{
			printf("retry=password user=%s\n", user.c_str());
			std::string again_user, again_password;
			printf("retry_one_shot=%s\n", ra::takeTokenRetry(again_user, again_password) ? "no" : "yes");
			passwordResult(retryLogin, serverToken);
		}
		else
		{
			printf("retry=none\n");
			printf("authenticated=no\n");
		}
	}
	else
		printf("login=none\n");

	printf("status=%s\n", ra::statusLine().c_str());
	printf("managed=%s\n", ra::isManaged() ? "yes" : "no");
	printf("suppressed=%s\n", ra::isSuppressed() ? "yes" : "no");
	printf("memory_user=%s memory_token=%s\n", config::AchievementsUserName.get().c_str(),
			fingerprint(config::AchievementsToken.get()).c_str());
	for (const std::string& text : umrk_test_notifications)
		printf("notify=%s\n", text.c_str());
	printf("notify_count=%zu\n", umrk_test_notifications.size());
	return 0;
}
