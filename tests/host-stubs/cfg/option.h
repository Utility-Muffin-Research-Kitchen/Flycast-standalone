// Host stand-in for core/cfg/option.h (see README.txt). Only the four
// achievement options the bridge touches, loaded from the real configuration
// store the way Flycast's Settings::load() does.
#pragma once
#include <string>

namespace config
{

template<typename T>
class Option
{
public:
	explicit Option(T def) : value(def), def(def) {}
	const T& get() const { return value; }
	T& get() { return value; }
	operator T() const { return value; }
	Option& operator=(const T& v) { value = v; return *this; }
	void reset() { value = def; }

private:
	T value;
	T def;
};

extern Option<bool> EnableAchievements;
extern Option<std::string> AchievementsUserName;
extern Option<std::string> AchievementsToken;
extern Option<std::string> AchievementsHostUrl;

// Test helper: reset to defaults, then read the [achievements] section of the
// loaded configuration, as a launch does.
void loadAchievementOptions();

} // namespace config
