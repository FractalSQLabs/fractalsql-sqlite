/* tests/retry_reasoning_plugin.c
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * Deterministic plugin for build_test.sh's retry-with-feedback gate.
 * Returns a rejected DDL statement ("DROP TABLE bt_orders", fails
 * ALLOWLIST) on the first GENERATE call, then "SELECT 1" (passes) on
 * the second -- exercising fractal_text_to_sql()'s retry loop
 * (fractalsql.c, the `last_sql != NULL` prompt-rebuild branch), which
 * is otherwise entirely uncovered since every other gate runs with
 * fractalsql.text_to_sql_max_attempts=1.
 *
 * The 2nd-call prompt is dumped to a fixed file so the harness can
 * confirm the attempt-1 rejection reason was actually threaded back
 * into the GENERATE prompt, not just that *a* retry happened.
 *
 * Test-harness use only; never shipped.
 *
 * Build: cc -shared -fPIC -std=c99 -Iinclude \
 *          tests/retry_reasoning_plugin.c -o <tmp>/retry_reasoning_plugin.so
 */
#define _POSIX_C_SOURCE 200809L

#include "fractalsql_sql.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
#endif

#define RETRY_PROMPT_FILE "/tmp/fractalsql_bt_retry_prompt.txt"

/* getenv() reads this module's own CRT-private environment view, which
 * misses a value set by a differently-built host through its own CRT.
 * GetEnvironmentVariableA reads the shared OS-level block instead. */
static const char *
retry_getenv(const char *name)
{
#ifdef _WIN32
    static char buf[64];
    DWORD n = GetEnvironmentVariableA(name, buf, sizeof buf);
    return (n > 0 && n < sizeof buf) ? buf : NULL;
#else
    return getenv(name);
#endif
}

/* Unlike the other test plugins' format_prompt (which return a fixed
 * dummy string since they don't care about prompt content), this one
 * passes `query` straight through -- retry_generate needs the REAL
 * GENERATE prompt fractalsql.c built (including the "Your previous
 * attempt was..." feedback text on attempt 2) to prove the retry
 * loop's feedback threading actually happened. */
static int
retry_format(void *u, const char *q, size_t ql, const char *c, size_t cl,
             const char **prompt_out, size_t *prompt_len_out)
{
    (void) u; (void) c; (void) cl;
    *prompt_out = q;
    *prompt_len_out = ql;
    return 0;
}

static void
retry_free(void *opaque)
{
    fsql_ai_response_t *r = (fsql_ai_response_t *) opaque;
    if (r != NULL && r->summary != NULL)
        free(r->summary);
}

static int call_count = 0;

static int
retry_generate(void *u, const char *p, size_t pl,
               char **response_out, size_t *response_len_out,
               void (**response_free_fn_out)(void *))
{
    (void) u;
    call_count++;

    if (call_count >= 2)
    {
        FILE *f = fopen(RETRY_PROMPT_FILE, "w");
        if (f != NULL)
        {
            fwrite(p, 1, pl, f);
            fclose(f);
        }
    }

    const char *sql = (call_count == 1) ? "DROP TABLE bt_orders" : "SELECT 1";
    size_t      len = strlen(sql);
    char       *resp = malloc(len + 16);
    if (resp == NULL)
        return -1;
    /* See mock_reasoning_plugin.c's matching comment: fractal_text_to_
     * sql()'s GENERATE step runs under FSQL_REASONING_HTTP_RESPONSE_
     * MODE=code, where a real plugin already strips the fence before
     * generate() returns -- this mock must match that contract or the
     * retry loop's own rebuilt prompt (which echoes attempt 1's
     * candidate back verbatim) ends up double-fenced and unparseable. */
    const char *response_mode = retry_getenv("FSQL_REASONING_HTTP_RESPONSE_MODE");
    if (response_mode != NULL && strcmp(response_mode, "code") == 0)
        strcpy(resp, sql);
    else
        snprintf(resp, len + 16, "```sql\n%s\n```", sql);
    *response_out         = resp;
    *response_len_out     = strlen(resp);
    *response_free_fn_out = retry_free;
    return 0;
}

int
fsql_reasoning_init(fsql_reasoning_vfs_t *vfs)
{
    vfs->abi_version   = FSQL_REASONING_ABI_VERSION;
    vfs->user_ctx      = NULL;
    vfs->format_prompt = retry_format;
    vfs->generate      = retry_generate;
    return 0;
}
