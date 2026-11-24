/* tests/windows/win_env_compat.h -- the POSIX setenv/unsetenv on Windows.
 *
 * The unit test (test/redact_unit.c) drives the audit trail's redaction by setting and
 * clearing an environment variable, which is how the server itself reads it at runtime.
 * Neither MSVC's CRT nor mingw's provides setenv/unsetenv -- those are POSIX -- so the
 * Windows build force-includes this header, which maps them onto the CRT's _putenv_s
 * (setting a variable to the empty string removes it, the CRT's documented behaviour).
 *
 * The test source stays POSIX-flavoured and portable this way -- the same shape as the
 * Windows version of the guard-page plugin fixture (tests/windows/
 * evil_nonterminating_plugin_win.c), which carries the Windows version of a POSIX
 * fixture instead of forking the fixture itself.
 */
#ifndef FSQL_WIN_ENV_COMPAT_H
#define FSQL_WIN_ENV_COMPAT_H

#ifdef _WIN32

#include <stdlib.h>

/* overwrite is ignored: _putenv_s always replaces the value. */
static inline int win_compat_setenv(const char *name, const char *value, int overwrite)
{
    (void)overwrite;
    return _putenv_s(name, value ? value : "");
}

static inline int win_compat_unsetenv(const char *name)
{
    return _putenv_s(name, "");
}

#define setenv win_compat_setenv
#define unsetenv win_compat_unsetenv

#endif /* _WIN32 */

#endif /* FSQL_WIN_ENV_COMPAT_H */
