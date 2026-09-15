/* tests/tsan_ledger_runner.c -- Gate 33 driver (build_test.sh --tsan).
 *
 * Why this exists instead of reusing the LD_PRELOAD-into-sqlite3-CLI
 * approach the other 32 gates use under --asan/--ubsan: that approach
 * retrofits a sanitizer runtime onto an ALREADY-STARTING host process
 * (the unsanitized sqlite3 CLI / python3), via LD_PRELOAD on Linux or
 * DYLD_INSERT_LIBRARIES on Darwin. fractalsql-core's own Darwin harness
 * work (build_test-darwin.sh, gate 05) hit this on real hardware in two
 * separate ways and abandoned it entirely:
 *   1. SIP silently strips DYLD_INSERT_LIBRARIES for Apple-signed /
 *      System-protected binaries -- the preload never happens, and
 *      there is no error, just an unsanitized run that looks clean.
 *   2. Even with a confirmed non-SIP host, the sanitizer runtime can
 *      refuse to trust its own interceptors ("loaded too late") because
 *      the host's own startup (CPython's interpreter init, in that
 *      case) allocates before the retrofitted runtime is live.
 * fractalsql-core's fix (tests/fault/tsan_thread_runner.c, same repo)
 * is to not retrofit anything: compile a tiny host binary WITH
 * -fsanitize=thread from the start, so the runtime initializes at
 * normal process startup like any sanitized binary, then dlopen (via
 * sqlite3_load_extension, SQLite's own dlopen wrapper) the
 * identically-sanitized fractalsql.so into it. No LD_PRELOAD, no
 * DYLD_INSERT_LIBRARIES, no SIP surface, no interceptor-timing race --
 * and the exact same binary works unmodified on Linux and Darwin.
 *
 * Scope: this exercises real cross-connection ledger concurrency --
 * fractal_ledger_flush()'s BEGIN IMMEDIATE serialization (see
 * src/fsql_ledger.c's own header comment) -- across N genuinely
 * concurrent OS threads, each on its own connection to the same
 * database file. This is the same scenario build_test.sh's gate 25
 * Phase C(b) already proves correct under the *default*
 * (non-instrumented) build; running it again here, but compiled into
 * a TSan-instrumented process, is what actually gives ThreadSanitizer
 * a chance to catch a genuine data race in the shared state behind
 * that serialization -- Phase C(b) running under the sqlite3 CLI is
 * not itself sanitized.
 *
 * Needs the vendored enterprise core (fractal_ledger_flush is a
 * dormant-tier no-op without it, same precondition as gate 25) --
 * build_test.sh's gate 33 checks for that before invoking this binary.
 *
 * Compiled by `make tsan-ledger-runner` (always -fsanitize=thread,
 * unconditionally -- this binary has exactly one purpose).
 *
 * Usage:
 *   ./tsan_ledger_runner --db <path> --ext <fractalsql.so> \
 *                         --ent-lib <enterprise .so/.dylib> [--threads N]
 *
 * Exit codes:
 *   0 -- workload completed, ledger verified consistent, no thread
 *        reported an error
 *   1 -- a thread failed (SQL error) or post-run verification failed
 *   2 -- environment failure (bad args, can't open db, can't load ext)
 */

#define _POSIX_C_SOURCE 200809L

#include <sqlite3.h>

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define DEFAULT_THREADS 8
#define MAX_THREADS     64

static const char *g_db_path;
static const char *g_ext_path;
static const char *g_ent_lib;

struct worker_ctx {
    int  id;
    int  rc;            /* 0 ok, 1 failed */
    char err[256];
};

static int
scalar_int_cb(void *ctx, int argc, char **argv, char **cols)
{
    (void)cols;
    if (argc > 0 && argv[0]) *(long *)ctx = atol(argv[0]);
    return 0;
}

static int
scalar_str_cb(void *ctx, int argc, char **argv, char **cols)
{
    (void)cols;
    if (argc > 0 && argv[0]) {
        strncpy((char *)ctx, argv[0], 1023);
        ((char *)ctx)[1023] = '\0';
    }
    return 0;
}

/* open_ledger_conn -- one connection: open, load the extension, point
 * it at the enterprise core, set a busy timeout so concurrent BEGIN
 * IMMEDIATE contention resolves via SQLite's own retry rather than an
 * immediate SQLITE_BUSY. Returns 0 on success. */
