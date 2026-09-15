/* src/fsql_sovereign.c: sovereign-tier scalar math surface.
 *
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * Implements the diversify/feedback, fractal-dimension, portfolio-
 * optimization, and domain-geometry SQL surface. This TU is compiled
 * ONLY under FSQL_SQLITE_SOVEREIGN: the functions below call
 * sovereign-only core ABI symbols (see include/fractalsql_sql.h)
 * that the minimal archive does not export, so there are no inner
 * #ifdefs here.
 *
 * SQL surface:
 *
 *   fractal_dimension_dfa(series)                        -> REAL
 *   fractal_dimension_drift(series, win)                 -> TEXT (JSON)
 *   fractal_dimension_boxcount(points, dim)              -> REAL
 *   fractal_optimize_portfolio(mu, cov, k                -> TEXT (JSON)
 *         [, seed [, use_obl [, diffusion_mode]]])
 *   fractal_optimize_portfolio_multimodal(mu, cov, k     -> TEXT (JSON)
 *         [, n_restarts [, overlap [, quality [, seed
 *         [, use_obl [, diffusion_mode]]]]]])
 *   fractal_optimize_portfolio_multimodal_pareto(        -> TEXT (JSON)
 *         mu, cov, k [, n_restarts [, max_front
 *         [, seed [, use_obl [, diffusion_mode]]]]])
 *   fractal_vascular_network(node_coords, edges, arc)    -> TEXT (JSON)
 *   fractal_cortical_folding(vertices, faces)            -> TEXT (JSON)
 *   fractal_nerve_plexus_metric(node_coords, dim, edges) -> TEXT (JSON)
 *   fractal_morphological_complexity(points, dim)        -> TEXT (JSON)
 *   fractal_diversify_enable()                           -> (null)
 *   fractal_diversify_disable()                          -> (null)
 *   fractal_diversify_set_params(params_json)            -> (null)
 *   fractal_diversify_current_dq()                       -> REAL / NULL
 *   fractal_diversify_overhead_p99_us()                  -> REAL / NULL
 *   fractal_feedback_report(handle, kind [, dwell_ms])   -> (null)
 *
 * Design notes:
 *
 *   - Flat numeric arrays arrive as TEXT (CSV or bracketed JSON,
 *     parsed by the shared fsql_parse_text_vector) or as a BLOB of
 *     packed little-endian float32 (parsed by the shared
 *     fsql_parse_blob_vector). Index arrays (edges/faces) are
 *     narrowed from doubles to size_t with a 1e-6 integrality check.
 *   - Result JSON documents come back as TEXT (SQLite has no jsonb;
 *     json() / json_extract work on the text).
 *   - Variadic-with-DEFAULTS signatures are reproduced by registering
 *     each portfolio / feedback name at several arities; omitted
 *     trailing arguments take the documented defaults exactly.
 *   - seed is signed 64-bit INTEGER, but a TEXT seed is additionally
 *     accepted and parsed via strtoull so full-range uint64 seeds are
 *     expressible.
 *   - The multimodal / Pareto functions call the core's *_ex symbols
 *     directly (the sovereign archive always exports them).
 *   - Portfolio decisions are not separately logged to the audit
 *     chain here.
 *   - fractal_detect_collapse() is registered here under its SQL name
 *     fractal_diversify_current_dq(); NaN (no query run yet /
 *     diversify disabled) becomes SQL NULL, since SQLite has no NaN.
 *   - fractal_explain_result lives in fsql_agents.c, not here.
 */

#include <sqlite3ext.h>
SQLITE_EXTENSION_INIT3

#include <math.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fsql_hmac.h"
#include "fsql_sqlite_internal.h"

/* Element-count ceiling for one decoded array argument (the same
 * 4 MiB input cap the rest of the extension applies; doubles in memory
 * may exceed the wire size, so the cap is counted in elements). */
#define FSQL_SOVEREIGN_MAX_ELEMS  FSQL_MAX_INPUT_BYTES

/* ------------------------------------------------------------------
 * State + small shared helpers
 * ------------------------------------------------------------------ */

/* Every function here needs the shared sovereign ctx. */
static FsqlState *sovereign_state(sqlite3_context *ctx) {
    FsqlState *st = (FsqlState *)sqlite3_user_data(ctx);
    if (!st || !st->ctx) {
        sqlite3_result_error(ctx, "fractalsql: extension not initialized", -1);
        return NULL;
    }
    return st;
}

/* STRICT-equivalent: any NULL argument -> NULL result. */
static int any_arg_null(int argc, sqlite3_value **argv) {
    for (int i = 0; i < argc; i++)
        if (sqlite3_value_type(argv[i]) == SQLITE_NULL) return 1;
    return 0;
}

/* ------------------------------------------------------------------
 * Array decoding: TEXT CSV/JSON or float32 BLOB -> malloc'd doubles.
 * Mirrors fsql_vector.c's fsql_vec_decode, but keeps double precision
 * and allows point-cloud / matrix sizes beyond fractal_vector's dim16.
 * ------------------------------------------------------------------ */

static int decode_series(sqlite3_value *v, double **out_data, int *out_n) {
    *out_data = NULL;
    *out_n = 0;

    int type = sqlite3_value_type(v);
    if (type == SQLITE_BLOB) {
        int nbytes = sqlite3_value_bytes(v);
        if (nbytes <= 0 || (nbytes & 3) != 0) return -1;
        if (nbytes > FSQL_MAX_INPUT_BYTES) return -1;
        int count = nbytes / 4;
        if (count > FSQL_SOVEREIGN_MAX_ELEMS) return -1;
        double *data = (double *)malloc((size_t)count * sizeof(double));
        if (!data) return -1;
        int n = fsql_parse_blob_vector(sqlite3_value_blob(v), nbytes,
                                       data, count);
        if (n < 1) { free(data); return -1; }
        *out_data = data;
        *out_n = n;
        return 0;
    }
    if (type != SQLITE_TEXT) return -1;

    int slen = sqlite3_value_bytes(v);
    if (slen <= 0 || slen > FSQL_MAX_INPUT_BYTES) return -1;
    const char *s = (const char *)sqlite3_value_text(v);

    /* Count elements first (worst case: n commas + 1), same as
     * fsql_vec_decode. */
    int cap = 1;
    for (int i = 0; i < slen; i++)
        if (s[i] == ',') cap++;
    if (cap > FSQL_SOVEREIGN_MAX_ELEMS) return -1;

    double *data = (double *)malloc((size_t)cap * sizeof(double));
    if (!data) return -1;
    int n = fsql_parse_text_vector(s, slen, data, cap);
    if (n < 1) { free(data); return -1; }

    *out_data = data;
    *out_n = n;
    return 0;
}

/* Flat index array (edges / faces): decode as doubles, then narrow to
 * size_t: entries must be non-negative integers (within 1e-6) and fit
 * a signed 32-bit range. Return codes: 0 ok, -1 malformed, -2
 * negative, -3 non-integral, -4 out of range, -5 OOM. */
static int decode_indices(sqlite3_value *v, size_t **out_idx, int *out_n,
                          char *err, size_t err_cap) {
    *out_idx = NULL;
    *out_n = 0;

    double *data = NULL;
    int n = 0;
    if (decode_series(v, &data, &n) != 0) return -1;

    size_t *idx = (size_t *)malloc((size_t)n * sizeof(size_t));
    if (!idx) { free(data); return -5; }

    for (int i = 0; i < n; i++) {
        double d = data[i];
        /* isnan first: every comparison below is false for NaN, so it
         * would sail through all three guards into a UB (size_t)
         * conversion. */
        if (isnan(d)) {
            free(data); free(idx);
            snprintf(err, err_cap,
                     "fractalsql: index array entries must be numbers "
                     "(got nan)");
            return -2;
        }
        if (d < 0.0) {
            free(data); free(idx);
            snprintf(err, err_cap,
                     "fractalsql: index array entries must be >= 0 (got %g)", d);
            return -2;
        }
        if (fabs(d - round(d)) > 1e-6) {
            free(data); free(idx);
            snprintf(err, err_cap,
                     "fractalsql: index array entries must be integers (got %g)", d);
            return -3;
        }
        if (d > 2147483647.0) {
            free(data); free(idx);
            snprintf(err, err_cap,
                     "fractalsql: index array entries must be <= 2147483647 (got %g)", d);
            return -4;
        }
        idx[i] = (size_t)d;
    }
    free(data);
    *out_idx = idx;
    *out_n = n;
    return 0;
}

