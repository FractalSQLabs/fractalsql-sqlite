/* src/fsql_verdict.h
 *
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * The text-to-SQL REVIEW verdict. The reply's first word, after leading whitespace, is PASS in any case: the end of
 * the reply or a non-identifier character comes right after it. "Password column is missing", "Passage of time ..."
 * and "PASS2 ..." begin with the same four letters and are critiques. A critique read as a pass lets a bad candidate
 * through; a pass read as a critique only costs a retry. Header-only so a plain C program can test it.
 */
#ifndef FSQL_VERDICT_H
#define FSQL_VERDICT_H

#include <ctype.h>

/* p points at the first non-whitespace byte of a NUL-terminated reply. */
static inline int fsql_verdict_is_pass(const char *p)
{
    if (p == 0) return 0;
    if (!(tolower((unsigned char)p[0]) == 'p' && tolower((unsigned char)p[1]) == 'a' && p[1] != '\0' &&
          tolower((unsigned char)p[2]) == 's' && p[2] != '\0' && tolower((unsigned char)p[3]) == 's' && p[3] != '\0'))
        return 0;
    return !(isalnum((unsigned char)p[4]) || p[4] == '_');
}

#endif
