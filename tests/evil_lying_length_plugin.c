/* tests/evil_lying_length_plugin.c
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * Adversarial reasoning plugin that allocates a tiny real buffer but
 * reports an implausible response_len_out (32 MiB) -- comfortably over
 * FSQL_MAX_INPUT_BYTES (1 MiB, src/fsql_sqlite_internal.h), so a build
 * missing fsql_reasoning_guard_response() would actually attempt to
 * read ~32 MiB out of an 8-byte allocation, not just hit a different,
 * unrelated allocation error.
 *
 * Proves fsql_reasoning_guard_response() rejects a lying plugin BEFORE
 * any read of `summary` is attempted, at all three call sites that use
 * it (fractal_reason, GENERATE, REVIEW).
 *
 * Build: cc -shared -fPIC -std=c99 -Iinclude \
 *          tests/evil_lying_length_plugin.c -o <tmp>/evil_lying.so
 */
#include "fractalsql_sql.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define LIE_LEN ((size_t) 32 * 1024 * 1024)

static int
ll_format(void *u, const char *q, size_t ql, const char *c, size_t cl,
          const char **prompt_out, size_t *prompt_len_out)
{
    (void) u; (void) q; (void) ql; (void) c; (void) cl;
    static char b[2] = { 'x', '\0' };
    *prompt_out = b;
    *prompt_len_out = 1;
    return 0;
}

/* free_fn is called as free_fn(resp) with resp the fsql_ai_response_t*
 * struct itself (fsql_ai_response_free, fractalsql-core/src/fsql.c) --
 * NOT resp->summary. Must cast back and free the buffer, not the
 * struct pointer (which is caller-stack-allocated in fractalsql.c;
 * free()-ing it directly is what actually crashed this test before
 * this fix -- guard_ai_response_len's cleanup call was correct all
 * along, this plugin's free_fn was not). Mirrors
 * tests/mock_reasoning_plugin.c's mock_free, which got this right. */
static void
ll_free(void *opaque)
{
    fsql_ai_response_t *r = (fsql_ai_response_t *) opaque;
    if (r != NULL && r->summary != NULL)
        free(r->summary);
}

/* See the matching comment in evil_nonterminating_plugin.c: GENERATE
 * and REVIEW are two separate calls through this same callback within
 * one fractal_text_to_sql() invocation. Lying on every call only
 * ever reaches GENERATE's guard_ai_response_len call site -- a failing
 * GENERATE never lets the pipeline reach REVIEW's own call site
 * (t2s_run_review, fractalsql.c). FSQL_EVIL_TRIGGER_CALL (fixed file,
 * defaults to call 1) selects which call lies, so trigger=1 tests
 * GENERATE (default), trigger=2 tests REVIEW. */
static int call_count = 0;

static int
ll_generate(void *u, const char *p, size_t pl,
            char **response_out, size_t *response_len_out,
            void (**response_free_fn_out)(void *))
{
    (void) u; (void) p; (void) pl;
    call_count++;

    int trigger = 1;
    FILE *tf = fopen("/tmp/fractalsql_bt_evil_trigger_call.txt", "r");
    if (tf != NULL)
    {
        if (fscanf(tf, "%d", &trigger) != 1)
            trigger = 1;
        fclose(tf);
    }

    if (call_count != trigger)
    {
        char *buf = malloc(9);
        if (buf == NULL)
            return -1;
        memcpy(buf, "SELECT 1", 9);
        *response_out          = buf;
        *response_len_out      = 8;
        *response_free_fn_out  = ll_free;
        return 0;
    }

    char *buf = malloc(8);
    if (buf == NULL)
        return -1;
    memcpy(buf, "SELECT 1", 8);
    *response_out          = buf;
    *response_len_out      = LIE_LEN;   /* the lie: buf is only 8 bytes */
    *response_free_fn_out  = ll_free;
    return 0;
}

int
fsql_reasoning_init(fsql_reasoning_vfs_t *vfs)
{
    vfs->abi_version   = FSQL_REASONING_ABI_VERSION;
    vfs->user_ctx      = NULL;
    vfs->format_prompt = ll_format;
    vfs->generate      = ll_generate;
    return 0;
}
