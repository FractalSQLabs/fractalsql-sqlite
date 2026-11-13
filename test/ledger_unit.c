/* test/ledger_unit.c -- the ledger and audit chain (src/fsql_ledger.c) driven at the storage seam, with a stand-in for the
 * enterprise core that really uses it.
 *
 * The enterprise core's ledger functions call back into the host's storage VFS (write_entry / read_entry / seal_ledger) and the host
 * persists the blobs in the fractalsql_ledger table. That seam is the part of fsql_ledger.c the shell-driven gates cannot reach with a
 * stub core, so this test links the extension's own objects (the instrumented ones, under --coverage) with a fake core that writes
 * and reads through the VFS, and then:
 *   - flushes and loads with and without an HMAC key, damaging the persisted rows in every way the loaders refuse (flipped payload,
 *     missing / short / wrong MAC, bad entry_hash, broken prev link, wrong genesis sentinel, short hashes), and checks the exact reason
 *   - checks each core return code is reported with its readable clause
 *   - drives the VFS callbacks directly (bad kinds, a NULL payload, a sealed slot read under a different key)
 *   - checks reset / compact clear exactly the slots they say, and that the destructive latch refuses all of them
 *   - appends audit entries of every payload shape, escapes, actor labels and the audit unpacker's grow-and-retry loop
 *   - verifies the chain after a deleted row, a rewritten link, a rewritten payload, a malformed row and a wiped table
 * Modes (argv[1]) run the process-wide settings the ledger reads once: default, cap, badcap, nocap, anchor, anchor-syslog, anchor-bogus.
 * Exit status is nonzero when any check fails.  Build: see test/coverage_run.sh. */
#define _POSIX_C_SOURCE 200809L
#define SQLITE_CORE 1
#include <sqlite3.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "fsql_sqlite_internal.h"
#include "fsql_hmac.h"

int sqlite3_fractalsql_init(sqlite3 *db, char **pzErrMsg, const sqlite3_api_routines *pApi);

static int passes, fails;
static char val[16384];   /* the last statement's first column, or its error message */
#define CHECK(cond, what) do { if (cond) passes++; else { fails++; printf("  FAIL %s (line %d) [last result: %.160s]\n", what, __LINE__, val); } } while (0)

/* ------------------------------------------------------------------ the fake core */
static FsqlState *g_st;
static int g_rc;                  /* nonzero: every fake core call returns it */
static int g_unpack_mode;         /* 0 echo, 1 report OK with an impossible length, 2 truncate forever, 3 truncate with no progress */
static size_t g_loaded_len[32];
static const char *g_payload[4] = {NULL, "truth-blob-v1", "shadow-blob-v1", "shadow-vectors-v1"};

static int fake_flush(fsql_ctx *c) {
    (void)c;
    if (g_rc) return g_rc;
    fsql_storage_vfs_t *v = &g_st->storage_vfs;
    for (int k = 1; k <= 3; k++) {
        int r = v->write_entry(v->user_ctx, k, g_payload[k], strlen(g_payload[k]));
        if (r != FSQL_OK) return r;
    }
    return v->seal_ledger(v->user_ctx);
}
static int fake_load(fsql_ctx *c) {
    (void)c;
    if (g_rc) return g_rc;
    fsql_storage_vfs_t *v = &g_st->storage_vfs;
    int got = 0;
    for (int k = 1; k <= 3; k++) {
        const void *p = NULL; size_t n = 0;
        int r = v->read_entry(v->user_ctx, k, &p, &n);
        if (r == FSQL_ESTORAGE_INTEGRITY) return r;
        if (r == FSQL_OK) { got++; g_loaded_len[k] = n; }
    }
    return got ? FSQL_OK : FSQL_ESTORAGE_UNAVAILABLE;
}
static int fake_op(fsql_ctx *c) { (void)c; return g_rc; }
static int fake_count(const fsql_ctx *c, size_t *out) { (void)c; if (g_rc) return g_rc; *out = 7; return FSQL_OK; }
static int fake_unpack(const void *blob, size_t n, char *out, size_t *cap) {
    if (g_rc) return g_rc;
    if (g_unpack_mode == 1) { *cap = *cap + 5; return FSQL_OK; }
    if (g_unpack_mode == 2) { *cap = (size_t)512 * 1024 * 1024; return FSQL_ETRUNCATED; }
    if (g_unpack_mode == 3) { return FSQL_ETRUNCATED; }
    if (n > *cap) { *cap = n; return FSQL_ETRUNCATED; }
    memcpy(out, blob, n); *cap = n; return FSQL_OK;
}

