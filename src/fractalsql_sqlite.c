/* src/fractalsql_sqlite.c
 *
 * fractalsql-sqlite v2.0 Community: SQLite loadable extension driving
 * the FractalSQL community-edition pure-C search core.
 *
 * SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
 * SPDX-FileCopyrightText: 2014 Hamid Salimi (SFS algorithmic lineage)
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * Entry point: `sqlite3_fractalsql_init` (matches `.load fractalsql`).
 *
 * Registered here (smoke + search surface):
 *   fractalsql_edition() -> TEXT      "Community"
 *   fractalsql_version() -> TEXT      "2.0.0"
 *   fractal_search(vector, query) -> DOUBLE
 *   fractal_search_explore(emb, query [, params]) -> TEXT (aggregate, Scout)
 * Remaining modules register from their own TUs (see
 * fsql_sqlite_internal.h for the TU map).
 *
 * Input shapes for vector / query:
 *   TEXT CSV or bracketed JSON : '1.0,0.5,-0.25'  or  '[1.0,0.5,-0.25]'
 *   BLOB                       : packed little-endian float32
 *
 * Per-row hot path
 *   `fractal_search` is invoked once per candidate row. SFS itself
 *   only depends on the query, not the row vector, so we run SFS
 *   ONCE per distinct query (memoized by FNV hash of the query
 *   bytes) and reuse the refined best_point for every row in the
 *   scan. Per-row cost is one cosine distance over arena memory.
 *
 * Threading
 *   Declared SQLITE_INNOCUOUS (+ SQLITE_DETERMINISTIC only on pure
 *   math functions). SQLite's default SQLITE_THREADSAFE=1 serializes
 *   calls against a connection, so per-connection state needs no
 *   extra locking.
 *
 * Vendored pure-C core
 *   include/fractalsql.h + include/fractalsql_sql.h + the per-platform
 *   libfractalsql-community-{minimal,sovereign}-c.a drop are statically
 *   linked into the loadable extension. No LuaJIT runtime dep.
 */

#include <sqlite3ext.h>
SQLITE_EXTENSION_INIT1

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

#include "fsql_sqlite_internal.h"
#include "fractalsql_parse.h"

/* -------------------------------------------------------------------
 * State lifecycle.
 * ------------------------------------------------------------------- */

FsqlState *fsql_state_create(sqlite3 *db, char **pzErrMsg) {
    FsqlState *st = (FsqlState *)calloc(1, sizeof(FsqlState));
    if (!st) {
        if (pzErrMsg)
            *pzErrMsg = sqlite3_mprintf("fractalsql: state alloc failed (OOM?)");
        return NULL;
    }
    st->db = db;

#ifdef FSQL_SQLITE_SOVEREIGN
    /* Sovereign build: ledger storage VFS (fractalsql_ledger table on
     * the same connection) wired in before ctx construction, since
     * fsql_new_sovereign copies the VFS struct by value. No reasoning
     * VFS at construction; plugins attach lazily via
     * fsql_load_reasoning. */
    if (fsql_ledger_vfs_setup(st) != 0) {
        if (pzErrMsg)
            *pzErrMsg = sqlite3_mprintf("fractalsql: ledger VFS setup failed");
        free(st);
        return NULL;
    }
    st->ctx = fsql_new_sovereign(&st->storage_vfs, NULL);
#else
    /* Minimal build: fsql_new_sovereign is not exported by the
     * archive. An unresolved symbol would break dlopen on musl
     * (eager binding) and error at the call site on glibc, so the
     * constructor is selected at compile time. */
    st->ctx = fsql_new_minimal();
#endif
    if (!st->ctx) {
        if (pzErrMsg)
            *pzErrMsg = sqlite3_mprintf(
                "fractalsql: core context allocation failed (OOM?)");
        free(st);
        return NULL;
    }
    return st;
}

