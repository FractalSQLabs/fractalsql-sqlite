/* src/fsql_domain_agents.c: the sixteen installable Domain Agent
 * engines.
 *
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * Sixteen parameterized "agent engine" compositions over the base
 * fractalsql primitives (Discovery + Cognition + Analytics),
 * productized so the caller's tables/columns are arguments instead of
 * hardcoded in a demo. SQLite has no server-side procedural language
 * and no second extension artifact, so they register here as plain
 * C SQL functions alongside the six Universal Agents in
 * fsql_agents.c, in the same statically-linked .so.
 *
 * Composition strategy: each engine below builds a small SQL string
 * (identifiers validated via agents_ident_ok()-equivalent and
 * interpolated only after that check, every VALUE bound as a
 * parameter, never interpolated) and runs it against st->db via
 * sqlite3_prepare_v2/bind/step, using SQLite's built-in JSON1
 * functions (json_extract) to reach into the composed primitives'
 * JSON results exactly as a human caller would in application code.
 * The one exception is the reasoning ("Cognition") step: every
 * engine's LLM call goes through fsql_reasoning_generate() directly
 * (FSQL_REASONING_TIER_CHAT) rather than a nested "SELECT
 * fractal_reason(...)": it's declared in the shared internal header
 * for exactly this kind of direct cross-TU use, and skipping the SQL
 * round-trip for the one step every engine makes keeps sixteen
 * engines' worth of prompt-building code a little lighter.
 *
 * doc_id resolution: the C primitives' 0-indexed scan position is
 * mapped back to a caller-named id column via `row_number() OVER
 * (ORDER BY rowid) - 1` (see fsql_agents.c's AgentCorpus comment: the
 * same "ORDER BY rowid" convention is what doc_id already means for
 * every primitive these engines compose).
 *
 * SQLite has no schemas or search path; every function name is a
 * single, unshadowable global registered by this same .so.
 *
 * Thirteen of the sixteen engines make a best-effort fractal_audit_log
 * call at the end, via da_audit_log_best_effort() below. Engines E, F,
 * and I (fractal_agent_recall_hybrid, _recommend_diverse,
 * _feedback_audit) don't: they are pure retrieval/analytics with no
 * LLM decision to record. fractal_audit_log (fsql_ledger.c) appends
 * kind=2 ledger rows unconditionally, with no tier gate, but
 * da_audit_log_best_effort() still discards any failure (a bad ledger
 * context, OOM, I/O), so provenance logging can never break an
 * engine's core result.
 *
 * Return shape: SQLite scalar functions can't return TABLE(...) /
 * composite rows, so every engine returns one TEXT JSON document (a
 * single object for a single-row result, a JSON array of objects for
 * a multi-row result), the same rule fsql_agents.c already applies to
 * the six Universal Agents and the table-backed searches.
 *
 * Sixteen engines (A-P):
 *   A. fractal_agent_anomaly_triage
 *   B. fractal_agent_allocate
 *   C. fractal_agent_route_task
 *   D. fractal_agent_outlier_intercept
 *   E. fractal_agent_recall_hybrid
 *   F. fractal_agent_recommend_diverse
 *   G. fractal_agent_data_analyst
 *   H. fractal_agent_patient_deterioration_triage
 *   I. fractal_agent_feedback_audit
 *   J. fractal_agent_schedule_workload
 *   K. fractal_agent_rebalance_sibling
 *   L. fractal_agent_detour_classify
 *   M. fractal_agent_track_anomaly
 *   N. fractal_agent_network_coverage_alert
 *   O. fractal_agent_regime_triage
 *   P. fractal_agent_diverse_portfolios (enterprise tier)
 */

/* strdup is POSIX, not C11: request its declaration under -std=c11 (a
 * no-op on Windows, which has no strdup at all). See fsql_config.c's
 * matching comment for the pointer-truncation bug this avoids. */
#if !defined(_WIN32) && !defined(_POSIX_C_SOURCE)
#  define _POSIX_C_SOURCE 200809L
#endif

#include <sqlite3ext.h>
SQLITE_EXTENSION_INIT3

#include <inttypes.h>
#include <math.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fsql_sqlite_internal.h"
#include "fsql_vector.h"

/* ------------------------------------------------------------------ */
/* Error + string-buffer helpers (same pattern as fsql_agents.c's own,  */
/* duplicated per-TU by this codebase's existing convention rather      */
/* than shared via a header; see StrBuf in fsql_agents.c/fsql_t2s.c).   */
/* ------------------------------------------------------------------ */

static void da_set_err(char *err, size_t err_cap, const char *fmt, ...) {
    if (!err || err_cap == 0) return;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(err, err_cap, fmt, ap);
    va_end(ap);
}

static void da_result_err(sqlite3_context *ctx, const char *err) {
    sqlite3_result_error(ctx, (err && *err) ? err
                            : "fractalsql: agent call failed", -1);
}

typedef struct StrBuf {
    char  *buf;
    size_t len;
    size_t cap;
    int    oom;
} StrBuf;

static void sb_init(StrBuf *b) { b->buf = NULL; b->len = 0; b->cap = 0; b->oom = 0; }
static void sb_free(StrBuf *b) {
    free(b->buf);
    b->buf = NULL; b->len = 0; b->cap = 0; b->oom = 0;
}
static int sb_reserve(StrBuf *b, size_t need) {
    if (b->oom) return -1;
    if (b->len + need + 1 <= b->cap) return 0;
    size_t nc = b->cap ? b->cap : 256;
    while (nc < b->len + need + 1) nc *= 2;
    char *nb = (char *)realloc(b->buf, nc);
    if (!nb) { b->oom = 1; return -1; }
    b->buf = nb; b->cap = nc;
    return 0;
}
static void sb_putn(StrBuf *b, const char *s, size_t n) {
    if (sb_reserve(b, n) != 0) return;
    memcpy(b->buf + b->len, s, n);
    b->len += n;
    b->buf[b->len] = '\0';
}
static void sb_puts(StrBuf *b, const char *s) { sb_putn(b, s, strlen(s)); }
static void sb_printf(StrBuf *b, const char *fmt, ...) {
    va_list ap, ap2;
    va_start(ap, fmt);
    va_copy(ap2, ap);
    int need = vsnprintf(NULL, 0, fmt, ap);
    va_end(ap);
    if (need < 0 || sb_reserve(b, (size_t)need) != 0) {
        va_end(ap2);
        b->oom = 1;
        return;
    }
    vsnprintf(b->buf + b->len, (size_t)need + 1, fmt, ap2);
    va_end(ap2);
    b->len += (size_t)need;
}
static int sb_failed(const StrBuf *b) { return b->oom; }

static void sb_json_string(StrBuf *b, const char *s) {
    sb_puts(b, "\"");
    if (s) {
        for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
            if (b->oom) break;
            switch (*p) {
            case '"':  sb_puts(b, "\\\""); break;
            case '\\': sb_puts(b, "\\\\"); break;
            case '\b': sb_puts(b, "\\b");  break;
            case '\f': sb_puts(b, "\\f");  break;
            case '\n': sb_puts(b, "\\n");  break;
            case '\r': sb_puts(b, "\\r");  break;
            case '\t': sb_puts(b, "\\t");  break;
            default:
                if (*p < 0x20) {
                    char esc[8];
                    snprintf(esc, sizeof esc, "\\u%04x", (unsigned)*p);
                    sb_puts(b, esc);
                } else {
                    sb_putn(b, (const char *)p, 1);
                }
            }
        }
    }
    sb_puts(b, "\"");
}

/* Appends `s` verbatim if it looks like a JSON value already (starts
 * with {, [, digit, -, t, f, n after skipping space), else as a JSON
 * string. Used for fields that are themselves JSON documents (e.g. a
 * composed primitive's own result) so they nest as real JSON, not a
 * doubly-escaped string. */
static void sb_json_raw_or_string(StrBuf *b, const char *s) {
    if (!s) { sb_puts(b, "null"); return; }
    const char *p = s;
    while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p++;
    if (*p == '{' || *p == '[' || *p == '"' || *p == 't' || *p == 'f' ||
        *p == 'n' || *p == '-' || (*p >= '0' && *p <= '9'))
        sb_puts(b, s);
    else
        sb_json_string(b, s);
}

/* True when s is ENTIRELY a JSON number (RFC 8259 grammar:
 * -?int(.frac)?([eE]exp)? -- no leading zeros, no bare '.'). */
static int da_json_number_ok(const char *s) {
    if (!s || !*s) return 0;
    const char *p = s;
    if (*p == '-') p++;
    if (!(*p >= '0' && *p <= '9')) return 0;
    if (p[0] == '0' && p[1] >= '0' && p[1] <= '9') return 0;
    while (*p >= '0' && *p <= '9') p++;
    if (*p == '.') {
        p++;
        if (!(*p >= '0' && *p <= '9')) return 0;
        while (*p >= '0' && *p <= '9') p++;
    }
    if (*p == 'e' || *p == 'E') {
        p++;
        if (*p == '+' || *p == '-') p++;
        if (!(*p >= '0' && *p <= '9')) return 0;
        while (*p >= '0' && *p <= '9') p++;
    }
    return *p == '\0';
}

/* Emits an id-column value: as a JSON number only when the ENTIRE
 * string is one, otherwise as a quoted JSON string. Data-derived
 * values never splice in as raw JSON structure -- sb_json_raw_or_string
 * would emit an id like '{"x":1' as syntax, structuring (or breaking)
 * the result document. Only code-generated primitives stay on the
 * raw-or-string path. */
static void sb_json_id_value(StrBuf *b, const char *s) {
    if (!s) { sb_puts(b, "null"); return; }
    if (da_json_number_ok(s)) sb_puts(b, s);
    else                      sb_json_string(b, s);
}

/* ------------------------------------------------------------------ */
/* Identifier validation + quoting (see fsql_agents.c's own copy for   */
/* the injection-defense rationale). Every VALUE is bound, never       */
/* interpolated; only a validated plain identifier is ever quoted in.  */
/* ------------------------------------------------------------------ */

static int da_ident_ok(const char *s) {
    if (!s || !*s) return 0;
    if (!((s[0] >= 'A' && s[0] <= 'Z') ||
          (s[0] >= 'a' && s[0] <= 'z') || s[0] == '_'))
        return 0;
    for (const char *p = s + 1; *p; p++) {
        if (!((*p >= 'A' && *p <= 'Z') || (*p >= 'a' && *p <= 'z') ||
              (*p >= '0' && *p <= '9') || *p == '_'))
            return 0;
    }
    return 1;
}

static void sb_sql_ident(StrBuf *sql, const char *ident) {
    sb_puts(sql, "\"");
    sb_puts(sql, ident);
    sb_puts(sql, "\"");
}

/* For values fractal_hybrid_clinical_search reads back with
 * sqlite3_value_text() (its table_name/vector_col args are strings,
 * not identifiers to resolve) -- a double-quoted sb_sql_ident() there
 * only worked by accident, via SQLite's legacy double-quoted-string
 * fallback for an unresolvable identifier; that fallback is
 * build-dependent (off by default in some SQLite builds), where it
 * fails clean with "no such column: ... - should this be a string
 * literal in single-quotes?". Every caller already passes plain
 * [A-Za-z_][A-Za-z0-9_]* names (da_ident_ok-checked before this is
 * ever reached), so no embedded quote can occur; escaping doubles any
 * anyway for defense in depth. */
static void sb_sql_lit(StrBuf *sql, const char *lit) {
    sb_puts(sql, "'");
    for (const char *p = lit; *p; p++) {
        if (*p == '\'') sb_puts(sql, "'");
        char one[2] = { *p, '\0' };
        sb_puts(sql, one);
    }
    sb_puts(sql, "'");
}

/* ------------------------------------------------------------------ */
/* Vector decode (mirrors agents_decode_query_doubles in fsql_agents.c)*/
/* ------------------------------------------------------------------ */

static double *da_decode_vec(sqlite3_value *v, int *out_dim) {
    *out_dim = 0;
    float *qf = NULL;
    int dim = 0;
    if (fsql_vec_decode(v, &qf, &dim) != 0) return NULL;
    /* Same arena bound as agents_decode_query_doubles: decode caps at
     * FSQL_VEC_MAX_DIM, but every core-facing search this TU feeds is
     * arena-sized at FSQL_ARENA_MAX_DIM. */
    if (dim < 1 || dim > FSQL_ARENA_MAX_DIM) { free(qf); return NULL; }
    double *q = (double *)malloc((size_t)dim * sizeof(double));
    if (!q) { free(qf); return NULL; }
    for (int i = 0; i < dim; i++) q[i] = (double)qf[i];
    free(qf);
    *out_dim = dim;
    return q;
}

/* Renders a double[] as a JSON array TEXT ("[1,2,3]"), the shape
 * every vector-argument primitive here accepts directly (see
 * docs/api-discovery.md's "SQLite conventions" note: CSV/JSON text or
 * a canonical fractal_vector BLOB). Returns a malloc'd string (caller
 * frees), or NULL on OOM. */
static char *da_vec_json(const double *v, int n) {
    StrBuf b; sb_init(&b);
    sb_puts(&b, "[");
    for (int i = 0; i < n; i++) {
        if (i) sb_puts(&b, ",");
        if (isnan(v[i])) sb_puts(&b, "null");
        else               sb_printf(&b, "%.17g", v[i]);
    }
    sb_puts(&b, "]");
    if (sb_failed(&b)) { sb_free(&b); return NULL; }
    return b.buf;
}

/* ------------------------------------------------------------------ */
/* Reasoning (Cognition step): direct call, no SQL re-entry            */
/* ------------------------------------------------------------------ */

static int da_require_reasoning(FsqlState *st, const char *who,
                                char *err, size_t err_cap) {
    if (!st || !st->ctx) {
        da_set_err(err, err_cap, "fractalsql: extension not initialized");
        return -1;
    }
    if (!st->cfg.reasoning_plugin || !*st->cfg.reasoning_plugin) {
        da_set_err(err, err_cap,
                   "%s: reasoning plugin not configured (set "
                   "fractalsql_set('reasoning_plugin', '/absolute/path.so'))",
                   who);
        return -1;
    }
    return 0;
}

/* Returns a malloc'd response (caller frees) or NULL with err filled. */
static char *da_reason(FsqlState *st, const char *who, const char *prompt,
                       const char *context_json, char *err, size_t err_cap) {
    if (da_require_reasoning(st, who, err, err_cap) != 0) return NULL;
    char *resp = NULL;
    if (fsql_reasoning_generate(st, FSQL_REASONING_TIER_CHAT, prompt,
                                (context_json && *context_json) ? context_json : "{}",
                                &resp, err, err_cap) != 0)
        return NULL;
    return resp;
}

/* ------------------------------------------------------------------ */
/* Small SQL-composition helpers shared by several engines             */
/* ------------------------------------------------------------------ */

/* SELECT 1 FROM "table" LIMIT 1: returns 1 (has rows), 0 (empty), or
 * -1 on a real error (err filled). */
static int da_table_has_rows(FsqlState *st, const char *table,
                             char *err, size_t err_cap) {
    StrBuf sql; sb_init(&sql);
    sb_puts(&sql, "SELECT 1 FROM ");
    sb_sql_ident(&sql, table);
    sb_puts(&sql, " LIMIT 1");
    if (sb_failed(&sql)) {
        sb_free(&sql);
        da_set_err(err, err_cap, "fractalsql: out of memory");
        return -1;
    }
    sqlite3_stmt *stmt = NULL;
    int rc = sqlite3_prepare_v2(st->db, sql.buf, -1, &stmt, NULL);
    sb_free(&sql);
    if (rc != SQLITE_OK) {
        da_set_err(err, err_cap, "fractalsql: %s", sqlite3_errmsg(st->db));
        return -1;
    }
    rc = sqlite3_step(stmt);
    int has = (rc == SQLITE_ROW) ? 1 : 0;
    sqlite3_finalize(stmt);
    return has;
}

/* Resolves a 0-indexed doc_id back to the named id column's value via
 * `row_number() OVER (ORDER BY rowid) - 1`. Returns a malloc'd TEXT
 * copy of the id (caller frees), or NULL (not found, not an error;
 * the caller COALESCEs). A real error (bad SQL, OOM) also returns
 * NULL but fills err; the caller distinguishes by checking err[0]. */