/* Replaces fsql_enterprise.c (not linked): the core is "loaded" and is the fake above; the state is captured for the VFS. */
int fsql_enterprise_ensure(FsqlState *st, char *err, size_t err_cap) {
    (void)err; (void)err_cap;
    g_st = st;
    st->ent_attempted = st->ent_loaded = 1;
    st->ent.ledger_flush = fake_flush;
    st->ent.ledger_load = fake_load;
    st->ent.ledger_compact = fake_op;
    st->ent.ledger_reset_soft = fake_op;
    st->ent.ledger_reset_hard = fake_op;
    st->ent.ledger_truth_count = fake_count;
    st->ent.ledger_shadow_count = fake_count;
    st->ent.audit_unpack = fake_unpack;
    return 1;
}

/* ------------------------------------------------------------------ helpers */
static sqlite3 *db;

/* Runs the statement; returns 1 and fills val with the first column (or "NULL"), or 0 and fills val with the error message. */
static int Q(const char *sql) {
    sqlite3_stmt *s = NULL;
    val[0] = 0;
    if (sqlite3_prepare_v2(db, sql, -1, &s, NULL) != SQLITE_OK) { snprintf(val, sizeof val, "%s", sqlite3_errmsg(db)); return 0; }
    int rc = sqlite3_step(s);
    if (rc == SQLITE_ROW) {
        const unsigned char *t = sqlite3_column_text(s, 0);
        snprintf(val, sizeof val, "%s", t ? (const char *)t : "NULL");
        sqlite3_finalize(s);
        return 1;
    }
    if (rc == SQLITE_DONE) { sqlite3_finalize(s); return 1; }
    snprintf(val, sizeof val, "%s", sqlite3_errmsg(db));
    sqlite3_finalize(s);
    return 0;
}
static void X(const char *sql) { char *e = NULL; if (sqlite3_exec(db, sql, NULL, NULL, &e) != SQLITE_OK) { printf("  setup failed: %s: %s\n", sql, e ? e : "?"); fails++; } sqlite3_free(e); }
static int ok(const char *sql) { return Q(sql); }
static int errs(const char *sql, const char *sub) { return !Q(sql) && strstr(val, sub) != NULL; }
static int has(const char *sub) { return strstr(val, sub) != NULL; }

static void open_db(const char *path) {
    if (db) sqlite3_close(db);
    db = NULL;
    if (sqlite3_open(path, &db) != SQLITE_OK) { printf("cannot open %s\n", path); exit(2); }
    g_st = NULL;
    /* Initialised directly, not through sqlite3_auto_extension: Apple's system libsqlite3 is built without the extension machinery and
     * never fires auto-extensions. The sources are built with -DSQLITE_CORE, so no api table is needed. */
    if (sqlite3_fractalsql_init(db, NULL, NULL) != SQLITE_OK) { printf("cannot initialise the extension\n"); exit(2); }
    Q("SELECT fractal_ledger_truth_count()");   /* the first ledger call captures the state via the fake ensure */
}
static void set_key(const char *k) { char sql[200]; snprintf(sql, sizeof sql, "SELECT fractal_config_set('enterprise_ledger_key','%s')", k); X(sql); }
static void fresh(const char *key) { g_rc = 0; open_db(":memory:"); set_key(key); Q("SELECT fractal_ledger_reset_hard()"); }   /* a new connection: nothing carried over, watermarks included */

