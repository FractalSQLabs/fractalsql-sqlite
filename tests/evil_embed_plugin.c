/* tests/evil_embed_plugin.c
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * Deterministic mock reasoning plugin for build_test.sh's evil-embed
 * gate. Returns a JSON array of MAX_EMBED_DIM_PLUS_ONE (16385, one more
 * than fractalsql.c's MAX_EMBED_DIM=16384) floats -- proving
 * parse_embedding_array() REJECTS an over-limit response (a real bug
 * fixed alongside this test: the original code silently truncated to
 * cap instead, returning a wrong-but-plausible-looking 16384-element
 * vector with no indication it was cut off).
 *
 * Same rationale as evil_lying_length_plugin.c (gate 07) for a buggy or
 * malicious plugin claiming an implausible size -- this is the
 * equivalent adversarial case for the embedding response path
 * specifically, which had no adversarial coverage before this file.
 *
 * Cross-platform, no OS-specific code -- built directly on both
 * build_test.sh and build_test.ps1, same as tests/mock_embed_plugin.c.
 *
 * Test-harness use only; never shipped.
 *
 * Build: cc -shared -fPIC -std=c99 -Iinclude \
 *          tests/evil_embed_plugin.c -o <tmp>/evil_embed_plugin.so
 */
#include "fractalsql_sql.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define EVIL_EMBED_COUNT 16385  /* MAX_EMBED_DIM (16384) + 1 */

static int
evil_embed_format(void *u, const char *q, size_t ql, const char *c, size_t cl,
                  const char **prompt_out, size_t *prompt_len_out)
{
    (void) u; (void) q; (void) ql; (void) c; (void) cl;
    static char b[2] = { 'x', '\0' };
    *prompt_out = b;
    *prompt_len_out = 1;
    return 0;
}

static void
evil_embed_free(void *opaque)
{
    fsql_ai_response_t *r = (fsql_ai_response_t *) opaque;
    if (r != NULL && r->summary != NULL)
        free(r->summary);
}

static int
evil_embed_generate(void *u, const char *p, size_t pl,
                    char **response_out, size_t *response_len_out,
                    void (**response_free_fn_out)(void *))
{
    (void) u; (void) p; (void) pl;

    /* "0," repeated EVIL_EMBED_COUNT-1 times, then a final "0", wrapped
     * in brackets -- e.g. "[0,0,0,...,0]". Each element is 2 bytes
     * ("0,"), so a generous fixed upper bound is enough; no need for a
     * precise size calculation for a test-only buffer. */
    size_t  cap = (size_t) EVIL_EMBED_COUNT * 2 + 16;
    char   *resp = malloc(cap);
    if (resp == NULL)
        return -1;

    size_t off = 0;
    resp[off++] = '[';
    for (int i = 0; i < EVIL_EMBED_COUNT; i++)
    {
        if (i > 0)
            resp[off++] = ',';
        resp[off++] = '0';
    }
    resp[off++] = ']';
    resp[off]   = '\0';

    *response_out         = resp;
    *response_len_out     = off;
    *response_free_fn_out = evil_embed_free;
    return 0;
}

int
fsql_reasoning_init(fsql_reasoning_vfs_t *vfs)
{
    vfs->abi_version   = FSQL_REASONING_ABI_VERSION;
    vfs->user_ctx      = NULL;
    vfs->format_prompt = evil_embed_format;
    vfs->generate      = evil_embed_generate;
    return 0;
}