static char *da_resolve_id(FsqlState *st, const char *table, const char *id_col,
                           int64_t doc_id, char *err, size_t err_cap) {
    StrBuf sql; sb_init(&sql);
    sb_puts(&sql, "SELECT ");
    sb_sql_ident(&sql, id_col);
    sb_puts(&sql, " FROM (SELECT ");
    sb_sql_ident(&sql, id_col);
    sb_puts(&sql, ", row_number() OVER (ORDER BY rowid) - 1 AS __doc_id FROM ");
    sb_sql_ident(&sql, table);
    sb_puts(&sql, ") WHERE __doc_id = ?1");
    if (sb_failed(&sql)) {
        sb_free(&sql);
        da_set_err(err, err_cap, "fractalsql: out of memory");
        return NULL;
    }
    sqlite3_stmt *stmt = NULL;
    int rc = sqlite3_prepare_v2(st->db, sql.buf, -1, &stmt, NULL);
    sb_free(&sql);
    if (rc != SQLITE_OK) {
        da_set_err(err, err_cap, "fractalsql: %s", sqlite3_errmsg(st->db));
        return NULL;
    }
    sqlite3_bind_int64(stmt, 1, (sqlite3_int64)doc_id);
    rc = sqlite3_step(stmt);
    char *out = NULL;
    if (rc == SQLITE_ROW) {
        const unsigned char *t = sqlite3_column_text(stmt, 0);
        if (t) out = strdup((const char *)t);
    } else if (rc != SQLITE_DONE) {
        da_set_err(err, err_cap, "fractalsql: %s", sqlite3_errmsg(st->db));
    }
    sqlite3_finalize(stmt);
    return out;
}

/* Runs a nearest-1 style search (fractal_search_telemetry or
 * fractal_search_trajectory shape) and extracts doc_id/distance from
 * its top-1 JSON result via json_extract. `fn_sql` is the full
 * "fractal_search_X(...)" call text with ?1.. placeholders already
 * substituted by the caller (identifiers pre-validated/quoted; the
 * caller binds any remaining value params before calling this via
 * `extra_binds`, which may be NULL). Returns 0 with *out_doc_id/
 * *out_dist set (or *out_doc_id = -1 if the primitive returned an
 * empty array, not an error), or -1 with err filled on a real
 * error. */
static int da_nearest1(FsqlState *st, const char *fn_sql,
                       void (*bind_extra)(sqlite3_stmt *, void *),
                       void *bind_ctx,
                       int64_t *out_doc_id, double *out_dist,
                       char *err, size_t err_cap) {
    StrBuf sql; sb_init(&sql);
    sb_puts(&sql, "SELECT json_extract(r.j,'$[0].doc_id'), "
                  "json_extract(r.j,'$[0].distance') "
                  "FROM (SELECT ");
    sb_puts(&sql, fn_sql);
    sb_puts(&sql, " AS j) r");
    if (sb_failed(&sql)) {
        sb_free(&sql);
        da_set_err(err, err_cap, "fractalsql: out of memory");
        return -1;
    }
    sqlite3_stmt *stmt = NULL;
    int rc = sqlite3_prepare_v2(st->db, sql.buf, -1, &stmt, NULL);
    sb_free(&sql);
    if (rc != SQLITE_OK) {
        da_set_err(err, err_cap, "fractalsql: %s", sqlite3_errmsg(st->db));
        return -1;
    }
    if (bind_extra) bind_extra(stmt, bind_ctx);
    rc = sqlite3_step(stmt);
    if (rc != SQLITE_ROW) {
        sqlite3_finalize(stmt);
        da_set_err(err, err_cap, "fractalsql: %s", sqlite3_errmsg(st->db));
        return -1;
    }
    if (sqlite3_column_type(stmt, 0) == SQLITE_NULL) {
        *out_doc_id = -1;
        *out_dist = 0.0;
    } else {
        *out_doc_id = sqlite3_column_int64(stmt, 0);
        *out_dist = sqlite3_column_double(stmt, 1);
    }
    sqlite3_finalize(stmt);
    return 0;
}

/* Builds a JSON array of every row's 0-indexed scan position
 * (row_number() OVER (ORDER BY rowid) - 1), optionally restricted by
 * `filter_col = ?1` (filter_col may be NULL for "every row"). Returns
 * a malloc'd JSON-array TEXT ("[0,1,4,...]", caller frees) or NULL
 * (empty match, not an error) or NULL with err filled on a real
 * error (caller distinguishes via err[0]). */
static char *da_build_cohort(FsqlState *st, const char *table,
                             const char *filter_col, const char *filter_val,
                             char *err, size_t err_cap) {
    /* The row_number() MUST be computed over the FULL, unfiltered table
     * in an inner subquery, with filter_col = ?1 applied only in the
     * outer query: SQL evaluates WHERE before window functions, so
     * putting the filter in the SAME FROM clause as the row_number()
     * call would number only the filtered rows (0, 1, 2, ...) instead
     * of their true positions in the full table-scan order, silently
     * building the wrong cohort. */
    StrBuf sql; sb_init(&sql);
    sb_puts(&sql, "SELECT '[' || group_concat(__doc_id) || ']' FROM "
                  "(SELECT __doc_id FROM (SELECT row_number() OVER "
                  "(ORDER BY rowid) - 1 AS __doc_id");
    if (filter_col) {
        sb_puts(&sql, ", ");
        sb_sql_ident(&sql, filter_col);
        sb_puts(&sql, " AS __fc");
    }
    sb_puts(&sql, " FROM ");
    sb_sql_ident(&sql, table);
    sb_puts(&sql, ")");
    if (filter_col) sb_puts(&sql, " WHERE __fc = ?1");
    sb_puts(&sql, ")");
    if (sb_failed(&sql)) {
        sb_free(&sql);
        da_set_err(err, err_cap, "fractalsql: out of memory");
        return NULL;
    }
    sqlite3_stmt *stmt = NULL;
    int rc = sqlite3_prepare_v2(st->db, sql.buf, -1, &stmt, NULL);
    sb_free(&sql);
    if (rc != SQLITE_OK) {
        da_set_err(err, err_cap, "fractalsql: %s", sqlite3_errmsg(st->db));
        return NULL;
    }
    if (filter_col) sqlite3_bind_text(stmt, 1, filter_val, -1, SQLITE_TRANSIENT);
    rc = sqlite3_step(stmt);
    char *out = NULL;
    if (rc == SQLITE_ROW && sqlite3_column_type(stmt, 0) != SQLITE_NULL) {
        const unsigned char *t = sqlite3_column_text(stmt, 0);
        if (t) out = strdup((const char *)t);
    } else if (rc != SQLITE_ROW && rc != SQLITE_DONE) {
        da_set_err(err, err_cap, "fractalsql: %s", sqlite3_errmsg(st->db));
    }
    sqlite3_finalize(stmt);
    return out;
}

/* Runs `sql` (a single already-built statement with ?1.. bound by
 * bind_extra) and returns the top-level result column 0 as a malloc'd
 * TEXT copy (caller frees), used to pull a JSON document straight
 * out of a composed primitive (fractal_dimension_drift, fractal_
 * optimize_portfolio, fractal_morphological_complexity, ...). NULL +
 * err on failure. */
static char *da_scalar_text(FsqlState *st, const char *sql,
                            void (*bind_extra)(sqlite3_stmt *, void *),
                            void *bind_ctx, char *err, size_t err_cap) {
    sqlite3_stmt *stmt = NULL;
    int rc = sqlite3_prepare_v2(st->db, sql, -1, &stmt, NULL);
    if (rc != SQLITE_OK) {
        da_set_err(err, err_cap, "fractalsql: %s", sqlite3_errmsg(st->db));
        return NULL;
    }
    if (bind_extra) bind_extra(stmt, bind_ctx);
    rc = sqlite3_step(stmt);
    char *out = NULL;
    if (rc == SQLITE_ROW) {
        const unsigned char *t = sqlite3_column_text(stmt, 0);
        if (t) out = strdup((const char *)t);
        else da_set_err(err, err_cap, "fractalsql: primitive call returned NULL");
    } else {
        da_set_err(err, err_cap, "fractalsql: %s", sqlite3_errmsg(st->db));
    }
    sqlite3_finalize(stmt);
    return out;
}

/* json_extract a numeric field out of a JSON document TEXT, defaulting
 * to 0.0 if absent/NULL/unparseable. */
static double da_json_num(FsqlState *st, const char *json, const char *path) {
    if (!json) return 0.0;
    char sql[128];
    snprintf(sql, sizeof sql, "SELECT COALESCE(json_extract(?1,'%s'),0.0)", path);
    sqlite3_stmt *stmt = NULL;
    double v = 0.0;
    if (sqlite3_prepare_v2(st->db, sql, -1, &stmt, NULL) == SQLITE_OK) {
        sqlite3_bind_text(stmt, 1, json, -1, SQLITE_TRANSIENT);
        if (sqlite3_step(stmt) == SQLITE_ROW) v = sqlite3_column_double(stmt, 0);
    }
    sqlite3_finalize(stmt);
    return v;
}

/* Bind helper for the common "one text param at ?1" shape. */
typedef struct OneText { const char *s; } OneText;
static void bind_one_text(sqlite3_stmt *stmt, void *ctx) {
    OneText *t = (OneText *)ctx;
    sqlite3_bind_text(stmt, 1, t->s, -1, SQLITE_TRANSIENT);
}
typedef struct TwoText { const char *a; const char *b; } TwoText;
static void bind_two_text(sqlite3_stmt *stmt, void *ctx) {
    TwoText *t = (TwoText *)ctx;
    sqlite3_bind_text(stmt, 1, t->a, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 2, t->b, -1, SQLITE_TRANSIENT);
}

/* Best-effort provenance: append the engine's decision to the audit chain
 * via the already-registered fractal_audit_log(entry_type, payload)
 * (fsql_ledger.c). fractal_audit_log appends kind=2 ledger rows
 * unconditionally once the ledger context exists, with no tier gate,
 * but the call is kept best-effort here since provenance logging is
 * peripheral to what an engine exists to compute, so any failure of
 * it (OOM, ledger I/O) must never surface as the engine's own error.
 * Any sqlite3_prepare_v2/step failure is silently discarded. */
static void da_audit_log_best_effort(FsqlState *st, const char *entry_type,
                                     const char *payload_json) {
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(st->db, "SELECT fractal_audit_log(?1,?2)", -1,
                           &stmt, NULL) != SQLITE_OK)
        return;
    sqlite3_bind_text(stmt, 1, entry_type, -1, SQLITE_STATIC);
    sqlite3_bind_text(stmt, 2, payload_json, -1, SQLITE_TRANSIENT);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
}

/* ======================================================================
 * Engine A: fractal_agent_anomaly_triage(log_table, metric_col,
 *   time_col, filter_col, filter_val, baseline_window DEFAULT 32)
 *   -> TEXT JSON {threat_score, anomaly_type, triage_summary}
 * ====================================================================== */
static void agent_anomaly_triage_fn(sqlite3_context *ctx, int argc,
                                    sqlite3_value **argv) {
    FsqlState *st = (FsqlState *)sqlite3_user_data(ctx);
    char err[512];
    if (argc < 5 || argc > 6) {
        sqlite3_result_error(ctx,
            "fractal_agent_anomaly_triage(log_table, metric_col, time_col, "
            "filter_col, filter_val [, baseline_window]) expects 5 or 6 args", -1);
        return;
    }
    for (int i = 0; i < 5; i++) {
        if (sqlite3_value_type(argv[i]) == SQLITE_NULL) {
            sqlite3_result_error(ctx,
                "fractal_agent_anomaly_triage: identifier arguments must not be NULL", -1);
            return;
        }
    }
    const char *log_table  = (const char *)sqlite3_value_text(argv[0]);
    const char *metric_col = (const char *)sqlite3_value_text(argv[1]);
    const char *time_col   = (const char *)sqlite3_value_text(argv[2]);
    const char *filter_col = (const char *)sqlite3_value_text(argv[3]);
    const char *filter_val = (const char *)sqlite3_value_text(argv[4]);
    int baseline_window = (argc >= 6 && sqlite3_value_type(argv[5]) != SQLITE_NULL)
                         ? sqlite3_value_int(argv[5]) : 32;
    if (!log_table || !metric_col || !time_col || !filter_col || !filter_val) {
        sqlite3_result_error_nomem(ctx); return;
    }
    if (!da_ident_ok(log_table) || !da_ident_ok(metric_col) || !da_ident_ok(time_col) ||
        !da_ident_ok(filter_col)) {
        sqlite3_result_error(ctx,
            "fractalsql: table/column identifiers must be plain identifiers "
            "([A-Za-z_][A-Za-z0-9_]*)", -1);
        return;
    }

    /* 1. Fetch the entity's metric series, ordered by time. */
    StrBuf sql; sb_init(&sql);
    sb_puts(&sql, "SELECT '[' || group_concat(v) || ']' FROM (SELECT ");
    sb_sql_ident(&sql, metric_col);
    sb_puts(&sql, " AS v FROM ");
    sb_sql_ident(&sql, log_table);
    sb_puts(&sql, " WHERE ");
    sb_sql_ident(&sql, filter_col);
    sb_puts(&sql, " = ?1 ORDER BY ");
    sb_sql_ident(&sql, time_col);
    sb_puts(&sql, ")");
    if (sb_failed(&sql)) { sb_free(&sql); sqlite3_result_error_nomem(ctx); return; }
    OneText bind = { filter_val };
    char *series_json = da_scalar_text(st, sql.buf, bind_one_text, &bind, err, sizeof err);
    sb_free(&sql);
    if (!series_json || strcmp(series_json, "[]") == 0) {
        free(series_json);
        char msg[384];
        snprintf(msg, sizeof msg,
                 "fractal_agent_anomaly_triage: no rows in %s.%s matching %s = %s",
                 log_table, metric_col, filter_col, filter_val);
        sqlite3_result_error(ctx, msg, -1);
        return;
    }

    /* 2. Real Analytics: regime-change drift. */
    OneText sbind = { series_json };
    char callsql[128];
    snprintf(callsql, sizeof callsql,
             "SELECT fractal_dimension_drift(?1,%d)", baseline_window);
    char *drift_json = da_scalar_text(st, callsql, bind_one_text, &sbind, err, sizeof err);
    free(series_json);
    if (!drift_json) { da_result_err(ctx, err); return; }

    double threat_score = da_json_num(st, drift_json, "$.drift");
    free(drift_json);

    /* 3. Real Cognition. */
    StrBuf prompt; sb_init(&prompt);
    sb_printf(&prompt, "Triage this anomaly: drift score %.10f", threat_score);
    StrBuf cjson; sb_init(&cjson);
    sb_puts(&cjson, "{\"table\":");
    sb_json_string(&cjson, log_table);
    sb_puts(&cjson, ",\"filter\":");
    sb_json_string(&cjson, filter_val);
    sb_puts(&cjson, "}");
    if (sb_failed(&prompt) || sb_failed(&cjson)) {
        sb_free(&prompt); sb_free(&cjson);
        sqlite3_result_error_nomem(ctx);
        return;
    }
    char *rationale = da_reason(st, "fractal_agent_anomaly_triage",
                                prompt.buf, cjson.buf, err, sizeof err);
    sb_free(&prompt); sb_free(&cjson);
    if (!rationale) { da_result_err(ctx, err); return; }

    StrBuf audit; sb_init(&audit);
    sb_printf(&audit, "{\"threat_score\":%.10f,\"anomaly_type\":\"vector_drift\","
                      "\"triage_summary\":", threat_score);
    sb_json_string(&audit, rationale);
    sb_puts(&audit, "}");
    if (!sb_failed(&audit))
        da_audit_log_best_effort(st, "agent_anomaly_triage", audit.buf);
    sb_free(&audit);

    StrBuf out; sb_init(&out);
    sb_printf(&out, "{\"threat_score\":%.10f,\"anomaly_type\":\"vector_drift\","
                    "\"triage_summary\":", threat_score);
    sb_json_string(&out, rationale);
    sb_puts(&out, "}");
    free(rationale);
    if (sb_failed(&out)) { sb_free(&out); sqlite3_result_error_nomem(ctx); return; }
    sqlite3_result_text(ctx, out.buf, (int)out.len, SQLITE_TRANSIENT);
    sb_free(&out);
}

/* ======================================================================
 * Engine B: fractal_agent_allocate(mu, cov, cardinality, context
 *   DEFAULT NULL) -> TEXT JSON {allocation, sharpe, rationale}
 * ====================================================================== */