/* ------------------------------------------------------------------
 * Growable string builder for the dynamic-size JSON results (the
 * portfolio functions embed n_assets / n_restarts weight rows; the
 * fixed-shape documents below use plain stack buffers instead).
 * ------------------------------------------------------------------ */

typedef struct { char *s; size_t len, cap; } SB;

static int sb_grow(SB *b, size_t need) {
    if (b->len + need + 1 <= b->cap) return 0;
    size_t ncap = b->cap ? b->cap : 256;
    while (ncap < b->len + need + 1) ncap *= 2;
    char *ns = (char *)realloc(b->s, ncap);
    if (!ns) return -1;
    b->s = ns;
    b->cap = ncap;
    return 0;
}

static int sb_append(SB *b, const char *s) {
    size_t n = strlen(s);
    if (sb_grow(b, n) != 0) return -1;
    memcpy(b->s + b->len, s, n + 1);
    b->len += n;
    return 0;
}

static int sb_appendf(SB *b, const char *fmt, ...) {
    va_list ap, ap2;
    va_start(ap, fmt);
    va_copy(ap2, ap);
    int need = vsnprintf(NULL, 0, fmt, ap);
    va_end(ap);
    if (need < 0 || sb_grow(b, (size_t)need) != 0) {
        va_end(ap2);
        return -1;
    }
    vsnprintf(b->s + b->len, (size_t)need + 1, fmt, ap2);
    va_end(ap2);
    b->len += (size_t)need;
    return 0;
}

/* Hand the built TEXT to SQLite (TRANSIENT copies, then we free). */
static void sb_result(sqlite3_context *ctx, SB *b) {
    if (!b->s) { sqlite3_result_error_nomem(ctx); return; }
    sqlite3_result_text(ctx, b->s, (int)b->len, SQLITE_TRANSIENT);
    free(b->s);
    b->s = NULL;
}

/* Fixed-shape JSON result, formatted with %.10f. */
static void result_jsonf(sqlite3_context *ctx, char *buf, size_t cap,
                         const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, cap, fmt, ap);
    va_end(ap);
    sqlite3_result_text(ctx, buf, -1, SQLITE_TRANSIENT);
}

/* ------------------------------------------------------------------
 * Argument parsing shared by the portfolio functions
 * ------------------------------------------------------------------ */

/* diffusion_mode text -> FSQL_SFS_DIFFUSE_* int. Returns -1 on a bad
 * value with the message already formatted into err. */
static int parse_diffusion_mode(sqlite3_value *v, char *err, size_t err_cap) {
    const char *mode = (const char *)sqlite3_value_text(v);
    if (mode && strcmp(mode, "gaussian") == 0) return 0;
    if (mode && strcmp(mode, "levy") == 0)     return 1;
    snprintf(err, err_cap,
             "fractalsql: diffusion_mode must be 'gaussian' or 'levy' (got '%s')",
             mode ? mode : "NULL");
    return -1;
}

/* seed: INTEGER wraps to uint64 via a (uint64_t) cast; TEXT is
 * additionally accepted and parsed with strtoull so the full unsigned
 * range is expressible (SQLite INTEGER is signed 64). */
static uint64_t parse_seed(sqlite3_value *v) {
    if (sqlite3_value_type(v) == SQLITE_TEXT) {
        const char *s = (const char *)sqlite3_value_text(v);
        return strtoull(s ? s : "0", NULL, 10);
    }
    /* INTEGER or FLOAT: both truncate/wrap to the unsigned value. */
    return (uint64_t)sqlite3_value_int64(v);
}

/* ------------------------------------------------------------------
 * Fractal dimension analysis
 * ------------------------------------------------------------------ */

/* fractal_dimension_dfa(series) -> REAL */
static void dim_dfa_fn(sqlite3_context *ctx, int argc,
                       sqlite3_value **argv) {
    (void)argc;
    if (any_arg_null(1, argv)) { sqlite3_result_null(ctx); return; }

    double *series = NULL;
    int n = 0;
    if (decode_series(argv[0], &series, &n) != 0) {
        sqlite3_result_error(ctx,
            "fractalsql: malformed series (expect CSV/JSON text or "
            "float32 BLOB)", -1);
        return;
    }
    double alpha = 0.0;
    int rc = fsql_dimension_dfa(series, (size_t)n, &alpha);
    free(series);
    if (rc != FSQL_OK) {
        char buf[128];
        snprintf(buf, sizeof buf,
                 "fractalsql: fractal_dimension_dfa rc=%d "
                 "(series needs >= 16 points)", rc);
        sqlite3_result_error(ctx, buf, -1);
        return;
    }
    sqlite3_result_double(ctx, alpha);
}

/* fractal_dimension_drift(series, win) -> TEXT JSON
 * {"drift":..,"recent_alpha":..,"baseline_alpha":..} */
static void dim_drift_fn(sqlite3_context *ctx, int argc,
                         sqlite3_value **argv) {
    (void)argc;
    if (any_arg_null(2, argv)) { sqlite3_result_null(ctx); return; }

    double *series = NULL;
    int n = 0;
    if (decode_series(argv[0], &series, &n) != 0) {
        sqlite3_result_error(ctx,
            "fractalsql: malformed series (expect CSV/JSON text or "
            "float32 BLOB)", -1);
        return;
    }
    int window = sqlite3_value_int(argv[1]);
    if (window <= 0) {
        free(series);
        sqlite3_result_error(ctx, "fractalsql: window must be > 0", -1);
        return;
    }

    double drift = 0.0, recent_alpha = 0.0, baseline_alpha = 0.0;
    int rc = fsql_dimension_drift(series, (size_t)n, (size_t)window,
                                  &drift, &recent_alpha, &baseline_alpha);
    free(series);
    if (rc != FSQL_OK) {
        char buf[160];
        snprintf(buf, sizeof buf,
                 "fractalsql: fractal_dimension_drift rc=%d "
                 "(need n >= window + 16, window >= 16)", rc);
        sqlite3_result_error(ctx, buf, -1);
        return;
    }

    char buf[256];
    result_jsonf(ctx, buf, sizeof buf,
                 "{\"drift\":%.10f,\"recent_alpha\":%.10f,"
                 "\"baseline_alpha\":%.10f}",
                 drift, recent_alpha, baseline_alpha);
}

/* fractal_dimension_boxcount(points, dim) -> REAL */
static void dim_boxcount_fn(sqlite3_context *ctx, int argc,
                            sqlite3_value **argv) {
    (void)argc;
    if (any_arg_null(2, argv)) { sqlite3_result_null(ctx); return; }

    double *points = NULL;
    int flat_n = 0;
    if (decode_series(argv[0], &points, &flat_n) != 0) {
        sqlite3_result_error(ctx,
            "fractalsql: malformed points (expect CSV/JSON text or "
            "float32 BLOB)", -1);
        return;
    }
    int dim = sqlite3_value_int(argv[1]);
    if (dim <= 0 || flat_n % dim != 0) {
        free(points);
        char buf[128];
        snprintf(buf, sizeof buf,
                 "fractalsql: points length (%d) must be a positive "
                 "multiple of dim (%d)", flat_n, dim);
        sqlite3_result_error(ctx, buf, -1);
        return;
    }

    double dimension = 0.0;
    int rc = fsql_dimension_boxcount(points, (size_t)(flat_n / dim),
                                     (size_t)dim, &dimension);
    free(points);
    if (rc != FSQL_OK) {
        char buf[160];
        snprintf(buf, sizeof buf,
                 "fractalsql: fractal_dimension_boxcount rc=%d "
                 "(need >= 8 points, non-degenerate bounding box)", rc);
        sqlite3_result_error(ctx, buf, -1);
        return;
    }
    sqlite3_result_double(ctx, dimension);
}