/* Recomputes entry_hash for one row from its stored prev_hash/payload/mac, so a row can be damaged in one field and stay self-consistent. */
static void rehash(long long id) {
    sqlite3_stmt *s = NULL;
    sqlite3_prepare_v2(db, "SELECT payload, mac, prev_hash FROM fractalsql_ledger WHERE id=?1", -1, &s, NULL);
    sqlite3_bind_int64(s, 1, id);
    if (sqlite3_step(s) == SQLITE_ROW) {
        int pl = sqlite3_column_bytes(s, 0), ml = sqlite3_column_bytes(s, 1);
        uint8_t buf[512]; uint8_t h[32];
        memcpy(buf, sqlite3_column_blob(s, 2), 32);
        memcpy(buf + 32, sqlite3_column_blob(s, 0), (size_t)pl);
        if (ml == 32) memcpy(buf + 32 + pl, sqlite3_column_blob(s, 1), 32);
        fsql_sha256(buf, 32 + (size_t)pl + (ml == 32 ? 32 : 0), h);
        sqlite3_stmt *u = NULL;
        sqlite3_prepare_v2(db, "UPDATE fractalsql_ledger SET entry_hash=?1 WHERE id=?2", -1, &u, NULL);
        sqlite3_bind_blob(u, 1, h, 32, SQLITE_STATIC); sqlite3_bind_int64(u, 2, id);
        sqlite3_step(u); sqlite3_finalize(u);
    }
    sqlite3_finalize(s);
}
static long long last_id(int kind) { char sql[120]; snprintf(sql, sizeof sql, "SELECT max(id) FROM fractalsql_ledger WHERE kind=%d", kind); Q(sql); return atoll(val); }
static void upd(int kind, const char *set, int which_last) {   /* UPDATE the newest (which_last=0) or oldest row of the kind */
    char sql[400];
    snprintf(sql, sizeof sql, "UPDATE fractalsql_ledger SET %s WHERE id=(SELECT %s(id) FROM fractalsql_ledger WHERE kind=%d)", set, which_last ? "min" : "max", kind);
    X(sql);
}
static void flush_n(int n) { for (int i = 0; i < n; i++) Q("SELECT fractal_ledger_flush()"); }

/* ------------------------------------------------------------------ scenarios */
static void test_flush_load(void) {
    fresh("");
    CHECK(errs("SELECT fractal_ledger_load()", "") == 0, "a load on an empty ledger is not an error");
    CHECK(ok("SELECT fractal_ledger_flush()") && !strcmp(val, "ok"), "flush");
    CHECK(ok("SELECT fractal_ledger_load()") && !strcmp(val, "ok"), "load after flush");
    CHECK(g_loaded_len[1] == strlen(g_payload[1]) && g_loaded_len[3] == strlen(g_payload[3]), "the core read back what it wrote, through the VFS");
    CHECK(ok("SELECT count(*) FROM fractalsql_ledger") && !strcmp(val, "3"), "one row per kind was appended");
    flush_n(2);
    CHECK(ok("SELECT fractal_ledger_verify(1)") && has("\"ok\":true") && has("\"rows_verified\":3"), "three flushes make a chain of three per kind");
    CHECK(ok("SELECT fractal_ledger_truth_count()") && !strcmp(val, "7"), "truth_count passes the core's number through");
    CHECK(ok("SELECT fractal_ledger_shadow_count()") && !strcmp(val, "7"), "shadow_count too");

    /* a second connection to a file database seeds its buffer from the table */
    char path[] = "/tmp/fsql_ledger_unit_XXXXXX";
    int fd = mkstemp(path); if (fd >= 0) close(fd);
    open_db(path);
    set_key("k1"); flush_n(2);
    open_db(path);
    set_key("k1");
    CHECK(ok("SELECT fractal_ledger_load()") && !strcmp(val, "ok"), "a new connection loads what the old one persisted");
    CHECK(g_loaded_len[2] == strlen(g_payload[2]), "and the core sees it");
    set_key("a-different-key");
    CHECK(errs("SELECT fractal_ledger_load()", "HMAC mismatch"), "a load under a different key is refused");
    open_db(":memory:");
    unlink(path);
}