static void agent_allocate_fn(sqlite3_context *ctx, int argc,
                              sqlite3_value **argv) {
    FsqlState *st = (FsqlState *)sqlite3_user_data(ctx);
    char err[512];
    if (argc < 3 || argc > 4) {
        sqlite3_result_error(ctx,
            "fractal_agent_allocate(mu, cov, cardinality [, context]) "
            "expects 3 or 4 args", -1);
        return;
    }
    if (sqlite3_value_type(argv[0]) == SQLITE_NULL ||
        sqlite3_value_type(argv[1]) == SQLITE_NULL ||
        sqlite3_value_type(argv[2]) == SQLITE_NULL) {
        sqlite3_result_error(ctx,
            "fractal_agent_allocate: mu, cov, and cardinality are required", -1);
        return;
    }
    int mu_dim = 0, cov_dim = 0;
    double *mu = da_decode_vec(argv[0], &mu_dim);
    double *cov = da_decode_vec(argv[1], &cov_dim);
    if (!mu || !cov) {
        free(mu); free(cov);
        sqlite3_result_error(ctx, "fractalsql: mu/cov must be CSV/JSON vectors", -1);
        return;
    }
    int cardinality = sqlite3_value_int(argv[2]);
    char *mu_json = da_vec_json(mu, mu_dim);
    char *cov_json = da_vec_json(cov, cov_dim);
    free(mu); free(cov);
    if (!mu_json || !cov_json) {
        free(mu_json); free(cov_json);
        sqlite3_result_error_nomem(ctx);
        return;
    }
    const char *context = "{}";
    if (argc == 4 && sqlite3_value_type(argv[3]) != SQLITE_NULL)
        context = (const char *)sqlite3_value_text(argv[3]);
    if (!context) context = "{}";

    char callsql[128];
    snprintf(callsql, sizeof callsql,
             /* Registered at arity 4/5/6 only, never 3: a bare seed-less
              * NULL keeps the core's default (random) seed. */
             "SELECT fractal_optimize_portfolio(?1,?2,%d,NULL)", cardinality);
    TwoText bind = { mu_json, cov_json };
    char *opt = da_scalar_text(st, callsql, bind_two_text, &bind, err, sizeof err);
    free(mu_json); free(cov_json);
    if (!opt) { da_result_err(ctx, err); return; }

    double sharpe = da_json_num(st, opt, "$.sharpe");

    StrBuf prompt; sb_init(&prompt);
    sb_puts(&prompt, "Explain this cardinality-constrained allocation and its "
                    "risk/return: ");
    sb_puts(&prompt, opt);
    if (sb_failed(&prompt)) { sb_free(&prompt); free(opt); sqlite3_result_error_nomem(ctx); return; }
    char *rationale = da_reason(st, "fractal_agent_allocate", prompt.buf, context,
                                err, sizeof err);
    sb_free(&prompt);
    if (!rationale) { free(opt); da_result_err(ctx, err); return; }

    StrBuf audit; sb_init(&audit);
    sb_printf(&audit, "{\"sharpe\":%.10f,\"cardinality\":%d,\"rationale\":",
             sharpe, cardinality);
    sb_json_string(&audit, rationale);
    sb_puts(&audit, "}");
    if (!sb_failed(&audit))
        da_audit_log_best_effort(st, "agent_allocate", audit.buf);
    sb_free(&audit);

    StrBuf out; sb_init(&out);
    sb_puts(&out, "{\"allocation\":");
    sb_json_raw_or_string(&out, opt);
    sb_printf(&out, ",\"sharpe\":%.10f,\"rationale\":", sharpe);
    sb_json_string(&out, rationale);
    sb_puts(&out, "}");
    free(opt); free(rationale);
    if (sb_failed(&out)) { sb_free(&out); sqlite3_result_error_nomem(ctx); return; }
    sqlite3_result_text(ctx, out.buf, (int)out.len, SQLITE_TRANSIENT);
    sb_free(&out);
}

/* ======================================================================
 * Engine C: fractal_agent_route_task(task_emb, cap_table, cap_emb_col,
 *   cap_id_col, budget, cost_per_route DEFAULT 150)
 *   -> TEXT JSON {routed_to, confidence, remaining_budget, rationale}
 * ====================================================================== */
static void agent_route_task_fn(sqlite3_context *ctx, int argc,
                                sqlite3_value **argv) {
    FsqlState *st = (FsqlState *)sqlite3_user_data(ctx);
    char err[512];
    if (argc < 5 || argc > 6) {
        sqlite3_result_error(ctx,
            "fractal_agent_route_task(task_emb, cap_table, cap_emb_col, "
            "cap_id_col, budget [, cost_per_route]) expects 5 or 6 args", -1);
        return;
    }
    if (sqlite3_value_type(argv[0]) == SQLITE_NULL ||
        sqlite3_value_type(argv[1]) == SQLITE_NULL ||
        sqlite3_value_type(argv[2]) == SQLITE_NULL ||
        sqlite3_value_type(argv[3]) == SQLITE_NULL) {
        sqlite3_result_error(ctx,
            "fractal_agent_route_task: identifier arguments must not be NULL", -1);
        return;
    }
    const char *cap_table   = (const char *)sqlite3_value_text(argv[1]);
    const char *cap_emb_col = (const char *)sqlite3_value_text(argv[2]);
    const char *cap_id_col  = (const char *)sqlite3_value_text(argv[3]);
    int budget = sqlite3_value_int(argv[4]);
    int cost_per_route = (argc >= 6 && sqlite3_value_type(argv[5]) != SQLITE_NULL)
                        ? sqlite3_value_int(argv[5]) : 150;
    if (!cap_table || !cap_emb_col || !cap_id_col) { sqlite3_result_error_nomem(ctx); return; }
    if (!da_ident_ok(cap_table) || !da_ident_ok(cap_emb_col) || !da_ident_ok(cap_id_col)) {
        sqlite3_result_error(ctx,
            "fractalsql: table/column identifiers must be plain identifiers "
            "([A-Za-z_][A-Za-z0-9_]*)", -1);
        return;
    }
    int rows = da_table_has_rows(st, cap_table, err, sizeof err);
    if (rows < 0) { da_result_err(ctx, err); return; }
    if (rows == 0) {
        char msg[256];
        snprintf(msg, sizeof msg,
                 "fractal_agent_route_task: no capability rows in %s", cap_table);
        sqlite3_result_error(ctx, msg, -1);
        return;
    }

    int dim = 0;
    double *task = da_decode_vec(argv[0], &dim);
    if (!task) { sqlite3_result_error(ctx, "fractalsql: task_emb must be a CSV/JSON vector", -1); return; }
    char *task_json = da_vec_json(task, dim);
    free(task);
    if (!task_json) { sqlite3_result_error_nomem(ctx); return; }

    StrBuf fnsql; sb_init(&fnsql);
    sb_puts(&fnsql, "fractal_search_telemetry(");
    sb_sql_ident(&fnsql, cap_table);
    sb_puts(&fnsql, ",");
    sb_sql_ident(&fnsql, cap_emb_col);
    sb_puts(&fnsql, ",?1,1)");
    if (sb_failed(&fnsql)) { sb_free(&fnsql); free(task_json); sqlite3_result_error_nomem(ctx); return; }
    OneText bind = { task_json };
    int64_t doc_id = -1; double dist = 0.0;
    int rc = da_nearest1(st, fnsql.buf, bind_one_text, &bind, &doc_id, &dist, err, sizeof err);
    sb_free(&fnsql);
    free(task_json);
    if (rc != 0) { da_result_err(ctx, err); return; }
    if (doc_id < 0) {
        char msg[256];
        snprintf(msg, sizeof msg,
                 "fractal_agent_route_task: no capability rows in %s", cap_table);
        sqlite3_result_error(ctx, msg, -1);
        return;
    }

    char *routed_to = da_resolve_id(st, cap_table, cap_id_col, doc_id, err, sizeof err);
    if (!routed_to && err[0]) { da_result_err(ctx, err); return; }

    StrBuf prompt; sb_init(&prompt);
    sb_printf(&prompt, "Route this task to capability %s (cosine distance %.10f). "
                       "Justify the routing in one sentence.",
                       routed_to ? routed_to : "?", dist);
    StrBuf cjson; sb_init(&cjson);
    sb_printf(&cjson, "{\"budget\":%d,\"cost_per_route\":%d}", budget, cost_per_route);
    if (sb_failed(&prompt) || sb_failed(&cjson)) {
        sb_free(&prompt); sb_free(&cjson); free(routed_to);
        sqlite3_result_error_nomem(ctx);
        return;
    }
    char *rationale = da_reason(st, "fractal_agent_route_task", prompt.buf, cjson.buf,
                                err, sizeof err);
    sb_free(&prompt); sb_free(&cjson);
    if (!rationale) { free(routed_to); da_result_err(ctx, err); return; }

    double confidence = 1.0 / (1.0 + dist);
    StrBuf audit; sb_init(&audit);
    sb_puts(&audit, "{\"routed_to\":");
    if (routed_to) sb_json_string(&audit, routed_to); else sb_puts(&audit, "null");
    sb_printf(&audit, ",\"confidence\":%.10f,\"remaining_budget\":%d,\"rationale\":",
             confidence, budget - cost_per_route);
    sb_json_string(&audit, rationale);
    sb_puts(&audit, "}");
    if (!sb_failed(&audit))
        da_audit_log_best_effort(st, "agent_route_task", audit.buf);
    sb_free(&audit);

    StrBuf out; sb_init(&out);
    sb_puts(&out, "{\"routed_to\":");
    if (routed_to) sb_json_string(&out, routed_to); else sb_puts(&out, "null");
    sb_printf(&out, ",\"confidence\":%.10f,\"remaining_budget\":%d,\"rationale\":",
             confidence, budget - cost_per_route);
    sb_json_string(&out, rationale);
    sb_puts(&out, "}");
    free(routed_to); free(rationale);
    if (sb_failed(&out)) { sb_free(&out); sqlite3_result_error_nomem(ctx); return; }
    sqlite3_result_text(ctx, out.buf, (int)out.len, SQLITE_TRANSIENT);
    sb_free(&out);
}

/* ======================================================================
 * Engine D: fractal_agent_outlier_intercept(state_vec, history_table,
 *   emb_col, threshold) -> TEXT JSON {intercepted, reason}
 * ====================================================================== */
static void agent_outlier_intercept_fn(sqlite3_context *ctx, int argc,
                                       sqlite3_value **argv) {
    FsqlState *st = (FsqlState *)sqlite3_user_data(ctx);
    char err[512];
    if (argc != 4) {
        sqlite3_result_error(ctx,
            "fractal_agent_outlier_intercept(state_vec, history_table, emb_col, "
            "threshold) expects 4 args", -1);
        return;
    }
    if (sqlite3_value_type(argv[0]) == SQLITE_NULL ||
        sqlite3_value_type(argv[1]) == SQLITE_NULL ||
        sqlite3_value_type(argv[2]) == SQLITE_NULL ||
        sqlite3_value_type(argv[3]) == SQLITE_NULL) {
        sqlite3_result_error(ctx,
            "fractal_agent_outlier_intercept: all arguments are required", -1);
        return;
    }
    const char *history_table = (const char *)sqlite3_value_text(argv[1]);
    const char *emb_col       = (const char *)sqlite3_value_text(argv[2]);
    double threshold = sqlite3_value_double(argv[3]);
    if (!history_table || !emb_col) { sqlite3_result_error_nomem(ctx); return; }
    if (!da_ident_ok(history_table) || !da_ident_ok(emb_col)) {
        sqlite3_result_error(ctx,
            "fractalsql: table/column identifiers must be plain identifiers "
            "([A-Za-z_][A-Za-z0-9_]*)", -1);
        return;
    }
    int rows = da_table_has_rows(st, history_table, err, sizeof err);
    if (rows < 0) { da_result_err(ctx, err); return; }
    if (rows == 0) {
        char msg[256];
        snprintf(msg, sizeof msg,
                 "fractal_agent_outlier_intercept: no bad-state rows in %s", history_table);
        sqlite3_result_error(ctx, msg, -1);
        return;
    }

    int dim = 0;
    double *state = da_decode_vec(argv[0], &dim);
    if (!state) { sqlite3_result_error(ctx, "fractalsql: state_vec must be a CSV/JSON vector", -1); return; }
    char *state_json = da_vec_json(state, dim);
    free(state);
    if (!state_json) { sqlite3_result_error_nomem(ctx); return; }

    StrBuf fnsql; sb_init(&fnsql);
    sb_puts(&fnsql, "fractal_search_telemetry(");
    sb_sql_ident(&fnsql, history_table);
    sb_puts(&fnsql, ",");
    sb_sql_ident(&fnsql, emb_col);
    sb_puts(&fnsql, ",?1,1)");
    if (sb_failed(&fnsql)) { sb_free(&fnsql); free(state_json); sqlite3_result_error_nomem(ctx); return; }
    OneText bind = { state_json };
    int64_t doc_id = -1; double dist = 0.0;
    int rc = da_nearest1(st, fnsql.buf, bind_one_text, &bind, &doc_id, &dist, err, sizeof err);
    sb_free(&fnsql);
    free(state_json);
    if (rc != 0) { da_result_err(ctx, err); return; }
    if (doc_id < 0) {
        char msg[256];
        snprintf(msg, sizeof msg,
                 "fractal_agent_outlier_intercept: no bad-state rows in %s", history_table);
        sqlite3_result_error(ctx, msg, -1);
        return;
    }

    int intercepted = dist < threshold;
    StrBuf prompt; sb_init(&prompt);
    sb_printf(&prompt,
             "Outlier intercept: nearest known-bad state is at cosine distance "
             "%.10f, threshold %.10f, so %s. Justify the decision in one sentence.",
             dist, threshold, intercepted ? "INTERCEPT" : "allow");
    StrBuf cjson; sb_init(&cjson);
    sb_printf(&cjson, "{\"threshold\":%.10f,\"intercepted\":%s}",
             threshold, intercepted ? "true" : "false");
    if (sb_failed(&prompt) || sb_failed(&cjson)) {
        sb_free(&prompt); sb_free(&cjson);
        sqlite3_result_error_nomem(ctx);
        return;
    }
    char *reason = da_reason(st, "fractal_agent_outlier_intercept", prompt.buf, cjson.buf,
                             err, sizeof err);
    sb_free(&prompt); sb_free(&cjson);
    if (!reason) { da_result_err(ctx, err); return; }

    StrBuf audit; sb_init(&audit);
    sb_printf(&audit, "{\"intercepted\":%s,\"nearest_distance\":%.10f,"
                      "\"threshold\":%.10f,\"reason\":",
             intercepted ? "true" : "false", dist, threshold);
    sb_json_string(&audit, reason);
    sb_puts(&audit, "}");
    if (!sb_failed(&audit))
        da_audit_log_best_effort(st, "agent_outlier_intercept", audit.buf);
    sb_free(&audit);

    StrBuf out; sb_init(&out);
    sb_printf(&out, "{\"intercepted\":%s,\"reason\":", intercepted ? "true" : "false");
    sb_json_string(&out, reason);
    sb_puts(&out, "}");
    free(reason);
    if (sb_failed(&out)) { sb_free(&out); sqlite3_result_error_nomem(ctx); return; }
    sqlite3_result_text(ctx, out.buf, (int)out.len, SQLITE_TRANSIENT);
    sb_free(&out);
}

/* ======================================================================
 * Engine E: fractal_agent_recall_hybrid(mem_table, vec_col, query_vec,
 *   filter_col DEFAULT NULL, filter_val DEFAULT NULL, k DEFAULT 5,
 *   id_col DEFAULT 'id', content_col DEFAULT NULL)
 *   -> TEXT JSON array of {mem_id, content}. No LLM step.
 * ====================================================================== */
