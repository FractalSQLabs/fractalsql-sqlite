/* src/fsql_t2s.c: fractal_schema_context + fractal_text_to_sql.
 *
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * Implements the text-to-SQL tier: fractal_schema_context (schema
 * introspection) and fractal_text_to_sql (LLM-driven SQL generation
 * with mechanical validation).
 *
 * Registered surface (SQLite has no text[], so arities are flat):
 *
 *   fractal_schema_context() -> TEXT
 *       Introspection only, no LLM call. Walks sqlite_master
 *       (type IN ('table','view'), sqlite_* internals excluded, capped
 *       at FSQL_T2S_MAX_TABLES) and emits, per relation, a plain-text
 *       shape:
 *
 *           Table: customers
 *             Columns:
 *               id INTEGER PK NOT NULL
 *               name TEXT NOT NULL DEFAULT '?'
 *             Foreign keys:
 *               customers: FOREIGN KEY (region_id) REFERENCES regions(id)
 *           (blank line)
 *
 *       There is no per-column comment support (SQLite has no
 *       COMMENT ON); columns additionally carry DEFAULT when a default
 *       is defined, because PRAGMA table_info hands it to us.
 *
 *   fractal_text_to_sql(question TEXT) -> TEXT
 *       GENERATE (LLM) -> ALLOWLIST (parse-only, never executes) ->
 *       [REVIEW, optional] -> RETURN, retrying GENERATE with the
 *       validator's reason fed back as feedback, up to
 *       t2s_max_attempts (config: 1..10, default 2). The validated SQL
 *       is returned as text and NEVER executed here.
 *
 * Mechanism notes:
 *
 *   parse-only validation
 *       -> sqlite3_prepare_v2 only. Preparing never executes, so the
 *       whole allowlist check is execution-free by construction. A
 *       CTE body must itself be a SELECT, so a data-modifying CTE
 *       (WITH d AS (DELETE ... RETURNING) SELECT ...) is rejected as
 *       a syntax error at prepare time, before any readonly analysis
 *       runs. EXPLAIN is rejected outright (stmt_isexplain below —
 *       a portable text-based stand-in for sqlite3_stmt_isexplain,
 *       which older SQLite headers neither declare nor route)
 *       rather than mechanically planned: preparing IS the mechanical
 *       parse check here, and there is no planner to consult without
 *       executing.
 *
 *   first-keyword pre-check
 *       -> the policy check runs on the raw text FIRST (skip
 *       whitespace/comments, case-insensitive first keyword) so
 *       DROP/CREATE/ATTACH/PRAGMA-style statements never even reach
 *       prepare. "WITH" leading keywords are accepted; the readonly /
 *       isexplain checks below make that safe.
 *
 *   dispatch
 *       -> fsql_reasoning_generate() (fsql_reasoning.c) with the
 *       FSQL_REASONING_TIER_T2S tier: the helper owns per-tier plugin
 *       attach (env block + load) and the evil-lying-length response
 *       guard. The RESPONSE_MODE=code juggling around the GENERATE
 *       call is applied by that tier's env block, and a local
 *       fenced-block extractor backs it up: the candidate SQL is
 *       pulled from a ```sql (or bare ```) fence when present, else
 *       the whole trimmed response is taken, so text- and code-mode
 *       plugins both work. The schema context is embedded in the
 *       prompt (it is plain text; the dispatch context here must be
 *       JSON).
 *
 *   audit
 *       -> t2s_audit_log_best_effort (enterprise ledger) is NOT ported;
 *       the ledger surface lives in fsql_ledger.c and text_to_sql
 *       stays a community feature that must not depend on it.
 *
 * Safety invariants (all paths): generated SQL is never executed; the
 * http_token config value is never written to any prompt or error;
 * every scratch buffer is freed on every path; inputs are bounded by
 * FSQL_MAX_INPUT_BYTES (question, schema description, plugin response
 * via the reasoning guard; retry feedback is additionally truncated).
 */

#include <sqlite3ext.h>
SQLITE_EXTENSION_INIT3

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fsql_sqlite_internal.h"

/* ------------------------------------------------------------------ */
/* Small helpers                                                       */
/* ------------------------------------------------------------------ */

/* err may be NULL (callers without an error buffer); truncation by
 * snprintf is fine — messages are diagnostics, not contracts. Same
 * shape as fsql_reasoning.c's set_err. */
static void set_err(char *err, size_t err_cap, const char *fmt, ...) {
    if (!err || err_cap == 0) return;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(err, err_cap, fmt, ap);
    va_end(ap);
}

static char *dup_str(const char *s) {
    if (!s) return NULL;
    size_t n = strlen(s);
    char *copy = (char *)malloc(n + 1);
    if (copy) memcpy(copy, s, n + 1);
    return copy;
}

/* Malloc'd copy capped at `max` bytes, with a truncation marker when
 * the source is longer. Keeps retry feedback (a model critique can be
 * ~1 MiB) from dominating the next prompt. */
static char *copy_bounded(const char *s, size_t max) {
    if (!s) return NULL;
    size_t n = strlen(s);
    int truncated = n > max;
    if (truncated) n = max;
    char *copy = (char *)malloc(n + (truncated ? 16 : 1));
    if (!copy) return NULL;
    memcpy(copy, s, n);
    if (truncated) {
        memcpy(copy + n, "...[truncated]", 14);
        n += 14;
    }
    copy[n] = '\0';
    return copy;
}

static int ascii_ieq(const char *a, const char *b) {
    while (*a && *b) {
        if (tolower((unsigned char)*a) != tolower((unsigned char)*b))
            return 0;
        a++;
        b++;
    }
    return *a == '\0' && *b == '\0';
}