static void test_tamper(void) {
    /* with a key: rows are MAC-tagged */
    fresh("key-one"); flush_n(3);
    CHECK(ok("SELECT fractal_ledger_load()"), "the untouched keyed ledger loads");

    upd(1, "payload=payload||x'00'", 0);
    CHECK(errs("SELECT fractal_ledger_load()", "HMAC mismatch"), "a payload change is caught by the MAC");

    fresh("key-one"); flush_n(3); upd(1, "mac=NULL", 0);
    CHECK(errs("SELECT fractal_ledger_load()", "no MAC"), "a missing MAC is refused when a key is set");

    fresh("key-one"); flush_n(3); upd(1, "mac=x'0102030405'", 0);
    CHECK(errs("SELECT fractal_ledger_load()", "stored MAC is 5 bytes"), "a short MAC is refused");

    fresh("key-one"); flush_n(3); upd(1, "entry_hash=zeroblob(32)", 0);
    CHECK(errs("SELECT fractal_ledger_load()", "hash does not match"), "an entry_hash that does not recompute is refused");

    fresh("key-one"); flush_n(3); upd(1, "prev_hash=x'01'", 0);
    CHECK(errs("SELECT fractal_ledger_load()", "not 32 bytes"), "a short prev_hash is refused");

    fresh("key-one"); flush_n(3); upd(1, "entry_hash=x'01'", 0);
    CHECK(errs("SELECT fractal_ledger_load()", "not 32 bytes"), "a short entry_hash is refused");

    /* no key: structural checks only */
    fresh(""); flush_n(3); upd(1, "payload=payload||x'00'", 0);
    CHECK(errs("SELECT fractal_ledger_load()", "hash does not match"), "without a key a payload change still breaks the entry hash");

    fresh(""); flush_n(3);
    long long id = last_id(1);
    upd(1, "prev_hash=zeroblob(32)", 0); rehash(id);
    CHECK(errs("SELECT fractal_ledger_load()", "predecessor"), "a rewritten link to the previous row is caught");

    fresh(""); flush_n(1);
    id = last_id(1);
    upd(1, "prev_hash=randomblob(32)", 0); rehash(id);
    CHECK(errs("SELECT fractal_ledger_load()", "genesis"), "a lone row must start from the genesis sentinel");

    fresh(""); flush_n(1); upd(1, "mac=x'0102030405'", 0);
    CHECK(errs("SELECT fractal_ledger_load()", "stored MAC is 5 bytes"), "without a key a short MAC is refused too");

    fresh(""); flush_n(1); upd(1, "mac=zeroblob(32)", 0); rehash(last_id(1));
    CHECK(ok("SELECT fractal_ledger_load()"), "without a key a well-formed but unverifiable MAC is accepted");

    /* a damaged row of another kind is found when it is seeded */
    fresh("key-one"); flush_n(2); upd(2, "mac=x'0102030405'", 0);
    CHECK(errs("SELECT fractal_ledger_load()", "stored MAC is 5 bytes"), "a short MAC on another kind is refused when seeding");
    fresh("key-one"); flush_n(2); upd(2, "mac=NULL", 0);
    CHECK(errs("SELECT fractal_ledger_load()", "no MAC"), "a missing MAC on another kind is refused when seeding");
    fresh("key-one"); flush_n(2); upd(2, "payload=payload||x'00'", 0);
    CHECK(errs("SELECT fractal_ledger_load()", "HMAC mismatch"), "a changed payload on another kind is refused when seeding");
    fresh("key-one"); flush_n(2);
    X("INSERT INTO fractalsql_ledger(kind,payload,mac,prev_hash,entry_hash) VALUES(99,x'01',NULL,zeroblob(32),zeroblob(32))");
    CHECK(ok("SELECT fractal_ledger_load()"), "a row of a kind the core does not own is skipped");
}

static void test_core_codes(void) {
    static const struct { int rc; const char *text; } T[] = {
        {FSQL_ERR_INVALID, "invalid argument"}, {FSQL_ERR_OOM, "out of memory"}, {FSQL_ERR_RUNTIME, "engine runtime failure"},
        {FSQL_ESTORAGE, "storage VFS failure"}, {FSQL_ESTORAGE_INTEGRITY, "ledger integrity check failed"},
        {FSQL_ELEDGER_INTEGRITY, "ledger integrity check failed"}, {FSQL_EDIVERSITY, "diversify state error"},
        {FSQL_EENTROPY, "entropy source error"}, {FSQL_ELEDGER_FULL, "ledger full (eviction failed)"},
        {FSQL_ELEDGER_IO, "ledger storage IO error"}, {-12345, "core error"},
    };
    static const char *FN[] = {"fractal_ledger_flush()", "fractal_ledger_load()", "fractal_ledger_compact()", "fractal_ledger_reset_soft()",
                               "fractal_ledger_reset_hard()", "fractal_ledger_truth_count()", "fractal_ledger_shadow_count()"};
    fresh("");
    flush_n(1);
    for (size_t i = 0; i < sizeof T / sizeof T[0]; i++) {
        g_rc = T[i].rc;
        for (size_t f = 0; f < sizeof FN / sizeof FN[0]; f++) {
            char sql[120]; snprintf(sql, sizeof sql, "SELECT %s", FN[f]);
            CHECK(!Q(sql) && has(T[i].text), "a core failure is reported with its readable clause");
        }
    }
    g_rc = 0;
    g_rc = FSQL_ESTORAGE_UNAVAILABLE;
    CHECK(ok("SELECT fractal_ledger_load()") && !strcmp(val, "ok"), "'no persisted ledger yet' from the core is not an error on load");
    CHECK(errs("SELECT fractal_ledger_flush()", "no persisted ledger yet"), "...but is on flush");
    g_rc = 0;
}