static void agent_recall_hybrid_fn(sqlite3_context *ctx, int argc,
                                   sqlite3_value **argv) {
    FsqlState *st = (FsqlState *)sqlite3_user_data(ctx);
    char err[512];
    if (argc < 3 || argc > 8) {
        sqlite3_result_error(ctx,
            "fractal_agent_recall_hybrid(mem_table, vec_col, query_vec "
            "[, filter_col, filter_val, k, id_col, content_col]) expects 3 to 8 args", -1);
        return;
    }
    if (sqlite3_value_type(argv[0]) == SQLITE_NULL ||
        sqlite3_value_type(argv[1]) == SQLITE_NULL ||
        sqlite3_value_type(argv[2]) == SQLITE_NULL) {
        sqlite3_result_error(ctx,
            "fractal_agent_recall_hybrid: mem_table, vec_col, query_vec are required", -1);
        return;
    }
    const char *mem_table = (const char *)sqlite3_value_text(argv[0]);
    const char *vec_col   = (const char *)sqlite3_value_text(argv[1]);
    const char *filter_col = (argc >= 4 && sqlite3_value_type(argv[3]) != SQLITE_NULL)
                            ? (const char *)sqlite3_value_text(argv[3]) : NULL;
    const char *filter_val = (argc >= 5 && sqlite3_value_type(argv[4]) != SQLITE_NULL)
                            ? (const char *)sqlite3_value_text(argv[4]) : NULL;
    int k = (argc >= 6 && sqlite3_value_type(argv[5]) != SQLITE_NULL)
          ? sqlite3_value_int(argv[5]) : 5;
    const char *id_col = (argc >= 7 && sqlite3_value_type(argv[6]) != SQLITE_NULL)
                        ? (const char *)sqlite3_value_text(argv[6]) : "id";
    const char *content_col = (argc >= 8 && sqlite3_value_type(argv[7]) != SQLITE_NULL)
                             ? (const char *)sqlite3_value_text(argv[7]) : NULL;
    if (!mem_table || !vec_col || !id_col) { sqlite3_result_error_nomem(ctx); return; }
    if (!da_ident_ok(mem_table) || !da_ident_ok(vec_col) || !da_ident_ok(id_col) ||
        (filter_col && !da_ident_ok(filter_col)) ||
        (content_col && !da_ident_ok(content_col))) {
        sqlite3_result_error(ctx,
            "fractalsql: table/column identifiers must be plain identifiers "
            "([A-Za-z_][A-Za-z0-9_]*)", -1);
        return;
    }

    char *cohort = da_build_cohort(st, mem_table, filter_col, filter_val, err, sizeof err);
    if (!cohort) {
        if (err[0]) { da_result_err(ctx, err); return; }
        char msg[256];
        snprintf(msg, sizeof msg,
                 "fractal_agent_recall_hybrid: filter matched no rows in %s", mem_table);
        sqlite3_result_error(ctx, msg, -1);
        return;
    }

    int dim = 0;
    double *qv = da_decode_vec(argv[2], &dim);
    if (!qv) { free(cohort); sqlite3_result_error(ctx, "fractalsql: query_vec must be a CSV/JSON vector", -1); return; }
    char *qv_json = da_vec_json(qv, dim);
    free(qv);
    if (!qv_json) { free(cohort); sqlite3_result_error_nomem(ctx); return; }

    StrBuf sql; sb_init(&sql);
    sb_puts(&sql, "SELECT '[' || group_concat(json_object('mem_id', x.idv, "
                  "'content', x.cnt)) || ']' FROM "
                  "(SELECT value AS j FROM json_each(fractal_hybrid_clinical_search(");
    sb_sql_lit(&sql, mem_table);
    sb_puts(&sql, ",");
    sb_sql_lit(&sql, vec_col);
    sb_printf(&sql, ",?1,?2,%d))) r JOIN "
             "(SELECT ", k);
    sb_sql_ident(&sql, id_col);
    sb_puts(&sql, " AS idv, ");
    if (content_col) sb_sql_ident(&sql, content_col); else sb_puts(&sql, "NULL");
    sb_puts(&sql, " AS cnt, row_number() OVER (ORDER BY rowid) - 1 AS __doc_id FROM ");
    sb_sql_ident(&sql, mem_table);
    sb_puts(&sql, ") x ON x.__doc_id = json_extract(r.j,'$.doc_id') "
                 "ORDER BY json_extract(r.j,'$.distance')");
    if (sb_failed(&sql)) {
        sb_free(&sql); free(cohort); free(qv_json);
        sqlite3_result_error_nomem(ctx);
        return;
    }
    TwoText bind = { qv_json, cohort };
    char *out_json = da_scalar_text(st, sql.buf, bind_two_text, &bind, err, sizeof err);
    sb_free(&sql);
    free(cohort); free(qv_json);
    if (!out_json) {
        /* da_scalar_text sets err on EVERY failure path, but only one of
         * them means "legitimately no matches": group_concat() over a
         * zero-row join evaluates to SQL NULL, which da_scalar_text
         * reports as this exact fixed sentinel string. Any other err
         * text is a real prepare/exec error (a genuine SQL failure, or
         * fractal_hybrid_clinical_search's own "doc_ids cohort matched
         * no rows in the corpus" propagated through sqlite3_errmsg) and
         * must NOT be swallowed into a clean-looking "[]" -- silently
         * discarding it here was hiding the actual failure reason
         * behind what looked like a valid empty result. */
        if (strcmp(err, "fractalsql: primitive call returned NULL") == 0) {
            sqlite3_result_text(ctx, "[]", 2, SQLITE_STATIC);
        } else {
            da_result_err(ctx, err);
        }
        return;
    }
    sqlite3_result_text(ctx, out_json, -1, SQLITE_TRANSIENT);
    free(out_json);
}

/* ======================================================================
 * Engine F: fractal_agent_recommend_diverse(catalog_table, emb_col,
 *   query_vec, k DEFAULT 10, id_col DEFAULT 'id')
 *   -> TEXT JSON array of {item_id, score}. No LLM step.
 * ====================================================================== */
static void agent_recommend_diverse_fn(sqlite3_context *ctx, int argc,
                                       sqlite3_value **argv) {
    FsqlState *st = (FsqlState *)sqlite3_user_data(ctx);
    char err[512];
    if (argc < 3 || argc > 5) {
        sqlite3_result_error(ctx,
            "fractal_agent_recommend_diverse(catalog_table, emb_col, query_vec "
            "[, k, id_col]) expects 3 to 5 args", -1);
        return;
    }
    if (sqlite3_value_type(argv[0]) == SQLITE_NULL ||
        sqlite3_value_type(argv[1]) == SQLITE_NULL ||
        sqlite3_value_type(argv[2]) == SQLITE_NULL) {
        sqlite3_result_error(ctx,
            "fractal_agent_recommend_diverse: catalog_table, emb_col, query_vec "
            "are required", -1);
        return;
    }
    const char *catalog_table = (const char *)sqlite3_value_text(argv[0]);
    const char *emb_col       = (const char *)sqlite3_value_text(argv[1]);
    int k = (argc >= 4 && sqlite3_value_type(argv[3]) != SQLITE_NULL)
          ? sqlite3_value_int(argv[3]) : 10;
    const char *id_col = (argc >= 5 && sqlite3_value_type(argv[4]) != SQLITE_NULL)
                        ? (const char *)sqlite3_value_text(argv[4]) : "id";
    if (!catalog_table || !emb_col || !id_col) { sqlite3_result_error_nomem(ctx); return; }
    if (!da_ident_ok(catalog_table) || !da_ident_ok(emb_col) || !da_ident_ok(id_col)) {
        sqlite3_result_error(ctx,
            "fractalsql: table/column identifiers must be plain identifiers "
            "([A-Za-z_][A-Za-z0-9_]*)", -1);
        return;
    }

    /* Enable session-global repulsion. Caller owns disabling it. */
    {
        sqlite3_stmt *stmt = NULL;
        if (sqlite3_prepare_v2(st->db, "SELECT fractal_diversify_enable()",
                               -1, &stmt, NULL) == SQLITE_OK)
            sqlite3_step(stmt);
        sqlite3_finalize(stmt);
    }

    int dim = 0;
    double *qv = da_decode_vec(argv[2], &dim);
    if (!qv) { sqlite3_result_error(ctx, "fractalsql: query_vec must be a CSV/JSON vector", -1); return; }
    char *qv_json = da_vec_json(qv, dim);
    free(qv);
    if (!qv_json) { sqlite3_result_error_nomem(ctx); return; }

    StrBuf sql; sb_init(&sql);
    sb_puts(&sql, "SELECT '[' || group_concat(json_object('item_id', x.idv, "
                  "'score', (1.0 - json_extract(r.j,'$.distance')))) || ']' FROM "
                  "(SELECT value AS j FROM json_each(fractal_search_telemetry(");
    sb_sql_ident(&sql, catalog_table);
    sb_puts(&sql, ",");
    sb_sql_ident(&sql, emb_col);
    sb_printf(&sql, ",?1,%d))) r JOIN "
             "(SELECT ", k);
    sb_sql_ident(&sql, id_col);
    sb_puts(&sql, " AS idv, row_number() OVER (ORDER BY rowid) - 1 AS __doc_id FROM ");
    sb_sql_ident(&sql, catalog_table);
    sb_puts(&sql, ") x ON x.__doc_id = json_extract(r.j,'$.doc_id') "
                 "ORDER BY json_extract(r.j,'$.distance')");
    if (sb_failed(&sql)) { sb_free(&sql); free(qv_json); sqlite3_result_error_nomem(ctx); return; }
    OneText bind = { qv_json };
    char *out_json = da_scalar_text(st, sql.buf, bind_one_text, &bind, err, sizeof err);
    sb_free(&sql);
    free(qv_json);
    if (!out_json) { da_result_err(ctx, err); return; }
    sqlite3_result_text(ctx, out_json, -1, SQLITE_TRANSIENT);
    free(out_json);
}

/* ======================================================================
 * Engine G: fractal_agent_data_analyst(question, table_names DEFAULT
 *   NULL, max_retries DEFAULT 2, context DEFAULT '{}')
 *   -> TEXT JSON {analysis, generated_sql, result_json}
 * ====================================================================== */
static void agent_data_analyst_fn(sqlite3_context *ctx, int argc,
                                  sqlite3_value **argv) {
    FsqlState *st = (FsqlState *)sqlite3_user_data(ctx);
    char err[512];
    if (argc < 1 || argc > 4) {
        sqlite3_result_error(ctx,
            "fractal_agent_data_analyst(question [, table_names, max_retries, "
            "context]) expects 1 to 4 args", -1);
        return;
    }
    if (sqlite3_value_type(argv[0]) == SQLITE_NULL) {
        sqlite3_result_error(ctx, "fractal_agent_data_analyst: question must not be NULL", -1);
        return;
    }
    const char *question = (const char *)sqlite3_value_text(argv[0]);
    const char *table_names = (argc >= 2 && sqlite3_value_type(argv[1]) != SQLITE_NULL)
                             ? (const char *)sqlite3_value_text(argv[1]) : NULL;
    int max_retries = (argc >= 3 && sqlite3_value_type(argv[2]) != SQLITE_NULL)
                     ? sqlite3_value_int(argv[2]) : 2;
    const char *context = (argc >= 4 && sqlite3_value_type(argv[3]) != SQLITE_NULL)
                         ? (const char *)sqlite3_value_text(argv[3]) : "{}";
    if (!question) { sqlite3_result_error_nomem(ctx); return; }
    if (!context) context = "{}";

    StrBuf sql; sb_init(&sql);
    sb_printf(&sql, "SELECT fractal_sql_agent(?1,?2,%d,1)", max_retries);
    if (sb_failed(&sql)) { sb_free(&sql); sqlite3_result_error_nomem(ctx); return; }
    sqlite3_stmt *stmt = NULL;
    int rc = sqlite3_prepare_v2(st->db, sql.buf, -1, &stmt, NULL);
    sb_free(&sql);
    if (rc != SQLITE_OK) {
        char msg[256]; snprintf(msg, sizeof msg, "fractalsql: %s", sqlite3_errmsg(st->db));
        sqlite3_result_error(ctx, msg, -1);
        return;
    }
    sqlite3_bind_text(stmt, 1, question, -1, SQLITE_TRANSIENT);
    if (table_names) sqlite3_bind_text(stmt, 2, table_names, -1, SQLITE_TRANSIENT);
    else             sqlite3_bind_null(stmt, 2);
    rc = sqlite3_step(stmt);
    if (rc != SQLITE_ROW) {
        char msg[512];
        snprintf(msg, sizeof msg, "fractalsql: %s", sqlite3_errmsg(st->db));
        sqlite3_finalize(stmt);
        sqlite3_result_error(ctx, msg, -1);
        return;
    }
    const unsigned char *res_t = sqlite3_column_text(stmt, 0);
    char *res = res_t ? strdup((const char *)res_t) : NULL;
    sqlite3_finalize(stmt);
    if (!res) { sqlite3_result_error(ctx, "fractalsql: fractal_sql_agent returned NULL", -1); return; }

    char *generated_sql = da_scalar_text(st,
        "SELECT json_extract(?1,'$.generated_sql')", bind_one_text,
        &(OneText){ res }, err, sizeof err);
    char *result_json = da_scalar_text(st,
        "SELECT json_extract(?1,'$.result_json')", bind_one_text,
        &(OneText){ res }, err, sizeof err);
    char *execution_status = da_scalar_text(st,
        "SELECT json_extract(?1,'$.execution_status')", bind_one_text,
        &(OneText){ res }, err, sizeof err);
    free(res);

    StrBuf prompt; sb_init(&prompt);
    sb_puts(&prompt, "Analyze this database query result and answer in one "
                    "paragraph: ");
    sb_puts(&prompt, result_json ? result_json : "null");
    if (sb_failed(&prompt)) {
        sb_free(&prompt); free(generated_sql); free(result_json); free(execution_status);
        sqlite3_result_error_nomem(ctx);
        return;
    }
    char *analysis = da_reason(st, "fractal_agent_data_analyst", prompt.buf, context,
                               err, sizeof err);
    sb_free(&prompt);
    if (!analysis) {
        free(generated_sql); free(result_json); free(execution_status);
        da_result_err(ctx, err); return;
    }

    StrBuf audit; sb_init(&audit);
    sb_puts(&audit, "{\"question\":");
    sb_json_string(&audit, question);
    sb_puts(&audit, ",\"generated_sql\":");
    if (generated_sql) sb_json_raw_or_string(&audit, generated_sql); else sb_puts(&audit, "null");
    sb_puts(&audit, ",\"execution_status\":");
    if (execution_status) sb_json_raw_or_string(&audit, execution_status); else sb_puts(&audit, "null");
    sb_puts(&audit, ",\"analysis\":");
    sb_json_string(&audit, analysis);
    sb_puts(&audit, "}");
    if (!sb_failed(&audit))
        da_audit_log_best_effort(st, "agent_data_analyst", audit.buf);
    sb_free(&audit);
    free(execution_status);

    StrBuf out; sb_init(&out);
    sb_puts(&out, "{\"analysis\":");
    sb_json_string(&out, analysis);
    sb_puts(&out, ",\"generated_sql\":");
    if (generated_sql) sb_json_raw_or_string(&out, generated_sql); else sb_puts(&out, "null");
    sb_puts(&out, ",\"result_json\":");
    sb_json_raw_or_string(&out, result_json);
    sb_puts(&out, "}");
    free(analysis); free(generated_sql); free(result_json);
    if (sb_failed(&out)) { sb_free(&out); sqlite3_result_error_nomem(ctx); return; }
    sqlite3_result_text(ctx, out.buf, (int)out.len, SQLITE_TRANSIENT);
    sb_free(&out);
}

/* ======================================================================
 * Engine H: fractal_agent_patient_deterioration_triage(patient_table,
 *   vec_col, query_vec, baseline_vec, current_vec,
 *   cohort_doc_ids DEFAULT NULL, k DEFAULT 5, id_col DEFAULT 'id')
 *   -> TEXT JSON {nearest_cohort_id, cohort_distance, drift_distance,
 *                 rationale, cohort_matches}
 * ====================================================================== */
