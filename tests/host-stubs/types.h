// Host stand-in for core/types.h (see README.txt).
#pragma once
#include <cstdint>
#include <cstring>
#include <stdexcept>
#include <string>
#include <strings.h>

#define stricmp strcasecmp

typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef uint64_t u64;
typedef int8_t s8;
typedef int16_t s16;
typedef int32_t s32;
typedef int64_t s64;

class FlycastException : public std::runtime_error
{
public:
	FlycastException(const std::string& reason) : std::runtime_error(reason) {}
	FlycastException(const char *reason) : std::runtime_error(reason) {}
};

// Every log line goes through one writer the fault fixture can make fail.
void umrk_test_log(const char *level, const char *fmt, ...)
#if defined(__GNUC__) || defined(__clang__)
	__attribute__((format(printf, 2, 3)))
#endif
	;

#define ERROR_LOG(t, ...) umrk_test_log("E", __VA_ARGS__)
#define WARN_LOG(t, ...) umrk_test_log("W", __VA_ARGS__)
#define NOTICE_LOG(t, ...) umrk_test_log("N", __VA_ARGS__)
#define INFO_LOG(t, ...) umrk_test_log("I", __VA_ARGS__)
#define DEBUG_LOG(t, ...) umrk_test_log("D", __VA_ARGS__)