static void test_vfs_direct(void) {
    fresh("");
    flush_n(1);
    fsql_storage_vfs_t *v = &g_st->storage_vfs;
    const void *p; size_t n;
    CHECK(v->write_entry(v->user_ctx, 0, "x", 1) == FSQL_ESTORAGE, "write_entry refuses kind 0");
    CHECK(v->write_entry(v->user_ctx, 17, "x", 1) == FSQL_ESTORAGE, "write_entry refuses a kind past the maximum");
    CHECK(v->write_entry(v->user_ctx, 4, NULL, 5) == FSQL_ESTORAGE, "write_entry refuses a NULL payload with a length");
    CHECK(v->write_entry(v->user_ctx, 4, NULL, 0) == FSQL_OK, "write_entry accepts an empty payload");
    CHECK(v->write_entry(NULL, 1, "x", 1) == FSQL_ESTORAGE, "write_entry refuses a missing context");
    CHECK(v->read_entry(NULL, 1, &p, &n) == FSQL_ESTORAGE && p == NULL && n == 0, "read_entry refuses a missing context");
    CHECK(v->read_entry(v->user_ctx, 0, &p, &n) == FSQL_ESTORAGE, "read_entry refuses kind 0");
    CHECK(v->read_entry(v->user_ctx, 99, &p, &n) == FSQL_ESTORAGE, "read_entry refuses a kind past the maximum");
    CHECK(v->read_entry(v->user_ctx, 16, &p, &n) == FSQL_ESTORAGE_UNAVAILABLE, "an empty slot reads as unavailable");
    CHECK(v->seal_ledger(NULL) == FSQL_ESTORAGE, "seal_ledger refuses a missing context");
    CHECK(v->read_entry(v->user_ctx, 4, &p, &n) == FSQL_OK && n == 0, "the empty payload reads back empty");

    set_key("seal-key");
    CHECK(v->write_entry(v->user_ctx, 5, "abc", 3) == FSQL_OK, "write under a key");
    CHECK(v->seal_ledger(v->user_ctx) == FSQL_OK, "seal tags the slot");
    CHECK(v->seal_ledger(v->user_ctx) == FSQL_OK, "sealing twice changes nothing");
    CHECK(v->read_entry(v->user_ctx, 5, &p, &n) == FSQL_OK && n == 3, "a sealed slot reads under the same key");
    set_key("other-key");
    CHECK(v->read_entry(v->user_ctx, 5, &p, &n) == FSQL_ESTORAGE_INTEGRITY, "a sealed slot read under another key is an integrity failure");
    set_key("");
    CHECK(v->read_entry(v->user_ctx, 5, &p, &n) == FSQL_OK, "with no key the slot is trusted as it is in memory");
}

static void test_reset(void) {
    fresh("");
    flush_n(1);
    fsql_storage_vfs_t *v = &g_st->storage_vfs;
    const void *p; size_t n;
    CHECK(ok("SELECT fractal_ledger_compact()") && !strcmp(val, "ok"), "compact");
    CHECK(v->read_entry(v->user_ctx, 2, &p, &n) == FSQL_OK, "compact keeps the slots");
    CHECK(ok("SELECT fractal_ledger_reset_soft()") && !strcmp(val, "ok"), "reset_soft");
    CHECK(v->read_entry(v->user_ctx, 1, &p, &n) == FSQL_OK, "reset_soft keeps the truth slot");
    CHECK(v->read_entry(v->user_ctx, 2, &p, &n) == FSQL_ESTORAGE_UNAVAILABLE && v->read_entry(v->user_ctx, 3, &p, &n) == FSQL_ESTORAGE_UNAVAILABLE,
          "reset_soft clears the shadow slots");
    CHECK(ok("SELECT fractal_ledger_reset_hard()") && !strcmp(val, "ok"), "reset_hard");
    CHECK(v->read_entry(v->user_ctx, 1, &p, &n) == FSQL_ESTORAGE_UNAVAILABLE, "reset_hard clears every slot");
}

