/* tests/extract_population_probe.c
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * Standalone unit test for src/fractalsql_parse.c's fsql_extract_
 * population(): parses the vendored core's own result JSON
 * ("population":[[...],[...]]) into a flat row-major double array.
 * Unlike fsql_extract_best_point/fsql_parse_embedding_array (its two
 * siblings in the same file), nothing in the normal SQL surface calls
 * this one -- its only caller is the libFuzzer smoke harness (gate 21,
 * FSQL_FUZZ_* only, not part of DEFAULT_GATES), so it's otherwise dead
 * in a plain `./build_test.sh --coverage` run. Built by gate 35's
 * sibling probe compile step, same reasoning as tests/ed25519_probe.c:
 * compiled from the repo root so the recorded source path for src/
 * fractalsql_parse.c matches the main build's own, merging rather than
 * duplicating in the lcov report.
 */
#include "../src/fractalsql_parse.h"

#include <stdio.h>
#include <string.h>

static int failed = 0;

static void check(const char *label, int cond) {
    if (cond) {
        printf("OK: %s\n", label);
    } else {
        failed = 1;
        printf("FAIL: %s\n", label);
    }
}

int main(void) {
    double out[8];

    int n = fsql_extract_population(
        "{\"population\":[[1.0,2.0],[3.0,4.0],[5.0,6.0]]}", 2, 10, out);
    check("parses 3 rows of dim 2", n == 3 &&
          out[0] == 1.0 && out[1] == 2.0 && out[2] == 3.0 &&
          out[3] == 4.0 && out[4] == 5.0 && out[5] == 6.0);

    n = fsql_extract_population("{\"n_found\":0}", 2, 10, out);
    check("no \"population\" key returns 0", n == 0);

    n = fsql_extract_population(NULL, 2, 10, out);
    check("NULL json returns 0", n == 0);

    n = fsql_extract_population(
        "{\"population\":[[1.0,2.0],[3.0,4.0]]}", 2, 1, out);
    check("max_rows caps the row count", n == 1);

    return failed ? 1 : 0;
}