/* ------------------------------------------------------------------
 * Portfolio optimization
 * ------------------------------------------------------------------ */

/* Shared input validation + decode for all portfolio variants.
 * Returns 0 on success with *mu_out / *cov_out malloc'd; on failure a
 * SQLite error has already been set and the outputs are NULL. */
static int portfolio_decode(sqlite3_context *ctx, sqlite3_value *mu_v,
                            sqlite3_value *cov_v, sqlite3_value *k_v,
                            double **mu_out, int *n_assets_out,
                            double **cov_out, int *k_out) {
    *mu_out = NULL;
    *cov_out = NULL;

    if (sqlite3_value_type(mu_v) == SQLITE_NULL ||
        sqlite3_value_type(cov_v) == SQLITE_NULL ||
        sqlite3_value_type(k_v) == SQLITE_NULL) {
        sqlite3_result_error(ctx,
            "fractalsql: mu, cov and k must not be NULL", -1);
        return -1;
    }

    int n_assets = 0, cov_n = 0;
    double *mu = NULL, *cov = NULL;
    if (decode_series(mu_v, &mu, &n_assets) != 0 ||
        decode_series(cov_v, &cov, &cov_n) != 0) {
        free(mu); free(cov);
        sqlite3_result_error(ctx,
            "fractalsql: malformed mu/cov (expect CSV/JSON text or "
            "float32 BLOB)", -1);
        return -1;
    }

    /* Both sides widened to int64 before multiplying. Without it, an
     * n_assets whose square wraps to a small value would let a short
     * cov buffer pass the length check and the optimizer would read
     * past the allocation. */
    if ((int64_t)cov_n != (int64_t)n_assets * (int64_t)n_assets) {
        char buf[160];
        snprintf(buf, sizeof buf,
                 "fractalsql: cov length (%d) must be n_assets^2 "
                 "(n_assets=%d, expected %lld)",
                 cov_n, n_assets, (long long)n_assets * (long long)n_assets);
        free(mu); free(cov);
        sqlite3_result_error(ctx, buf, -1);
        return -1;
    }

    int k = sqlite3_value_int(k_v);
    if (k <= 0 || k > n_assets) {
        char buf[128];
        snprintf(buf, sizeof buf,
                 "fractalsql: k must satisfy 1 <= k <= n_assets (%d)",
                 n_assets);
        free(mu); free(cov);
        sqlite3_result_error(ctx, buf, -1);
        return -1;
    }

    *mu_out = mu;
    *cov_out = cov;
    *n_assets_out = n_assets;
    *k_out = k;
    return 0;
}

/* Trailing-argument accessors: argc is the registered arity actually
 * invoked; missing trailing args take the documented DEFAULT values. */
static uint64_t opt_seed(int argc, sqlite3_value **argv, int idx) {
    if (argc <= idx || sqlite3_value_type(argv[idx]) == SQLITE_NULL) return 0;
    return parse_seed(argv[idx]);
}
static int opt_bool(int argc, sqlite3_value **argv, int idx) {
    if (argc <= idx || sqlite3_value_type(argv[idx]) == SQLITE_NULL) return 0;
    return sqlite3_value_int(argv[idx]) != 0;
}
static double opt_double(int argc, sqlite3_value **argv, int idx,
                         double dflt) {
    if (argc <= idx || sqlite3_value_type(argv[idx]) == SQLITE_NULL)
        return dflt;
    return sqlite3_value_double(argv[idx]);
}
static int opt_int(int argc, sqlite3_value **argv, int idx, int dflt) {
    if (argc <= idx || sqlite3_value_type(argv[idx]) == SQLITE_NULL)
        return dflt;
    return sqlite3_value_int(argv[idx]);
}
/* Returns the FSQL_SFS_DIFFUSE_* value, or -1 with err filled in. */
static int opt_diffusion(int argc, sqlite3_value **argv, int idx,
                         char *err, size_t err_cap) {
    if (argc <= idx || sqlite3_value_type(argv[idx]) == SQLITE_NULL)
        return 0;                       /* 'gaussian' */
    return parse_diffusion_mode(argv[idx], err, err_cap);
}

/* Best-effort audit-chain provenance (fractalsql_ledger kind=2).
 * fractal_audit_log is itself enterprise-gated (fsql_ledger.c), so
 * this silently no-ops on a community-only connection -- portfolio
 * optimization is a community feature and must keep working
 * regardless. Any failure (no license, OOM, ledger I/O) is discarded,
 * same pattern as da_audit_log_best_effort in fsql_domain_agents.c.
 * `entry_json` is the bare entry object (no outer
 * {"type":..,"entry":..} envelope -- fractal_audit_log adds that). */
static void sovereign_audit_log_best_effort(FsqlState *st,
                                            const char *entry_type,
                                            const char *entry_json) {
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(st->db, "SELECT fractal_audit_log(?1,?2)", -1,
                           &stmt, NULL) != SQLITE_OK)
        return;
    sqlite3_bind_text(stmt, 1, entry_type, -1, SQLITE_STATIC);
    sqlite3_bind_text(stmt, 2, entry_json, -1, SQLITE_TRANSIENT);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
}

/* SHA-256 of the flattened (mu || cov) input bytes, as lowercase hex --
 * a compact, non-reversible fingerprint of the optimization inputs for
 * the audit record's `inputs_hash` field. */
static int sovereign_inputs_hash_hex(const double *mu, const double *cov,
                                     int n_assets, char hex_out[65]) {
    size_t mu_bytes = (size_t)n_assets * sizeof(double);
    size_t cov_bytes = (size_t)n_assets * (size_t)n_assets * sizeof(double);
    uint8_t *buf = (uint8_t *)malloc(mu_bytes + cov_bytes);
    if (!buf) return -1;
    memcpy(buf, mu, mu_bytes);
    memcpy(buf + mu_bytes, cov, cov_bytes);
    uint8_t hash[32];
    fsql_sha256(buf, mu_bytes + cov_bytes, hash);
    free(buf);
    for (int i = 0; i < 32; i++)
        snprintf(hex_out + i * 2, 3, "%02x", hash[i]);
    return 0;
}

static void portfolio_audit_log_best_effort(FsqlState *st, const double *mu,
                                            const double *cov, int n_assets,
                                            int k, uint64_t seed,
                                            double sharpe,
                                            const double *weights) {
    char hash_hex[65];
    if (sovereign_inputs_hash_hex(mu, cov, n_assets, hash_hex) != 0) return;

    SB js; memset(&js, 0, sizeof js);
    int bad = sb_appendf(&js,
        "{\"seed\":%llu,\"n_assets\":%d,\"k\":%d,\"sharpe\":%.10f,"
        "\"inputs_hash\":\"%s\",\"weights\":[",
        (unsigned long long)seed, n_assets, k, sharpe, hash_hex);
    for (int i = 0; i < n_assets && !bad; i++)
        bad = sb_appendf(&js, "%s%.10f", i ? "," : "", weights[i]);
    if (!bad) bad = sb_append(&js, "]}");
    if (!bad) sovereign_audit_log_best_effort(st, "portfolio_optimize", js.s);
    free(js.s);
}

