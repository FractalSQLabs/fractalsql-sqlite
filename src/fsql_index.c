/* src/fsql_index.c -- fractal_index_* and the indexed fractal_search for SQLite.
 *
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * Sovereign-tier TU (it calls the core's fsql_ivf_* maths, which the minimal build does not carry). The core does the maths
 * (k-means cells, INT8 / INT4 / FP16 / FP32 codes, candidate search, recall estimation); this file owns the storage and the
 * SQL surface:
 *
 *   fractal_index_create(table, column [, options]) -> TEXT (JSON)   build and store an index; calibrates the default nprobe
 *   fractal_index_rebuild(name)                     -> TEXT (JSON)   full rebuild from the current rows, same options
 *   fractal_index_drop(name)                        -> INTEGER       1 when dropped
 *   fractal_index_info(name)                        -> TEXT (JSON)   format, sizes, staleness, calibration, last search stats, status + advice
 *   fractal_index_list()                            -> TEXT (JSON)   one object per index: name, table, column, format, rows, stale, status, generation
 *   fractal_index_refresh(name)                     -> TEXT (JSON)   fold the rows added since the build into the cells (no retraining)
 *   fractal_search(table, column, query, k [, options]) -> TEXT (JSON array of {doc_id, distance, scan_pos})
 *                                                       indexed approximate search; exact scan when no index exists
 *   fractal_index_candidates(table, column, query [, options]) -> TEXT (JSON array of rowids) candidate rows for Scout
 *
 * Storage (created on first use, plain SQLite tables so they travel with the database file):
 *   fractal_index_meta(name PRIMARY KEY, tbl, col, dim, metric, format, nlist, pca_dim, rows, max_rowid, model, seed,
 *                      generation, format_version, options, built_at, nprobe_default, calib, model_blob)
 *   fractal_index_cells(name, generation, cell, n, ids BLOB (int64 little-endian), codes BLOB)  WITHOUT ROWID
 * A build writes a NEW generation and switches the generation pointer in one SAVEPOINT; readers only ever see a complete
 * generation. Rows added after the build (rowid above max_rowid) are scanned exactly (the delta) until fractal_index_refresh folds
 * them into the cells (a new generation, the model is kept); deleted rows are dropped by the verify step; a changed vector is only
 * picked up by a rebuild (fractal_index_info reports stale and says which of the two it recommends).
 *
 * Every candidate is verified: the shortlist rows are fetched, deleted rows dropped, exact double cosine distances computed
 * with the one shared implementation (fsql_precision.h) and ordered by distance then rowid. The index never returns an
 * approximate distance as an answer. Indexed fractal_search does not apply Diversify repulsion (use
 * fractal_search_telemetry for stateful diversity).
 */
#define _POSIX_C_SOURCE 200809L
#include <sqlite3ext.h>
#include <errno.h>
#include <math.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "fsql_sqlite_internal.h"
#include "fsql_precision.h"
#include "fractalsql_parse.h"
#include "fractalsql_sql.h"

SQLITE_EXTENSION_INIT3

/* The IVF maths lives in fractalsql-core and the vendored core archive must carry it: the linker
 * extracts an archive member only to resolve an undefined STRONG reference, so a weak reference
 * would leave the symbol NULL -- the index would then be silently unavailable even with a fresh
 * archive. The declarations below therefore refer to the core's own header (a strong reference),
 * and a build against a core that predates the index is opted out of explicitly with
 * -DFSQL_NO_IVF: the functions stay registered and report that this core has no index. */

#if defined(FSQL_NO_IVF)
/* 0: this build was told the core has no IVF maths. */
static int fi_ivf_available(void) { return 0; }
#else
/* 1: the core's IVF maths is linked in. */
static int fi_ivf_available(void) { return 1; }
#endif

#define FI_NO_CORE_MSG "fractalsql: this build of fractalsql-core does not carry the IVF index " \
                       "(rebuild the core and refresh include/<platform>)"


#define FI_MAXDIM        8192
#define FI_MAX_CACHED    8
#define FI_MAX_BYTES     ((size_t)2 << 30)       /* cap on the in-memory build (codes + ids) */
#define FI_CALIB_FLOATS  ((size_t)1 << 28)       /* corpus floats the calibration may hold for exact ground truth */
#define FI_FORMAT_VERSION 1

static const char *const FI_FMT_NAME[4] = { "INT8", "INT4", "FP16", "FP32" };

static int fi_ident_ok(const char *s)
{
    if (!s || !*s) return 0;
    size_t n = strlen(s);
    if (n > 63) return 0;
    for (size_t i = 0; i < n; i++) {
        char c = s[i];
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || (i > 0 && c >= '0' && c <= '9'))) return 0;
    }
    return 1;
}

static double fi_opt_num(const char *json, const char *key, double dflt)
{
    if (!json) return dflt;
    const char *p = fsql_json_top_level_value(json, key);
    if (!p) return dflt;
    char *e;
    double v = strtod(p, &e);
    return (e == p || v != v) ? dflt : v;
}

static int fi_opt_bool(const char *json, const char *key, int dflt)
{
    if (!json) return dflt;
    const char *p = fsql_json_top_level_value(json, key);
    if (!p) return dflt;
    if (!strncmp(p, "true", 4)) return 1;
    if (!strncmp(p, "false", 5)) return 0;
    return dflt;
}

static int fi_opt_str(const char *json, const char *key, char *out, size_t cap)
{
    out[0] = 0;
    if (!json) return 0;
    const char *p = fsql_json_top_level_value(json, key);
    if (!p || *p != '"') return 0;
    p++;
    size_t n = 0;
    while (*p && *p != '"' && n + 1 < cap) out[n++] = *p++;
    out[n] = 0;
    return 1;
}

static void put_le64(uint8_t *p, int64_t v) { uint64_t u = (uint64_t)v; for (int i = 0; i < 8; i++) p[i] = (uint8_t)(u >> (8 * i)); }
static int64_t get_le64(const uint8_t *p) { uint64_t u = 0; for (int i = 0; i < 8; i++) u |= (uint64_t)p[i] << (8 * i); return (int64_t)u; }

/* ---------------------------------------------------------------- state */

typedef struct FIdx {
    char            name[64], tbl[64], col[64], model[64];
    int             dim, fmt, nlist, pca_dim, generation, loaded, nprobe_default;
    int64_t         rows, max_rowid;
    fsql_ivf_model *m;
    fsql_ivf_index *x;
} FIdx;

typedef struct FIdxState {
    FsqlState *st;
    FIdx       cache[FI_MAX_CACHED];
    int        ncache;
    int64_t    last_rows_scanned;           /* last search statistics: the "index actually used" gate */
    int        last_cells_probed, last_used_index, last_lookups;
} FIdxState;

static void fi_release(FIdx *x)
{
    if (x->x) fsql_ivf_index_free(x->x);
    if (x->m) fsql_ivf_model_free(x->m);
    memset(x, 0, sizeof *x);
}

static int fi_parse_fmt(const char *s)
{
    for (int i = 0; i < 4; i++) if (!strcmp(s, FI_FMT_NAME[i])) return i;
    return -1;
}

static size_t fi_default_rerank(int fmt) { return fmt == FSQL_IVF_FMT_INT4 ? 40u : (fmt == FSQL_IVF_FMT_INT8 ? 30u : 0u); }

/* ---------------------------------------------------------------- tables */

static int fi_exec(sqlite3 *db, const char *sql, char *err, size_t cap)
{
    char *m = NULL;
    int rc = sqlite3_exec(db, sql, NULL, NULL, &m);
    if (rc != SQLITE_OK) { snprintf(err, cap, "fractalsql: %s", m ? m : "sql error"); sqlite3_free(m); return -1; }
    return 0;
}

static int fi_ensure_tables(sqlite3 *db, char *err, size_t cap)
{
    return fi_exec(db,
        "CREATE TABLE IF NOT EXISTS fractal_index_meta("
        " name TEXT PRIMARY KEY, tbl TEXT NOT NULL, col TEXT NOT NULL, dim INTEGER NOT NULL, metric TEXT NOT NULL,"
        " format TEXT NOT NULL, nlist INTEGER NOT NULL, pca_dim INTEGER NOT NULL, rows INTEGER NOT NULL, max_rowid INTEGER NOT NULL,"
        " model TEXT NOT NULL, seed INTEGER NOT NULL, generation INTEGER NOT NULL, format_version INTEGER NOT NULL,"
        " options TEXT NOT NULL, built_at TEXT NOT NULL, nprobe_default INTEGER NOT NULL DEFAULT 0, calib TEXT NOT NULL DEFAULT '',"
        " model_blob BLOB NOT NULL);"
        "CREATE TABLE IF NOT EXISTS fractal_index_cells("
        " name TEXT NOT NULL, generation INTEGER NOT NULL, cell INTEGER NOT NULL, n INTEGER NOT NULL,"
        " ids BLOB NOT NULL, codes BLOB NOT NULL, PRIMARY KEY(name, generation, cell)) WITHOUT ROWID;",
        err, cap);
}

/* read the meta row (no payload); returns 0 ok, 1 absent */
static int fi_read_meta(sqlite3 *db, const char *name, FIdx *x, char *options, size_t ocap)
{
    sqlite3_stmt *s = NULL;
    if (sqlite3_prepare_v2(db, "SELECT tbl,col,dim,format,nlist,pca_dim,rows,max_rowid,model,generation,options,nprobe_default"
                               " FROM fractal_index_meta WHERE name=?1", -1, &s, NULL) != SQLITE_OK) return 1;
    sqlite3_bind_text(s, 1, name, -1, SQLITE_STATIC);
    if (sqlite3_step(s) != SQLITE_ROW) { sqlite3_finalize(s); return 1; }
    memset(x, 0, sizeof *x);
    snprintf(x->name, sizeof x->name, "%s", name);
    snprintf(x->tbl, sizeof x->tbl, "%s", (const char *)sqlite3_column_text(s, 0));
    snprintf(x->col, sizeof x->col, "%s", (const char *)sqlite3_column_text(s, 1));
    x->dim = sqlite3_column_int(s, 2);
    x->fmt = fi_parse_fmt((const char *)sqlite3_column_text(s, 3));
    x->nlist = sqlite3_column_int(s, 4); x->pca_dim = sqlite3_column_int(s, 5);
    x->rows = sqlite3_column_int64(s, 6); x->max_rowid = sqlite3_column_int64(s, 7);
    snprintf(x->model, sizeof x->model, "%s", (const char *)sqlite3_column_text(s, 8));
    x->generation = sqlite3_column_int(s, 9);
    if (options && ocap) snprintf(options, ocap, "%s", (const char *)sqlite3_column_text(s, 10));
    x->nprobe_default = sqlite3_column_int(s, 11);
    sqlite3_finalize(s);
    return x->fmt < 0 ? 1 : 0;
}

static int fi_find_name(sqlite3 *db, const char *tbl, const char *col, char *name, size_t cap)
{
    sqlite3_stmt *s = NULL;
    if (sqlite3_prepare_v2(db, "SELECT name FROM fractal_index_meta WHERE tbl=?1 AND col=?2 ORDER BY name LIMIT 1", -1, &s, NULL) != SQLITE_OK) return 0;
    sqlite3_bind_text(s, 1, tbl, -1, SQLITE_STATIC); sqlite3_bind_text(s, 2, col, -1, SQLITE_STATIC);
    int ok = 0;
    if (sqlite3_step(s) == SQLITE_ROW) { snprintf(name, cap, "%s", (const char *)sqlite3_column_text(s, 0)); ok = 1; }
    sqlite3_finalize(s);
    return ok;
}