void fsql_state_destroy(void *p) {
    FsqlState *st = (FsqlState *)p;
    if (!st) return;
    if (st->ctx) fsql_free(st->ctx);
    free(st->cfg.reasoning_plugin);
    free(st->cfg.http_url);
    free(st->cfg.http_token);
    free(st->cfg.http_model);
    free(st->cfg.http_embed_url);
    free(st->cfg.http_embed_model);
    free(st->cfg.http_think);
    free(st->cfg.http_think_provider);
    free(st->cfg.http_native_url);
    free(st->cfg.t2s_allowed_statements);
    free(st->cfg.enterprise_lib);
    free(st->cfg.enterprise_ledger_key);
    free(st->cfg.response_mode);
    free(st->attached_plugin);   /* vestigial; see fsql_sqlite_internal.h */
    for (int i = 0; i < FSQL_REASONING_TIER_COUNT; i++) {
        free(st->reasoning_attach[i].plugin_path);
        if (st->reasoning_ctx[i]) fsql_free(st->reasoning_ctx[i]);
    }
    /* ledger_ctx: a single block whose slot payloads are separate
     * allocations — fsql_ledger_teardown walks and frees both. It runs
     * after fsql_free(st->ctx) above because that call may re-enter
     * seal_ledger with the ctx still alive. Sovereign builds only: a
     * minimal link compiles the ledger TU out, and with it the only
     * code that ever allocates ledger_ctx, so there is nothing to
     * walk here. */
#ifdef FSQL_SQLITE_SOVEREIGN
    fsql_ledger_teardown(st);
#endif
    free(st);
}

/* -------------------------------------------------------------------
 * Input decoding (unchanged behavior from the 1.x bridge).
 * ------------------------------------------------------------------- */

int fsql_parse_text_vector(const char *src, int slen, double *out, int cap) {
    if (slen <= 0) return -1;
    if ((size_t)slen > FSQL_MAX_INPUT_BYTES) return -1;
    char *buf = (char *)malloc((size_t)slen + 1);
    if (!buf) return -1;
    memcpy(buf, src, (size_t)slen);
    buf[slen] = '\0';

    char *p = buf;
    int n = 0;
    while (*p && n < cap) {
        while (*p == ' ' || *p == '\t' || *p == ',' ||
               *p == '[' || *p == ']' || *p == '\n' || *p == '\r')
            p++;
        if (!*p) break;
        char *end;
        errno = 0;
        double d = strtod(p, &end);
        if (end == p || errno == ERANGE) { free(buf); return -1; }
        out[n++] = d;
        p = end;
    }
    free(buf);
    return n;
}

int fsql_parse_blob_vector(const void *src, int nbytes, double *out, int cap) {
    if (nbytes <= 0 || (nbytes & 3) != 0) return -1;
    int count = nbytes / 4;
    if (count > cap) return -1;
    const uint8_t *bytes = (const uint8_t *)src;
    for (int i = 0; i < count; i++) {
        float f;
        memcpy(&f, bytes + i * 4, 4);
        out[i] = (double)f;
    }
    return count;
}

int fsql_parse_value_to_doubles(sqlite3_value *v, double *out, int cap) {
    switch (sqlite3_value_type(v)) {
    case SQLITE_BLOB:
        return fsql_parse_blob_vector(
            sqlite3_value_blob(v), sqlite3_value_bytes(v), out, cap);
    case SQLITE_TEXT:
        return fsql_parse_text_vector(
            (const char *)sqlite3_value_text(v),
            sqlite3_value_bytes(v), out, cap);
    default:
        return -1;
    }
}

/* -------------------------------------------------------------------
 * SQL functions — smoke surface.
 * ------------------------------------------------------------------- */

static void edition_fn(sqlite3_context *ctx, int argc, sqlite3_value **argv) {
    (void)argc; (void)argv;
    sqlite3_result_text(ctx, FSQL_SQLITE_EDITION_STR, -1, SQLITE_STATIC);
}

static void version_fn(sqlite3_context *ctx, int argc, sqlite3_value **argv) {
    (void)argc; (void)argv;
    sqlite3_result_text(ctx, FSQL_SQLITE_VERSION_STR, -1, SQLITE_STATIC);
}

/* -------------------------------------------------------------------
 * fractal_search — Sniper mode, memoized per distinct query.
 * ------------------------------------------------------------------- */