static void portfolio_multimodal_audit_log_best_effort(FsqlState *st,
                                                        const double *mu,
                                                        const double *cov,
                                                        int n_assets, int k,
                                                        int n_restarts,
                                                        uint64_t seed,
                                                        int n_found,
                                                        const double *sharpes,
                                                        const double *weights) {
    char hash_hex[65];
    if (sovereign_inputs_hash_hex(mu, cov, n_assets, hash_hex) != 0) return;

    SB js; memset(&js, 0, sizeof js);
    int bad = sb_appendf(&js,
        "{\"seed\":%llu,\"n_assets\":%d,\"k\":%d,\"n_restarts\":%d,"
        "\"n_found\":%d,\"inputs_hash\":\"%s\",\"candidates\":[",
        (unsigned long long)seed, n_assets, k, n_restarts, n_found, hash_hex);
    for (int c = 0; c < n_found && !bad; c++) {
        bad = sb_appendf(&js, "%s{\"sharpe\":%.10f,\"weights\":[",
                         c ? "," : "", sharpes[c]);
        for (int i = 0; i < n_assets && !bad; i++)
            bad = sb_appendf(&js, "%s%.10f", i ? "," : "",
                             weights[(size_t)c * n_assets + i]);
        if (!bad) bad = sb_append(&js, "]}");
    }
    if (!bad) bad = sb_append(&js, "]}");
    if (!bad)
        sovereign_audit_log_best_effort(st, "portfolio_optimize_multimodal",
                                        js.s);
    free(js.s);
}

static void portfolio_multimodal_pareto_audit_log_best_effort(
        FsqlState *st, const double *mu, const double *cov, int n_assets,
        int k, int n_restarts, int max_front, uint64_t seed, int n_found,
        const double *returns, const double *risks, const double *weights) {
    char hash_hex[65];
    if (sovereign_inputs_hash_hex(mu, cov, n_assets, hash_hex) != 0) return;

    SB js; memset(&js, 0, sizeof js);
    int bad = sb_appendf(&js,
        "{\"seed\":%llu,\"n_assets\":%d,\"k\":%d,\"n_restarts\":%d,"
        "\"max_front\":%d,\"n_found\":%d,\"inputs_hash\":\"%s\","
        "\"candidates\":[",
        (unsigned long long)seed, n_assets, k, n_restarts, max_front,
        n_found, hash_hex);
    for (int c = 0; c < n_found && !bad; c++) {
        bad = sb_appendf(&js, "%s{\"return\":%.10f,\"risk\":%.10f,\"weights\":[",
                         c ? "," : "", returns[c], risks[c]);
        for (int i = 0; i < n_assets && !bad; i++)
            bad = sb_appendf(&js, "%s%.10f", i ? "," : "",
                             weights[(size_t)c * n_assets + i]);
        if (!bad) bad = sb_append(&js, "]}");
    }
    if (!bad) bad = sb_append(&js, "]}");
    if (!bad)
        sovereign_audit_log_best_effort(
            st, "portfolio_optimize_multimodal_pareto", js.s);
    free(js.s);
}

/* fractal_optimize_portfolio(mu, cov, k [, seed [, use_obl
 * [, diffusion_mode]]]) -> TEXT JSON {"sharpe":X,"weights":[...]}. */
static void portfolio_fn(sqlite3_context *ctx, int argc,
                         sqlite3_value **argv) {
    FsqlState *st = sovereign_state(ctx);
    if (!st) return;

    char err[192];
    double *mu = NULL, *cov = NULL;
    int n_assets = 0, k = 0;
    if (portfolio_decode(ctx, argv[0], argv[1], argv[2],
                         &mu, &n_assets, &cov, &k) != 0)
        return;

    uint64_t seed = opt_seed(argc, argv, 3);
    int use_obl = opt_bool(argc, argv, 4);
    int diffusion_mode = opt_diffusion(argc, argv, 5, err, sizeof err);
    if (diffusion_mode < 0) {
        free(mu); free(cov);
        sqlite3_result_error(ctx, err, -1);
        return;
    }

    double *weights = (double *)malloc((size_t)n_assets * sizeof(double));
    if (!weights) {
        free(mu); free(cov);
        sqlite3_result_error_nomem(ctx);
        return;
    }
    double sharpe = 0.0;
    int rc = fsql_optimize_portfolio_ex(mu, cov, (size_t)n_assets,
                                        (size_t)k, seed, use_obl,
                                        diffusion_mode, weights, &sharpe);
    if (rc != FSQL_OK) {
        char buf[128];
        snprintf(buf, sizeof buf,
                 "fractalsql: fractal_optimize_portfolio rc=%d", rc);
        free(mu); free(cov); free(weights);
        sqlite3_result_error(ctx, buf, -1);
        return;
    }
    portfolio_audit_log_best_effort(st, mu, cov, n_assets, k, seed, sharpe,
                                    weights);

    SB out;
    memset(&out, 0, sizeof out);
    int bad = sb_appendf(&out, "{\"sharpe\":%.10f,\"weights\":[", sharpe);
    for (int i = 0; i < n_assets && !bad; i++)
        bad = sb_appendf(&out, "%s%.10f", i ? "," : "", weights[i]);
    if (!bad) bad = sb_append(&out, "]}");
    free(mu); free(cov); free(weights);
    if (bad) { free(out.s); sqlite3_result_error_nomem(ctx); return; }
    sb_result(ctx, &out);
}

/* fractal_optimize_portfolio_multimodal(mu, cov, k [, n_restarts
 * [, overlap_threshold [, quality_frac [, seed [, use_obl
 * [, diffusion_mode]]]]]]) -> TEXT JSON
 * {"candidates":[{"sharpe":X,"weights":[...]} ,...],"n_found":N}. */
static void portfolio_multimodal_fn(sqlite3_context *ctx, int argc,
                                    sqlite3_value **argv) {
    FsqlState *st = sovereign_state(ctx);
    if (!st) return;

    char err[192];
    double *mu = NULL, *cov = NULL;
    int n_assets = 0, k = 0;
    if (portfolio_decode(ctx, argv[0], argv[1], argv[2],
                         &mu, &n_assets, &cov, &k) != 0)
        return;

    int n_restarts = opt_int(argc, argv, 3, 8);
    double overlap_thr = opt_double(argc, argv, 4, 0.15);
    double quality_frac = opt_double(argc, argv, 5, 0.90);
    uint64_t seed = opt_seed(argc, argv, 6);
    int use_obl = opt_bool(argc, argv, 7);
    int diffusion_mode = opt_diffusion(argc, argv, 8, err, sizeof err);
    if (diffusion_mode < 0) {
        free(mu); free(cov);
        sqlite3_result_error(ctx, err, -1);
        return;
    }
    if (n_restarts <= 0 || n_restarts > 64) {
        free(mu); free(cov);
        sqlite3_result_error(ctx,
            "fractalsql: n_restarts must satisfy 1 <= n_restarts <= 64", -1);
        return;
    }

    double *weights = (double *)malloc((size_t)n_restarts *
                                       (size_t)n_assets * sizeof(double));
    double *sharpes = (double *)malloc((size_t)n_restarts * sizeof(double));
    if (!weights || !sharpes) {
        free(mu); free(cov); free(weights); free(sharpes);
        sqlite3_result_error_nomem(ctx);
        return;
    }
    int n_found = 0;
    /* Enterprise-gated. Prefer the extended (_ex) symbol when the core
     * has it; if it doesn't, a non-default use_obl/diffusion_mode
     * can't be honored (that specific error); otherwise fall back to
     * the plain symbol, which still serves default-args calls against
     * an older enterprise core that predates OBL/Lévy-flight support.
     * Demanding _ex unconditionally (as this used to) rejected that
     * older-core default-args case. */
    char enterr[256];
    if (fsql_enterprise_ensure(st, enterr, sizeof enterr) != 1) {
        free(mu); free(cov); free(weights); free(sharpes);
        sqlite3_result_error(ctx, enterr, -1);
        return;
    }
    int rc;
    if (st->ent.optimize_portfolio_multimodal_ex) {
        rc = st->ent.optimize_portfolio_multimodal_ex(
            mu, cov, (size_t)n_assets, (size_t)k, n_restarts,
            overlap_thr, quality_frac, seed, use_obl, diffusion_mode,
            weights, sharpes, &n_found);
    } else if (use_obl || diffusion_mode != 0) {
        free(mu); free(cov); free(weights); free(sharpes);
        sqlite3_result_error(ctx,
            "fractalsql: use_obl/diffusion_mode not available in this "
            "enterprise library (this enterprise core build predates "
            "portfolio OBL/Levy-flight support -- upgrade enterprise_lib, "
            "or omit use_obl/diffusion_mode)", -1);
        return;
    } else if (st->ent.optimize_portfolio_multimodal) {
        rc = st->ent.optimize_portfolio_multimodal(
            mu, cov, (size_t)n_assets, (size_t)k, n_restarts,
            overlap_thr, quality_frac, seed,
            weights, sharpes, &n_found);
    } else {
        free(mu); free(cov); free(weights); free(sharpes);
        sqlite3_result_error(ctx,
            "fractalsql: fractal_optimize_portfolio_multimodal not "
            "available in this enterprise library (this enterprise core "
            "build predates portfolio multimodal support -- upgrade "
            "enterprise_lib)", -1);
        return;
    }
    if (rc != FSQL_OK) {
        char buf[160];
        snprintf(buf, sizeof buf,
                 "fractalsql: fractal_optimize_portfolio_multimodal rc=%d",
                 rc);
        free(mu); free(cov); free(weights); free(sharpes);
        sqlite3_result_error(ctx, buf, -1);
        return;
    }

    /* Clamp against the allocated buffers: the vendor contract
     * (fractalsql_sql.h) guarantees 1..n_restarts, but a version-
     * mismatched or buggy core reporting more would index out of
     * bounds in the audit log and the result loop below. */
    if (n_found > n_restarts) n_found = n_restarts;
    if (n_found < 0)          n_found = 0;

    portfolio_multimodal_audit_log_best_effort(st, mu, cov, n_assets, k,
                                               n_restarts, seed, n_found,
                                               sharpes, weights);

    SB out;
    memset(&out, 0, sizeof out);
    int bad = sb_append(&out, "{\"candidates\":[");
    for (int c = 0; c < n_found && !bad; c++) {
        bad = sb_appendf(&out, "%s{\"sharpe\":%.10f,\"weights\":[",
                         c ? "," : "", sharpes[c]);
        for (int i = 0; i < n_assets && !bad; i++)
            bad = sb_appendf(&out, "%s%.10f", i ? "," : "",
                             weights[(size_t)c * n_assets + i]);
        if (!bad) bad = sb_append(&out, "]}");
    }
    if (!bad)
        bad = sb_appendf(&out, "],\"n_found\":%d}", n_found);
    free(mu); free(cov); free(weights); free(sharpes);
    if (bad) { free(out.s); sqlite3_result_error_nomem(ctx); return; }
    sb_result(ctx, &out);
}

