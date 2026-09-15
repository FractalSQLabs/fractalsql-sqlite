/* tests/evil_crash_plugin.c
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * Deliberately self-crashing reasoning plugin. Its generate() writes
 * through a NULL pointer -- an unrecoverable SIGSEGV, not a bug we can
 * guard against (unlike the over-read/lying-length classes covered by
 * evil_nonterminating_plugin.c). No in-process defense can stop this;
 * the extension runs loaded into the calling process, so a plugin
 * crash takes that whole process down.
 *
 * Used by build_test.sh's gate 06 (crash_recovery) to verify what
 * happens next: the sqlite3 process dies, and on the next open SQLite's
 * own WAL/journal replay must bring the database back with no data
 * loss, rather than that being asserted from documentation.
 *
 * Build: cc -shared -fPIC -std=c99 -Iinclude \
 *          tests/evil_crash_plugin.c -o <tmp>/evil_crash.so
 */
#include "fractalsql_sql.h"

#include <stddef.h>

static int
ec_format(void *u, const char *q, size_t ql, const char *c, size_t cl,
          const char **prompt_out, size_t *prompt_len_out)
{
    (void) u; (void) q; (void) ql; (void) c; (void) cl;
    static char b[2] = { 'x', '\0' };
    *prompt_out = b;
    *prompt_len_out = 1;
    return 0;
}

static int
ec_generate(void *u, const char *p, size_t pl,
            char **response_out, size_t *response_len_out,
            void (**response_free_fn_out)(void *))
{
    (void) u; (void) p; (void) pl;
    (void) response_out; (void) response_len_out; (void) response_free_fn_out;
    volatile int *bad = NULL;
    *bad = 1;               /* SIGSEGV, on purpose */
    return -1;              /* unreachable */
}

int
fsql_reasoning_init(fsql_reasoning_vfs_t *vfs)
{
    vfs->abi_version   = FSQL_REASONING_ABI_VERSION;
    vfs->user_ctx      = NULL;
    vfs->format_prompt = ec_format;
    vfs->generate      = ec_generate;
    return 0;
}