/* load the current generation into memory (resident cache, reloaded when the generation pointer moves) */
static FIdx *fi_load(FIdxState *S, sqlite3 *db, const char *name, char *err, size_t cap)
{
    FIdx meta;
    if (!fi_ivf_available()) { snprintf(err, cap, "%s", FI_NO_CORE_MSG); return NULL; }
    if (fi_read_meta(db, name, &meta, NULL, 0) != 0) { snprintf(err, cap, "fractalsql: no index named '%s'", name); return NULL; }
    FIdx *slot = NULL;
    for (int i = 0; i < S->ncache; i++)
        if (!strcmp(S->cache[i].name, name)) {
            if (S->cache[i].loaded && S->cache[i].generation == meta.generation) { S->cache[i].nprobe_default = meta.nprobe_default; return &S->cache[i]; }
            fi_release(&S->cache[i]);
            slot = &S->cache[i];
            break;
        }
    if (!slot) {
        if (S->ncache >= FI_MAX_CACHED) { snprintf(err, cap, "fractalsql: too many resident indexes (limit %d)", FI_MAX_CACHED); return NULL; }
        slot = &S->cache[S->ncache++];
    }
    *slot = meta;

    sqlite3_stmt *s = NULL;
    if (sqlite3_prepare_v2(db, "SELECT model_blob FROM fractal_index_meta WHERE name=?1", -1, &s, NULL) != SQLITE_OK) {
        snprintf(err, cap, "fractalsql: cannot read index '%s'", name); fi_release(slot); return NULL; }
    sqlite3_bind_text(s, 1, name, -1, SQLITE_STATIC);
    if (sqlite3_step(s) == SQLITE_ROW) {
        int rc = 0;
        const void *b = sqlite3_column_blob(s, 0);
        int bl = sqlite3_column_bytes(s, 0);
        if (b && bl > 0) slot->m = fsql_ivf_model_load((const uint8_t *)b, (size_t)bl, &rc);
    }
    sqlite3_finalize(s);
    fsql_ivf_info_t info;
    if (!slot->m || fsql_ivf_model_info(slot->m, &info) != FSQL_OK || (int)info.dim != slot->dim || (int)info.nlist != slot->nlist ||
        (int)info.format != slot->fmt) {
        snprintf(err, cap, "fractalsql: index '%s' has a missing or corrupt model; rebuild it", name); fi_release(slot); return NULL; }
    slot->x = fsql_ivf_index_new(slot->m);
    if (!slot->x) { snprintf(err, cap, "fractalsql: out of memory loading index '%s'", name); fi_release(slot); return NULL; }

    if (sqlite3_prepare_v2(db, "SELECT cell,n,ids,codes FROM fractal_index_cells WHERE name=?1 AND generation=?2 ORDER BY cell", -1, &s, NULL) != SQLITE_OK) {
        snprintf(err, cap, "fractalsql: cannot read index cells"); fi_release(slot); return NULL; }
    sqlite3_bind_text(s, 1, name, -1, SQLITE_STATIC); sqlite3_bind_int(s, 2, slot->generation);
    int cells = 0; int64_t total = 0;
    while (sqlite3_step(s) == SQLITE_ROW) {
        int c = sqlite3_column_int(s, 0);
        int64_t n = sqlite3_column_int64(s, 1);
        int ib = sqlite3_column_bytes(s, 2), cb = sqlite3_column_bytes(s, 3);
        const uint8_t *ip = (const uint8_t *)sqlite3_column_blob(s, 2), *cp = (const uint8_t *)sqlite3_column_blob(s, 3);
        /* The sizes are checked by division, not by multiplication: n comes from the database and a
         * hostile row could make n * 8 overflow (signed overflow is undefined behaviour). */
        if (c < 0 || c >= slot->nlist || n < 0 || ib < 0 || cb < 0 || info.code_bytes == 0 ||
            (int64_t)ib / 8 != n || (int64_t)ib % 8 != 0 || (int64_t)cb / (int64_t)info.code_bytes != n || (int64_t)cb % (int64_t)info.code_bytes != 0 ||
            (n > 0 && (!ip || !cp))) {
            sqlite3_finalize(s); snprintf(err, cap, "fractalsql: index '%s' is corrupt (cell %d)", name, c); fi_release(slot); return NULL; }
        int64_t *ids = (int64_t *)malloc((size_t)(n ? n : 1) * sizeof(int64_t));
        if (!ids) { sqlite3_finalize(s); snprintf(err, cap, "fractalsql: out of memory loading index"); fi_release(slot); return NULL; }
        for (int64_t j = 0; j < n; j++) ids[j] = get_le64(ip + (size_t)j * 8);
        int rc = fsql_ivf_index_set_cell(slot->x, (uint32_t)c, ids, cp, (size_t)n);
        free(ids);
        if (rc != FSQL_OK) { sqlite3_finalize(s); snprintf(err, cap, "fractalsql: out of memory loading index"); fi_release(slot); return NULL; }
        cells++; total += n;
    }
    sqlite3_finalize(s);
    if (cells != slot->nlist || total != slot->rows) {
        snprintf(err, cap, "fractalsql: index '%s' is incomplete (%d of %d cells)", name, cells, slot->nlist); fi_release(slot); return NULL; }
    slot->loaded = 1;
    return slot;
}

/* The build timestamp, in UTC, as an ISO-8601 string. gmtime_r is POSIX, gmtime_s is the Windows
 * spelling of the same thing: the host builds on both. */
static void fi_utc_now(char *ts, size_t cap)
{
    time_t now = time(NULL);
    struct tm tmv;
#if defined(_WIN32)
    if (gmtime_s(&tmv, &now) == 0) strftime(ts, cap, "%Y-%m-%dT%H:%M:%SZ", &tmv);
    else snprintf(ts, cap, "1970-01-01T00:00:00Z");
#else
    if (gmtime_r(&now, &tmv)) strftime(ts, cap, "%Y-%m-%dT%H:%M:%SZ", &tmv);
    else snprintf(ts, cap, "1970-01-01T00:00:00Z");
#endif
}

/* ---------------------------------------------------------------- build */

static void fi_forget(FIdxState *S, const char *name)
{
    for (int i = 0; i < S->ncache; i++)
        if (!strcmp(S->cache[i].name, name)) { fi_release(&S->cache[i]); S->cache[i].name[0] = 0; }
}

/* read rows once: calls cb for each (rowid, float vector of the table's dimension). Returns 0 ok, -1 error (err filled). */
typedef int (*fi_row_cb)(void *ud, int64_t rowid, const float *vec, int dim);

/* after_rowid: only rows with a larger rowid (INT64_MIN: every row). */
static int fi_scan_rows_after(sqlite3 *db, const char *tbl, const char *col, int64_t after_rowid, int *dim_io, fi_row_cb cb, void *ud, char *err, size_t ecap)
{
    char sql[300];
    snprintf(sql, sizeof sql, "SELECT rowid, \"%s\" FROM \"%s\" WHERE \"%s\" IS NOT NULL%s ORDER BY rowid", col, tbl, col,
             after_rowid == INT64_MIN ? "" : " AND rowid > ?1");
    sqlite3_stmt *rs = NULL;
    if (sqlite3_prepare_v2(db, sql, -1, &rs, NULL) != SQLITE_OK) { snprintf(err, ecap, "fractalsql: cannot read %s.%s: %s", tbl, col, sqlite3_errmsg(db)); return -1; }
    if (after_rowid != INT64_MIN) sqlite3_bind_int64(rs, 1, after_rowid);
    double *dbuf = (double *)malloc(FI_MAXDIM * sizeof(double));
    float *fbuf = (float *)malloc(FI_MAXDIM * sizeof(float));
    if (!dbuf || !fbuf) { free(dbuf); free(fbuf); sqlite3_finalize(rs); snprintf(err, ecap, "fractalsql: out of memory"); return -1; }
    int rc = 0, D = *dim_io;
    while (sqlite3_step(rs) == SQLITE_ROW) {
        int64_t id = sqlite3_column_int64(rs, 0);
        int d = fsql_parse_value_to_doubles(sqlite3_column_value(rs, 1), dbuf, FI_MAXDIM);
        if (d <= 0) { snprintf(err, ecap, "fractalsql: malformed vector at rowid %lld", (long long)id); rc = -1; break; }
        if (D == 0) D = d;
        if (d != D) { snprintf(err, ecap, "fractalsql: vector dimension %d at rowid %lld differs from %d", d, (long long)id, D); rc = -1; break; }
        for (int i = 0; i < d; i++) {
            if (!isfinite(dbuf[i]) || fabs(dbuf[i]) > 3.0e38) { snprintf(err, ecap, "fractalsql: non-finite or out-of-range component at rowid %lld", (long long)id); rc = -1; break; }
            fbuf[i] = (float)dbuf[i];
        }
        if (rc) break;
        if (cb(ud, id, fbuf, d) != 0) { snprintf(err, ecap, "fractalsql: out of memory"); rc = -1; break; }
    }
    sqlite3_finalize(rs); free(dbuf); free(fbuf);
    *dim_io = D;
    return rc;
}

static int fi_scan_rows(sqlite3 *db, const char *tbl, const char *col, int *dim_io, fi_row_cb cb, void *ud, char *err, size_t ecap)
{
    return fi_scan_rows_after(db, tbl, col, INT64_MIN, dim_io, cb, ud, err, ecap);
}

typedef struct { fsql_ivf_trainer *t; int64_t rows; } FiSampleCtx;

static int fi_cb_sample(void *ud, int64_t rowid, const float *vec, int dim)
{
    (void)rowid; (void)dim;
    FiSampleCtx *c = (FiSampleCtx *)ud;
    c->rows++;
    return fsql_ivf_trainer_add(c->t, vec, 1) == FSQL_OK ? 0 : -1;
}

typedef struct {
    const fsql_ivf_model *m;
    size_t   code_bytes, cap, n;
    int64_t  *rowid;
    uint32_t *cell;
    uint8_t  *codes;
    float    *corpus;                 /* normalised copy for the calibration's exact truth (NULL when too large) */
    size_t    corpus_cap;
    int       dim;
    int64_t   max_rowid;
} FiEncodeCtx;

static int fi_cb_encode(void *ud, int64_t rowid, const float *vec, int dim)
{
    FiEncodeCtx *c = (FiEncodeCtx *)ud;
    if (c->n == c->cap) {
        size_t nc = c->cap ? c->cap * 2u : 1024u;
        size_t b1, b2, b3;
        if (nc > ((size_t)-1) / sizeof(int64_t) || nc > ((size_t)-1) / (c->code_bytes ? c->code_bytes : 1)) return -1;
        b1 = nc * sizeof(int64_t); b2 = nc * sizeof(uint32_t); b3 = nc * c->code_bytes;
        if (b1 + b2 + b3 > FI_MAX_BYTES) return -1;
        int64_t *r = (int64_t *)realloc(c->rowid, b1); if (!r) return -1; c->rowid = r;
        uint32_t *l = (uint32_t *)realloc(c->cell, b2); if (!l) return -1; c->cell = l;
        uint8_t *k = (uint8_t *)realloc(c->codes, b3 ? b3 : 1); if (!k) return -1; c->codes = k;
        c->cap = nc;
    }
    if (fsql_ivf_encode(c->m, vec, &c->cell[c->n], c->codes + c->n * c->code_bytes) != FSQL_OK) return -1;
    c->rowid[c->n] = rowid;
    if (rowid > c->max_rowid) c->max_rowid = rowid;
    if (c->corpus) {
        if (c->n == c->corpus_cap) {
            size_t nc = c->corpus_cap ? c->corpus_cap * 2u : 1024u;
            if (nc > FI_CALIB_FLOATS / (size_t)dim) { free(c->corpus); c->corpus = NULL; }
            else {
                float *nb = (float *)realloc(c->corpus, nc * (size_t)dim * sizeof(float));
                if (!nb) { free(c->corpus); c->corpus = NULL; } else { c->corpus = nb; c->corpus_cap = nc; }
            }
        }
        if (c->corpus) fsql_ivf_normalize(vec, (size_t)dim, c->corpus + c->n * (size_t)dim);
    }
    c->n++;
    return 0;
}

/* Monte Carlo calibration: sample rows as queries (each left out of its own ground truth), compare the index with exact
 * search at nprobe 1, 2, 4 ... nlist and recommend the smallest nprobe whose 95% lower bound reaches the target. */
static int fi_calibrate(const fsql_ivf_index *x, const fsql_ivf_info_t *info, const float *Xn, const float *Xraw, const int64_t *ids, size_t n, int dim,
                        double target, unsigned samples, uint64_t seed, int fmt, char *calib, size_t ccap, int *nprobe_out)
{
    const unsigned K = 10;
    if (samples < 20u) samples = 20u;
    if (samples > 2000u) samples = 2000u;
    if (n < (size_t)K + 2u || (size_t)samples > n) { if (n < (size_t)K + 2u) return 1; samples = (unsigned)n; }
    uint64_t *pos = (uint64_t *)malloc(samples * sizeof(uint64_t));
    float *Q = (float *)malloc((size_t)samples * (size_t)dim * sizeof(float));
    int64_t *self = (int64_t *)malloc(samples * sizeof(int64_t)), *truth = (int64_t *)malloc((size_t)samples * K * sizeof(int64_t));
    if (!pos || !Q || !self || !truth) { free(pos); free(Q); free(self); free(truth); return -1; }
    int rc = fsql_ivf_sample_rows(n, samples, seed, pos);
    for (unsigned i = 0; rc == FSQL_OK && i < samples; i++) {
        memcpy(Q + (size_t)i * dim, Xraw + pos[i] * (size_t)dim, (size_t)dim * sizeof(float));
        self[i] = ids[pos[i]];
        size_t nt = 0;
        rc = fsql_ivf_exact_topk(Xn, ids, n, (size_t)dim, Xn + pos[i] * (size_t)dim, self[i], 1, K, truth + (size_t)i * K, &nt);
        if (rc == FSQL_OK && nt != K) rc = FSQL_ERR_INVALID;
    }
    uint32_t np[24]; size_t nnp = 0;
    for (uint32_t v = 1; v < info->nlist && nnp < 22; v *= 2u) np[nnp++] = v;
    np[nnp++] = info->nlist;
    double mean[24], se[24], lo[24], sc[24]; uint32_t rec = 0;
    uint32_t shortlist = (uint32_t)fi_default_rerank(fmt); if (shortlist < K + 5u) shortlist = K + 5u;
    int er = FSQL_ERR_INVALID;
    if (rc == FSQL_OK) er = fsql_ivf_estimate_recall(x, Q, self, truth, samples, K, np, nnp, shortlist, target, mean, se, lo, sc, &rec);
    int ret = (er == FSQL_OK || er == 1) ? 0 : -1;
    if (ret == 0) {
        size_t len = 0;
        len += (size_t)snprintf(calib + len, ccap - len, "{\"samples\":%u,\"k\":%u,\"target\":%g,\"shortlist\":%u,\"estimates\":[", samples, K, target, shortlist);
        for (size_t a = 0; a < nnp && len + 160 < ccap; a++)
            len += (size_t)snprintf(calib + len, ccap - len, "%s{\"nprobe\":%u,\"recall\":%.4f,\"se\":%.4f,\"ci95_low\":%.4f,\"mean_rows_scanned\":%.0f}", a ? "," : "", np[a], mean[a], se[a], lo[a], sc[a]);
        snprintf(calib + len, ccap - len, "],\"recommended_nprobe\":%u,\"reaches_target\":%s}", rec, er == FSQL_OK ? "true" : "false");
        *nprobe_out = (int)rec;
    }
    free(pos); free(Q); free(self); free(truth);
    return ret;
}