/* fractal_optimize_portfolio_multimodal_pareto(mu, cov, k
 * [, n_restarts [, max_front [, seed [, use_obl
 * [, diffusion_mode]]]]]]) -> TEXT JSON
 * {"candidates":[{"return":R,"risk":K,"sharpe":S,"weights":[...]}
 * ,...],"n_found":N}. */
static void portfolio_pareto_fn(sqlite3_context *ctx, int argc,
                                sqlite3_value **argv) {
    FsqlState *st = sovereign_state(ctx);
    if (!st) return;

    char err[192];
    double *mu = NULL, *cov = NULL;
    int n_assets = 0, k = 0;
    if (portfolio_decode(ctx, argv[0], argv[1], argv[2],
                         &mu, &n_assets, &cov, &k) != 0)
        return;

    int n_restarts = opt_int(argc, argv, 3, 8);
    int max_front = opt_int(argc, argv, 4, 8);
    uint64_t seed = opt_seed(argc, argv, 5);
    int use_obl = opt_bool(argc, argv, 6);
    int diffusion_mode = opt_diffusion(argc, argv, 7, err, sizeof err);
    if (diffusion_mode < 0) {
        free(mu); free(cov);
        sqlite3_result_error(ctx, err, -1);
        return;
    }
    if (n_restarts <= 0 || n_restarts > 64) {
        free(mu); free(cov);
        sqlite3_result_error(ctx,
            "fractalsql: n_restarts must satisfy 1 <= n_restarts <= 64", -1);
        return;
    }
    if (max_front <= 0 || max_front > n_restarts) {
        free(mu); free(cov);
        char buf[128];
        snprintf(buf, sizeof buf,
                 "fractalsql: max_front must satisfy 1 <= max_front <= "
                 "n_restarts (%d)", n_restarts);
        sqlite3_result_error(ctx, buf, -1);
        return;
    }

    double *weights = (double *)malloc((size_t)max_front *
                                       (size_t)n_assets * sizeof(double));
    double *returns = (double *)malloc((size_t)max_front * sizeof(double));
    double *risks = (double *)malloc((size_t)max_front * sizeof(double));
    if (!weights || !returns || !risks) {
        free(mu); free(cov); free(weights); free(returns); free(risks);
        sqlite3_result_error_nomem(ctx);
        return;
    }
    int n_found = 0;
    /* Enterprise-gated symbol, same gate shape as the scalar-Sharpe
     * multimodal variant above (fsql_enterprise.c has the link proof). */
    char enterr[256];
    if (fsql_enterprise_ensure(st, enterr, sizeof enterr) != 1) {
        free(mu); free(cov); free(weights); free(returns); free(risks);
        sqlite3_result_error(ctx, enterr, -1);
        return;
    }
    if (!st->ent.optimize_portfolio_multimodal_pareto) {
        free(mu); free(cov); free(weights); free(returns); free(risks);
        sqlite3_result_error(ctx,
            "fractalsql: fractal_optimize_portfolio_multimodal_pareto "
            "not available in this enterprise library (upgrade "
            "enterprise_lib)", -1);
        return;
    }
    int rc = st->ent.optimize_portfolio_multimodal_pareto(
        mu, cov, (size_t)n_assets, (size_t)k, n_restarts, max_front,
        seed, use_obl, diffusion_mode, weights, returns, risks, &n_found);
    if (rc != FSQL_OK) {
        char buf[176];
        snprintf(buf, sizeof buf,
                 "fractalsql: fractal_optimize_portfolio_multimodal_pareto "
                 "rc=%d", rc);
        free(mu); free(cov); free(weights); free(returns); free(risks);
        sqlite3_result_error(ctx, buf, -1);
        return;
    }
    /* Same clamp rationale as the scalar-Sharpe variant above: trust
     * the allocated max_front, not the core's reported count. */
    if (n_found > max_front) n_found = max_front;
    if (n_found < 0)         n_found = 0;

    portfolio_multimodal_pareto_audit_log_best_effort(
        st, mu, cov, n_assets, k, n_restarts, max_front, seed, n_found,
        returns, risks, weights);

    SB out;
    memset(&out, 0, sizeof out);
    int bad = sb_append(&out, "{\"candidates\":[");
    for (int c = 0; c < n_found && !bad; c++) {
        double ret = returns[c], risk = risks[c];
        bad = sb_appendf(&out,
                         "%s{\"return\":%.10f,\"risk\":%.10f,"
                         "\"sharpe\":%.10f,\"weights\":[",
                         c ? "," : "", ret, risk,
                         risk != 0.0 ? ret / risk : 0.0);
        for (int i = 0; i < n_assets && !bad; i++)
            bad = sb_appendf(&out, "%s%.10f", i ? "," : "",
                             weights[(size_t)c * n_assets + i]);
        if (!bad) bad = sb_append(&out, "]}");
    }
    if (!bad)
        bad = sb_appendf(&out, "],\"n_found\":%d}", n_found);
    free(mu); free(cov); free(weights); free(returns); free(risks);
    if (bad) { free(out.s); sqlite3_result_error_nomem(ctx); return; }
    sb_result(ctx, &out);
}

/* ------------------------------------------------------------------
 * Domain-specific geometric/topological metrics
 * ------------------------------------------------------------------ */

/* fractal_vascular_network(node_coords, edges, edge_arc_length)
 * -> TEXT JSON {mean_tortuosity, branch_density, fractal_dimension}. */
