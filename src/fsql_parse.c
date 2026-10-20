/* src/fractalsql_parse.c
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * Implementations for fractalsql_parse.h. Pure C99, standard library
 * only.
 */
#include "fractalsql_parse.h"

#include <limits.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

/* Skips the separator set the plugin's JSON emits between array items:
 * spaces, commas and the newline-family. */
static const char *
skip_json_space(const char *p)
{
    while (*p == ' ' || *p == ',' || *p == '\n' || *p == '\r' ||
           *p == '\t') p++;
    return p;
}

int
fsql_extract_best_point(const char *json, double *out, int cap)
{
    if (!json) return -1;
    const char *p = strstr(json, "\"best_point\"");
    if (!p) return -1;
    p = strchr(p, '[');
    if (!p) return -1;
    p++;
    int n = 0;
    for (; *p && n < cap;) {
        p = skip_json_space(p);
        if (*p == ']' || !*p) break;
        char *end = NULL;
        double d = strtod(p, &end);
        if (end == p) return -1;
        out[n++] = d;
        p = end;
    }
    return n;
}

int
fsql_parse_embedding_array(const char *json, double *out, int cap)
{
    if (!json) return -1;
    const char *p = strchr(json, '[');
    if (!p) return -1;
    p++;
    int n = 0;
    while (*p) {
        p = skip_json_space(p);
        if (*p == ']' || !*p) break;
        char *end = NULL;
        double d = strtod(p, &end);
        if (end == p) return -1;
        if (n >= cap) return -1;
        out[n++] = d;
        p = end;
    }
    return n;
}

int
fsql_extract_population(const char *json, int dim, int max_rows, double *out_flat)
{
    if (!json) return 0;
    const char *p = strstr(json, "\"population\":[");
    if (!p)
        return 0;
    p += strlen("\"population\":[");
    int np = 0;
    for (; np < max_rows; np++) {
        while (*p == ' ' || *p == ',') p++;
        if (*p != '[')                          /* end of outer array */
            break;
        p++;
        for (int d = 0; d < dim; d++) {
            char *end = NULL;
            out_flat[(size_t) np * dim + d] = strtod(p, &end);
            if (end == p)                       /* malformed: stop */
                return np;
            p = end;
            while (*p == ' ' || *p == ',') p++;
        }
        if (*p == ']') p++;
    }
    return np;
}

/* Parses one `{"idx": N, "dist": X}` object (the plugin emits objects
 * with idx first, dist second; dist may be JSON null, meaning "no
 * distance"). On success advances *pp past the object's closing '}',
 * fills *idx / *dist and returns 1; on a malformed entry returns 0
 * (the caller treats that as a whole-call failure, as before). */
static int
parse_topk_object(const char **pp, long *idx, double *dist)
{
    const char *p = *pp;
    const char *idx_p = strstr(p, "\"idx\":");
    if (!idx_p) return 0;
    idx_p += strlen("\"idx\":");
    char *end = NULL;
    *idx = strtol(idx_p, &end, 10);
    if (end == idx_p) return 0;
    p = end;
    const char *dist_p = strstr(p, "\"dist\":");
    if (!dist_p) return 0;
    dist_p += strlen("\"dist\":");
    if (strncmp(dist_p, "null", 4) == 0) {
        *dist = 0.0;
        p = dist_p + 4;
    } else {
        end = NULL;
        *dist = strtod(dist_p, &end);
        if (end == dist_p) return 0;
        p = end;
    }
    p = strchr(p, '}');
    if (!p) return 0;
    *pp = p + 1;
    return 1;
}

int
fsql_extract_topk(const char *json, int max_k, int *out_idx, double *out_dist)
{
    /* NULL-safe: a caller whose fsql_search_ptr call failed leaves json NULL,
     * and strstr(NULL, ...) is undefined (segfault). Return "no results"
     * rather than dereferencing. */
    if (!json)
        return -1;
    const char *p = strstr(json, "\"top_k\":[");
    if (!p)
        return -1;
    p += strlen("\"top_k\":[");
    int n = 0;
    for (; n < max_k;) {
        p = skip_json_space(p);
        if (*p == ']' || !*p) break;             /* end of top_k array */
        if (*p != '{') return -1;
        long idx = 0;
        double dist = 0.0;
        if (!parse_topk_object(&p, &idx, &dist)) return -1;
        if (idx >= 0 && idx <= INT_MAX) {       /* skip unfilled (-1) slots;
                                                 * reject values that would
                                                 * wrap in the int cast */
            out_idx[n]  = (int) idx;
            out_dist[n] = dist;
            n++;
        }
    }
    return n;
}
