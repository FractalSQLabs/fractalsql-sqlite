/*
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * tests/fuzz/fuzz_extract_population.c — libFuzzer entry point for
 * fsql_extract_population() (src/fractalsql_parse.c).
 *
 * Same trust tier as fuzz_extract_best_point.c (parses fsql_search_ptr's
 * own result JSON from the vendored core, not third-party input) --
 * included for the same defense-in-depth reason, and because this
 * parser's nested nested-array/dim-stride bookkeeping is the most
 * structurally complex of the three, the likeliest to have an edge
 * case the other two don't share.
 *
 * dim and max_rows are caller-controlled in production (derived from
 * the query's own dimension and the configured population_size), not
 * part of the untrusted JSON -- so this harness derives small values
 * for both from the first two fuzz bytes rather than fixing them,
 * exercising the dim/max_rows-dependent stride arithmetic
 * (out_flat[(size_t) np * dim + d]) across a real range instead of a
 * single fixed shape. The rest of the input is the JSON to parse.
 *
 * Build/run: see build_test.sh's fuzz gate ("21 fuzz_smoke") -- do not
 * invoke this file's compile line by hand except for local iteration.
 *   clang -std=c99 -O1 -g -fsanitize=fuzzer,address \
 *         -Iinclude -Isrc \
 *         src/fractalsql_parse.c tests/fuzz/fuzz_extract_population.c \
 *         -o fuzz_extract_population
 *   ./fuzz_extract_population -max_total_time=30 \
 *         tests/fuzz/corpus_extract_population/
 */
#include "fractalsql_parse.h"

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* dim in [1,16], max_rows in [1,64] -- small enough that out_flat's
 * dim*max_rows allocation is always cheap (<= 8KB), large enough to
 * exercise multi-row/multi-dim strides, not just the dim=1 case. */
#define FUZZ_MIN_DIM        1
#define FUZZ_MAX_DIM        16
#define FUZZ_MIN_MAX_ROWS   1
#define FUZZ_MAX_MAX_ROWS   64

int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    if (size < 2)
        return 0;

    int dim      = FUZZ_MIN_DIM      + (data[0] % (FUZZ_MAX_DIM - FUZZ_MIN_DIM + 1));
    int max_rows = FUZZ_MIN_MAX_ROWS + (data[1] % (FUZZ_MAX_MAX_ROWS - FUZZ_MIN_MAX_ROWS + 1));

    const uint8_t *json_bytes = data + 2;
    size_t         json_size  = size - 2;

    /* Same NUL-termination rationale as the other two fuzzers in this
     * directory -- the real caller's JSON is always NUL-terminated. */
    char *json = malloc(json_size + 1);
    if (!json)
        return 0;
    memcpy(json, json_bytes, json_size);
    json[json_size] = '\0';

    double *out_flat = malloc((size_t) dim * (size_t) max_rows * sizeof(double));
    if (out_flat)
    {
        fsql_extract_population(json, dim, max_rows, out_flat);
        free(out_flat);
    }
    free(json);
    return 0;
}