static int fi_build(FIdxState *S, sqlite3 *db, const char *name, const char *tbl, const char *col, const char *opts, int is_rebuild,
                    char *out, size_t ocap, char *err, size_t ecap)
{
    if (fi_ensure_tables(db, err, ecap)) return -1;
    char fmtname[16] = "INT8", model[64] = "", tmp_opt[64];
    if (fi_opt_str(opts, "vector_format", tmp_opt, sizeof tmp_opt)) snprintf(fmtname, sizeof fmtname, "%s", tmp_opt);   /* a missing key keeps the default */
    int fmt = fi_parse_fmt(fmtname);
    if (fmt < 0) { snprintf(err, ecap, "fractalsql: vector_format must be INT8, INT4, FP16 or FP32 (got '%s')", fmtname); return -1; }
    fi_opt_str(opts, "model", model, sizeof model);
    double nlist_d = fi_opt_num(opts, "nlist", 0), iters_d = fi_opt_num(opts, "iters", 0), sample_d = fi_opt_num(opts, "sample", 0);
    double pca_d = fi_opt_num(opts, "pca_dim", 0), seed_d = fi_opt_num(opts, "seed", 1);
    if (nlist_d < 0 || nlist_d > 4096 || iters_d < 0 || iters_d > 100 || sample_d < 0 || sample_d > 1000000 || pca_d < 0 || pca_d > FI_MAXDIM || seed_d < 0) {
        snprintf(err, ecap, "fractalsql: nlist must be 0..4096, iters 0..100, sample 0..1000000, pca_dim 0..%d, seed >= 0", FI_MAXDIM); return -1; }
    uint64_t seed = (uint64_t)seed_d; if (!seed) seed = 1;

    FIdx prev;
    int had = fi_read_meta(db, name, &prev, NULL, 0) == 0;
    if (had && !is_rebuild) { snprintf(err, ecap, "fractalsql: index '%s' already exists (use fractal_index_rebuild or drop it first)", name); return -1; }
    if (!had && is_rebuild) { snprintf(err, ecap, "fractalsql: no index named '%s'", name); return -1; }

    /* pass 1: the training sample (also counts the rows and fixes the dimension) */
    int D = 0;
    fsql_ivf_options_t o; memset(&o, 0, sizeof o);
    /* the dimension is needed to create the trainer: peek at the first row */
    {
        char sql[300]; snprintf(sql, sizeof sql, "SELECT \"%s\" FROM \"%s\" WHERE \"%s\" IS NOT NULL LIMIT 1", col, tbl, col);
        sqlite3_stmt *fs = NULL;
        if (sqlite3_prepare_v2(db, sql, -1, &fs, NULL) != SQLITE_OK) { snprintf(err, ecap, "fractalsql: cannot read %s.%s: %s", tbl, col, sqlite3_errmsg(db)); return -1; }
        double *probe = (double *)malloc(FI_MAXDIM * sizeof(double));
        if (!probe) { sqlite3_finalize(fs); snprintf(err, ecap, "fractalsql: out of memory"); return -1; }
        if (sqlite3_step(fs) == SQLITE_ROW) { int d = fsql_parse_value_to_doubles(sqlite3_column_value(fs, 0), probe, FI_MAXDIM); D = d > 0 ? d : 0; }
        free(probe); sqlite3_finalize(fs);
    }
    if (D == 0) { snprintf(err, ecap, "fractalsql: %s.%s has no vectors to index", tbl, col); return -1; }
    o.struct_size = sizeof o; o.dim = (uint32_t)D; o.format = (uint32_t)fmt; o.nlist = (uint32_t)nlist_d; o.pca_dim = (fmt <= FSQL_IVF_FMT_INT4) ? (uint32_t)pca_d : 0u;
    o.kmeans_iters = (uint32_t)iters_d; o.sample = (uint32_t)sample_d; o.seed = seed;
    int trc = 0;
    fsql_ivf_trainer *t = fsql_ivf_trainer_new(&o, &trc);
    if (!t) { snprintf(err, ecap, trc == FSQL_ERR_OOM ? "fractalsql: out of memory" : "fractalsql: invalid index options for dimension %d (INT8/INT4 need dimension <= 4096 and pca_dim <= dimension)", D); return -1; }
    FiSampleCtx sc = { t, 0 };
    int dd = D;
    if (fi_scan_rows(db, tbl, col, &dd, fi_cb_sample, &sc, err, ecap)) { fsql_ivf_trainer_free(t); return -1; }
    uint8_t *blob = NULL; size_t blen = 0;
    int frc = sc.rows > 0 ? fsql_ivf_trainer_finish(t, &blob, &blen) : FSQL_ERR_INVALID;
    fsql_ivf_trainer_free(t);
    if (frc != FSQL_OK) { snprintf(err, ecap, frc == FSQL_ERR_OOM ? "fractalsql: out of memory training the index" : "fractalsql: %s.%s has no vectors to index", tbl, col); return -1; }
    int mrc = 0;
    fsql_ivf_model *m = fsql_ivf_model_load(blob, blen, &mrc);
    if (!m) { fsql_ivf_free(blob); snprintf(err, ecap, "fractalsql: internal error loading the trained model"); return -1; }
    fsql_ivf_info_t info; fsql_ivf_model_info(m, &info);

    /* pass 2: encode every row */
    FiEncodeCtx ec; memset(&ec, 0, sizeof ec);
    ec.m = m; ec.code_bytes = info.code_bytes; ec.dim = D;
    int want_calib = fi_opt_num(opts, "calibration_samples", 200) > 0 && fi_opt_num(opts, "target_recall", 0.95) > 0;
    if (want_calib) { ec.corpus = (float *)malloc((size_t)1024 * (size_t)D * sizeof(float)); ec.corpus_cap = ec.corpus ? 1024 : 0; }
    int enc_rc = fi_scan_rows(db, tbl, col, &dd, fi_cb_encode, &ec, err, ecap);
    if (enc_rc == 0 && ec.n == 0) { snprintf(err, ecap, "fractalsql: %s.%s has no vectors to index", tbl, col); enc_rc = -1; }
    int rc = -1;
    fsql_ivf_index *x = NULL;
    size_t *ccount = NULL; uint8_t *cellbuf = NULL; int64_t *idbuf = NULL; uint8_t *idbytes = NULL;
    char calib[4096]; calib[0] = 0; int calibrated_nprobe = 0, calib_rc = 1;
    int generation = had ? prev.generation + 1 : 1;
    if (enc_rc != 0) { if (enc_rc > 0 || err[0] == 0) snprintf(err, ecap, "fractalsql: out of memory or over the %zu MiB build limit (use a smaller vector_format or fewer rows)", FI_MAX_BYTES >> 20); goto done; }

    ccount = (size_t *)calloc(info.nlist, sizeof(size_t));
    if (!ccount) { snprintf(err, ecap, "fractalsql: out of memory"); goto done; }
    for (size_t r = 0; r < ec.n; r++) ccount[ec.cell[r]]++;
    x = fsql_ivf_index_new(m);
    if (!x) { snprintf(err, ecap, "fractalsql: out of memory"); goto done; }
    cellbuf = (uint8_t *)malloc(ec.n * info.code_bytes + 1); idbuf = (int64_t *)malloc(ec.n * sizeof(int64_t) + 1);
    idbytes = (uint8_t *)malloc(ec.n * 8 + 1);
    if (!cellbuf || !idbuf || !idbytes) { snprintf(err, ecap, "fractalsql: out of memory"); goto done; }

    if (fi_exec(db, "SAVEPOINT fractal_idx_build", err, ecap)) goto done;
    sqlite3_stmt *ins = NULL;
    if (sqlite3_prepare_v2(db, "INSERT INTO fractal_index_cells(name,generation,cell,n,ids,codes) VALUES(?1,?2,?3,?4,?5,?6)", -1, &ins, NULL) != SQLITE_OK) {
        snprintf(err, ecap, "fractalsql: %s", sqlite3_errmsg(db)); fi_exec(db, "ROLLBACK TO fractal_idx_build; RELEASE fractal_idx_build", err, ecap); goto done; }
    int fail = 0;
    for (uint32_t c = 0; c < info.nlist && !fail; c++) {
        size_t k = 0;
        for (size_t r = 0; r < ec.n; r++)
            if (ec.cell[r] == c) { idbuf[k] = ec.rowid[r]; memcpy(cellbuf + k * info.code_bytes, ec.codes + r * info.code_bytes, info.code_bytes); put_le64(idbytes + k * 8, ec.rowid[r]); k++; }
        if (fsql_ivf_index_set_cell(x, c, idbuf, cellbuf, k) != FSQL_OK) { snprintf(err, ecap, "fractalsql: out of memory"); fail = 1; break; }
        sqlite3_reset(ins); sqlite3_bind_text(ins, 1, name, -1, SQLITE_STATIC); sqlite3_bind_int(ins, 2, generation); sqlite3_bind_int(ins, 3, (int)c);
        sqlite3_bind_int64(ins, 4, (sqlite3_int64)k); sqlite3_bind_blob(ins, 5, idbytes, (int)(k * 8), SQLITE_STATIC);
        sqlite3_bind_blob(ins, 6, cellbuf, (int)(k * info.code_bytes), SQLITE_STATIC);
        if (sqlite3_step(ins) != SQLITE_DONE) { snprintf(err, ecap, "fractalsql: writing cell %u: %s", c, sqlite3_errmsg(db)); fail = 1; }
    }
    sqlite3_finalize(ins);
    if (fail) { char e2[200]; fi_exec(db, "ROLLBACK TO fractal_idx_build; RELEASE fractal_idx_build", e2, sizeof e2); goto done; }

    if (want_calib && ec.corpus) {
        double target = fi_opt_num(opts, "target_recall", 0.95); if (target > 1.0) target = 1.0;
        /* raw (un-normalised) float rows are not kept; the normalised copy doubles as the query set (the index normalises queries) */
        calib_rc = fi_calibrate(x, &info, ec.corpus, ec.corpus, ec.rowid, ec.n, D, target, (unsigned)fi_opt_num(opts, "calibration_samples", 200), seed, fmt, calib, sizeof calib, &calibrated_nprobe);
    } else if (want_calib) {
        snprintf(calib, sizeof calib, "{\"skipped\":\"corpus too large to hold for exact ground truth; default nprobe 16\"}");
    }
    {
        char ts[40]; fi_utc_now(ts, sizeof ts);
        sqlite3_stmt *ms = NULL;
        if (sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO fractal_index_meta(name,tbl,col,dim,metric,format,nlist,pca_dim,rows,max_rowid,model,seed,generation,format_version,options,built_at,nprobe_default,calib,model_blob)"
                                   " VALUES(?1,?2,?3,?4,'cosine',?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18)", -1, &ms, NULL) != SQLITE_OK) {
            snprintf(err, ecap, "fractalsql: %s", sqlite3_errmsg(db)); char e2[200]; fi_exec(db, "ROLLBACK TO fractal_idx_build; RELEASE fractal_idx_build", e2, sizeof e2); goto done; }
        sqlite3_bind_text(ms, 1, name, -1, SQLITE_STATIC); sqlite3_bind_text(ms, 2, tbl, -1, SQLITE_STATIC); sqlite3_bind_text(ms, 3, col, -1, SQLITE_STATIC);
        sqlite3_bind_int(ms, 4, D); sqlite3_bind_text(ms, 5, FI_FMT_NAME[fmt], -1, SQLITE_STATIC); sqlite3_bind_int(ms, 6, (int)info.nlist); sqlite3_bind_int(ms, 7, (int)info.pca_dim);
        sqlite3_bind_int64(ms, 8, (sqlite3_int64)ec.n); sqlite3_bind_int64(ms, 9, (sqlite3_int64)ec.max_rowid); sqlite3_bind_text(ms, 10, model, -1, SQLITE_STATIC);
        sqlite3_bind_int64(ms, 11, (sqlite3_int64)seed); sqlite3_bind_int(ms, 12, generation); sqlite3_bind_int(ms, 13, FI_FORMAT_VERSION);
        sqlite3_bind_text(ms, 14, opts ? opts : "{}", -1, SQLITE_STATIC); sqlite3_bind_text(ms, 15, ts, -1, SQLITE_STATIC);
        sqlite3_bind_int(ms, 16, calibrated_nprobe); sqlite3_bind_text(ms, 17, calib, -1, SQLITE_STATIC); sqlite3_bind_blob(ms, 18, blob, (int)blen, SQLITE_STATIC);
        int sr = sqlite3_step(ms); sqlite3_finalize(ms);
        if (sr != SQLITE_DONE) { snprintf(err, ecap, "fractalsql: writing index metadata: %s", sqlite3_errmsg(db)); char e2[200]; fi_exec(db, "ROLLBACK TO fractal_idx_build; RELEASE fractal_idx_build", e2, sizeof e2); goto done; }
        sqlite3_stmt *ds = NULL;
        if (sqlite3_prepare_v2(db, "DELETE FROM fractal_index_cells WHERE name=?1 AND generation<?2", -1, &ds, NULL) == SQLITE_OK) {
            sqlite3_bind_text(ds, 1, name, -1, SQLITE_STATIC); sqlite3_bind_int(ds, 2, generation); sqlite3_step(ds); sqlite3_finalize(ds); }
    }
    if (fi_exec(db, "RELEASE fractal_idx_build", err, ecap)) goto done;
    fi_forget(S, name);
    {
        int n = snprintf(out, ocap, "{\"name\":\"%s\",\"table\":\"%s\",\"column\":\"%s\",\"format\":\"%s\",\"dim\":%d,\"rows\":%zu,\"nlist\":%u,\"pca_dim\":%u,\"generation\":%d,\"bytes\":%zu",
                         name, tbl, col, FI_FMT_NAME[fmt], D, ec.n, info.nlist, info.pca_dim, generation, ec.n * info.code_bytes);
        if (n > 0 && (size_t)n < ocap && calib_rc == 0 && calibrated_nprobe > 0)
            snprintf(out + n, ocap - (size_t)n, ",\"calibrated_nprobe\":%d}", calibrated_nprobe);
        else if (n > 0 && (size_t)n + 2 < ocap) { out[n] = '}'; out[n + 1] = 0; }
    }
    rc = 0;
