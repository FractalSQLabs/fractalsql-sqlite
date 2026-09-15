/* src/fsql_vectorizer.c: background vectorizer: registry + queue +
 * per-table enqueue triggers + claim loop, and the fractal_embed()
 * embedding entry point.
 *
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * Implements the Vectorizer section (fractal_vectorizers,
 * fractal_vectorizer_queue, fractal_vectorizer_rate_window, the
 * enqueue trigger, and the fractal_vectorizer_create/pause/resume/
 * drop/process_queue functions) plus the C-level fractal_embed()
 * entry point. Configuration reaches the reasoning plugin as
 * FSQL_REASONING_HTTP_* environment variables through
 * fsql_reasoning_generate()'s tier mechanism (here the
 * FSQL_REASONING_TIER_EMBED env block), never through the per-call
 * context JSON, which the plugin embeds into the prompt as data.
 *
 * Design notes:
 *
 *   - Registry/queue/rate-window state lives in TEMP tables/triggers/
 *     view created lazily on first vectorizer call. TEMP objects live
 *     in the connection-private `temp` namespace, so they neither
 *     pollute the user's schema nor leak between connections. Since a
 *     TEMP table is visible to exactly one connection, the claim
 *     transaction's BEGIN IMMEDIATE + busy_timeout is belt-and-braces
 *     rather than a correctness requirement.
 *   - Timestamps are stored as epoch-second INTEGERs
 *     (CAST(strftime('%s','now') AS INTEGER)); stale_after is a plain
 *     seconds INTEGER.
 *   - The enqueue trigger fires on every UPDATE: SQLite parses trigger
 *     UPDATE OF but ignores it.
 *   - The enqueue trigger dedupes with NOT EXISTS instead of an
 *     upsert against the partial unique index: upsert-inside-trigger
 *     support is version-sensitive in SQLite, and the two forms are
 *     semantically identical over these private tables. The backfill
 *     insert keeps the ON CONFLICT form against that index.
 *   - A permanently bad row is marked 'failed' and retrying stops (no
 *     attempts column, no retry cap, no other 'error' status).
 *   - fractal_embed() returns the canonical fractal_vector BLOB (see
 *     fsql_vector.h), since SQLite has no array type, and the BLOB
 *     convention is this extension's vector representation everywhere
 *     else.
 *   - The embed endpoint/model reach the plugin as
 *     FSQL_REASONING_HTTP_* environment variables via
 *     fsql_reasoning_generate()'s FSQL_REASONING_TIER_EMBED tier
 *     (fsql_reasoning.c applies the embed env block before the
 *     plugin's init, with no per-call context keys, which the plugin
 *     would only embed into the prompt as data).
 * Identifier safety: every piece of caller-supplied text that reaches
 * a string-built SQL statement is validated (alnum + underscore +
 * internal dots per segment, no leading digit) and double-quoted
 * before interpolation; everything else is bound parameters. Scratch
 * buffers are freed on all paths. Pure C11, no VLAs.
 */

#include <sqlite3ext.h>
SQLITE_EXTENSION_INIT3

#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fsql_sqlite_internal.h"
#include "fractalsql_parse.h"

/* ------------------------------------------------------------------ */
/* Constants                                                           */
/* ------------------------------------------------------------------ */

/* DoS bound for fsql_parse_embedding_array()'s cap: generous headroom
 * above any real embedding model, small enough to bound a buggy
 * plugin response. Also comfortably below FSQL_VEC_MAX_DIM, so the
 * canonical BLOB encoding below cannot overflow the u16 dim field. */
#define FSQLV_MAX_EMBED_DIM      16384

#define FSQLV_DEFAULT_BATCH      100
#define FSQLV_MAX_BATCH          100000
#define FSQLV_DEFAULT_STALE_SECS 600     /* 10 minutes                 */
#define FSQLV_CLAIM_BUSY_MS      5000    /* BEGIN IMMEDIATE wait       */

/* Bound on one row's error text copied into the queue. */
#define FSQLV_ERR_MAX            512

/* Scratch buffer for dynamically-built DDL/DML. Worst case: four
 * quoted identifiers (~66 chars each after validation) plus fixed
 * text — 2048 is comfortable. snprintf return values are checked so a
 * surprise truncation fails loudly instead of shipping truncated SQL. */
#define FSQLV_SQL_MAX            2048

/* ------------------------------------------------------------------ */
/* Error helper                                                        */
/* ------------------------------------------------------------------ */

/* err may be NULL; truncation is fine — messages are diagnostics. */
static void fsqlv_set_err(char *err, size_t err_cap,
                          const char *fmt, ...) {
    if (!err || err_cap == 0) return;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(err, err_cap, fmt, ap);
    va_end(ap);
}

/* sqlite3_exec wrapper that funnels the engine's message into the
 * caller's error buffer. */
static int fsqlv_exec(sqlite3 *db, const char *sql,
                      char *err, size_t err_cap) {
    char *msg = NULL;
    int rc = sqlite3_exec(db, sql, NULL, NULL, &msg);
    if (rc != SQLITE_OK) {
        fsqlv_set_err(err, err_cap, "%s (%s)",
                      msg ? msg : sqlite3_errmsg(db), sql);
    }
    sqlite3_free(msg);
    return rc;
}

/* ------------------------------------------------------------------ */
/* Identifier validation + quoting                                     */
/* ------------------------------------------------------------------ */

/* Accept [A-Za-z_][A-Za-z0-9_]* segments joined by '.' — schema-
 * qualified table names allowed, everything else rejected. `dots`
 * permits the internal dot (table names); column identifiers pass 0.
 * This is the ONLY gate between caller text and string-built SQL:
 * anything reaching interpolation below has been through here and is
 * then double-quoted, so no character that could escape the quoting
 * exists in the first place. */
