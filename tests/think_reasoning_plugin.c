/* tests/think_reasoning_plugin.c
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * Deterministic, file-driven mock reasoning plugin for build_test.sh's
 * THINK-GUC gate. Dumps the four THINK-related env vars (THINK,
 * THINK_PROVIDER, NATIVE_URL, NUM_CTX) it sees at format_prompt() time
 * to a fixed file, one per line,
 * "(unset)" for any that aren't set -- the shell-side gate reads that
 * file back and asserts on it. Same fixed-path convention as
 * mock_reasoning_plugin.c/retry_reasoning_plugin.c: the backend forked
 * from the postmaster doesn't inherit the harness's own shell
 * environment, so a file is the only way to get data out.
 *
 * Test-harness use only; never shipped.
 *
 * Build: cc -shared -fPIC -std=c99 -Iinclude \
 *          tests/think_reasoning_plugin.c -o <tmp>/think_reasoning_plugin.so
 */
#define _POSIX_C_SOURCE 200809L

#include "fractalsql_sql.h"

#include <stdio.h>
#include <stdlib.h>

#ifdef _WIN32
#include <windows.h>
#endif

#define THINK_DUMP_FILE "/tmp/fractalsql_bt_think_dump.txt"

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
#ifdef _WIN32
    static char buf[64];
    DWORD n = GetEnvironmentVariableA(name, buf, sizeof buf);
    return (n > 0 && n < sizeof buf) ? buf : NULL;
#else
    return getenv(name);
#endif
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