static int ascii_prefix_ieq(const char *a, const char *b) {
    while (*a && *b) {
        if (tolower((unsigned char)*a) != tolower((unsigned char)*b))
            return 0;
        a++;
        b++;
    }
    return *b == '\0';
}

/* Case-insensitive substring search (no strcasestr in strict C11). */
static const char *find_ci(const char *hay, const char *needle) {
    if (!*needle) return hay;
    for (const char *p = hay; *p; p++) {
        size_t i;
        for (i = 0; needle[i]; i++) {
            if (!p[i]) return NULL;
            if (tolower((unsigned char)p[i]) !=
                tolower((unsigned char)needle[i]))
                break;
        }
        if (!needle[i]) return p;
    }
    return NULL;
}

/* ------------------------------------------------------------------ */
/* Growable text buffer                                                */
/* ------------------------------------------------------------------ */

typedef struct StrBuf {
    char  *buf;
    size_t cap;
    size_t len;
    int    failed;   /* OOM — sticky; all later appends are no-ops */
} StrBuf;

static void sb_init(StrBuf *b) {
    b->cap = 512;
    b->buf = (char *)malloc(b->cap);
    b->len = 0;
    b->failed = (b->buf == NULL);
    if (b->buf) b->buf[0] = '\0';
}

static void sb_free(StrBuf *b) {
    free(b->buf);
    b->buf = NULL;
    b->cap = 0;
    b->len = 0;
}

static void sb_reset(StrBuf *b) {
    b->len = 0;
    b->failed = 0;
    if (b->buf) b->buf[0] = '\0';
}

static void sb_putn(StrBuf *b, const char *s, size_t n) {
    if (b->failed || n == 0) return;
    if (b->len + n + 1 > b->cap) {
        size_t nc = b->cap * 2;
        while (nc < b->len + n + 1) nc *= 2;
        char *nb = (char *)realloc(b->buf, nc);
        if (!nb) {
            b->failed = 1;
            return;
        }
        b->buf = nb;
        b->cap = nc;
    }
    memcpy(b->buf + b->len, s, n);
    b->len += n;
    b->buf[b->len] = '\0';
}

static void sb_put(StrBuf *b, const char *s) { sb_putn(b, s, strlen(s)); }
static void sb_putc(StrBuf *b, char c)       { sb_putn(b, &c, 1); }

/* Malloc'd copy of [start, end) with both edges whitespace-trimmed.
 * NULL on OOM; an empty (not NULL) string when the range is all
 * whitespace. */
static char *copy_trimmed(const char *start, const char *end) {
    while (start < end && isspace((unsigned char)*start)) start++;
    while (end > start && isspace((unsigned char)end[-1])) end--;
    size_t n = (size_t)(end - start);
    char *out = (char *)malloc(n + 1);
    if (!out) return NULL;
    memcpy(out, start, n);
    out[n] = '\0';
    return out;
}

/* ------------------------------------------------------------------ */
/* Schema context — fractal_schema_context                             */
/* ------------------------------------------------------------------ */

/* PRAGMA argument handling. The parameterized form
 * "PRAGMA table_info(?1)" prepared fine before SQLite 3.41 but is
 * rejected at prepare time by current versions ("parameters are not
 * allowed in PRAGMA"), so: try the bound form first; on prepare
 * failure fall back to formatting the pragma string, which is only
 * safe after the identifier passes a strict [A-Za-z0-9_] check. A
 * table whose name cannot be safely embedded is SKIPPED (introspected
 * partially no more) rather than smuggled into SQL text. */
typedef enum { PRAGMA_OK, PRAGMA_SKIP, PRAGMA_ERR } PragmaRc;

static int ident_is_safe(const char *s) {
    if (!s || !*s) return 0;
    if (strlen(s) >= 200) return 0;
    for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
        if (!((*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z') ||
              (*p >= '0' && *p <= '9') || *p == '_'))
            return 0;
    }
    return 1;
}

static PragmaRc prepare_pragma(sqlite3 *db, const char *sql_param,
                               const char *pragma_name, const char *arg,
                               sqlite3_stmt **out_stmt) {
    *out_stmt = NULL;

    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(db, sql_param, -1, &stmt, NULL) == SQLITE_OK) {
        if (sqlite3_bind_text(stmt, 1, arg, -1, SQLITE_TRANSIENT)
                == SQLITE_OK) {
            *out_stmt = stmt;
            return PRAGMA_OK;
        }
        sqlite3_finalize(stmt);
        return PRAGMA_ERR;
    }
    /* Bound form unsupported on this SQLite version — formatted form. */
    if (!ident_is_safe(arg)) return PRAGMA_SKIP;

    StrBuf sql;
    sb_init(&sql);
    sb_put(&sql, pragma_name);
    sb_put(&sql, "(\"");
    sb_put(&sql, arg);
    sb_put(&sql, "\")");
    PragmaRc rc = PRAGMA_ERR;
    if (!sql.failed &&
        sqlite3_prepare_v2(db, sql.buf, -1, &stmt, NULL) == SQLITE_OK) {
        *out_stmt = stmt;
        rc = PRAGMA_OK;
    }
    sb_free(&sql);
    return rc;
}

/* One foreign-key constraint group, flattened from contiguous
 * foreign_key_list rows sharing an id. */
#define FK_ROW_MAX 256

typedef struct FkRow {
    long  id;       /* constraint id (groups the constraint's columns) */
    char *rtable;
    char *from;
    char *to;       /* NULL when the FK omits the referenced columns */
    char *on_update;
    char *on_delete;
    char *match;
} FkRow;

static void fk_rows_free(FkRow *rows, int n) {
    for (int i = 0; i < n; i++) {
        free(rows[i].rtable);
        free(rows[i].from);
        free(rows[i].to);
        free(rows[i].on_update);
        free(rows[i].on_delete);
        free(rows[i].match);
    }
}