static uint64_t fnv1a_64(const void *bytes, size_t n) {
    const uint8_t *p = (const uint8_t *)bytes;
    uint64_t h = 0xcbf29ce484222325ULL;
    for (size_t i = 0; i < n; i++) {
        h ^= p[i];
        h *= 0x100000001b3ULL;
    }
    return h;
}

static double cosine_distance(const double *a, const double *b, int dim) {
    double dot = 0.0, na = 0.0, nb = 0.0;
    for (int i = 0; i < dim; i++) {
        dot += a[i] * b[i];
        na  += a[i] * a[i];
        nb  += b[i] * b[i];
    }
    if (na == 0.0 || nb == 0.0) return 1.0;
    return 1.0 - dot / (sqrt(na) * sqrt(nb));
}

/* Run SFS on st->query and cache the refined point in st->best_point.
 * Uses a 1-row dummy corpus (the query itself); SFS is corpus-
 * independent for best_point computation, and the dummy keeps the
 * C-API contract satisfied. best_point extraction comes from
 * fsql_parse.c (the fuzz-covered extractor). */
static int run_sniper_and_cache(FsqlState *st, int dim) {
    const char *result_json = NULL;
    size_t      result_len  = 0;

    int rc = fsql_search_ptr(
        st->ctx,
        st->query, /*n_rows*/ 1, (size_t)dim,
        st->query, (size_t)dim,
        /*k*/ 1,
        FSQL_SFS_PARAMS_JSON, strlen(FSQL_SFS_PARAMS_JSON),
        &result_json, &result_len);
    if (rc != 0 || !result_json) return 0;

    int n = fsql_extract_best_point(result_json, st->best_point,
                                    FSQL_ARENA_MAX_DIM);
    return n == dim;
}

static void fractal_search_fn(sqlite3_context *ctx, int argc,
                              sqlite3_value **argv) {
    if (argc != 2) {
        sqlite3_result_error(ctx,
            "fractal_search(vector, query) expects 2 args", -1);
        return;
    }
    FsqlState *st = (FsqlState *)sqlite3_user_data(ctx);
    if (!st || !st->ctx) {
        sqlite3_result_error(ctx, "fractalsql: extension not initialized", -1);
        return;
    }
    if (sqlite3_value_type(argv[0]) == SQLITE_NULL ||
        sqlite3_value_type(argv[1]) == SQLITE_NULL) {
        sqlite3_result_null(ctx);
        return;
    }

    int dim_vec = fsql_parse_value_to_doubles(argv[0], st->trial,
                                              FSQL_ARENA_MAX_DIM);
    if (dim_vec <= 0) {
        sqlite3_result_error(ctx,
            "fractalsql: invalid vector (expect CSV/JSON text or float32 BLOB)", -1);
        return;
    }

    int dim_q = fsql_parse_value_to_doubles(argv[1], st->query,
                                            FSQL_ARENA_MAX_DIM);
    if (dim_q <= 0 || dim_q != dim_vec) {
        sqlite3_result_error(ctx,
            "fractalsql: query dim mismatch with vector", -1);
        return;
    }

    uint64_t h = fnv1a_64(st->query, (size_t)dim_q * sizeof(double));
    int need_refresh = !st->best_valid ||
                       st->arena_dim != dim_q ||
                       st->best_hash != h;

    st->arena_dim = dim_q;
    if (need_refresh) {
        if (!run_sniper_and_cache(st, dim_q)) {
            const char *err = fsql_last_error(st->ctx);
            char buf[256];
            snprintf(buf, sizeof(buf), "fractalsql: SFS call failed: %s",
                     (err && *err) ? err : "(no detail)");
            sqlite3_result_error(ctx, buf, -1);
            return;
        }
        st->best_valid = 1;
        st->best_hash = h;
    }

    double dist = cosine_distance(st->trial, st->best_point, dim_q);
    sqlite3_result_double(ctx, dist);
}

/* -------------------------------------------------------------------
 * fractal_search_explore — Scout Mode aggregate.
 *
 * Sniper (fractal_search, scalar) collapses into one basin. Scout
 * scans the WHOLE `emb` column as the corpus and runs SFS with walk=0
 * + return_population so the final population disperses across
 * distinct basins. The corpus buffer is the one place this TU still
 * needs a growable array — a plain malloc/realloc block, no libstdc++.
 * ------------------------------------------------------------------- */

