/* src/fractalsql_parse.h
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * Pure-C string-parsing helpers. These three functions are the only
 * hand-rolled parsers in the extension that read externally-influenceable
 * text (the core's own search-result JSON, or a reasoning/embedding
 * plugin's raw response) into a fixed-size buffer, exactly the shape
 * of code most worth fuzzing. They live in their own translation unit
 * so a libFuzzer driver can link against them directly. See
 * tests/fuzz/README.md.
 */
#ifndef FRACTALSQL_PARSE_H
#define FRACTALSQL_PARSE_H

#ifdef __cplusplus
extern "C" {
#endif

/* Extract best_point doubles from fsql_search_ptr's result JSON
 * (fractal_search/fractal_search_debug). Returns the count parsed, or
 * -1 on malformed input. */
int fsql_extract_best_point(const char *json, double *out, int cap);

/* Parse a JSON array-of-floats string (e.g. "[0.1,-0.2,0.3]"), the
 * shape of fractal_embed()'s response from the configured embedding
 * plugin, into up to cap doubles. Returns the count parsed, or -1 on
 * malformed input or an array with more than cap elements (never a
 * silent truncation). */
int fsql_parse_embedding_array(const char *json, double *out, int cap);

/* Parse "population":[[...],[...]] from fsql_search_ptr's result JSON
 * (fractal_search_explore / Scout mode) into a flat row-major buffer.
 * Returns the number of particles parsed (never more than max_rows). */
int fsql_extract_population(const char *json, int dim, int max_rows, double *out_flat);

/* Parse "top_k":[{"idx":N,"dist":D},...] from fsql_search_ptr's result
 * JSON (plain, non-population top-k mode: fractal_search_telemetry and
 * its thin compositions) into parallel idx/dist arrays. idx==-1 entries
 * (a corpus row that never got filled, k > n_corpus) are skipped, not
 * emitted. Returns the count parsed (never more than max_k), or -1 on
 * malformed input. */
int fsql_extract_topk(const char *json, int max_k, int *out_idx, double *out_dist);

#ifdef __cplusplus
}
#endif

#endif /* FRACTALSQL_PARSE_H */