static int fsqlv_ident_ok(const char *s, int dots) {
    if (!s || !*s) return 0;
    size_t total = 0;
    int seg_len = 0, nseg = 1;
    for (const char *p = s; *p; p++) {
        if (*p == '.') {
            if (dots <= 0 || seg_len == 0) return 0;
            nseg++;
            if (nseg > 3) return 0;      /* [catalog.]schema.table max */
            seg_len = 0;
            continue;
        }
        if (seg_len == 0) {
            if (*p != '_' && !((*p >= 'a' && *p <= 'z') ||
                               (*p >= 'A' && *p <= 'Z'))) return 0;
        } else {
            if (*p != '_' &&
                !((*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z') ||
                  (*p >= '0' && *p <= '9'))) return 0;
        }
        seg_len++;
        total++;
        if (seg_len > 63 || total > 256) return 0;   /* NAMEDATALEN-ish */
    }
    return seg_len > 0;
}

/* Append `"seg"` (validation already forbids quotes; the quoting keeps
 * even a future validator change safe). Returns the number of bytes
 * written, 0 on truncation. */
static size_t fsqlv_qseg(char *out, size_t cap, const char *seg) {
    size_t n = (size_t)snprintf(out, cap, "\"%s\"", seg);
    return (n < cap) ? n : 0;
}

/* Quote a validated dotted identifier into out ("a"."b"). Returns 0 on
 * success, -1 if it does not validate or does not fit. */
static int fsqlv_quote_ident(char *out, size_t cap, const char *ident,
                             int dots) {
    if (!fsqlv_ident_ok(ident, dots)) return -1;
    size_t used = 0;
    const char *p = ident;
    while (*p) {
        char seg[80];
        size_t seglen = 0;
        while (p[seglen] && p[seglen] != '.') seglen++;
        size_t n = fsqlv_qseg(seg, sizeof seg, p);  /* seg <= 63 chars */
        if (n == 0) return -1;
        if (used + n + 2 >= cap) return -1;
        if (used > 0) out[used++] = '.';
        memcpy(out + used, seg, n);
        used += n;
        out[used] = '\0';
        p += seglen;
        if (*p == '.') p++;
    }
    return (used > 0) ? 0 : -1;
}

/* ------------------------------------------------------------------ */
/* Lazy schema (TEMP namespace, created on first vectorizer call)      */
/* ------------------------------------------------------------------ */

/* DDL for fractal_vectorizers / fractal_vectorizer_queue /
 * fractal_vectorizer_rate_window and the two queue indexes. The FK
 * to the vectorizer id is application-enforced as a cascade in
 * fractal_vectorizer_drop() (a TEMP table cannot reference a
 * main-schema table anyway). */
static const char *FSQLV_SCHEMA_SQL =
    "CREATE TEMP TABLE IF NOT EXISTS fractal_vectorizers ("
    "  id             INTEGER PRIMARY KEY,"
    "  source_table   TEXT NOT NULL,"
    "  source_pk_col  TEXT NOT NULL,"
    "  text_col       TEXT NOT NULL,"
    "  embedding_col  TEXT NOT NULL,"
    "  options        TEXT NOT NULL DEFAULT '{}',"
    "  enabled        INTEGER NOT NULL DEFAULT 1,"
    "  created_at     INTEGER NOT NULL DEFAULT "
    "                 (CAST(strftime('%s','now') AS INTEGER)),"
    "  UNIQUE (source_table, text_col, embedding_col)"
    ");"
    "CREATE TEMP TABLE IF NOT EXISTS fractal_vectorizer_queue ("
    "  id                    INTEGER PRIMARY KEY,"
    "  vectorizer_id         INTEGER NOT NULL,"
    "  source_pk_value       TEXT NOT NULL,"
    "  status                TEXT NOT NULL DEFAULT 'pending'"
    "                        CHECK (status IN "
    "                               ('pending','processing','done','failed')),"
    "  error                 TEXT,"
    "  created_at            INTEGER NOT NULL DEFAULT "
    "                        (CAST(strftime('%s','now') AS INTEGER)),"
    "  processing_started_at INTEGER,"
    "  updated_at            INTEGER NOT NULL DEFAULT "
    "                        (CAST(strftime('%s','now') AS INTEGER))"
    ");"
    "CREATE UNIQUE INDEX IF NOT EXISTS "
    "  temp.fractal_vectorizer_queue_pending_uniq"
    "  ON fractal_vectorizer_queue (vectorizer_id, source_pk_value)"
    "  WHERE status IN ('pending','processing');"
    "CREATE INDEX IF NOT EXISTS "
    "  temp.fractal_vectorizer_queue_pending_scan"
    "  ON fractal_vectorizer_queue (created_at) WHERE status = 'pending';"
    "CREATE TEMP TABLE IF NOT EXISTS fractal_vectorizer_rate_window ("
    "  vectorizer_id  INTEGER PRIMARY KEY,"
    "  window_start   INTEGER NOT NULL DEFAULT "
    "                 (CAST(strftime('%s','now') AS INTEGER)),"
    "  window_calls   INTEGER NOT NULL DEFAULT 0"
    ");"
    /* fractal_vectorizer_status view, written for stock SQLite:
     * last_failure_at via CASE-in-MAX, last_error via an ordered
     * scalar subquery. */
    "CREATE TEMP VIEW IF NOT EXISTS fractal_vectorizer_status AS "
    "SELECT v.id AS vectorizer_id, v.source_table, v.text_col, "
    "       v.embedding_col, v.enabled, q.status, COUNT(*) AS n, "
    "       MAX(CASE WHEN q.status='failed' THEN q.updated_at END) "
    "           AS last_failure_at, "
    "       (SELECT q2.error FROM fractal_vectorizer_queue q2 "
    "         WHERE q2.vectorizer_id = v.id AND q2.status = 'failed' "
    "         ORDER BY q2.updated_at DESC LIMIT 1) AS last_error "
    "FROM fractal_vectorizers v "
    "JOIN fractal_vectorizer_queue q ON q.vectorizer_id = v.id "
    "GROUP BY v.id, v.source_table, v.text_col, v.embedding_col, "
    "         v.enabled, q.status;";

static int fsqlv_ensure_schema(FsqlState *st, char *err, size_t err_cap) {
    return fsqlv_exec(st->db, FSQLV_SCHEMA_SQL, err, err_cap);
}

/* ------------------------------------------------------------------ */
/* Embedding core (fractal_embed + the queue's per-row embed)          */
/* ------------------------------------------------------------------ */

/* One embedding call: validate the tier config, dispatch through the
 * reasoning plugin, parse the JSON float-array response, and encode it
 * as the canonical fractal_vector BLOB (u16 dim LE + u16 reserved +
 * float32 payload — see fsql_vector.h). On success returns 0 and sets
 * *out_blob to a sqlite3_malloc'd buffer the caller releases with
 * sqlite3_free(); on failure returns -1 with a message in `err` and
 * leaves *out_blob NULL. */
static int fsqlv_embed(FsqlState *st, const char *text,
                       unsigned char **out_blob, int *out_bytes,
                       char *err, size_t err_cap) {
    *out_blob = NULL;
    *out_bytes = 0;

    /* Config is per-connection SQL state, so the hint below names
     * fractalsql_set(). */
    if (!st->cfg.reasoning_plugin || !*st->cfg.reasoning_plugin) {
        fsqlv_set_err(err, err_cap,
                      "fractalsql: reasoning plugin not configured (set "
                      "fractalsql_set('reasoning_plugin', '/absolute/path'))");
        return -1;
    }
    /* No fallback to the chat http_url — a chat model is not a
     * substitute for a purpose-trained embedding model, and the two
     * live on different endpoint paths even on the same provider. */
    if (!st->cfg.http_embed_url || !*st->cfg.http_embed_url) {
        fsqlv_set_err(err, err_cap,
                      "fractal_embed: http_embed_url is not configured (set "
                      "fractalsql_set('http_embed_url', "
                      "'https://.../v1/embeddings'))");
        return -1;
    }

    /* Dispatch context is empty: embed configuration (endpoint, model,
     * embedding mode, token) reaches the plugin through the
     * FSQL_REASONING_TIER_EMBED tier's env block in fsql_reasoning.c
     * — the plugin embeds per-call context into the prompt as data, so
     * it must never carry config keys. */
    char *resp = NULL;
    int rc = fsql_reasoning_generate(st, FSQL_REASONING_TIER_EMBED,
                                     text, "{}", &resp, err, err_cap);
    if (rc != 0) return -1;

    double *vals = (double *)malloc(FSQLV_MAX_EMBED_DIM * sizeof(double));
    if (!vals) {
        free(resp);
        fsqlv_set_err(err, err_cap,
                      "fractalsql: out of memory parsing embedding response");
        return -1;
    }

    int n = fsql_parse_embedding_array(resp, vals, FSQLV_MAX_EMBED_DIM);
    if (n < 1) {
        fsqlv_set_err(err, err_cap,
                      "fractal_embed: could not parse embedding response "
                      "(raw: %.200s)",
                      (resp && *resp) ? resp : "(empty)");
        free(resp);
        free(vals);
        return -1;
    }
    free(resp);

    int nbytes = FSQL_VEC_HDRSZ + n * 4;
    unsigned char *blob = (unsigned char *)sqlite3_malloc(nbytes);
    if (!blob) {
        free(vals);
        fsqlv_set_err(err, err_cap, "fractalsql: out of memory");
        return -1;
    }
    blob[0] = (unsigned char)(n & 0xff);
    blob[1] = (unsigned char)((n >> 8) & 0xff);
    blob[2] = 0;
    blob[3] = 0;
    for (int i = 0; i < n; i++) {
        float f = (float)vals[i];
        memcpy(blob + FSQL_VEC_HDRSZ + (size_t)i * 4, &f, 4);
    }
    free(vals);

    *out_blob = blob;
    *out_bytes = nbytes;
    return 0;
}

/* fractal_embed(input TEXT) -> canonical fractal_vector BLOB. */
static void fsqlv_embed_fn(sqlite3_context *ctx, int argc,
                           sqlite3_value **argv) {
    (void)argc;
    FsqlState *st = (FsqlState *)sqlite3_user_data(ctx);

    if (sqlite3_value_type(argv[0]) == SQLITE_NULL) {
        sqlite3_result_error(ctx, "fractal_embed: input must not be NULL",
                             -1);
        return;
    }
    const char *text = (const char *)sqlite3_value_text(argv[0]);
    if (!text) text = "";

    /* Same input-side bound the t2s tier enforces (FSQL_MAX_INPUT_BYTES):
     * the reasoning layer caps the RESPONSE, not the query, and an
     * uncapped embed streams arbitrarily large payloads at the
     * configured endpoint. */
    if (strlen(text) > FSQL_MAX_INPUT_BYTES) {
        sqlite3_result_error(ctx,
            "fractal_embed: input exceeds the 4 MiB limit", -1);
        return;
    }

    char err[FSQLV_ERR_MAX];
    err[0] = '\0';
    unsigned char *blob = NULL;
    int nbytes = 0;
    if (fsqlv_embed(st, text, &blob, &nbytes, err, sizeof err) != 0) {
        sqlite3_result_error(ctx, err, -1);
        return;
    }
    sqlite3_result_blob(ctx, blob, nbytes, sqlite3_free);
}

/* ------------------------------------------------------------------ */
/* fractal_vectorizer_create                                           */
/* ------------------------------------------------------------------ */

/* The vectorizer is wired to its source table by TWO temp triggers
 * (AFTER INSERT + AFTER UPDATE OF text_col): SQLite's trigger grammar
 * has no combined insert-or-update event (trigger_event is DELETE |
 * INSERT | UPDATE [OF cols] — there is no OR slot). Both share the
 * same enqueue body; the NOT EXISTS dedupe inside it makes the
 * doubled firings cheap no-ops. The 'u' suffix keeps the names
 * distinct. */
static int fsqlv_drop_triggers(FsqlState *st, sqlite3_int64 vid,
                               char *err, size_t err_cap) {
    char sql[FSQLV_SQL_MAX];
    snprintf(sql, sizeof sql,
             "DROP TRIGGER IF EXISTS \"fractal_vectorizer_trg_%lld\";",
             (long long)vid);
    if (fsqlv_exec(st->db, sql, err, err_cap) != 0) return -1;
    snprintf(sql, sizeof sql,
             "DROP TRIGGER IF EXISTS \"fractal_vectorizer_trg_%lldu\";",
             (long long)vid);
    return fsqlv_exec(st->db, sql, err, err_cap);
}

/* Builds and executes one enqueue trigger (`event` is the full
 * "AFTER ..." header text; `suffix` disambiguates the trigger name). */
static int fsqlv_create_trigger(FsqlState *st, sqlite3_int64 vid,
                                const char *suffix, const char *event,
                                const char *qtbl, const char *qpk,
                                char *err, size_t err_cap) {
    char sql[FSQLV_SQL_MAX];
    int n = snprintf(sql, sizeof sql,
        "CREATE TEMP TRIGGER \"fractal_vectorizer_trg_%lld%s\" "
        "%s ON %s "
        "BEGIN "
        "INSERT INTO fractal_vectorizer_queue (vectorizer_id, source_pk_value) "
        "SELECT %lld, CAST(NEW.%s AS TEXT) "
        "WHERE (SELECT enabled FROM fractal_vectorizers WHERE id=%lld) "
        "AND NOT EXISTS ("
        "  SELECT 1 FROM fractal_vectorizer_queue "
        "  WHERE vectorizer_id=%lld "
        "    AND source_pk_value = CAST(NEW.%s AS TEXT) "
        "    AND status IN ('pending','processing'));"
        "END",
        (long long)vid, suffix, event, qtbl,
        (long long)vid, qpk, (long long)vid, (long long)vid, qpk);
    if (n <= 0 || (size_t)n >= sizeof sql) {
        fsqlv_set_err(err, err_cap,
            "fractalsql: internal error building trigger SQL");
        return -1;
    }
    return fsqlv_exec(st->db, sql, err, err_cap);
}

/* Shared cleanup for mid-flight failures so a failed create never
 * leaves a half-registered vectorizer behind. */
static void fsqlv_create_cleanup(FsqlState *st, sqlite3_int64 vid) {
    fsqlv_drop_triggers(st, vid, NULL, 0);
    char sql[FSQLV_SQL_MAX];
    snprintf(sql, sizeof sql,
             "DELETE FROM fractal_vectorizer_queue WHERE vectorizer_id=%lld;",
             (long long)vid);
    sqlite3_exec(st->db, sql, NULL, NULL, NULL);
    snprintf(sql, sizeof sql,
             "DELETE FROM fractal_vectorizer_rate_window WHERE "
             "vectorizer_id=%lld;", (long long)vid);
    sqlite3_exec(st->db, sql, NULL, NULL, NULL);
    snprintf(sql, sizeof sql,
             "DELETE FROM fractal_vectorizers WHERE id=%lld;",
             (long long)vid);
    sqlite3_exec(st->db, sql, NULL, NULL, NULL);
}

/* Find the source table's single-column PRIMARY KEY via PRAGMA
 * table_info's pk column (1-based position within the PK, 0 = not
 * part of it). Returns 0 on success (pk_col filled), -1 with a
 * message in err for a missing table, composite PK, or no PK:
 * composite and missing-PK tables have no single generic value to
 * key the queue on, and there is no rowid fallback. */
static int fsqlv_find_pk(FsqlState *st, const char *src_ident,
                         char *pk_col, size_t pk_cap,
                         char *err, size_t err_cap) {
    /* PRAGMA's schema prefix and table name are two separate slots;
     * a dotted source_table splits into "schema".table_info("table"). */
    char qtbl[600], sql[768];
    if (fsqlv_quote_ident(qtbl, sizeof qtbl, src_ident, 1) != 0) {
        fsqlv_set_err(err, err_cap, "fractalsql: invalid identifier");
        return -1;
    }

    const char *dot = strrchr(src_ident, '.');
    if (dot) {
        /* Schema-qualified: qtbl is "schema"."table" — take the quoted
         * table (last quoted segment) and prefix the quoted schema. */
        const char *last = strrchr(qtbl, '"');       /* closing quote  */
        const char *first = strrchr(qtbl, '.');      /* before "table" */
        if (!last || !first || first >= last || last - first < 3) {
            fsqlv_set_err(err, err_cap, "fractalsql: invalid identifier");
            return -1;
        }
        char qschema[80];
        size_t slen = (size_t)(dot - src_ident);
        if (slen >= sizeof qschema - 2) {
            fsqlv_set_err(err, err_cap, "fractalsql: invalid identifier");
            return -1;
        }
        qschema[0] = '"';
        memcpy(qschema + 1, src_ident, slen);   /* validated: no quotes */
        qschema[1 + slen] = '"';
        qschema[2 + slen] = '\0';
        snprintf(sql, sizeof sql, "PRAGMA %s.table_info(%s)",
                 qschema, first + 1);
    } else {
        snprintf(sql, sizeof sql, "PRAGMA main.table_info(%s)", qtbl);
    }

    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(st->db, sql, -1, &stmt, NULL) != SQLITE_OK) {
        fsqlv_set_err(err, err_cap,
                      "fractal_vectorizer_create: source table \"%s\" does "
                      "not exist (%s)", src_ident, sqlite3_errmsg(st->db));
        return -1;
    }

    int npk = 0;
    int rc;
    while ((rc = sqlite3_step(stmt)) == SQLITE_ROW) {
        int is_pk = sqlite3_column_int(stmt, 5);
        if (is_pk > 0) {
            npk++;
            if (is_pk == 1) {
                const char *name = (const char *)sqlite3_column_text(stmt, 1);
                if (name) {
                    int pn = snprintf(pk_col, pk_cap, "%s", name);
                    if (pn < 0 || (size_t)pn >= pk_cap) {
                        sqlite3_finalize(stmt);
                        fsqlv_set_err(err, err_cap,
                            "fractal_vectorizer_create: primary key column "
                            "name is longer than %d characters",
                            (int)pk_cap - 1);
                        return -1;
                    }
                }
            }
        }
    }
    sqlite3_finalize(stmt);
    if (rc != SQLITE_DONE) {
        fsqlv_set_err(err, err_cap, "fractal_vectorizer_create: %s",
                      sqlite3_errmsg(st->db));
        return -1;
    }

    if (npk != 1) {
        /* A plain rowid table deliberately does NOT fall back to
         * rowid: the PK is what makes the queue key stable across
         * re-writes. */
        fsqlv_set_err(err, err_cap,
                      "fractal_vectorizer_create: %s has no single-column "
                      "primary key (composite and missing-PK tables are not "
                      "supported in v1)", src_ident);
        return -1;
    }
    return 0;
}