static int json_get_int(const char *s, const char *key, int fallback) {
    if (!s || !*s) return fallback;
    char needle[64];
    snprintf(needle, sizeof needle, "\"%s\"", key);
    const char *p = strstr(s, needle);
    if (!p) return fallback;
    p = strchr(p, ':');
    if (!p) return fallback;
    p++;
    while (*p == ' ' || *p == '\t') p++;
    char *end;
    long v = strtol(p, &end, 10);
    return (end == p) ? fallback : (int)v;
}

typedef struct ScoutAgg {
    double  *corpus;            /* flat row-major; NULL until first step */
    int      corpus_cap;        /* allocated doubles                     */
    int      dim;
    int      n_rows;
    double   query[FSQL_ARENA_MAX_DIM];
    int      query_dim;
    int      captured;          /* query/params captured once            */
    int      bad;               /* a row errored -> finalize to error    */
    char     params[256];
} ScoutAgg;

static int scout_corpus_append(ScoutAgg *agg, const double *row, int d) {
    if (agg->n_rows * d + d > agg->corpus_cap) {
        int new_cap = agg->corpus_cap ? agg->corpus_cap * 2 : 4096;
        while (new_cap < agg->n_rows * d + d) new_cap *= 2;
        double *nb = (double *)realloc(agg->corpus,
                                       (size_t)new_cap * sizeof(double));
        if (!nb) return -1;
        agg->corpus = nb;
        agg->corpus_cap = new_cap;
    }
    memcpy(agg->corpus + (size_t)agg->n_rows * d, row,
           (size_t)d * sizeof(double));
    agg->n_rows++;
    return 0;
}

static void fractal_search_explore_step(sqlite3_context *ctx, int argc,
                                 sqlite3_value **argv) {
    if (argc < 2 || argc > 3) {
        sqlite3_result_error(ctx,
            "fractal_search_explore(emb, query [, params]) expects 2 or 3 args", -1);
        return;
    }
    ScoutAgg *agg = (ScoutAgg *)sqlite3_aggregate_context(ctx, sizeof(ScoutAgg));
    if (!agg) { return; }                 /* OOM — SQLite raises */
    if (agg->bad) return;

    /* Skip rows with a NULL/absent embedding rather than poisoning the
     * whole aggregate. */
    if (sqlite3_value_type(argv[0]) == SQLITE_NULL) return;
    if (sqlite3_value_type(argv[1]) == SQLITE_NULL) { agg->bad = 1; return; }

    if (!agg->captured) {
        int qd = fsql_parse_value_to_doubles(argv[1], agg->query,
                                             FSQL_ARENA_MAX_DIM);
        if (qd <= 0) { agg->bad = 1; return; }
        agg->query_dim = qd;
        if (argc == 3 && sqlite3_value_type(argv[2]) == SQLITE_TEXT) {
            const char *ps = (const char *)sqlite3_value_text(argv[2]);
            if (ps) strncpy(agg->params, ps, sizeof(agg->params) - 1);
        }
        agg->captured = 1;
    }

    double trial[FSQL_ARENA_MAX_DIM];
    int d = fsql_parse_value_to_doubles(argv[0], trial, FSQL_ARENA_MAX_DIM);
    if (d <= 0) return;                   /* skip an unparseable row */
    if (agg->dim == 0) agg->dim = d;
    if (d != agg->dim || d != agg->query_dim) { agg->bad = 1; return; }

    if (scout_corpus_append(agg, trial, d) != 0) agg->bad = 1;
}

