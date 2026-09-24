/*
	Host fault injection for the Leaf account fixture.

	Defines fopen, fwrite, fflush, fsync, fclose and rename in the test
	executable itself. The real bridge, marker and configuration code linked
	into the same executable bind to these at link time (no LD_PRELOAD or
	DYLD_INSERT_LIBRARIES, so it behaves the same on Linux and macOS), and each
	call is forwarded to the C library unless a fault is armed for it.

	UMRK_TEST_FAULTS is a ';'-separated list of OP:NAME:MODE[:NTH]
	  OP    fopen_r | fopen_w | fwrite | fflush | fsync | fclose | rename
	        (fopen_w covers "w" and "a" modes; rename matches its source)
	  NAME  the file's basename, compared exactly
	  MODE  eio | enospc | erofs | eacces   fail the call with that errno
	        crash                           _exit(86) instead of the call:
	                                        the process dies at that point
	        partial                         fwrite only: write the first half,
	                                        flush it to the file, then _exit(86)
	  NTH   1-based occurrence of OP on NAME to hit; "*" (default) hits all

	A failing fwrite reports a short count, as a full card does.
*/
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define MAX_FAULTS 16
#define MAX_FILES 64

struct fault
{
	char op[16];
	char name[128];
	char mode[16];
	int nth; /* 0 = every occurrence */
	int seen;
};

static struct fault faults[MAX_FAULTS];
static int fault_count = -1;

static struct
{
	FILE *file;
	int fd;
	char name[128];
} open_files[MAX_FILES];

static const char *base_name(const char *path)
{
	const char *slash = strrchr(path, '/');
	return slash != NULL ? slash + 1 : path;
}

static void load_faults(void)
{
	if (fault_count >= 0)
		return;
	fault_count = 0;
	const char *spec = getenv("UMRK_TEST_FAULTS");
	if (spec == NULL || *spec == '\0')
		return;
	char buffer[2048];
	snprintf(buffer, sizeof(buffer), "%s", spec);
	char *save = NULL;
	for (char *item = strtok_r(buffer, ";", &save); item != NULL && fault_count < MAX_FAULTS;
			item = strtok_r(NULL, ";", &save))
	{
		struct fault *f = &faults[fault_count];
		char nth[16] = "*";
		memset(f, 0, sizeof(*f));
		if (sscanf(item, "%15[^:]:%127[^:]:%15[^:]:%15s", f->op, f->name, f->mode, nth) < 3) {
			fprintf(stderr, "fault shim: bad fault spec '%s'\n", item);
			_exit(2);
		}
		f->nth = strcmp(nth, "*") == 0 ? 0 : atoi(nth);
		fault_count++;
	}
}

/* The armed fault for this call, or NULL. Counts every matching call. */
static struct fault *hit(const char *op, const char *name)
{
	load_faults();
	if (name == NULL)
		return NULL;
	for (int i = 0; i < fault_count; i++)
	{
		struct fault *f = &faults[i];
		if (strcmp(f->op, op) != 0 || strcmp(f->name, name) != 0)
			continue;
		f->seen++;
		if (f->nth == 0 || f->nth == f->seen)
			return f;
	}
	return NULL;
}

static int fault_errno(const struct fault *f)
{
	if (strcmp(f->mode, "enospc") == 0)
		return ENOSPC;
	if (strcmp(f->mode, "erofs") == 0)
		return EROFS;
	if (strcmp(f->mode, "eacces") == 0)
		return EACCES;
	return EIO;
}

static void maybe_crash(const struct fault *f)
{
	if (strcmp(f->mode, "crash") == 0)
		_exit(86);
}

static const char *name_of_file(FILE *file)
{
	for (int i = 0; i < MAX_FILES; i++)
		if (open_files[i].file == file && file != NULL)
			return open_files[i].name;
	return NULL;
}

static const char *name_of_fd(int fd)
{
	for (int i = 0; i < MAX_FILES; i++)
		if (open_files[i].file != NULL && open_files[i].fd == fd)
			return open_files[i].name;
	return NULL;
}

#define REAL(ret, name, args) \
	static ret(*real_##name) args; \
	if (real_##name == NULL) \
		*(void **)(&real_##name) = dlsym(RTLD_NEXT, #name)

FILE *fopen(const char *__restrict path, const char *__restrict mode)
{
	REAL(FILE *, fopen, (const char *, const char *));
	const char *name = base_name(path);
	struct fault *f = hit(mode[0] == 'r' ? "fopen_r" : "fopen_w", name);
	if (f != NULL) {
		maybe_crash(f);
		errno = fault_errno(f);
		return NULL;
	}
	FILE *file = real_fopen(path, mode);
	if (file != NULL)
		for (int i = 0; i < MAX_FILES; i++)
			if (open_files[i].file == NULL) {
				open_files[i].file = file;
				open_files[i].fd = fileno(file);
				snprintf(open_files[i].name, sizeof(open_files[i].name), "%s", name);
				break;
			}
	return file;
}

size_t fwrite(const void *__restrict ptr, size_t size, size_t count, FILE *__restrict file)
{
	REAL(size_t, fwrite, (const void *, size_t, size_t, FILE *));
	REAL(int, fflush, (FILE *));
	struct fault *f = hit("fwrite", name_of_file(file));
	if (f != NULL) {
		maybe_crash(f);
		if (strcmp(f->mode, "partial") == 0) {
			real_fwrite(ptr, 1, (size * count) / 2, file);
			real_fflush(file);
			_exit(86);
		}
		/* A full card: part of the data may land, the count comes up short. */
		size_t half = count / 2;
		if (half > 0)
			real_fwrite(ptr, size, half, file);
		errno = fault_errno(f);
		return half;
	}
	return real_fwrite(ptr, size, count, file);
}

int fflush(FILE *file)
{
	REAL(int, fflush, (FILE *));
	struct fault *f = hit("fflush", name_of_file(file));
	if (f != NULL) {
		maybe_crash(f);
		errno = fault_errno(f);
		return EOF;
	}
	return real_fflush(file);
}

int fsync(int fd)
{
	REAL(int, fsync, (int));
	struct fault *f = hit("fsync", name_of_fd(fd));
	if (f != NULL) {
		maybe_crash(f);
		errno = fault_errno(f);
		return -1;
	}
	return real_fsync(fd);
}

int fclose(FILE *file)
{
	REAL(int, fclose, (FILE *));
	const char *name = name_of_file(file);
	struct fault *f = hit("fclose", name);
	for (int i = 0; i < MAX_FILES; i++)
		if (open_files[i].file == file)
			open_files[i].file = NULL;
	if (f != NULL) {
		maybe_crash(f);
		/* Like a close that reports a deferred write error: the stream is
		   gone either way. */
		real_fclose(file);
		errno = fault_errno(f);
		return EOF;
	}
	return real_fclose(file);
}

int rename(const char *from, const char *to)
{
	REAL(int, rename, (const char *, const char *));
	struct fault *f = hit("rename", base_name(from));
	if (f != NULL) {
		maybe_crash(f);
		errno = fault_errno(f);
		return -1;
	}
	return real_rename(from, to);
}
