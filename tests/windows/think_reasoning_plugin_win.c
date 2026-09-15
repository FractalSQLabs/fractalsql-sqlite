/* tests/windows/think_reasoning_plugin_win.c
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * Windows port of tests/think_reasoning_plugin.c -- same dump-the-four-
 * THINK-env-vars-to-a-file behavior for build_test.ps1's THINK-GUC gate.
 *
 * Bare relative filename, not the Linux original's /tmp path -- see
 * retry_reasoning_plugin_win.c's header comment for why: the backend's
 * CWD is its own data directory at startup, a location it can always
 * write to, unlike a hardcoded /tmp path that doesn't resolve on
 * Windows. build_test.ps1 reads this back at
 * $DataDir\fractalsql_bt_think_dump.txt to match.
 *
 * Build (via build_test.ps1 -- do not invoke directly):
 *   cl /nologo /MT /LD /DFSQL_STATIC /I<repo>\include ^
 *      tests\windows\think_reasoning_plugin_win.c ^
 *      /Fe<out>\think.dll ^
 *      /link /DEF:tests\windows\fractalsql-test-plugin.def
 */
/* MSVC's CRT-deprecation warnings (fopen/getenv below) are expected in
 * these fixtures -- silenced at the source. */
#define _CRT_SECURE_NO_WARNINGS

#include "fractalsql_sql.h"

#include <stdio.h>
#include <stdlib.h>
#include <Windows.h>

/* Bare relative filename -- see file header comment. */
#define THINK_DUMP_FILE "fractalsql_bt_think_dump.txt"

static const char *
or_unset(const char *v)
{
    return (v != NULL) ? v : "(unset)";
}

/* getenv() reads this module's own CRT-private environment view, which
 * misses a value set by a differently-built host through its own CRT.
 * GetEnvironmentVariableA reads the shared OS-level block instead. */
static const char *
think_getenv(const char *name)
{
    static char buf[64];
    DWORD n = GetEnvironmentVariableA(name, buf, sizeof buf);
    return (n > 0 && n < sizeof buf) ? buf : NULL;
}

static int
think_format(void *u, const char *q, size_t ql, const char *c, size_t cl,
             const char **prompt_out, size_t *prompt_len_out)
{
    (void) u; (void) q; (void) ql; (void) c; (void) cl;

    FILE *f = fopen(THINK_DUMP_FILE, "w");
    if (f != NULL)
    {
        fprintf(f, "THINK=%s\n",          or_unset(think_getenv("FSQL_REASONING_HTTP_THINK")));
        fprintf(f, "THINK_PROVIDER=%s\n", or_unset(think_getenv("FSQL_REASONING_HTTP_THINK_PROVIDER")));
        fprintf(f, "NATIVE_URL=%s\n",     or_unset(think_getenv("FSQL_REASONING_HTTP_NATIVE_URL")));
        fprintf(f, "NUM_CTX=%s\n",        or_unset(think_getenv("FSQL_REASONING_HTTP_NUM_CTX")));
        fclose(f);
    }

    static char b[2] = { 'x', '\0' };
    *prompt_out = b;
    *prompt_len_out = 1;
    return 0;
}

static void
think_free(void *opaque)
{
    fsql_ai_response_t *r = (fsql_ai_response_t *) opaque;
    if (r != NULL && r->summary != NULL)
        free(r->summary);
}

static int
think_generate(void *u, const char *p, size_t pl,
               char **response_out, size_t *response_len_out,
               void (**response_free_fn_out)(void *))
{
    (void) u; (void) p; (void) pl;

    char *resp = malloc(3);
    if (resp == NULL)
        return -1;
    resp[0] = 'O'; resp[1] = 'K'; resp[2] = '\0';
    *response_out         = resp;
    *response_len_out     = 2;
    *response_free_fn_out = think_free;
    return 0;
}

int
fsql_reasoning_init(fsql_reasoning_vfs_t *vfs)
{
    vfs->abi_version   = FSQL_REASONING_ABI_VERSION;
    vfs->user_ctx      = NULL;
    vfs->format_prompt = think_format;
    vfs->generate      = think_generate;
    return 0;
}
