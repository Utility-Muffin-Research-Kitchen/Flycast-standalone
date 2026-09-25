// Host stand-in for core/oslib/i18n.h (see README.txt).
#pragma once
#include <string>
namespace i18n
{
static inline std::string Ts(const std::string& msg) { return msg; }
static inline const char *T(const char *msg) { return msg; }
}