static void test_latch(void) {
    fresh("");
    flush_n(1);
    CHECK(ok("SELECT fractal_lock_destructive()") && !strcmp(val, "locked"), "the latch sets");
    static const char *FN[] = {"fractal_ledger_flush()", "fractal_ledger_load()", "fractal_ledger_compact()", "fractal_ledger_reset_soft()",
                               "fractal_ledger_reset_hard()", "fractal_audit_log('t','{}')"};
    for (size_t i = 0; i < sizeof FN / sizeof FN[0]; i++) { char sql[100]; snprintf(sql, sizeof sql, "SELECT %s", FN[i]); CHECK(errs(sql, "locked"), "refused under the latch"); }
    CHECK(ok("SELECT fractal_ledger_verify(1)") && has("\"ok\":true"), "verify still works under the latch");
    open_db(":memory:");   /* the latch is per connection */
}

static void test_audit(void) {
    fresh("");
    CHECK(ok("SELECT fractal_audit_log('decision','{\"a\":1}')") && !strcmp(val, "ok"), "an object payload");
    CHECK(ok("SELECT fractal_audit_log('decision','{}')") && !strcmp(val, "ok"), "an empty object payload");
    CHECK(ok("SELECT fractal_audit_log('decision','  { \"a\" : 1 }  ')") && !strcmp(val, "ok"), "an object payload with surrounding whitespace");
    CHECK(ok("SELECT fractal_audit_log('decision','[1,2,3]')") && !strcmp(val, "ok"), "an array payload");
    CHECK(ok("SELECT fractal_audit_log('decision','\"text\"')") && !strcmp(val, "ok"), "a string payload");
    CHECK(ok("SELECT fractal_audit_log('decision','42')") && !strcmp(val, "ok"), "a number payload");
    CHECK(ok("SELECT fractal_audit_log('a\"b\\c'||char(8)||char(12)||char(10)||char(13)||char(9)||char(1),'{}')") && !strcmp(val, "ok"),
          "an entry type that needs every JSON escape");
    CHECK(ok("SELECT fractal_set_actor('alice \"the\" admin')") && has("alice"), "set_actor stores the label");
    CHECK(ok("SELECT fractal_audit_log('decision','{\"a\":2}')") && !strcmp(val, "ok"), "an append under an actor label");
    CHECK(ok("SELECT payload FROM fractalsql_ledger WHERE kind=2 ORDER BY id DESC LIMIT 1") && has("\\\"the\\\""), "the actor label is escaped in the entry");
    CHECK(ok("SELECT fractal_set_actor(5)") && !strcmp(val, ""), "a non-text actor label becomes empty");
    CHECK(ok("SELECT fractal_audit_log(NULL,'{}')") && !strcmp(val, "NULL"), "a NULL entry type is a no-op");
    CHECK(ok("SELECT fractal_audit_log('t',NULL)") && !strcmp(val, "NULL"), "a NULL payload is a no-op");
    CHECK(errs("SELECT fractal_audit_log(1,'{}')", "expects 2 TEXT"), "a non-text entry type is an error");
    CHECK(errs("SELECT fractal_audit_log('t',5)", "expects 2 TEXT"), "a non-text payload is an error");
    CHECK(errs("SELECT fractal_audit_log('t','{bad')", "well-formed JSON"), "a malformed payload is refused");
    CHECK(errs("SELECT fractal_audit_log('t','{\"_actor\":1}')", "reserved key"), "the reserved key is refused");
    CHECK(ok("SELECT fractal_ledger_verify(2)") && has("\"ok\":true") && has("\"rows_verified\":8"), "every accepted append is in the chain");

    /* BEGIN IMMEDIATE cannot nest */
    X("BEGIN");
    CHECK(errs("SELECT fractal_audit_log('t','{}')", "transaction"), "an append inside an open transaction reports the failed BEGIN");
    CHECK(errs("SELECT fractal_ledger_flush()", "transaction"), "so does a flush");
    X("ROLLBACK");

    /* the unpacker */
    CHECK(ok("SELECT fractal_audit_unpack(NULL)") && !strcmp(val, "NULL"), "unpack of NULL is NULL");
    CHECK(ok("SELECT fractal_audit_unpack(x'414243')") && !strcmp(val, "ABC"), "unpack of a small blob");
    CHECK(ok("SELECT length(fractal_audit_unpack(zeroblob(0)))") , "unpack of an empty blob");
    CHECK(ok("SELECT length(fractal_audit_unpack(CAST(replace(hex(zeroblob(20000)),'0','4') AS BLOB)))") && !strcmp(val, "40000"),
          "a blob larger than the first buffer is unpacked through the grow-and-retry loop");
    g_unpack_mode = 1;
    CHECK(errs("SELECT fractal_audit_unpack(x'4142')", "out-of-range"), "a core reporting an impossible length is refused");
    g_unpack_mode = 2;
    CHECK(errs("SELECT fractal_audit_unpack(x'4142')", "out of memory"), "an absurd size requirement is refused");
    g_unpack_mode = 3;
    CHECK(errs("SELECT fractal_audit_unpack(x'4142')", "out of memory"), "a retry that makes no progress is refused");
    g_unpack_mode = 0;
    g_rc = FSQL_ERR_RUNTIME;
    CHECK(errs("SELECT fractal_audit_unpack(x'4142')", "engine runtime failure"), "a core failure is reported");
    g_rc = 0;
}