static void vascular_fn(sqlite3_context *ctx, int argc,
                        sqlite3_value **argv) {
    (void)argc;
    if (any_arg_null(3, argv)) { sqlite3_result_null(ctx); return; }

    double *node_coords = NULL;
    int nc_n = 0;
    size_t *edges = NULL;
    int e_n = 0;
    double *arc = NULL;
    int al_n = 0;
    char err[192] = "";   /* decode_series failures below never write it */

    if (decode_series(argv[0], &node_coords, &nc_n) != 0 ||
        decode_indices(argv[1], &edges, &e_n, err, sizeof err) != 0 ||
        decode_series(argv[2], &arc, &al_n) != 0) {
        free(node_coords); free(edges); free(arc);
        sqlite3_result_error(ctx, err[0] ? err :
            "fractalsql: malformed node_coords/edges/edge_arc_length",
            -1);
        return;
    }

    if (nc_n % 3 != 0) {
        free(node_coords); free(edges); free(arc);
        sqlite3_result_error(ctx,
            "fractalsql: node_coords length must be a multiple of 3", -1);
        return;
    }
    if (e_n % 2 != 0) {
        free(node_coords); free(edges); free(arc);
        sqlite3_result_error(ctx,
            "fractalsql: edges length must be a multiple of 2", -1);
        return;
    }
    if (al_n != e_n / 2) {
        char buf[128];
        snprintf(buf, sizeof buf,
                 "fractalsql: edge_arc_length length (%d) must equal "
                 "edges length / 2 (%d)", al_n, e_n / 2);
        free(node_coords); free(edges); free(arc);
        sqlite3_result_error(ctx, buf, -1);
        return;
    }

    double mean_tortuosity = 0.0, branch_density = 0.0, fdim = 0.0;
    int rc = fsql_vascular_network(node_coords, (size_t)(nc_n / 3),
                                   edges, arc, (size_t)(e_n / 2),
                                   &mean_tortuosity, &branch_density,
                                   &fdim);
    free(node_coords); free(edges); free(arc);
    if (rc != FSQL_OK) {
        char buf[128];
        snprintf(buf, sizeof buf,
                 "fractalsql: fractal_vascular_network rc=%d", rc);
        sqlite3_result_error(ctx, buf, -1);
        return;
    }

    char buf[320];
    result_jsonf(ctx, buf, sizeof buf,
                 "{\"mean_tortuosity\":%.10f,\"branch_density\":%.10f,"
                 "\"fractal_dimension\":%.10f}",
                 mean_tortuosity, branch_density, fdim);
}

/* fractal_cortical_folding(vertices, faces) -> TEXT JSON
 * {mesh_area, hull_area, gyrification_index}. */
static void cortical_fn(sqlite3_context *ctx, int argc,
                        sqlite3_value **argv) {
    (void)argc;
    if (any_arg_null(2, argv)) { sqlite3_result_null(ctx); return; }

    double *vertices = NULL;
    int v_n = 0;
    size_t *faces = NULL;
    int f_n = 0;
    char err[192] = "";   /* decode_series failures below never write it */

    if (decode_series(argv[0], &vertices, &v_n) != 0 ||
        decode_indices(argv[1], &faces, &f_n, err, sizeof err) != 0) {
        free(vertices); free(faces);
        sqlite3_result_error(ctx, err[0] ? err :
            "fractalsql: malformed vertices/faces", -1);
        return;
    }

    if (v_n % 3 != 0) {
        free(vertices); free(faces);
        sqlite3_result_error(ctx,
            "fractalsql: vertices length must be a multiple of 3", -1);
        return;
    }
    if (f_n % 3 != 0) {
        free(vertices); free(faces);
        sqlite3_result_error(ctx,
            "fractalsql: faces length must be a multiple of 3", -1);
        return;
    }

    double mesh_area = 0.0, hull_area = 0.0, gi = 0.0;
    int rc = fsql_cortical_folding(vertices, (size_t)(v_n / 3),
                                   faces, (size_t)(f_n / 3),
                                   &mesh_area, &hull_area, &gi);
    free(vertices); free(faces);
    if (rc != FSQL_OK) {
        char buf[160];
        snprintf(buf, sizeof buf,
                 "fractalsql: fractal_cortical_folding rc=%d "
                 "(need >= 4 non-coplanar vertices)", rc);
        sqlite3_result_error(ctx, buf, -1);
        return;
    }

    char buf[320];
    result_jsonf(ctx, buf, sizeof buf,
                 "{\"mesh_area\":%.10f,\"hull_area\":%.10f,"
                 "\"gyrification_index\":%.10f}",
                 mesh_area, hull_area, gi);
}

/* fractal_nerve_plexus_metric(node_coords, dim, edges) -> TEXT JSON
 * {fiber_length_density, branch_density, fractal_dimension}. */
static void nerve_fn(sqlite3_context *ctx, int argc,
                     sqlite3_value **argv) {
    (void)argc;
    if (any_arg_null(3, argv)) { sqlite3_result_null(ctx); return; }

    double *node_coords = NULL;
    int nc_n = 0;
    size_t *edges = NULL;
    int e_n = 0;
    char err[192] = "";   /* decode_series failures below never write it */

    if (decode_series(argv[0], &node_coords, &nc_n) != 0 ||
        decode_indices(argv[2], &edges, &e_n, err, sizeof err) != 0) {
        free(node_coords); free(edges);
        sqlite3_result_error(ctx, err[0] ? err :
            "fractalsql: malformed node_coords/edges", -1);
        return;
    }

    int dim = sqlite3_value_int(argv[1]);
    if (dim <= 0 || nc_n % dim != 0) {
        char buf[128];
        snprintf(buf, sizeof buf,
                 "fractalsql: node_coords length (%d) must be a positive "
                 "multiple of dim (%d)", nc_n, dim);
        free(node_coords); free(edges);
        sqlite3_result_error(ctx, buf, -1);
        return;
    }
    if (e_n % 2 != 0) {
        free(node_coords); free(edges);
        sqlite3_result_error(ctx,
            "fractalsql: edges length must be a multiple of 2", -1);
        return;
    }

    double fld = 0.0, branch_density = 0.0, fdim = 0.0;
    int rc = fsql_nerve_plexus_metric(node_coords, (size_t)(nc_n / dim),
                                      (size_t)dim, edges,
                                      (size_t)(e_n / 2),
                                      &fld, &branch_density, &fdim);
    free(node_coords); free(edges);
    if (rc != FSQL_OK) {
        char buf[144];
        snprintf(buf, sizeof buf,
                 "fractalsql: fractal_nerve_plexus_metric rc=%d", rc);
        sqlite3_result_error(ctx, buf, -1);
        return;
    }

    char buf[320];
    result_jsonf(ctx, buf, sizeof buf,
                 "{\"fiber_length_density\":%.10f,\"branch_density\":%.10f,"
                 "\"fractal_dimension\":%.10f}",
                 fld, branch_density, fdim);
}

/* fractal_morphological_complexity(points, dim) -> TEXT JSON
 * {dimension, lacunarity}. */
static void morphology_fn(sqlite3_context *ctx, int argc,
                          sqlite3_value **argv) {
    (void)argc;
    if (any_arg_null(2, argv)) { sqlite3_result_null(ctx); return; }

    double *points = NULL;
    int p_n = 0;
    if (decode_series(argv[0], &points, &p_n) != 0) {
        sqlite3_result_error(ctx,
            "fractalsql: malformed points (expect CSV/JSON text or "
            "float32 BLOB)", -1);
        return;
    }

    int dim = sqlite3_value_int(argv[1]);
    if (dim <= 0 || p_n % dim != 0) {
        char buf[128];
        snprintf(buf, sizeof buf,
                 "fractalsql: points length (%d) must be a positive "
                 "multiple of dim (%d)", p_n, dim);
        free(points);
        sqlite3_result_error(ctx, buf, -1);
        return;
    }

    double dimension = 0.0, lacunarity = 0.0;
    int rc = fsql_morphological_complexity(points, (size_t)(p_n / dim),
                                           (size_t)dim, &dimension,
                                           &lacunarity);
    free(points);
    if (rc != FSQL_OK) {
        char buf[176];
        snprintf(buf, sizeof buf,
                 "fractalsql: fractal_morphological_complexity rc=%d "
                 "(need >= 8 points, non-degenerate bounding box)", rc);
        sqlite3_result_error(ctx, buf, -1);
        return;
    }

    char buf[256];
    result_jsonf(ctx, buf, sizeof buf,
                 "{\"dimension\":%.10f,\"lacunarity\":%.10f}",
                 dimension, lacunarity);
}

