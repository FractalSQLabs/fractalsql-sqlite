/* tests/mock_reasoning_plugin.c
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * Deterministic, file-driven mock reasoning plugin for build_test.sh's
 * text-to-sql gate. Implements the reasoning ABI (fsql_reasoning_init)
 * and returns, as the "LLM response", whatever SQL the harness has
 * written to /tmp/fractalsql_bt_sql.txt (wrapped in a ```sql fence).
 * Falls back to "SELECT 1" if the file is absent.
 *
 * A fixed path is used on purpose: the backend is forked from the
 * postmaster and does NOT inherit the harness's environment, so we
 * cannot pass the path via an env var -- the harness writes the file,
 * the plugin reads it. Test-harness use only; never shipped.
 *
 * Build: cc -shared -fPIC -std=c99 -Iinclude \
 *          tests/mock_reasoning_plugin.c -o <tmp>/mock_reasoning_plugin.so
 */
#define _POSIX_C_SOURCE 200809L

#include "fractalsql_sql.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
#endif

#define MOCK_SQL_FILE "/tmp/fractalsql_bt_sql.txt"

/* Dumped fresh on every generate() call so gate_28_review_isolation can
 * tell which tier's dispatch last ran: REVIEW runs after GENERATE within
 * one fractal_text_to_sql() call, so the file reflects REVIEW's env. */
#define MOCK_RESPONSE_MODE_DUMP_FILE "/tmp/fractalsql_bt_review_env_dump.txt"

/* Captured at init, not re-read live in mock_generate(): the real plugin
 * reads RESPONSE_MODE once at init and keeps it for the loaded instance's
 * lifetime; a live getenv() here would always read as unset since
 * ensure_attached() unsets it right after T2S's load. */
static char g_response_mode_at_init[64] = "(unset)";

/* This fixture is built with MinGW gcc but loaded into an MSVC-built
 * sqlite3.exe -- getenv() reads MinGW's own CRT-private environment view,
 * which misses updates the host made through its own CRT.
 * GetEnvironmentVariableA reads the shared OS-level block instead. */
static const char *mock_getenv_response_mode(void) {
#ifdef _WIN32
    static char buf[64];
    DWORD n = GetEnvironmentVariableA(
        "FSQL_REASONING_HTTP_RESPONSE_MODE", buf, sizeof buf);
    return (n > 0 && n < sizeof buf) ? buf : NULL;
#else
    return getenv("FSQL_REASONING_HTTP_RESPONSE_MODE");
#endif
}

static int
mock_format(void *u, const char *q, size_t ql, const char *c, size_t cl,
            const char **prompt_out, size_t *prompt_len_out)
{
    (void) u; (void) q; (void) ql; (void) c; (void) cl;
    static char b[2] = { 'x', '\0' };
    *prompt_out = b;
    *prompt_len_out = 1;
    return 0;
}

static void
mock_free(void *opaque)
{
    fsql_ai_response_t *r = (fsql_ai_response_t *) opaque;
    if (r != NULL && r->summary != NULL)
        free(r->summary);
}

static int
mock_generate(void *u, const char *p, size_t pl,
              char **response_out, size_t *response_len_out,
              void (**response_free_fn_out)(void *))
{
    (void) u; (void) p; (void) pl;

    char  sql[8192] = "SELECT 1";
    FILE *f = fopen(MOCK_SQL_FILE, "r");
    if (f != NULL)
    {
        size_t n = fread(sql, 1, sizeof(sql) - 1, f);
        sql[n] = '\0';
        while (n > 0 && (sql[n - 1] == '\n' || sql[n - 1] == '\r'))
            sql[--n] = '\0';
        fclose(f);
    }

    /* fractal_text_to_sql()'s GENERATE step loads its own reasoning
     * context with FSQL_REASONING_HTTP_RESPONSE_MODE=code -- under
     * that mode a real fractalsql-reasoning-http plugin already
     * strips the fence itself before generate() returns (its own
     * tested extract-and-fail-on-2+-blocks logic), so this mock does
     * no fence-stripping of its own either (that used to be
     * find_sql_span()/extract_sql_from_response(), removed when this
     * mode switch landed). This mock must model that same contract or
     * every gate driving it through fractal_text_to_sql() would see
     * literal ```sql fences as part of the "SQL" and fail to parse --
     * matching real reasoning-http's behavior, not the pre-refactor
     * shape. fractal_reason()'s own bare calls (gate 05/07) never set
     * RESPONSE_MODE, so they still get the fenced form here, same as
     * a real chat-mode response would look before any extraction. */
    const char *response_mode = mock_getenv_response_mode();
    int         code_mode = response_mode != NULL && strcmp(response_mode, "code") == 0;

    FILE *dump = fopen(MOCK_RESPONSE_MODE_DUMP_FILE, "w");
    if (dump != NULL)
    {
        fprintf(dump, "RESPONSE_MODE=%s\n", g_response_mode_at_init);
        fclose(dump);
    }

    char *resp = malloc(strlen(sql) + 16);
    if (resp == NULL)
        return -1;
    if (code_mode)
        strcpy(resp, sql);
    else
        snprintf(resp, strlen(sql) + 16, "```sql\n%s\n```", sql);
    *response_out         = resp;
    *response_len_out     = strlen(resp);
    *response_free_fn_out = mock_free;
    return 0;
}

int
fsql_reasoning_init(fsql_reasoning_vfs_t *vfs)
{
    const char *rm = mock_getenv_response_mode();
    snprintf(g_response_mode_at_init, sizeof g_response_mode_at_init,
             "%s", rm != NULL ? rm : "(unset)");

    vfs->abi_version   = FSQL_REASONING_ABI_VERSION;
    vfs->user_ctx      = NULL;
    vfs->format_prompt = mock_format;
    vfs->generate      = mock_generate;
    return 0;
}