static int emit_foreign_keys(FsqlState *st, StrBuf *out, const char *name,
                             char *err, size_t err_cap) {
    sqlite3_stmt *fs = NULL;
    PragmaRc prc = prepare_pragma(st->db, "PRAGMA foreign_key_list(?1)",
                                  "PRAGMA foreign_key_list", name, &fs);
    if (prc == PRAGMA_SKIP) return 0;   /* unsafe name, no param form */
    if (prc == PRAGMA_ERR || fs == NULL) {
        set_err(err, err_cap,
                "fractal_schema_context: FK introspection failed for %s: %s",
                name, sqlite3_errmsg(st->db));
        return -1;
    }

    FkRow rows[FK_ROW_MAX];
    int n = 0;
    for (;;) {
        int rc = sqlite3_step(fs);
        if (rc == SQLITE_DONE) break;
        if (rc != SQLITE_ROW) {
            set_err(err, err_cap,
                    "fractal_schema_context: FK introspection failed for %s: %s",
                    name, sqlite3_errmsg(st->db));
            sqlite3_finalize(fs);
            fk_rows_free(rows, n);
            return -1;
        }
        if (n >= FK_ROW_MAX) {
            set_err(err, err_cap,
                    "fractal_schema_context: more than %d foreign-key "
                    "column mappings on %s", FK_ROW_MAX, name);
            sqlite3_finalize(fs);
            fk_rows_free(rows, n);
            return -1;
        }
        rows[n].id     = sqlite3_column_int(fs, 0);
        rows[n].rtable = dup_str((const char *)sqlite3_column_text(fs, 2));
        rows[n].from   = dup_str((const char *)sqlite3_column_text(fs, 3));
        rows[n].to     = dup_str((const char *)sqlite3_column_text(fs, 4));
        rows[n].on_update = dup_str((const char *)sqlite3_column_text(fs, 5));
        rows[n].on_delete = dup_str((const char *)sqlite3_column_text(fs, 6));
        rows[n].match  = dup_str((const char *)sqlite3_column_text(fs, 7));
        if (!rows[n].rtable || !rows[n].from) {
            set_err(err, err_cap, "fractalsql: out of memory");
            sqlite3_finalize(fs);
            fk_rows_free(rows, n + 1);
            return -1;
        }
        n++;
    }
    sqlite3_finalize(fs);

    if (n > 0) sb_put(out, "  Foreign keys:\n");

    /* foreign_key_list rows for one constraint are contiguous (ids are
     * handed out per constraint); group on id changes. sqlite3's own
     * constraintdef rendering has no analog here, so rebuild a
     * DDL-shaped line the way pg_get_constraintdef would. */
    StrBuf fcol, tcol;
    sb_init(&fcol);
    sb_init(&tcol);
    int i = 0;
    while (i < n && !out->failed && !fcol.failed && !tcol.failed) {
        int j = i;
        sb_reset(&fcol);
        sb_reset(&tcol);
        while (j < n && rows[j].id == rows[i].id) {
            if (j > i) sb_put(&fcol, ", ");
            sb_put(&fcol, rows[j].from);
            if (rows[j].to) {
                if (j > i) sb_put(&tcol, ", ");
                sb_put(&tcol, rows[j].to);
            }
            j++;
        }

        sb_put(out, "    ");
        sb_put(out, name);
        sb_put(out, ": FOREIGN KEY (");
        sb_put(out, fcol.buf ? fcol.buf : "");
        sb_put(out, ") REFERENCES ");
        sb_put(out, rows[i].rtable);
        if (tcol.len > 0) {
            sb_put(out, "(");
            sb_put(out, tcol.buf);
            sb_put(out, ")");
        }
        if (rows[i].on_update && strcmp(rows[i].on_update, "NO ACTION") != 0) {
            sb_put(out, " ON UPDATE ");
            sb_put(out, rows[i].on_update);
        }
        if (rows[i].on_delete && strcmp(rows[i].on_delete, "NO ACTION") != 0) {
            sb_put(out, " ON DELETE ");
            sb_put(out, rows[i].on_delete);
        }
        if (rows[i].match && strcmp(rows[i].match, "NONE") != 0) {
            sb_put(out, " MATCH ");
            sb_put(out, rows[i].match);
        }
        sb_putc(out, '\n');
        i = j;
    }

    sb_free(&fcol);
    sb_free(&tcol);
    fk_rows_free(rows, n);
    return out->failed ? -1 : 0;
}

/* Resolve `name` (from sqlite_master) and append its structure/FK
 * context to `out`. Returns 0 on success (table emitted or skipped),
 * -1 on hard error with `err` filled. */
