// Host stand-in for core/stdclass.h (see README.txt).
#pragma once
#include "types.h"
#include <string>

std::string get_writable_config_path(const std::string& filename);
std::string get_readonly_config_path(const std::string& filename);

static inline std::string trim_ws(const std::string& str,
		const std::string& whitespace = " \t\r\n")
{
	const auto strStart = str.find_first_not_of(whitespace);
	if (strStart == std::string::npos)
		return "";
	return str.substr(strStart, str.find_last_not_of(whitespace) + 1 - strStart);
}