static int
open_ledger_conn(sqlite3 **out, char *err, size_t err_cap)
{
    sqlite3 *db = NULL;
    char *errmsg = NULL;
    char sql[1024];

    if (sqlite3_open(g_db_path, &db) != SQLITE_OK) {
        snprintf(err, err_cap, "open: %s", sqlite3_errmsg(db));
        if (db) sqlite3_close(db);
        return 1;
    }
    sqlite3_enable_load_extension(db, 1);
    if (sqlite3_load_extension(db, g_ext_path, "sqlite3_fractalsql_init",
                                &errmsg) != SQLITE_OK) {
        snprintf(err, err_cap, "load_extension: %s",
                 errmsg ? errmsg : "(unknown)");
        sqlite3_free(errmsg);
        sqlite3_close(db);
        return 1;
    }
    sqlite3_exec(db, "PRAGMA busy_timeout=5000", NULL, NULL, NULL);

    snprintf(sql, sizeof sql,
             "SELECT fractalsql_set('enterprise_lib', '%s')", g_ent_lib);
    errmsg = NULL;
    if (sqlite3_exec(db, sql, NULL, NULL, &errmsg) != SQLITE_OK) {
        snprintf(err, err_cap, "enterprise_lib: %s",
                 errmsg ? errmsg : "(unknown)");
        sqlite3_free(errmsg);
        sqlite3_close(db);
        return 1;
    }

    *out = db;
    return 0;
}

static void *
worker_main(void *arg)
{
    struct worker_ctx *w = (struct worker_ctx *)arg;
    sqlite3 *db = NULL;
    char *errmsg = NULL;
    char sql[256];

    if (open_ledger_conn(&db, w->err, sizeof w->err)) {
        w->rc = 1;
        return NULL;
    }

    if (sqlite3_exec(db, "SELECT fractal_diversify_enable()",
                      NULL, NULL, &errmsg) != SQLITE_OK) {
        snprintf(w->err, sizeof w->err, "diversify_enable: %s",
                 errmsg ? errmsg : "(unknown)");
        sqlite3_free(errmsg);
        w->rc = 1;
        sqlite3_close(db);
        return NULL;
    }

    snprintf(sql, sizeof sql,
             "SELECT fractal_feedback_report(%d, 'positive')", w->id);
    errmsg = NULL;
    if (sqlite3_exec(db, sql, NULL, NULL, &errmsg) != SQLITE_OK) {
        snprintf(w->err, sizeof w->err, "feedback_report: %s",
                 errmsg ? errmsg : "(unknown)");
        sqlite3_free(errmsg);
        w->rc = 1;
        sqlite3_close(db);
        return NULL;
    }

    errmsg = NULL;
    if (sqlite3_exec(db, "SELECT fractal_ledger_flush()",
                      NULL, NULL, &errmsg) != SQLITE_OK) {
        snprintf(w->err, sizeof w->err, "ledger_flush: %s",
                 errmsg ? errmsg : "(unknown)");
        sqlite3_free(errmsg);
        w->rc = 1;
        sqlite3_close(db);
        return NULL;
    }

    sqlite3_close(db);
    w->rc = 0;
    return NULL;
}