static int append_table_context(FsqlState *st, StrBuf *out,
                                const char *name, int is_view,
                                char *err, size_t err_cap) {
    sqlite3_stmt *cs = NULL;
    PragmaRc prc = prepare_pragma(st->db, "PRAGMA table_info(?1)",
                                  "PRAGMA table_info", name, &cs);
    if (prc == PRAGMA_SKIP) return 0;   /* unsafe name, no param form */
    if (prc == PRAGMA_ERR || cs == NULL) {
        set_err(err, err_cap,
                "fractal_schema_context: column introspection failed for %s: %s",
                name, sqlite3_errmsg(st->db));
        return -1;
    }

    sb_put(out, is_view ? "View: " : "Table: ");
    sb_put(out, name);
    sb_putc(out, '\n');
    sb_put(out, "  Columns:\n");

    /* PRAGMA table_info row: cid, name, type, notnull, dflt_value, pk.
     * DEFAULT is appended when present (PRAGMA hands it over, and
     * defaults are prompt-relevant). */
    for (;;) {
        int rc = sqlite3_step(cs);
        if (rc == SQLITE_DONE) break;
        if (rc != SQLITE_ROW) {
            set_err(err, err_cap,
                    "fractal_schema_context: column introspection failed "
                    "for %s: %s", name, sqlite3_errmsg(st->db));
            sqlite3_finalize(cs);
            return -1;
        }
        const char *cname = (const char *)sqlite3_column_text(cs, 1);
        const char *ctype = (const char *)sqlite3_column_text(cs, 2);
        int notnull = sqlite3_column_int(cs, 3);
        const char *dflt = (const char *)sqlite3_column_text(cs, 4);
        int pk = sqlite3_column_int(cs, 5);

        sb_put(out, "    ");
        sb_put(out, cname ? cname : "?");
        if (ctype && *ctype) {
            sb_putc(out, ' ');
            sb_put(out, ctype);
        }
        if (pk)       sb_put(out, " PK");
        if (notnull)  sb_put(out, " NOT NULL");
        if (dflt && *dflt) {
            sb_put(out, " DEFAULT ");
            sb_put(out, dflt);
        }
        sb_putc(out, '\n');
    }
    sqlite3_finalize(cs);

    if (emit_foreign_keys(st, out, name, err, err_cap) != 0) return -1;

    sb_putc(out, '\n');
    return out->failed ? -1 : 0;
}

/* Shared guts of fractal_schema_context(), factored out so
 * fractal_text_to_sql() can build context directly in C. Returns a
 * malloc'd NUL-terminated schema description (caller frees), or NULL
 * with `err` filled. Bounded by FSQL_MAX_INPUT_BYTES. */
static char *build_schema_context(FsqlState *st, char *err, size_t err_cap) {
    StrBuf out;
    sb_init(&out);
    if (out.failed) {
        set_err(err, err_cap, "fractalsql: out of memory");
        return NULL;
    }

    /* sqlite_* internals (sqlite_sequence, sqlite_stat1, ...) are
     * engine bookkeeping; they carry no user data and only confuse
     * the model. */
    static const char *const DISCOVER_SQL =
        "SELECT name, type FROM sqlite_master "
        "WHERE type IN ('table','view') AND substr(name,1,7) <> 'sqlite_' "
        "ORDER BY name";

    sqlite3_stmt *disc = NULL;
    if (sqlite3_prepare_v2(st->db, DISCOVER_SQL, -1, &disc, NULL)
            != SQLITE_OK) {
        set_err(err, err_cap, "fractal_schema_context: table discovery "
                "failed: %s", sqlite3_errmsg(st->db));
        sb_free(&out);
        return NULL;
    }

    int n_tables = 0;
    for (;;) {
        int rc = sqlite3_step(disc);
        if (rc == SQLITE_DONE) break;
        if (rc != SQLITE_ROW) {
            set_err(err, err_cap,
                    "fractal_schema_context: table discovery failed: %s",
                    sqlite3_errmsg(st->db));
            sqlite3_finalize(disc);
            sb_free(&out);
            return NULL;
        }
        const char *name = (const char *)sqlite3_column_text(disc, 0);
        const char *type = (const char *)sqlite3_column_text(disc, 1);
        if (!name || !type) continue;
        if (n_tables >= FSQL_T2S_MAX_TABLES) {
            set_err(err, err_cap,
                    "fractal_schema_context: more than %d tables/views "
                    "found, exceeds the limit -- scope the schema before "
                    "calling", FSQL_T2S_MAX_TABLES);
            sqlite3_finalize(disc);
            sb_free(&out);
            return NULL;
        }
        if (append_table_context(st, &out, name,
                                 strcmp(type, "view") == 0,
                                 err, err_cap) != 0) {
            sqlite3_finalize(disc);
            sb_free(&out);
            return NULL;
        }
        n_tables++;
        /* Abort mid-build once the description can no longer serve as
         * a prompt component — don't accumulate an unbounded buffer
         * just to fail the final size check. */
        if (out.failed || out.len > (size_t)FSQL_MAX_INPUT_BYTES) {
            set_err(err, err_cap,
                    "fractal_schema_context: schema description exceeds "
                    "the %d-byte input cap -- scope the schema before "
                    "calling", FSQL_MAX_INPUT_BYTES);
            sqlite3_finalize(disc);
            sb_free(&out);
            return NULL;
        }
    }
    sqlite3_finalize(disc);

    if (n_tables == 0) {
        set_err(err, err_cap, "fractal_schema_context: no visible tables "
                "found");
        sb_free(&out);
        return NULL;
    }
    if (out.failed || out.len > (size_t)FSQL_MAX_INPUT_BYTES) {
        set_err(err, err_cap,
                "fractal_schema_context: schema description exceeds the "
                "%d-byte input cap (or out of memory) -- scope the schema "
                "before calling", FSQL_MAX_INPUT_BYTES);
        sb_free(&out);
        return NULL;
    }
    return out.buf;
}

/* ------------------------------------------------------------------ */
/* Candidate validation — allowlist, prepare-only                      */
/* ------------------------------------------------------------------ */

/* Skip leading whitespace and SQL comments ("--" to EOL, C-style
 * block comments). */
static const char *skip_ws_comments(const char *p) {
    for (;;) {
        while (*p && isspace((unsigned char)*p)) p++;
        if (p[0] == '-' && p[1] == '-') {
            p += 2;
            while (*p && *p != '\n') p++;
            continue;
        }
        if (p[0] == '/' && p[1] == '*') {
            const char *e = strstr(p + 2, "*/");
            if (!e) return p + strlen(p);
            p = e + 2;
            continue;
        }
        return p;
    }
}

