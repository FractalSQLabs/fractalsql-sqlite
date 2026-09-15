/* tests/mock_embed_plugin.c
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * Deterministic mock reasoning plugin for build_test.sh's embed/
 * vectorizer gate. Implements the reasoning ABI directly (no HTTP at
 * all) and always returns a fixed JSON array-of-floats string as the
 * "generate" response -- the exact shape fractal_embed()'s
 * parse_embedding_array() expects (matching what the real
 * fractalsql-reasoning-http plugin hands back after ITS OWN
 * data[0].embedding extraction; see that repo's own mock_http_test.sh
 * for the HTTP-level equivalent of this same contract).
 *
 * Deliberately ignores query/context entirely -- this gate is testing
 * this extension's OWN dispatch/parsing glue (apply_embed_env,
 * fractal_embed, the vectorizer's write-back), not any provider's HTTP
 * behavior. That's already covered by fractalsql-reasoning-http's own
 * test suite and this repo's tests/test_vectorizer.py (which exercises
 * the real vendored .so against a mock HTTP server).
 *
 * Test-harness use only; never shipped.
 *
 * Cross-platform, no OS-specific code (no file I/O, no POSIX-only
 * calls) -- built directly on both build_test.sh (Linux) and
 * build_test.ps1 (Windows), same as tests/evil_lying_length_plugin.c,
 * no separate tests/windows/*_win.c copy needed.
 *
 * Build: cc -shared -fPIC -std=c99 -Iinclude \
 *          tests/mock_embed_plugin.c -o <tmp>/mock_embed_plugin.so
 */
#include "fractalsql_sql.h"

#include <stdlib.h>
#include <string.h>

#define MOCK_EMBED_VECTOR "[0.1,0.2,0.3]"

static int
mock_embed_format(void *u, const char *q, size_t ql, const char *c, size_t cl,
                  const char **prompt_out, size_t *prompt_len_out)
{
    (void) u; (void) q; (void) ql; (void) c; (void) cl;
    static char b[2] = { 'x', '\0' };
    *prompt_out = b;
    *prompt_len_out = 1;
    return 0;
}

static void
mock_embed_free(void *opaque)
{
    fsql_ai_response_t *r = (fsql_ai_response_t *) opaque;
    if (r != NULL && r->summary != NULL)
        free(r->summary);
}

static int
mock_embed_generate(void *u, const char *p, size_t pl,
                    char **response_out, size_t *response_len_out,
                    void (**response_free_fn_out)(void *))
{
    (void) u; (void) p; (void) pl;

    /* Not strdup() -- POSIX-only, and MSVC's CRT treats it as
     * deprecated (C4996). A plain malloc+memcpy has no such baggage on
     * either toolchain. */
    size_t len = strlen(MOCK_EMBED_VECTOR);
    char  *resp = malloc(len + 1);
    if (resp == NULL)
        return -1;
    memcpy(resp, MOCK_EMBED_VECTOR, len + 1);
    *response_out         = resp;
    *response_len_out     = strlen(resp);
    *response_free_fn_out = mock_embed_free;
    return 0;
}

int
fsql_reasoning_init(fsql_reasoning_vfs_t *vfs)
{
    vfs->abi_version   = FSQL_REASONING_ABI_VERSION;
    vfs->user_ctx      = NULL;
    vfs->format_prompt = mock_embed_format;
    vfs->generate      = mock_embed_generate;
    return 0;
}