done:
    free(ec.rowid); free(ec.cell); free(ec.codes); free(ec.corpus);
    free(ccount); free(cellbuf); free(idbuf); free(idbytes);
    if (x) fsql_ivf_index_free(x);
    fsql_ivf_model_free(m); fsql_ivf_free(blob);
    return rc;
}

/* ---------------------------------------------------------------- a small string builder, and the index's health */


typedef struct { char *s; size_t len, cap; int bad; } FiSb;

static void fi_sb_put(FiSb *b, const char *z)
{
    size_t n = strlen(z);
    if (b->bad) return;
    if (b->len + n + 1 > b->cap) {
        size_t nc = b->cap ? b->cap : 256;
        while (nc < b->len + n + 1) nc *= 2;
        char *p = (char *)realloc(b->s, nc);
        if (!p) { b->bad = 1; return; }
        b->s = p; b->cap = nc;
    }
    memcpy(b->s + b->len, z, n + 1); b->len += n;
}

static void fi_sb_putf(FiSb *b, const char *fmt, ...)
{
    char tmp[600];
    va_list ap; va_start(ap, fmt);
    vsnprintf(tmp, sizeof tmp, fmt, ap);
    va_end(ap);
    fi_sb_put(b, tmp);
}

/* An index whose cells were trained on earlier rows, or whose recall never reached its target, deserves a word. These are the
 * thresholds behind the status and the advice in fractal_index_info; they are advice, never an error. */
#define FI_REFRESH_MAX_FRAC   0.25     /* more than this fraction of the rows added since the build: rebuild, do not just refresh */
#define FI_DELETED_MAX_FRAC   0.20     /* more than this fraction deleted: the cells hold many dead entries */

typedef struct {
    int64_t now, maxnow, added, deleted;
    int     stale, has_delta, have_calib, reaches_target, missing;
    double  target, recall;
} FiHealth;

/* The calibration JSON the build stored: whether it reached its target, the target, and the recall at the recommended nprobe. */
static void fi_calib_facts(const char *calib, FiHealth *h)
{
    const char *p = calib ? strstr(calib, "\"reaches_target\":") : NULL;
    h->have_calib = p != NULL;
    if (!p) return;
    h->reaches_target = strncmp(p + 17, "true", 4) == 0;
    const char *t = strstr(calib, "\"target\":");
    h->target = t ? strtod(t + 9, NULL) : 0.95;
    const char *r = strstr(calib, "\"recommended_nprobe\":");
    if (r) {
        long np = strtol(r + 21, NULL, 10);
        char key[48]; snprintf(key, sizeof key, "\"nprobe\":%ld,\"recall\":", np);
        const char *e = strstr(calib, key);
        if (e) h->recall = strtod(e + strlen(key), NULL);
    }
}

static void fi_health(sqlite3 *db, const FIdx *m, const char *calib, FiHealth *h)
{
    memset(h, 0, sizeof *h);
    char sql[300];
    snprintf(sql, sizeof sql, "SELECT count(*), coalesce(max(rowid),0) FROM \"%s\" WHERE \"%s\" IS NOT NULL", m->tbl, m->col);
    sqlite3_stmt *s = NULL;
    h->now = -1;
    if (sqlite3_prepare_v2(db, sql, -1, &s, NULL) == SQLITE_OK && sqlite3_step(s) == SQLITE_ROW) { h->now = sqlite3_column_int64(s, 0); h->maxnow = sqlite3_column_int64(s, 1); }
    sqlite3_finalize(s);
    if (h->now < 0) {                         /* the catalog outlives the table it indexes: a missing table or column is "orphaned", not an error */
        h->missing = 1; h->deleted = m->rows; fi_calib_facts(calib, h);
        return;
    }
    snprintf(sql, sizeof sql, "SELECT count(*) FROM \"%s\" WHERE \"%s\" IS NOT NULL AND rowid > ?1", m->tbl, m->col);
    s = NULL;
    if (sqlite3_prepare_v2(db, sql, -1, &s, NULL) == SQLITE_OK) {
        sqlite3_bind_int64(s, 1, m->max_rowid);
        if (sqlite3_step(s) == SQLITE_ROW) h->added = sqlite3_column_int64(s, 0);
    }
    sqlite3_finalize(s);
    h->deleted = m->rows - (h->now - h->added);
    if (h->deleted < 0) h->deleted = 0;
    h->has_delta = h->added > 0;
    h->stale = h->now != m->rows || h->maxnow != m->max_rowid;
    fi_calib_facts(calib, h);
}

/* ready | stale | degraded | empty: the most important thing to know first. "stale" here means there is something to do (rows were added, or many
 * were deleted); the raw "stale" flag in fractal_index_info is true for any change, including a few deleted rows that the verify step
 * already drops from results, which need no action. */
static const char *fi_status(const FIdx *m, const FiHealth *h)
{
    double rows = m->rows > 0 ? (double)m->rows : 1.0;
    if (h->missing) return "orphaned";
    if (h->now == 0) return "empty";
    if (h->have_calib && !h->reaches_target) return "degraded";
    if (h->added > 0 || (h->deleted > 0 && (double)h->deleted / rows > FI_DELETED_MAX_FRAC)) return "stale";
    return "ready";
}

/* The advice list as a JSON array body (no brackets): every applicable item, most useful first. */
static void fi_advice(const FIdx *m, const FiHealth *h, FiSb *b)
{
    int n = 0;
    double rows = m->rows > 0 ? (double)m->rows : 1.0;
    if (h->missing) { fi_sb_putf(b, "\"the table %s or its column %s no longer exists; fractal_index_drop removes the index\"", m->tbl, m->col); return; }
    if (h->now == 0) {
        fi_sb_put(b, "\"the table has no vectors; load rows and build the index again\""); n++;
    }
    if (h->have_calib && !h->reaches_target) {
        fi_sb_putf(b, "%s\"the build's calibration reached recall %.2f against a target of %.2f; %s\"", n++ ? "," : "", h->recall, h->target,
                   (m->fmt == FSQL_IVF_FMT_INT8 || m->fmt == FSQL_IVF_FMT_INT4)
                       ? "rebuild with vector_format FP16 or FP32, or search with a larger rerank"
                       : "rebuild with a smaller nlist, or lower the target");
    }
    if (h->now > 0 && h->added > 0 && (double)h->added / rows > FI_REFRESH_MAX_FRAC) {
        fi_sb_putf(b, "%s\"rebuild: %.0f%% of the rows (%lld) were added since the build, more than the cells were trained for\"", n++ ? "," : "",
                   100.0 * (double)h->added / rows, (long long)h->added);
    } else if (h->added > 0) {
        fi_sb_putf(b, "%s\"refresh: %lld rows (%.0f%% of the index) were added since the build; fractal_index_refresh folds them in\"", n++ ? "," : "",
                   (long long)h->added, 100.0 * (double)h->added / rows);
    }
    if (h->deleted > 0 && (double)h->deleted / rows > FI_DELETED_MAX_FRAC) {
        fi_sb_putf(b, "%s\"rebuild: %lld rows (%.0f%%) were deleted since the build; they are dropped from results but still held in the cells\"", n++ ? "," : "",
                   (long long)h->deleted, 100.0 * (double)h->deleted / rows);
    }
}

/* ---------------------------------------------------------------- refresh */

/* Folds the rows added since the build (rowid above the watermark) into the cells: each new row is encoded with the index's existing
 * model (no retraining) and appended to its cell, in a NEW generation written in one SAVEPOINT, so a reader only ever sees a
 * complete generation. Deleted rows and rows whose vector changed are not touched: deleted rows are already dropped by the verify
 * step, and a changed vector needs fractal_index_rebuild (fractal_index_info says which one it recommends). */