/* ------------------------------------------------------------------
 * Diversify / Repulsion controls
 * ------------------------------------------------------------------ */

/* fractal_diversify_enable() — opt the connection's shared ctx into
 * the divergence monitor + repulsive post-filter. */
static void diversify_enable_fn(sqlite3_context *ctx, int argc,
                                sqlite3_value **argv) {
    (void)argc; (void)argv;
    FsqlState *st = sovereign_state(ctx);
    if (!st) return;
    int rc = fsql_diversify_enable(st->ctx);
    if (rc != FSQL_OK) {
        char buf[192];
        snprintf(buf, sizeof buf,
                 "fractalsql: fsql_diversify_enable rc=%d: %s",
                 rc, fsql_last_error(st->ctx));
        sqlite3_result_error(ctx, buf, -1);
        return;
    }
    sqlite3_result_null(ctx);
}

static void diversify_disable_fn(sqlite3_context *ctx, int argc,
                                 sqlite3_value **argv) {
    (void)argc; (void)argv;
    FsqlState *st = sovereign_state(ctx);
    if (!st) return;
    int rc = fsql_diversify_disable(st->ctx);
    if (rc != FSQL_OK) {
        char buf[192];
        snprintf(buf, sizeof buf,
                 "fractalsql: fsql_diversify_disable rc=%d: %s",
                 rc, fsql_last_error(st->ctx));
        sqlite3_result_error(ctx, buf, -1);
        return;
    }
    sqlite3_result_null(ctx);
}

/* Targeted JSON extractors — the same idea as the entry TU's
 * json_get_int, plus a double variant. Only flat scalar fields of one
 * flat object are ever read here; no nested-object or array support is
 * attempted (the params document has none). */

static const char *json_value_ptr(const char *s, const char *key) {
    if (!s || !*s) return NULL;
    char needle[64];
    snprintf(needle, sizeof needle, "\"%s\"", key);
    const char *p = strstr(s, needle);
    if (!p) return NULL;
    p = strchr(p, ':');
    if (!p) return NULL;
    p++;
    while (*p == ' ' || *p == '\t') p++;
    return p;
}

static int json_get_int(const char *s, const char *key, int *found) {
    *found = 0;
    const char *p = json_value_ptr(s, key);
    if (!p) return 0;
    char *end;
    long v = strtol(p, &end, 10);
    if (end == p) return 0;
    *found = 1;
    return (int)v;
}

static double json_get_double(const char *s, const char *key, int *found) {
    *found = 0;
    const char *p = json_value_ptr(s, key);
    if (!p) return 0.0;
    char *end;
    double v = strtod(p, &end);
    if (end == p) return 0.0;
    *found = 1;
    return v;
}

/* fractal_diversify_set_params(params_json) — one flat JSON object
 * with any subset of {window_n, stall_threshold, repulsion_sigma,
 * repulsion_weight, max_shadows_considered, tail_buffer_cap}.
 *
 * The core's current value is read first and only fields present in
 * the JSON are overridden. On a fresh connection the core's values
 * are the documented defaults (window_n 5, stall_threshold 0.15,
 * repulsion_sigma f(dim), max_shadows_considered 64,
 * tail_buffer_cap 256), so absent fields always resolve to
 * defaults-or-earlier-override — never reset. */
static void diversify_set_params_fn(sqlite3_context *ctx, int argc,
                                    sqlite3_value **argv) {
    (void)argc;
    FsqlState *st = sovereign_state(ctx);
    if (!st) return;

    /* A NULL/absent params document changes nothing: every field left
     * NULL keeps the core's current value. */
    if (sqlite3_value_type(argv[0]) == SQLITE_NULL) {
        sqlite3_result_null(ctx);
        return;
    }
    if (sqlite3_value_type(argv[0]) != SQLITE_TEXT) {
        sqlite3_result_error(ctx,
            "fractalsql: params must be a JSON object text", -1);
        return;
    }
    const char *s = (const char *)sqlite3_value_text(argv[0]);
    if (!s) { sqlite3_result_error_nomem(ctx); return; }

    fsql_diversify_params_t p;
    int rc = fsql_diversify_get_params(st->ctx, &p);
    if (rc != FSQL_OK) {
        char buf[192];
        snprintf(buf, sizeof buf,
                 "fractalsql: fsql_diversify_get_params rc=%d: %s",
                 rc, fsql_last_error(st->ctx));
        sqlite3_result_error(ctx, buf, -1);
        return;
    }

    int found = 0;
    int v = json_get_int(s, "window_n", &found);
    if (found) p.window_n = (uint32_t)v;
    v = json_get_int(s, "max_shadows_considered", &found);
    if (found) p.max_shadows_considered = (uint32_t)v;
    v = json_get_int(s, "tail_buffer_cap", &found);
    if (found) p.tail_buffer_cap = (uint32_t)v;

    double d = json_get_double(s, "stall_threshold", &found);
    if (found) p.stall_threshold = d;
    d = json_get_double(s, "repulsion_sigma", &found);
    if (found) p.repulsion_sigma = d;
    d = json_get_double(s, "repulsion_weight", &found);
    if (found) p.repulsion_weight = d;

    rc = fsql_diversify_set_params(st->ctx, &p);
    if (rc != FSQL_OK) {
        char buf[192];
        snprintf(buf, sizeof buf,
                 "fractalsql: fsql_diversify_set_params rc=%d: %s",
                 rc, fsql_last_error(st->ctx));
        sqlite3_result_error(ctx, buf, -1);
        return;
    }
    sqlite3_result_null(ctx);
}

/* fractal_diversify_current_dq() — most recent D_q, or NULL when NaN
 * (no query run yet / diversify disabled). SQLite has no NaN, so
 * NULL is the honest spelling of that internal NaN. */
static void diversify_dq_fn(sqlite3_context *ctx, int argc,
                            sqlite3_value **argv) {
    (void)argc; (void)argv;
    FsqlState *st = sovereign_state(ctx);
    if (!st) return;
    double dq = fsql_diversify_current_dq(st->ctx);
    if (isnan(dq)) { sqlite3_result_null(ctx); return; }
    sqlite3_result_double(ctx, dq);
}

/* fractal_diversify_overhead_p99_us() — rolling p99 of core's own
 * per-query diversify overhead; NULL while NaN (buffer not full /
 * diversify disabled). */
static void diversify_overhead_fn(sqlite3_context *ctx, int argc,
                                  sqlite3_value **argv) {
    (void)argc; (void)argv;
    FsqlState *st = sovereign_state(ctx);
    if (!st) return;
    double us = fsql_diversify_overhead_p99_us(st->ctx);
    if (isnan(us)) { sqlite3_result_null(ctx); return; }
    sqlite3_result_double(ctx, us);
}

/* ------------------------------------------------------------------
 * Feedback / engagement
 * ------------------------------------------------------------------ */

/* kind text -> fsql_engagement_kind_t. Returns -1 with err filled in. */
static int parse_engagement_kind(sqlite3_value *v, char *err,
                                 size_t err_cap) {
    const char *kind = (const char *)sqlite3_value_text(v);
    if (kind) {
        if (strcmp(kind, "dwell") == 0)    return FSQL_ENGAGE_DWELL;
        if (strcmp(kind, "positive") == 0) return FSQL_ENGAGE_POSITIVE;
        if (strcmp(kind, "negative") == 0) return FSQL_ENGAGE_NEGATIVE;
    }
    snprintf(err, err_cap,
             "fractalsql: kind must be one of 'dwell', 'positive', "
             "'negative' (got '%s')", kind ? kind : "NULL");
    return -1;
}

