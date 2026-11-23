/* tests/embed_then_fail_plugin.c
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * Test fixture for the partial-result path of the retrieval agents (fractal_search_agent, fractal_rag_agent): the FIRST generate call of a
 * process answers with a 3-dim embedding, so the agent's embed step and Scout search complete, and every later call fails. The agent's
 * reasoning step is therefore the call that fails, with its data half already computed -- what agent_partial_reasoning_fail keeps (on) or
 * discards (off, the default). The count is per process, so each sqlite3 invocation in a gate starts over. FSQL_ETF_REPLY makes the
 * later calls answer with that text instead of failing; FSQL_ETF_SCRIPT scripts every call (see script_pick).
 *
 *   cc -shared -fPIC -std=c99 -Iinclude tests/embed_then_fail_plugin.c -o <tmp>/embed_then_fail_plugin.so
 */
#include "fractalsql_sql.h"

#include <stdlib.h>
#include <string.h>

#define EMBED_VECTOR "[0.1,0.2,0.3]"

static int g_calls;

/* FSQL_ETF_SCRIPT: replies separated by the ASCII record separator (0x1e), one per generate call in this process, in order; a reply may be empty.
 * Once the script is used up every later call fails. Returns 0 when there is no script, 1 with the reply for call `idx`, -1 past the end. */
static int
script_pick(int idx, const char **p, size_t *n)
{
    const char *s = getenv("FSQL_ETF_SCRIPT");
    if (s == NULL)
        return 0;
    for (int i = 0;; i++) {
        const char *e = strchr(s, '\x1e');
        size_t len = e ? (size_t) (e - s) : strlen(s);
        if (i == idx) { *p = s; *n = len; return 1; }
        if (e == NULL)
            return -1;
        s = e + 1;
    }
}

static int
etf_format(void *u, const char *q, size_t ql, const char *c, size_t cl, const char **prompt_out, size_t *prompt_len_out)
{
    (void) u; (void) q; (void) ql; (void) c; (void) cl;
    static char b[2] = { 'x', '\0' };
    *prompt_out = b;
    *prompt_len_out = 1;
    return 0;
}

static void
etf_free(void *opaque)
{
    (void) opaque;
}

static int
etf_generate(void *u, const char *p, size_t pl, char **response_out, size_t *response_len_out, void (**response_free_fn_out)(void *))
{
    (void) u; (void) p; (void) pl;
    ++g_calls;
    const char *sp = NULL; size_t sn = 0;
    int sc = script_pick(g_calls - 1, &sp, &sn);
    if (sc < 0)
        return -1;
    if (sc > 0) {
        static char sbuf[8192];
        if (sn >= sizeof sbuf) sn = sizeof sbuf - 1;
        memcpy(sbuf, sp, sn); sbuf[sn] = '\0';
        *response_out = sbuf;
        *response_len_out = sn;
        *response_free_fn_out = etf_free;
        return 0;
    }
    if (g_calls > 1) {
        /* the reasoning step: the plugin reports a failure, unless FSQL_ETF_REPLY gives it a reply to return (a test of how the agents write
         * a model's answer into their JSON: the reply may carry backspace, form feed, carriage return, tab, other control characters, a
         * quote and a backslash). Static buffer: nothing to free. */
        const char *reply = getenv("FSQL_ETF_REPLY");
        if (reply == NULL || reply[0] == '\0')
            return -1;
        static char rbuf[512];
        size_t n = strlen(reply);
        if (n >= sizeof rbuf) n = sizeof rbuf - 1;
        memcpy(rbuf, reply, n); rbuf[n] = '\0';
        *response_out = rbuf;
        *response_len_out = n;
        *response_free_fn_out = etf_free;
        return 0;
    }
    static char resp[] = EMBED_VECTOR;                 /* static: nothing to free */
    *response_out = resp;
    *response_len_out = strlen(resp);
    *response_free_fn_out = etf_free;
    return 0;
}

int
fsql_reasoning_init(fsql_reasoning_vfs_t *vfs)
{
    vfs->abi_version   = FSQL_REASONING_ABI_VERSION;
    vfs->user_ctx      = NULL;
    vfs->format_prompt = etf_format;
    vfs->generate      = etf_generate;
    return 0;
}