static int fi_refresh(FIdxState *S, sqlite3 *db, const char *name, char *out, size_t ocap, char *err, size_t ecap)
{
    if (fi_ensure_tables(db, err, ecap)) return -1;
    FIdx *x = fi_load(S, db, name, err, ecap);
    if (!x) return -1;
    fsql_ivf_info_t info;
    if (fsql_ivf_model_info(x->m, &info) != FSQL_OK) { snprintf(err, ecap, "fractalsql: index '%s' has a corrupt model; rebuild it", name); return -1; }
    char tbl[64], col[64]; snprintf(tbl, sizeof tbl, "%s", x->tbl); snprintf(col, sizeof col, "%s", x->col);
    int64_t old_rows = x->rows, old_max = x->max_rowid; int old_gen = x->generation, nlist = x->nlist;

    FiEncodeCtx ec; memset(&ec, 0, sizeof ec);
    ec.m = x->m; ec.code_bytes = info.code_bytes; ec.dim = x->dim; ec.max_rowid = old_max;
    int dd = x->dim;
    if (fi_scan_rows_after(db, tbl, col, old_max, &dd, fi_cb_encode, &ec, err, ecap) != 0) {
        free(ec.rowid); free(ec.cell); free(ec.codes);
        if (err[0] == 0) snprintf(err, ecap, "fractalsql: out of memory or over the %zu MiB build limit", (size_t)(FI_MAX_BYTES >> 20));
        return -1;
    }
    int rc = -1;
    uint8_t *mi = NULL, *mc = NULL;
    if (ec.n == 0) {
        snprintf(out, ocap, "{\"name\":\"%s\",\"added\":0,\"rows\":%lld,\"generation\":%d,\"refreshed\":false}", name, (long long)old_rows, old_gen);
        free(ec.rowid); free(ec.cell); free(ec.codes);
        return 0;
    }
    int new_gen = old_gen + 1;
    size_t *add = (size_t *)calloc((size_t)nlist, sizeof(size_t));
    if (!add) { snprintf(err, ecap, "fractalsql: out of memory"); goto done; }
    for (size_t r = 0; r < ec.n; r++) add[ec.cell[r]]++;
    if (fi_exec(db, "SAVEPOINT fractal_idx_refresh", err, ecap)) goto done;
    char e2[200];
    {
        sqlite3_stmt *cp = NULL;
        if (sqlite3_prepare_v2(db, "INSERT INTO fractal_index_cells(name,generation,cell,n,ids,codes) SELECT name,?2,cell,n,ids,codes FROM fractal_index_cells WHERE name=?1 AND generation=?3",
                               -1, &cp, NULL) != SQLITE_OK) { snprintf(err, ecap, "fractalsql: %s", sqlite3_errmsg(db)); goto rollback; }
        sqlite3_bind_text(cp, 1, name, -1, SQLITE_STATIC); sqlite3_bind_int(cp, 2, new_gen); sqlite3_bind_int(cp, 3, old_gen);
        int sr = sqlite3_step(cp); sqlite3_finalize(cp);
        if (sr != SQLITE_DONE) { snprintf(err, ecap, "fractalsql: copying the cells: %s", sqlite3_errmsg(db)); goto rollback; }
    }
    {
        sqlite3_stmt *rd = NULL, *up = NULL;
        if (sqlite3_prepare_v2(db, "SELECT n,ids,codes FROM fractal_index_cells WHERE name=?1 AND generation=?2 AND cell=?3", -1, &rd, NULL) != SQLITE_OK ||
            sqlite3_prepare_v2(db, "UPDATE fractal_index_cells SET n=?4, ids=?5, codes=?6 WHERE name=?1 AND generation=?2 AND cell=?3", -1, &up, NULL) != SQLITE_OK) {
            snprintf(err, ecap, "fractalsql: %s", sqlite3_errmsg(db)); sqlite3_finalize(rd); sqlite3_finalize(up); goto rollback; }
        int fail = 0;
        for (int c = 0; c < nlist && !fail; c++) {
            if (add[c] == 0) continue;
            sqlite3_reset(rd); sqlite3_bind_text(rd, 1, name, -1, SQLITE_STATIC); sqlite3_bind_int(rd, 2, new_gen); sqlite3_bind_int(rd, 3, c);
            if (sqlite3_step(rd) != SQLITE_ROW) { snprintf(err, ecap, "fractalsql: index '%s' is missing cell %d", name, c); fail = 1; break; }
            int64_t n0 = sqlite3_column_int64(rd, 0);
            int ib = sqlite3_column_bytes(rd, 1), cb = sqlite3_column_bytes(rd, 2);
            const uint8_t *ip = (const uint8_t *)sqlite3_column_blob(rd, 1), *cp2 = (const uint8_t *)sqlite3_column_blob(rd, 2);
            if (n0 < 0 || ib < 0 || cb < 0 || (int64_t)ib / 8 != n0 || (int64_t)cb / (int64_t)info.code_bytes != n0) { snprintf(err, ecap, "fractalsql: index '%s' is corrupt (cell %d)", name, c); fail = 1; break; }
            size_t nn = (size_t)n0 + add[c];
            free(mi); free(mc);
            mi = (uint8_t *)malloc(nn * 8 + 1); mc = (uint8_t *)malloc(nn * info.code_bytes + 1);
            if (!mi || !mc) { snprintf(err, ecap, "fractalsql: out of memory"); fail = 1; break; }
            if (ib > 0) memcpy(mi, ip, (size_t)ib);
            if (cb > 0) memcpy(mc, cp2, (size_t)cb);
            size_t k = (size_t)n0;
            for (size_t r = 0; r < ec.n; r++)
                if (ec.cell[r] == (uint32_t)c) { put_le64(mi + k * 8, ec.rowid[r]); memcpy(mc + k * info.code_bytes, ec.codes + r * info.code_bytes, info.code_bytes); k++; }
            sqlite3_reset(up); sqlite3_bind_text(up, 1, name, -1, SQLITE_STATIC); sqlite3_bind_int(up, 2, new_gen); sqlite3_bind_int(up, 3, c);
            sqlite3_bind_int64(up, 4, (sqlite3_int64)nn); sqlite3_bind_blob(up, 5, mi, (int)(nn * 8), SQLITE_STATIC); sqlite3_bind_blob(up, 6, mc, (int)(nn * info.code_bytes), SQLITE_STATIC);
            if (sqlite3_step(up) != SQLITE_DONE) { snprintf(err, ecap, "fractalsql: writing cell %d: %s", c, sqlite3_errmsg(db)); fail = 1; }
        }
        sqlite3_finalize(rd); sqlite3_finalize(up);
        if (fail) goto rollback;
    }
    {
        sqlite3_stmt *ms = NULL;
        if (sqlite3_prepare_v2(db, "UPDATE fractal_index_meta SET rows=?2, max_rowid=?3, generation=?4 WHERE name=?1", -1, &ms, NULL) != SQLITE_OK) { snprintf(err, ecap, "fractalsql: %s", sqlite3_errmsg(db)); goto rollback; }
        sqlite3_bind_text(ms, 1, name, -1, SQLITE_STATIC); sqlite3_bind_int64(ms, 2, (sqlite3_int64)(old_rows + (int64_t)ec.n)); sqlite3_bind_int64(ms, 3, (sqlite3_int64)ec.max_rowid); sqlite3_bind_int(ms, 4, new_gen);
        int sr = sqlite3_step(ms); sqlite3_finalize(ms);
        if (sr != SQLITE_DONE) { snprintf(err, ecap, "fractalsql: writing index metadata: %s", sqlite3_errmsg(db)); goto rollback; }
        sqlite3_stmt *ds = NULL;
        if (sqlite3_prepare_v2(db, "DELETE FROM fractal_index_cells WHERE name=?1 AND generation<?2", -1, &ds, NULL) == SQLITE_OK) {
            sqlite3_bind_text(ds, 1, name, -1, SQLITE_STATIC); sqlite3_bind_int(ds, 2, new_gen); sqlite3_step(ds); sqlite3_finalize(ds); }
    }
    if (fi_exec(db, "RELEASE fractal_idx_refresh", err, ecap)) goto rollback;
    fi_forget(S, name);
    snprintf(out, ocap, "{\"name\":\"%s\",\"added\":%zu,\"rows\":%lld,\"generation\":%d,\"max_rowid\":%lld,\"refreshed\":true}",
             name, ec.n, (long long)(old_rows + (int64_t)ec.n), new_gen, (long long)ec.max_rowid);
    rc = 0;
    goto done;
rollback:
    fi_exec(db, "ROLLBACK TO fractal_idx_refresh; RELEASE fractal_idx_refresh", e2, sizeof e2);
done:
    free(add); free(mi); free(mc);
    free(ec.rowid); free(ec.cell); free(ec.codes);
    return rc;
}

/* ---------------------------------------------------------------- SQL functions */

static void fi_err(sqlite3_context *c, const char *m) { sqlite3_result_error(c, m, -1); }

static void fi_create_fn(sqlite3_context *ctx, int argc, sqlite3_value **argv)
{
    FIdxState *S = (FIdxState *)sqlite3_user_data(ctx);
    FSQL_REFUSE_IN_GENERATED_SQL(ctx, S->st, "fractal_index_create");
    if (!fi_ivf_available()) { fi_err(ctx, FI_NO_CORE_MSG); return; }
    const char *tbl = (const char *)sqlite3_value_text(argv[0]), *col = (const char *)sqlite3_value_text(argv[1]);
    const char *opts = argc > 2 ? (const char *)sqlite3_value_text(argv[2]) : "{}";
    if (!opts) opts = "{}";
    if (!fi_ident_ok(tbl) || !fi_ident_ok(col)) { fi_err(ctx, "fractalsql: table and column must be plain identifiers"); return; }
    char name[64];
    if (!fi_opt_str(opts, "name", name, sizeof name)) snprintf(name, sizeof name, "%.28s_%.28s", tbl, col);
    if (!fi_ident_ok(name)) { fi_err(ctx, "fractalsql: index name must be a plain identifier"); return; }
    char out[1400], err[300];
    err[0] = 0;
    if (fi_build(S, S->st->db, name, tbl, col, opts, 0, out, sizeof out, err, sizeof err)) { fi_err(ctx, err[0] ? err : "fractalsql: index build failed"); return; }
    sqlite3_result_text(ctx, out, -1, SQLITE_TRANSIENT);
}

static void fi_rebuild_fn(sqlite3_context *ctx, int argc, sqlite3_value **argv)
{
    (void)argc;
    FIdxState *S = (FIdxState *)sqlite3_user_data(ctx);
    FSQL_REFUSE_IN_GENERATED_SQL(ctx, S->st, "fractal_index_rebuild");
    if (!fi_ivf_available()) { fi_err(ctx, FI_NO_CORE_MSG); return; }
    const char *name = (const char *)sqlite3_value_text(argv[0]);
    char opt[512], out[1400], err[300];
    FIdx m;
    err[0] = 0;
    if (!name || !fi_ident_ok(name) || fi_read_meta(S->st->db, name, &m, opt, sizeof opt) != 0) { fi_err(ctx, "fractalsql: no such index"); return; }
    if (fi_build(S, S->st->db, name, m.tbl, m.col, opt, 1, out, sizeof out, err, sizeof err)) { fi_err(ctx, err[0] ? err : "fractalsql: index rebuild failed"); return; }
    sqlite3_result_text(ctx, out, -1, SQLITE_TRANSIENT);
}

static void fi_drop_fn(sqlite3_context *ctx, int argc, sqlite3_value **argv)
{
    (void)argc;
    FIdxState *S = (FIdxState *)sqlite3_user_data(ctx);
    FSQL_REFUSE_IN_GENERATED_SQL(ctx, S->st, "fractal_index_drop");
    const char *name = (const char *)sqlite3_value_text(argv[0]);
    char err[300];
    if (!name || !fi_ident_ok(name)) { fi_err(ctx, "fractalsql: invalid index name"); return; }
    sqlite3 *db = S->st->db;
    FIdx m;
    if (fi_ensure_tables(db, err, sizeof err)) { fi_err(ctx, err); return; }
    if (fi_read_meta(db, name, &m, NULL, 0) != 0) { fi_err(ctx, "fractalsql: no such index"); return; }
    sqlite3_stmt *s = NULL;
    if (sqlite3_prepare_v2(db, "DELETE FROM fractal_index_cells WHERE name=?1", -1, &s, NULL) == SQLITE_OK) { sqlite3_bind_text(s, 1, name, -1, SQLITE_STATIC); sqlite3_step(s); sqlite3_finalize(s); }
    if (sqlite3_prepare_v2(db, "DELETE FROM fractal_index_meta WHERE name=?1", -1, &s, NULL) == SQLITE_OK) { sqlite3_bind_text(s, 1, name, -1, SQLITE_STATIC); sqlite3_step(s); sqlite3_finalize(s); }
    fi_forget(S, name);
    sqlite3_result_int(ctx, 1);
}

static void fi_refresh_fn(sqlite3_context *ctx, int argc, sqlite3_value **argv)
{
    (void)argc;
    FIdxState *S = (FIdxState *)sqlite3_user_data(ctx);
    FSQL_REFUSE_IN_GENERATED_SQL(ctx, S->st, "fractal_index_refresh");
    const char *name = (const char *)sqlite3_value_text(argv[0]);
    if (!name || !fi_ident_ok(name)) { fi_err(ctx, "fractalsql: invalid index name"); return; }
    char out[512] = "", err[300] = "";
    if (fi_refresh(S, S->st->db, name, out, sizeof out, err, sizeof err) != 0) { fi_err(ctx, err[0] ? err : "fractalsql: refresh failed"); return; }
    sqlite3_result_text(ctx, out, -1, SQLITE_TRANSIENT);
}

/* For agent_use_index = auto: an index on tbl.col that is ready (nothing stale beyond a refresh), calibrated and at its target recall, on a
 * table with at least min_rows rows. 0 when there is no such index, no catalog yet, or the core carries no IVF. */
int fsql_index_ready_for_agents(sqlite3 *db, const char *tbl, const char *col, long long min_rows)
{
    char name[64], calib[4096] = "{}";
    FIdx m;
    if (!fi_ivf_available() || !fi_find_name(db, tbl, col, name, sizeof name)) return 0;
    if (fi_read_meta(db, name, &m, NULL, 0) != 0) return 0;
    sqlite3_stmt *t = NULL;
    if (sqlite3_prepare_v2(db, "SELECT calib FROM fractal_index_meta WHERE name=?1", -1, &t, NULL) == SQLITE_OK) {
        sqlite3_bind_text(t, 1, name, -1, SQLITE_STATIC);
        if (sqlite3_step(t) == SQLITE_ROW) { const char *c = (const char *)sqlite3_column_text(t, 0); if (c && *c) snprintf(calib, sizeof calib, "%s", c); }
        sqlite3_finalize(t);
    }
    FiHealth h;
    fi_health(db, &m, calib, &h);
    if (strcmp(fi_status(&m, &h), "ready") != 0) return 0;
    if (!h.have_calib || !h.reaches_target) return 0;
    return (long long)h.now >= min_rows;
}