static void agent_patient_deterioration_triage_fn(sqlite3_context *ctx, int argc,
                                                   sqlite3_value **argv) {
    FsqlState *st = (FsqlState *)sqlite3_user_data(ctx);
    char err[512];
    if (argc < 5 || argc > 8) {
        sqlite3_result_error(ctx,
            "fractal_agent_patient_deterioration_triage(patient_table, vec_col, "
            "query_vec, baseline_vec, current_vec [, cohort_doc_ids, k, id_col]) "
            "expects 5 to 8 args", -1);
        return;
    }
    for (int i = 0; i < 5; i++) {
        if (sqlite3_value_type(argv[i]) == SQLITE_NULL) {
            sqlite3_result_error(ctx,
                "fractal_agent_patient_deterioration_triage: the first five "
                "arguments are required", -1);
            return;
        }
    }
    const char *patient_table = (const char *)sqlite3_value_text(argv[0]);
    const char *vec_col       = (const char *)sqlite3_value_text(argv[1]);
    const char *cohort_ids_json = (argc >= 6 && sqlite3_value_type(argv[5]) != SQLITE_NULL)
                                 ? (const char *)sqlite3_value_text(argv[5]) : NULL;
    int k = (argc >= 7 && sqlite3_value_type(argv[6]) != SQLITE_NULL)
          ? sqlite3_value_int(argv[6]) : 5;
    const char *id_col = (argc >= 8 && sqlite3_value_type(argv[7]) != SQLITE_NULL)
                        ? (const char *)sqlite3_value_text(argv[7]) : "id";
    if (!patient_table || !vec_col || !id_col) { sqlite3_result_error_nomem(ctx); return; }
    if (!da_ident_ok(patient_table) || !da_ident_ok(vec_col) || !da_ident_ok(id_col)) {
        sqlite3_result_error(ctx,
            "fractalsql: table/column identifiers must be plain identifiers "
            "([A-Za-z_][A-Za-z0-9_]*)", -1);
        return;
    }
    int rows = da_table_has_rows(st, patient_table, err, sizeof err);
    if (rows < 0) { da_result_err(ctx, err); return; }
    if (rows == 0) {
        char msg[256];
        snprintf(msg, sizeof msg,
                 "fractal_agent_patient_deterioration_triage: no patient rows in %s",
                 patient_table);
        sqlite3_result_error(ctx, msg, -1);
        return;
    }

    char *cohort = NULL;
    if (cohort_ids_json) {
        cohort = strdup(cohort_ids_json);
    } else {
        cohort = da_build_cohort(st, patient_table, NULL, NULL, err, sizeof err);
    }
    if (!cohort) {
        if (err[0]) { da_result_err(ctx, err); return; }
        char msg[256];
        snprintf(msg, sizeof msg,
                 "fractal_agent_patient_deterioration_triage: cohort matched no "
                 "rows in %s", patient_table);
        sqlite3_result_error(ctx, msg, -1);
        return;
    }

    int qdim = 0;
    double *qv = da_decode_vec(argv[2], &qdim);
    if (!qv) { free(cohort); sqlite3_result_error(ctx, "fractalsql: query_vec must be a CSV/JSON vector", -1); return; }
    char *qv_json = da_vec_json(qv, qdim);
    free(qv);

    /* Cohort matches: up to k nearest patients, resolved to named id. */
    StrBuf sql; sb_init(&sql);
    sb_puts(&sql, "SELECT '[' || group_concat(json_object('id', x.idv, "
                  "'distance', json_extract(r.j,'$.distance'))) || ']' FROM "
                  "(SELECT value AS j FROM json_each(fractal_hybrid_clinical_search(");
    sb_sql_lit(&sql, patient_table);
    sb_puts(&sql, ",");
    sb_sql_lit(&sql, vec_col);
    sb_printf(&sql, ",?1,?2,%d))) r JOIN "
             "(SELECT ", k);
    sb_sql_ident(&sql, id_col);
    sb_puts(&sql, " AS idv, row_number() OVER (ORDER BY rowid) - 1 AS __doc_id FROM ");
    sb_sql_ident(&sql, patient_table);
    sb_puts(&sql, ") x ON x.__doc_id = json_extract(r.j,'$.doc_id') "
                 "ORDER BY json_extract(r.j,'$.distance')");
    if (sb_failed(&sql) || !qv_json) {
        sb_free(&sql); free(cohort); free(qv_json);
        sqlite3_result_error_nomem(ctx);
        return;
    }
    TwoText bind = { qv_json, cohort };
    char *matches = da_scalar_text(st, sql.buf, bind_two_text, &bind, err, sizeof err);
    sb_free(&sql); free(cohort); free(qv_json);
    if (!matches || strcmp(matches, "[]") == 0) {
        free(matches);
        char msg[256];
        snprintf(msg, sizeof msg,
                 "fractal_agent_patient_deterioration_triage: hybrid search "
                 "returned no row in %s", patient_table);
        sqlite3_result_error(ctx, msg, -1);
        return;
    }
    char *resolved_id = da_scalar_text(st, "SELECT json_extract(?1,'$[0].id')",
                                       bind_one_text, &(OneText){ matches }, err, sizeof err);
    double cohort_dist = da_json_num(st, matches, "$[0].distance");

    /* Baseline -> current drift, single result. */
    int bdim = 0, cdim = 0;
    double *bv = da_decode_vec(argv[3], &bdim);
    double *cv = da_decode_vec(argv[4], &cdim);
    if (!bv || !cv) {
        free(bv); free(cv); free(matches); free(resolved_id);
        sqlite3_result_error(ctx, "fractalsql: baseline_vec/current_vec must be CSV/JSON vectors", -1);
        return;
    }
    char *bv_json = da_vec_json(bv, bdim);
    char *cv_json = da_vec_json(cv, cdim);
    free(bv); free(cv);
    StrBuf trajsql; sb_init(&trajsql);
    sb_puts(&trajsql, "fractal_search_trajectory(");
    sb_sql_ident(&trajsql, patient_table);
    sb_puts(&trajsql, ",");
    sb_sql_ident(&trajsql, vec_col);
    sb_puts(&trajsql, ",?1,?2,1)");
    if (sb_failed(&trajsql) || !bv_json || !cv_json) {
        sb_free(&trajsql); free(bv_json); free(cv_json); free(matches); free(resolved_id);
        sqlite3_result_error_nomem(ctx);
        return;
    }
    TwoText tbind = { bv_json, cv_json };
    int64_t traj_doc = -1; double traj_dist = 0.0;
    int rc = da_nearest1(st, trajsql.buf, bind_two_text, &tbind, &traj_doc, &traj_dist,
                         err, sizeof err);
    sb_free(&trajsql); free(bv_json); free(cv_json);
    if (rc != 0) { free(matches); free(resolved_id); da_result_err(ctx, err); return; }

    StrBuf prompt; sb_init(&prompt);
    sb_printf(&prompt,
             "Triage this patient: nearest cohort match is id %s at cosine "
             "distance %.10f; baseline->current drift distance is %.10f. "
             "Justify the deterioration triage in one sentence.",
             resolved_id ? resolved_id : "?", cohort_dist, traj_dist);
    StrBuf cjson; sb_init(&cjson);
    sb_printf(&cjson, "{\"cohort_distance\":%.10f,\"drift_distance\":%.10f}",
             cohort_dist, traj_dist);
    if (sb_failed(&prompt) || sb_failed(&cjson)) {
        sb_free(&prompt); sb_free(&cjson); free(matches); free(resolved_id);
        sqlite3_result_error_nomem(ctx);
        return;
    }
    char *rationale = da_reason(st, "fractal_agent_patient_deterioration_triage",
                                prompt.buf, cjson.buf, err, sizeof err);
    sb_free(&prompt); sb_free(&cjson);
    if (!rationale) { free(matches); free(resolved_id); da_result_err(ctx, err); return; }

    StrBuf audit; sb_init(&audit);
    sb_puts(&audit, "{\"nearest_cohort_id\":");
    if (resolved_id) sb_json_id_value(&audit, resolved_id); else sb_puts(&audit, "null");
    sb_printf(&audit, ",\"cohort_distance\":%.10f,\"drift_distance\":%.10f,"
             "\"rationale\":", cohort_dist, traj_dist);
    sb_json_string(&audit, rationale);
    sb_puts(&audit, ",\"cohort_matches\":");
    sb_json_raw_or_string(&audit, matches);
    sb_puts(&audit, "}");
    if (!sb_failed(&audit))
        da_audit_log_best_effort(st, "agent_patient_deterioration_triage", audit.buf);
    sb_free(&audit);

    StrBuf out; sb_init(&out);
    sb_puts(&out, "{\"nearest_cohort_id\":");
    if (resolved_id) sb_json_id_value(&out, resolved_id); else sb_puts(&out, "null");
    sb_printf(&out, ",\"cohort_distance\":%.10f,\"drift_distance\":%.10f,"
             "\"rationale\":", cohort_dist, traj_dist);
    sb_json_string(&out, rationale);
    sb_puts(&out, ",\"cohort_matches\":");
    sb_json_raw_or_string(&out, matches);
    sb_puts(&out, "}");
    free(matches); free(resolved_id); free(rationale);
    if (sb_failed(&out)) { sb_free(&out); sqlite3_result_error_nomem(ctx); return; }
    sqlite3_result_text(ctx, out.buf, (int)out.len, SQLITE_TRANSIENT);
    sb_free(&out);
}

/* ======================================================================
 * Engine I: fractal_agent_feedback_audit(catalog_table, emb_col,
 *   query_vec, warmup_table, warmup_vec_col, warmup_count DEFAULT 8,
 *   k DEFAULT 3) -> TEXT JSON {diversity_quotient, explanation}
 *   Pure analytics, no LLM step. Self-contained: disables diversify
 *   itself at the end (unlike Engine F, which leaves it on).
 * ====================================================================== */
static void agent_feedback_audit_fn(sqlite3_context *ctx, int argc,
                                    sqlite3_value **argv) {
    FsqlState *st = (FsqlState *)sqlite3_user_data(ctx);
    char err[512];
    if (argc < 5 || argc > 7) {
        sqlite3_result_error(ctx,
            "fractal_agent_feedback_audit(catalog_table, emb_col, query_vec, "
            "warmup_table, warmup_vec_col [, warmup_count, k]) expects 5 to 7 args", -1);
        return;
    }
    for (int i = 0; i < 5; i++) {
        if (sqlite3_value_type(argv[i]) == SQLITE_NULL) {
            sqlite3_result_error(ctx,
                "fractal_agent_feedback_audit: the first five arguments are required", -1);
            return;
        }
    }
    const char *catalog_table  = (const char *)sqlite3_value_text(argv[0]);
    const char *emb_col        = (const char *)sqlite3_value_text(argv[1]);
    const char *warmup_table   = (const char *)sqlite3_value_text(argv[3]);
    const char *warmup_vec_col = (const char *)sqlite3_value_text(argv[4]);
    int warmup_count = (argc >= 6 && sqlite3_value_type(argv[5]) != SQLITE_NULL)
                      ? sqlite3_value_int(argv[5]) : 8;
    int k = (argc >= 7 && sqlite3_value_type(argv[6]) != SQLITE_NULL)
          ? sqlite3_value_int(argv[6]) : 3;
    if (!catalog_table || !emb_col || !warmup_table || !warmup_vec_col) {
        sqlite3_result_error_nomem(ctx); return;
    }
    if (!da_ident_ok(catalog_table) || !da_ident_ok(emb_col) ||
        !da_ident_ok(warmup_table) || !da_ident_ok(warmup_vec_col)) {
        sqlite3_result_error(ctx,
            "fractalsql: table/column identifiers must be plain identifiers "
            "([A-Za-z_][A-Za-z0-9_]*)", -1);
        return;
    }
    int rows = da_table_has_rows(st, catalog_table, err, sizeof err);
    if (rows < 0) { da_result_err(ctx, err); return; }
    if (rows == 0) {
        char msg[256];
        snprintf(msg, sizeof msg,
                 "fractal_agent_feedback_audit: no catalog rows in %s", catalog_table);
        sqlite3_result_error(ctx, msg, -1);
        return;
    }

    /* 1. Enable repulsion + the audit defaults. */
    {
        sqlite3_stmt *stmt = NULL;
        if (sqlite3_prepare_v2(st->db, "SELECT fractal_diversify_enable()",
                               -1, &stmt, NULL) == SQLITE_OK) sqlite3_step(stmt);
        sqlite3_finalize(stmt); stmt = NULL;
        if (sqlite3_prepare_v2(st->db,
                "SELECT fractal_diversify_set_params("
                "'{\"window_n\":5,\"repulsion_sigma\":0.3,\"repulsion_weight\":0.5}')",
                -1, &stmt, NULL) == SQLITE_OK) sqlite3_step(stmt);
        sqlite3_finalize(stmt);
    }

    /* 2. Warm the D_q rolling window with warmup_count varied queries. */
    {
        StrBuf wsql; sb_init(&wsql);
        sb_puts(&wsql, "SELECT ");
        sb_sql_ident(&wsql, warmup_vec_col);
        sb_puts(&wsql, " FROM ");
        sb_sql_ident(&wsql, warmup_table);
        sb_printf(&wsql, " LIMIT %d", warmup_count);
        if (!sb_failed(&wsql)) {
            sqlite3_stmt *wstmt = NULL;
            if (sqlite3_prepare_v2(st->db, wsql.buf, -1, &wstmt, NULL) == SQLITE_OK) {
                while (sqlite3_step(wstmt) == SQLITE_ROW) {
                    const unsigned char *vtxt = sqlite3_column_text(wstmt, 0);
                    if (!vtxt) continue;
                    StrBuf tsql; sb_init(&tsql);
                    sb_puts(&tsql, "SELECT fractal_search_telemetry(");
                    sb_sql_ident(&tsql, catalog_table);
                    sb_puts(&tsql, ",");
                    sb_sql_ident(&tsql, emb_col);
                    sb_printf(&tsql, ",?1,%d)", k);
                    if (!sb_failed(&tsql)) {
                        sqlite3_stmt *tstmt = NULL;
                        if (sqlite3_prepare_v2(st->db, tsql.buf, -1, &tstmt, NULL) == SQLITE_OK) {
                            sqlite3_bind_text(tstmt, 1, (const char *)vtxt, -1, SQLITE_TRANSIENT);
                            sqlite3_step(tstmt);
                        }
                        sqlite3_finalize(tstmt);
                    }
                    sb_free(&tsql);
                }
            }
            sqlite3_finalize(wstmt);
        }
        sb_free(&wsql);
    }

    /* 3. Capture the audit target's top doc_id, report negative feedback. */
    int dim = 0;
    double *qv = da_decode_vec(argv[2], &dim);
    if (!qv) { sqlite3_result_error(ctx, "fractalsql: query_vec must be a CSV/JSON vector", -1); return; }
    char *qv_json = da_vec_json(qv, dim);
    free(qv);
    if (!qv_json) { sqlite3_result_error_nomem(ctx); return; }
    StrBuf tsql; sb_init(&tsql);
    sb_puts(&tsql, "fractal_search_telemetry(");
    sb_sql_ident(&tsql, catalog_table);
    sb_puts(&tsql, ",");
    sb_sql_ident(&tsql, emb_col);
    sb_puts(&tsql, ",?1,1)");
    if (sb_failed(&tsql)) { sb_free(&tsql); free(qv_json); sqlite3_result_error_nomem(ctx); return; }
    OneText bind = { qv_json };
    int64_t target_doc = -1; double target_dist = 0.0;
    int rc = da_nearest1(st, tsql.buf, bind_one_text, &bind, &target_doc, &target_dist,
                         err, sizeof err);
    sb_free(&tsql); free(qv_json);
    if (rc != 0) { da_result_err(ctx, err); return; }
    if (target_doc >= 0) {
        sqlite3_stmt *stmt = NULL;
        if (sqlite3_prepare_v2(st->db, "SELECT fractal_isolate_background(?1)",
                               -1, &stmt, NULL) == SQLITE_OK) {
            sqlite3_bind_int64(stmt, 1, (sqlite3_int64)target_doc);
            sqlite3_step(stmt);
        }
        sqlite3_finalize(stmt);
    }

    /* 4. Pure analytics: diversity quotient + session diagnostics. */
    double dq = 0.0;
    {
        sqlite3_stmt *stmt = NULL;
        if (sqlite3_prepare_v2(st->db, "SELECT fractal_detect_collapse()",
                               -1, &stmt, NULL) == SQLITE_OK) {
            if (sqlite3_step(stmt) == SQLITE_ROW) dq = sqlite3_column_double(stmt, 0);
        }
        sqlite3_finalize(stmt);
    }
    char *diag = da_scalar_text(st, "SELECT fractal_explain_result()", NULL, NULL,
                                err, sizeof err);

    /* 5. Self-contained: disable diversify. */
    {
        sqlite3_stmt *stmt = NULL;
        if (sqlite3_prepare_v2(st->db, "SELECT fractal_diversify_disable()",
                               -1, &stmt, NULL) == SQLITE_OK) sqlite3_step(stmt);
        sqlite3_finalize(stmt);
    }

    StrBuf out; sb_init(&out);
    sb_printf(&out, "{\"diversity_quotient\":%.10f,\"explanation\":", dq);
    sb_json_raw_or_string(&out, diag);
    sb_puts(&out, "}");
    free(diag);
    if (sb_failed(&out)) { sb_free(&out); sqlite3_result_error_nomem(ctx); return; }
    sqlite3_result_text(ctx, out.buf, (int)out.len, SQLITE_TRANSIENT);
    sb_free(&out);
}

/* ======================================================================
 * Engine J: fractal_agent_schedule_workload(task_vec, node_table,
 *   node_emb_col, node_id_col, iterations DEFAULT 30, population
 *   DEFAULT 50, k DEFAULT 5, context DEFAULT '{}')
 *   -> TEXT JSON {assigned_node, confidence, rationale}
 * ====================================================================== */