/* fractal_vectorizer_create(source_table, text_col, embedding_col
 *                           [, options_json]) -> vectorizer id.
 * The options default is an optional TEXT argument defaulting to
 * '{}'. */
static void fsqlv_create_fn(sqlite3_context *ctx, int argc,
                            sqlite3_value **argv) {
    FsqlState *st = (FsqlState *)sqlite3_user_data(ctx);
    char err[FSQLV_ERR_MAX];
    err[0] = '\0';

    const char *src = (argc >= 1 && sqlite3_value_type(argv[0]) != SQLITE_NULL)
                    ? (const char *)sqlite3_value_text(argv[0]) : NULL;
    const char *tcol = (argc >= 2 && sqlite3_value_type(argv[1]) != SQLITE_NULL)
                     ? (const char *)sqlite3_value_text(argv[1]) : NULL;
    const char *ecol = (argc >= 3 && sqlite3_value_type(argv[2]) != SQLITE_NULL)
                     ? (const char *)sqlite3_value_text(argv[2]) : NULL;
    const char *opts = (argc >= 4 && sqlite3_value_type(argv[3]) != SQLITE_NULL)
                     ? (const char *)sqlite3_value_text(argv[3]) : "{}";

    if (!src || !tcol || !ecol) {
        sqlite3_result_error(ctx,
            "fractal_vectorizer_create: source_table, text_col and "
            "embedding_col must not be NULL", -1);
        return;
    }

    /* Validate + quote BEFORE any string-built SQL sees the text. */
    char qtbl[600], qtcol[80], qecol[80];
    if (fsqlv_quote_ident(qtbl, sizeof qtbl, src, 1) != 0 ||
        fsqlv_quote_ident(qtcol, sizeof qtcol, tcol, 0) != 0 ||
        fsqlv_quote_ident(qecol, sizeof qecol, ecol, 0) != 0) {
        sqlite3_result_error(ctx, "fractalsql: invalid identifier", -1);
        return;
    }

    if (fsqlv_ensure_schema(st, err, sizeof err) != 0) {
        sqlite3_result_error(ctx, err, -1);
        return;
    }

    /* Single-column PK introspection. */
    char pk_col[80];
    if (fsqlv_find_pk(st, src, pk_col, sizeof pk_col, err, sizeof err) != 0) {
        sqlite3_result_error(ctx, err, -1);
        return;
    }
    char qpk[80];
    if (fsqlv_quote_ident(qpk, sizeof qpk, pk_col, 0) != 0) {
        sqlite3_result_error(ctx, "fractalsql: invalid identifier", -1);
        return;
    }

    /* Duplicate-vectorizer check up front, naming the existing id in
     * the error (TEMP tables are connection-private, so there is no
     * TOCTOU window). */
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(st->db,
            "SELECT id FROM fractal_vectorizers "
            "WHERE source_table=?1 AND text_col=?2 AND embedding_col=?3",
            -1, &stmt, NULL) == SQLITE_OK) {
        sqlite3_bind_text(stmt, 1, src, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 2, tcol, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 3, ecol, -1, SQLITE_TRANSIENT);
        if (sqlite3_step(stmt) == SQLITE_ROW) {
            sqlite3_int64 existing = sqlite3_column_int64(stmt, 0);
            sqlite3_finalize(stmt);
            char msg[FSQLV_ERR_MAX];
            snprintf(msg, sizeof msg,
                     "fractal_vectorizer_create: a vectorizer for %.64s.%.64s "
                     "-> %.64s already exists (id=%lld)",
                     qtbl, qtcol, qecol, (long long)existing);
            sqlite3_result_error(ctx, msg, -1);
            return;
        }
    }
    if (stmt) { sqlite3_finalize(stmt); stmt = NULL; }

    /* Registry row. */
    if (sqlite3_prepare_v2(st->db,
            "INSERT INTO fractal_vectorizers "
            "(source_table, source_pk_col, text_col, embedding_col, options) "
            "VALUES (?1, ?2, ?3, ?4, ?5)",
            -1, &stmt, NULL) != SQLITE_OK) {
        fsqlv_set_err(err, sizeof err, "fractal_vectorizer_create: %s",
                      sqlite3_errmsg(st->db));
        sqlite3_result_error(ctx, err, -1);
        return;
    }
    sqlite3_bind_text(stmt, 1, src, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 2, pk_col, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 3, tcol, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 4, ecol, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 5, opts, -1, SQLITE_TRANSIENT);
    if (sqlite3_step(stmt) != SQLITE_DONE) {
        fsqlv_set_err(err, sizeof err, "fractal_vectorizer_create: %s",
                      sqlite3_errmsg(st->db));
        sqlite3_finalize(stmt);
        sqlite3_result_error(ctx, err, -1);
        return;
    }
    sqlite3_finalize(stmt);
    sqlite3_int64 vid = sqlite3_last_insert_rowid(st->db);

    /* Two AFTER triggers — INSERT plus UPDATE OF text_col (see
     * fsqlv_drop_triggers above for why it isn't one combined trigger).
     * The enabled-check in the SELECT makes a paused (or deleted)
     * registry row a no-op rather than an error. */
    char upd_event[100];
    snprintf(upd_event, sizeof upd_event, "AFTER UPDATE OF %s", qtcol);
    if (fsqlv_create_trigger(st, vid, "", "AFTER INSERT", qtbl, qpk,
                             err, sizeof err) != 0 ||
        fsqlv_create_trigger(st, vid, "u", upd_event, qtbl, qpk,
                             err, sizeof err) != 0) {
        fsqlv_create_cleanup(st, vid);
        sqlite3_result_error(ctx, err, -1);
        return;
    }

    /* Backfill: queue existing rows that don't have an embedding yet,
     * not the whole table — a vectorizer retrofitted onto a table that
     * already has some embeddings shouldn't redo them (ON CONFLICT ...
     * DO NOTHING against the partial unique index). */
    char sql[FSQLV_SQL_MAX];
    int n = snprintf(sql, sizeof sql,
        "INSERT INTO fractal_vectorizer_queue (vectorizer_id, source_pk_value) "
        "SELECT %lld, CAST(%s AS TEXT) FROM %s "
        "WHERE %s IS NULL AND %s IS NOT NULL "
        "ON CONFLICT (vectorizer_id, source_pk_value) "
        "  WHERE status IN ('pending','processing') DO NOTHING",
        (long long)vid, qpk, qtbl, qecol, qtcol);
    if (n <= 0 || (size_t)n >= sizeof sql) {
        fsqlv_create_cleanup(st, vid);
        sqlite3_result_error(ctx,
            "fractalsql: internal error building backfill SQL", -1);
        return;
    }
    if (fsqlv_exec(st->db, sql, err, sizeof err) != 0) {
        fsqlv_create_cleanup(st, vid);
        sqlite3_result_error(ctx, err, -1);
        return;
    }

    sqlite3_result_int64(ctx, vid);
}