/* fractal_index_ensure(table, column [, options]) -> JSON {name, action, status, generation, rows}
 * One call that leaves an index that is fit to use, and does nothing when it already is. It is meant for a setup script or a scheduled job,
 * never for a search. action is:
 *   created    no index covered the table and column: one was built with the options
 *   refreshed  the status was stale and the advice said refresh (rows added, up to a quarter of the index)
 *   rebuilt    the advice said rebuild (more than a quarter added, more than a fifth deleted), or the status was degraded and the caller
 *              passed options (for example a different vector_format) to try again with
 *   unchanged  nothing to do: ready, empty, orphaned (the table or column is gone: it is reported, not recreated), or degraded with no new options */
static void fi_ensure_fn(sqlite3_context *ctx, int argc, sqlite3_value **argv)
{
    FIdxState *S = (FIdxState *)sqlite3_user_data(ctx);
    FSQL_REFUSE_IN_GENERATED_SQL(ctx, S->st, "fractal_index_ensure");
    if (!fi_ivf_available()) { fi_err(ctx, FI_NO_CORE_MSG); return; }
    sqlite3 *db = S->st->db;
    const char *tbl = (const char *)sqlite3_value_text(argv[0]), *col = (const char *)sqlite3_value_text(argv[1]);
    const char *opts = argc > 2 ? (const char *)sqlite3_value_text(argv[2]) : "{}";
    if (!opts) opts = "{}";
    if (!fi_ident_ok(tbl) || !fi_ident_ok(col)) { fi_err(ctx, "fractalsql: table and column must be plain identifiers"); return; }
    char err[300] = "", name[64] = "", out[1400], stored[512] = "";
    const char *action = "unchanged";
    int new_opts = strcmp(opts, "{}") != 0 && *opts;
    if (fi_ensure_tables(db, err, sizeof err)) { fi_err(ctx, err); return; }
    if (!fi_find_name(db, tbl, col, name, sizeof name)) {
        if (!fi_opt_str(opts, "name", name, sizeof name)) snprintf(name, sizeof name, "%.28s_%.28s", tbl, col);
        if (!fi_ident_ok(name)) { fi_err(ctx, "fractalsql: index name must be a plain identifier"); return; }
        if (fi_build(S, db, name, tbl, col, opts, 0, out, sizeof out, err, sizeof err)) { fi_err(ctx, err[0] ? err : "fractalsql: index build failed"); return; }
        action = "created";
    } else {
        FIdx m;
        char calib[4096] = "{}";
        if (fi_read_meta(db, name, &m, stored, sizeof stored) != 0) { fi_err(ctx, "fractalsql: no such index"); return; }
        sqlite3_stmt *t = NULL;
        if (sqlite3_prepare_v2(db, "SELECT calib FROM fractal_index_meta WHERE name=?1", -1, &t, NULL) == SQLITE_OK) {
            sqlite3_bind_text(t, 1, name, -1, SQLITE_STATIC);
            if (sqlite3_step(t) == SQLITE_ROW) { const char *c = (const char *)sqlite3_column_text(t, 0); if (c && *c) snprintf(calib, sizeof calib, "%s", c); }
            sqlite3_finalize(t);
        }
        FiHealth h; fi_health(db, &m, calib, &h);
        const char *st = fi_status(&m, &h);
        double rows = m.rows > 0 ? (double)m.rows : 1.0;
        int big_add = h.added > 0 && (double)h.added / rows > FI_REFRESH_MAX_FRAC;
        int big_del = h.deleted > 0 && (double)h.deleted / rows > FI_DELETED_MAX_FRAC;
        if (!strcmp(st, "degraded")) {
            if (new_opts) {
                if (fi_build(S, db, name, m.tbl, m.col, opts, 1, out, sizeof out, err, sizeof err)) { fi_err(ctx, err[0] ? err : "fractalsql: index rebuild failed"); return; }
                action = "rebuilt";
            }
        } else if (!strcmp(st, "stale")) {
            if (big_add || big_del) {
                if (fi_build(S, db, name, m.tbl, m.col, new_opts ? opts : stored, 1, out, sizeof out, err, sizeof err)) { fi_err(ctx, err[0] ? err : "fractalsql: index rebuild failed"); return; }
                action = "rebuilt";
            } else {
                if (fi_refresh(S, db, name, out, sizeof out, err, sizeof err) != 0) { fi_err(ctx, err[0] ? err : "fractalsql: refresh failed"); return; }
                action = "refreshed";
            }
        }
    }
    /* the state after the action */
    FIdx m;
    char calib[4096] = "{}";
    if (fi_read_meta(db, name, &m, NULL, 0) != 0) { fi_err(ctx, "fractalsql: no such index"); return; }
    sqlite3_stmt *t = NULL;
    if (sqlite3_prepare_v2(db, "SELECT calib FROM fractal_index_meta WHERE name=?1", -1, &t, NULL) == SQLITE_OK) {
        sqlite3_bind_text(t, 1, name, -1, SQLITE_STATIC);
        if (sqlite3_step(t) == SQLITE_ROW) { const char *c = (const char *)sqlite3_column_text(t, 0); if (c && *c) snprintf(calib, sizeof calib, "%s", c); }
        sqlite3_finalize(t);
    }
    FiHealth h; fi_health(db, &m, calib, &h);
    char res[400];
    snprintf(res, sizeof res, "{\"name\":\"%s\",\"action\":\"%s\",\"status\":\"%s\",\"generation\":%d,\"rows\":%lld}",
             name, action, fi_status(&m, &h), m.generation, (long long)m.rows);
    sqlite3_result_text(ctx, res, -1, SQLITE_TRANSIENT);
}

static void fi_info_fn(sqlite3_context *ctx, int argc, sqlite3_value **argv)
{
    (void)argc;
    FIdxState *S = (FIdxState *)sqlite3_user_data(ctx);
    sqlite3 *db = S->st->db;
    const char *name = (const char *)sqlite3_value_text(argv[0]);
    FIdx m;
    if (!name || !fi_ident_ok(name) || fi_read_meta(db, name, &m, NULL, 0) != 0) { fi_err(ctx, "fractalsql: no such index"); return; }
    char built[40] = "", calib[4096] = "{}";
    int fv = 0; int64_t seed = 0;
    sqlite3_stmt *t = NULL;
    if (sqlite3_prepare_v2(db, "SELECT built_at, format_version, seed, calib FROM fractal_index_meta WHERE name=?1", -1, &t, NULL) == SQLITE_OK) {
        sqlite3_bind_text(t, 1, name, -1, SQLITE_STATIC);
        if (sqlite3_step(t) == SQLITE_ROW) {
            snprintf(built, sizeof built, "%s", (const char *)sqlite3_column_text(t, 0));
            fv = sqlite3_column_int(t, 1); seed = sqlite3_column_int64(t, 2);
            const char *c = (const char *)sqlite3_column_text(t, 3);
            if (c && *c) snprintf(calib, sizeof calib, "%s", c);
        }
        sqlite3_finalize(t);
    }
    FiHealth h; fi_health(db, &m, calib, &h);
    FiSb out = { 0 }, adv = { 0 };
    fi_advice(&m, &h, &adv);
    fi_sb_putf(&out,
        "{\"name\":\"%s\",\"table\":\"%s\",\"column\":\"%s\",\"metric\":\"cosine\",\"format\":\"%s\",\"dim\":%d,\"model\":\"%s\",\"nlist\":%d,\"pca_dim\":%d,\"generation\":%d,"
        "\"format_version\":%d,\"seed\":%lld,\"built_at\":\"%s\",\"rows_indexed\":%lld,\"rows_now\":%lld,\"max_rowid_indexed\":%lld,\"max_rowid_now\":%lld,"
        "\"has_delta\":%s,\"stale\":%s,\"rows_added_since_build\":%lld,\"rows_deleted_since_build\":%lld,\"status\":\"%s\",\"advice\":[",
        m.name, m.tbl, m.col, FI_FMT_NAME[m.fmt], m.dim, m.model, m.nlist, m.pca_dim, m.generation, fv, (long long)seed, built, (long long)m.rows, (long long)h.now,
        (long long)m.max_rowid, (long long)h.maxnow, h.has_delta ? "true" : "false", h.stale ? "true" : "false", (long long)h.added, (long long)h.deleted,
        fi_status(&m, &h));
    fi_sb_put(&out, adv.s ? adv.s : "");
    fi_sb_putf(&out, "],\"rerank_default\":%zu,\"nprobe_default\":%d,\"calibration\":", fi_default_rerank(m.fmt), m.nprobe_default);
    fi_sb_put(&out, calib);
    fi_sb_putf(&out, ",\"last_search\":{\"used_index\":%s,\"rows_scanned\":%lld,\"cells_probed\":%d,\"lookups\":%d}}",
        S->last_used_index ? "true" : "false", (long long)S->last_rows_scanned, S->last_cells_probed, S->last_lookups);
    free(adv.s);
    if (out.bad || !out.s) { free(out.s); sqlite3_result_error_nomem(ctx); return; }
    sqlite3_result_text(ctx, out.s, -1, SQLITE_TRANSIENT);
    free(out.s);
}

/* fractal_index_list() -> JSON array, one object per index. Reads the catalog without creating it: a database that never built an
 * index lists as []. */
static void fi_list_fn(sqlite3_context *ctx, int argc, sqlite3_value **argv)
{
    (void)argc; (void)argv;
    FIdxState *S = (FIdxState *)sqlite3_user_data(ctx);
    sqlite3 *db = S->st->db;
    FiSb out = { 0 };
    fi_sb_put(&out, "[");
    sqlite3_stmt *has = NULL; int exists = 0;
    if (sqlite3_prepare_v2(db, "SELECT 1 FROM sqlite_master WHERE type='table' AND name='fractal_index_meta'", -1, &has, NULL) == SQLITE_OK)
        exists = sqlite3_step(has) == SQLITE_ROW;
    sqlite3_finalize(has);
    if (exists) {
        sqlite3_stmt *s = NULL;
        if (sqlite3_prepare_v2(db, "SELECT name, calib FROM fractal_index_meta ORDER BY name", -1, &s, NULL) == SQLITE_OK) {
            int first = 1;
            while (sqlite3_step(s) == SQLITE_ROW) {
                char nm[64]; snprintf(nm, sizeof nm, "%s", (const char *)sqlite3_column_text(s, 0));
                const char *calib = (const char *)sqlite3_column_text(s, 1);
                FIdx m;
                if (fi_read_meta(db, nm, &m, NULL, 0) != 0) continue;
                FiHealth h; fi_health(db, &m, calib, &h);
                fi_sb_putf(&out, "%s{\"name\":\"%s\",\"table\":\"%s\",\"column\":\"%s\",\"format\":\"%s\",\"dim\":%d,\"rows\":%lld,"
                                 "\"rows_now\":%lld,\"stale\":%s,\"status\":\"%s\",\"generation\":%d}",
                           first ? "" : ",", m.name, m.tbl, m.col, FI_FMT_NAME[m.fmt], m.dim, (long long)m.rows, (long long)h.now,
                           h.stale ? "true" : "false", fi_status(&m, &h), m.generation);
                first = 0;
            }
        }
        sqlite3_finalize(s);
    }
    fi_sb_put(&out, "]");
    if (out.bad || !out.s) { free(out.s); sqlite3_result_error_nomem(ctx); return; }
    sqlite3_result_text(ctx, out.s, -1, SQLITE_TRANSIENT);
    free(out.s);
}

/* result accumulator: sorted ascending by distance, ties by rowid, bounded */
typedef struct { int64_t id; double d; } FiCand;

static void fi_ins(FiCand *a, int *n, int cap, FiCand c)
{
    int i;
    if (*n == cap) {
        FiCand *w = &a[cap - 1];
        if (!(c.d < w->d || (c.d == w->d && c.id < w->id))) return;
        i = cap - 1;
    } else i = (*n)++;
    while (i > 0 && (a[i - 1].d > c.d || (a[i - 1].d == c.d && a[i - 1].id > c.id))) { a[i] = a[i - 1]; i--; }
    a[i] = c;
}

static int fi_fetch(sqlite3_stmt *s, int64_t id, double *out)
{
    sqlite3_reset(s); sqlite3_bind_int64(s, 1, id);
    int d = 0;
    if (sqlite3_step(s) == SQLITE_ROW) { d = fsql_parse_value_to_doubles(sqlite3_column_value(s, 0), out, FI_MAXDIM); if (d < 0) d = 0; }
    return d;
}

/* The ids option: restrict a search to a set of rowids (a JSON array, for example from json_group_array(rowid) over an ordinary
 * WHERE). A short list is scanned exactly; a long one goes through the index and is filtered, and when that leaves fewer than k rows the
 * list is scanned exactly, so the answer is never short just because the index's shortlist missed the set. */