static void agent_schedule_workload_fn(sqlite3_context *ctx, int argc,
                                       sqlite3_value **argv) {
    FsqlState *st = (FsqlState *)sqlite3_user_data(ctx);
    char err[512];
    if (argc < 4 || argc > 8) {
        sqlite3_result_error(ctx,
            "fractal_agent_schedule_workload(task_vec, node_table, node_emb_col, "
            "node_id_col [, iterations, population, k, context]) expects 4 to 8 args", -1);
        return;
    }
    for (int i = 0; i < 4; i++) {
        if (sqlite3_value_type(argv[i]) == SQLITE_NULL) {
            sqlite3_result_error(ctx,
                "fractal_agent_schedule_workload: the first four arguments are required", -1);
            return;
        }
    }
    const char *node_table    = (const char *)sqlite3_value_text(argv[1]);
    const char *node_emb_col  = (const char *)sqlite3_value_text(argv[2]);
    const char *node_id_col   = (const char *)sqlite3_value_text(argv[3]);
    int iterations = (argc >= 5 && sqlite3_value_type(argv[4]) != SQLITE_NULL)
                    ? sqlite3_value_int(argv[4]) : 30;
    int population = (argc >= 6 && sqlite3_value_type(argv[5]) != SQLITE_NULL)
                    ? sqlite3_value_int(argv[5]) : 50;
    const char *context = (argc >= 8 && sqlite3_value_type(argv[7]) != SQLITE_NULL)
                         ? (const char *)sqlite3_value_text(argv[7]) : "{}";
    if (!node_table || !node_emb_col || !node_id_col) { sqlite3_result_error_nomem(ctx); return; }
    if (!context) context = "{}";
    if (!da_ident_ok(node_table) || !da_ident_ok(node_emb_col) || !da_ident_ok(node_id_col)) {
        sqlite3_result_error(ctx,
            "fractalsql: table/column identifiers must be plain identifiers "
            "([A-Za-z_][A-Za-z0-9_]*)", -1);
        return;
    }
    int rows = da_table_has_rows(st, node_table, err, sizeof err);
    if (rows < 0) { da_result_err(ctx, err); return; }
    if (rows == 0) {
        char msg[256];
        snprintf(msg, sizeof msg,
                 "fractal_agent_schedule_workload: no node rows in %s", node_table);
        sqlite3_result_error(ctx, msg, -1);
        return;
    }

    int dim = 0;
    double *task = da_decode_vec(argv[0], &dim);
    if (!task) { sqlite3_result_error(ctx, "fractalsql: task_vec must be a CSV/JSON vector", -1); return; }
    char *task_json = da_vec_json(task, dim);
    free(task);
    if (!task_json) { sqlite3_result_error_nomem(ctx); return; }

    /* 1. Refine the task vector (fractal_search's "sniper search"). */
    char callsql[160];
    snprintf(callsql, sizeof callsql,
             "SELECT json_extract(fractal_search_debug(?1,%d,%d,2),'$.best_point')",
             iterations, population);
    char *refined_json = da_scalar_text(st, callsql, bind_one_text,
                                        &(OneText){ task_json }, err, sizeof err);
    free(task_json);
    if (!refined_json) { da_result_err(ctx, err); return; }

    /* 2. Nearest node to the refined task vector. */
    StrBuf fnsql; sb_init(&fnsql);
    sb_puts(&fnsql, "fractal_search_telemetry(");
    sb_sql_ident(&fnsql, node_table);
    sb_puts(&fnsql, ",");
    sb_sql_ident(&fnsql, node_emb_col);
    sb_puts(&fnsql, ",?1,1)");
    if (sb_failed(&fnsql)) { sb_free(&fnsql); free(refined_json); sqlite3_result_error_nomem(ctx); return; }
    OneText bind = { refined_json };
    int64_t doc_id = -1; double dist = 0.0;
    int rc = da_nearest1(st, fnsql.buf, bind_one_text, &bind, &doc_id, &dist, err, sizeof err);
    sb_free(&fnsql); free(refined_json);
    if (rc != 0) { da_result_err(ctx, err); return; }
    if (doc_id < 0) {
        char msg[256];
        snprintf(msg, sizeof msg,
                 "fractal_agent_schedule_workload: no node rows in %s", node_table);
        sqlite3_result_error(ctx, msg, -1);
        return;
    }

    char *assigned = da_resolve_id(st, node_table, node_id_col, doc_id, err, sizeof err);
    if (!assigned && err[0]) { da_result_err(ctx, err); return; }

    StrBuf prompt; sb_init(&prompt);
    sb_printf(&prompt,
             "Schedule this workload onto node %s (cosine distance %.10f after "
             "fractal_search refinement). Justify the placement in one sentence.",
             assigned ? assigned : "?", dist);
    if (sb_failed(&prompt)) { sb_free(&prompt); free(assigned); sqlite3_result_error_nomem(ctx); return; }
    char *rationale = da_reason(st, "fractal_agent_schedule_workload", prompt.buf, context,
                                err, sizeof err);
    sb_free(&prompt);
    if (!rationale) { free(assigned); da_result_err(ctx, err); return; }

    double confidence = 1.0 / (1.0 + dist);
    StrBuf audit; sb_init(&audit);
    sb_puts(&audit, "{\"assigned_node\":");
    if (assigned) sb_json_string(&audit, assigned); else sb_puts(&audit, "null");
    sb_printf(&audit, ",\"confidence\":%.10f,\"rationale\":", confidence);
    sb_json_string(&audit, rationale);
    sb_puts(&audit, "}");
    if (!sb_failed(&audit))
        da_audit_log_best_effort(st, "agent_schedule_workload", audit.buf);
    sb_free(&audit);

    StrBuf out; sb_init(&out);
    sb_puts(&out, "{\"assigned_node\":");
    if (assigned) sb_json_string(&out, assigned); else sb_puts(&out, "null");
    sb_printf(&out, ",\"confidence\":%.10f,\"rationale\":", confidence);
    sb_json_string(&out, rationale);
    sb_puts(&out, "}");
    free(assigned); free(rationale);
    if (sb_failed(&out)) { sb_free(&out); sqlite3_result_error_nomem(ctx); return; }
    sqlite3_result_text(ctx, out.buf, (int)out.len, SQLITE_TRANSIENT);
    sb_free(&out);
}

/* ======================================================================
 * Engine K: fractal_agent_rebalance_sibling(mu, cov, cardinality,
 *   alloc_table, alloc_emb_col, baseline_vec, seed DEFAULT NULL,
 *   k DEFAULT 5, id_col DEFAULT 'id', context DEFAULT '{}')
 *   -> TEXT JSON {sharpe, weights, nearest_alloc_id, nearest_distance,
 *                 rationale}
 * ====================================================================== */
static void agent_rebalance_sibling_fn(sqlite3_context *ctx, int argc,
                                       sqlite3_value **argv) {
    FsqlState *st = (FsqlState *)sqlite3_user_data(ctx);
    char err[512];
    if (argc < 6 || argc > 10) {
        sqlite3_result_error(ctx,
            "fractal_agent_rebalance_sibling(mu, cov, cardinality, alloc_table, "
            "alloc_emb_col, baseline_vec [, seed, k, id_col, context]) expects "
            "6 to 10 args", -1);
        return;
    }
    for (int i = 0; i < 6; i++) {
        if (sqlite3_value_type(argv[i]) == SQLITE_NULL) {
            sqlite3_result_error(ctx,
                "fractal_agent_rebalance_sibling: the first six arguments are required", -1);
            return;
        }
    }
    int cardinality = sqlite3_value_int(argv[2]);
    const char *alloc_table   = (const char *)sqlite3_value_text(argv[3]);
    const char *alloc_emb_col = (const char *)sqlite3_value_text(argv[4]);
    int have_seed = (argc >= 7 && sqlite3_value_type(argv[6]) != SQLITE_NULL);
    sqlite3_int64 seed = have_seed ? sqlite3_value_int64(argv[6]) : 0;
    const char *id_col = (argc >= 9 && sqlite3_value_type(argv[8]) != SQLITE_NULL)
                        ? (const char *)sqlite3_value_text(argv[8]) : "id";
    const char *context = (argc >= 10 && sqlite3_value_type(argv[9]) != SQLITE_NULL)
                         ? (const char *)sqlite3_value_text(argv[9]) : "{}";
    if (!alloc_table || !alloc_emb_col || !id_col) { sqlite3_result_error_nomem(ctx); return; }
    if (!context) context = "{}";
    if (!da_ident_ok(alloc_table) || !da_ident_ok(alloc_emb_col) || !da_ident_ok(id_col)) {
        sqlite3_result_error(ctx,
            "fractalsql: table/column identifiers must be plain identifiers "
            "([A-Za-z_][A-Za-z0-9_]*)", -1);
        return;
    }
    int rows = da_table_has_rows(st, alloc_table, err, sizeof err);
    if (rows < 0) { da_result_err(ctx, err); return; }
    if (rows == 0) {
        char msg[256];
        snprintf(msg, sizeof msg,
                 "fractal_agent_rebalance_sibling: no allocation rows in %s", alloc_table);
        sqlite3_result_error(ctx, msg, -1);
        return;
    }

    int mu_dim = 0, cov_dim = 0;
    double *mu = da_decode_vec(argv[0], &mu_dim);
    double *cov = da_decode_vec(argv[1], &cov_dim);
    if (!mu || !cov) {
        free(mu); free(cov);
        sqlite3_result_error(ctx, "fractalsql: mu/cov must be CSV/JSON vectors", -1);
        return;
    }
    char *mu_json = da_vec_json(mu, mu_dim);
    char *cov_json = da_vec_json(cov, cov_dim);
    free(mu); free(cov);

    char callsql[160];
    if (have_seed)
        snprintf(callsql, sizeof callsql,
                 "SELECT fractal_optimize_portfolio(?1,?2,%d,%lld)",
                 cardinality, (long long)seed);
    else
        /* Registered at arity 4/5/6 only, never 3: a bare seed-less
         * NULL keeps the core's default (random) seed. */
        snprintf(callsql, sizeof callsql,
                 "SELECT fractal_optimize_portfolio(?1,?2,%d,NULL)", cardinality);
    TwoText obind = { mu_json, cov_json };
    char *opt = da_scalar_text(st, callsql, bind_two_text, &obind, err, sizeof err);
    free(mu_json); free(cov_json);
    if (!opt) { da_result_err(ctx, err); return; }
    double sharpe = da_json_num(st, opt, "$.sharpe");
    char *weights_vec_json = da_scalar_text(st, "SELECT json_extract(?1,'$.weights')",
                                            bind_one_text, &(OneText){ opt }, err, sizeof err);

    int bdim = 0;
    double *bv = da_decode_vec(argv[5], &bdim);
    if (!bv || !weights_vec_json) {
        free(bv); free(opt); free(weights_vec_json);
        sqlite3_result_error(ctx, "fractalsql: baseline_vec must be a CSV/JSON vector", -1);
        return;
    }
    char *bv_json = da_vec_json(bv, bdim);
    free(bv);

    StrBuf trajsql; sb_init(&trajsql);
    sb_puts(&trajsql, "fractal_search_trajectory(");
    sb_sql_ident(&trajsql, alloc_table);
    sb_puts(&trajsql, ",");
    sb_sql_ident(&trajsql, alloc_emb_col);
    sb_puts(&trajsql, ",?1,?2,1)");
    if (sb_failed(&trajsql) || !bv_json) {
        sb_free(&trajsql); free(bv_json); free(opt); free(weights_vec_json);
        sqlite3_result_error_nomem(ctx);
        return;
    }
    TwoText tbind = { bv_json, weights_vec_json };
    int64_t nearest_doc = -1; double nearest_dist = 0.0;
    int rc = da_nearest1(st, trajsql.buf, bind_two_text, &tbind, &nearest_doc, &nearest_dist,
                         err, sizeof err);
    sb_free(&trajsql); free(bv_json);
    if (rc != 0) { free(opt); free(weights_vec_json); da_result_err(ctx, err); return; }
    if (nearest_doc < 0) {
        free(opt); free(weights_vec_json);
        char msg[256];
        snprintf(msg, sizeof msg,
                 "fractal_agent_rebalance_sibling: no allocation rows in %s", alloc_table);
        sqlite3_result_error(ctx, msg, -1);
        return;
    }

    char *resolved_id = da_resolve_id(st, alloc_table, id_col, nearest_doc, err, sizeof err);
    if (!resolved_id && err[0]) { free(opt); free(weights_vec_json); da_result_err(ctx, err); return; }

    StrBuf prompt; sb_init(&prompt);
    sb_printf(&prompt,
             "Rebalance triage: the optimized portfolio has Sharpe %.10f and is "
             "nearest to historical allocation id %s (cosine distance %.10f). "
             "Justify the rebalance in one sentence.",
             sharpe, resolved_id ? resolved_id : "?", nearest_dist);
    if (sb_failed(&prompt)) {
        sb_free(&prompt); free(opt); free(weights_vec_json); free(resolved_id);
        sqlite3_result_error_nomem(ctx);
        return;
    }
    char *rationale = da_reason(st, "fractal_agent_rebalance_sibling", prompt.buf, context,
                                err, sizeof err);
    sb_free(&prompt);
    if (!rationale) { free(opt); free(weights_vec_json); free(resolved_id); da_result_err(ctx, err); return; }

    StrBuf audit; sb_init(&audit);
    sb_printf(&audit, "{\"sharpe\":%.10f,\"nearest_alloc_id\":", sharpe);
    if (resolved_id) sb_json_id_value(&audit, resolved_id); else sb_puts(&audit, "null");
    sb_printf(&audit, ",\"nearest_distance\":%.10f,\"rationale\":", nearest_dist);
    sb_json_string(&audit, rationale);
    sb_puts(&audit, "}");
    if (!sb_failed(&audit))
        da_audit_log_best_effort(st, "agent_rebalance_sibling", audit.buf);
    sb_free(&audit);

    StrBuf out; sb_init(&out);
    sb_printf(&out, "{\"sharpe\":%.10f,\"weights\":", sharpe);
    sb_json_raw_or_string(&out, weights_vec_json);
    sb_puts(&out, ",\"nearest_alloc_id\":");
    if (resolved_id) sb_json_id_value(&out, resolved_id); else sb_puts(&out, "null");
    sb_printf(&out, ",\"nearest_distance\":%.10f,\"rationale\":", nearest_dist);
    sb_json_string(&out, rationale);
    sb_puts(&out, "}");
    free(opt); free(weights_vec_json); free(resolved_id); free(rationale);
    if (sb_failed(&out)) { sb_free(&out); sqlite3_result_error_nomem(ctx); return; }
    sqlite3_result_text(ctx, out.buf, (int)out.len, SQLITE_TRANSIENT);
    sb_free(&out);
}

/* ======================================================================
 * Engine L: fractal_agent_detour_classify(vehicle_table, emb_col,
 *   baseline_vec, current_vec, gps_trace, k DEFAULT 5, id_col DEFAULT
 *   'id', boxcount_dim DEFAULT 2)
 *   -> TEXT JSON {nearest_fleet_id, trajectory_distance,
 *                 trace_complexity, rationale}
 * ====================================================================== */
