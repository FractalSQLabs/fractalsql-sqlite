/* src/fsql_agents.c: agent-tier composition surface.
 *
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * Agent-tier composition surface: fractal_reason, the search/sql/rag
 * agents, planning/trajectory helpers, table-backed top-k telemetry
 * search and its thin compositions (hybrid cohort, cross-modal), and
 * the session-level Diversify inspectors (explain/collapse).
 *
 * Registered here:
 *
 *   fractal_reason(query, context)                      -> TEXT
 *   fractal_search_debug(query [, iters, pop, diff])    -> TEXT (JSON)
 *   fractal_search_agent(query, table, col
 *                        [, pop, iterations])           -> TEXT (JSON)
 *   fractal_sql_agent(question [, tables, retries,
 *                        auto_execute])                 -> TEXT (JSON)
 *   fractal_rag_agent(query, table, col
 *                     [, meta_filter])                  -> TEXT (JSON)
 *   fractal_agent_plan_explore(state, table, col, N)    -> TEXT (JSON)
 *   fractal_agent_trajectory_predict(table, col, id, N) -> TEXT (JSON)
 *   fractal_agent_detect_loop(series)                   -> TEXT (JSON)
 *   fractal_search_telemetry(table, col, query, k)      -> TEXT (JSON)
 *   fractal_search_trajectory(table, col, baseline,
 *                             current, k)               -> TEXT (JSON)
 *   fractal_hybrid_clinical_search(table, col, query,
 *                                 doc_ids, k)           -> TEXT (JSON)
 *   fractal_cross_modal_search(table, col, morph, clin,
 *                              alpha, k)                 -> TEXT (JSON)
 *   fractal_explain_result()                            -> TEXT (JSON)
 *   fractal_detect_collapse()                           -> REAL
 *   fractal_store_morphology(doc_id, features)          -> TEXT ('ok')
 *   fractal_mine_topology_negatives(surrogate, k)       -> TEXT (JSON)
 *
 * Design notes (documented, intentional):
 *
 *   - SQLite scalar functions can't return composite types or SETOF
 *     tables, so every composite comes back as one TEXT JSON document,
 *     and every (doc_id, distance) / plan-branch result set as a JSON
 *     array in result order.
 *
 *   - fractal_feedback_report / fractal_isolate_background /
 *     fractal_diversify_* are NOT here: they mutate shadow-store state
 *     on the shared ctx and belong to fsql_sovereign.c, which owns
 *     that block. This TU only READS Diversify state, through the
 *     core ABI getters (fsql_diversify_current_dq,
 *     fsql_diversify_get_params, fsql_diversify_overhead_p99_us).
 *
 *   - fractal_search_trajectory collapses the float8[] and
 *     fractal_vector (fractal_search_trajectory_fv) forms into one
 *     5-arg SQLite registration: fsql_vec_decode accepts both the
 *     CSV/JSON-text and canonical-BLOB vector forms, and the input
 *     storage class picks the arithmetic path (BLOB pair -> float32
 *     fsql_vector_sub, widened once at the boundary; otherwise double
 *     math).
 *
 *   - Agents embed the query through the embed tier:
 *     agents_embed_query() below passes FSQL_REASONING_TIER_EMBED to
 *     fsql_reasoning_generate(), and fsql_reasoning.c applies the
 *     embed env block (embed endpoint/model, MODE=embedding, think
 *     vars unset) before the plugin's init. No per-call context keys:
 *     the plugin embeds the context JSON into the prompt as data, so
 *     it must never carry configuration.
 *
 *   - fractal_sql_agent runs its own GENERATE prompt (fsql_t2s.c
 *     exposes no internal helper and this TU must not reach into its
 *     statics) using the same class of validation: parse via
 *     sqlite3_prepare_v2, a single-statement check on the pzTail, and
 *     a read-only statement check against the configured
 *     t2s_allowed_statements mode (a data-modifying CTE would already
 *     be a syntax error at parse time, since a CTE body must be a
 *     SELECT). Generated SQL is executed only when auto_execute is on,
 *     it validated, and it is read-only.
 *
 *   - Table/column identifiers coming from SQL arguments are validated
 *     against [A-Za-z_][A-Za-z0-9_]* before being quoted into dynamic
 *     SQL, keeping dynamic SQL to plain identifiers only. Every VALUE
 *     goes in as a bound parameter, never interpolated.
 *
 *   - DoS caps: corpus scans are bounded by FSQL_AGENTS_MAX_ROWS /
 *     FSQL_AGENTS_MAX_BYTES (2M rows / 2 GiB), SFS hyperparameters by
 *     fixed ranges, embedding dims by FSQL_AGENTS_MAX_EMBED_DIM (the
 *     shared arena bound, above any current embedding model and
 *     consistent with the entry TU), and plugin responses by the
 *     shared reasoning guard inside fsql_reasoning_generate().
 *
 * Threading/serialization: SQLite serializes calls on a connection;
 * these functions run inner read-only statements on st->db and keep no
 * module-global state, so no extra locking. Nothing here is
 * DETERMINISTIC (LLM calls, stochastic SFS, per-session Diversify
 * state), so everything registers SQLITE_UTF8 | SQLITE_INNOCUOUS.
 */

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
#include "fractalsql_parse.h"

/* ------------------------------------------------------------------ */
/* Limits (DoS guards)                                                  */
/* ------------------------------------------------------------------ */

/* The SFS hyperparameter ceilings live in fsql_sqlite_internal.h --
 * the Scout explore path in fractalsql_sqlite.c clamps against the
 * same numbers. */

/* Bounds the corpus a table scan may materialize (row count AND
 * actual bytes). */
#define FSQL_AGENTS_MAX_ROWS         ((uint64_t) 2000000)
#define FSQL_AGENTS_MAX_BYTES        ((uint64_t) 2ULL * 1024 * 1024 * 1024)

/* Cap on rows replayed into fractal_sql_agent's result_json when
 * auto_execute is on. */
#define FSQL_AGENTS_MAX_RESULT_ROWS  1024

/* Cap on distinct rows fetched into a retrieval context (one bound
 * rowid per Scout hit; pop_size bounds it in practice, 64 keeps the
 * LLM context prompt-sized). */
#define FSQL_AGENTS_MAX_CONTEXT_ROWS 64

/* Capped here to the shared arena bound, already above every current
 * embedding model and consistent with the entry TU's vector buffers. */
#define FSQL_AGENTS_MAX_EMBED_DIM    FSQL_ARENA_MAX_DIM

/* ------------------------------------------------------------------ */
/* Error + string-buffer helpers                                       */
/* ------------------------------------------------------------------ */

static void agents_set_err(char *err, size_t err_cap, const char *fmt, ...) {
    if (!err || err_cap == 0) return;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(err, err_cap, fmt, ap);
    va_end(ap);
}

static void agents_result_err(sqlite3_context *ctx, const char *err) {
    sqlite3_result_error(ctx, (err && *err) ? err
                            : "fractalsql: agent call failed", -1);
}

static const char *agents_core_detail(const FsqlState *st) {
    const char *detail = fsql_last_error(st->ctx);
    return (detail && *detail) ? detail : "(no detail)";
}

/* Growable append buffer — the allocation pattern this TU needs for
 * JSON assembly. All appends are bounds-checked; an OOM latches
 * b->oom and the caller checks it once at the end. */
typedef struct StrBuf {
    char  *buf;
    size_t len;
    size_t cap;
    int    oom;
} StrBuf;

static void sb_init(StrBuf *b) {
    b->buf = NULL; b->len = 0; b->cap = 0; b->oom = 0;
}

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
    b->buf = nb;
    b->cap = nc;
    return 0;
}

static void sb_putn(StrBuf *b, const char *s, size_t n) {
    if (sb_reserve(b, n) != 0) return;
    memcpy(b->buf + b->len, s, n);
    b->len += n;
    b->buf[b->len] = '\0';
}

static void sb_puts(StrBuf *b, const char *s) {
    sb_putn(b, s, strlen(s));
}

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

/* Append `s` as a quoted, escaped JSON string literal. */
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

/* Append a JSON array of doubles: [1.5,-2,...] ("%.17g" — round-trip
 * exact). */
static void sb_json_doubles(StrBuf *b, const double *v, int n) {
    sb_puts(b, "[");
    for (int i = 0; i < n; i++) {
        if (i) sb_puts(b, ",");
        if (isnan(v[i])) sb_puts(b, "null");   /* JSON has no NaN */
        else               sb_printf(b, "%.17g", v[i]);
    }
    sb_puts(b, "]");
}

/* ------------------------------------------------------------------ */
/* Identifier validation (see header comment, injection bullet)        */
/* ------------------------------------------------------------------ */

