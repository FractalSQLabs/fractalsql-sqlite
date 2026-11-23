/* SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * The REVIEW verdict (src/fsql_verdict.h): the word PASS at the front of the reply, not the letters of a longer word.
 *   cc -std=c11 -Wall -Wextra -Isrc tests/verdict_test.c -o verdict_test && ./verdict_test
 */
#include "fsql_verdict.h"

#include <stdio.h>

/* What the product does first: step over leading whitespace. */
static int verdict(const char *reply)
{
    const char *p = reply;
    while (*p && isspace((unsigned char) *p)) p++;
    return fsql_verdict_is_pass(p);
}

int main(void)
{
    struct { const char *reply; int pass; const char *why; } v[] = {
        { "PASS", 1, "PASS" }, { "pass", 1, "lower case" }, { "Pass", 1, "mixed case" },
        { "  \n PASS", 1, "leading whitespace" }, { "PASS: matches the question", 1, "a reason" },
        { "PASS\nlooks right", 1, "a reason on the next line" }, { "PASS.", 1, "a full stop" },
        { "FAIL: wrong table", 0, "FAIL" }, { "The statement is fine. PASS", 0, "not at the front" },
        { "It selects the wrong column.", 0, "a critique" }, { "", 0, "empty" },
        { "Password column is missing", 0, "a word that starts with pass" },
        { "Passage of time is not modelled", 0, "another" }, { "PASS2 is not a verdict", 0, "a digit after PASS" },
        { "PASS_THROUGH", 0, "an underscore after PASS" }, { "PAS", 0, "too short" },
    };
    int failures = 0;
    for (size_t i = 0; i < sizeof v / sizeof v[0]; i++)
        if (verdict(v[i].reply) != v[i].pass) {
            printf("FAIL (%s): %s\n", v[i].why, v[i].reply);
            failures++;
        }
    if (failures) { printf("%d failure(s)\n", failures); return 1; }
    printf("verdict_test: all cases pass\n");
    return 0;
}