static void agent_detour_classify_fn(sqlite3_context *ctx, int argc,
                                     sqlite3_value **argv) {
    FsqlState *st = (FsqlState *)sqlite3_user_data(ctx);
    char err[512];
    if (argc < 5 || argc > 8) {
        sqlite3_result_error(ctx,
            "fractal_agent_detour_classify(vehicle_table, emb_col, baseline_vec, "
            "current_vec, gps_trace [, k, id_col, boxcount_dim]) expects 5 to 8 args", -1);
        return;
    }
    for (int i = 0; i < 5; i++) {
        if (sqlite3_value_type(argv[i]) == SQLITE_NULL) {
            sqlite3_result_error(ctx,
                "fractal_agent_detour_classify: the first five arguments are required", -1);
            return;
        }
    }
    const char *vehicle_table = (const char *)sqlite3_value_text(argv[0]);
    const char *emb_col       = (const char *)sqlite3_value_text(argv[1]);
    const char *id_col = (argc >= 7 && sqlite3_value_type(argv[6]) != SQLITE_NULL)
                        ? (const char *)sqlite3_value_text(argv[6]) : "id";
    int boxcount_dim = (argc >= 8 && sqlite3_value_type(argv[7]) != SQLITE_NULL)
                      ? sqlite3_value_int(argv[7]) : 2;
    if (!vehicle_table || !emb_col || !id_col) { sqlite3_result_error_nomem(ctx); return; }
    if (!da_ident_ok(vehicle_table) || !da_ident_ok(emb_col) || !da_ident_ok(id_col)) {
        sqlite3_result_error(ctx,
            "fractalsql: table/column identifiers must be plain identifiers "
            "([A-Za-z_][A-Za-z0-9_]*)", -1);
        return;
    }
    int rows = da_table_has_rows(st, vehicle_table, err, sizeof err);
    if (rows < 0) { da_result_err(ctx, err); return; }
    if (rows == 0) {
        char msg[256];
        snprintf(msg, sizeof msg,
                 "fractal_agent_detour_classify: no vehicle rows in %s", vehicle_table);
        sqlite3_result_error(ctx, msg, -1);
        return;
    }

    int bdim = 0, cdim = 0;
    double *bv = da_decode_vec(argv[2], &bdim);
    double *cv = da_decode_vec(argv[3], &cdim);
    if (!bv || !cv) {
        free(bv); free(cv);
        sqlite3_result_error(ctx, "fractalsql: baseline_vec/current_vec must be CSV/JSON vectors", -1);
        return;
    }
    char *bv_json = da_vec_json(bv, bdim);
    char *cv_json = da_vec_json(cv, cdim);
    free(bv); free(cv);

    StrBuf trajsql; sb_init(&trajsql);
    sb_puts(&trajsql, "fractal_search_trajectory(");
    sb_sql_ident(&trajsql, vehicle_table);
    sb_puts(&trajsql, ",");
    sb_sql_ident(&trajsql, emb_col);
    sb_puts(&trajsql, ",?1,?2,1)");
    if (sb_failed(&trajsql) || !bv_json || !cv_json) {
        sb_free(&trajsql); free(bv_json); free(cv_json);
        sqlite3_result_error_nomem(ctx);
        return;
    }
    TwoText tbind = { bv_json, cv_json };
    int64_t nearest_doc = -1; double nearest_dist = 0.0;
    int rc = da_nearest1(st, trajsql.buf, bind_two_text, &tbind, &nearest_doc, &nearest_dist,
                         err, sizeof err);
    sb_free(&trajsql); free(bv_json); free(cv_json);
    if (rc != 0) { da_result_err(ctx, err); return; }
    if (nearest_doc < 0) {
        char msg[256];
        snprintf(msg, sizeof msg,
                 "fractal_agent_detour_classify: no vehicle rows in %s", vehicle_table);
        sqlite3_result_error(ctx, msg, -1);
        return;
    }

    int gdim = 0;
    double *gps = da_decode_vec(argv[4], &gdim);
    if (!gps) { sqlite3_result_error(ctx, "fractalsql: gps_trace must be a CSV/JSON vector", -1); return; }
    char *gps_json = da_vec_json(gps, gdim);
    free(gps);
    if (!gps_json) { sqlite3_result_error_nomem(ctx); return; }
    char bcsql[128];
    snprintf(bcsql, sizeof bcsql, "SELECT fractal_dimension_boxcount(?1,%d)", boxcount_dim);
    char *bc_text = da_scalar_text(st, bcsql, bind_one_text, &(OneText){ gps_json }, err, sizeof err);
    free(gps_json);
    if (!bc_text) { da_result_err(ctx, err); return; }
    double bc = atof(bc_text);
    free(bc_text);

    char *resolved_id = da_resolve_id(st, vehicle_table, id_col, nearest_doc, err, sizeof err);
    if (!resolved_id && err[0]) { da_result_err(ctx, err); return; }

    StrBuf prompt; sb_init(&prompt);
    sb_printf(&prompt,
             "Detour classify: vehicle %s deviates from its baseline by cosine "
             "distance %.10f (nearest fleet peer); its GPS trace has "
             "box-counting dimension %.10f. Classify the detour in one sentence.",
             resolved_id ? resolved_id : "?", nearest_dist, bc);
    StrBuf cjson; sb_init(&cjson);
    sb_printf(&cjson, "{\"trajectory_distance\":%.10f,\"trace_complexity\":%.10f}",
             nearest_dist, bc);
    if (sb_failed(&prompt) || sb_failed(&cjson)) {
        sb_free(&prompt); sb_free(&cjson); free(resolved_id);
        sqlite3_result_error_nomem(ctx);
        return;
    }
    char *rationale = da_reason(st, "fractal_agent_detour_classify", prompt.buf, cjson.buf,
                                err, sizeof err);
    sb_free(&prompt); sb_free(&cjson);
    if (!rationale) { free(resolved_id); da_result_err(ctx, err); return; }

    StrBuf audit; sb_init(&audit);
    sb_puts(&audit, "{\"nearest_fleet_id\":");
    if (resolved_id) sb_json_id_value(&audit, resolved_id); else sb_puts(&audit, "null");
    sb_printf(&audit, ",\"trajectory_distance\":%.10f,\"trace_complexity\":%.10f,"
             "\"rationale\":", nearest_dist, bc);
    sb_json_string(&audit, rationale);
    sb_puts(&audit, "}");
    if (!sb_failed(&audit))
        da_audit_log_best_effort(st, "agent_detour_classify", audit.buf);
    sb_free(&audit);

    StrBuf out; sb_init(&out);
    sb_puts(&out, "{\"nearest_fleet_id\":");
    if (resolved_id) sb_json_id_value(&out, resolved_id); else sb_puts(&out, "null");
    sb_printf(&out, ",\"trajectory_distance\":%.10f,\"trace_complexity\":%.10f,"
             "\"rationale\":", nearest_dist, bc);
    sb_json_string(&out, rationale);
    sb_puts(&out, "}");
    free(resolved_id); free(rationale);
    if (sb_failed(&out)) { sb_free(&out); sqlite3_result_error_nomem(ctx); return; }
    sqlite3_result_text(ctx, out.buf, (int)out.len, SQLITE_TRANSIENT);
    sb_free(&out);
}

/* ======================================================================
 * Engine M: fractal_agent_track_anomaly(track_table, emb_col,
 *   baseline_vec, current_vec, heading_series, k DEFAULT 5, id_col
 *   DEFAULT 'id')
 *   -> TEXT JSON {nearest_fleet_id, trajectory_distance, dfa_exponent,
 *                 rationale}
 * ====================================================================== */
static void agent_track_anomaly_fn(sqlite3_context *ctx, int argc,
                                   sqlite3_value **argv) {
    FsqlState *st = (FsqlState *)sqlite3_user_data(ctx);
    char err[512];
    if (argc < 5 || argc > 7) {
        sqlite3_result_error(ctx,
            "fractal_agent_track_anomaly(track_table, emb_col, baseline_vec, "
            "current_vec, heading_series [, k, id_col]) expects 5 to 7 args", -1);
        return;
    }
    for (int i = 0; i < 5; i++) {
        if (sqlite3_value_type(argv[i]) == SQLITE_NULL) {
            sqlite3_result_error(ctx,
                "fractal_agent_track_anomaly: the first five arguments are required", -1);
            return;
        }
    }
    const char *track_table = (const char *)sqlite3_value_text(argv[0]);
    const char *emb_col     = (const char *)sqlite3_value_text(argv[1]);
    const char *id_col = (argc >= 7 && sqlite3_value_type(argv[6]) != SQLITE_NULL)
                        ? (const char *)sqlite3_value_text(argv[6]) : "id";
    if (!track_table || !emb_col || !id_col) { sqlite3_result_error_nomem(ctx); return; }
    if (!da_ident_ok(track_table) || !da_ident_ok(emb_col) || !da_ident_ok(id_col)) {
        sqlite3_result_error(ctx,
            "fractalsql: table/column identifiers must be plain identifiers "
            "([A-Za-z_][A-Za-z0-9_]*)", -1);
        return;
    }
    int rows = da_table_has_rows(st, track_table, err, sizeof err);
    if (rows < 0) { da_result_err(ctx, err); return; }
    if (rows == 0) {
        char msg[256];
        snprintf(msg, sizeof msg,
                 "fractal_agent_track_anomaly: no track rows in %s", track_table);
        sqlite3_result_error(ctx, msg, -1);
        return;
    }

    int bdim = 0, cdim = 0;
    double *bv = da_decode_vec(argv[2], &bdim);
    double *cv = da_decode_vec(argv[3], &cdim);
    if (!bv || !cv) {
        free(bv); free(cv);
        sqlite3_result_error(ctx, "fractalsql: baseline_vec/current_vec must be CSV/JSON vectors", -1);
        return;
    }
    char *bv_json = da_vec_json(bv, bdim);
    char *cv_json = da_vec_json(cv, cdim);
    free(bv); free(cv);

    StrBuf trajsql; sb_init(&trajsql);
    sb_puts(&trajsql, "fractal_search_trajectory(");
    sb_sql_ident(&trajsql, track_table);
    sb_puts(&trajsql, ",");
    sb_sql_ident(&trajsql, emb_col);
    sb_puts(&trajsql, ",?1,?2,1)");
    if (sb_failed(&trajsql) || !bv_json || !cv_json) {
        sb_free(&trajsql); free(bv_json); free(cv_json);
        sqlite3_result_error_nomem(ctx);
        return;
    }
    TwoText tbind = { bv_json, cv_json };
    int64_t nearest_doc = -1; double nearest_dist = 0.0;
    int rc = da_nearest1(st, trajsql.buf, bind_two_text, &tbind, &nearest_doc, &nearest_dist,
                         err, sizeof err);
    sb_free(&trajsql); free(bv_json); free(cv_json);
    if (rc != 0) { da_result_err(ctx, err); return; }
    if (nearest_doc < 0) {
        char msg[256];
        snprintf(msg, sizeof msg,
                 "fractal_agent_track_anomaly: no track rows in %s", track_table);
        sqlite3_result_error(ctx, msg, -1);
        return;
    }

    int hdim = 0;
    double *heading = da_decode_vec(argv[4], &hdim);
    if (!heading) { sqlite3_result_error(ctx, "fractalsql: heading_series must be a CSV/JSON vector", -1); return; }
    char *heading_json = da_vec_json(heading, hdim);
    free(heading);
    if (!heading_json) { sqlite3_result_error_nomem(ctx); return; }
    char *dfa_text = da_scalar_text(st, "SELECT fractal_dimension_dfa(?1)",
                                    bind_one_text, &(OneText){ heading_json }, err, sizeof err);
    free(heading_json);
    if (!dfa_text) { da_result_err(ctx, err); return; }
    double dfa = atof(dfa_text);
    free(dfa_text);

    char *resolved_id = da_resolve_id(st, track_table, id_col, nearest_doc, err, sizeof err);
    if (!resolved_id && err[0]) { da_result_err(ctx, err); return; }

    StrBuf prompt; sb_init(&prompt);
    sb_printf(&prompt,
             "Track anomaly: vessel/host %s deviates from baseline by cosine "
             "distance %.10f; its heading-change series has DFA exponent %.10f "
             "(dfa=-1 means insufficient window). Triage the track in one sentence.",
             resolved_id ? resolved_id : "?", nearest_dist, dfa);
    StrBuf cjson; sb_init(&cjson);
    sb_printf(&cjson, "{\"trajectory_distance\":%.10f,\"dfa_exponent\":%.10f}",
             nearest_dist, dfa);
    if (sb_failed(&prompt) || sb_failed(&cjson)) {
        sb_free(&prompt); sb_free(&cjson); free(resolved_id);
        sqlite3_result_error_nomem(ctx);
        return;
    }
    char *rationale = da_reason(st, "fractal_agent_track_anomaly", prompt.buf, cjson.buf,
                                err, sizeof err);
    sb_free(&prompt); sb_free(&cjson);
    if (!rationale) { free(resolved_id); da_result_err(ctx, err); return; }

    StrBuf audit; sb_init(&audit);
    sb_puts(&audit, "{\"nearest_fleet_id\":");
    if (resolved_id) sb_json_id_value(&audit, resolved_id); else sb_puts(&audit, "null");
    sb_printf(&audit, ",\"trajectory_distance\":%.10f,\"dfa_exponent\":%.10f,"
             "\"rationale\":", nearest_dist, dfa);
    sb_json_string(&audit, rationale);
    sb_puts(&audit, "}");
    if (!sb_failed(&audit))
        da_audit_log_best_effort(st, "agent_track_anomaly", audit.buf);
    sb_free(&audit);

    StrBuf out; sb_init(&out);
    sb_puts(&out, "{\"nearest_fleet_id\":");
    if (resolved_id) sb_json_id_value(&out, resolved_id); else sb_puts(&out, "null");
    sb_printf(&out, ",\"trajectory_distance\":%.10f,\"dfa_exponent\":%.10f,"
             "\"rationale\":", nearest_dist, dfa);
    sb_json_string(&out, rationale);
    sb_puts(&out, "}");
    free(resolved_id); free(rationale);
    if (sb_failed(&out)) { sb_free(&out); sqlite3_result_error_nomem(ctx); return; }
    sqlite3_result_text(ctx, out.buf, (int)out.len, SQLITE_TRANSIENT);
    sb_free(&out);
}

/* ======================================================================
 * Engine N: fractal_agent_network_coverage_alert(point_cloud,
 *   drift_series, boxcount_dim DEFAULT 2, drift_win DEFAULT 48,
 *   drift_threshold DEFAULT 0.5, context DEFAULT '{}')
 *   -> TEXT JSON {morph_dimension, lacunarity, drift_detected,
 *                 rationale}
 * ====================================================================== */
static void agent_network_coverage_alert_fn(sqlite3_context *ctx, int argc,
                                            sqlite3_value **argv) {
    FsqlState *st = (FsqlState *)sqlite3_user_data(ctx);
    char err[512];
    if (argc < 2 || argc > 6) {
        sqlite3_result_error(ctx,
            "fractal_agent_network_coverage_alert(point_cloud, drift_series "
            "[, boxcount_dim, drift_win, drift_threshold, context]) expects "
            "2 to 6 args", -1);
        return;
    }
    if (sqlite3_value_type(argv[0]) == SQLITE_NULL ||
        sqlite3_value_type(argv[1]) == SQLITE_NULL) {
        sqlite3_result_error(ctx,
            "fractal_agent_network_coverage_alert: point_cloud and drift_series "
            "are required", -1);
        return;
    }
    int boxcount_dim = (argc >= 3 && sqlite3_value_type(argv[2]) != SQLITE_NULL)
                      ? sqlite3_value_int(argv[2]) : 2;
    int drift_win = (argc >= 4 && sqlite3_value_type(argv[3]) != SQLITE_NULL)
                   ? sqlite3_value_int(argv[3]) : 48;
    double drift_threshold = (argc >= 5 && sqlite3_value_type(argv[4]) != SQLITE_NULL)
                            ? sqlite3_value_double(argv[4]) : 0.5;
    const char *context = (argc >= 6 && sqlite3_value_type(argv[5]) != SQLITE_NULL)
                         ? (const char *)sqlite3_value_text(argv[5]) : "{}";
    if (!context) context = "{}";

    int pdim = 0;
    double *points = da_decode_vec(argv[0], &pdim);
    if (!points) { sqlite3_result_error(ctx, "fractalsql: point_cloud must be a CSV/JSON vector", -1); return; }
    char *points_json = da_vec_json(points, pdim);
    free(points);
    if (!points_json) { sqlite3_result_error_nomem(ctx); return; }
    char morphsql[128];
    snprintf(morphsql, sizeof morphsql,
             "SELECT fractal_morphological_complexity(?1,%d)", boxcount_dim);
    char *morph = da_scalar_text(st, morphsql, bind_one_text, &(OneText){ points_json },
                                 err, sizeof err);
    free(points_json);
    if (!morph) { da_result_err(ctx, err); return; }
    double md = da_json_num(st, morph, "$.dimension");
    double lac = da_json_num(st, morph, "$.lacunarity");
    free(morph);

    int ddim = 0;
    double *drift_series = da_decode_vec(argv[1], &ddim);
    if (!drift_series) { sqlite3_result_error(ctx, "fractalsql: drift_series must be a CSV/JSON vector", -1); return; }
    char *drift_json_in = da_vec_json(drift_series, ddim);
    free(drift_series);
    if (!drift_json_in) { sqlite3_result_error_nomem(ctx); return; }
    char driftsql[128];
    snprintf(driftsql, sizeof driftsql,
             "SELECT fractal_dimension_drift(?1,%d)", drift_win);
    char *drift = da_scalar_text(st, driftsql, bind_one_text, &(OneText){ drift_json_in },
                                 err, sizeof err);
    free(drift_json_in);
    if (!drift) { da_result_err(ctx, err); return; }
    double dv = da_json_num(st, drift, "$.drift");
    free(drift);
    int dd = fabs(dv) > drift_threshold;

    StrBuf prompt; sb_init(&prompt);
    sb_printf(&prompt,
             "Network coverage alert: the sensor grid has morphological "
             "dimension %.10f and lacunarity %.10f; the telemetry drift is "
             "%.10f (drift_detected=%s, threshold %.10f). Issue the coverage "
             "alert in one sentence.",
             md, lac, dv, dd ? "true" : "false", drift_threshold);
    if (sb_failed(&prompt)) { sb_free(&prompt); sqlite3_result_error_nomem(ctx); return; }
    char *rationale = da_reason(st, "fractal_agent_network_coverage_alert", prompt.buf,
                                context, err, sizeof err);
    sb_free(&prompt);
    if (!rationale) { da_result_err(ctx, err); return; }

    StrBuf audit; sb_init(&audit);
    sb_printf(&audit, "{\"morph_dimension\":%.10f,\"lacunarity\":%.10f,"
                      "\"drift_detected\":%s,\"rationale\":",
             md, lac, dd ? "true" : "false");
    sb_json_string(&audit, rationale);
    sb_puts(&audit, "}");
    if (!sb_failed(&audit))
        da_audit_log_best_effort(st, "agent_network_coverage_alert", audit.buf);
    sb_free(&audit);

    StrBuf out; sb_init(&out);
    sb_printf(&out, "{\"morph_dimension\":%.10f,\"lacunarity\":%.10f,"
                    "\"drift_detected\":%s,\"rationale\":",
             md, lac, dd ? "true" : "false");
    sb_json_string(&out, rationale);
    sb_puts(&out, "}");
    free(rationale);
    if (sb_failed(&out)) { sb_free(&out); sqlite3_result_error_nomem(ctx); return; }
    sqlite3_result_text(ctx, out.buf, (int)out.len, SQLITE_TRANSIENT);
    sb_free(&out);
}

