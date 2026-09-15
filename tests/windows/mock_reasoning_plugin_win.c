/* tests/windows/mock_reasoning_plugin_win.c
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * Windows port of tests/mock_reasoning_plugin.c -- same file-driven
 * design (returns whatever SQL the harness wrote to a fixed path,
 * wrapped in a ```sql fence, falling back to "SELECT 1" if absent),
 * but the fixed path is a Windows one. The original's hardcoded
 * "/tmp/fractalsql_bt_sql.txt" does not resolve to anything real on
 * Windows (no /tmp), so fopen() always failed there and every gate 04
 * scenario silently got the "SELECT 1" fallback regardless of what
 * build_test.ps1 actually wrote -- confirmed on the first real
 * Windows run (every injected-SQL scenario reported 'SELECT 1' back).
 *
 * Must match build_test.ps1's $SqlFile constant exactly.
 *
 * Build (via build_test.ps1 -- do not invoke directly):
 *   cl /nologo /MT /LD /DFSQL_STATIC /I<repo>\include ^
 *      tests\windows\mock_reasoning_plugin_win.c ^
 *      /Fe<out>\mock.dll ^
 *      /link /DEF:tests\windows\fractalsql-test-plugin.def
 */
/* MSVC's CRT-deprecation warnings (fopen/strcpy below) are expected in
 * these fixtures -- silenced at the source, not chased file-by-file. */
#define _CRT_SECURE_NO_WARNINGS

#include "fractalsql_sql.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <Windows.h>

/* Bare relative filename, not an absolute C:\Windows\Temp\... path --
 * that absolute path was the previous attempt, and it silently never
 * worked (fopen always returned NULL despite the file demonstrably
 * existing there with the right content, confirmed via diagnostics on
 * a real Windows run -- likely some access restriction specific to
 * that system directory from within the host process, still not
 * fully root-caused). A relative path resolves against the host
 * process's CWD, which build_test.ps1 sets once at startup and never
 * changes -- a location it always has full read/write access to.
 * build_test.ps1 writes this file to match. */
#define MOCK_SQL_FILE "fractalsql_bt_sql.txt"

/* Dumped fresh on every generate() call so Gate-28-ReviewIsolation can
 * tell which tier's dispatch last ran: REVIEW runs after GENERATE within
 * one fractal_text_to_sql() call, so the file reflects REVIEW's env. */
#define MOCK_RESPONSE_MODE_DUMP_FILE "fractalsql_bt_review_env_dump.txt"

/* Captured at init, not re-read live in mock_generate() -- see
 * tests/mock_reasoning_plugin.c's matching comment. */
static char g_response_mode_at_init[64] = "(unset)";

/* getenv() reads this module's own CRT-private environment view, which
 * misses a value set by a differently-built host through its own CRT.
 * GetEnvironmentVariableA reads the shared OS-level block instead. */
static const char *mock_getenv_response_mode(void) {
    static char buf[64];
    DWORD n = GetEnvironmentVariableA(
        "FSQL_REASONING_HTTP_RESPONSE_MODE", buf, sizeof buf);
    return (n > 0 && n < sizeof buf) ? buf : NULL;
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
     * strips the fence itself before generate() returns, so this mock
     * does no fence-stripping of its own either (that used to be
     * find_sql_span()/extract_sql_from_response(), removed when this
     * mode switch landed -- see tests/mock_reasoning_plugin.c's
     * matching Linux-side comment for the full story). This mock must
     * model that same contract or every gate driving it through
     * fractal_text_to_sql() sees literal ```sql fences as part of the
     * "SQL" and fails to parse. fractal_reason()'s own bare calls
     * (gate 05/07) never set RESPONSE_MODE, so they still get the
     * fenced form here, same as a real chat-mode response would look
     * before any extraction. */
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