/* First SQL keyword (identifier-shaped) at `p`. Returns 1 and copies
 * it into `word` (NUL-terminated) when present, 0 when the statement
 * does not start with a plain keyword (quoted/bracketed token, '(',
 * etc.) — such shapes are not in the allowlist anyway. */
static int first_word(const char *p, char *word, size_t cap) {
    size_t n = 0;
    if (!isalpha((unsigned char)*p) && *p != '_') return 0;
    while (isalnum((unsigned char)*p) || *p == '_') {
        if (n + 1 < cap) word[n] = (char)*p;
        n++;
        p++;
    }
    if (n >= cap) n = cap - 1;
    word[n] = '\0';
    return n > 0;
}

/* Portable stand-in for sqlite3_stmt_isexplain: that interface only
 * arrived in SQLite 3.28, and its sqlite3ext.h routing was itself
 * broken until 3.31.1, so an extension compiled against older system
 * headers can neither declare nor route it. Derive the same 0/1/2
 * answer from the statement text instead: sqlite3_sql() predates
 * every header this extension can be compiled against and routes
 * through the extension API everywhere. The prepare-only caller has
 * already succeeded by the time this runs, so the text is a complete,
 * parseable statement. */
static int stmt_isexplain(sqlite3_stmt *stmt) {
    const char *sql = stmt ? sqlite3_sql(stmt) : NULL;
    if (!sql) return 0;
    const char *p = skip_ws_comments(sql);
    char word[16];
    if (!first_word(p, word, sizeof word) || !ascii_ieq(word, "explain"))
        return 0;
    p = skip_ws_comments(p + strlen(word));
    if (!(first_word(p, word, sizeof word) && ascii_ieq(word, "query")))
        return 1;
    p = skip_ws_comments(p + strlen(word));
    return (first_word(p, word, sizeof word) && ascii_ieq(word, "plan"))
               ? 2 : 1;
}

/* Statement-shape allowlist, SQLite style:
 *   - first keyword must be in the policy set (checked BEFORE prepare,
 *     on the raw text, so DROP/CREATE/ATTACH/PRAGMA-style statements
 *     are rejected without touching the parser);
 *   - must parse (sqlite3_prepare_v2 — parse only, never executes);
 *   - must be exactly one statement (no stacked-statement injection
 *     via the pzTail chain);
 *   - must not be EXPLAIN;
 *   - in "select" mode must be read-only per sqlite3_stmt_readonly.
 *     A CTE body must be a SELECT, so a data-modifying CTE
 *     (WITH d AS (DELETE/UPDATE/INSERT ...)) is a parse-time syntax
 *     error here, never reaching this check at all -- a writable CTE
 *     hidden inside a nominally read-only statement is not
 *     expressible in SQLite.
 * Returns 0 if `sql` passes, else -1 with a human-readable reason in
 * `reason` suitable for feeding straight back into the next GENERATE
 * retry. */
static int t2s_validate(sqlite3 *db, const char *sql, int allow_dml,
                        char *reason, size_t rcap) {
    char word[32];
    if (!first_word(skip_ws_comments(sql), word, sizeof word)) {
        set_err(reason, rcap, "statement is empty or does not start with "
                "an SQL keyword");
        return -1;
    }

    int kw_ok = ascii_ieq(word, "select") || ascii_ieq(word, "with");
    if (!kw_ok && allow_dml)
        kw_ok = ascii_ieq(word, "insert") || ascii_ieq(word, "update");
    if (!kw_ok) {
        set_err(reason, rcap,
                "statement type \"%s\" is not permitted -- "
                "fractalsql.text_to_sql_allowed_statements is set to "
                "\"%s\"", word, allow_dml ? "select_insert_update"
                                          : "select");
        return -1;
    }

    /* Parse-only walk of the statement chain. Preparing a statement
     * never executes it, so this is safe for every first keyword that
     * got past the pre-check above. */
    const char *tail = sql;
    sqlite3_stmt *first = NULL;
    int n = 0;
    for (;;) {
        sqlite3_stmt *s = NULL;
        const char *next = tail;
        int rc = sqlite3_prepare_v2(db, tail, -1, &s, &next);
        if (rc != SQLITE_OK) {
            sqlite3_finalize(s);
            sqlite3_finalize(first);
            set_err(reason, rcap, "SQL does not parse: %s",
                    sqlite3_errmsg(db));
            return -1;
        }
        if (!s) break;   /* trailing whitespace/comments — nothing left */
        if (next == tail) {   /* paranoia: never loop without progress */
            sqlite3_finalize(s);
            sqlite3_finalize(first);
            set_err(reason, rcap, "could not walk statement chain");
            return -1;
        }
        tail = next;
        n++;
        if (n == 1) {
            first = s;
        } else {
            /* More than one statement — count is all the caller needs;
             * stop walking, free the extra handle. */
            sqlite3_finalize(s);
            break;
        }
    }

    if (n == 0) {
        set_err(reason, rcap, "no SQL statement found");
        return -1;
    }
    if (n != 1) {
        sqlite3_finalize(first);
        set_err(reason, rcap,
                "expected exactly one SQL statement, found more than one "
                "-- fractal_text_to_sql only returns a single statement");
        return -1;
    }

    if (stmt_isexplain(first)) {
        sqlite3_finalize(first);
        set_err(reason, rcap,
                "EXPLAIN statements are not permitted -- "
                "fractal_text_to_sql returns executable SQL only");
        return -1;
    }

    if (!allow_dml && !sqlite3_stmt_readonly(first)) {
        sqlite3_finalize(first);
        set_err(reason, rcap,
                "statement is not read-only -- "
                "fractalsql.text_to_sql_allowed_statements is set to "
                "\"select\" and does not permit writes");
        return -1;
    }

    sqlite3_finalize(first);
    return 0;
}

/* ------------------------------------------------------------------ */
/* Response extraction + review                                        */
/* ------------------------------------------------------------------ */

