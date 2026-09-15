/*
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * tests/fuzz/fuzz_extract_best_point.c — libFuzzer entry point for
 * fsql_extract_best_point() (src/fractalsql_parse.c).
 *
 * Lower external-adversary risk than fuzz_parse_embedding_array.c: the
 * JSON this parses is fsql_search_ptr's own result from the vendored
 * fractalsql-core archive, not a third-party HTTP response -- but it's
 * the same hand-rolled strtod-scan technique, worth the same hardening
 * as defense-in-depth against a future core bug or ABI drift feeding
 * this function something unexpected.
 *
 * Build/run: see build_test.sh's fuzz gate ("21 fuzz_smoke") -- do not
 * invoke this file's compile line by hand except for local iteration.
 *   clang -std=c99 -O1 -g -fsanitize=fuzzer,address \
 *         -Iinclude -Isrc \
 *         src/fractalsql_parse.c tests/fuzz/fuzz_extract_best_point.c \
 *         -o fuzz_extract_best_point
 *   ./fuzz_extract_best_point -max_total_time=30 \
 *         tests/fuzz/corpus_extract_best_point/
 */
#include "fractalsql_parse.h"

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* Generous upper bound on `dim` for this harness -- real callers derive
 * cap from the query array's own length (bounded by fractalsql-core's
 * FSQL_MAX_DIM=16384 ceiling; see build_test.sh Gate 19's own note on
 * that constant). */
#define FUZZ_MAX_DIM 16384

int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    if (size == 0)
        return 0;

    /* The real caller (run_sfs's result JSON) is always NUL-terminated
     * by the core; mirror that with a NUL-terminated copy of the fuzz
     * input, same rationale as fuzz_parse_embedding_array.c. */
    char *json = malloc(size + 1);
    if (!json)
        return 0;
    memcpy(json, data, size);
    json[size] = '\0';

    double *out = malloc((size_t) FUZZ_MAX_DIM * sizeof(double));
    if (out)
    {
        fsql_extract_best_point(json, out, FUZZ_MAX_DIM);
        free(out);
    }
    free(json);
    return 0;
}