int
main(int argc, char **argv)
{
    int threads_n = DEFAULT_THREADS;
    int i;

    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--db") == 0 && i + 1 < argc) {
            g_db_path = argv[++i];
        } else if (strcmp(argv[i], "--ext") == 0 && i + 1 < argc) {
            g_ext_path = argv[++i];
        } else if (strcmp(argv[i], "--ent-lib") == 0 && i + 1 < argc) {
            g_ent_lib = argv[++i];
        } else if (strcmp(argv[i], "--threads") == 0 && i + 1 < argc) {
            threads_n = atoi(argv[++i]);
        } else {
            fprintf(stderr, "unknown arg: %s\n", argv[i]);
            return 2;
        }
    }
    if (!g_db_path || !g_ext_path || !g_ent_lib) {
        fprintf(stderr,
            "usage: %s --db <path> --ext <fractalsql.so> "
            "--ent-lib <enterprise lib> [--threads N]\n", argv[0]);
        return 2;
    }
    if (threads_n < 1 || threads_n > MAX_THREADS) {
        fprintf(stderr, "--threads must be 1..%d\n", MAX_THREADS);
        return 2;
    }

    /* Setup: fresh chain, one pre-flushed row so the workers append to
     * an existing chain rather than racing on CREATE TABLE IF NOT
     * EXISTS (same rationale as gate 25 Phase C(b)'s Python driver). */
    {
        sqlite3 *setup = NULL;
        char err[256];
        char *errmsg = NULL;

        if (open_ledger_conn(&setup, err, sizeof err)) {
            fprintf(stderr, "setup: %s\n", err);
            return 2;
        }
        sqlite3_exec(setup, "DROP TABLE IF EXISTS fractalsql_ledger",
                     NULL, NULL, NULL);
        sqlite3_exec(setup, "SELECT fractal_diversify_enable()",
                     NULL, NULL, NULL);
        if (sqlite3_exec(setup, "SELECT fractal_feedback_report(0, 'positive')",
                          NULL, NULL, &errmsg) != SQLITE_OK) {
            fprintf(stderr, "setup feedback_report: %s\n",
                    errmsg ? errmsg : "(unknown)");
            sqlite3_free(errmsg);
            sqlite3_close(setup);
            return 2;
        }
        errmsg = NULL;
        if (sqlite3_exec(setup, "SELECT fractal_ledger_flush()",
                          NULL, NULL, &errmsg) != SQLITE_OK) {
            fprintf(stderr, "setup ledger_flush: %s\n",
                    errmsg ? errmsg : "(unknown)");
            sqlite3_free(errmsg);
            sqlite3_close(setup);
            return 2;
        }
        sqlite3_close(setup);
    }

    /* N concurrent writers, each its own connection to the same file. */
    {
        struct worker_ctx ctxs[MAX_THREADS];
        pthread_t tids[MAX_THREADS];
        int any_failed = 0;

        for (i = 0; i < threads_n; i++) {
            ctxs[i].id = i + 1;
            ctxs[i].rc = 0;
            ctxs[i].err[0] = '\0';
            if (pthread_create(&tids[i], NULL, worker_main, &ctxs[i]) != 0) {
                fprintf(stderr, "pthread_create failed for worker %d\n", i + 1);
                return 2;
            }
        }
        for (i = 0; i < threads_n; i++) {
            pthread_join(tids[i], NULL);
            if (ctxs[i].rc != 0) {
                fprintf(stderr, "worker %d: %s\n", ctxs[i].id, ctxs[i].err);
                any_failed = 1;
            }
        }
        if (any_failed) return 1;
    }

    /* Verify: expect (1 pre-flush + threads_n) rows, and the chain
     * verifies as one unforked line -- proving BEGIN IMMEDIATE actually
     * serialized the read-head/link/insert sequence across real
     * concurrent connections. Matched via substring, not JSON-parsed:
     * this harness is a sanitizer stress driver, not a correctness
     * oracle (gate 25's Python driver already owns that). */
    {
        sqlite3 *vcon = NULL;
        char err[256];
        long rows = -1;
        char report[1024] = {0};
        char *errmsg = NULL;

        if (open_ledger_conn(&vcon, err, sizeof err)) {
            fprintf(stderr, "verify: %s\n", err);
            return 1;
        }
        if (sqlite3_exec(vcon,
                "SELECT count(*) FROM fractalsql_ledger WHERE kind=1",
                scalar_int_cb, &rows, &errmsg) != SQLITE_OK) {
            fprintf(stderr, "verify count: %s\n", errmsg ? errmsg : "?");
            sqlite3_free(errmsg);
            sqlite3_close(vcon);
            return 1;
        }
        errmsg = NULL;
        if (sqlite3_exec(vcon, "SELECT fractal_ledger_verify()",
                          scalar_str_cb, report, &errmsg) != SQLITE_OK) {
            fprintf(stderr, "verify ledger_verify: %s\n",
                    errmsg ? errmsg : "?");
            sqlite3_free(errmsg);
            sqlite3_close(vcon);
            return 1;
        }
        sqlite3_close(vcon);

        long want_rows = 1 + threads_n;
        int chain_ok = strstr(report, "\"ok\":true") != NULL
                     || strstr(report, "\"ok\": true") != NULL;
        if (rows != want_rows || !chain_ok) {
            fprintf(stderr,
                "FAIL: rows=%ld want=%ld chain_ok=%d report=%s\n",
                rows, want_rows, chain_ok, report);
            return 1;
        }
        printf("tsan-ledger-concurrent ok: threads=%d rows=%ld verify=%s\n",
               threads_n, rows, report);
    }

    return 0;
}