/* ======================================================================
 * Engine O: fractal_agent_regime_triage(series, win DEFAULT 64,
 *   drift_threshold DEFAULT 0.5, context DEFAULT '{}')
 *   -> TEXT JSON {dfa_exponent, drift_detected, recent_alpha,
 *                 baseline_alpha, rationale}
 * ====================================================================== */
static void agent_regime_triage_fn(sqlite3_context *ctx, int argc,
                                   sqlite3_value **argv) {
    FsqlState *st = (FsqlState *)sqlite3_user_data(ctx);
    char err[512];
    if (argc < 1 || argc > 4) {
        sqlite3_result_error(ctx,
            "fractal_agent_regime_triage(series [, win, drift_threshold, "
            "context]) expects 1 to 4 args", -1);
        return;
    }
    if (sqlite3_value_type(argv[0]) == SQLITE_NULL) {
        sqlite3_result_error(ctx, "fractal_agent_regime_triage: series is required", -1);
        return;
    }
    int win = (argc >= 2 && sqlite3_value_type(argv[1]) != SQLITE_NULL)
            ? sqlite3_value_int(argv[1]) : 64;
    double drift_threshold = (argc >= 3 && sqlite3_value_type(argv[2]) != SQLITE_NULL)
                            ? sqlite3_value_double(argv[2]) : 0.5;
    const char *context = (argc >= 4 && sqlite3_value_type(argv[3]) != SQLITE_NULL)
                         ? (const char *)sqlite3_value_text(argv[3]) : "{}";
    if (!context) context = "{}";

    int sdim = 0;
    double *series = da_decode_vec(argv[0], &sdim);
    if (!series) { sqlite3_result_error(ctx, "fractalsql: series must be a CSV/JSON vector", -1); return; }
    char *series_json = da_vec_json(series, sdim);
    free(series);
    if (!series_json) { sqlite3_result_error_nomem(ctx); return; }

    char *dfa_text = da_scalar_text(st, "SELECT fractal_dimension_dfa(?1)",
                                    bind_one_text, &(OneText){ series_json }, err, sizeof err);
    if (!dfa_text) { free(series_json); da_result_err(ctx, err); return; }
    double dfa = atof(dfa_text);
    free(dfa_text);

    char driftsql[128];
    snprintf(driftsql, sizeof driftsql, "SELECT fractal_dimension_drift(?1,%d)", win);
    char *drift = da_scalar_text(st, driftsql, bind_one_text, &(OneText){ series_json },
                                 err, sizeof err);
    free(series_json);
    if (!drift) { da_result_err(ctx, err); return; }
    double dv = da_json_num(st, drift, "$.drift");
    double ra = da_json_num(st, drift, "$.recent_alpha");
    double ba = da_json_num(st, drift, "$.baseline_alpha");
    free(drift);
    int dd = fabs(dv) > drift_threshold;

    StrBuf prompt; sb_init(&prompt);
    sb_printf(&prompt,
             "Regime triage: the series has DFA exponent %.10f and drift %.10f "
             "(drift_detected=%s, recent_alpha=%.10f, baseline_alpha=%.10f). "
             "Triage the regime change in one sentence.",
             dfa, dv, dd ? "true" : "false", ra, ba);
    if (sb_failed(&prompt)) { sb_free(&prompt); sqlite3_result_error_nomem(ctx); return; }
    char *rationale = da_reason(st, "fractal_agent_regime_triage", prompt.buf, context,
                                err, sizeof err);
    sb_free(&prompt);
    if (!rationale) { da_result_err(ctx, err); return; }

    StrBuf audit; sb_init(&audit);
    sb_printf(&audit, "{\"dfa_exponent\":%.10f,\"drift_detected\":%s,"
                      "\"drift\":%.10f,\"rationale\":",
             dfa, dd ? "true" : "false", dv);
    sb_json_string(&audit, rationale);
    sb_puts(&audit, "}");
    if (!sb_failed(&audit))
        da_audit_log_best_effort(st, "agent_regime_triage", audit.buf);
    sb_free(&audit);

    StrBuf out; sb_init(&out);
    sb_printf(&out, "{\"dfa_exponent\":%.10f,\"drift_detected\":%s,"
                    "\"recent_alpha\":%.10f,\"baseline_alpha\":%.10f,\"rationale\":",
             dfa, dd ? "true" : "false", ra, ba);
    sb_json_string(&out, rationale);
    sb_puts(&out, "}");
    free(rationale);
    if (sb_failed(&out)) { sb_free(&out); sqlite3_result_error_nomem(ctx); return; }
    sqlite3_result_text(ctx, out.buf, (int)out.len, SQLITE_TRANSIENT);
    sb_free(&out);
}

/* ======================================================================
 * Engine P: fractal_agent_diverse_portfolios(mu, cov, cardinality,
 *   n_restarts DEFAULT 8, overlap_threshold DEFAULT 0.15, quality_frac
 *   DEFAULT 0.90, seed DEFAULT NULL, context DEFAULT '{}',
 *   objective_mode DEFAULT 'sharpe')
 *   -> TEXT JSON array of {candidate_id, sharpe, weights, rationale}
 *   Enterprise tier: fractal_optimize_portfolio_multimodal(_pareto)
 *   error with "enterprise tier not loaded" until fractalsql.
 *   enterprise_lib is set.
 * ====================================================================== */
static void agent_diverse_portfolios_fn(sqlite3_context *ctx, int argc,
                                        sqlite3_value **argv) {
    FsqlState *st = (FsqlState *)sqlite3_user_data(ctx);
    char err[512];
    if (argc < 3 || argc > 9) {
        sqlite3_result_error(ctx,
            "fractal_agent_diverse_portfolios(mu, cov, cardinality "
            "[, n_restarts, overlap_threshold, quality_frac, seed, context, "
            "objective_mode]) expects 3 to 9 args", -1);
        return;
    }
    if (sqlite3_value_type(argv[0]) == SQLITE_NULL ||
        sqlite3_value_type(argv[1]) == SQLITE_NULL ||
        sqlite3_value_type(argv[2]) == SQLITE_NULL) {
        sqlite3_result_error(ctx,
            "fractal_agent_diverse_portfolios: mu, cov, cardinality are required", -1);
        return;
    }
    int cardinality = sqlite3_value_int(argv[2]);
    int n_restarts = (argc >= 4 && sqlite3_value_type(argv[3]) != SQLITE_NULL)
                    ? sqlite3_value_int(argv[3]) : 8;
    double overlap_threshold = (argc >= 5 && sqlite3_value_type(argv[4]) != SQLITE_NULL)
                              ? sqlite3_value_double(argv[4]) : 0.15;
    double quality_frac = (argc >= 6 && sqlite3_value_type(argv[5]) != SQLITE_NULL)
                         ? sqlite3_value_double(argv[5]) : 0.90;
    const char *context = (argc >= 8 && sqlite3_value_type(argv[7]) != SQLITE_NULL)
                         ? (const char *)sqlite3_value_text(argv[7]) : "{}";
    const char *objective_mode = (argc >= 9 && sqlite3_value_type(argv[8]) != SQLITE_NULL)
                                ? (const char *)sqlite3_value_text(argv[8]) : "sharpe";
    if (!context) context = "{}";
    if (!objective_mode) objective_mode = "sharpe";
    int is_pareto = strcmp(objective_mode, "pareto") == 0;
    if (!is_pareto && strcmp(objective_mode, "sharpe") != 0) {
        char msg[256];
        snprintf(msg, sizeof msg,
                 "fractal_agent_diverse_portfolios: objective_mode must be "
                 "'sharpe' or 'pareto' (got %s)", objective_mode);
        sqlite3_result_error(ctx, msg, -1);
        return;
    }

    int mu_dim = 0, cov_dim = 0;
    double *mu = da_decode_vec(argv[0], &mu_dim);
    double *cov = da_decode_vec(argv[1], &cov_dim);
    if (!mu || !cov) {
        free(mu); free(cov);
        sqlite3_result_error(ctx, "fractalsql: mu/cov must be CSV/JSON vectors", -1);
        return;
    }
    char *mu_json = da_vec_json(mu, mu_dim);
    char *cov_json = da_vec_json(cov, cov_dim);
    free(mu); free(cov);
    if (!mu_json || !cov_json) {
        free(mu_json); free(cov_json);
        sqlite3_result_error_nomem(ctx);
        return;
    }

    char *opt = NULL;
    if (is_pareto) {
        char callsql[160];
        snprintf(callsql, sizeof callsql,
                 "SELECT fractal_optimize_portfolio_multimodal_pareto(?1,?2,%d,%d,%d)",
                 cardinality, n_restarts, n_restarts);
        TwoText bind = { mu_json, cov_json };
        opt = da_scalar_text(st, callsql, bind_two_text, &bind, err, sizeof err);
    } else {
        char callsql[224];
        snprintf(callsql, sizeof callsql,
                 "SELECT fractal_optimize_portfolio_multimodal(?1,?2,%d,%d,%.10f,%.10f)",
                 cardinality, n_restarts, overlap_threshold, quality_frac);
        TwoText bind = { mu_json, cov_json };
        opt = da_scalar_text(st, callsql, bind_two_text, &bind, err, sizeof err);
    }
    free(mu_json); free(cov_json);
    if (!opt) { da_result_err(ctx, err); return; }

    int n_found = (int)da_json_num(st, opt, "$.n_found");
    if (n_found <= 0) {
        free(opt);
        sqlite3_result_error(ctx,
            "fractal_agent_diverse_portfolios: no candidates found", -1);
        return;
    }

    /* One rationale covering all candidates' tradeoffs. */
    StrBuf prompt; sb_init(&prompt);
    if (is_pareto) {
        sb_printf(&prompt,
                 "Found %d Pareto-optimal (non-dominated return-vs-risk) "
                 "portfolios. Summarize in one paragraph the return/risk "
                 "tradeoffs a portfolio manager should weigh between these "
                 "options. Candidates: ", n_found);
    } else {
        sb_printf(&prompt,
                 "Found %d structurally distinct portfolios. Summarize in one "
                 "paragraph the strategic tradeoffs a portfolio manager should "
                 "weigh between these options. Candidates: ", n_found);
    }
    sb_puts(&prompt, opt);
    if (sb_failed(&prompt)) { sb_free(&prompt); free(opt); sqlite3_result_error_nomem(ctx); return; }
    char *rationale = da_reason(st, "fractal_agent_diverse_portfolios", prompt.buf, context,
                                err, sizeof err);
    sb_free(&prompt);
    if (!rationale) { free(opt); da_result_err(ctx, err); return; }

    StrBuf audit; sb_init(&audit);
    sb_puts(&audit, "{\"objective_mode\":");
    sb_json_string(&audit, objective_mode);
    sb_printf(&audit, ",\"n_found\":%d,\"cardinality\":%d,\"rationale\":",
             n_found, cardinality);
    sb_json_string(&audit, rationale);
    sb_puts(&audit, "}");
    if (!sb_failed(&audit))
        da_audit_log_best_effort(st, "agent_diverse_portfolios", audit.buf);
    sb_free(&audit);

    /* Build the per-candidate rows. weights carries {weights,return,risk}
     * in pareto mode (so per-row return/risk are machine-queryable
     * without a second call), or the bare weights array otherwise. */
    StrBuf sql; sb_init(&sql);
    if (is_pareto) {
        sb_puts(&sql,
            "SELECT '[' || group_concat(json_object('candidate_id', "
            "key,'sharpe',json_extract(value,'$.sharpe'),'weights', "
            "json_object('weights',json_extract(value,'$.weights'),"
            "'return',json_extract(value,'$.return'),'risk',"
            "json_extract(value,'$.risk'))) ) || ']' "
            "FROM json_each(json_extract(?1,'$.candidates'))");
    } else {
        sb_puts(&sql,
            "SELECT '[' || group_concat(json_object('candidate_id', "
            "key,'sharpe',json_extract(value,'$.sharpe'),'weights', "
            "json_extract(value,'$.weights'))) || ']' "
            "FROM json_each(json_extract(?1,'$.candidates'))");
    }
    if (sb_failed(&sql)) { sb_free(&sql); free(opt); free(rationale); sqlite3_result_error_nomem(ctx); return; }
    char *rows_json = da_scalar_text(st, sql.buf, bind_one_text, &(OneText){ opt },
                                     err, sizeof err);
    sb_free(&sql);
    free(opt);
    if (!rows_json) { free(rationale); da_result_err(ctx, err); return; }

    /* Splice the shared rationale into every row (one reasoning call
     * covering all candidates, repeated per row). */
    StrBuf out; sb_init(&out);
    sb_puts(&out, "[");
    {
        sqlite3_stmt *stmt = NULL;
        if (sqlite3_prepare_v2(st->db,
                "SELECT key, json_extract(value,'$.candidate_id'), "
                "json_extract(value,'$.sharpe'), json_extract(value,'$.weights') "
                "FROM json_each(?1)", -1, &stmt, NULL) == SQLITE_OK) {
            sqlite3_bind_text(stmt, 1, rows_json, -1, SQLITE_TRANSIENT);
            int first = 1;
            while (sqlite3_step(stmt) == SQLITE_ROW) {
                if (!first) sb_puts(&out, ",");
                first = 0;
                int64_t cid = sqlite3_column_int64(stmt, 1);
                double csh = sqlite3_column_double(stmt, 2);
                const unsigned char *w = sqlite3_column_text(stmt, 3);
                sb_printf(&out, "{\"candidate_id\":%lld,\"sharpe\":%.10f,\"weights\":",
                         (long long)cid, csh);
                sb_puts(&out, w ? (const char *)w : "null");
                sb_puts(&out, ",\"rationale\":");
                sb_json_string(&out, rationale);
                sb_puts(&out, "}");
            }
        }
        sqlite3_finalize(stmt);
    }
    sb_puts(&out, "]");
    free(rows_json); free(rationale);
    if (sb_failed(&out)) { sb_free(&out); sqlite3_result_error_nomem(ctx); return; }
    sqlite3_result_text(ctx, out.buf, (int)out.len, SQLITE_TRANSIENT);
    sb_free(&out);
}

/* ------------------------------------------------------------------ */
/* Registration                                                        */
/* ------------------------------------------------------------------ */

int fsql_domain_agents_register(sqlite3 *db, FsqlState *st) {
    static const int flags = SQLITE_UTF8 | SQLITE_INNOCUOUS;

    struct {
        const char *name;
        int         narg;
        void (*fn)(sqlite3_context *, int, sqlite3_value **);
    } fns[] = {
        { "fractal_agent_anomaly_triage",                -1, agent_anomaly_triage_fn                },
        { "fractal_agent_allocate",                      -1, agent_allocate_fn                      },
        { "fractal_agent_route_task",                    -1, agent_route_task_fn                    },
        { "fractal_agent_outlier_intercept",               4, agent_outlier_intercept_fn             },
        { "fractal_agent_recall_hybrid",                 -1, agent_recall_hybrid_fn                 },
        { "fractal_agent_recommend_diverse",             -1, agent_recommend_diverse_fn             },
        { "fractal_agent_data_analyst",                  -1, agent_data_analyst_fn                  },
        { "fractal_agent_patient_deterioration_triage",  -1, agent_patient_deterioration_triage_fn  },
        { "fractal_agent_feedback_audit",                -1, agent_feedback_audit_fn                },
        { "fractal_agent_schedule_workload",              -1, agent_schedule_workload_fn             },
        { "fractal_agent_rebalance_sibling",              -1, agent_rebalance_sibling_fn             },
        { "fractal_agent_detour_classify",                -1, agent_detour_classify_fn               },
        { "fractal_agent_track_anomaly",                  -1, agent_track_anomaly_fn                 },
        { "fractal_agent_network_coverage_alert",         -1, agent_network_coverage_alert_fn        },
        { "fractal_agent_regime_triage",                  -1, agent_regime_triage_fn                 },
        { "fractal_agent_diverse_portfolios",             -1, agent_diverse_portfolios_fn            },
    };

    for (size_t i = 0; i < sizeof(fns) / sizeof(fns[0]); i++) {
        int rc = sqlite3_create_function_v2(
            db, fns[i].name, fns[i].narg, flags, st, fns[i].fn,
            NULL, NULL, NULL);
        if (rc != SQLITE_OK) return rc;
    }
    return SQLITE_OK;
}