/* ------------------------------------------------------------------ */
/* pause / resume / drop                                               */
/* ------------------------------------------------------------------ */

/* fractal_vectorizer_pause(id) / fractal_vectorizer_resume(id) —
 * shared body. `enabled` is the new registry value; fn_name appears in
 * the "no vectorizer with id" error. Idempotent (pausing an
 * already-paused id is a no-op); the only real failure
 * mode is an id that doesn't exist. */
static void fsqlv_pause_resume_impl(sqlite3_context *ctx,
                                    sqlite3_value *id_arg,
                                    int enabled, const char *fn_name) {
    FsqlState *st = (FsqlState *)sqlite3_user_data(ctx);

    if (sqlite3_value_type(id_arg) == SQLITE_NULL) {
        sqlite3_result_error(ctx,
            "fractal_vectorizer_pause: no vectorizer with id NULL", -1);
        return;
    }
    sqlite3_int64 vid = sqlite3_value_int64(id_arg);

    char err[FSQLV_ERR_MAX];
    err[0] = '\0';
    if (fsqlv_ensure_schema(st, err, sizeof err) != 0) {
        sqlite3_result_error(ctx, err, -1);
        return;
    }

    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(st->db,
            "UPDATE fractal_vectorizers SET enabled=?1 WHERE id=?2",
            -1, &stmt, NULL) != SQLITE_OK) {
        sqlite3_result_error(ctx, sqlite3_errmsg(st->db), -1);
        return;
    }
    sqlite3_bind_int(stmt, 1, enabled);
    sqlite3_bind_int64(stmt, 2, vid);
    int rc = sqlite3_step(stmt);
    sqlite3_finalize(stmt);
    if (rc != SQLITE_DONE) {
        sqlite3_result_error(ctx, sqlite3_errmsg(st->db), -1);
        return;
    }
    if (sqlite3_changes(st->db) == 0) {
        char msg[128];
        snprintf(msg, sizeof msg,
                 "%s: no vectorizer with id %lld", fn_name, (long long)vid);
        sqlite3_result_error(ctx, msg, -1);
        return;
    }
    sqlite3_result_int(ctx, 0);
}

