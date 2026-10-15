/* tests/extract_parse_probe.c
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * Standalone unit test for src/fractalsql_parse.c's other three
 * parsers: fsql_extract_best_point(), fsql_parse_embedding_array(),
 * and fsql_extract_topk() (which also exercises its static helper
 * parse_topk_object()). All three parse JSON text that, through any
 * real SQL-level call, only ever comes back well-formed from the
 * vendored SFS core or from tests/mock_reasoning_plugin.c's canned
 * responses -- there is no SQL-reachable way to feed them a
 * deliberately malformed "result_json"/embedding response, so their
 * error branches (missing key, malformed number, missing closing
 * brace, etc.) are otherwise dead in a plain `./build_test.sh
 * --coverage` run. Same standalone-probe treatment as gate 35/36
 * (tests/ed25519_probe.c, tests/extract_population_probe.c): built
 * from the repo root so the recorded source path for src/fractalsql_
 * parse.c matches the main build's own, merging into its coverage
 * rather than duplicating.
 */
#include "../src/fractalsql_parse.h"

#include <stdio.h>
#include <limits.h>
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

static void test_best_point(void) {
    double out[8];

    int n = fsql_extract_best_point(
        "{\"best_point\":[1.5,2.5,3.5]}", out, 8);
    check("best_point: parses 3 values", n == 3 &&
          out[0] == 1.5 && out[1] == 2.5 && out[2] == 3.5);

    n = fsql_extract_best_point(NULL, out, 8);
    check("best_point: NULL json returns -1", n == -1);

    n = fsql_extract_best_point("{\"n_found\":0}", out, 8);
    check("best_point: no \"best_point\" key returns -1", n == -1);

    n = fsql_extract_best_point("{\"best_point\":not-an-array}", out, 8);
    check("best_point: no '[' after key returns -1", n == -1);

    n = fsql_extract_best_point("{\"best_point\":[1.0,xyz,3.0]}", out, 8);
    check("best_point: malformed element (strtod no progress) returns -1",
          n == -1);

    n = fsql_extract_best_point("{\"best_point\":[]}", out, 8);
    check("best_point: empty array returns 0", n == 0);

    n = fsql_extract_best_point(
        "{\"best_point\":[1.0,2.0,3.0,4.0]}", out, 2);
    check("best_point: cap stops the scan early", n == 2);
}

static void test_embedding_array(void) {
    double out[8];

    int n = fsql_parse_embedding_array("[1.0,2.0,3.0]", out, 8);
    check("embedding_array: parses 3 values", n == 3 &&
          out[0] == 1.0 && out[1] == 2.0 && out[2] == 3.0);

    n = fsql_parse_embedding_array(NULL, out, 8);
    check("embedding_array: NULL json returns -1", n == -1);

    n = fsql_parse_embedding_array("no-bracket-here", out, 8);
    check("embedding_array: no '[' returns -1", n == -1);

    n = fsql_parse_embedding_array("[1.0,garbage,3.0]", out, 8);
    check("embedding_array: malformed element returns -1", n == -1);

    n = fsql_parse_embedding_array("[1.0,2.0,3.0,4.0]", out, 2);
    check("embedding_array: over-cap input returns -1 (unlike best_point's "
          "silent truncation)", n == -1);

    n = fsql_parse_embedding_array("[]", out, 8);
    check("embedding_array: empty array returns 0", n == 0);
}

static void test_topk(void) {
    int idx[8];
    double dist[8];

    int n = fsql_extract_topk(
        "{\"top_k\":[{\"idx\":1,\"dist\":0.5},"
        "{\"idx\":2,\"dist\":0.25}]}", 8, idx, dist);
    check("topk: parses 2 entries", n == 2 &&
          idx[0] == 1 && dist[0] == 0.5 && idx[1] == 2 && dist[1] == 0.25);

    n = fsql_extract_topk(NULL, 8, idx, dist);
    check("topk: NULL json returns -1", n == -1);

    n = fsql_extract_topk("{\"n_found\":0}", 8, idx, dist);
    check("topk: no \"top_k\" key returns -1", n == -1);

    n = fsql_extract_topk("{\"top_k\":[]}", 8, idx, dist);
    check("topk: empty array returns 0", n == 0);

    n = fsql_extract_topk("{\"top_k\":[1,2,3]}", 8, idx, dist);
    check("topk: element not starting with '{' returns -1", n == -1);

    n = fsql_extract_topk(
        "{\"top_k\":[{\"dist\":0.5}]}", 8, idx, dist);
    check("topk: object missing \"idx\" key returns -1", n == -1);

    n = fsql_extract_topk(
        "{\"top_k\":[{\"idx\":abc,\"dist\":0.5}]}", 8, idx, dist);
    check("topk: idx value strtol no-progress returns -1", n == -1);

    n = fsql_extract_topk(
        "{\"top_k\":[{\"idx\":1}]}", 8, idx, dist);
    check("topk: object missing \"dist\" key returns -1", n == -1);

    n = fsql_extract_topk(
        "{\"top_k\":[{\"idx\":1,\"dist\":xyz}]}", 8, idx, dist);
    check("topk: dist value strtod no-progress returns -1", n == -1);

    n = fsql_extract_topk(
        "{\"top_k\":[{\"idx\":1,\"dist\":null}]}", 8, idx, dist);
    check("topk: JSON null dist parses as 0.0", n == 1 &&
          idx[0] == 1 && dist[0] == 0.0);

    n = fsql_extract_topk(
        "{\"top_k\":[{\"idx\":1,\"dist\":0.5", 8, idx, dist);
    check("topk: object missing closing '}' returns -1", n == -1);

    n = fsql_extract_topk(
        "{\"top_k\":[{\"idx\":-1,\"dist\":0.5},"
        "{\"idx\":3,\"dist\":0.75}]}", 8, idx, dist);
    check("topk: negative idx slot is skipped, not counted", n == 1 &&
          idx[0] == 3 && dist[0] == 0.75);

    {
        /* idx beyond INT_MAX: only reachable where `long` is wider
         * than `int` (true of every build_test.sh host platform). */
        char buf[96];
        long over = (long) INT_MAX + 1;
        snprintf(buf, sizeof buf,
                 "{\"top_k\":[{\"idx\":%ld,\"dist\":0.5}]}", over);
        n = fsql_extract_topk(buf, 8, idx, dist);
        check("topk: idx beyond INT_MAX is skipped, not counted", n == 0);
    }

    n = fsql_extract_topk(
        "{\"top_k\":[{\"idx\":1,\"dist\":0.1},{\"idx\":2,\"dist\":0.2},"
        "{\"idx\":3,\"dist\":0.3}]}", 2, idx, dist);
    check("topk: max_k caps the scan", n == 2);
}

int main(void) {
    test_best_point();
    test_embedding_array();
    test_topk();
    return failed ? 1 : 0;
}
