// Host stand-in for core/ui/gui_achievements.h (see README.txt).
#pragma once
#include <string>

namespace achievements
{

class Notification
{
public:
	enum Type { None, Login, GameLoaded, Unlocked, Progress, Mastery, Challenge, Leaderboard, Error };
	void notify(Type type, const std::string& image, const std::string& text1,
			const std::string& text2 = {}, const std::string& text3 = {});
};

extern Notification notifier;

} // namespace achievements