/* Pull the candidate SQL out of a model response: a ```sql fenced
 * block when present,
 * else a bare ``` fence (content starts after the first newline so a
 * language tag on the fence line is skipped), else the whole response
 * trimmed. Returns a malloc'd string, or NULL on OOM; an empty string
 * means "no SQL found". */
static char *extract_sql_from_response(const char *resp) {
    const char *p = resp;
    while ((p = find_ci(p, "```")) != NULL) {
        const char *body = p + 3;
        if ((body[0] == 's' || body[0] == 'S') &&
            (body[1] == 'q' || body[1] == 'Q') &&
            (body[2] == 'l' || body[2] == 'L') &&
            (isspace((unsigned char)body[3]) || body[3] == '\0')) {
            const char *start = body + 3;
            const char *end = find_ci(start, "```");
            if (!end) end = start + strlen(start);
            return copy_trimmed(start, end);
        }
        p = body;
    }

    p = find_ci(resp, "```");
    if (p) {
        const char *start = strchr(p + 3, '\n');
        start = start ? start + 1 : p + 3;
        const char *end = find_ci(start, "```");
        if (!end) end = start + strlen(start);
        return copy_trimmed(start, end);
    }

    return copy_trimmed(resp, resp + strlen(resp));
}

/* Ask the model to self-review its own candidate against the original
 * question, gated behind t2s_use_review (default off; it is just a
 * second reasoning call with a critique-shaped prompt, not a distinct
 * security mechanism).
 * On success returns 0 and sets *out_critique to a malloc'd copy of
 * the model's full response (caller frees); returns -1 on dispatch
 * failure with `err` filled. Whether the critique PASSes is judged by
 * the caller from the first line, case-insensitively.
 *
 * Dispatches on its own FSQL_REASONING_TIER_REVIEW, not
 * FSQL_REASONING_TIER_T2S: T2S hard-forces RESPONSE_MODE=code (for
 * GENERATE's fenced-SQL extraction), which would let the plugin try to
 * pull a fenced block out of this plain-text critique instead of
 * returning it verbatim — on the rare occasion the model quotes the
 * candidate SQL back inside its explanation, that could return just
 * the quoted fragment instead of the leading "PASS"/"FAIL"
 * critique_pass() below expects. See apply_review_env() in
 * fsql_reasoning.c. */
static int t2s_review(FsqlState *st, const char *question,
                      const char *candidate_sql, char **out_critique,
                      char *err, size_t err_cap) {
    StrBuf prompt;
    sb_init(&prompt);
    sb_put(&prompt, "Original request: ");
    sb_put(&prompt, question);
    sb_put(&prompt, "\n\nCandidate SQL:\n");
    sb_put(&prompt, candidate_sql);
    sb_put(&prompt, "\n\nDoes this candidate correctly and completely "
           "answer the request? Answer PASS or FAIL on the first line, "
           "then explain briefly.");
    if (prompt.failed) {
        sb_free(&prompt);
        set_err(err, err_cap,
                "fractalsql: out of memory building review prompt");
        return -1;
    }

    char *resp = NULL;
    int rc = fsql_reasoning_generate(st, FSQL_REASONING_TIER_REVIEW,
                                     prompt.buf, "{}", &resp,
                                     err, err_cap);
    sb_free(&prompt);
    if (rc != 0) return -1;
    *out_critique = resp;
    return 0;
}

static int critique_pass(const char *critique) {
    const char *p = critique ? critique : "";
    while (*p && isspace((unsigned char)*p)) p++;
    return ascii_prefix_ieq(p, "PASS");
}

/* ------------------------------------------------------------------ */
/* fractal_text_to_sql — the retry loop                                */
/* ------------------------------------------------------------------ */

/* Truncation marker helper shared with the error excerpt below. */
#define T2S_FEEDBACK_MAX 8192

static char *t2s_feedback_copy(const char *s) {
    return copy_bounded(s, T2S_FEEDBACK_MAX);
}

/* Append `s` as a quoted, escaped JSON string literal (RFC 8259: the two
 * mandatory escapes plus the short control-character forms). Duplicated
 * per-TU rather than shared via a header, matching this codebase's
 * existing convention (see fsql_agents.c/fsql_domain_agents.c's own
 * copies). */
static void t2s_json_string(StrBuf *b, const char *s) {
    sb_putc(b, '"');
    if (s) {
        for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
            if (b->failed) break;
            switch (*p) {
            case '"':  sb_put(b, "\\\""); break;
            case '\\': sb_put(b, "\\\\"); break;
            case '\b': sb_put(b, "\\b");  break;
            case '\f': sb_put(b, "\\f");  break;
            case '\n': sb_put(b, "\\n");  break;
            case '\r': sb_put(b, "\\r");  break;
            case '\t': sb_put(b, "\\t");  break;
            default:
                if (*p < 0x20) {
                    char esc[8];
                    snprintf(esc, sizeof esc, "\\u%04x", (unsigned)*p);
                    sb_put(b, esc);
                } else {
                    sb_putn(b, (const char *)p, 1);
                }
            }
        }
    }
    sb_putc(b, '"');
}

/* Best-effort audit-chain provenance (fractalsql_ledger kind=2) for a
 * successful text_to_sql attempt. fractal_audit_log is itself enterprise-gated
 * (fsql_ledger.c), so this silently no-ops on a community-only connection
 * -- text_to_sql is a community feature and must keep working regardless;
 * the audit record is a bonus when licensed, not a requirement. Any
 * failure (no license, OOM, ledger I/O) is discarded, same pattern as
 * da_audit_log_best_effort in fsql_domain_agents.c. */