static void test_verify(void) {
    fresh("");
    for (int i = 0; i < 5; i++) Q("SELECT fractal_audit_log('t','{\"i\":1}')");
    CHECK(ok("SELECT fractal_ledger_verify(2)") && has("\"rows_verified\":5"), "a clean chain");
    CHECK(ok("SELECT fractal_ledger_verify(NULL)") && has("\"rows_verified\":0"), "a NULL kind verifies the default chain, which is empty");
    CHECK(ok("SELECT fractal_ledger_verify(99)") && has("\"rows_verified\":0"), "an unused kind");
    CHECK(ok("SELECT fractal_ledger_verify(-3)") && has("\"rows_verified\":0"), "a negative kind");

    /* chains of different kinds interleave in the one id sequence: that is not a gap */
    Q("SELECT fractal_ledger_flush()");
    Q("SELECT fractal_audit_log('t','{\"i\":2}')");
    Q("SELECT fractal_ledger_flush()");
    Q("SELECT fractal_audit_log('t','{\"i\":3}')");
    CHECK(ok("SELECT fractal_ledger_verify(2)") && has("\"ok\":true") && has("\"rows_verified\":9"), "rows of other kinds between a chain's rows are not a sequence gap");
    CHECK(ok("SELECT fractal_ledger_verify(1)") && has("\"ok\":true") && has("\"rows_verified\":2"), "nor in the other direction");
    X("DELETE FROM fractalsql_ledger WHERE kind=1");
    X("DELETE FROM fractalsql_ledger WHERE id=(SELECT id FROM fractalsql_ledger WHERE kind=2 ORDER BY id LIMIT 1 OFFSET 2)");
    CHECK(ok("SELECT fractal_ledger_verify(2)") && has("sequence gap"), "a deleted row of the chain is still a sequence gap");

    fresh("");
    for (int i = 0; i < 4; i++) Q("SELECT fractal_audit_log('t','{\"i\":1}')");
    upd(2, "prev_hash=randomblob(32)", 0);
    CHECK(ok("SELECT fractal_ledger_verify(2)") && has("chain-link break"), "a rewritten link is a chain-link break");

    fresh("");
    for (int i = 0; i < 4; i++) Q("SELECT fractal_audit_log('t','{\"i\":1}')");
    upd(2, "payload=payload||x'20'", 0);
    CHECK(ok("SELECT fractal_ledger_verify(2)") && has("entry_hash mismatch"), "a rewritten payload fails the entry hash");

    fresh("");
    for (int i = 0; i < 3; i++) Q("SELECT fractal_audit_log('t','{\"i\":1}')");
    upd(2, "mac=x'0102'", 0);
    CHECK(ok("SELECT fractal_ledger_verify(2)") && has("malformed row"), "a short mac is a malformed row");

    fresh("");
    for (int i = 0; i < 3; i++) Q("SELECT fractal_audit_log('t','{\"i\":1}')");
    CHECK(ok("SELECT fractal_ledger_verify(2)") && has("\"rows_verified\":3"), "three rows seen");
    X("DELETE FROM fractalsql_ledger WHERE kind=2");
    CHECK(ok("SELECT fractal_ledger_verify(2)") && has("chain truncated or wiped"), "a wiped chain is reported against what this connection saw");
    X("DROP TABLE fractalsql_ledger");
    CHECK(ok("SELECT fractal_ledger_verify(2)") && has("chain truncated or wiped"), "...also when the table was dropped");

    /* the old last-writer-wins shape is migrated */
    X("DROP TABLE IF EXISTS fractalsql_ledger");
    X("CREATE TABLE fractalsql_ledger(kind INTEGER PRIMARY KEY, payload BLOB)");
    X("INSERT INTO fractalsql_ledger VALUES(1, x'01')");
    CHECK(ok("SELECT fractal_audit_log('t','{}')") && !strcmp(val, "ok"), "an old-shape table is dropped and recreated");

    /* a table that cannot be created */
    X("DROP TABLE IF EXISTS fractalsql_ledger");
    X("CREATE VIEW fractalsql_ledger AS SELECT 1 AS id");
    CHECK(!Q("SELECT fractal_audit_log('t','{}')"), "an append fails cleanly when the ledger name is taken by a view");
    CHECK(!Q("SELECT fractal_ledger_verify(2)"), "so does a verify");
    CHECK(!Q("SELECT fractal_ledger_flush()"), "and a flush");
    CHECK(!Q("SELECT fractal_ledger_load()"), "and a load");
    X("DROP VIEW fractalsql_ledger");
}