static void fsqlv_pause_fn(sqlite3_context *ctx, int argc,
                           sqlite3_value **argv) {
    (void)argc;
    fsqlv_pause_resume_impl(ctx, argv[0], 0, "fractal_vectorizer_pause");
}

static void fsqlv_resume_fn(sqlite3_context *ctx, int argc,
                            sqlite3_value **argv) {
    (void)argc;
    fsqlv_pause_resume_impl(ctx, argv[0], 1, "fractal_vectorizer_resume");
}

/* fractal_vectorizer_drop(id) — irreversible: drop the enqueue trigger
 * (if still installed), delete the queue rows and the rate-window
 * counter, delete the registry row (ON DELETE CASCADE, applied by
 * hand). For a temporary stop that keeps config/history, use
 * fractal_vectorizer_pause() instead. */
static void fsqlv_drop_fn(sqlite3_context *ctx, int argc,
                          sqlite3_value **argv) {
    (void)argc;
    FsqlState *st = (FsqlState *)sqlite3_user_data(ctx);

    if (sqlite3_value_type(argv[0]) == SQLITE_NULL) {
        sqlite3_result_error(ctx,
            "fractal_vectorizer_drop: no vectorizer with id NULL", -1);
        return;
    }
    sqlite3_int64 vid = sqlite3_value_int64(argv[0]);

    char err[FSQLV_ERR_MAX];
    err[0] = '\0';
    if (fsqlv_ensure_schema(st, err, sizeof err) != 0) {
        sqlite3_result_error(ctx, err, -1);
        return;
    }

    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(st->db,
            "SELECT id FROM fractal_vectorizers WHERE id=?1",
            -1, &stmt, NULL) != SQLITE_OK) {
        sqlite3_result_error(ctx, sqlite3_errmsg(st->db), -1);
        return;
    }
    sqlite3_bind_int64(stmt, 1, vid);
    int rc = sqlite3_step(stmt);
    sqlite3_finalize(stmt);
    if (rc != SQLITE_ROW) {
        char msg[128];
        snprintf(msg, sizeof msg,
                 "fractal_vectorizer_drop: no vectorizer with id %lld",
                 (long long)vid);
        sqlite3_result_error(ctx, msg, -1);
        return;
    }

    /* The triggers may already be gone (source table dropped since
     * create; SQLite took the temp triggers with it) — IF EXISTS keeps
     * this a clean no-op. */
    char sql[FSQLV_SQL_MAX];
    if (fsqlv_drop_triggers(st, vid, err, sizeof err) != 0) {
        sqlite3_result_error(ctx, err, -1);
        return;
    }
    snprintf(sql, sizeof sql,
             "DELETE FROM fractal_vectorizer_queue WHERE vectorizer_id=%lld;",
             (long long)vid);
    if (fsqlv_exec(st->db, sql, err, sizeof err) != 0) {
        sqlite3_result_error(ctx, err, -1);
        return;
    }
    snprintf(sql, sizeof sql,
             "DELETE FROM fractal_vectorizer_rate_window WHERE "
             "vectorizer_id=%lld;", (long long)vid);
    if (fsqlv_exec(st->db, sql, err, sizeof err) != 0) {
        sqlite3_result_error(ctx, err, -1);
        return;
    }
    snprintf(sql, sizeof sql,
             "DELETE FROM fractal_vectorizers WHERE id=%lld;",
             (long long)vid);
    if (fsqlv_exec(st->db, sql, err, sizeof err) != 0) {
        sqlite3_result_error(ctx, err, -1);
        return;
    }
    sqlite3_result_int(ctx, 0);
}

/* ------------------------------------------------------------------ */
/* fractal_vectorizer_process_queue                                    */
/* ------------------------------------------------------------------ */

/* Read a vectorizer's options JSON for the rate cap. Uses json_extract
 * when the host SQLite ships JSON1; without it the cap is invisible
 * and every row is processed uncapped (the pre-cap behavior).
 * Returns 0 and fills *max_calls (-1 = no cap) / *window_secs. */
static void fsqlv_read_rate_cap(FsqlState *st, const char *options,
                                int *max_calls, int *window_secs) {
    *max_calls = -1;
    *window_secs = 3600;

    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(st->db,
            "SELECT json_extract(?1,'$.max_embeds_per_window'), "
            "       json_extract(?1,'$.rate_window_secs')",
            -1, &stmt, NULL) != SQLITE_OK)
        return;                              /* no JSON1: no cap */

    sqlite3_bind_text(stmt, 1, options, -1, SQLITE_TRANSIENT);
    if (sqlite3_step(stmt) == SQLITE_ROW &&
        sqlite3_column_type(stmt, 0) == SQLITE_INTEGER) {
        *max_calls = sqlite3_column_int(stmt, 0);
        if (sqlite3_column_type(stmt, 1) == SQLITE_INTEGER)
            *window_secs = sqlite3_column_int(stmt, 1);
        if (*window_secs < 1) *window_secs = 1;   /* clamp a bad override */
        if (*max_calls < 0) *max_calls = 0;
    }
    sqlite3_finalize(stmt);
}