static void t2s_audit_log_best_effort(FsqlState *st, const char *question,
                                      const char *sql, int attempt) {
    StrBuf js;
    sb_init(&js);
    sb_put(&js, "{\"question\":");
    t2s_json_string(&js, question);
    sb_put(&js, ",\"generated_sql\":");
    t2s_json_string(&js, sql);
    {
        char n[64];
        snprintf(n, sizeof n, ",\"attempt\":%d,\"allowed_statements\":", attempt);
        sb_put(&js, n);
    }
    t2s_json_string(&js, st->cfg.t2s_allowed_statements
                        ? st->cfg.t2s_allowed_statements : "select");
    sb_put(&js, "}");
    if (js.failed) { sb_free(&js); return; }

    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(st->db, "SELECT fractal_audit_log(?1,?2)", -1,
                           &stmt, NULL) == SQLITE_OK) {
        sqlite3_bind_text(stmt, 1, "text_to_sql", -1, SQLITE_STATIC);
        sqlite3_bind_text(stmt, 2, js.buf, -1, SQLITE_TRANSIENT);
        sqlite3_step(stmt);
        sqlite3_finalize(stmt);
    }
    sb_free(&js);
}

/* One GENERATE attempt: prompt (schema + question + policy + optional
 * feedback) -> fsql_reasoning_generate -> candidate SQL extracted.
 * Returns a malloc'd candidate, or NULL with `err` filled on dispatch
 * failure / OOM / prompt overflow. */
static char *t2s_generate_once(FsqlState *st, const char *question,
                               const char *schema, int allow_dml,
                               const char *feedback,
                               char *err, size_t err_cap) {
    StrBuf prompt;
    sb_init(&prompt);
    sb_put(&prompt, "Write a single SQLite ");
    sb_put(&prompt, allow_dml ? "SELECT, INSERT, UPDATE, or DELETE"
                              : "SELECT");
    sb_put(&prompt, " statement that answers this question. Return ONLY "
           "the SQL, wrapped in a ```sql fenced code block, with no "
           "other explanation.\n\nQuestion: ");
    sb_put(&prompt, question);
    sb_put(&prompt, "\n\nDatabase schema:\n");
    sb_put(&prompt, schema);
    if (feedback && *feedback) {
        sb_put(&prompt, "\n\nYour previous attempt was rejected for this "
               "reason: ");
        sb_put(&prompt, feedback);
        sb_put(&prompt, "\n\nWrite a corrected statement.\n");
    }
    if (prompt.failed) {
        sb_free(&prompt);
        set_err(err, err_cap,
                "fractal_text_to_sql: prompt exceeds the %d-byte input "
                "cap (or out of memory)", FSQL_MAX_INPUT_BYTES);
        return NULL;
    }

    /* The T2S tier attach in fsql_reasoning.c forces
     * RESPONSE_MODE=code around this dispatch so the plugin returns a
     * bare fenced block; the local extractor below handles both
     * shapes anyway. */
    char *resp = NULL;
    int rc = fsql_reasoning_generate(st, FSQL_REASONING_TIER_T2S,
                                     prompt.buf, "{}", &resp,
                                     err, err_cap);
    sb_free(&prompt);
    if (rc != 0) return NULL;

    char *candidate = extract_sql_from_response(resp);
    free(resp);
    return candidate;
}

/* Full pipeline. Returns a malloc'd validated SQL statement (caller
 * frees with free()), or NULL with `err` filled. Never executes the
 * candidate. */
static char *t2s_run(FsqlState *st, const char *question,
                     char *err, size_t err_cap) {
    int allow_dml = st->cfg.t2s_allowed_statements &&
                    strcmp(st->cfg.t2s_allowed_statements,
                           "select_insert_update") == 0;
    int use_review = st->cfg.t2s_use_review != 0;

    /* Config validation clamps to 1..10 at set time; clamp again so a
     * hand-poked state can never zero the loop. */
    int attempts = st->cfg.t2s_max_attempts;
    if (attempts < 1) attempts = 1;
    if (attempts > 10) attempts = 10;

    char *schema = build_schema_context(st, err, err_cap);
    if (!schema) return NULL;

    char *result = NULL;
    char *last_sql = NULL;
    char *feedback = NULL;

    for (int attempt = 1; attempt <= attempts; attempt++) {
        /* ---- GENERATE ---- */
        char *candidate = t2s_generate_once(st, question, schema,
                                            allow_dml, feedback,
                                            err, err_cap);
        if (!candidate) {
            /* Dispatch failure is not retried — the plugin error is
             * already in `err`. */
            free(last_sql);
            free(feedback);
            free(schema);
            return NULL;
        }
        free(last_sql);
        last_sql = candidate;

        if (!*candidate) {
            /* last_sql aliases candidate here — clear it first. */
            free(candidate);
            last_sql = NULL;
            free(feedback);
            feedback = t2s_feedback_copy(
                "the model response contained no SQL (no ```sql fenced "
                "block and no bare statement)");
            if (!feedback) {
                set_err(err, err_cap, "fractalsql: out of memory");
                free(schema);
                return NULL;
            }
            if (attempt == attempts) {
                set_err(err, err_cap,
                        "fractal_text_to_sql: exhausted %d attempt(s), "
                        "last rejection: %s", attempts, feedback);
                free(schema);
                free(feedback);
                return NULL;
            }
            continue;
        }

        /* ---- ALLOWLIST (parse-only, never executed) ---- */
        char reason[512] = "";
        if (t2s_validate(st->db, candidate, allow_dml,
                         reason, sizeof reason) != 0) {
            free(feedback);
            feedback = t2s_feedback_copy(reason);
            if (!feedback) {
                set_err(err, err_cap, "fractalsql: out of memory");
                free(last_sql);
                free(schema);
                return NULL;
            }
            if (attempt == attempts) {
                set_err(err, err_cap,
                        "fractal_text_to_sql: exhausted %d attempt(s), "
                        "last rejection: %s -- Last candidate SQL: %.200s",
                        attempts, feedback, candidate);
                free(last_sql);
                free(feedback);
                free(schema);
                return NULL;
            }
            continue;
        }

        /* ---- REVIEW (optional, default off) ---- */
        if (use_review) {
            char *critique = NULL;
            if (t2s_review(st, question, candidate, &critique,
                           err, err_cap) != 0) {
                free(last_sql);
                free(feedback);
                free(schema);
                return NULL;
            }
            if (!critique_pass(critique)) {
                free(feedback);
                feedback = t2s_feedback_copy(critique);
                free(critique);
                if (!feedback) {
                    set_err(err, err_cap, "fractalsql: out of memory");
                    free(last_sql);
                    free(schema);
                    return NULL;
                }
                if (attempt == attempts) {
                    set_err(err, err_cap,
                            "fractal_text_to_sql: exhausted %d attempt(s), "
                            "last review verdict: %s", attempts, feedback);
                    free(last_sql);
                    free(feedback);
                    free(schema);
                    return NULL;
                }
                continue;
            }
            free(critique);
        }

        /* ---- RETURN. Never auto-executed. ---- */
        t2s_audit_log_best_effort(st, question, candidate, attempt);
        result = dup_str(candidate);
        break;
    }

    free(last_sql);
    free(feedback);
    free(schema);

    if (!result) {
        /* Unreachable: the loop above always returns, continues on the
         * final attempt's failure branch, or breaks with `result`.
         * t2s_max_attempts is bounded 1..10. */
        set_err(err, err_cap,
                "fractal_text_to_sql: unreachable retry-loop exit");
        return NULL;
    }
    return result;
}