static void fractal_search_explore_final(sqlite3_context *ctx) {
    ScoutAgg *agg = (ScoutAgg *)sqlite3_aggregate_context(ctx, 0);
    FsqlState *st = (FsqlState *)sqlite3_user_data(ctx);

    if (!agg || !agg->corpus || agg->n_rows == 0 || agg->bad) {
        if (agg && agg->corpus) { free(agg->corpus); agg->corpus = NULL; }
        if (agg && agg->bad)
            sqlite3_result_error(ctx, "fractalsql: fractal_search_explore input error", -1);
        else
            sqlite3_result_null(ctx);
        return;
    }

    int pop_size = json_get_int(agg->params, "population_size",  50);
    int iters    = json_get_int(agg->params, "iterations",       15);
    int diff     = json_get_int(agg->params, "diffusion_factor", 2);
    /* Clamped on both sides, matching the SFS validation ceilings the
     * agent tier enforces (FSQL_AGENTS_MAX_*): json_get_int accepts any
     * positive value out of the memoized params JSON, and an unbounded
     * population/iteration count is in-process resource exhaustion. */
    if (pop_size < 2)             pop_size = 2;
    if (pop_size > FSQL_AGENTS_MAX_POPULATION)
                                  pop_size = FSQL_AGENTS_MAX_POPULATION;
    if (iters    < 1)             iters    = 1;
    if (iters    > FSQL_AGENTS_MAX_ITERATIONS)
                                  iters    = FSQL_AGENTS_MAX_ITERATIONS;
    if (diff     < 1)             diff     = 1;
    if (diff     > FSQL_AGENTS_MAX_DIFFUSION)
                                  diff     = FSQL_AGENTS_MAX_DIFFUSION;

    char core_params[256];
    snprintf(core_params, sizeof core_params,
        "{\"max_generation\":%d,\"population_size\":%d,"
        "\"maximum_diffusion\":%d,\"walk\":0,"
        "\"return_population\":true,\"bound_clipping\":true}",
        iters, pop_size, diff);

    const char *result_json = NULL;
    size_t result_len = 0;
    int rc = fsql_search_ptr(
        st ? st->ctx : NULL,
        agg->corpus, (size_t)agg->n_rows, (size_t)agg->dim,
        agg->query, (size_t)agg->dim,
        /*k*/ 1,
        core_params, strlen(core_params),
        &result_json, &result_len);

    free(agg->corpus);
    agg->corpus = NULL;

    if (rc != 0 || !result_json) {
        const char *err = st ? fsql_last_error(st->ctx) : NULL;
        char buf[256];
        snprintf(buf, sizeof buf, "fractalsql: scout SFS failed: %s",
                 (err && *err) ? err : "(no detail)");
        sqlite3_result_error(ctx, buf, -1);
        return;
    }
    /* result_json (incl. "population") is owned by st->ctx until the
     * next search on it; SQLITE_TRANSIENT copies it now. */
    sqlite3_result_text(ctx, result_json, (int)result_len, SQLITE_TRANSIENT);
}

/* -------------------------------------------------------------------
 * Minimal always-registered subset of SQLite's optional built-in math
 * functions (the SQLITE_ENABLE_MATH_FUNCTIONS module). RHEL/Rocky 8
 * and 9's stock sqlite3 package, and Debian 11's, ship without that
 * module compiled in ("no such function: sin"/"sqrt") even though
 * every other SQL surface this extension needs (JSON1, window
 * functions) works fine there — verified directly against each. Only
 * sin() and sqrt() are registered because grepping every shipped
 * demo SQL script found no other math function actually called
 * anywhere; add more here only if a demo starts using one. Registered
 * unconditionally on every host, including ones that already have the
 * real module: SQLite permits overriding an existing scalar function
 * of the same name/arity with no error (verified), and libm produces
 * the same result either way, so this makes every demo self-contained
 * regardless of how the host's sqlite3 was built. NULL/out-of-domain
 * in, NULL out, matching the real module's documented behavior.
 * ------------------------------------------------------------------- */
static void math_sin_fn(sqlite3_context *ctx, int argc, sqlite3_value **argv) {
    (void)argc;
    if (sqlite3_value_type(argv[0]) == SQLITE_NULL) {
        sqlite3_result_null(ctx);
        return;
    }
    sqlite3_result_double(ctx, sin(sqlite3_value_double(argv[0])));
}