/* Apply (or defer under) a vectorizer's rolling-window rate cap.
 * vid is the registry id (the window counter's key); qid is the queue
 * row id (what gets put back on a cap hit). Returns 0 = row may
 * proceed (window call consumed), 1 = cap hit — the row goes back to
 * 'pending' and is NOT counted as processed, -1 = window bookkeeping
 * broke (the row is failed, the batch continues). */
static int fsqlv_rate_gate(FsqlState *st, sqlite3_int64 vid,
                           sqlite3_int64 qid, int max_calls,
                           int window_secs, char *err, size_t err_cap) {
    char sql[256];
    snprintf(sql, sizeof sql,
             "INSERT INTO fractal_vectorizer_rate_window (vectorizer_id) "
             "VALUES (%lld) ON CONFLICT (vectorizer_id) DO NOTHING",
             (long long)vid);
    if (fsqlv_exec(st->db, sql, err, err_cap) != 0) return -1;

    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(st->db,
            "SELECT window_start, window_calls "
            "FROM fractal_vectorizer_rate_window WHERE vectorizer_id=?1",
            -1, &stmt, NULL) != SQLITE_OK) {
        fsqlv_set_err(err, err_cap, "fractal_vectorizer_process_queue: %s",
                      sqlite3_errmsg(st->db));
        return -1;
    }
    sqlite3_bind_int64(stmt, 1, vid);
    int rc = sqlite3_step(stmt);
    if (rc != SQLITE_ROW) {
        fsqlv_set_err(err, err_cap, "fractal_vectorizer_process_queue: %s",
                      sqlite3_errmsg(st->db));
        sqlite3_finalize(stmt);
        return -1;
    }
    sqlite3_int64 wstart = sqlite3_column_int64(stmt, 0);
    sqlite3_int64 wcalls = sqlite3_column_int64(stmt, 1);
    sqlite3_finalize(stmt);

    sqlite3_int64 now = 0;
    sqlite3_stmt *nowq = NULL;
    if (sqlite3_prepare_v2(st->db,
            "SELECT CAST(strftime('%s','now') AS INTEGER)",
            -1, &nowq, NULL) == SQLITE_OK) {
        if (sqlite3_step(nowq) == SQLITE_ROW)
            now = sqlite3_column_int64(nowq, 0);
        sqlite3_finalize(nowq);
    }

    if (now - wstart > (sqlite3_int64)window_secs) {
        wstart = now;
        wcalls = 0;
    }
    if (wcalls >= (sqlite3_int64)max_calls) {
        /* Cap hit for this vectorizer's current window: put the row
         * back to 'pending' (the claim transaction already moved it to
         * 'processing') and move on to the next queue row. Not counted
         * in n_processed — it wasn't processed, just deferred. */
        if (sqlite3_prepare_v2(st->db,
                "UPDATE fractal_vectorizer_queue "
                "SET status='pending', processing_started_at=NULL "
                "WHERE id=?1", -1, &stmt, NULL) != SQLITE_OK) {
            fsqlv_set_err(err, err_cap, "fractal_vectorizer_process_queue: %s",
                          sqlite3_errmsg(st->db));
            return -1;
        }
        sqlite3_bind_int64(stmt, 1, qid);
        sqlite3_step(stmt);
        sqlite3_finalize(stmt);
        return 1;
    }

    snprintf(sql, sizeof sql,
             "UPDATE fractal_vectorizer_rate_window "
             "SET window_start=%lld, window_calls=%lld "
             "WHERE vectorizer_id=%lld",
             (long long)wstart, (long long)(wcalls + 1), (long long)vid);
    if (fsqlv_exec(st->db, sql, err, err_cap) != 0) return -1;
    return 0;
}

/* fractal_vectorizer_process_queue([batch_size [, stale_after_secs]])
 * -> number of rows actually processed (done + failed) — a row
 * deferred by the rate cap or belonging to a paused vectorizer isn't
 * counted. */