/* ------------------------------------------------------------------ */
/* SQL entry points                                                    */
/* ------------------------------------------------------------------ */

/* fractal_schema_context() -> TEXT */
static void schema_ctx_fn(sqlite3_context *ctx, int argc,
                          sqlite3_value **argv) {
    (void)argc;
    (void)argv;

    FsqlState *st = (FsqlState *)sqlite3_user_data(ctx);
    if (!st || !st->db) {
        sqlite3_result_error(ctx, "fractalsql: not initialized", -1);
        return;
    }

    char err[512] = "";
    char *out = build_schema_context(st, err, sizeof err);
    if (!out) {
        sqlite3_result_error(ctx,
                             err[0] ? err : "fractal_schema_context failed",
                             -1);
        return;
    }
    sqlite3_result_text(ctx, out, -1, free);
}

/* fractal_text_to_sql(question TEXT) -> TEXT */
static void t2s_fn(sqlite3_context *ctx, int argc, sqlite3_value **argv) {
    (void)argc;

    FsqlState *st = (FsqlState *)sqlite3_user_data(ctx);
    if (!st || !st->ctx || !st->db) {
        sqlite3_result_error(ctx, "fractalsql: not initialized", -1);
        return;
    }
    if (sqlite3_value_type(argv[0]) != SQLITE_TEXT) {
        sqlite3_result_error(ctx,
            "fractal_text_to_sql(question) expects a TEXT question", -1);
        return;
    }
    const char *question = (const char *)sqlite3_value_text(argv[0]);
    size_t qlen = (size_t)sqlite3_value_bytes(argv[0]);
    if (!question) {
        sqlite3_result_error(ctx,
            "fractal_text_to_sql: question must not be NULL", -1);
        return;
    }
    if (qlen > (size_t)FSQL_MAX_INPUT_BYTES) {
        sqlite3_result_error(ctx,
            "fractal_text_to_sql: question exceeds the 1048576-byte "
            "input cap", -1);
        return;
    }

    /* The plugin gate, raised before any LLM traffic. */
    if (!st->cfg.reasoning_plugin || !*st->cfg.reasoning_plugin) {
        sqlite3_result_error(ctx,
            "fractalsql: reasoning plugin not configured (set "
            "fractalsql_set('reasoning_plugin', '/absolute/path'))", -1);
        return;
    }

    char err[512] = "";
    char *sql = t2s_run(st, question, err, sizeof err);
    if (!sql) {
        sqlite3_result_error(ctx, err[0] ? err
                                : "fractal_text_to_sql failed", -1);
        return;
    }
    sqlite3_result_text(ctx, sql, -1, free);
}

/* ------------------------------------------------------------------ */
/* Registration                                                        */
/* ------------------------------------------------------------------ */

int fsql_t2s_register(sqlite3 *db, FsqlState *st) {
    if (!db || !st) return SQLITE_MISUSE;

    /* Introspection is per-connection state reads, not a pure function
     * — same flag set as the config functions. */
    const int flags = SQLITE_UTF8 | SQLITE_INNOCUOUS;

    int rc = sqlite3_create_function_v2(
        db, "fractal_schema_context", 0, flags, st,
        schema_ctx_fn, NULL, NULL, NULL);
    if (rc != SQLITE_OK) return rc;

    /* fractal_text_to_sql is deliberately NOT SQLITE_INNOCUOUS: it
     * loads the reasoning plugin, mutates process state, and sends the
     * caller's text to the configured endpoint. INNOCUOUS would assert
     * to SQLite that the function is safe inside views/triggers under
     * SQLITE_DBCONFIG_TRUSTED_SCHEMA=off, letting a schema writer
     * embed LLM dispatch into a view any more-privileged reader
     * triggers. Same reasoning as the vectorizer's registry-backed
     * functions. */
    return sqlite3_create_function_v2(
        db, "fractal_text_to_sql", 1, SQLITE_UTF8, st,
        t2s_fn, NULL, NULL, NULL);
}