static void math_sqrt_fn(sqlite3_context *ctx, int argc, sqlite3_value **argv) {
    (void)argc;
    if (sqlite3_value_type(argv[0]) == SQLITE_NULL) {
        sqlite3_result_null(ctx);
        return;
    }
    double x = sqlite3_value_double(argv[0]);
    if (x < 0.0) {
        sqlite3_result_null(ctx);
        return;
    }
    sqlite3_result_double(ctx, sqrt(x));
}

/* -------------------------------------------------------------------
 * Extension entry point. Symbol name matches `fractalsql` so SQLite's
 * `.load fractalsql` / `load_extension('./fractalsql')` finds it via
 * dlsym.
 * ------------------------------------------------------------------- */

#ifdef _WIN32
__declspec(dllexport)
#endif
int sqlite3_fractalsql_init(sqlite3 *db, char **pzErrMsg,
                            const sqlite3_api_routines *pApi)
{
    SQLITE_EXTENSION_INIT2(pApi);

    FsqlState *st = fsql_state_create(db, pzErrMsg);
    if (!st) return SQLITE_ERROR;

    const int flags = SQLITE_UTF8 | SQLITE_DETERMINISTIC | SQLITE_INNOCUOUS;
    int rc;

    /* Smoke surface. fractal_search owns the state (xDestroy) — every
     * later registration passes NULL to avoid a double-free. */
    rc = sqlite3_create_function_v2(
        db, "fractalsql_edition", 0, flags, NULL,
        edition_fn, NULL, NULL, NULL);
    if (rc != SQLITE_OK) { fsql_state_destroy(st); return rc; }

    rc = sqlite3_create_function_v2(
        db, "fractalsql_version", 0, flags, NULL,
        version_fn, NULL, NULL, NULL);
    if (rc != SQLITE_OK) { fsql_state_destroy(st); return rc; }

    rc = sqlite3_create_function_v2(
        db, "fractal_search", 2, flags, st,
        fractal_search_fn, NULL, NULL, fsql_state_destroy);
    if (rc != SQLITE_OK) { fsql_state_destroy(st); return rc; }

    /* sin/sqrt: self-contained even on hosts missing
     * SQLITE_ENABLE_MATH_FUNCTIONS (see the registrations' own comment
     * above). Best-effort: a failure here would only affect demo SQL
     * that calls sin()/sqrt() directly, never the extension's own
     * registered functions, so it does not abort init. */
    sqlite3_create_function_v2(
        db, "sin", 1, flags, NULL, math_sin_fn, NULL, NULL, NULL);
    sqlite3_create_function_v2(
        db, "sqrt", 1, flags, NULL, math_sqrt_fn, NULL, NULL, NULL);

    /* fractal_search_explore — Scout Mode aggregate (xStep + xFinal). Shares
     * the same per-connection state as fractal_search. NOT marked
     * DETERMINISTIC — SFS is stochastic. Variadic narg (-1) accepts
     * the 2-arg (emb, query) and 3-arg (emb, query, params) forms. */
    rc = sqlite3_create_function_v2(
        db, "fractal_search_explore", -1, SQLITE_UTF8 | SQLITE_INNOCUOUS, st,
        NULL /*xFunc*/,
        fractal_search_explore_step, fractal_search_explore_final,
        NULL /*xDestroy — owned by fractal_search's registration*/);
    if (rc != SQLITE_OK) return rc;

    /* Feature modules. Sovereign-only modules are compiled out on a
     * minimal build (their names then resolve as unknown functions). */
#ifdef FSQL_SQLITE_SOVEREIGN
    rc = fsql_vector_register(db, st);        if (rc) return rc;
    rc = fsql_config_register(db, st);        if (rc) return rc;
    rc = fsql_t2s_register(db, st);           if (rc) return rc;
    rc = fsql_vectorizer_register(db, st);    if (rc) return rc;
    rc = fsql_agents_register(db, st);        if (rc) return rc;
    rc = fsql_domain_agents_register(db, st); if (rc) return rc;
    rc = fsql_ledger_register(db, st);        if (rc) return rc;
    rc = fsql_sovereign_register(db, st);     if (rc) return rc;
#else
    rc = fsql_vector_register(db, st);
    if (rc) return rc;
#endif

    return SQLITE_OK;
}