static void test_cap(int expect_cap) {
    fresh("");
    int refused = 0, accepted = 0;
    for (int i = 0; i < 6; i++) { if (Q("SELECT fractal_audit_log('t','{\"i\":1}')")) accepted++; else if (has("chain is full")) refused++; }
    if (expect_cap) CHECK(accepted == 3 && refused == 3, "with FSQL_LEDGER_MAX_ROWS=3 the fourth append is refused");
    else CHECK(accepted == 6 && refused == 0, "no cap: every append is accepted");
    CHECK(ok("SELECT fractal_ledger_verify(2)") && has("\"ok\":true"), "the chain that was kept verifies");
    Q("SELECT fractal_ledger_flush()");
    if (expect_cap) CHECK(has("chain is full"), "a flush is refused at the cap as well");
}

static void test_anchor(const char *mode) {
    fflush(stderr);
    char path[] = "/tmp/fsql_ledger_anchor_XXXXXX";
    int fd = mkstemp(path);
    int saved = dup(2);
    dup2(fd, 2);
    fresh("");
    for (int i = 0; i < 3; i++) Q("SELECT fractal_audit_log('t','{\"i\":1}')");
    flush_n(1);
    fflush(stderr);
    dup2(saved, 2); close(saved);
    lseek(fd, 0, SEEK_SET);
    char buf[8192]; ssize_t n = read(fd, buf, sizeof buf - 1); if (n < 0) n = 0; buf[n] = 0;
    close(fd); unlink(path);
    int lines = 0; for (const char *p = buf; (p = strstr(p, "\"event\":\"ledger_head\"")); p++) lines++;
    if (!strcmp(mode, "anchor")) CHECK(lines == 6, "stderr anchor mode publishes one head per append (3 audit + 3 flush rows)");
    else CHECK(lines == 0, "an unknown mode, or the system logger, writes nothing to stderr");
    CHECK(ok("SELECT fractal_ledger_verify(2)") && has("\"ok\":true"), "the anchored chain verifies");
}

int main(int argc, char **argv) {
    const char *mode = argc > 1 ? argv[1] : "default";
    open_db(":memory:");
    if (!g_st) { printf("  FAIL the extension did not load or did not capture its state\n"); return 1; }
    if (!strcmp(mode, "default")) {
        test_flush_load(); test_tamper(); test_core_codes(); test_vfs_direct(); test_reset(); test_latch(); test_audit(); test_verify();
    } else if (!strcmp(mode, "cap")) test_cap(1);
    else if (!strcmp(mode, "badcap") || !strcmp(mode, "nocap")) test_cap(0);
    else if (!strncmp(mode, "anchor", 6)) test_anchor(mode);
    else { printf("unknown mode %s\n", mode); return 2; }
    sqlite3_close(db);
    printf("ledger_unit[%s]: %d checks passed, %d failed\n", mode, passes, fails);
    return fails ? 1 : 0;
}