#define FI_IDS_MAX         1000000
#define FI_IDS_EXACT_MAX   4096

typedef struct { int64_t *v; size_t n; } FiIds;

static int fi_ids_cmp(const void *a, const void *b)
{
    int64_t x = *(const int64_t *)a, y = *(const int64_t *)b;
    return x < y ? -1 : (x > y ? 1 : 0);
}

static int fi_ids_has(const FiIds *s, int64_t id)
{
    size_t lo = 0, hi = s->n;
    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2;
        if (s->v[mid] == id) return 1;
        if (s->v[mid] < id) lo = mid + 1; else hi = mid;
    }
    return 0;
}

/* 0: no ids option; 1: parsed (sorted, de-duplicated); -1: malformed (err filled). */
static int fi_ids_parse(const char *opts, FiIds *out, char *err, size_t ecap)
{
    const char *p = fsql_json_top_level_value(opts, "ids");
    if (!p) return 0;
    while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p++;
    if (*p != '[') { snprintf(err, ecap, "fractalsql: ids must be a JSON array of integer rowids"); return -1; }
    p++;
    size_t cap = 64, n = 0;
    int64_t *v = (int64_t *)malloc(cap * sizeof(int64_t));
    if (!v) { snprintf(err, ecap, "fractalsql: out of memory"); return -1; }
    for (;;) {
        while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p++;
        if (*p == ']') break;
        char *e;
        errno = 0;
        long long x = strtoll(p, &e, 10);
        if (e == p || errno == ERANGE) { free(v); snprintf(err, ecap, "fractalsql: ids must be a JSON array of integer rowids"); return -1; }
        if (n >= FI_IDS_MAX) { free(v); snprintf(err, ecap, "fractalsql: ids holds more than %d rowids", FI_IDS_MAX); return -1; }
        if (n == cap) { cap *= 2; int64_t *nv = (int64_t *)realloc(v, cap * sizeof(int64_t)); if (!nv) { free(v); snprintf(err, ecap, "fractalsql: out of memory"); return -1; } v = nv; }
        v[n++] = (int64_t)x;
        p = e;
        while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p++;
        if (*p == ',') { p++; continue; }
        if (*p == ']') break;
        free(v); snprintf(err, ecap, "fractalsql: ids must be a JSON array of integer rowids"); return -1;
    }
    qsort(v, n, sizeof(int64_t), fi_ids_cmp);
    size_t w = 0;
    for (size_t i = 0; i < n; i++) if (w == 0 || v[i] != v[w - 1]) v[w++] = v[i];
    out->v = v; out->n = w;
    return 1;
}

/* Scans exactly the rows the ids name. Returns 0, or -1 with err filled (a query of another dimension than a stored vector). */
static int fi_exact_over_ids(sqlite3 *db, const char *tbl, const char *col, const FiIds *ids, const double *q, int D, double *dv,
                             FiCand *res, int *nres, int k, int64_t *scanned, char *err, size_t ecap)
{
    char sql[300];
    snprintf(sql, sizeof sql, "SELECT \"%s\" FROM \"%s\" WHERE rowid=?1", col, tbl);
    sqlite3_stmt *look = NULL;
    if (sqlite3_prepare_v2(db, sql, -1, &look, NULL) != SQLITE_OK) { snprintf(err, ecap, "fractalsql: cannot read the table"); return -1; }
    *nres = 0;
    for (size_t i = 0; i < ids->n; i++) {
        int d = fi_fetch(look, ids->v[i], dv);
        if (d != D) { if (d > 0) { sqlite3_finalize(look); snprintf(err, ecap, "fractalsql: query dim mismatch with vector"); return -1; } continue; }
        FiCand c = { ids->v[i], fsqlp_cosine_distance_d(dv, q, (size_t)D) };
        fi_ins(res, nres, k, c); (*scanned)++;
    }
    sqlite3_finalize(look);
    return 0;
}

static void fi_search_impl(sqlite3_context *ctx, int argc, sqlite3_value **argv, const FiIds *ids)
{
    FIdxState *S = (FIdxState *)sqlite3_user_data(ctx);
    sqlite3 *db = S->st->db;
    const char *tbl = (const char *)sqlite3_value_text(argv[0]), *col = (const char *)sqlite3_value_text(argv[1]);
    if (!tbl || !col || !fi_ident_ok(tbl) || !fi_ident_ok(col)) { fi_err(ctx, "fractalsql: table and column must be plain identifiers"); return; }
    if (sqlite3_value_type(argv[2]) == SQLITE_NULL) { sqlite3_result_null(ctx); return; }
    double *q = (double *)malloc(FI_MAXDIM * sizeof(double)), *dv = (double *)malloc(FI_MAXDIM * sizeof(double));
    if (!q || !dv) { free(q); free(dv); sqlite3_result_error_nomem(ctx); return; }
    int D = fsql_parse_value_to_doubles(argv[2], q, FI_MAXDIM);
    if (D <= 0) { free(q); free(dv); fi_err(ctx, "fractalsql: invalid query vector"); return; }
    int k = fsql_value_int(argv[3]);
    if (k < 1 || k > 1000) { free(q); free(dv); fi_err(ctx, "fractalsql: k out of range [1, 1000]"); return; }
    const char *opts = argc > 4 ? (const char *)sqlite3_value_text(argv[4]) : "{}";
    if (!opts) opts = "{}";
    int use_index = fi_opt_bool(opts, "use_index", 1), verify = fi_opt_bool(opts, "verify", 1);
    double nprobe_d = fi_opt_num(opts, "nprobe", 0);
    char qmodel[64]; int have_model = fi_opt_str(opts, "model", qmodel, sizeof qmodel);
    char iname[64] = "", err[300] = "";
    FIdx *x = NULL;
    if (use_index) {
        if (!fi_opt_str(opts, "index", iname, sizeof iname)) { if (!fi_find_name(db, tbl, col, iname, sizeof iname)) iname[0] = 0; }
        if (iname[0]) { x = fi_load(S, db, iname, err, sizeof err); if (!x) { free(q); free(dv); fi_err(ctx, err); return; } }
    }
    FiCand *res = (FiCand *)malloc(sizeof(FiCand) * (size_t)k);
    if (!res) { free(q); free(dv); sqlite3_result_error_nomem(ctx); return; }
    int nres = 0;
    char sql[300];
    int64_t scanned = 0; int cells_probed = 0, lookups = 0, used_index = 0;
    const int exact_ids = ids != NULL && (x == NULL || ids->n <= FI_IDS_EXACT_MAX);

    if (exact_ids) {
        if (x && x->dim != D) { snprintf(err, sizeof err, "fractalsql: query dimension %d does not match index '%s' dimension %d", D, x->name, x->dim); free(res); free(q); free(dv); fi_err(ctx, err); return; }
        if (fi_exact_over_ids(db, tbl, col, ids, q, D, dv, res, &nres, k, &scanned, err, sizeof err) != 0) { free(res); free(q); free(dv); fi_err(ctx, err); return; }
    } else if (!x) {
        /* exact scan fallback (what fractal_search_telemetry does) */
        snprintf(sql, sizeof sql, "SELECT rowid, \"%s\" FROM \"%s\" WHERE \"%s\" IS NOT NULL", col, tbl, col);
        sqlite3_stmt *s = NULL;
        if (sqlite3_prepare_v2(db, sql, -1, &s, NULL) != SQLITE_OK) { free(res); free(q); free(dv); fi_err(ctx, "fractalsql: cannot read the table"); return; }
        while (sqlite3_step(s) == SQLITE_ROW) {
            int d = fsql_parse_value_to_doubles(sqlite3_column_value(s, 1), dv, FI_MAXDIM);
            if (d != D) { if (d > 0) { sqlite3_finalize(s); free(res); free(q); free(dv); fi_err(ctx, "fractalsql: query dim mismatch with vector"); return; } continue; }
            FiCand c = { sqlite3_column_int64(s, 0), fsqlp_cosine_distance_d(dv, q, (size_t)D) };
            fi_ins(res, &nres, k, c); scanned++;
        }
        sqlite3_finalize(s);
    } else {
        if (x->dim != D) { snprintf(err, sizeof err, "fractalsql: query dimension %d does not match index '%s' dimension %d", D, x->name, x->dim); free(res); free(q); free(dv); fi_err(ctx, err); return; }
        if (have_model && x->model[0] && strcmp(qmodel, x->model)) {
            snprintf(err, sizeof err, "fractalsql: model '%s' does not match index '%s' (built for '%s'); rebuild the index", qmodel, x->name, x->model);
            free(res); free(q); free(dv); fi_err(ctx, err); return; }
        int nprobe = nprobe_d > 0 ? (int)(nprobe_d > 1e9 ? 1e9 : nprobe_d) : (x->nprobe_default > 0 ? x->nprobe_default : 16);
        if (nprobe < 1) nprobe = 1;
        if (nprobe > x->nlist) nprobe = x->nlist;
        size_t rr = fi_default_rerank(x->fmt);
        if (fsql_json_top_level_value(opts, "rerank")) {
            double v = fi_opt_num(opts, "rerank", (double)rr);
            if (v < 0 || v > 100000) { free(res); free(q); free(dv); fi_err(ctx, "fractalsql: rerank out of range"); return; }
            if (x->fmt == FSQL_IVF_FMT_INT4 && v < 20) { free(res); free(q); free(dv); fi_err(ctx, "fractalsql: INT4 indexes always rerank; rerank must be at least 20"); return; }
            rr = (size_t)v;
        }
        size_t R = rr > (size_t)k ? rr : (size_t)k + 5u;
        if (R > (size_t)k + 400u) R = (size_t)k + 400u;
        if (ids) R = (size_t)k + 400u;                       /* a filtered search needs a deeper shortlist to still have k rows left */
        float *qf = (float *)malloc((size_t)D * sizeof(float));
        int64_t *cid = (int64_t *)malloc(R * sizeof(int64_t));
        double *cd = (double *)malloc(R * sizeof(double));
        if (!qf || !cid || !cd) { free(qf); free(cid); free(cd); free(res); free(q); free(dv); sqlite3_result_error_nomem(ctx); return; }
        int okq = 1;
        for (int i = 0; i < D; i++) { if (!isfinite(q[i]) || fabs(q[i]) > 3.0e38) okq = 0; qf[i] = (float)q[i]; }
        size_t ncand = 0; fsql_ivf_stats_t st;
        int src = okq ? fsql_ivf_search(x->x, qf, (uint32_t)nprobe, (uint32_t)R, cid, cd, &ncand, &st) : FSQL_ERR_INVALID;
        free(qf);
        if (src != FSQL_OK) { free(cid); free(cd); free(res); free(q); free(dv); fi_err(ctx, okq ? "fractalsql: index search failed" : "fractalsql: query contains non-finite values"); return; }
        scanned = (int64_t)st.rows_scanned; cells_probed = (int)st.cells_probed; used_index = 1;
        /* delta: rows added after the build (rowid watermark), scanned exactly */
        snprintf(sql, sizeof sql, "SELECT rowid, \"%s\" FROM \"%s\" WHERE rowid > ?1 AND \"%s\" IS NOT NULL", col, tbl, col);
        sqlite3_stmt *ds = NULL;
        if (sqlite3_prepare_v2(db, sql, -1, &ds, NULL) == SQLITE_OK) {
            sqlite3_bind_int64(ds, 1, x->max_rowid);
            while (sqlite3_step(ds) == SQLITE_ROW) {
                if (ids && !fi_ids_has(ids, sqlite3_column_int64(ds, 0))) continue;
                int d = fsql_parse_value_to_doubles(sqlite3_column_value(ds, 1), dv, FI_MAXDIM);
                if (d != D) continue;
                FiCand c = { sqlite3_column_int64(ds, 0), fsqlp_cosine_distance_d(dv, q, (size_t)D) };
                fi_ins(res, &nres, k, c); scanned++;
            }
            sqlite3_finalize(ds);
        }
        /* verify the shortlist against the base table: exact distances, deleted rows dropped */
        size_t nver = (rr > 0 || ids) ? ncand : (verify ? (ncand < (size_t)k + 5u ? ncand : (size_t)k + 5u) : 0);
        if (nver > 0) {
            snprintf(sql, sizeof sql, "SELECT \"%s\" FROM \"%s\" WHERE rowid=?1", col, tbl);
            sqlite3_stmt *look = NULL;
            if (sqlite3_prepare_v2(db, sql, -1, &look, NULL) != SQLITE_OK) { free(cid); free(cd); free(res); free(q); free(dv); fi_err(ctx, "fractalsql: cannot read the table"); return; }
            for (size_t i = 0; i < nver; i++) {
                if (ids && !fi_ids_has(ids, cid[i])) continue;
                int d = fi_fetch(look, cid[i], dv); lookups++;
                if (d != D) continue;                  /* row deleted (or changed shape): dropped */
                FiCand c = { cid[i], fsqlp_cosine_distance_d(dv, q, (size_t)D) };
                fi_ins(res, &nres, k, c);
            }
            sqlite3_finalize(look);
        } else {
            for (size_t i = 0; i < ncand && (ids || (int)i < k); i++) { if (ids && !fi_ids_has(ids, cid[i])) continue; FiCand c = { cid[i], cd[i] }; fi_ins(res, &nres, k, c); }   /* approximate, verify off */
        }
        free(cid); free(cd);
        /* the filter left fewer than k rows: the set is small enough that scanning it exactly is the honest answer */
        if (ids && nres < k && (size_t)nres < ids->n) {
            if (fi_exact_over_ids(db, tbl, col, ids, q, D, dv, res, &nres, k, &scanned, err, sizeof err) != 0) { free(res); free(q); free(dv); fi_err(ctx, err); return; }
            used_index = 0;
        }
    }
    S->last_rows_scanned = scanned; S->last_cells_probed = cells_probed; S->last_used_index = used_index; S->last_lookups = lookups;
    size_t cap = 96 * (size_t)nres + 8, len = 0;
    char *out = (char *)malloc(cap);
    if (!out) { free(res); free(q); free(dv); sqlite3_result_error_nomem(ctx); return; }
    out[len++] = '[';
    for (int i = 0; i < nres; i++) {
        int n = snprintf(out + len, cap - len, "%s{\"doc_id\":%lld,\"distance\":%.17g,\"scan_pos\":%lld}", i ? "," : "", (long long)res[i].id, res[i].d, (long long)res[i].id);
        if (n < 0 || (size_t)n >= cap - len) break;
        len += (size_t)n;
    }
    out[len++] = ']'; out[len] = 0;
    sqlite3_result_text(ctx, out, (int)len, SQLITE_TRANSIENT);
    free(out); free(res); free(q); free(dv);
}

