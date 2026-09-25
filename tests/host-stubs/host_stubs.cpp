// Implementations behind the host stand-in headers (see README.txt): the
// configuration directory, the log writer, the two notification surfaces,
// the plain-file storage the real configuration store opens emu.cfg through,
// and the four achievement options.
#include "types.h"
#include "stdclass.h"
#include "cfg/cfg.h"
#include "cfg/option.h"
#include "oslib/oslib.h"
#include "oslib/storage.h"
#include "ui/gui_achievements.h"

#include <cstdarg>
#include <cstdio>
#include <string>
#include <vector>

std::string umrk_test_config_dir;
std::vector<std::string> umrk_test_notifications;

std::string get_writable_config_path(const std::string& filename)
{
	if (umrk_test_config_dir.empty())
		return {};
	return umrk_test_config_dir + "/" + filename;
}

std::string get_readonly_config_path(const std::string& filename)
{
	return get_writable_config_path(filename);
}

// Flycast's log goes to a file on the same card as everything else, and a log
// write that fails is ignored there too. This writer opens the file through
// the shim, so the fixture can make every log write fail.
void umrk_test_log(const char *level, const char *fmt, ...)
{
	static FILE *log = nullptr;
	static bool tried = false;
	if (!tried) {
		tried = true;
		log = fopen(get_writable_config_path("flycast.log").c_str(), "a");
	}
	char line[1024];
	va_list args;
	va_start(args, fmt);
	vsnprintf(line, sizeof(line), fmt, args);
	va_end(args);
	if (log != nullptr) {
		std::string text = std::string(level) + " " + line + "\n";
		fwrite(text.data(), 1, text.size(), log);
		fflush(log);
	}
}

void os_notify(const char *msg, int, const char *details)
{
	umrk_test_notifications.push_back(std::string("os:") + msg
			+ (details != nullptr ? std::string(" | ") + details : std::string()));
}

namespace achievements
{
Notification notifier;
void Notification::notify(Type, const std::string&, const std::string& text1,
		const std::string& text2, const std::string&)
{
	umrk_test_notifications.push_back("notifier:" + text1
			+ (text2.empty() ? std::string() : " | " + text2));
}
} // namespace achievements

namespace hostfs
{
std::vector<FileInfo> AllStorage::listContent(const std::string&) { return {}; }
File *AllStorage::openFile(const std::string& path, const std::string& mode)
{
	FILE *file = fopen(path.c_str(), mode.c_str());
	return file == nullptr ? nullptr : new StdFile(file);
}
std::string AllStorage::getParentPath(const std::string& path)
{
	const size_t slash = path.find_last_of('/');
	return slash == std::string::npos ? "." : path.substr(0, slash);
}
std::string AllStorage::getSubPath(const std::string& reference, const std::string& subpath)
{
	return reference + "/" + subpath;
}
FileInfo AllStorage::getFileInfo(const std::string& path) { return FileInfo(path, path, false); }
bool AllStorage::exists(const std::string&) { return false; }
AllStorage& storage()
{
	static AllStorage instance;
	return instance;
}
} // namespace hostfs

namespace config
{
Option<bool> EnableAchievements(false);
Option<std::string> AchievementsUserName("");
Option<std::string> AchievementsToken("");
Option<std::string> AchievementsHostUrl("");

void loadAchievementOptions()
{
	EnableAchievements.reset();
	AchievementsUserName.reset();
	AchievementsToken.reset();
	AchievementsHostUrl.reset();
	EnableAchievements = loadBool("achievements", "Enabled", false);
	AchievementsUserName = loadStr("achievements", "UserName", "");
	AchievementsToken = loadStr("achievements", "Token", "");
	AchievementsHostUrl = loadStr("achievements", "HostUrl", "");
}
} // namespace config