static int agents_ident_ok(const char *s) {
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

/* Append a VALIDATED identifier as a double-quoted SQL identifier.
 * Defense in depth: validation already guarantees a plain identifier
 * shape, so the quoting is belt-and-suspenders. */
static void sb_sql_ident(StrBuf *sql, const char *ident) {
    sb_puts(sql, "\"");
    sb_puts(sql, ident);
    sb_puts(sql, "\"");
}

/* ------------------------------------------------------------------ */
/* Corpus scan                                                         */
/* ------------------------------------------------------------------ */

/* A table column scanned into a flat row-major double corpus. Scanned
 * with ORDER BY rowid so doc_id (the 0-indexed scan position) is
 * deterministic — the same doc_id convention fractal_feedback_report's
 * result_handle shares. Rows may keep their rowid so search-result
 * positions map back to physical rows for content retrieval. */
typedef struct AgentCorpus {
    double  *data;      /* row-major, n_rows * dim */
    int64_t *rowids;    /* NULL unless captured    */
    size_t   n_rows;
    int      dim;
} AgentCorpus;

static void agents_corpus_free(AgentCorpus *c) {
    free(c->data);
    free(c->rowids);
    memset(c, 0, sizeof(*c));
}

static int agents_corpus_append(AgentCorpus *c, const double *row,
                                int64_t rowid, int have_rowid) {
    if (c->n_rows + 1 > (size_t)FSQL_AGENTS_MAX_ROWS)
        return -1;
    size_t need = (c->n_rows + 1) * (size_t)c->dim;
    if (need > SIZE_MAX / sizeof(double)) return -1;
    if ((uint64_t)need * sizeof(double) > FSQL_AGENTS_MAX_BYTES)
        return -1;

    size_t new_count = c->n_rows + 1;
    double *nd = (double *)realloc(c->data,
                                   new_count * (size_t)c->dim * sizeof(double));
    if (!nd) return -1;
    c->data = nd;
    if (have_rowid) {
        int64_t *nr = (int64_t *)realloc(c->rowids,
                                         new_count * sizeof(int64_t));
        if (!nr) return -1;
        c->rowids = nr;
        c->rowids[c->n_rows] = rowid;
    }
    memcpy(c->data + (size_t)c->n_rows * c->dim, row,
           (size_t)c->dim * sizeof(double));
    c->n_rows = new_count;
    return 0;
}

/* The core SFS arena and every fixed scratch buffer in this TU are
 * sized FSQL_ARENA_MAX_DIM, while fsql_vec_decode's own cap is the
 * wider FSQL_VEC_MAX_DIM (32767). Any vector destined for core-facing
 * search or a stack row buffer must be re-bounded to the arena cap
 * right after decode -- a 5000-dim CSV/JSON input decodes fine and
 * would otherwise walk off the end of those buffers. */
static int agents_dim_in_arena(int dim) {
    return dim >= 1 && dim <= FSQL_ARENA_MAX_DIM;
}

/* Scan table.col into *out. A row whose vector decodes to a different
 * dim than `dim` is a hard error, as is a NULL vector.
 * Returns 0 on success (possibly 0 rows), -1 with err set. */
static int agents_scan_corpus(FsqlState *st, const char *table,
                              const char *col, int dim, int want_rowids,
                              AgentCorpus *out, char *err, size_t err_cap) {
    memset(out, 0, sizeof(*out));
    out->dim = dim;
    if (!agents_dim_in_arena(dim)) {
        agents_set_err(err, err_cap,
                       "fractalsql: query dim %d out of range [1, %d]",
                       dim, FSQL_ARENA_MAX_DIM);
        return -1;
    }

    StrBuf sql;
    sb_init(&sql);
    sb_puts(&sql, "SELECT ");
    if (want_rowids) sb_puts(&sql, "rowid, ");
    sb_puts(&sql, "\"");
    sb_puts(&sql, col);          /* validated with agents_ident_ok */
    sb_puts(&sql, "\" FROM \"");
    sb_puts(&sql, table);        /* validated with agents_ident_ok */
    sb_puts(&sql, "\" ORDER BY rowid");

    if (sb_failed(&sql)) {
        sb_free(&sql);
        agents_set_err(err, err_cap, "fractalsql: out of memory");
        return -1;
    }

    sqlite3_stmt *stmt = NULL;
    int rc = sqlite3_prepare_v2(st->db, sql.buf, -1, &stmt, NULL);
    sb_free(&sql);
    if (rc != SQLITE_OK) {
        agents_set_err(err, err_cap, "fractalsql: scan of %s.%s failed: %s",
                       table, col, sqlite3_errmsg(st->db));
        return -1;
    }

    double row[FSQL_ARENA_MAX_DIM];
    for (;;) {
        rc = sqlite3_step(stmt);
        if (rc == SQLITE_DONE) break;
        if (rc != SQLITE_ROW) {
            agents_set_err(err, err_cap,
                           "fractalsql: scan of %s.%s failed: %s",
                           table, col, sqlite3_errmsg(st->db));
            goto fail;
        }

        size_t r = out->n_rows;
        int vec_i = want_rowids ? 1 : 0;
        if (sqlite3_column_type(stmt, vec_i) == SQLITE_NULL) {
            agents_set_err(err, err_cap,
                           "fractalsql: NULL vector at row %zu", r);
            goto fail;
        }

        float *fv = NULL;
        int    fdim = 0;
        if (fsql_vec_decode(sqlite3_column_value(stmt, vec_i),
                            &fv, &fdim) != 0) {
            agents_set_err(err, err_cap,
                           "fractalsql: malformed vector at %s.%s row %zu "
                           "(expect CSV/JSON text or canonical BLOB)",
                           table, col, r);
            goto fail;
        }
        if (fdim != dim) {
            free(fv);
            agents_set_err(err, err_cap,
                           "fractalsql: %s.%s row %zu has dim %d, "
                           "expected %d (match the query)",
                           table, col, r, fdim, dim);
            goto fail;
        }
        for (int i = 0; i < dim; i++) row[i] = (double)fv[i];
        free(fv);

        int64_t rowid = 0;
        if (want_rowids) rowid = sqlite3_column_int64(stmt, 0);
        if (agents_corpus_append(out, row, rowid, want_rowids) != 0) {
            agents_set_err(err, err_cap,
                           "fractalsql: %s.%s corpus exceeds the row/byte "
                           "cap (or out of memory) at row %zu",
                           table, col, r);
            goto fail;
        }
    }

    sqlite3_finalize(stmt);
    return 0;

fail:
    sqlite3_finalize(stmt);
    agents_corpus_free(out);
    return -1;
}

/* ------------------------------------------------------------------ */
/* Embed tier (see header comment, embed-tier bullet)                  */
/* ------------------------------------------------------------------ */

/* Embed `text` through the configured plugin in embedding mode;
 * returns a malloc'd double vector. 0 on success, -1 with err set. */
static int agents_embed_query(FsqlState *st, const char *text,
                              double **out_vec, int *out_dim,
                              char *err, size_t err_cap) {
    *out_vec = NULL;
    *out_dim = 0;

    if (!st->cfg.reasoning_plugin || !*st->cfg.reasoning_plugin) {
        agents_set_err(err, err_cap,
                       "fractalsql: reasoning plugin not configured "
                       "(set fractalsql_set('reasoning_plugin', "
                       "'/absolute/path.so'))");
        return -1;
    }
    if (!st->cfg.http_embed_url || !*st->cfg.http_embed_url) {
        /* No fallback to the chat http_url — a chat model is not a
         * substitute for a purpose-trained embedding model. */
        agents_set_err(err, err_cap,
                       "fractalsql: http_embed_url is not configured (set "
                       "fractalsql_set('http_embed_url', ...))");
        return -1;
    }

    /* Dispatch context is empty: embed configuration (endpoint, model,
     * embedding mode, token) reaches the plugin through the
     * FSQL_REASONING_TIER_EMBED tier's env block in fsql_reasoning.c —
     * the plugin embeds per-call context into the prompt as data, so
     * it must never carry config keys. */
    char *resp = NULL;
    int rc = fsql_reasoning_generate(st, FSQL_REASONING_TIER_EMBED,
                                     text, "{}", &resp, err, err_cap);
    if (rc != 0) return -1;

    double *vec = (double *)malloc(
        (size_t)FSQL_AGENTS_MAX_EMBED_DIM * sizeof(double));
    if (!vec) {
        free(resp);
        agents_set_err(err, err_cap, "fractalsql: out of memory");
        return -1;
    }
    int n = fsql_parse_embedding_array(resp, vec, FSQL_AGENTS_MAX_EMBED_DIM);
    free(resp);
    if (n <= 0) {
        free(vec);
        agents_set_err(err, err_cap,
                       "fractalsql: failed to parse embedding response");
        return -1;
    }

    *out_vec = vec;
    *out_dim = n;
    return 0;
}

/* ------------------------------------------------------------------ */
/* Reasoning / Scout / top-k composition helpers                       */
/* ------------------------------------------------------------------ */

static int agents_require_reasoning(FsqlState *st, const char *who,
                                    char *err, size_t err_cap) {
    if (!st || !st->ctx) {
        agents_set_err(err, err_cap, "fractalsql: extension not initialized");
        return -1;
    }
    if (!st->cfg.reasoning_plugin || !*st->cfg.reasoning_plugin) {
        agents_set_err(err, err_cap,
                       "%s: reasoning plugin not configured "
                       "(set fractalsql_set('reasoning_plugin', "
                       "'/absolute/path.so'))", who);
        return -1;
    }
    return 0;
}

/* Scout-mode search over a scanned corpus (return_population +
 * walk=0.0 + mmr_lambda=0.5). */
static int agents_scout_search(FsqlState *st, const AgentCorpus *c,
                               const double *query, int k,
                               int pop_size, int iterations,
                               const char **out_json, size_t *out_len,
                               char *err, size_t err_cap) {
    char params[256];
    snprintf(params, sizeof params,
             "{\"return_population\":true,\"max_generation\":%d,"
             "\"population_size\":%d,\"maximum_diffusion\":2,"
             "\"walk\":0.0,\"bound_clipping\":true,\"mmr_lambda\":0.5}",
             iterations, pop_size);

    int rc = fsql_search_ptr(st->ctx, c->data, c->n_rows, (size_t)c->dim,
                             query, (size_t)c->dim, k,
                             params, strlen(params), out_json, out_len);
    if (rc != 0 || !*out_json) {
        agents_set_err(err, err_cap, "fractalsql: scout SFS failed: %s",
                       agents_core_detail(st));
        return -1;
    }
    return 0;
}

/* Table-backed top-k telemetry search.
 * Emits a JSON array of {"doc_id":N,"distance":D} ascending by
 * distance. doc_id is the 0-indexed scan position (the result_handle
 * convention), translated through doc_id_map when a cohort filter
 * reordered the corpus. Returns 0 / -1 with err set. */
static int agents_topk_json(FsqlState *st, const AgentCorpus *c,
                            const double *query, int k,
                            const int64_t *doc_id_map,
                            StrBuf *out, char *err, size_t err_cap) {
    if (c->n_rows == 0) {
        agents_set_err(err, err_cap, "fractalsql: no corpus rows to search");
        return -1;
    }

    /* Plain top-k mode param shape (walk 0.5). */
    const char params[] =
        "{\"max_generation\":15,\"population_size\":50,"
        "\"maximum_diffusion\":2,\"walk\":0.5,\"bound_clipping\":true}";

    const char *result_json = NULL;
    size_t      result_len  = 0;
    int rc = fsql_search_ptr(st->ctx, c->data, c->n_rows, (size_t)c->dim,
                             query, (size_t)c->dim, k,
                             params, strlen(params),
                             &result_json, &result_len);
    if (rc != 0 || !result_json) {
        agents_set_err(err, err_cap, "fractalsql: telemetry search rc=%d: %s",
                       rc, agents_core_detail(st));
        return -1;
    }

    int  *idx  = (int *)malloc((size_t)k * sizeof(int));
    double *dist = (double *)malloc((size_t)k * sizeof(double));
    if (!idx || !dist) {
        free(idx); free(dist);
        agents_set_err(err, err_cap, "fractalsql: out of memory");
        return -1;
    }
    int n = fsql_extract_topk(result_json, k, idx, dist);
    if (n < 0) {
        free(idx); free(dist);
        agents_set_err(err, err_cap,
                       "fractalsql: malformed top_k in search result");
        return -1;
    }

    sb_puts(out, "[");
    for (int i = 0; i < n; i++) {
        if (i) sb_puts(out, ",");
        if (idx[i] < 0 || (size_t)idx[i] >= c->n_rows) {
            free(idx); free(dist);
            agents_set_err(err, err_cap,
                           "fractalsql: malformed top_k in search result");
            return -1;
        }
        int64_t doc_id = doc_id_map ? doc_id_map[idx[i]] : (int64_t)idx[i];
        sb_printf(out, "{\"doc_id\":%lld,\"distance\":%.17g}",
                  (long long)doc_id, dist[i]);
    }
    sb_puts(out, "]");
    free(idx);
    free(dist);
    if (sb_failed(out)) {
        agents_set_err(err, err_cap, "fractalsql: out of memory");
        return -1;
    }
    return 0;
}

/* SFS hyperparameter validation (validate_sfs_params port). */
static int agents_validate_sfs_params(int dim, int iterations, int pop_size,
                                      int diff_f, char *err, size_t err_cap) {
    if (dim <= 0 || dim > FSQL_ARENA_MAX_DIM) {
        agents_set_err(err, err_cap,
                       "fractalsql: query dim %d out of range [1, %d]",
                       dim, FSQL_ARENA_MAX_DIM);
        return -1;
    }
    if (iterations <= 0 || iterations > FSQL_AGENTS_MAX_ITERATIONS) {
        agents_set_err(err, err_cap,
                       "fractalsql: iterations %d out of range [1, %d]",
                       iterations, FSQL_AGENTS_MAX_ITERATIONS);
        return -1;
    }
    if (pop_size <= 0 || pop_size > FSQL_AGENTS_MAX_POPULATION) {
        agents_set_err(err, err_cap,
                       "fractalsql: population_size %d out of range [1, %d]",
                       pop_size, FSQL_AGENTS_MAX_POPULATION);
        return -1;
    }
    if (diff_f <= 0 || diff_f > FSQL_AGENTS_MAX_DIFFUSION) {
        agents_set_err(err, err_cap,
                       "fractalsql: diffusion_factor %d out of range [1, %d]",
                       diff_f, FSQL_AGENTS_MAX_DIFFUSION);
        return -1;
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/* Retrieval context                                                    */
/* ------------------------------------------------------------------ */

/* Serialize one column value as JSON. BLOBs have no lossless JSON
 * form worth feeding an LLM context — emitted as null. */
static void sb_json_column(StrBuf *b, sqlite3_stmt *stmt, int i) {
    switch (sqlite3_column_type(stmt, i)) {
    case SQLITE_INTEGER:
        sb_printf(b, "%lld", (long long)sqlite3_column_int64(stmt, i));
        break;
    case SQLITE_FLOAT:
        sb_printf(b, "%.17g", sqlite3_column_double(stmt, i));
        break;
    case SQLITE_TEXT: {
        const unsigned char *t = sqlite3_column_text(stmt, i);
        sb_json_string(b, t ? (const char *)t : "");
        break;
    }
    default: /* SQLITE_NULL, SQLITE_BLOB */
        sb_puts(b, "null");
        break;
    }
}

/* Fetch the matched rows' content (all columns except the embedding
 * column) as a compact JSON array — the LLM never sees raw embedding
 * vectors (they are large and useless to it). Returns a malloc'd JSON
 * string ("[]" when nothing matches), or NULL with err set. */
static char *agents_retrieval_context(FsqlState *st, const char *table,
                                      const char *vector_col,
                                      const AgentCorpus *c,
                                      const int *idx, int got,
                                      char *err, size_t err_cap) {
    if (got <= 0 || !c->rowids) {
        char *empty = (char *)malloc(3);
        if (empty) memcpy(empty, "[]", 3);
        return empty;
    }

    /* Distinct, in-range rowids for the matched positions, capped. */
    int64_t rids[FSQL_AGENTS_MAX_CONTEXT_ROWS];
    int n_rids = 0;
    for (int i = 0; i < got && n_rids < FSQL_AGENTS_MAX_CONTEXT_ROWS; i++) {
        int r = idx[i];
        if (r < 0 || (size_t)r >= c->n_rows) continue;
        int64_t rid = c->rowids[r];
        int dup = 0;
        for (int j = 0; j < n_rids; j++)
            if (rids[j] == rid) { dup = 1; break; }
        if (!dup) rids[n_rids++] = rid;
    }
    if (n_rids == 0) {
        char *empty = (char *)malloc(3);
        if (empty) memcpy(empty, "[]", 3);
        return empty;
    }

    StrBuf sql;
    sb_init(&sql);
    sb_puts(&sql, "SELECT * FROM ");
    sb_sql_ident(&sql, table);
    sb_puts(&sql, " WHERE rowid IN (?1");
    for (int i = 1; i < n_rids; i++)
        sb_printf(&sql, ",?%d", i + 1);
    sb_puts(&sql, ")");
    if (sb_failed(&sql)) {
        sb_free(&sql);
        agents_set_err(err, err_cap, "fractalsql: out of memory");
        return NULL;
    }

    sqlite3_stmt *stmt = NULL;
    int rc = sqlite3_prepare_v2(st->db, sql.buf, -1, &stmt, NULL);
    sb_free(&sql);
    if (rc != SQLITE_OK) {
        agents_set_err(err, err_cap,
                       "fractalsql: retrieval context query failed: %s",
                       sqlite3_errmsg(st->db));
        return NULL;
    }
    for (int i = 0; i < n_rids; i++)
        sqlite3_bind_int64(stmt, i + 1, rids[i]);

    StrBuf out;
    sb_init(&out);
    sb_puts(&out, "[");
    int n_cols = sqlite3_column_count(stmt);
    int rows = 0;
    int truncated = 0;      /* size-cap break: truncation, not failure */
    while ((rc = sqlite3_step(stmt)) == SQLITE_ROW) {
        if (rows) sb_puts(&out, ",");
        sb_puts(&out, "{");
        int emitted = 0;
        for (int i = 0; i < n_cols; i++) {
            const char *name = sqlite3_column_name(stmt, i);
            if (name && strcmp(name, vector_col) == 0) continue;
            if (emitted) sb_puts(&out, ",");
            sb_json_string(&out, name ? name : "?");
            sb_puts(&out, ":");
            sb_json_column(&out, stmt, i);
            emitted = 1;
        }
        sb_puts(&out, "}");
        rows++;
        /* Keep the LLM context prompt-sized even when top-k is large. */
        if (out.len > FSQL_MAX_INPUT_BYTES / 2) { truncated = 1; break; }
    }
    sb_puts(&out, "]");
    sqlite3_finalize(stmt);
    if (truncated) rc = SQLITE_DONE;

    if (rc != SQLITE_DONE || sb_failed(&out)) {
        if (rc != SQLITE_DONE)
            agents_set_err(err, err_cap,
                           "fractalsql: retrieval context query failed: %s",
                           sqlite3_errmsg(st->db));
        else
            agents_set_err(err, err_cap, "fractalsql: out of memory");
        sb_free(&out);
        return NULL;
    }
    return out.buf;
}

/* ------------------------------------------------------------------ */
/* fractal_reason(query, context)                                      */
/* ------------------------------------------------------------------ */

static void fractal_reason_fn(sqlite3_context *ctx, int argc,
                              sqlite3_value **argv) {
    FsqlState *st = (FsqlState *)sqlite3_user_data(ctx);
    char err[512];

    if (argc < 1 || argc > 2) {
        sqlite3_result_error(ctx,
            "fractal_reason(query, context) expects 1 or 2 args", -1);
        return;
    }
    if (!st || !st->ctx) {
        sqlite3_result_error(ctx, "fractalsql: extension not initialized", -1);
        return;
    }
    if (sqlite3_value_type(argv[0]) == SQLITE_NULL) {
        sqlite3_result_error(ctx, "fractal_reason: query must not be NULL", -1);
        return;
    }
    const char *query = (const char *)sqlite3_value_text(argv[0]);
    if (!query) { sqlite3_result_error_nomem(ctx); return; }

    const char *context = "{}";
    if (argc == 2 && sqlite3_value_type(argv[1]) != SQLITE_NULL)
        context = (const char *)sqlite3_value_text(argv[1]);
    if (!context) context = "{}";

    if (agents_require_reasoning(st, "fractal_reason", err, sizeof err) != 0) {
        agents_result_err(ctx, err);
        return;
    }

    char *resp = NULL;
    if (fsql_reasoning_generate(st, FSQL_REASONING_TIER_CHAT, query,
                                context, &resp,
                                err, sizeof err) != 0) {
        agents_result_err(ctx, err);
        return;
    }
    sqlite3_result_text(ctx, resp, -1, SQLITE_TRANSIENT);
    free(resp);
}

/* ------------------------------------------------------------------ */
/* fractal_search_debug(query [, iterations, population_size,
 *                       diffusion_factor])
 *
 * Per-generation SFS diagnostics document. Runs FRESH (never the
 * entry TU's memoized best_point): a different-params SFS must not
 * poison fractal_search's (query-hash -> best_point) memo, so this
 * call neither reads nor writes st->best_*. Uses a "no corpus"
 * convention: a 1-row dummy corpus holding the query itself routes
 * the core through real SFS convergence instead of the brute-force
 * retrieval path. */
/* ------------------------------------------------------------------ */

static void fractal_search_debug_fn(sqlite3_context *ctx, int argc,
                                    sqlite3_value **argv) {
    FsqlState *st = (FsqlState *)sqlite3_user_data(ctx);
    char err[512];

    if (argc < 1 || argc > 4) {
        sqlite3_result_error(ctx,
            "fractal_search_debug(query [, iterations, population_size, "
            "diffusion_factor]) expects 1 to 4 args", -1);
        return;
    }
    if (!st || !st->ctx) {
        sqlite3_result_error(ctx, "fractalsql: extension not initialized", -1);
        return;
    }
    if (sqlite3_value_type(argv[0]) == SQLITE_NULL) {
        sqlite3_result_null(ctx);   /* STRICT: NULL in, NULL out */
        return;
    }

    int iterations = 30, pop_size = 50, diff_f = 2;
    if (argc >= 2 && sqlite3_value_type(argv[1]) != SQLITE_NULL)
        iterations = sqlite3_value_int(argv[1]);
    if (argc >= 3 && sqlite3_value_type(argv[2]) != SQLITE_NULL)
        pop_size = sqlite3_value_int(argv[2]);
    if (argc >= 4 && sqlite3_value_type(argv[3]) != SQLITE_NULL)
        diff_f = sqlite3_value_int(argv[3]);

    float  *qf = NULL;
    int     dim = 0;
    if (fsql_vec_decode(argv[0], &qf, &dim) != 0) {
        sqlite3_result_error(ctx,
            "fractalsql: invalid query vector (expect CSV/JSON text or "
            "canonical float32 BLOB)", -1);
        return;
    }
    /* Bound BEFORE the stack copy below: query[] is arena-sized, while
     * decode accepts up to FSQL_VEC_MAX_DIM. */
    if (!agents_dim_in_arena(dim)) {
        char buf[128];
        snprintf(buf, sizeof buf,
                 "fractalsql: query dim %d out of range [1, %d]",
                 dim, FSQL_ARENA_MAX_DIM);
        free(qf);
        sqlite3_result_error(ctx, buf, -1);
        return;
    }
    double query[FSQL_ARENA_MAX_DIM];
    for (int i = 0; i < dim; i++) query[i] = (double)qf[i];
    free(qf);

    if (agents_validate_sfs_params(dim, iterations, pop_size, diff_f,
                                   err, sizeof err) != 0) {
        agents_result_err(ctx, err);
        return;
    }

    /* run_sfs port: fresh, non-memoized. */
    char params[160];
    snprintf(params, sizeof params,
             "{\"iterations\":%d,\"population_size\":%d,"
             "\"diffusion_factor\":%d,\"walk\":0.5,\"no_corpus\":true}",
             iterations, pop_size, diff_f);

    const char *result_json = NULL;
    size_t      result_len  = 0;
    int rc = fsql_search_ptr(st->ctx,
                             query, /*n_rows*/ 1, (size_t)dim,
                             query, (size_t)dim,
                             /*k*/ 1,
                             params, strlen(params),
                             &result_json, &result_len);
    if (rc != 0 || !result_json) {
        snprintf(err, sizeof err, "fractalsql: fsql_search_ptr rc=%d: %s",
                 rc, agents_core_detail(st));
        agents_result_err(ctx, err);
        return;
    }
    /* result_json is owned by st->ctx until its next search — copy. */
    sqlite3_result_text(ctx, result_json, (int)result_len, SQLITE_TRANSIENT);
}

/* ------------------------------------------------------------------ */
/* Shared Search->Synthesize pipeline (search_agent / rag_agent)       */
/* ------------------------------------------------------------------ */

/* embed query -> scan corpus (with rowids) -> Scout search -> content
 * retrieval -> LLM synthesis. On success `answer` holds the LLM's
 * response and idx/dist/got carry the top-k (search_agent's
 * source_doc_ids). */
static int agents_rag_pipeline(FsqlState *st, const char *who,
                               const char *query, const char *table,
                               const char *col, int pop_size, int iterations,
                               char **out_answer,
                               int **out_idx, double **out_dist, int *out_got,
                               char *err, size_t err_cap) {
    *out_answer = NULL;
    *out_idx = NULL;
    *out_dist = NULL;
    *out_got = 0;

    /* 1. Embed the natural-language query (embed tier; errors clearly
     * when http_embed_url is unset). */
    double *query_vec = NULL;
    int dim = 0;
    if (agents_embed_query(st, query, &query_vec, &dim, err, err_cap) != 0)
        return -1;
    if (dim > FSQL_ARENA_MAX_DIM) {
        free(query_vec);
        agents_set_err(err, err_cap,
                       "fractalsql: embedding dim %d exceeds the arena cap %d",
                       dim, FSQL_ARENA_MAX_DIM);
        return -1;
    }

    /* 2. Diverse Scout search over table.col, capturing each row's
     * rowid so result positions map back to physical rows. */
    AgentCorpus corpus;
    if (agents_scan_corpus(st, table, col, dim, 1, &corpus,
                           err, err_cap) != 0) {
        free(query_vec);
        return -1;
    }
    if (corpus.n_rows == 0) {
        agents_corpus_free(&corpus);
        free(query_vec);
        agents_set_err(err, err_cap, "fractalsql: no rows found in %s.%s",
                       table, col);
        return -1;
    }

    const char *result_json = NULL;
    size_t      result_len  = 0;
    int rc = agents_scout_search(st, &corpus, query_vec, pop_size,
                                 pop_size, iterations,
                                 &result_json, &result_len, err, err_cap);
    free(query_vec);
    if (rc != 0) {
        agents_corpus_free(&corpus);
        return -1;
    }

    int *idx     = (int *)malloc((size_t)pop_size * sizeof(int));
    double *dist = (double *)malloc((size_t)pop_size * sizeof(double));
    if (!idx || !dist) {
        free(idx); free(dist);
        agents_corpus_free(&corpus);
        agents_set_err(err, err_cap, "fractalsql: out of memory");
        return -1;
    }
    int got = fsql_extract_topk(result_json, pop_size, idx, dist);
    if (got < 0) {
        free(idx); free(dist);
        agents_corpus_free(&corpus);
        agents_set_err(err, err_cap,
                       "fractalsql: malformed top_k in search result");
        return -1;
    }

    /* 3. Reason over the matched rows' CONTENT, not the raw vectors. */
    char *ctx_json = agents_retrieval_context(st, table, col, &corpus,
                                              idx, got, err, err_cap);
    agents_corpus_free(&corpus);
    if (!ctx_json) {
        free(idx); free(dist);
        return -1;
    }

    char *answer = NULL;
    rc = fsql_reasoning_generate(st, FSQL_REASONING_TIER_CHAT, query,
                                 ctx_json, &answer, err, err_cap);
    free(ctx_json);
    if (rc != 0) {
        free(idx); free(dist);
        return -1;
    }

    *out_answer = answer;
    *out_idx = idx;
    *out_dist = dist;
    *out_got = got;
    (void)who;
    return 0;
}

static void fractal_search_agent_fn(sqlite3_context *ctx, int argc,
                                    sqlite3_value **argv) {
    FsqlState *st = (FsqlState *)sqlite3_user_data(ctx);
    char err[512];

    if (argc < 3 || argc > 5) {
        sqlite3_result_error(ctx,
            "fractal_search_agent(query, table_name, vector_col "
            "[, pop_size, iterations]) expects 3 to 5 args", -1);
        return;
    }
    if (sqlite3_value_type(argv[0]) == SQLITE_NULL ||
        sqlite3_value_type(argv[1]) == SQLITE_NULL ||
        sqlite3_value_type(argv[2]) == SQLITE_NULL) {
        sqlite3_result_error(ctx,
            "fractalsql: query, table_name, and vector_col are required", -1);
        return;
    }
    int pop_size = 50, iterations = 15;
    if (argc >= 4 && sqlite3_value_type(argv[3]) != SQLITE_NULL)
        pop_size = sqlite3_value_int(argv[3]);
    if (argc >= 5 && sqlite3_value_type(argv[4]) != SQLITE_NULL)
        iterations = sqlite3_value_int(argv[4]);

    const char *query = (const char *)sqlite3_value_text(argv[0]);
    const char *table = (const char *)sqlite3_value_text(argv[1]);
    const char *col   = (const char *)sqlite3_value_text(argv[2]);
    if (!query || !table || !col) { sqlite3_result_error_nomem(ctx); return; }

    if (!agents_ident_ok(table) || !agents_ident_ok(col)) {
        sqlite3_result_error(ctx,
            "fractalsql: table_name and vector_col must be plain "
            "identifiers ([A-Za-z_][A-Za-z0-9_]*)", -1);
        return;
    }
    if (agents_require_reasoning(st, "fractal_search_agent",
                                 err, sizeof err) != 0) {
        agents_result_err(ctx, err);
        return;
    }

    char *answer = NULL;
    int *idx = NULL;
    double *dist = NULL;
    int got = 0;
    if (agents_rag_pipeline(st, "fractal_search_agent", query, table, col,
                            pop_size, iterations, &answer,
                            &idx, &dist, &got, err, sizeof err) != 0) {
        agents_result_err(ctx, err);
        return;
    }
    free(dist);

    /* 4. Composite result as JSON. */
    StrBuf out;
    sb_init(&out);
    sb_puts(&out, "{\"answer\":");
    sb_json_string(&out, answer);
    sb_puts(&out, ",\"source_doc_ids\":[");
    for (int i = 0; i < got; i++) {
        if (i) sb_puts(&out, ",");
        sb_printf(&out, "%d", idx[i]);
    }
    /* 100 ms placeholder for execution_time_ms. */
    sb_puts(&out, "],\"execution_time_ms\":100}");
    free(idx);
    free(answer);

    if (sb_failed(&out)) {
        sb_free(&out);
        sqlite3_result_error_nomem(ctx);
        return;
    }
    sqlite3_result_text(ctx, out.buf, (int)out.len, SQLITE_TRANSIENT);
    sb_free(&out);
}

/* ------------------------------------------------------------------ */
/* fractal_rag_agent(query, table_name, vector_col [, meta_filter])    */
/* ------------------------------------------------------------------ */

static void fractal_rag_agent_fn(sqlite3_context *ctx, int argc,
                                 sqlite3_value **argv) {
    FsqlState *st = (FsqlState *)sqlite3_user_data(ctx);
    char err[512];

    if (argc < 3 || argc > 4) {
        sqlite3_result_error(ctx,
            "fractal_rag_agent(query, table_name, vector_col "
            "[, meta_filter]) expects 3 or 4 args", -1);
        return;
    }
    if (sqlite3_value_type(argv[0]) == SQLITE_NULL ||
        sqlite3_value_type(argv[1]) == SQLITE_NULL ||
        sqlite3_value_type(argv[2]) == SQLITE_NULL) {
        sqlite3_result_error(ctx,
            "fractalsql: query, table_name, and vector_col are required", -1);
        return;
    }
    const char *query = (const char *)sqlite3_value_text(argv[0]);
    const char *table = (const char *)sqlite3_value_text(argv[1]);
    const char *col   = (const char *)sqlite3_value_text(argv[2]);
    if (!query || !table || !col) { sqlite3_result_error_nomem(ctx); return; }
    /* meta_filter (argv[3]) is reserved for a future metadata WHERE
     * filter and stays unimplemented. */

    if (!agents_ident_ok(table) || !agents_ident_ok(col)) {
        sqlite3_result_error(ctx,
            "fractalsql: table_name and vector_col must be plain "
            "identifiers ([A-Za-z_][A-Za-z0-9_]*)", -1);
        return;
    }
    if (agents_require_reasoning(st, "fractal_rag_agent",
                                 err, sizeof err) != 0) {
        agents_result_err(ctx, err);
        return;
    }

    char *answer = NULL;
    int *idx = NULL;
    double *dist = NULL;
    int got = 0;
    if (agents_rag_pipeline(st, "fractal_rag_agent", query, table, col,
                            /*pop_size*/ 50, /*iterations*/ 15, &answer,
                            &idx, &dist, &got, err, sizeof err) != 0) {
        agents_result_err(ctx, err);
        return;
    }
    free(idx);
    free(dist);

    /* Result JSON has the single attribute `answer`. */
    StrBuf out;
    sb_init(&out);
    sb_puts(&out, "{\"answer\":");
    sb_json_string(&out, answer);
    sb_puts(&out, "}");
    free(answer);

    if (sb_failed(&out)) {
        sb_free(&out);
        sqlite3_result_error_nomem(ctx);
        return;
    }
    sqlite3_result_text(ctx, out.buf, (int)out.len, SQLITE_TRANSIENT);
    sb_free(&out);
}

/* ------------------------------------------------------------------ */
/* fractal_sql_agent helpers                                           */
/* ------------------------------------------------------------------ */

/* Parse a TEXT JSON array of strings (the text[] analog for
 * table_names). Returns a malloc'd array of malloc'd strings.
 * 0 on success (possibly 0 strings), -1 on malformed input. */
static int agents_parse_string_array(const char *json,
                                     char ***out, int *out_n) {
    *out = NULL;
    *out_n = 0;
    if (!json) return 0;
    const char *p = json;
    while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p++;
    if (*p == '\0') return 0;
    if (*p != '[') return -1;
    p++;

    char **arr = (char **)calloc((size_t)FSQL_T2S_MAX_TABLES, sizeof(char *));
    if (!arr) return -1;
    int n = 0;

    for (;;) {
        while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r' || *p == ',')
            p++;
        if (*p == ']') break;
        if (*p != '"' || n >= FSQL_T2S_MAX_TABLES) goto fail;
        p++;
        StrBuf s;
        sb_init(&s);
        while (*p && *p != '"') {
            if (*p == '\\' && p[1]) {
                p++;
                switch (*p) {
                case 'n': sb_putn(&s, "\n", 1); break;
                case 't': sb_putn(&s, "\t", 1); break;
                case 'r': sb_putn(&s, "\r", 1); break;
                default:  sb_putn(&s, p, 1);    break;  /* \" \\ etc. */
                }
                p++;
            } else {
                sb_putn(&s, p, 1);
                p++;
            }
        }
        if (*p != '"' || sb_failed(&s)) { sb_free(&s); goto fail; }
        p++;
        arr[n++] = s.buf;
    }

    *out = arr;
    *out_n = n;
    return 0;

fail:
    for (int i = 0; i < n; i++) free(arr[i]);
    free(arr);
    return -1;
}

static void agents_free_string_array(char **arr, int n) {
    if (!arr) return;
    for (int i = 0; i < n; i++) free(arr[i]);
    free(arr);
}

/* Plain-text schema description from sqlite_master (the
 * fractal_schema_context analog for the GENERATE prompt). Named
 * tables are matched with a bound parameter; NULL/empty list means
 * every non-internal table/view. Returns malloc'd text or NULL. */
static char *agents_schema_context(FsqlState *st, char **tables, int n_tables,
                                   char *err, size_t err_cap) {
    StrBuf out;
    sb_init(&out);

    sqlite3_stmt *stmt = NULL;
    int rc;
    if (n_tables > 0) {
        rc = sqlite3_prepare_v2(st->db,
            "SELECT name, sql FROM sqlite_master "
            "WHERE type IN ('table','view') AND name = ?1", -1, &stmt, NULL);
    } else {
        rc = sqlite3_prepare_v2(st->db,
            "SELECT name, sql FROM sqlite_master "
            "WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%' "
            "ORDER BY name", -1, &stmt, NULL);
    }
    if (rc != SQLITE_OK) {
        agents_set_err(err, err_cap,
                       "fractal_sql_agent: schema introspection failed: %s",
                       sqlite3_errmsg(st->db));
        sb_free(&out);
        return NULL;
    }

    int found = 0;
    for (int t = 0; t < n_tables || (t == 0 && n_tables == 0); t++) {
        if (n_tables > 0)
            sqlite3_bind_text(stmt, 1, tables[t], -1, SQLITE_TRANSIENT);
        while ((rc = sqlite3_step(stmt)) == SQLITE_ROW) {
            const unsigned char *name = sqlite3_column_text(stmt, 0);
            const unsigned char *ddl  = sqlite3_column_text(stmt, 1);
            sb_puts(&out, "Table: ");
            sb_puts(&out, name ? (const char *)name : "?");
            sb_puts(&out, "\n");
            if (ddl && *ddl) {
                sb_puts(&out, (const char *)ddl);
                sb_puts(&out, "\n");
            }
            sb_puts(&out, "\n");
            found++;
            /* The auto-discovery path is bounded too. */
            if (n_tables == 0 && found >= FSQL_T2S_MAX_TABLES) break;
        }
        if (rc != SQLITE_DONE && rc != SQLITE_ROW) break;
        if (n_tables > 0)
            sqlite3_reset(stmt);
        else
            break;
    }
    sqlite3_finalize(stmt);

    if (sb_failed(&out)) {
        sb_free(&out);
        agents_set_err(err, err_cap, "fractalsql: out of memory");
        return NULL;
    }
    if (found == 0) {
        sb_free(&out);
        agents_set_err(err, err_cap,
                       "fractal_sql_agent: no matching tables found");
        return NULL;
    }
    return out.buf;
}

/* Strip a ```sql fenced code block from the model's GENERATE response.
 * Returns a malloc'd copy of the inner SQL, or a malloc'd copy of the
 * trimmed input when no fence is present. NULL on OOM. */
static char *agents_strip_sql_fence(const char *s) {
    if (!s) s = "";
    const char *start = s;
    while (*start == ' ' || *start == '\t' || *start == '\n' ||
           *start == '\r') start++;

    char *out = NULL;
    if (start[0] == '`' && start[1] == '`' && start[2] == '`') {
        const char *body = start + 3;
        while (*body && *body != '\n') body++;      /* skip the language tag */
        if (*body) body++;
        const char *end = strstr(body, "```");
        size_t len = end ? (size_t)(end - body) : strlen(body);
        out = (char *)malloc(len + 1);
        if (out) {
            memcpy(out, body, len);
            out[len] = '\0';
        }
    } else {
        size_t len = strlen(start);
        out = (char *)malloc(len + 1);
        if (out) {
            memcpy(out, start, len);
            out[len] = '\0';
        }
    }
    /* Trim trailing whitespace. */
    if (out) {
        size_t len = strlen(out);
        while (len > 0 && (out[len - 1] == '\n' || out[len - 1] == '\r' ||
                           out[len - 1] == ' '  || out[len - 1] == '\t'))
            out[--len] = '\0';
    }
    return out;
}

/* Allowlist check for model-generated SQL — prepare-based (see the
 * header comment). Returns NULL when the statement passes, else a
 * malloc'd rejection reason to feed back to the next GENERATE attempt
 * (the t2s_check_allowlist contract). */
static char *agents_check_allowlist(FsqlState *st, const char *sql) {
    sqlite3_stmt *stmt = NULL;
    const char *tail = NULL;
    int rc = sqlite3_prepare_v2(st->db, sql, -1, &stmt, &tail);
    if (rc != SQLITE_OK) {
        const char *msg = sqlite3_errmsg(st->db);
        size_t need = strlen(msg) + 64;
        char *out = (char *)malloc(need);
        if (out) snprintf(out, need, "SQL does not parse: %s", msg);
        return out;
    }

    char *result = NULL;
    /* Single-statement check: anything but whitespace after the first
     * prepared statement is a smuggled second statement. */
    const char *t = tail;
    while (*t == ' ' || *t == '\t' || *t == '\n' || *t == '\r' ||
           *t == '\f' || *t == '\v')
        t++;
    if (*t != '\0') {
        result = (char *)malloc(160);
        if (result)
            strcpy(result,
                   "expected exactly one SQL statement -- "
                   "fractal_sql_agent only returns a single statement");
    }

    /* Statement-class check. In "select" mode the statement must be
     * read-only; sqlite3_stmt_readonly is false for any statement that
     * writes, including a data-modifying CTE wrapped in a top-level
     * SELECT (the t2s_check_readonly analog). */
    if (!result) {
        const char *mode = fsql_config_get(st, "text_to_sql_allowed_statements");
        int allow_writes = (mode && strcmp(mode, "select_insert_update") == 0);
        if (!allow_writes && !sqlite3_stmt_readonly(stmt)) {
            result = (char *)malloc(256);
            if (result)
                snprintf(result, 256,
                         "statement is not permitted -- "
                         "fractalsql_set('text_to_sql_allowed_statements') "
                         "is set to \"%s\"",
                         (mode && *mode) ? mode : "select");
        }
    }

    sqlite3_finalize(stmt);
    return result;
}

/* Execute a validated read-only SELECT, accumulating up to
 * FSQL_AGENTS_MAX_RESULT_ROWS rows as a JSON array of arrays. 0 on
 * success, -1 with err set. */
static int agents_exec_select_json(FsqlState *st, const char *sql,
                                   StrBuf *rows, int *n_rows,
                                   char *err, size_t err_cap) {
    *n_rows = 0;
    sqlite3_stmt *stmt = NULL;
    int rc = sqlite3_prepare_v2(st->db, sql, -1, &stmt, NULL);
    if (rc != SQLITE_OK) {
        agents_set_err(err, err_cap, "fractalsql: execution failed: %s",
                       sqlite3_errmsg(st->db));
        return -1;
    }
    if (!sqlite3_stmt_readonly(stmt)) {
        /* Re-checked here so nothing but a read-only statement is ever
         * stepped by the agent, whatever the caller passed. */
        sqlite3_finalize(stmt);
        agents_set_err(err, err_cap,
                       "fractalsql: execution failed: refusing to run a "
                       "non-read-only statement");
        return -1;
    }

    sb_puts(rows, "[");
    int ncols = sqlite3_column_count(stmt);
    while ((rc = sqlite3_step(stmt)) == SQLITE_ROW) {
        if (*n_rows) sb_puts(rows, ",");
        sb_puts(rows, "[");
        for (int i = 0; i < ncols; i++) {
            if (i) sb_puts(rows, ",");
            sb_json_column(rows, stmt, i);
        }
        sb_puts(rows, "]");
        (*n_rows)++;
        if (*n_rows >= FSQL_AGENTS_MAX_RESULT_ROWS) break;
    }
    sb_puts(rows, "]");
    sqlite3_finalize(stmt);

    if (rc != SQLITE_DONE && rc != SQLITE_ROW) {
        agents_set_err(err, err_cap, "fractalsql: execution failed: %s",
                       sqlite3_errmsg(st->db));
        return -1;
    }
    if (sb_failed(rows)) {
        agents_set_err(err, err_cap, "fractalsql: out of memory");
        return -1;
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/* fractal_sql_agent(question [, table_names, max_retries,
 *                   auto_execute])                                    */
/* ------------------------------------------------------------------ */

static void fractal_sql_agent_fn(sqlite3_context *ctx, int argc,
                                 sqlite3_value **argv) {
    FsqlState *st = (FsqlState *)sqlite3_user_data(ctx);
    char err[512];

    if (argc < 1 || argc > 4) {
        sqlite3_result_error(ctx,
            "fractal_sql_agent(question [, table_names, max_retries, "
            "auto_execute]) expects 1 to 4 args", -1);
        return;
    }
    if (sqlite3_value_type(argv[0]) == SQLITE_NULL) {
        sqlite3_result_error(ctx,
            "fractalsql: question must not be NULL", -1);
        return;
    }
    const char *question = (const char *)sqlite3_value_text(argv[0]);
    if (!question) { sqlite3_result_error_nomem(ctx); return; }

    int max_retries = 2;
    if (argc >= 3 && sqlite3_value_type(argv[2]) != SQLITE_NULL)
        max_retries = sqlite3_value_int(argv[2]);
    int auto_execute = 0;
    if (argc >= 4 && sqlite3_value_type(argv[3]) != SQLITE_NULL)
        auto_execute = sqlite3_value_int(argv[3]) != 0;
    /* max_retries <= 0 always allows at least one attempt. */
    if (max_retries < 1) max_retries = 1;

    if (agents_require_reasoning(st, "fractal_sql_agent",
                                 err, sizeof err) != 0) {
        agents_result_err(ctx, err);
        return;
    }

    char **tables = NULL;
    int n_tables = 0;
    if (argc >= 2 && sqlite3_value_type(argv[1]) != SQLITE_NULL) {
        const char *tjson = (const char *)sqlite3_value_text(argv[1]);
        if (!tjson) { sqlite3_result_error_nomem(ctx); return; }
        if (agents_parse_string_array(tjson, &tables, &n_tables) != 0) {
            sqlite3_result_error(ctx,
                "fractalsql: table_names must be a JSON array of "
                "table-name strings", -1);
            return;
        }
        if (n_tables > FSQL_T2S_MAX_TABLES) {
            agents_free_string_array(tables, n_tables);
            sqlite3_result_error(ctx,
                "fractalsql: too many table_names (limit 512)", -1);
            return;
        }
    }

    char *schema_ctx = agents_schema_context(st, tables, n_tables,
                                             err, sizeof err);
    agents_free_string_array(tables, n_tables);
    if (!schema_ctx) {
        agents_result_err(ctx, err);
        return;
    }

    const char *mode = fsql_config_get(st, "text_to_sql_allowed_statements");
    int allow_writes = (mode && strcmp(mode, "select_insert_update") == 0);

    /* GENERATE -> allowlist -> retry loop. Validates by preparing
     * rather than EXPLAINing — preparing is the same mechanical parse
     * check and never executes. */
    char *final_sql  = NULL;
    char *feedback   = NULL;
    int   passed     = 0;
    int   attempt    = 0;
    while (attempt < max_retries) {
        attempt++;

        StrBuf prompt;
        sb_init(&prompt);
        sb_printf(&prompt,
                  "Write a single SQLite %s statement that answers this "
                  "question. Return ONLY the SQL, wrapped in a ```sql "
                  "fenced code block, with no other explanation.\n\n"
                  "Question: %s\n",
                  allow_writes ? "SELECT, INSERT, or UPDATE" : "SELECT",
                  question);
        if (feedback) {
            sb_printf(&prompt,
                      "\nYour previous attempt was rejected for this "
                      "reason: %s\n\nWrite a corrected statement.\n",
                      feedback);
        }
        sb_puts(&prompt, "\nSchema:\n");
        sb_puts(&prompt, schema_ctx);
        if (sb_failed(&prompt)) {
            sb_free(&prompt);
            free(final_sql);
            free(feedback);
            free(schema_ctx);
            sqlite3_result_error_nomem(ctx);
            return;
        }

        /* Runs on the T2S tier so the T2S env block applies
         * (RESPONSE_MODE=code, SYSTEM_TAG=sqlite) — see the header
         * comment, fractal_sql_agent bullet. */
        char *resp = NULL;
        int grc = fsql_reasoning_generate(st, FSQL_REASONING_TIER_T2S,
                                          prompt.buf, "{}", &resp,
                                          err, sizeof err);
        sb_free(&prompt);
        if (grc != 0) {
            free(final_sql);
            free(feedback);
            free(schema_ctx);
            agents_result_err(ctx, err);
            return;
        }

        free(final_sql);
        final_sql = agents_strip_sql_fence(resp);
        free(resp);
        if (!final_sql) {
            free(feedback);
            free(schema_ctx);
            sqlite3_result_error_nomem(ctx);
            return;
        }

        char *allow_err = agents_check_allowlist(st, final_sql);
        free(feedback);
        feedback = allow_err;
        if (allow_err) continue;   /* retry with the rejection reason */
        passed = 1;
        break;
    }
    free(schema_ctx);

    /* auto_execute: run the validated, read-only statement and collect
     * the rows. Only reached when `passed`, so no unvalidated SQL ever
     * runs. */
    StrBuf result_json;
    sb_init(&result_json);
    int executed_ok = 0;
    int result_is_object = 0;   /* result_json holds a {"status":..} doc
                                 * rather than a bare rows array */
    if (auto_execute && passed && final_sql) {
        int n_rows = 0;
        if (agents_exec_select_json(st, final_sql, &result_json, &n_rows,
                                    err, sizeof err) == 0) {
            executed_ok = 1;
        } else {
            sb_free(&result_json);
            sb_init(&result_json);
            sb_puts(&result_json, "{\"status\":\"execution_failed\","
                                  "\"rows\":[]}");
            result_is_object = 1;
        }
    }

    /* Composite result as JSON. */
    StrBuf out;
    sb_init(&out);
    sb_puts(&out, "{\"generated_sql\":");
    if (final_sql) sb_json_string(&out, final_sql);
    else           sb_puts(&out, "null");
    sb_puts(&out, ",\"execution_status\":");
    if (executed_ok)         sb_json_string(&out, "executed");
    else if (auto_execute && passed) sb_json_string(&out, "execution_failed");
    else if (passed)         sb_json_string(&out, "success");
    else                     sb_json_string(&out, "validation_failed");
    sb_printf(&out, ",\"retry_count\":%d", attempt);
    sb_puts(&out, ",\"result_json\":");
    if (executed_ok) {
        sb_printf(&out, "{\"status\":\"executed\",\"rows\":%s}",
                  result_json.buf ? result_json.buf : "[]");
    } else if (result_is_object) {
        sb_puts(&out, result_json.buf);
    } else if (!passed && feedback) {
        sb_puts(&out, "{\"status\":\"validation_failed\",\"error\":");
        sb_json_string(&out, feedback);
        sb_puts(&out, "}");
    } else {
        sb_puts(&out, "null");
    }
    sb_puts(&out, "}");

    free(final_sql);
    free(feedback);
    sb_free(&result_json);

    if (sb_failed(&out)) {
        sb_free(&out);
        sqlite3_result_error_nomem(ctx);
        return;
    }
    sqlite3_result_text(ctx, out.buf, (int)out.len, SQLITE_TRANSIENT);
    sb_free(&out);
}

/* ------------------------------------------------------------------ */
/* fractal_agent_plan_explore(initial_state, strategy_table,
 *                            vector_col, max_branches)                */
/* ------------------------------------------------------------------ */

static void fractal_plan_explore_fn(sqlite3_context *ctx, int argc,
                                    sqlite3_value **argv) {
    (void)argc;
    FsqlState *st = (FsqlState *)sqlite3_user_data(ctx);
    char err[512];

    /* STRICT: NULL in, NULL out. */
    for (int i = 0; i < 4; i++) {
        if (sqlite3_value_type(argv[i]) == SQLITE_NULL) {
            sqlite3_result_null(ctx);
            return;
        }
    }
    if (!st || !st->ctx) {
        sqlite3_result_error(ctx, "fractalsql: extension not initialized", -1);
        return;
    }
    const char *initial_state = (const char *)sqlite3_value_text(argv[0]);
    const char *table         = (const char *)sqlite3_value_text(argv[1]);
    const char *col           = (const char *)sqlite3_value_text(argv[2]);
    int max_branches          = sqlite3_value_int(argv[3]);
    if (!initial_state || !table || !col) {
        sqlite3_result_error_nomem(ctx);
        return;
    }
    if (!agents_ident_ok(table) || !agents_ident_ok(col)) {
        sqlite3_result_error(ctx,
            "fractalsql: strategy_table and vector_col must be plain "
            "identifiers ([A-Za-z_][A-Za-z0-9_]*)", -1);
        return;
    }
    if (max_branches < 1) {
        sqlite3_result_error(ctx,
            "fractalsql: max_branches must be > 0", -1);
        return;
    }
    if (max_branches > FSQL_AGENTS_MAX_POPULATION) {
        sqlite3_result_error(ctx,
            "fractalsql: max_branches out of range [1, 100000]", -1);
        return;
    }

    /* Embed initial_state as the query. */
    double *query_vec = NULL;
    int dim = 0;
    if (agents_embed_query(st, initial_state, &query_vec, &dim,
                           err, sizeof err) != 0) {
        agents_result_err(ctx, err);
        return;
    }

    AgentCorpus corpus;
    if (agents_scan_corpus(st, table, col, dim, 0, &corpus,
                           err, sizeof err) != 0) {
        free(query_vec);
        agents_result_err(ctx, err);
        return;
    }
    if (corpus.n_rows == 0) {
        agents_corpus_free(&corpus);
        free(query_vec);
        sqlite3_result_error(ctx, "fractalsql: no rows found in the corpus", -1);
        return;
    }

    /* Full Scout params (max_generation=15, pop=max_branches) so
     * fsql_search_ptr populates top_k. */
    const char *result_json = NULL;
    size_t      result_len  = 0;
    int rc = agents_scout_search(st, &corpus, query_vec, max_branches,
                                 max_branches, /*iterations*/ 15,
                                 &result_json, &result_len,
                                 err, sizeof err);
    free(query_vec);
    if (rc != 0) {
        agents_corpus_free(&corpus);
        agents_result_err(ctx, err);
        return;
    }

    int *idx = (int *)malloc((size_t)max_branches * sizeof(int));
    double *dist = (double *)malloc((size_t)max_branches * sizeof(double));
    if (!idx || !dist) {
        free(idx); free(dist);
        agents_corpus_free(&corpus);
        sqlite3_result_error_nomem(ctx);
        return;
    }
    int got = fsql_extract_topk(result_json, max_branches, idx, dist);
    if (got < 0) got = 0;   /* empty set, not a crash */

    /* JSON array of branch records; each branch's plan_trajectory is
     * its OWN matched strategy vector (corpus row idx[i]), confidence
     * = 1 - distance. */
    StrBuf out;
    sb_init(&out);
    sb_puts(&out, "[");
    int emitted = 0;
    for (int i = 0; i < got; i++) {
        if (idx[i] < 0 || (size_t)idx[i] >= corpus.n_rows) continue;
        if (emitted) sb_puts(&out, ",");
        sb_printf(&out, "{\"branch_id\":%d,\"plan_trajectory\":", idx[i]);
        sb_json_doubles(&out, corpus.data + (size_t)idx[i] * corpus.dim,
                        corpus.dim);
        sb_printf(&out, ",\"confidence_score\":%.17g}", 1.0 - dist[i]);
        emitted = 1;
    }
    sb_puts(&out, "]");
    free(idx);
    free(dist);
    agents_corpus_free(&corpus);

    if (sb_failed(&out)) {
        sb_free(&out);
        sqlite3_result_error_nomem(ctx);
        return;
    }
    sqlite3_result_text(ctx, out.buf, (int)out.len, SQLITE_TRANSIENT);
    sb_free(&out);
}

/* ------------------------------------------------------------------ */
/* fractal_agent_trajectory_predict(table_name, vector_col,
 *                                  baseline_id, forecast_steps)       */
/* ------------------------------------------------------------------ */

/* Decode the single vector value produced by a prepared one-row
 * query into a malloc'd double buffer. Returns 0 / -1. */
static int agents_decode_row_vector(sqlite3_stmt *stmt, int col,
                                    double **out, int *out_dim) {
    *out = NULL;
    *out_dim = 0;
    if (sqlite3_column_type(stmt, col) == SQLITE_NULL) return -1;
    float *fv = NULL;
    int fdim = 0;
    if (fsql_vec_decode(sqlite3_column_value(stmt, col), &fv, &fdim) != 0)
        return -1;
    if (!agents_dim_in_arena(fdim)) { free(fv); return -1; }
    double *v = (double *)malloc((size_t)fdim * sizeof(double));
    if (!v) { free(fv); return -1; }
    for (int i = 0; i < fdim; i++) v[i] = (double)fv[i];
    free(fv);
    *out = v;
    *out_dim = fdim;
    return 0;
}

static void fractal_trajectory_predict_fn(sqlite3_context *ctx, int argc,
                                          sqlite3_value **argv) {
    (void)argc;
    FsqlState *st = (FsqlState *)sqlite3_user_data(ctx);
    char err[512];

    for (int i = 0; i < 4; i++) {
        if (sqlite3_value_type(argv[i]) == SQLITE_NULL) {
            sqlite3_result_null(ctx);   /* STRICT */
            return;
        }
    }
    if (!st || !st->ctx) {
        sqlite3_result_error(ctx, "fractalsql: extension not initialized", -1);
        return;
    }
    const char *table = (const char *)sqlite3_value_text(argv[0]);
    const char *col   = (const char *)sqlite3_value_text(argv[1]);
    sqlite3_int64 baseline_id = sqlite3_value_int64(argv[2]);
    int forecast_steps = sqlite3_value_int(argv[3]);
    if (!table || !col) { sqlite3_result_error_nomem(ctx); return; }
    /* forecast_steps is accepted but unused (the delta extrapolation
     * is one step). */
    (void)forecast_steps;

    if (!agents_ident_ok(table) || !agents_ident_ok(col)) {
        sqlite3_result_error(ctx,
            "fractalsql: table_name and vector_col must be plain "
            "identifiers ([A-Za-z_][A-Za-z0-9_]*)", -1);
        return;
    }

    /* SQLite tables are keyed by rowid (WITHOUT ROWID tables surface a
     * clean prepare error here: "no usable primary key"). */
    sqlite3_stmt *stmt = NULL;
    double *baseline = NULL, *current = NULL;
    int b_dim = 0, c_dim = 0;

    StrBuf sql;
    sb_init(&sql);
    sb_puts(&sql, "SELECT ");
    sb_sql_ident(&sql, col);
    sb_puts(&sql, " FROM ");
    sb_sql_ident(&sql, table);
    sb_puts(&sql, " WHERE rowid = ?1");
    if (sb_failed(&sql)) {
        sb_free(&sql);
        sqlite3_result_error_nomem(ctx);
        return;
    }
    int rc = sqlite3_prepare_v2(st->db, sql.buf, -1, &stmt, NULL);
    sb_free(&sql);
    if (rc != SQLITE_OK) {
        agents_set_err(err, sizeof err,
                       "fractal_agent_trajectory_predict: table %s has no "
                       "usable rowid key: %s", table, sqlite3_errmsg(st->db));
        agents_result_err(ctx, err);
        return;
    }
    sqlite3_bind_int64(stmt, 1, baseline_id);
    rc = sqlite3_step(stmt);
    if (rc != SQLITE_ROW) {
        agents_set_err(err, sizeof err,
                       "fractal_agent_trajectory_predict: no row in %s with "
                       "rowid = %lld", table, (long long)baseline_id);
        sqlite3_finalize(stmt);
        agents_result_err(ctx, err);
        return;
    }
    if (agents_decode_row_vector(stmt, 0, &baseline, &b_dim) != 0) {
        sqlite3_finalize(stmt);
        sqlite3_result_error(ctx,
            "fractal_agent_trajectory_predict: baseline vector is NULL or "
            "malformed", -1);
        return;
    }
    sqlite3_finalize(stmt);

    /* Current vector: the latest row by rowid. */
    sb_init(&sql);
    sb_puts(&sql, "SELECT ");
    sb_sql_ident(&sql, col);
    sb_puts(&sql, " FROM ");
    sb_sql_ident(&sql, table);
    sb_puts(&sql, " ORDER BY rowid DESC LIMIT 1");
    if (sb_failed(&sql)) {
        sb_free(&sql);
        free(baseline);
        sqlite3_result_error_nomem(ctx);
        return;
    }
    rc = sqlite3_prepare_v2(st->db, sql.buf, -1, &stmt, NULL);
    sb_free(&sql);
    if (rc != SQLITE_OK) {
        agents_set_err(err, sizeof err,
                       "fractal_agent_trajectory_predict: current-row query "
                       "failed: %s", sqlite3_errmsg(st->db));
        free(baseline);
        agents_result_err(ctx, err);
        return;
    }
    rc = sqlite3_step(stmt);
    if (rc != SQLITE_ROW) {
        agents_set_err(err, sizeof err,
                       "fractal_agent_trajectory_predict: %s has no rows",
                       table);
        sqlite3_finalize(stmt);
        free(baseline);
        agents_result_err(ctx, err);
        return;
    }
    int drc = agents_decode_row_vector(stmt, 0, &current, &c_dim);
    sqlite3_finalize(stmt);
    if (drc != 0) {
        free(baseline);
        sqlite3_result_error(ctx,
            "fractal_agent_trajectory_predict: current vector is NULL or "
            "malformed", -1);
        return;
    }

    if (c_dim != b_dim) {
        agents_set_err(err, sizeof err,
                       "fractal_agent_trajectory_predict: baseline dim %d != "
                       "current dim %d", b_dim, c_dim);
        free(baseline); free(current);
        agents_result_err(ctx, err);
        return;
    }

    /* Delta = current - baseline (the real computed delta, not a
     * stub). */
    double *delta = (double *)malloc((size_t)b_dim * sizeof(double));
    if (!delta) {
        free(baseline); free(current);
        sqlite3_result_error_nomem(ctx);
        return;
    }
    for (int i = 0; i < b_dim; i++) delta[i] = current[i] - baseline[i];
    free(baseline);
    free(current);

    /* Search the whole corpus for the nearest point to the delta. */
    AgentCorpus corpus;
    if (agents_scan_corpus(st, table, col, b_dim, 0, &corpus,
                           err, sizeof err) != 0) {
        free(delta);
        agents_result_err(ctx, err);
        return;
    }
    if (corpus.n_rows == 0) {
        agents_corpus_free(&corpus);
        free(delta);
        sqlite3_result_error(ctx,
            "fractal_agent_trajectory_predict: corpus has no rows", -1);
        return;
    }

    const char *result_json = NULL;
    size_t      result_len  = 0;
    int src = fsql_search_ptr(st->ctx, corpus.data, corpus.n_rows,
                              (size_t)b_dim, delta, (size_t)b_dim, 1,
                              "{}", 2, &result_json, &result_len);
    free(delta);
    if (src != 0 || !result_json) {
        agents_set_err(err, sizeof err,
                       "fractalsql: trajectory search failed: %s",
                       agents_core_detail(st));
        agents_corpus_free(&corpus);
        agents_result_err(ctx, err);
        return;
    }

    int idx[1];
    double dist[1];
    int got = fsql_extract_topk(result_json, 1, idx, dist);
    if (got <= 0 || idx[0] < 0 || (size_t)idx[0] >= corpus.n_rows) {
        agents_corpus_free(&corpus);
        sqlite3_result_error(ctx,
            "fractal_agent_trajectory_predict: no predicted state found", -1);
        return;
    }

    double drift = dist[0];
    int risk = (drift > 0.5);   /* threshold should ideally be configurable */

    StrBuf out;
    sb_init(&out);
    sb_puts(&out, "{\"predicted_state_vector\":");
    sb_json_doubles(&out, corpus.data + (size_t)idx[0] * corpus.dim,
                    corpus.dim);
    sb_printf(&out, ",\"projected_drift_delta\":%.17g", drift);
    sb_printf(&out, ",\"risk_threshold_exceeded\":%s}",
              risk ? "true" : "false");
    agents_corpus_free(&corpus);

    if (sb_failed(&out)) {
        sb_free(&out);
        sqlite3_result_error_nomem(ctx);
        return;
    }
    sqlite3_result_text(ctx, out.buf, (int)out.len, SQLITE_TRANSIENT);
    sb_free(&out);
}

/* ------------------------------------------------------------------ */
/* fractal_agent_detect_loop(series)                                   */
/* ------------------------------------------------------------------ */

/* Detect a tight repetition cycle in a discrete-valued series: the
 * smallest period p in [1, max_p] with series[i] == series[i+p] for
 * every i in [0, n-p). Exact equality is correct — the entries are
 * integer state hashes cast to double (within 2^53). */
static int agents_detect_short_period(const double *s, int n, int max_p) {
    if (max_p > n / 2) max_p = n / 2;
    for (int p = 1; p <= max_p; p++) {
        int ok = 1;
        for (int i = 0; i < n - p; i++) {
            if (s[i] != s[i + p]) { ok = 0; break; }
        }
        if (ok) return p;
    }
    return 0;
}

static void fractal_detect_loop_fn(sqlite3_context *ctx, int argc,
                                   sqlite3_value **argv) {
    (void)argc;
    FsqlState *st = (FsqlState *)sqlite3_user_data(ctx);
    char err[512];

    if (sqlite3_value_type(argv[0]) == SQLITE_NULL) {
        sqlite3_result_null(ctx);   /* STRICT */
        return;
    }
    if (!st || !st->ctx) {
        sqlite3_result_error(ctx, "fractalsql: extension not initialized", -1);
        return;
    }

    /* int8[] analog: a TEXT (JSON/CSV) or float32-BLOB numeric series. */
    double *series = (double *)malloc(
        (size_t)FSQL_ARENA_MAX_DIM * sizeof(double));
    if (!series) { sqlite3_result_error_nomem(ctx); return; }
    int n = fsql_parse_value_to_doubles(argv[0], series,
                                        FSQL_ARENA_MAX_DIM);
    if (n <= 0) {
        free(series);
        sqlite3_result_error(ctx,
            "fractal_agent_detect_loop: log_arr must be a JSON/CSV array "
            "of state hashes (TEXT) or a float32 BLOB series", -1);
        return;
    }

    double alpha = 0.0;
    int rc = fsql_dimension_dfa(series, (size_t)n, &alpha);
    if (rc != FSQL_OK) {
        free(series);
        snprintf(err, sizeof err,
                 "fractal_agent_detect_loop: DFA needs a longer series "
                 "(rc=%d; >= 16 points)", rc);
        agents_result_err(ctx, err);
        return;
    }

    int period = agents_detect_short_period(series, n, n / 4);
    free(series);

    /* Flag a loop if EITHER the DFA exponent exceeds 0.9 (drift-to-
     * chaos cycling) OR a tight discrete period was found (clean
     * toggles like 12345<->67890 that DFA scores as low alpha). */
    StrBuf out;
    sb_init(&out);
    sb_printf(&out,
              "{\"agent_id\":\"monitor\",\"dfa_exponent\":%.17g,"
              "\"is_loop_detected\":%s}",
              alpha, (alpha > 0.9 || period > 0) ? "true" : "false");
    if (sb_failed(&out)) {
        sb_free(&out);
        sqlite3_result_error_nomem(ctx);
        return;
    }
    sqlite3_result_text(ctx, out.buf, (int)out.len, SQLITE_TRANSIENT);
    sb_free(&out);
}

/* ------------------------------------------------------------------ */
/* fractal_search_telemetry(table_name, vector_col, query, k)          */
/* fractal_hybrid_clinical_search(table_name, vector_col, query,
 *                                doc_ids, k)                          */
/* fractal_cross_modal_search(table_name, vector_col, morphology_vector,
 *                            clinical_vector, alpha_weight, k)        */
/* ------------------------------------------------------------------ */

/* Binary search in a sorted int64 array. */
static int agents_i64_cmp(const void *pa, const void *pb) {
    int64_t a = *(const int64_t *)pa, b = *(const int64_t *)pb;
    return (a > b) - (a < b);
}

static int agents_i64_sorted_contains(const int64_t *a, int n, int64_t key) {
    int lo = 0, hi = n - 1;
    while (lo <= hi) {
        int mid = lo + (hi - lo) / 2;
        if (a[mid] == key) return 1;
        if (a[mid] < key)  lo = mid + 1;
        else               hi = mid - 1;
    }
    return 0;
}

/* Shared body for the three table-backed top-k searches. Runs the
 * telemetry-shaped top-k over table.col; when `cohort` is non-NULL,
 * only rows whose 0-indexed scan position is in the (sorted) cohort
 * are searched, and doc_id_map translates filtered positions back to
 * real doc_ids. */
static void agents_telemetry_run(sqlite3_context *ctx,
                                 const char *table, const char *col,
                                 const double *query, int dim,
                                 int64_t *cohort, int n_cohort, int k) {
    FsqlState *st = (FsqlState *)sqlite3_user_data(ctx);
    char err[512];

    AgentCorpus corpus;
    if (agents_scan_corpus(st, table, col, dim, 0, &corpus,
                           err, sizeof err) != 0) {
        agents_result_err(ctx, err);
        return;
    }

    int64_t *doc_id_map = NULL;
    if (cohort) {
        double *filtered = (double *)malloc(
            (corpus.n_rows ? corpus.n_rows : 1)
            * (size_t)dim * sizeof(double));
        int64_t *map = (int64_t *)malloc(
            (corpus.n_rows ? corpus.n_rows : 1) * sizeof(int64_t));
        if (!filtered || !map) {
            free(filtered); free(map);
            agents_corpus_free(&corpus);
            sqlite3_result_error_nomem(ctx);
            return;
        }
        size_t kept_n = 0;
        for (size_t r = 0; r < corpus.n_rows; r++) {
            if (!agents_i64_sorted_contains(cohort, n_cohort, (int64_t)r))
                continue;
            memcpy(filtered + kept_n * (size_t)dim,
                   corpus.data + r * (size_t)dim,
                   (size_t)dim * sizeof(double));
            map[kept_n++] = (int64_t)r;
        }
        if (kept_n == 0) {
            free(filtered); free(map);
            agents_corpus_free(&corpus);
            sqlite3_result_error(ctx,
                "fractalsql: doc_ids cohort matched no rows in the corpus",
                -1);
            return;
        }
        free(corpus.data);          /* the filtered copy replaces it */
        corpus.data = filtered;
        corpus.n_rows = kept_n;
        doc_id_map = map;
    }

    StrBuf out;
    sb_init(&out);
    int trc = agents_topk_json(st, &corpus, query, k, doc_id_map, &out,
                               err, sizeof err);
    free(doc_id_map);
    agents_corpus_free(&corpus);
    if (trc != 0) {
        agents_result_err(ctx, err);
        return;
    }
    sqlite3_result_text(ctx, out.buf, (int)out.len, SQLITE_TRANSIENT);
    sb_free(&out);
}

/* Decode a query argument (TEXT CSV/JSON or canonical BLOB) into a
 * malloc'd double buffer. Returns NULL on malformed input. */
static double *agents_decode_query_doubles(sqlite3_value *v, int *out_dim) {
    *out_dim = 0;
    float *qf = NULL;
    int dim = 0;
    if (fsql_vec_decode(v, &qf, &dim) != 0) return NULL;
    if (!agents_dim_in_arena(dim)) { free(qf); return NULL; }
    double *q = (double *)malloc((size_t)dim * sizeof(double));
    if (!q) { free(qf); return NULL; }
    for (int i = 0; i < dim; i++) q[i] = (double)qf[i];
    free(qf);
    *out_dim = dim;
    return q;
}

/* STRICT: NULL in, NULL out. */
static void fractal_search_telemetry_fn(sqlite3_context *ctx, int argc,
                                        sqlite3_value **argv) {
    (void)argc;
    FsqlState *st = (FsqlState *)sqlite3_user_data(ctx);

    for (int i = 0; i < 4; i++) {
        if (sqlite3_value_type(argv[i]) == SQLITE_NULL) {
            sqlite3_result_null(ctx);
            return;
        }
    }
    if (!st || !st->ctx) {
        sqlite3_result_error(ctx, "fractalsql: extension not initialized", -1);
        return;
    }
    const char *table = (const char *)sqlite3_value_text(argv[0]);
    const char *col   = (const char *)sqlite3_value_text(argv[1]);
    if (!table || !col) { sqlite3_result_error_nomem(ctx); return; }
    if (!agents_ident_ok(table) || !agents_ident_ok(col)) {
        sqlite3_result_error(ctx,
            "fractalsql: table_name and vector_col must be plain "
            "identifiers ([A-Za-z_][A-Za-z0-9_]*)", -1);
        return;
    }
    int k = sqlite3_value_int(argv[3]);
    if (k <= 0) {
        sqlite3_result_error(ctx, "fractalsql: k must be > 0", -1);
        return;
    }
    int dim = 0;
    double *query = agents_decode_query_doubles(argv[2], &dim);
    if (!query) {
        sqlite3_result_error(ctx,
            "fractalsql: invalid query vector (expect CSV/JSON text or "
            "canonical float32 BLOB)", -1);
        return;
    }
    agents_telemetry_run(ctx, table, col, query, dim, NULL, 0, k);
    free(query);
}

/* STRICT: NULL in, NULL out. */
static void fractal_hybrid_clinical_search_fn(sqlite3_context *ctx, int argc,
                                              sqlite3_value **argv) {
    (void)argc;
    FsqlState *st = (FsqlState *)sqlite3_user_data(ctx);

    for (int i = 0; i < 5; i++) {
        if (sqlite3_value_type(argv[i]) == SQLITE_NULL) {
            sqlite3_result_null(ctx);
            return;
        }
    }
    if (!st || !st->ctx) {
        sqlite3_result_error(ctx, "fractalsql: extension not initialized", -1);
        return;
    }
    const char *table = (const char *)sqlite3_value_text(argv[0]);
    const char *col   = (const char *)sqlite3_value_text(argv[1]);
    if (!table || !col) { sqlite3_result_error_nomem(ctx); return; }
    if (!agents_ident_ok(table) || !agents_ident_ok(col)) {
        sqlite3_result_error(ctx,
            "fractalsql: table_name and vector_col must be plain "
            "identifiers ([A-Za-z_][A-Za-z0-9_]*)", -1);
        return;
    }
    int k = sqlite3_value_int(argv[4]);
    if (k <= 0) {
        sqlite3_result_error(ctx, "fractalsql: k must be > 0", -1);
        return;
    }

    /* doc_ids arrives as a JSON/CSV array of integers as TEXT, parsed
     * with the shared numeric-series parser. */
    double *raw = (double *)malloc(
        (size_t)FSQL_ARENA_MAX_DIM * sizeof(double));
    if (!raw) { sqlite3_result_error_nomem(ctx); return; }
    int n_cohort = fsql_parse_value_to_doubles(argv[3], raw,
                                               FSQL_ARENA_MAX_DIM);
    if (n_cohort <= 0) {
        free(raw);
        sqlite3_result_error(ctx,
            "fractalsql: doc_ids must be a non-empty JSON/CSV array of "
            "doc ids", -1);
        return;
    }
    int64_t *cohort = (int64_t *)malloc((size_t)n_cohort * sizeof(int64_t));
    if (!cohort) {
        free(raw);
        sqlite3_result_error_nomem(ctx);
        return;
    }
    for (int i = 0; i < n_cohort; i++) cohort[i] = (int64_t)raw[i];
    free(raw);
    /* agents_i64_sorted_contains binary-searches this array; the input
     * arrives in whatever order the caller wrote it, so sort it here. */
    qsort(cohort, (size_t)n_cohort, sizeof(int64_t), agents_i64_cmp);

    int dim = 0;
    double *query = agents_decode_query_doubles(argv[2], &dim);
    if (!query) {
        free(cohort);
        sqlite3_result_error(ctx,
            "fractalsql: invalid query vector (expect CSV/JSON text or "
            "canonical float32 BLOB)", -1);
        return;
    }
    agents_telemetry_run(ctx, table, col, query, dim, cohort, n_cohort, k);
    free(query);
    free(cohort);
}

/* STRICT: NULL in, NULL out. */
static void fractal_cross_modal_search_fn(sqlite3_context *ctx, int argc,
                                          sqlite3_value **argv) {
    (void)argc;
    FsqlState *st = (FsqlState *)sqlite3_user_data(ctx);

    for (int i = 0; i < 6; i++) {
        if (sqlite3_value_type(argv[i]) == SQLITE_NULL) {
            sqlite3_result_null(ctx);
            return;
        }
    }
    if (!st || !st->ctx) {
        sqlite3_result_error(ctx, "fractalsql: extension not initialized", -1);
        return;
    }
    const char *table = (const char *)sqlite3_value_text(argv[0]);
    const char *col   = (const char *)sqlite3_value_text(argv[1]);
    if (!table || !col) { sqlite3_result_error_nomem(ctx); return; }
    if (!agents_ident_ok(table) || !agents_ident_ok(col)) {
        sqlite3_result_error(ctx,
            "fractalsql: table_name and vector_col must be plain "
            "identifiers ([A-Za-z_][A-Za-z0-9_]*)", -1);
        return;
    }
    int k = sqlite3_value_int(argv[5]);
    if (k <= 0) {
        sqlite3_result_error(ctx, "fractalsql: k must be > 0", -1);
        return;
    }
    double alpha = sqlite3_value_double(argv[4]);
    if (isnan(alpha) || alpha < 0.0 || alpha > 1.0) {
        sqlite3_result_error(ctx,
            "fractalsql: alpha_weight must be in [0,1]", -1);
        return;
    }

    /* Weighted concatenation in double precision (the CSV/JSON-text
     * form's math; the canonical-BLOB form does the same in float32).
     * The corpus is stored in the same combined shape upstream. */
    float *mo = NULL, *cl = NULL;
    int mo_dim = 0, cl_dim = 0;
    if (fsql_vec_decode(argv[2], &mo, &mo_dim) != 0 ||
        fsql_vec_decode(argv[3], &cl, &cl_dim) != 0) {
        free(mo); free(cl);
        sqlite3_result_error(ctx,
            "fractalsql: malformed modality vector (expect CSV/JSON text "
            "or canonical float32 BLOB)", -1);
        return;
    }
    int dim = mo_dim + cl_dim;
    double *query = (double *)malloc((size_t)dim * sizeof(double));
    if (!query) {
        free(mo); free(cl);
        sqlite3_result_error_nomem(ctx);
        return;
    }
    for (int i = 0; i < mo_dim; i++) query[i] = (double)mo[i] * alpha;
    for (int i = 0; i < cl_dim; i++)
        query[mo_dim + i] = (double)cl[i] * (1.0 - alpha);
    free(mo); free(cl);

    agents_telemetry_run(ctx, table, col, query, dim, NULL, 0, k);
    free(query);
}

/* ------------------------------------------------------------------ */
/* fractal_search_trajectory(table_name, vector_col, baseline_vector,
 *                           current_vector, k)                       */
/* ------------------------------------------------------------------ */

/* One 5-arg SQLite registration: fsql_vec_decode accepts both the
 * CSV/JSON-text form and the canonical BLOB form. Arithmetic differs
 * by form: a canonical-BLOB pair subtracts in core's float32
 * fsql_vector_sub and widens to double ONCE at this boundary; anything
 * else (CSV/JSON text) subtracts in double. The delta vector (current
 * - baseline) is what actually gets searched — "what has changed"
 * rather than "where am I", the natural query shape for
 * drift/trajectory monitoring. Output shape and doc_id convention
 * match fractal_search_telemetry (no cohort filter). STRICT: NULL in,
 * NULL out. */
static void fractal_search_trajectory_fn(sqlite3_context *ctx, int argc,
                                         sqlite3_value **argv) {
    (void)argc;
    FsqlState *st = (FsqlState *)sqlite3_user_data(ctx);

    for (int i = 0; i < 5; i++) {
        if (sqlite3_value_type(argv[i]) == SQLITE_NULL) {
            sqlite3_result_null(ctx);
            return;
        }
    }
    if (!st || !st->ctx) {
        sqlite3_result_error(ctx, "fractalsql: extension not initialized", -1);
        return;
    }
    const char *table = (const char *)sqlite3_value_text(argv[0]);
    const char *col   = (const char *)sqlite3_value_text(argv[1]);
    if (!table || !col) { sqlite3_result_error_nomem(ctx); return; }
    if (!agents_ident_ok(table) || !agents_ident_ok(col)) {
        sqlite3_result_error(ctx,
            "fractalsql: table_name and vector_col must be plain "
            "identifiers ([A-Za-z_][A-Za-z0-9_]*)", -1);
        return;
    }
    int k = sqlite3_value_int(argv[4]);
    if (k <= 0) {
        sqlite3_result_error(ctx, "fractalsql: k must be > 0", -1);
        return;
    }

    float *base_f = NULL, *cur_f = NULL;
    int base_dim = 0, cur_dim = 0;
    if (fsql_vec_decode(argv[2], &base_f, &base_dim) != 0 ||
        fsql_vec_decode(argv[3], &cur_f, &cur_dim) != 0) {
        free(base_f); free(cur_f);
        sqlite3_result_error(ctx,
            "fractalsql: malformed vector (expect CSV/JSON text or "
            "canonical float32 BLOB)", -1);
        return;
    }
    if (base_dim != cur_dim) {
        char buf[128];
        snprintf(buf, sizeof buf,
                 "fractalsql: baseline_vector dim (%d) must match "
                 "current_vector dim (%d)", base_dim, cur_dim);
        free(base_f); free(cur_f);
        sqlite3_result_error(ctx, buf, -1);
        return;
    }
    if (base_dim < 1) {
        free(base_f); free(cur_f);
        sqlite3_result_error(ctx, "fractalsql: empty vector", -1);
        return;
    }

    double *delta = (double *)malloc((size_t)base_dim * sizeof(double));
    if (!delta) {
        free(base_f); free(cur_f);
        sqlite3_result_error_nomem(ctx);
        return;
    }
    if (sqlite3_value_type(argv[2]) == SQLITE_BLOB &&
        sqlite3_value_type(argv[3]) == SQLITE_BLOB) {
        /* The fractal_vector path: float32 subtract in core, widen to
         * double once at the boundary. */
        float *delta_f = (float *)malloc((size_t)base_dim * sizeof(float));
        if (!delta_f) {
            free(base_f); free(cur_f); free(delta);
            sqlite3_result_error_nomem(ctx);
            return;
        }
        int rc = fsql_vector_sub(cur_f, base_f, (size_t)base_dim, delta_f);
        if (rc != FSQL_OK) {
            free(base_f); free(cur_f); free(delta); free(delta_f);
            sqlite3_result_error(ctx,
                "fractalsql: vector op failed", -1);
            return;
        }
        for (int i = 0; i < base_dim; i++) delta[i] = (double)delta_f[i];
        free(delta_f);
    } else {
        /* The float8[] path: full double math. */
        for (int i = 0; i < base_dim; i++)
            delta[i] = (double)cur_f[i] - (double)base_f[i];
    }
    free(base_f);
    free(cur_f);

    agents_telemetry_run(ctx, table, col, delta, base_dim, NULL, 0, k);
    free(delta);
}

/* ------------------------------------------------------------------ */
/* fractal_explain_result() / fractal_detect_collapse()                */
/* ------------------------------------------------------------------ */

/* The Diversify inspector snapshot, read through the core ABI
 * getters. */
static void fractal_explain_result_fn(sqlite3_context *ctx, int argc,
                                      sqlite3_value **argv) {
    (void)argc; (void)argv;
    FsqlState *st = (FsqlState *)sqlite3_user_data(ctx);
    if (!st || !st->ctx) {
        sqlite3_result_error(ctx, "fractalsql: extension not initialized", -1);
        return;
    }

    double dq  = fsql_diversify_current_dq(st->ctx);
    double p99 = fsql_diversify_overhead_p99_us(st->ctx);
    fsql_diversify_params_t dp;
    int enabled = (fsql_diversify_get_params(st->ctx, &dp) == FSQL_OK);

    char dq_s[32], p99_s[32];
    if (isnan(dq))  strcpy(dq_s, "null");
    else            snprintf(dq_s, sizeof dq_s, "%.6f", dq);
    if (isnan(p99)) strcpy(p99_s, "null");
    else            snprintf(p99_s, sizeof p99_s, "%.6f", p99);

    char buf[160];
    snprintf(buf, sizeof buf,
             "{\"dq\":%s,\"diversify_enabled\":%s,\"overhead_p99_us\":%s}",
             dq_s, enabled ? "true" : "false", p99_s);
    sqlite3_result_text(ctx, buf, -1, SQLITE_TRANSIENT);
}

/* The current D_q, NaN when diversify is off or no query has run
 * yet. */
static void fractal_detect_collapse_fn(sqlite3_context *ctx, int argc,
                                       sqlite3_value **argv) {
    (void)argc; (void)argv;
    FsqlState *st = (FsqlState *)sqlite3_user_data(ctx);
    if (!st || !st->ctx) {
        sqlite3_result_error(ctx, "fractalsql: extension not initialized", -1);
        return;
    }
    sqlite3_result_double(ctx, fsql_diversify_current_dq(st->ctx));
}

/* ------------------------------------------------------------------ */
/* Named feature store                                                 */
/*                                                                    */
/* fractal_store_morphology / fractal_mine_topology_negatives: a      */
/* generic per-doc_id vector store, backed by a plain table rather    */
/* than a core primitive (the ledger API is whole-ledger admin + two  */
/* counters, no per-item put/get). Lazily creates                     */
/* fractalsql_feature_store on first use.                             */
/* ------------------------------------------------------------------ */

static const char FSQL_FEATURE_STORE_DDL[] =
    "CREATE TABLE IF NOT EXISTS fractalsql_feature_store("
    "doc_id INTEGER PRIMARY KEY,"
    "features BLOB NOT NULL,"
    "updated_at TEXT NOT NULL DEFAULT (datetime('now')))";

static int feature_store_ensure(sqlite3 *db, char *err, size_t err_cap) {
    char *emsg = NULL;
    int rc = sqlite3_exec(db, FSQL_FEATURE_STORE_DDL, NULL, NULL, &emsg);
    if (rc != SQLITE_OK) {
        agents_set_err(err, err_cap,
                       "fractalsql: cannot create fractalsql_feature_store: %s",
                       emsg ? emsg : sqlite3_errmsg(db));
        sqlite3_free(emsg);
        return -1;
    }
    sqlite3_free(emsg);
    return 0;
}

/* STRICT: NULL in, NULL out. Upserts feature_array (stored as a
 * canonical fractal_vector BLOB) against doc_id, last-writer-wins. */
static void fractal_store_morphology_fn(sqlite3_context *ctx, int argc,
                                        sqlite3_value **argv) {
    (void)argc;
    FsqlState *st = (FsqlState *)sqlite3_user_data(ctx);
    if (sqlite3_value_type(argv[0]) == SQLITE_NULL ||
        sqlite3_value_type(argv[1]) == SQLITE_NULL) {
        sqlite3_result_null(ctx);
        return;
    }
    if (!st || !st->db) {
        sqlite3_result_error(ctx, "fractalsql: extension not initialized", -1);
        return;
    }
    int64_t doc_id = sqlite3_value_int64(argv[0]);
    if (doc_id < 0) {
        sqlite3_result_error(ctx, "fractalsql: doc_id must be >= 0", -1);
        return;
    }
    float *data = NULL;
    int    dim  = 0;
    if (fsql_vec_decode(argv[1], &data, &dim) != 0 ||
        !agents_dim_in_arena(dim)) {
        free(data);
        sqlite3_result_error(ctx,
            "fractalsql: invalid feature_array (expect CSV/JSON text or "
            "canonical float32 BLOB)", -1);
        return;
    }

    char err[256];
    if (feature_store_ensure(st->db, err, sizeof err) != 0) {
        free(data);
        agents_result_err(ctx, err);
        return;
    }

    int      nbytes = FSQL_VEC_HDRSZ + dim * 4;
    uint8_t *blob   = (uint8_t *)malloc((size_t)nbytes);
    if (!blob) {
        free(data);
        sqlite3_result_error_nomem(ctx);
        return;
    }
    blob[0] = (uint8_t)(dim & 0xff);
    blob[1] = (uint8_t)((dim >> 8) & 0xff);
    blob[2] = 0;
    blob[3] = 0;
    memcpy(blob + FSQL_VEC_HDRSZ, data, (size_t)dim * 4);
    free(data);

    static const char SQL[] =
        "INSERT INTO fractalsql_feature_store(doc_id, features, updated_at) "
        "VALUES(?1, ?2, datetime('now')) "
        "ON CONFLICT(doc_id) DO UPDATE SET "
        "features = excluded.features, updated_at = excluded.updated_at";
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(st->db, SQL, -1, &stmt, NULL) != SQLITE_OK) {
        free(blob);
        sqlite3_result_error(ctx, sqlite3_errmsg(st->db), -1);
        return;
    }
    sqlite3_bind_int64(stmt, 1, doc_id);
    sqlite3_bind_blob(stmt, 2, blob, nbytes, SQLITE_TRANSIENT);
    int rc = sqlite3_step(stmt);
    free(blob);
    if (rc != SQLITE_DONE) {
        sqlite3_result_error(ctx, sqlite3_errmsg(st->db), -1);
        sqlite3_finalize(stmt);
        return;
    }
    sqlite3_finalize(stmt);
    sqlite3_result_text(ctx, "ok", -1, SQLITE_STATIC);
}

typedef struct { int64_t doc_id; double dist; } fsql_topo_cand_t;

static int topo_cand_cmp(const void *a, const void *b) {
    double da = ((const fsql_topo_cand_t *)a)->dist;
    double db = ((const fsql_topo_cand_t *)b)->dist;
    if (da < db) return -1;
    if (da > db) return 1;
    return 0;
}

/* STRICT: NULL in, NULL out. Brute-force k-NN (true Euclidean
 * distance, ascending) over fractalsql_feature_store. A stored row
 * whose vector dimension doesn't match surrogate_vector's is skipped
 * rather than aborting the whole scan. */
static void fractal_mine_topology_negatives_fn(sqlite3_context *ctx, int argc,
                                               sqlite3_value **argv) {
    (void)argc;
    FsqlState *st = (FsqlState *)sqlite3_user_data(ctx);
    if (sqlite3_value_type(argv[0]) == SQLITE_NULL ||
        sqlite3_value_type(argv[1]) == SQLITE_NULL) {
        sqlite3_result_null(ctx);
        return;
    }
    if (!st || !st->db) {
        sqlite3_result_error(ctx, "fractalsql: extension not initialized", -1);
        return;
    }
    int k = sqlite3_value_int(argv[1]);
    if (k <= 0) {
        sqlite3_result_error(ctx, "fractalsql: k must be > 0", -1);
        return;
    }
    int     dim       = 0;
    double *surrogate = agents_decode_query_doubles(argv[0], &dim);
    if (!surrogate) {
        sqlite3_result_error(ctx,
            "fractalsql: invalid surrogate_vector (expect CSV/JSON text or "
            "canonical float32 BLOB)", -1);
        return;
    }

    char err[256];
    if (feature_store_ensure(st->db, err, sizeof err) != 0) {
        free(surrogate);
        agents_result_err(ctx, err);
        return;
    }

    static const char SQL[] =
        "SELECT doc_id, features FROM fractalsql_feature_store";
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(st->db, SQL, -1, &stmt, NULL) != SQLITE_OK) {
        free(surrogate);
        sqlite3_result_error(ctx, sqlite3_errmsg(st->db), -1);
        return;
    }

    fsql_topo_cand_t *cands = NULL;
    size_t cap = 0, kept = 0;
    int    step_rc;
    while ((step_rc = sqlite3_step(stmt)) == SQLITE_ROW) {
        int64_t row_doc_id = sqlite3_column_int64(stmt, 0);
        float  *rv   = NULL;
        int     rdim = 0;
        if (fsql_vec_decode(sqlite3_column_value(stmt, 1), &rv, &rdim) != 0)
            continue;
        if (rdim != dim) { free(rv); continue; }

        double sumsq = 0.0;
        for (int j = 0; j < dim; j++) {
            double diff = (double)rv[j] - surrogate[j];
            sumsq += diff * diff;
        }
        free(rv);

        if (kept == cap) {
            size_t newcap = cap ? cap * 2 : 16;
            fsql_topo_cand_t *tmp =
                (fsql_topo_cand_t *)realloc(cands, newcap * sizeof *cands);
            if (!tmp) {
                free(cands);
                free(surrogate);
                sqlite3_finalize(stmt);
                sqlite3_result_error_nomem(ctx);
                return;
            }
            cands = tmp;
            cap   = newcap;
        }
        cands[kept].doc_id = row_doc_id;
        cands[kept].dist   = sqrt(sumsq);
        kept++;
    }
    free(surrogate);
    if (step_rc != SQLITE_DONE) {
        free(cands);
        sqlite3_result_error(ctx, sqlite3_errmsg(st->db), -1);
        sqlite3_finalize(stmt);
        return;
    }
    sqlite3_finalize(stmt);

    if (kept > 1) qsort(cands, kept, sizeof *cands, topo_cand_cmp);

    size_t out_n = kept < (size_t)k ? kept : (size_t)k;
    StrBuf out;
    sb_init(&out);
    sb_puts(&out, "[");
    for (size_t i = 0; i < out_n; i++) {
        if (i) sb_puts(&out, ",");
        sb_printf(&out, "{\"doc_id\":%lld,\"distance\":%.17g}",
                  (long long)cands[i].doc_id, cands[i].dist);
    }
    sb_puts(&out, "]");
    free(cands);
    if (sb_failed(&out)) {
        sb_free(&out);
        sqlite3_result_error_nomem(ctx);
        return;
    }
    sqlite3_result_text(ctx, out.buf, (int)out.len, SQLITE_TRANSIENT);
    sb_free(&out);
}

/* ------------------------------------------------------------------ */
/* Registration                                                        */
/* ------------------------------------------------------------------ */

/* All INNOCUOUS, none DETERMINISTIC: the agent tier touches LLMs,
 * stochastic SFS, and per-session Diversify state (see the header
 * comment). user_data is the shared per-connection state; xDestroy is
 * NULL everywhere — the entry TU's fractal_search registration owns
 * fsql_state_destroy. */
int fsql_agents_register(sqlite3 *db, FsqlState *st) {
    static const int flags = SQLITE_UTF8 | SQLITE_INNOCUOUS;

    struct {
        const char *name;
        int         narg;
        void (*fn)(sqlite3_context *, int, sqlite3_value **);
    } fns[] = {
        { "fractal_reason",                   -1, fractal_reason_fn                 },
        { "fractal_search_debug",             -1, fractal_search_debug_fn           },
        { "fractal_search_agent",             -1, fractal_search_agent_fn           },
        { "fractal_sql_agent",                -1, fractal_sql_agent_fn              },
        { "fractal_rag_agent",                -1, fractal_rag_agent_fn              },
        { "fractal_agent_plan_explore",        4, fractal_plan_explore_fn           },
        { "fractal_agent_trajectory_predict",  4, fractal_trajectory_predict_fn     },
        { "fractal_agent_detect_loop",         1, fractal_detect_loop_fn            },
        { "fractal_search_telemetry",          4, fractal_search_telemetry_fn       },
        { "fractal_search_trajectory",         5, fractal_search_trajectory_fn      },
        { "fractal_hybrid_clinical_search",    5, fractal_hybrid_clinical_search_fn },
        { "fractal_cross_modal_search",        6, fractal_cross_modal_search_fn     },
        { "fractal_explain_result",            0, fractal_explain_result_fn         },
        { "fractal_detect_collapse",           0, fractal_detect_collapse_fn        },
        { "fractal_store_morphology",          2, fractal_store_morphology_fn       },
        { "fractal_mine_topology_negatives",   2, fractal_mine_topology_negatives_fn},
    };

    for (size_t i = 0; i < sizeof(fns) / sizeof(fns[0]); i++) {
        int rc = sqlite3_create_function_v2(
            db, fns[i].name, fns[i].narg, flags, st, fns[i].fn,
            NULL, NULL, NULL);
        if (rc != SQLITE_OK) return rc;
    }
    return SQLITE_OK;
}