static void fi_search_fn(sqlite3_context *ctx, int argc, sqlite3_value **argv)
{
    FiIds ids = { NULL, 0 };
    char err[300] = "";
    const char *opts = argc > 4 ? (const char *)sqlite3_value_text(argv[4]) : NULL;
    int ir = opts ? fi_ids_parse(opts, &ids, err, sizeof err) : 0;
    if (ir < 0) { fi_err(ctx, err); return; }
    fi_search_impl(ctx, argc, argv, ir > 0 ? &ids : NULL);
    free(ids.v);
}

/* fractal_index_candidates(table, col, query [, options]) -> JSON array of rowids for Scout: every row of the `near` nearest
 * cells plus `per_cell` representative rows from each other cell, plus rows newer than the index (the delta). */
static void fi_cand_fn(sqlite3_context *ctx, int argc, sqlite3_value **argv)
{
    FIdxState *S = (FIdxState *)sqlite3_user_data(ctx);
    sqlite3 *db = S->st->db;
    const char *tbl = (const char *)sqlite3_value_text(argv[0]), *col = (const char *)sqlite3_value_text(argv[1]);
    if (!tbl || !col || !fi_ident_ok(tbl) || !fi_ident_ok(col)) { fi_err(ctx, "fractalsql: table and column must be plain identifiers"); return; }
    double *q = (double *)malloc(FI_MAXDIM * sizeof(double));
    if (!q) { sqlite3_result_error_nomem(ctx); return; }
    int D = fsql_parse_value_to_doubles(argv[2], q, FI_MAXDIM);
    if (D <= 0) { free(q); fi_err(ctx, "fractalsql: invalid query vector"); return; }
    const char *opts = argc > 3 ? (const char *)sqlite3_value_text(argv[3]) : "{}";
    if (!opts) opts = "{}";
    double near_d = fi_opt_num(opts, "near", 6), per_d = fi_opt_num(opts, "per_cell", 1);
    int near = (int)(near_d < 0 ? 0 : (near_d > 4096 ? 4096 : near_d)), per = (int)(per_d < 0 ? 0 : (per_d > 100000 ? 100000 : per_d));
    char iname[64] = "", err[300] = "";
    if (!fi_opt_str(opts, "index", iname, sizeof iname) && !fi_find_name(db, tbl, col, iname, sizeof iname)) { free(q); fi_err(ctx, "fractalsql: no index on this table and column"); return; }
    FIdx *x = fi_load(S, db, iname, err, sizeof err);
    if (!x) { free(q); fi_err(ctx, err); return; }
    if (x->dim != D) { free(q); fi_err(ctx, "fractalsql: query dimension does not match the index"); return; }
    float *qf = (float *)malloc((size_t)D * sizeof(float)); uint32_t *cells = (uint32_t *)malloc((size_t)(x->nlist > 0 ? x->nlist : 1) * sizeof(uint32_t));
    if (!qf || !cells) { free(q); free(qf); free(cells); sqlite3_result_error_nomem(ctx); return; }
    for (int i = 0; i < D; i++) { if (!isfinite(q[i]) || fabs(q[i]) > 3.0e38) { free(q); free(qf); free(cells); fi_err(ctx, "fractalsql: query contains non-finite values"); return; } qf[i] = (float)q[i]; }
    uint32_t nc = 0;
    int prc = fsql_ivf_probe_cells(x->m, qf, (uint32_t)(near > 0 ? near : 1), cells, &nc);
    free(qf); free(q);
    if (prc != FSQL_OK) { free(cells); fi_err(ctx, "fractalsql: probe failed"); return; }
    if (near == 0) nc = 0;
    char *isnear = (char *)calloc((size_t)x->nlist, 1);
    size_t cap = 4096, len = 0;
    char *out = (char *)malloc(cap);
    if (!isnear || !out) { free(isnear); free(out); free(cells); sqlite3_result_error_nomem(ctx); return; }
    for (uint32_t i = 0; i < nc; i++) if (cells[i] < (uint32_t)x->nlist) isnear[cells[i]] = 1;
    free(cells);
    out[len++] = '[';
    int first = 1;
    /* the resident index does not expose rows, so read the stored cells for the ids (cheap: ids only) */
    sqlite3_stmt *cs = NULL;
    if (sqlite3_prepare_v2(db, "SELECT cell, n, ids FROM fractal_index_cells WHERE name=?1 AND generation=?2 ORDER BY cell", -1, &cs, NULL) == SQLITE_OK) {
        sqlite3_bind_text(cs, 1, x->name, -1, SQLITE_STATIC); sqlite3_bind_int(cs, 2, x->generation);
        while (sqlite3_step(cs) == SQLITE_ROW) {
            int c = sqlite3_column_int(cs, 0); int64_t n = sqlite3_column_int64(cs, 1);
            const uint8_t *ip = (const uint8_t *)sqlite3_column_blob(cs, 2);
            if (c < 0 || c >= x->nlist || n < 0 || sqlite3_column_bytes(cs, 2) < 0 || (int64_t)sqlite3_column_bytes(cs, 2) / 8 != n || (n > 0 && !ip)) continue;   /* by division: n is data, n * 8 could overflow */
            int64_t take = isnear[c] ? n : (per < n ? per : n);
            for (int64_t j = 0; j < take; j++) {
                if (len + 32 > cap) { size_t nc2 = cap * 2; char *nb = (char *)realloc(out, nc2); if (!nb) break; out = nb; cap = nc2; }
                len += (size_t)snprintf(out + len, cap - len, "%s%lld", first ? "" : ",", (long long)get_le64(ip + (size_t)j * 8)); first = 0;
            }
        }
        sqlite3_finalize(cs);
    }
    snprintf(err, sizeof err, "SELECT rowid FROM \"%s\" WHERE rowid > ?1 AND \"%s\" IS NOT NULL", tbl, col);
    sqlite3_stmt *ds = NULL;
    if (sqlite3_prepare_v2(db, err, -1, &ds, NULL) == SQLITE_OK) {
        sqlite3_bind_int64(ds, 1, x->max_rowid);
        while (sqlite3_step(ds) == SQLITE_ROW) {
            if (len + 32 > cap) { size_t nc2 = cap * 2; char *nb = (char *)realloc(out, nc2); if (!nb) break; out = nb; cap = nc2; }
            len += (size_t)snprintf(out + len, cap - len, "%s%lld", first ? "" : ",", (long long)sqlite3_column_int64(ds, 0)); first = 0;
        }
        sqlite3_finalize(ds);
    }
    /* room for the closing bracket and the NUL: a failed realloc here would leave the buffer
     * one or two bytes short of the two bytes written below, so it is an error, not a truncation */
    if (len + 2 > cap) {
        char *nb = (char *)realloc(out, cap + 2);
        if (!nb) { free(out); free(isnear); sqlite3_result_error_nomem(ctx); return; }
        out = nb;
    }
    out[len++] = ']'; out[len] = 0;
    {   /* fractal_index_info reports the shortlist as the last search: the rows it names, and the cells it came from */
        long long ncand = 0;
        for (size_t i = 0; i + 1 < len; i++) if (out[i] == ',') ncand++;
        if (len > 2) ncand++;
        S->last_rows_scanned = ncand; S->last_cells_probed = (int)near_d; S->last_used_index = 1; S->last_lookups = 0;
    }
    sqlite3_result_text(ctx, out, (int)len, SQLITE_TRANSIENT);
    free(out); free(isnear);
}

/* The old two-argument fractal_search(vector, query) scalar was renamed fractal_sfs_converge (it runs SFS toward the query direction;
 * it is not a retrieval function). Not an alias: calling the old form is an error that says what changed. */
static void fi_renamed_fn(sqlite3_context *ctx, int argc, sqlite3_value **argv)
{
    (void)argc; (void)argv;
    sqlite3_result_error(ctx, "fractalsql: fractal_search(vector, query) was renamed fractal_sfs_converge(vector, query); "
                              "fractal_search is now fractal_search(table, column, query, k [, options]) (indexed search)", -1);
}

static void fi_state_free(void *p)
{
    FIdxState *S = (FIdxState *)p;
    if (!S) return;
    for (int i = 0; i < S->ncache; i++) fi_release(&S->cache[i]);
    free(S);
}

int fsql_index_register(sqlite3 *db, FsqlState *st)
{
    FIdxState *S = (FIdxState *)calloc(1, sizeof *S);
    if (!S) return SQLITE_NOMEM;
    S->st = st;
    const int f = SQLITE_UTF8, fd = SQLITE_UTF8 | SQLITE_DIRECTONLY;
    int rc = sqlite3_create_function_v2(db, "fractal_index_create", 2, fd, S, fi_create_fn, NULL, NULL, fi_state_free);
    if (rc) return rc;
    if ((rc = sqlite3_create_function_v2(db, "fractal_index_create", 3, fd, S, fi_create_fn, NULL, NULL, NULL))) return rc;
    if ((rc = sqlite3_create_function_v2(db, "fractal_index_rebuild", 1, fd, S, fi_rebuild_fn, NULL, NULL, NULL))) return rc;
    if ((rc = sqlite3_create_function_v2(db, "fractal_index_drop", 1, fd, S, fi_drop_fn, NULL, NULL, NULL))) return rc;
    if ((rc = sqlite3_create_function_v2(db, "fractal_index_info", 1, f, S, fi_info_fn, NULL, NULL, NULL))) return rc;
    if ((rc = sqlite3_create_function_v2(db, "fractal_index_list", 0, f, S, fi_list_fn, NULL, NULL, NULL))) return rc;
    if ((rc = sqlite3_create_function_v2(db, "fractal_index_refresh", 1, fd, S, fi_refresh_fn, NULL, NULL, NULL))) return rc;
    if ((rc = sqlite3_create_function_v2(db, "fractal_index_ensure", 2, fd, S, fi_ensure_fn, NULL, NULL, NULL))) return rc;
    if ((rc = sqlite3_create_function_v2(db, "fractal_index_ensure", 3, fd, S, fi_ensure_fn, NULL, NULL, NULL))) return rc;
    if ((rc = sqlite3_create_function_v2(db, "fractal_search", 2, f, S, fi_renamed_fn, NULL, NULL, NULL))) return rc;
    if ((rc = sqlite3_create_function_v2(db, "fractal_search", 3, f, S, fi_renamed_fn, NULL, NULL, NULL))) return rc;
    if ((rc = sqlite3_create_function_v2(db, "fractal_search", 4, f, S, fi_search_fn, NULL, NULL, NULL))) return rc;
    if ((rc = sqlite3_create_function_v2(db, "fractal_search", 5, f, S, fi_search_fn, NULL, NULL, NULL))) return rc;
    if ((rc = sqlite3_create_function_v2(db, "fractal_index_candidates", 3, f, S, fi_cand_fn, NULL, NULL, NULL))) return rc;
    return sqlite3_create_function_v2(db, "fractal_index_candidates", 4, f, S, fi_cand_fn, NULL, NULL, NULL);
}
