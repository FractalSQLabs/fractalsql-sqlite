/*
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * tests/fuzz/fuzz_parse_embedding_array.c — libFuzzer entry point for
 * fsql_parse_embedding_array() (src/fractalsql_parse.c).
 *
 * Highest-priority fuzz target in this repo: this is the ONE parser
 * here that consumes genuinely externally-adversarial input --
 * fractal_embed()'s raw response from whatever embedding endpoint
 * fractalsql.http_embed_url points at (a malicious or merely buggy
 * third-party HTTP provider fully controls these bytes; see
 * src/fractalsql.c's fractal_embed(), which calls this function on
 * resp.summary after fsql_dispatch_ai returns).
 *
 * Build/run: see scripts wired into build_test.sh's fuzz gate ("21
 * fuzz_smoke") -- do not invoke this file's compile line by hand
 * except for local iteration; the gate is the source of truth for
 * flags.
 *   clang -std=c99 -O1 -g -fsanitize=fuzzer,address \
 *         -Iinclude -Isrc \
 *         src/fractalsql_parse.c tests/fuzz/fuzz_parse_embedding_array.c \
 *         -o fuzz_parse_embedding_array
 *   ./fuzz_parse_embedding_array -max_total_time=30 \
 *         tests/fuzz/corpus_parse_embedding_array/
 */
#include "fractalsql_parse.h"

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* Matches src/fsql_vectorizer.c's FSQLV_MAX_EMBED_DIM -- the real cap
 * fractal_embed() passes. Not #included directly: fsql_vectorizer.c
 * requires sqlite3ext.h and the full extension build environment to
 * compile, so the constant is duplicated here rather than shared.
 * Kept in sync by hand; a mismatch would only make this fuzzer's
 * bound looser or tighter than production, not silently skip
 * coverage of the real code (the parser itself is identical either
 * way).
 */
#define FUZZ_MAX_EMBED_DIM 16384

int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    if (size == 0)
        return 0;

    /* fractal_embed()'s real call site NUL-terminates the plugin's raw
     * response via pnstrdup(resp.summary, resp.summary_len) before
     * handing it to the parser (which uses strchr/strtod -- NUL-
     * terminated-string functions, no length parameter). Mirror that
     * exactly, including the case where the fuzz input contains an
     * embedded NUL before its actual end -- pnstrdup would produce the
     * identical truncated-at-the-NUL view in that case too, so this is
     * a faithful adversarial-response simulation, not a fuzzer-only
     * artifact. */
    char *json = malloc(size + 1);
    if (!json)
        return 0;
    memcpy(json, data, size);
    json[size] = '\0';

    double *out = malloc((size_t) FUZZ_MAX_EMBED_DIM * sizeof(double));
    if (out)
    {
        /* Must not crash, hang, or write past `out`'s FUZZ_MAX_EMBED_DIM
         * doubles on any input, including one with more than
         * FUZZ_MAX_EMBED_DIM elements (must return -1, not overflow --
         * see fractalsql_parse.h's own comment on this function). */
        fsql_parse_embedding_array(json, out, FUZZ_MAX_EMBED_DIM);
        free(out);
    }
    free(json);
    return 0;
}