/* fractal_feedback_report(result_handle, kind [, dwell_ms]).
 * handle: INTEGER (int64, >= 0) or TEXT (strtoull — full uint64 range,
 * same reasoning as the portfolio seed). kind: 'dwell'|'positive'|
 * 'negative'. dwell_ms: DEFAULT NULL -> 0. */
static void feedback_report_fn(sqlite3_context *ctx, int argc,
                               sqlite3_value **argv) {
    FsqlState *st = sovereign_state(ctx);
    if (!st) return;

    char err[192];

    uint64_t handle = 0;
    if (sqlite3_value_type(argv[0]) != SQLITE_NULL) {
        if (sqlite3_value_type(argv[0]) == SQLITE_TEXT) {
            const char *s = (const char *)sqlite3_value_text(argv[0]);
            if (s && s[0] == '-') {
                sqlite3_result_error(ctx,
                    "fractalsql: result_handle must be >= 0", -1);
                return;
            }
            handle = strtoull(s ? s : "0", NULL, 10);
        } else {
            int64_t h = sqlite3_value_int64(argv[0]);
            if (h < 0) {
                sqlite3_result_error(ctx,
                    "fractalsql: result_handle must be >= 0", -1);
                return;
            }
            handle = (uint64_t)h;
        }
    }

    int kind = parse_engagement_kind(argv[1], err, sizeof err);
    if (kind < 0) {
        sqlite3_result_error(ctx, err, -1);
        return;
    }

    uint32_t dwell_ms = 0;
    if (argc > 2 && sqlite3_value_type(argv[2]) != SQLITE_NULL)
        dwell_ms = (uint32_t)sqlite3_value_int(argv[2]);

    int rc = fsql_feedback_report(st->ctx, handle,
                                  (fsql_engagement_kind_t)kind, dwell_ms);
    if (rc != FSQL_OK) {
        snprintf(err, sizeof err,
                 "fractalsql: fsql_feedback_report rc=%d: %s",
                 rc, fsql_last_error(st->ctx));
        sqlite3_result_error(ctx, err, -1);
        return;
    }
    sqlite3_result_null(ctx);
}

/* fractal_isolate_background(result_handle): convenience wrapper for a
 * negative-engagement feedback report, no dwell. Inert until
 * fractal_diversify_enable() has been called on this session;
 * documented, not silently misleading. */
static void isolate_background_fn(sqlite3_context *ctx, int argc,
                                  sqlite3_value **argv) {
    (void)argc;
    FsqlState *st = sovereign_state(ctx);
    if (!st) return;
    if (sqlite3_value_type(argv[0]) == SQLITE_NULL) {
        sqlite3_result_null(ctx);
        return;
    }

    uint64_t handle = 0;
    if (sqlite3_value_type(argv[0]) == SQLITE_TEXT) {
        const char *s = (const char *)sqlite3_value_text(argv[0]);
        if (s && s[0] == '-') {
            sqlite3_result_error(ctx,
                "fractalsql: result_handle must be >= 0", -1);
            return;
        }
        handle = strtoull(s ? s : "0", NULL, 10);
    } else {
        int64_t h = sqlite3_value_int64(argv[0]);
        if (h < 0) {
            sqlite3_result_error(ctx,
                "fractalsql: result_handle must be >= 0", -1);
            return;
        }
        handle = (uint64_t)h;
    }

    int rc = fsql_feedback_report(st->ctx, handle,
                                  FSQL_ENGAGE_NEGATIVE, 0);
    if (rc != FSQL_OK) {
        char err[192];
        snprintf(err, sizeof err,
                 "fractalsql: fsql_feedback_report rc=%d: %s",
                 rc, fsql_last_error(st->ctx));
        sqlite3_result_error(ctx, err, -1);
        return;
    }
    sqlite3_result_null(ctx);
}

/* ------------------------------------------------------------------
 * Registration
 * ------------------------------------------------------------------ */

static int reg_fn(sqlite3 *db, const char *name, int narg, int flags,
                  FsqlState *st, void *fn) {
    return sqlite3_create_function_v2(
        db, name, narg, flags, st,
        (void (*)(sqlite3_context *, int, sqlite3_value **))fn,
        NULL, NULL, NULL);
}

int fsql_sovereign_register(sqlite3 *db, FsqlState *st) {
    /* Pure math over caller-supplied data: deterministic + innocuous.
     * The portfolio family is stochastic (RNG seeded from SQL input)
     * and the diversify/feedback family mutates shared ctx state, so
     * both drop DETERMINISTIC while staying innocuous. */
    const int f_pure  = SQLITE_UTF8 | SQLITE_DETERMINISTIC | SQLITE_INNOCUOUS;
    const int f_run   = SQLITE_UTF8 | SQLITE_INNOCUOUS;
    int rc;

    struct { const char *name; int narg; void *fn; } pure[] = {
        { "fractal_dimension_dfa",             1, (void *)dim_dfa_fn       },
        { "fractal_dimension_drift",           2, (void *)dim_drift_fn     },
        { "fractal_dimension_boxcount",        2, (void *)dim_boxcount_fn  },
        { "fractal_vascular_network",          3, (void *)vascular_fn      },
        { "fractal_cortical_folding",          2, (void *)cortical_fn      },
        { "fractal_nerve_plexus_metric",       3, (void *)nerve_fn         },
        { "fractal_morphological_complexity",  2, (void *)morphology_fn    },
    };
    for (size_t i = 0; i < sizeof(pure) / sizeof(pure[0]); i++) {
        rc = reg_fn(db, pure[i].name, pure[i].narg, f_pure, st, pure[i].fn);
        if (rc != SQLITE_OK) return rc;
    }

    /* Portfolio family: same name at every supported arity; omitted
     * trailing arguments take the documented DEFAULT values inside
     * the shared bodies. */
    static const int portfolio_arities[]   = { 4, 5, 6 };
    static const int multimodal_arities[]  = { 4, 5, 6, 7, 8, 9 };
    static const int pareto_arities[]      = { 4, 5, 6, 7, 8 };

    for (size_t i = 0; i < sizeof(portfolio_arities) / sizeof(int); i++) {
        rc = reg_fn(db, "fractal_optimize_portfolio", portfolio_arities[i],
                    f_run, st, (void *)portfolio_fn);
        if (rc != SQLITE_OK) return rc;
    }
    for (size_t i = 0; i < sizeof(multimodal_arities) / sizeof(int); i++) {
        rc = reg_fn(db, "fractal_optimize_portfolio_multimodal",
                    multimodal_arities[i], f_run, st,
                    (void *)portfolio_multimodal_fn);
        if (rc != SQLITE_OK) return rc;
    }
    for (size_t i = 0; i < sizeof(pareto_arities) / sizeof(int); i++) {
        rc = reg_fn(db, "fractal_optimize_portfolio_multimodal_pareto",
                    pareto_arities[i], f_run, st,
                    (void *)portfolio_pareto_fn);
        if (rc != SQLITE_OK) return rc;
    }

    struct { const char *name; int narg; void *fn; } stateful[] = {
        { "fractal_diversify_enable",           0, (void *)diversify_enable_fn    },
        { "fractal_diversify_disable",          0, (void *)diversify_disable_fn   },
        { "fractal_diversify_set_params",       1, (void *)diversify_set_params_fn},
        { "fractal_diversify_current_dq",       0, (void *)diversify_dq_fn        },
        { "fractal_diversify_overhead_p99_us",  0, (void *)diversify_overhead_fn  },
        { "fractal_feedback_report",            2, (void *)feedback_report_fn     },
        { "fractal_feedback_report",            3, (void *)feedback_report_fn     },
        { "fractal_isolate_background",         1, (void *)isolate_background_fn  },
    };
    for (size_t i = 0; i < sizeof(stateful) / sizeof(stateful[0]); i++) {
        rc = reg_fn(db, stateful[i].name, stateful[i].narg, f_run, st,
                    stateful[i].fn);
        if (rc != SQLITE_OK) return rc;
    }

    return SQLITE_OK;
}