static void fsqlv_process_fn(sqlite3_context *ctx, int argc,
                             sqlite3_value **argv) {
    FsqlState *st = (FsqlState *)sqlite3_user_data(ctx);
    char err[FSQLV_ERR_MAX];
    err[0] = '\0';

    int batch = FSQLV_DEFAULT_BATCH;
    if (argc >= 1 && sqlite3_value_type(argv[0]) != SQLITE_NULL)
        batch = sqlite3_value_int(argv[0]);
    int stale_secs = FSQLV_DEFAULT_STALE_SECS;
    if (argc >= 2 && sqlite3_value_type(argv[1]) != SQLITE_NULL)
        stale_secs = sqlite3_value_int(argv[1]);

    if (batch < 1 || batch > FSQLV_MAX_BATCH) {
        char msg[128];
        snprintf(msg, sizeof msg,
                 "fractal_vectorizer_process_queue: batch_size must be "
                 "1..%d, got %d", FSQLV_MAX_BATCH, batch);
        sqlite3_result_error(ctx, msg, -1);
        return;
    }
    if (stale_secs < 1) {
        sqlite3_result_error(ctx,
            "fractal_vectorizer_process_queue: stale_after must be a "
            "positive number of seconds", -1);
        return;
    }

    if (fsqlv_ensure_schema(st, err, sizeof err) != 0) {
        sqlite3_result_error(ctx, err, -1);
        return;
    }

    /* Stale reclaim: rows stranded in 'processing' by a caller that
     * crashed or was killed mid-batch — claiming a row only protects
     * against concurrent callers racing each other, not against a
     * caller that claimed a row and never came back. Epoch
     * text/integer coercion is pinned with explicit CASTs so the
     * comparison is numeric on both sides. */
    {
        sqlite3_stmt *u = NULL;
        if (sqlite3_prepare_v2(st->db,
                "UPDATE fractal_vectorizer_queue "
                "SET status='pending', processing_started_at=NULL "
                "WHERE status='processing' "
                "  AND processing_started_at IS NOT NULL "
                "  AND CAST(processing_started_at AS INTEGER) < "
                "      CAST(strftime('%s','now') AS INTEGER) - ?1",
                -1, &u, NULL) != SQLITE_OK) {
            sqlite3_result_error(ctx, sqlite3_errmsg(st->db), -1);
            return;
        }
        sqlite3_bind_int(u, 1, stale_secs);
        int rc = sqlite3_step(u);
        sqlite3_finalize(u);
        if (rc != SQLITE_DONE) {
            sqlite3_result_error(ctx, sqlite3_errmsg(st->db), -1);
            return;
        }
    }

    /* Candidate selection: oldest created_at first, enabled
     * vectorizers only, capped at batch_size. */
    sqlite3_int64 *ids = (sqlite3_int64 *)malloc(
        (size_t)batch * sizeof(sqlite3_int64));
    if (!ids) {
        sqlite3_result_error_nomem(ctx);
        return;
    }

    sqlite3_stmt *q = NULL;
    if (sqlite3_prepare_v2(st->db,
            "SELECT q.id "
            "FROM fractal_vectorizer_queue q "
            "JOIN fractal_vectorizers v ON v.id = q.vectorizer_id "
            "WHERE q.status='pending' AND v.enabled=1 "
            "ORDER BY q.created_at LIMIT ?1",
            -1, &q, NULL) != SQLITE_OK) {
        sqlite3_result_error(ctx, sqlite3_errmsg(st->db), -1);
        free(ids);
        return;
    }
    sqlite3_bind_int(q, 1, batch);
    int n_claim = 0;
    while (sqlite3_step(q) == SQLITE_ROW && n_claim < batch) {
        ids[n_claim] = sqlite3_column_int64(q, 0);
        n_claim++;
    }
    sqlite3_finalize(q);
    if (n_claim == 0) {
        free(ids);
        sqlite3_result_int(ctx, 0);
        return;
    }

    /* The claim UPDATE renders each id as <= 20 characters plus a comma
     * into a fixed FSQLV_SQL_MAX scratch (prefix below is well under
     * 256 bytes). Keep the claimed batch within what renders without
     * truncation — a larger batch would otherwise abort the whole run
     * with "internal error building claim SQL" after a wasted
     * BEGIN/ROLLBACK round-trip. The loop above caps n_claim at batch,
     * so this only ever reduces it; remaining rows are picked up by
     * the next process_queue call. */
    {
        int max_claim = (FSQLV_SQL_MAX - 256 - 2) / 21;
        if (n_claim > max_claim) n_claim = max_claim;
    }

    /* Claim: BEGIN IMMEDIATE + conditional UPDATE + COMMIT — the
     * FOR UPDATE SKIP LOCKED analog. busy_timeout is per-connection,
     * so the 5 s claim window is set here and restored (to SQLite's
     * stock no-handler default) once the claim transaction closes; a
     * host-installed busy handler cannot be read back and reinstalled,
     * which is the one observable cost of the restore. TEMP tables are
     * connection-private, so contention here is theoretical — the
     * transaction shape is kept anyway for defense in depth. */
    sqlite3_busy_timeout(st->db, FSQLV_CLAIM_BUSY_MS);
    int failed = 0;
    if (fsqlv_exec(st->db, "BEGIN IMMEDIATE", err, sizeof err) != 0) {
        failed = 1;
    } else {
        /* Build "id IN (...)" from the selected ids — plain int64
         * text, nothing injectable. */
        char sql[FSQLV_SQL_MAX];
        int n = snprintf(sql, sizeof sql,
            "UPDATE fractal_vectorizer_queue "
            "SET status='processing', "
            "    processing_started_at="
            "      CAST(strftime('%%s','now') AS INTEGER), "
            "    updated_at=CAST(strftime('%%s','now') AS INTEGER) "
            "WHERE status='pending' AND id IN (");
        size_t used = 0;
        if (n > 0 && (size_t)n < sizeof sql) {
            used = (size_t)n;
            for (int i = 0; i < n_claim; i++) {
                n = snprintf(sql + used, sizeof sql - used, "%s%lld",
                             i ? "," : "", (long long)ids[i]);
                if (n <= 0 || (size_t)n >= sizeof sql - used) {
                    used = 0;          /* truncation: bail out */
                    break;
                }
                used += (size_t)n;
            }
        }
        if (used == 0 || used + 2 >= sizeof sql) {
            fsqlv_set_err(err, sizeof err,
                          "fractal_vectorizer_process_queue: internal error "
                          "building claim SQL");
            failed = 1;
        } else {
            memcpy(sql + used, ")", 2);
            if (fsqlv_exec(st->db, sql, err, sizeof err) != 0) failed = 1;
        }
        if (failed) {
            sqlite3_exec(st->db, "ROLLBACK", NULL, NULL, NULL);
        } else if (fsqlv_exec(st->db, "COMMIT", err, sizeof err) != 0) {
            sqlite3_exec(st->db, "ROLLBACK", NULL, NULL, NULL);
            failed = 1;
        }
    }
    sqlite3_busy_timeout(st->db, 0);       /* restore the stock default */
    if (failed) {
        free(ids);
        sqlite3_result_error(ctx, err, -1);
        return;
    }

    /* Per-row statements, prepared once and reset per row. */
    sqlite3_stmt *row_q = NULL;    /* re-read one claimed queue row     */
    sqlite3_stmt *txt_q = NULL;    /* read the source row's text col    */
    sqlite3_stmt *wr_u  = NULL;    /* write the embedding back          */
    sqlite3_stmt *done_u = NULL;   /* mark done                         */
    sqlite3_stmt *fail_u = NULL;   /* mark failed + error text          */
    int ok = sqlite3_prepare_v2(st->db,
        "SELECT q.source_pk_value, v.source_table, v.source_pk_col, "
        "       v.text_col, v.embedding_col, v.options, v.id "
        "FROM fractal_vectorizer_queue q "
        "JOIN fractal_vectorizers v ON v.id = q.vectorizer_id "
        "WHERE q.id=?1 AND q.status='processing'",
        -1, &row_q, NULL) == SQLITE_OK
        && sqlite3_prepare_v2(st->db,
        "UPDATE fractal_vectorizer_queue "
        "SET status='done', error=NULL, "
        "    updated_at=CAST(strftime('%s','now') AS INTEGER) "
        "WHERE id=?1", -1, &done_u, NULL) == SQLITE_OK
        && sqlite3_prepare_v2(st->db,
        "UPDATE fractal_vectorizer_queue SET status='failed', "
        "    error=?1, "
        "    updated_at=CAST(strftime('%s','now') AS INTEGER) "
        "WHERE id=?2", -1, &fail_u, NULL) == SQLITE_OK;
    if (!ok) {
        if (row_q) sqlite3_finalize(row_q);
        if (done_u) sqlite3_finalize(done_u);
        if (fail_u) sqlite3_finalize(fail_u);
        free(ids);
        sqlite3_result_error(ctx, sqlite3_errmsg(st->db), -1);
        return;
    }

    int n_processed = 0;
    char rowerr[FSQLV_ERR_MAX];
    char sql[FSQLV_SQL_MAX];

    for (int i = 0; i < n_claim; i++) {
        sqlite3_int64 qid = ids[i];

        sqlite3_reset(row_q);
        sqlite3_clear_bindings(row_q);
        sqlite3_bind_int64(row_q, 1, qid);
        if (sqlite3_step(row_q) != SQLITE_ROW) continue;

        const char *pk_val = (const char *)sqlite3_column_text(row_q, 0);
        const char *tbl    = (const char *)sqlite3_column_text(row_q, 1);
        const char *pkcol  = (const char *)sqlite3_column_text(row_q, 2);
        const char *tcol   = (const char *)sqlite3_column_text(row_q, 3);
        const char *ecol   = (const char *)sqlite3_column_text(row_q, 4);
        const char *opts   = (const char *)sqlite3_column_text(row_q, 5);
        sqlite3_int64 reg_id = sqlite3_column_int64(row_q, 6);
        if (!pk_val) pk_val = "";
        if (!opts || !*opts) opts = "{}";

        /* The registry values were validated at create() time; the
         * re-validation before EVERY interpolation is defense in depth
         * (they live in a mutable temp table). */
        char qtbl[600], qpk[80], qtcol[80], qecol[80];
        if (fsqlv_quote_ident(qtbl, sizeof qtbl, tbl, 1) != 0 ||
            fsqlv_quote_ident(qpk, sizeof qpk, pkcol, 0) != 0 ||
            fsqlv_quote_ident(qtcol, sizeof qtcol, tcol, 0) != 0 ||
            fsqlv_quote_ident(qecol, sizeof qecol, ecol, 0) != 0) {
            snprintf(rowerr, sizeof rowerr,
                     "fractal_vectorizer_process_queue: invalid identifier "
                     "in registry for vectorizer %lld", (long long)reg_id);
            sqlite3_reset(fail_u);
            sqlite3_bind_text(fail_u, 1, rowerr, -1, SQLITE_TRANSIENT);
            sqlite3_bind_int64(fail_u, 2, qid);
            sqlite3_step(fail_u);
            n_processed++;
            continue;
        }

        /* Rate cap, read fresh per row so a cap edited mid-batch takes
         * effect on the very next row, and so a batch mixing rows from
         * several vectorizers applies each one's own cap correctly. */
        int max_calls = -1, window_secs = 3600;
        fsqlv_read_rate_cap(st, opts, &max_calls, &window_secs);
        if (max_calls >= 0) {
            int grc = fsqlv_rate_gate(st, reg_id, qid, max_calls,
                                      window_secs, rowerr, sizeof rowerr);
            if (grc < 0) {
                /* Window bookkeeping broke — fail this row, not the
                 * whole batch. */
                sqlite3_reset(fail_u);
                sqlite3_bind_text(fail_u, 1, rowerr, -1, SQLITE_TRANSIENT);
                sqlite3_bind_int64(fail_u, 2, qid);
                sqlite3_step(fail_u);
                n_processed++;
                continue;
            }
            if (grc > 0) continue;   /* deferred: stays pending, uncounted */
        }

        /* Read the source row's text. The PK column is cast to text
         * for the comparison (never the reverse) so this works
         * generically across int/real/text PKs without a type lookup —
         * a correctness-over-index-use trade. */
        snprintf(sql, sizeof sql,
                 "SELECT %s FROM %s WHERE CAST(%s AS TEXT) = ?1",
                 qtcol, qtbl, qpk);
        if (txt_q) { sqlite3_finalize(txt_q); txt_q = NULL; }
        if (sqlite3_prepare_v2(st->db, sql, -1, &txt_q, NULL)
                != SQLITE_OK) {
            snprintf(rowerr, sizeof rowerr,
                     "fractal_vectorizer_process_queue: source read failed "
                     "for %.64s: %.160s", qtbl, sqlite3_errmsg(st->db));
            sqlite3_reset(fail_u);
            sqlite3_bind_text(fail_u, 1, rowerr, -1, SQLITE_TRANSIENT);
            sqlite3_bind_int64(fail_u, 2, qid);
            sqlite3_step(fail_u);
            n_processed++;
            continue;
        }
        sqlite3_bind_text(txt_q, 1, pk_val, -1, SQLITE_TRANSIENT);
        int src_rc = sqlite3_step(txt_q);
        if (src_rc != SQLITE_ROW && src_rc != SQLITE_DONE) {
            snprintf(rowerr, sizeof rowerr,
                     "fractal_vectorizer_process_queue: source read failed "
                     "for %.64s: %.160s", qtbl, sqlite3_errmsg(st->db));
            sqlite3_finalize(txt_q);
            txt_q = NULL;
            sqlite3_reset(fail_u);
            sqlite3_bind_text(fail_u, 1, rowerr, -1, SQLITE_TRANSIENT);
            sqlite3_bind_int64(fail_u, 2, qid);
            sqlite3_step(fail_u);
            n_processed++;
            continue;
        }
        const char *text = (src_rc == SQLITE_ROW)
                         ? (const char *)sqlite3_column_text(txt_q, 0)
                         : NULL;
        if (src_rc == SQLITE_DONE || !text) {
            /* Source row deleted, or its text column went NULL, since
             * this queue entry was created — nothing to embed, not a
             * failure. */
            sqlite3_finalize(txt_q);
            txt_q = NULL;
            sqlite3_reset(done_u);
            sqlite3_clear_bindings(done_u);
            sqlite3_bind_int64(done_u, 1, qid);
            sqlite3_step(done_u);
            n_processed++;
            continue;
        }

        /* Embed + write the canonical BLOB back to the source row.
         * Same 4 MiB input bound as fractal_embed above — the
         * reasoning layer caps the response, not the query. */
        unsigned char *blob = NULL;
        int nbytes = 0;
        int erc;
        if (strlen(text) > FSQL_MAX_INPUT_BYTES) {
            snprintf(rowerr, sizeof rowerr,
                     "fractal_vectorizer_process_queue: source text exceeds "
                     "the 4 MiB embed limit");
            erc = -1;
        } else {
            erc = fsqlv_embed(st, text, &blob, &nbytes,
                              rowerr, sizeof rowerr);
        }
        if (erc != 0) {
            sqlite3_finalize(txt_q);
            txt_q = NULL;
            sqlite3_reset(fail_u);
            sqlite3_bind_text(fail_u, 1, rowerr, -1, SQLITE_TRANSIENT);
            sqlite3_bind_int64(fail_u, 2, qid);
            sqlite3_step(fail_u);
            n_processed++;
            continue;
        }

        snprintf(sql, sizeof sql,
                 "UPDATE %s SET %s = ?1 WHERE CAST(%s AS TEXT) = ?2",
                 qtbl, qecol, qpk);
        if (wr_u) { sqlite3_finalize(wr_u); wr_u = NULL; }
        if (sqlite3_prepare_v2(st->db, sql, -1, &wr_u, NULL) != SQLITE_OK) {
            snprintf(rowerr, sizeof rowerr,
                     "fractal_vectorizer_process_queue: embed write failed "
                     "for %.64s: %.160s", qtbl, sqlite3_errmsg(st->db));
            sqlite3_free(blob);
            sqlite3_finalize(txt_q);
            txt_q = NULL;
            sqlite3_reset(fail_u);
            sqlite3_bind_text(fail_u, 1, rowerr, -1, SQLITE_TRANSIENT);
            sqlite3_bind_int64(fail_u, 2, qid);
            sqlite3_step(fail_u);
            n_processed++;
            continue;
        }
        sqlite3_bind_blob(wr_u, 1, blob, nbytes, SQLITE_TRANSIENT);
        sqlite3_bind_text(wr_u, 2, pk_val, -1, SQLITE_TRANSIENT);
        int wrc = sqlite3_step(wr_u);
        sqlite3_free(blob);
        sqlite3_finalize(wr_u);
        wr_u = NULL;
        sqlite3_finalize(txt_q);
        txt_q = NULL;
        if (wrc != SQLITE_DONE) {
            snprintf(rowerr, sizeof rowerr,
                     "fractal_vectorizer_process_queue: embed write failed "
                     "for %.64s: %.160s", qtbl, sqlite3_errmsg(st->db));
            sqlite3_reset(fail_u);
            sqlite3_bind_text(fail_u, 1, rowerr, -1, SQLITE_TRANSIENT);
            sqlite3_bind_int64(fail_u, 2, qid);
            sqlite3_step(fail_u);
            n_processed++;
            continue;
        }

        sqlite3_reset(done_u);
        sqlite3_clear_bindings(done_u);
        sqlite3_bind_int64(done_u, 1, qid);
        sqlite3_step(done_u);
        n_processed++;
    }

    if (row_q) sqlite3_finalize(row_q);
    if (txt_q) sqlite3_finalize(txt_q);
    if (wr_u) sqlite3_finalize(wr_u);
    if (done_u) sqlite3_finalize(done_u);
    if (fail_u) sqlite3_finalize(fail_u);
    free(ids);

    sqlite3_result_int(ctx, n_processed);
}

/* ------------------------------------------------------------------ */
/* Registration                                                        */
/* ------------------------------------------------------------------ */

int fsql_vectorizer_register(sqlite3 *db, FsqlState *st) {
    /* None of this surface is DETERMINISTIC (network I/O, queue
     * mutation, clock reads), and none of it is INNOCUOUS — it sends
     * data to a configured endpoint and mutates the user's tables. */
    const int flags = SQLITE_UTF8;
    int rc;

    struct { const char *name; int narg; void *fn; } fns[] = {
        { "fractal_vectorizer_create",       -1, (void *)fsqlv_create_fn  },
        { "fractal_vectorizer_pause",         1, (void *)fsqlv_pause_fn   },
        { "fractal_vectorizer_resume",        1, (void *)fsqlv_resume_fn  },
        { "fractal_vectorizer_drop",          1, (void *)fsqlv_drop_fn    },
        { "fractal_vectorizer_process_queue", -1, (void *)fsqlv_process_fn },
        { "fractal_embed",                    1, (void *)fsqlv_embed_fn   },
    };
    for (size_t i = 0; i < sizeof(fns) / sizeof(fns[0]); i++) {
        rc = sqlite3_create_function_v2(db, fns[i].name, fns[i].narg,
                                        flags, st,
                                        (void (*)(sqlite3_context *, int,
                                                  sqlite3_value **))fns[i].fn,
                                        NULL, NULL, NULL);
        if (rc != SQLITE_OK) return rc;
    }
    return SQLITE_OK;
}