/* src/fsql_ledger.c: storage VFS implementation + the fractal_ledger_* /
 * fractal_audit_* SQL surface.
 *
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * Sovereign-tier TU: excluded from the minimal link (see the TU map in
 * fsql_sqlite_internal.h).
 *
 * ---------------------------------------------------------------------------
 * How the pieces fit
 * ---------------------------------------------------------------------------
 *
 * The fsql_ledger_* / fsql_audit_unpack core symbols are
 * ENTERPRISE-GATED: absent from the community sovereign archive (the
 * vendor header marks them "absent from a community-compiled object",
 * and the MSVC link proved it: LNK2001 on every one of them). This TU
 * therefore dlopens the separately-licensed enterprise core
 * (cfg.enterprise_lib) and resolves them at call time. See
 * fsql_enterprise.c (fsql_enterprise_ensure, one attempt per
 * connection). The host-side storage VFS and the HMAC envelope below
 * are community code; only the core-side ledger operations require the
 * enterprise library. See the "Enterprise gating" comment near
 * fsql_ledger_register for the audit of which functions are (and are
 * not) actually gated.
 *
 * Storage VFS (host side). The core persists through the
 * fsql_storage_vfs_t captured at fsql_new_sovereign time:
 *
 *   write_entry(kind, payload, len)  1=truth, 2=shadow, 3=shadow_vectors
 *     Buffers a copy of the payload in ledger_ctx memory (most-recent
 *     wins per kind). NO re-entrant SQLite calls: the core may call
 *     these mid-statement (fsql_ledger_flush runs inside a search
 *     teardown), so the callbacks only ever touch malloc'd memory.
 *     Returns FSQL_OK or FSQL_ESTORAGE.
 *
 *   read_entry(kind, *payload_out, *len_out)
 *     Returns the most-recent buffered payload for `kind`:
 *     FSQL_OK on hit, FSQL_ESTORAGE_UNAVAILABLE on miss,
 *     FSQL_ESTORAGE_INTEGRITY if a sealed slot fails HMAC verification.
 *     The buffer is implementation-owned (the engine never frees).
 *
 *   seal_ledger()
 *     Computes the integrity seal over every occupied slot (see the
 *     envelope below). Called by the core at fsql_free time and after
 *     long runs; never fails teardown. Materialization to the table
 *     does NOT happen here, only the top-level SQL functions below
 *     touch SQLite.
 *
 * Ledger seal envelope, defined ONCE, here:
 *
 *   When cfg.enterprise_ledger_key is set (fractalsql_set(
 *   'enterprise_ledger_key', ...)), every persisted payload carries a
 *   32-byte authentication tag:
 *
 *       tag = HMAC-SHA256(key = enterprise_ledger_key, msg = payload)
 *
 *   where `payload` is the EXACT raw core blob (the tag is computed over
 *   the unmodified write_entry bytes, never over a wrapped form).
 *
 *   Storage layout: the fractalsql_ledger.mac BLOB column holds the
 *   bare 32-byte tag; the payload column stays the raw core blob. The
 *   in-RAM slot mirrors this: FsqlLedgerSlot.tag[32] + tag_valid — see
 *   the DDL below.
 *
 *   Verification: on read with a key configured, a tag-bearing slot is
 *   re-verified (HMAC recomputed over the payload) and a mismatch
 *   surfaces as FSQL_ESTORAGE_INTEGRITY (fractal_ledger_load maps it to
 *   a readable SQL error). A configured key + a persisted row with NO
 *   tag is refused at load ("written before the key was set") -- an
 *   unauthenticated blob is never trusted once a key is configured.
 *   With no key configured the ledger validates structurally only (the
 *   core's own QTL header decode plus the unconditional entry_hash
 *   chain check below), the historical behavior.
 *
 * Table. fractalsql_ledger is an APPEND-ONLY HASH CHAIN: every
 * row links to its predecessor (for the same `kind`) via
 * entry_hash = SHA256(prev_hash || payload || mac), so a rewritten row
 * breaks the chain and a deleted row leaves a visible gap in the `id`
 * sequence — see fractal_ledger_verify() below, the O(n) walk that proves
 * it. Created lazily on the first top-level ledger call via sqlite3_exec
 * on st->db (migrating the old last-writer-wins snapshot shape first, if
 * found — see ledger_ensure_table):
 *
 *   CREATE TABLE IF NOT EXISTS fractalsql_ledger(
 *     id         INTEGER PRIMARY KEY AUTOINCREMENT,
 *     kind       INTEGER NOT NULL,
 *     payload    BLOB NOT NULL,
 *     mac        BLOB,                 -- HMAC-SHA256 tag (32B), NULL when key unset
 *     prev_hash  BLOB NOT NULL,        -- entry_hash of the prior row for this kind; all-zero(32) = genesis
 *     entry_hash BLOB NOT NULL,        -- SHA256(prev_hash || payload || mac) -- the chain link
 *     sealed     INTEGER NOT NULL DEFAULT 0,
 *     updated_at TEXT NOT NULL DEFAULT (datetime('now')))
 *   CREATE INDEX IF NOT EXISTS fractalsql_ledger_kind_id_idx
 *     ON fractalsql_ledger(kind, id DESC)
 *
 * Top-level flush = core fsql_ledger_flush() (which drives write_entry
 * into the buffer) followed by one APPEND INSERT per occupied slot,
 * each linked into its kind's chain, inside a single transaction (see
 * ledger_materialize). Top-level load = an O(1) tip verify of kind=1's
 * latest row (ledger_verify_tip — structural entry_hash check always,
 * MAC check when a key is configured, chain-link check against the row
 * before it), then clear the buffer and seed it from the LATEST row per
 * kind, then call core fsql_ledger_load(), which pulls the blobs back
 * through read_entry and decodes. compact / reset_soft / reset_hard call
 * the core directly and additionally clear the host-side buffer slots so
 * a later load without an intervening flush cannot resurrect a reset
 * ledger from RAM. fractal_ledger_verify() is the O(n) counterpart: a
 * full walk of one kind's chain, on demand, not run on every load.
 *
 * State invariants:
 *   - st arrives via sqlite3_user_data(ctx); st->ctx for core calls,
 *     st->db for table IO.
 *   - st->ledger_ctx is allocated as ONE calloc block by
 *     fsql_ledger_vfs_setup (never realloc'd or split) and released by
 *     fsql_ledger_teardown, which fsql_state_destroy calls after
 *     fsql_free(st->ctx) -- teardown walks and frees every occupied
 *     slot payload before freeing the block itself. The ctx holds a pointer
 *     back to the owning FsqlState so the callbacks can read the LIVE
 *     cfg.enterprise_ledger_key (key changes take effect at the next
 *     seal/load without re-wiring the VFS); this is safe because the
 *     state outlives both the core ctx and ledger_ctx (fsql_state_destroy
 *     runs fsql_free(st->ctx), which may re-enter seal_ledger, before
 *     freeing ledger_ctx and st).
 *
 * Notes:
 *   - Concurrency: SQLite has no advisory locks; BEGIN IMMEDIATE (the
 *     database's one write lock, acquired up front) serializes the
 *     "read latest, link, insert" sequence — coarser than a per-kind
 *     lock (it serializes across ALL kinds, not just the one being
 *     written) but SQLite only ever has one writer at a time anyway,
 *     so the extra breadth is free.
 *   - Enterprise_lib dlopen path: the community sovereign archive lacks
 *     the fsql_ledger_* / fsql_audit_unpack symbols, so the core-side
 *     operations resolve from the enterprise library (fsql_enterprise.c).
 *     The storage VFS + HMAC envelope below are community code.
 *   - fractal_audit_log takes TEXT (SQLite has no jsonb); the payload is
 *     stored verbatim, not re-parsed into jsonb.
 *   - Mutating functions return 'ok' TEXT so the SQLite surface has a
 *     uniform success value.
 * ---------------------------------------------------------------------- */

#include <sqlite3ext.h>
SQLITE_EXTENSION_INIT3

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fsql_hmac.h"
#include "fsql_sqlite_internal.h"

/* ------------------------------------------------------------------ */
/* Ledger context (the storage VFS user_ctx)                           */
/* ------------------------------------------------------------------ */

/* Core tags 1=truth, 2=shadow, 3=shadow_vectors (fractalsql_sql.h).
 * fractal_audit_log additionally appends kind=2 rows directly to the
 * table, via the same append-only chain machinery: an independent
 * chain per kind (each filtered by WHERE kind=?), so a core write on
 * kind=2 and an audit_log write never collide — each gets its own row,
 * linked into its own kind's chain. The cap is headroom, not a semantic
 * promise: a core that emits an unlisted tag gets FSQL_ESTORAGE rather
 * than silent corruption. */
#define FSQL_LEDGER_MAX_KIND   16

/* audit_unpack growth bounds: start on the stack, grow on the heap,
 * refuse to chase a core that reports no progress or an absurd size. */
#define FSQL_AUDIT_START_CAP   8192u
#define FSQL_AUDIT_MAX_CAP     (256u * 1024u * 1024u)

#define FSQL_LEDGER_CTX_MAGIC  0x46534C4Cu  /* 'FSLL' */

typedef struct FsqlLedgerSlot {
    uint8_t *payload;      /* raw core bytes (never enveloped in RAM)   */
    size_t   len;          /* payload length in bytes                   */
    uint8_t  tag[32];      /* HMAC-SHA256 seal; valid iff tag_valid     */
    int      tag_valid;
    int      have;         /* slot occupied                             */
} FsqlLedgerSlot;

typedef struct FsqlLedgerCtx {
    uint32_t       magic;  /* FSQL_LEDGER_CTX_MAGIC — lifetime canary   */
    FsqlState     *st;     /* owning state (reads cfg live); outlives us*/
    FsqlLedgerSlot slot[FSQL_LEDGER_MAX_KIND + 1];  /* indexed by kind  */
} FsqlLedgerCtx;

/* Validate + downcast the user_ctx the engine hands back. */
static FsqlLedgerCtx *ledger_ctx_of(void *user) {
    FsqlLedgerCtx *lc = (FsqlLedgerCtx *)user;
    if (!lc || lc->magic != FSQL_LEDGER_CTX_MAGIC) return NULL;
    return lc;
}

static void ledger_slot_clear(FsqlLedgerSlot *s) {
    free(s->payload);
    s->payload = NULL;
    s->len = 0;
    memset(s->tag, 0, sizeof s->tag);
    s->tag_valid = 0;
    s->have = 0;
}

/* Clear every slot (all kinds). */
static void ledger_slots_clear_all(FsqlLedgerCtx *lc) {
    for (int k = 1; k <= FSQL_LEDGER_MAX_KIND; k++)
        ledger_slot_clear(&lc->slot[k]);
}

/* Store (replace) the buffered blob for a kind. Takes a copy; `tag` may
 * be NULL (unsealed). Returns 0 on success, -1 on OOM / bad kind. */
static int ledger_slot_store(FsqlLedgerCtx *lc, int kind,
                             const void *payload, size_t len,
                             const uint8_t tag[32]) {
    if (kind < 1 || kind > FSQL_LEDGER_MAX_KIND) return -1;
    if (!payload && len) return -1;
    uint8_t *copy = (uint8_t *)malloc(len ? len : 1);
    if (!copy) return -1;
    if (len) memcpy(copy, payload, len);   /* len==0 may come with NULL src */
    FsqlLedgerSlot *s = &lc->slot[kind];
    free(s->payload);
    s->payload = copy;
    s->len = len;
    if (tag) {
        memcpy(s->tag, tag, 32);
        s->tag_valid = 1;
    } else {
        memset(s->tag, 0, sizeof s->tag);
        s->tag_valid = 0;
    }
    s->have = 1;
    return 0;
}

/* HMAC key live from the config; NULL/empty when unset. */
static const char *ledger_key(const FsqlLedgerCtx *lc) {
    const char *key = lc->st->cfg.enterprise_ledger_key;
    return (key && key[0]) ? key : NULL;
}

/* Compute the seal over every occupied slot that has no valid tag yet
 * (the envelope in the file header). Idempotent; returns 0 on success,
 * -1 on OOM. Never touches SQLite. */
static int ledger_seal_buffer(FsqlLedgerCtx *lc) {
    const char *key = ledger_key(lc);
    if (!key) return 0;                       /* no key => structural only */
    size_t keylen = strlen(key);
    for (int k = 1; k <= FSQL_LEDGER_MAX_KIND; k++) {
        FsqlLedgerSlot *s = &lc->slot[k];
        if (!s->have || s->tag_valid) continue;
        uint8_t tag[32];
        fsql_hmac_sha256((const uint8_t *)key, keylen,
                         s->payload, s->len, tag);
        memcpy(s->tag, tag, 32);
        s->tag_valid = 1;
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/* Storage VFS callbacks (host side — memory only, NO SQLite re-entry) */
/* ------------------------------------------------------------------ */

static int ledger_vfs_write_entry(fsql_storage_user_ctx user, int kind,
                                  const void *payload, size_t len) {
    FsqlLedgerCtx *lc = ledger_ctx_of(user);
    if (!lc) return FSQL_ESTORAGE;
    if (kind < 1 || kind > FSQL_LEDGER_MAX_KIND) return FSQL_ESTORAGE;
    if (ledger_slot_store(lc, kind, payload, len, NULL) != 0)
        return FSQL_ESTORAGE;
    return FSQL_OK;
}

static int ledger_vfs_read_entry(fsql_storage_user_ctx user, int kind,
                                 const void **payload_out, size_t *len_out) {
    FsqlLedgerCtx *lc = ledger_ctx_of(user);
    *payload_out = NULL;
    *len_out = 0;
    if (!lc) return FSQL_ESTORAGE;
    if (kind < 1 || kind > FSQL_LEDGER_MAX_KIND) return FSQL_ESTORAGE;
    const FsqlLedgerSlot *s = &lc->slot[kind];
    if (!s->have) return FSQL_ESTORAGE_UNAVAILABLE;   /* first load, empty */

    /* Envelope verification (see the file-header definition): a sealed
     * slot is re-verified against the LIVE key on every read. An
     * unsealed in-RAM slot (written this session, not yet sealed) is
     * trusted — nothing external can tamper with our own heap. */
    const char *key = ledger_key(lc);
    if (key && s->tag_valid) {
        uint8_t tag[32];
        fsql_hmac_sha256((const uint8_t *)key, strlen(key),
                         s->payload, s->len, tag);
        if (fsql_ct_memcmp(tag, s->tag, 32) != 0) return FSQL_ESTORAGE_INTEGRITY;
    }
    *payload_out = s->payload;
    *len_out = s->len;
    return FSQL_OK;
}

static int ledger_vfs_seal_ledger(fsql_storage_user_ctx user) {
    FsqlLedgerCtx *lc = ledger_ctx_of(user);
    if (!lc) return FSQL_ESTORAGE;
    /* Tags are recomputed at materialization time as well, so a seal
     * failure here (OOM) never fails teardown — the contract says seal
     * commits pending state, and the durable copy is written by the
     * top-level flush, not by this callback. */
    (void)ledger_seal_buffer(lc);
    return FSQL_OK;
}

/* ------------------------------------------------------------------ */
/* fsql_ledger_vfs_setup — called by fsql_state_create BEFORE           */
/* fsql_new_sovereign copies the VFS struct by value                   */
/* ------------------------------------------------------------------ */

int fsql_ledger_vfs_setup(FsqlState *st) {
    /* ONE calloc block for the context itself (never realloc'd or
     * split); the per-slot payload copies on top of it are released by
     * fsql_ledger_teardown at state destroy. */
    FsqlLedgerCtx *lc = (FsqlLedgerCtx *)calloc(1, sizeof(FsqlLedgerCtx));
    if (!lc) return -1;
    lc->magic = FSQL_LEDGER_CTX_MAGIC;
    lc->st = st;

    st->ledger_ctx = lc;
    st->storage_vfs.user_ctx = lc;
    st->storage_vfs.write_entry = ledger_vfs_write_entry;
    st->storage_vfs.read_entry = ledger_vfs_read_entry;
    st->storage_vfs.seal_ledger = ledger_vfs_seal_ledger;
    return 0;
}

/* fsql_ledger_teardown — fsql_state_destroy calls this INSTEAD of a
 * plain free(st->ledger_ctx), AFTER fsql_free(st->ctx) (which may
 * re-enter seal_ledger), so every slot payload is released before the
 * context block itself goes away. */
void fsql_ledger_teardown(FsqlState *st) {
    FsqlLedgerCtx *lc = ledger_ctx_of(st ? st->ledger_ctx : NULL);
    if (!lc) return;
    ledger_slots_clear_all(lc);
    lc->magic = 0;          /* canary down: no callback can reuse us */
    free(lc);
    st->ledger_ctx = NULL;
}

/* ------------------------------------------------------------------ */
/* Table IO (top-level SQL functions only)                             */
/* ------------------------------------------------------------------ */

/* Mandated DDL — the append-only hash chain (see the file header for
 * the full column-by-column rationale). */
static const char FSQL_LEDGER_DDL[] =
    "CREATE TABLE IF NOT EXISTS fractalsql_ledger("
    "id INTEGER PRIMARY KEY AUTOINCREMENT,"
    "kind INTEGER NOT NULL,"
    "payload BLOB NOT NULL,"
    "mac BLOB,"
    "prev_hash BLOB NOT NULL,"
    "entry_hash BLOB NOT NULL,"
    "sealed INTEGER NOT NULL DEFAULT 0,"
    "updated_at TEXT NOT NULL DEFAULT (datetime('now')))";

static const char FSQL_LEDGER_INDEX_DDL[] =
    "CREATE INDEX IF NOT EXISTS fractalsql_ledger_kind_id_idx "
    "ON fractalsql_ledger(kind, id DESC)";

/* Detect the OLD last-writer-wins snapshot shape this port used to ship
 * (kind INTEGER PRIMARY KEY, no id column) so ledger_ensure_table can
 * migrate it. PRAGMA table_info returns zero rows for a table that
 * doesn't exist (no error), so this one query covers both "fresh
 * install, nothing to migrate" (has_any=0) and "exists, old shape"
 * (has_any=1, has_id=0) in one query. */
static int ledger_table_is_old_shape(FsqlLedgerCtx *lc) {
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(lc->st->db, "PRAGMA table_info(fractalsql_ledger)",
                           -1, &stmt, NULL) != SQLITE_OK)
        return 0;   /* can't tell -- CREATE TABLE IF NOT EXISTS below is safe either way */
    int has_any = 0, has_id = 0;
    while (sqlite3_step(stmt) == SQLITE_ROW) {
        has_any = 1;
        const unsigned char *name = sqlite3_column_text(stmt, 1);  /* PRAGMA table_info: col 1 = name */
        if (name && strcmp((const char *)name, "id") == 0) has_id = 1;
    }
    sqlite3_finalize(stmt);
    return has_any && !has_id;
}

/* Ensure fractalsql_ledger exists in the new append-only chain shape,
 * migrating the old last-writer-wins snapshot first if that's what's
 * there. Nothing is worth preserving from the old shape -- it never
 * carried real history, one row per kind, last write wins -- so
 * migration is DROP + recreate fresh, not an in-place ALTER. A
 * brand-new install (no table at all) skips straight to CREATE TABLE.
 *
 * Deliberately re-verified on every call rather than cached after the
 * first success: the table is reachable through plain SQL (it is an
 * ordinary table, not something hidden behind the enterprise core), so
 * a caller can DROP it out from under a live connection -- the
 * documented way to start a genuinely fresh chain is exactly that. A
 * sticky "already ensured" flag would trust a table that no longer
 * exists and fail every subsequent ledger call with "no such table"
 * for the rest of the connection's life. The cost of re-checking is
 * one PRAGMA table_info plus two idempotent IF NOT EXISTS statements,
 * which is negligible next to the HMAC/chain-hash work flush/load/
 * verify already do around every call site below. */
static int ledger_ensure_table(FsqlLedgerCtx *lc, char *err, size_t err_cap) {
    char *emsg = NULL;
    int rc;

    if (ledger_table_is_old_shape(lc)) {
        rc = sqlite3_exec(lc->st->db, "DROP TABLE fractalsql_ledger", NULL, NULL, &emsg);
        if (rc != SQLITE_OK) {
            snprintf(err, err_cap, "fractalsql: cannot migrate fractalsql_ledger: %s",
                     emsg ? emsg : sqlite3_errmsg(lc->st->db));
            sqlite3_free(emsg);
            return -1;
        }
        sqlite3_free(emsg); emsg = NULL;
    }

    rc = sqlite3_exec(lc->st->db, FSQL_LEDGER_DDL, NULL, NULL, &emsg);
    if (rc != SQLITE_OK) {
        snprintf(err, err_cap, "fractalsql: cannot create fractalsql_ledger: %s",
                 emsg ? emsg : sqlite3_errmsg(lc->st->db));
        sqlite3_free(emsg);
        return -1;
    }
    sqlite3_free(emsg); emsg = NULL;

    rc = sqlite3_exec(lc->st->db, FSQL_LEDGER_INDEX_DDL, NULL, NULL, &emsg);
    if (rc != SQLITE_OK) {
        snprintf(err, err_cap, "fractalsql: cannot create fractalsql_ledger index: %s",
                 emsg ? emsg : sqlite3_errmsg(lc->st->db));
        sqlite3_free(emsg);
        return -1;
    }
    sqlite3_free(emsg);
    return 0;
}

static int ledger_tx_exec(FsqlLedgerCtx *lc, const char *sql,
                          char *err, size_t err_cap) {
    char *emsg = NULL;
    int rc = sqlite3_exec(lc->st->db, sql, NULL, NULL, &emsg);
    if (rc != SQLITE_OK) {
        snprintf(err, err_cap, "fractalsql: ledger %s failed: %s", sql,
                 emsg ? emsg : sqlite3_errmsg(lc->st->db));
        sqlite3_free(emsg);
        return -1;
    }
    sqlite3_free(emsg);
    return 0;
}

/* Read entry_hash of the latest row for `kind` into prev_hash[32]; the
 * all-zero genesis sentinel when this kind has no rows yet. Caller must
 * already hold the write transaction (see ledger_chain_insert). */
static int ledger_chain_read_prev(FsqlLedgerCtx *lc, int kind,
                                  uint8_t prev_hash[32],
                                  char *err, size_t err_cap) {
    memset(prev_hash, 0, 32);
    static const char SQL[] =
        "SELECT entry_hash FROM fractalsql_ledger "
        "WHERE kind=?1 ORDER BY id DESC LIMIT 1";
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(lc->st->db, SQL, -1, &stmt, NULL) != SQLITE_OK) {
        snprintf(err, err_cap, "fractalsql: ledger prev_hash read prepare failed: %s",
                 sqlite3_errmsg(lc->st->db));
        return -1;
    }
    sqlite3_bind_int(stmt, 1, kind);
    int rc = sqlite3_step(stmt);
    if (rc == SQLITE_ROW) {
        const void *h = sqlite3_column_blob(stmt, 0);
        int hlen = sqlite3_column_bytes(stmt, 0);
        if (h && hlen == 32) memcpy(prev_hash, h, 32);
    } else if (rc != SQLITE_DONE) {
        sqlite3_finalize(stmt);
        snprintf(err, err_cap, "fractalsql: ledger prev_hash read failed: %s",
                 sqlite3_errmsg(lc->st->db));
        return -1;
    }
    sqlite3_finalize(stmt);
    return 0;
}

/* Append one row to `kind`'s chain:
 *   prev_hash  = the latest row's entry_hash for this kind, or the
 *                genesis sentinel (all-zero) when there isn't one yet.
 *   mac        = HMAC-SHA256(key, payload) when enterprise_ledger_key is
 *                configured, else absent (NULL column).
 *   entry_hash = SHA256(prev_hash || payload || mac), computed
 *                UNCONDITIONALLY -- even with no key configured -- so
 *                every row's structural integrity and ordering is
 *                independently verifiable without a key.
 * Plain INSERT, never INSERT OR REPLACE/upsert -- append-only; `id`
 * autoincrements and a later DELETE leaves a visible gap in it. Caller
 * must already hold the write transaction (BEGIN IMMEDIATE, taken by
 * ledger_materialize / the audit_log write path -- see the file header
 * for why that lock is needed here). */
static int ledger_chain_insert(FsqlLedgerCtx *lc, int kind,
                               const void *payload, size_t len,
                               char *err, size_t err_cap) {
    uint8_t prev_hash[32];
    if (ledger_chain_read_prev(lc, kind, prev_hash, err, err_cap) != 0)
        return -1;

    const char *key = ledger_key(lc);
    uint8_t mac[32];
    int have_mac = 0;
    if (key) {
        fsql_hmac_sha256((const uint8_t *)key, strlen(key),
                         (const uint8_t *)payload, len, mac);
        have_mac = 1;
    }

    uint8_t entry_hash[32];
    {
        size_t buflen = 32 + len + (have_mac ? 32 : 0);
        uint8_t *buf = (uint8_t *)malloc(buflen ? buflen : 1);
        if (!buf) {
            snprintf(err, err_cap, "fractalsql: out of memory computing entry_hash");
            return -1;
        }
        memcpy(buf, prev_hash, 32);
        if (len) memcpy(buf + 32, payload, len);
        if (have_mac) memcpy(buf + 32 + len, mac, 32);
        fsql_sha256(buf, buflen, entry_hash);
        free(buf);
    }

    static const char SQL[] =
        "INSERT INTO fractalsql_ledger"
        "(kind, payload, mac, prev_hash, entry_hash, sealed, updated_at) "
        "VALUES(?1, ?2, ?3, ?4, ?5, 0, datetime('now'))";
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(lc->st->db, SQL, -1, &stmt, NULL) != SQLITE_OK) {
        snprintf(err, err_cap, "fractalsql: ledger insert prepare failed: %s",
                 sqlite3_errmsg(lc->st->db));
        return -1;
    }
    /* Every bound value outlives the step (slot memory / stack buffers),
     * so SQLITE_STATIC is safe. */
    if (len > 0x7fffffffu) {
        /* sqlite3_bind_blob takes an int length; a size_t >= 2^31 would
         * truncate to a negative n, which SQLite reads as a
         * NUL-terminated string (strlen over binary bytes). Fail the
         * write instead. */
        snprintf(err, err_cap,
                 "fractalsql: ledger payload too large to persist (%zu bytes)",
                 len);
        return -1;
    }
    sqlite3_bind_int(stmt, 1, kind);
    sqlite3_bind_blob(stmt, 2, payload, (int)len, SQLITE_STATIC);
    if (have_mac) sqlite3_bind_blob(stmt, 3, mac, 32, SQLITE_STATIC);
    else          sqlite3_bind_null(stmt, 3);
    sqlite3_bind_blob(stmt, 4, prev_hash, 32, SQLITE_STATIC);
    sqlite3_bind_blob(stmt, 5, entry_hash, 32, SQLITE_STATIC);

    int rc = sqlite3_step(stmt);
    sqlite3_finalize(stmt);
    if (rc != SQLITE_DONE) {
        snprintf(err, err_cap, "fractalsql: ledger insert failed: %s",
                 sqlite3_errmsg(lc->st->db));
        return -1;
    }
    return 0;
}

/* Materialize the buffer into the table: one APPEND row per occupied
 * slot, each linked into its kind's chain, inside a single transaction.
 * Seals untagged slots first so the envelope covers the exact bytes
 * being persisted.
 *
 * BEGIN IMMEDIATE grabs the database's one RESERVED write lock up
 * front -- before ensure_table, before any read -- so no other
 * connection can race a concurrent flush/migration/audit_log write into
 * the middle of this "read latest, link, insert" sequence. This blocks
 * ALL kinds for the duration, not just the ones being written here, but
 * SQLite only ever has one writer at a time regardless, so the extra
 * breadth costs nothing. */
static int ledger_materialize(FsqlLedgerCtx *lc, char *err, size_t err_cap) {
    if (ledger_seal_buffer(lc) != 0) {
        snprintf(err, err_cap, "fractalsql: out of memory sealing the ledger");
        return -1;
    }
    if (ledger_tx_exec(lc, "BEGIN IMMEDIATE", err, err_cap) != 0)
        return -1;
    if (ledger_ensure_table(lc, err, err_cap) != 0) {
        ledger_tx_exec(lc, "ROLLBACK", err, err_cap);
        return -1;
    }
    for (int k = 1; k <= FSQL_LEDGER_MAX_KIND; k++) {
        const FsqlLedgerSlot *s = &lc->slot[k];
        if (!s->have) continue;
        if (ledger_chain_insert(lc, k, s->payload, s->len, err, err_cap) != 0) {
            ledger_tx_exec(lc, "ROLLBACK", err, err_cap);
            return -1;
        }
    }
    if (ledger_tx_exec(lc, "COMMIT", err, err_cap) != 0)
        return -1;
    return 0;
}

/* ------------------------------------------------------------------ */
/* Error mapping + shared wrappers                                     */
/* ------------------------------------------------------------------ */

/* Core error code -> readable clause. */
static const char *ledger_rc_message(int rc) {
    switch (rc) {
    case FSQL_OK:                   return "ok";
    case FSQL_ERR_INVALID:          return "invalid argument";
    case FSQL_ERR_OOM:              return "out of memory";
    case FSQL_ERR_RUNTIME:          return "engine runtime failure";
    case FSQL_ESTORAGE:             return "storage VFS failure";
    case FSQL_ESTORAGE_UNAVAILABLE: return "no persisted ledger yet";
    case FSQL_ESTORAGE_INTEGRITY:
    case FSQL_ELEDGER_INTEGRITY:    return "ledger integrity check failed";
    case FSQL_EDIVERSITY:           return "diversify state error";
    case FSQL_EENTROPY:             return "entropy source error";
    case FSQL_ELEDGER_FULL:         return "ledger full (eviction failed)";
    case FSQL_ELEDGER_IO:           return "ledger storage IO error";
    default:                        return "core error";
    }
}

/* Uniform failure for the core-call wrappers. */
static void ledger_core_error(sqlite3_context *sctx, FsqlState *st,
                              const char *api, int rc) {
    const char *detail = fsql_last_error(st->ctx);
    char msg[320];
    snprintf(msg, sizeof msg, "fractalsql: %s failed (rc=%d, %s)%s%s",
             api, rc, ledger_rc_message(rc),
             (detail && *detail) ? ": " : "",
             (detail && *detail) ? detail : "");
    sqlite3_result_error(sctx, msg, -1);
}

static FsqlState *ledger_state_of(sqlite3_context *sctx) {
    FsqlState *st = (FsqlState *)sqlite3_user_data(sctx);
    if (!st || !st->ctx) {
        sqlite3_result_error(sctx, "fractalsql: not initialized", -1);
        return NULL;
    }
    return st;
}

/* Enterprise gate for the whole ledger/audit surface: the core
 * fsql_ledger_* / fsql_audit_unpack symbols live only in the dlopen'd
 * enterprise library (see fsql_enterprise.c for the link proof against
 * the community archive). On failure the SQL error is already set and
 * the caller returns. */
static int ledger_ensure_ent(FsqlState *st, sqlite3_context *sctx) {
    char err[256];
    if (fsql_enterprise_ensure(st, err, sizeof err) != 1) {
        sqlite3_result_error(sctx, err, -1);
        return -1;
    }
    return 0;
}

/* O(1) load-time check (storage seam). Before the enterprise core
 * decodes the persisted blob, verify only the
 * LATEST row for `kind`: its entry_hash recomputes correctly from its own
 * payload/mac (structural integrity, unconditional -- no key required),
 * its MAC checks out when a key is configured, and its prev_hash matches
 * the entry_hash of the row immediately before it (the chain link to the
 * rest of history is intact) -- or, for a lone (genesis) row, prev_hash
 * is the all-zero sentinel. Intentionally O(1), NOT a full chain walk:
 * catches "the current row was tampered" plus "the row right before this
 * one was rewritten or deleted," but not tampering further back in
 * history -- that is fractal_ledger_verify()'s job (O(n), on demand).
 * No rows yet => nothing to verify, empty start (returns 0). On failure,
 * writes a message into err and returns -1; caller surfaces it as the SQL
 * error from fractal_ledger_load. */
static int ledger_verify_tip(FsqlLedgerCtx *lc, int kind,
                             char *err, size_t err_cap) {
    static const char SQL[] =
        "SELECT payload, mac, prev_hash, entry_hash FROM fractalsql_ledger "
        "WHERE kind=?1 ORDER BY id DESC LIMIT 2";
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(lc->st->db, SQL, -1, &stmt, NULL) != SQLITE_OK) {
        snprintf(err, err_cap, "fractalsql: ledger tip verify prepare failed: %s",
                 sqlite3_errmsg(lc->st->db));
        return -1;
    }
    sqlite3_bind_int(stmt, 1, kind);

    int rc = sqlite3_step(stmt);
    if (rc == SQLITE_DONE) { sqlite3_finalize(stmt); return 0; }   /* no rows yet -- empty start */
    if (rc != SQLITE_ROW) {
        sqlite3_finalize(stmt);
        snprintf(err, err_cap, "fractalsql: ledger tip verify read failed: %s",
                 sqlite3_errmsg(lc->st->db));
        return -1;
    }

    const void *payload = sqlite3_column_blob(stmt, 0);
    int plen = sqlite3_column_bytes(stmt, 0);
    size_t payload_len = (size_t)(plen > 0 ? plen : 0);
    int mac_null = (sqlite3_column_type(stmt, 1) == SQLITE_NULL);
    const void *mac_blob = sqlite3_column_blob(stmt, 1);
    int mac_len = sqlite3_column_bytes(stmt, 1);
    const void *prev_blob = sqlite3_column_blob(stmt, 2);
    int prev_len = sqlite3_column_bytes(stmt, 2);
    const void *hash_blob = sqlite3_column_blob(stmt, 3);
    int hash_len = sqlite3_column_bytes(stmt, 3);

    if (prev_len != 32 || hash_len != 32) {
        sqlite3_finalize(stmt);
        snprintf(err, err_cap,
            "fractalsql: fractal_ledger_load: ledger chain verification "
            "failed -- stored prev_hash/entry_hash is not 32 bytes");
        return -1;
    }

    const char *key = ledger_key(lc);
    int require_mac = key != NULL;

    if (require_mac && mac_null) {
        sqlite3_finalize(stmt);
        snprintf(err, err_cap,
            "fractalsql: fractal_ledger_load: ledger MAC verification "
            "failed -- the persisted blob has no MAC (written before "
            "enterprise_ledger_key was set); re-flush with the key "
            "configured, or unset the key for structural-only validation");
        return -1;
    }

    uint8_t mac_bytes[32];
    int have_mac = !mac_null;
    if (have_mac) {
        if (mac_len != 32) {
            sqlite3_finalize(stmt);
            snprintf(err, err_cap,
                "fractalsql: fractal_ledger_load: ledger MAC verification "
                "failed -- stored MAC is %d bytes, expected 32", mac_len);
            return -1;
        }
        memcpy(mac_bytes, mac_blob, 32);
        if (require_mac) {
            uint8_t tag[32];
            fsql_hmac_sha256((const uint8_t *)key, strlen(key),
                             payload, payload_len, tag);
            if (fsql_ct_memcmp(tag, mac_bytes, 32) != 0) {
                sqlite3_finalize(stmt);
                snprintf(err, err_cap,
                    "fractalsql: fractal_ledger_load: ledger MAC verification "
                    "failed -- the persisted QTL blob is tampered (HMAC "
                    "mismatch); set enterprise_ledger_key to the key used at "
                    "flush, or re-flush to re-tag it");
                return -1;
            }
        }
    }

    uint8_t prev_hash[32], entry_hash[32];
    memcpy(prev_hash, prev_blob, 32);
    memcpy(entry_hash, hash_blob, 32);

    uint8_t recomputed[32];
    {
        size_t buflen = 32 + payload_len + (have_mac ? 32 : 0);
        uint8_t *buf = (uint8_t *)malloc(buflen ? buflen : 1);
        if (!buf) {
            sqlite3_finalize(stmt);
            snprintf(err, err_cap, "fractalsql: out of memory verifying the ledger");
            return -1;
        }
        memcpy(buf, prev_hash, 32);
        if (payload_len) memcpy(buf + 32, payload, payload_len);
        if (have_mac) memcpy(buf + 32 + payload_len, mac_bytes, 32);
        fsql_sha256(buf, buflen, recomputed);
        free(buf);
    }
    if (memcmp(recomputed, entry_hash, 32) != 0) {
        sqlite3_finalize(stmt);
        snprintf(err, err_cap,
            "fractalsql: fractal_ledger_load: ledger chain verification "
            "failed -- the latest entry's hash does not match its stored "
            "payload/mac (structural tamper, independent of any MAC key); "
            "run fractal_ledger_verify() to locate exactly where the chain "
            "diverges, or re-flush to start a fresh chain");
        return -1;
    }

    /* Chain-link check against the row immediately before this one, if
     * any; a lone (genesis) row instead requires the all-zero sentinel. */
    rc = sqlite3_step(stmt);
    if (rc == SQLITE_ROW) {
        const void *prior_hash = sqlite3_column_blob(stmt, 3);
        int prior_hash_len = sqlite3_column_bytes(stmt, 3);
        if (prior_hash_len != 32 || memcmp(prev_hash, prior_hash, 32) != 0) {
            sqlite3_finalize(stmt);
            snprintf(err, err_cap,
                "fractalsql: fractal_ledger_load: ledger chain verification "
                "failed -- the latest entry's prev_hash does not match its "
                "predecessor's entry_hash (a row was rewritten, reordered, "
                "or deleted); run fractal_ledger_verify() to locate exactly "
                "where the chain diverges");
            return -1;
        }
    } else {
        uint8_t zero[32];
        memset(zero, 0, 32);
        if (memcmp(prev_hash, zero, 32) != 0) {
            sqlite3_finalize(stmt);
            snprintf(err, err_cap,
                "fractalsql: fractal_ledger_load: ledger chain verification "
                "failed -- the sole entry's prev_hash is not the genesis "
                "sentinel (an earlier row was deleted); run "
                "fractal_ledger_verify() to locate exactly where the chain "
                "diverges");
            return -1;
        }
    }

    sqlite3_finalize(stmt);
    return 0;
}

/* ------------------------------------------------------------------ */
/* fractal_ledger_flush / load / compact / reset_soft / reset_hard     */
/* fractal_ledger_truth_count / shadow_count                           */
/* ------------------------------------------------------------------ */

/* flush(): core flush (drives write_entry into the buffer), then
 * materialize the buffer into fractalsql_ledger in one transaction. */
static void ledger_flush_fn(sqlite3_context *sctx, int argc,
                            sqlite3_value **argv) {
    (void)argc; (void)argv;
    FsqlState *st = ledger_state_of(sctx);
    if (!st) return;
    if (ledger_ensure_ent(st, sctx) != 0) return;
    FsqlLedgerCtx *lc = ledger_ctx_of(st->ledger_ctx);
    if (!lc) {
        sqlite3_result_error(sctx, "fractalsql: ledger context invalid", -1);
        return;
    }

    int rc = st->ent.ledger_flush(st->ctx);
    if (rc != FSQL_OK) { ledger_core_error(sctx, st, "fsql_ledger_flush", rc); return; }

    char err[256] = "";
    if (ledger_materialize(lc, err, sizeof err) != 0) {
        sqlite3_result_error(sctx, err, -1);
        return;
    }
    sqlite3_result_text(sctx, "ok", -1, SQLITE_STATIC);
}

/* load(): clear the buffer, authenticate + seed it from the table
 * (HMAC verification happens per the envelope contract; read_entry
 * re-verifies sealed slots when the core pulls them back), then let the
 * core decode. FSQL_ESTORAGE_UNAVAILABLE (no persisted ledger yet) is
 * NOT an error: the ledger simply starts empty. */
static void ledger_load_fn(sqlite3_context *sctx, int argc,
                           sqlite3_value **argv) {
    (void)argc; (void)argv;
    FsqlState *st = ledger_state_of(sctx);
    if (!st) return;
    if (ledger_ensure_ent(st, sctx) != 0) return;
    FsqlLedgerCtx *lc = ledger_ctx_of(st->ledger_ctx);
    if (!lc) {
        sqlite3_result_error(sctx, "fractalsql: ledger context invalid", -1);
        return;
    }

    /* 384, not the usual 256: ledger_verify_tip's chain-link/tamper
     * messages (below) run longer than this file's other error paths. */
    char err[384] = "";
    if (ledger_ensure_table(lc, err, sizeof err) != 0) {
        sqlite3_result_error(sctx, err, -1);
        return;
    }

    /* O(1) tip verify BEFORE the core ever sees a byte: kind=1 is the
     * QTL Truth/Shadow stream fractal_ledger_load is about to decode. */
    if (ledger_verify_tip(lc, 1, err, sizeof err) != 0) {
        sqlite3_result_error(sctx, err, -1);
        return;
    }

    /* Seed the buffer from the LATEST row per kind (the chain may hold
     * many historical rows per kind; the core only ever wants "the
     * current blob," same as ledger_vfs_read_entry's contract). */
    static const char SQL[] =
        "SELECT kind, payload, mac FROM ("
        "  SELECT kind, payload, mac,"
        "         ROW_NUMBER() OVER (PARTITION BY kind ORDER BY id DESC) AS rn"
        "  FROM fractalsql_ledger"
        ") WHERE rn = 1";
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(st->db, SQL, -1, &stmt, NULL) != SQLITE_OK) {
        snprintf(err, sizeof err, "fractalsql: ledger read prepare failed: %s",
                 sqlite3_errmsg(st->db));
        sqlite3_result_error(sctx, err, -1);
        return;
    }

    const char *key = ledger_key(lc);
    size_t keylen = key ? strlen(key) : 0;
    int failed = 0;

    ledger_slots_clear_all(lc);   /* stale in-RAM blobs never survive a load */

    while (!failed && sqlite3_step(stmt) == SQLITE_ROW) {
        int kind = sqlite3_column_int(stmt, 0);
        if (kind < 1 || kind > FSQL_LEDGER_MAX_KIND)
            continue;   /* not a core ledger slot (future/foreign row) */

        const void *payload = sqlite3_column_blob(stmt, 1);
        int plen = sqlite3_column_bytes(stmt, 1);
        const void *mac = sqlite3_column_blob(stmt, 2);
        int mlen = sqlite3_column_bytes(stmt, 2);
        int mac_null = (sqlite3_column_type(stmt, 2) == SQLITE_NULL);

        /* A non-NULL mac that is not exactly 32 bytes can never be a
         * valid tag, and ledger_slot_store would memcpy 32 bytes out of
         * it regardless of its real length. This holds with or without
         * a key configured, so the check lives outside the `if (key)`
         * block. */
        if (!mac_null && mlen != 32) {
            snprintf(err, sizeof err,
                "fractalsql: fractal_ledger_load: ledger MAC verification "
                "failed -- stored MAC is %d bytes, expected 32",
                mlen);
            failed = 1;
            break;
        }
        if (key) {
            /* A configured key requires an authenticated blob — refuse
             * one persisted before the key was set. */
            if (mac_null) {
                snprintf(err, sizeof err,
                    "fractalsql: fractal_ledger_load: ledger MAC verification "
                    "failed -- the persisted blob has no MAC (written before "
                    "enterprise_ledger_key was set); re-flush with the key "
                    "configured, or unset the key for structural-only "
                    "validation");
                failed = 1;
                break;
            }
            uint8_t tag[32];
            fsql_hmac_sha256((const uint8_t *)key, keylen,
                             payload, (size_t)(plen > 0 ? plen : 0), tag);
            if (fsql_ct_memcmp(tag, mac, 32) != 0) {
                snprintf(err, sizeof err,
                    "fractalsql: fractal_ledger_load: ledger MAC verification "
                    "failed -- the persisted QTL blob is tampered (HMAC "
                    "mismatch); set enterprise_ledger_key to the key used at "
                    "flush, or re-flush to re-tag it");
                failed = 1;
                break;
            }
        }
        /* No key configured: accept rows regardless of a stale (but
         * well-formed, 32-byte) tag — verification is impossible
         * without the key (historical structural-only behavior). */

        if (ledger_slot_store(lc, kind, payload,
                              (size_t)(plen > 0 ? plen : 0),
                              mac_null ? NULL : (const uint8_t *)mac) != 0) {
            snprintf(err, sizeof err, "fractalsql: out of memory loading the ledger");
            failed = 1;
            break;
        }
    }
    sqlite3_finalize(stmt);
    if (failed) {
        ledger_slots_clear_all(lc);
        sqlite3_result_error(sctx, err, -1);
        return;
    }

    int rc = st->ent.ledger_load(st->ctx);
    if (rc != FSQL_OK && rc != FSQL_ESTORAGE_UNAVAILABLE) {
        ledger_slots_clear_all(lc);
        ledger_core_error(sctx, st, "fsql_ledger_load", rc);
        return;
    }
    sqlite3_result_text(sctx, "ok", -1, SQLITE_STATIC);
}

/* Shared body for compact / reset_soft / reset_hard: call the core, then
 * drop the matching host-side buffer slots so a later load without an
 * intervening flush cannot resurrect the pre-reset ledger from RAM.
 * min_kind 0 clears every slot; otherwise only kinds >= min_kind
 * (reset_soft clears the Shadow slots, 2=shadow and 3=shadow_vectors,
 * and preserves the Truth slot, matching the core's own soft-reset
 * contract). */
static void ledger_reset_common(sqlite3_context *sctx,
                                int (*core_call)(fsql_ctx *),
                                const char *api, int min_kind) {
    FsqlState *st = ledger_state_of(sctx);
    if (!st) return;
    FsqlLedgerCtx *lc = ledger_ctx_of(st->ledger_ctx);
    if (!lc) {
        sqlite3_result_error(sctx, "fractalsql: ledger context invalid", -1);
        return;
    }
    int rc = core_call(st->ctx);
    if (rc != FSQL_OK) { ledger_core_error(sctx, st, api, rc); return; }
    for (int k = min_kind < 1 ? 1 : min_kind; k <= FSQL_LEDGER_MAX_KIND; k++)
        ledger_slot_clear(&lc->slot[k]);
    sqlite3_result_text(sctx, "ok", -1, SQLITE_STATIC);
}

static void ledger_compact_fn(sqlite3_context *sctx, int argc,
                              sqlite3_value **argv) {
    (void)argc; (void)argv;
    FsqlState *st = ledger_state_of(sctx);
    if (!st) return;
    if (ledger_ensure_ent(st, sctx) != 0) return;
    /* Compact drops decayed/evicted shadow entries — no slot clearing
     * (the surviving blob stays authoritative). */
    ledger_reset_common(sctx, st->ent.ledger_compact, "fsql_ledger_compact", -1);
}

static void ledger_reset_soft_fn(sqlite3_context *sctx, int argc,
                                 sqlite3_value **argv) {
    (void)argc; (void)argv;
    FsqlState *st = ledger_state_of(sctx);
    if (!st) return;
    if (ledger_ensure_ent(st, sctx) != 0) return;
    ledger_reset_common(sctx, st->ent.ledger_reset_soft,
                        "fsql_ledger_reset_soft",
                        2 /* preserve kind=1 Truth slot */);
}

static void ledger_reset_hard_fn(sqlite3_context *sctx, int argc,
                                 sqlite3_value **argv) {
    (void)argc; (void)argv;
    FsqlState *st = ledger_state_of(sctx);
    if (!st) return;
    if (ledger_ensure_ent(st, sctx) != 0) return;
    ledger_reset_common(sctx, st->ent.ledger_reset_hard,
                        "fsql_ledger_reset_hard",
                        0 /* clear every slot */);
}

typedef int (*ledger_count_fn)(const fsql_ctx *, size_t *);

static void ledger_count_fn_wrap(sqlite3_context *sctx, int argc,
                                 sqlite3_value **argv,
                                 ledger_count_fn core_call, const char *api) {
    (void)argc; (void)argv;
    FsqlState *st = ledger_state_of(sctx);
    if (!st) return;
    size_t n = 0;
    int rc = core_call(st->ctx, &n);
    if (rc != FSQL_OK) { ledger_core_error(sctx, st, api, rc); return; }
    sqlite3_result_int64(sctx, (sqlite3_int64)n);
}

static void ledger_truth_count_fn(sqlite3_context *sctx, int argc,
                                  sqlite3_value **argv) {
    FsqlState *st = ledger_state_of(sctx);
    if (!st) return;
    if (ledger_ensure_ent(st, sctx) != 0) return;
    ledger_count_fn_wrap(sctx, argc, argv, st->ent.ledger_truth_count,
                         "fsql_ledger_truth_count");
}

static void ledger_shadow_count_fn(sqlite3_context *sctx, int argc,
                                   sqlite3_value **argv) {
    FsqlState *st = ledger_state_of(sctx);
    if (!st) return;
    if (ledger_ensure_ent(st, sctx) != 0) return;
    ledger_count_fn_wrap(sctx, argc, argv, st->ent.ledger_shadow_count,
                         "fsql_ledger_shadow_count");
}

/* ------------------------------------------------------------------ */
/* fractal_audit_unpack(blob) -> TEXT (JSON)                           */
/* ------------------------------------------------------------------ */

/* Pattern A growing-buffer contract (fractalsql_sql.h): call once with a
 * stack buffer; on FSQL_ETRUNCATED *json_cap reports the required size —
 * retry on the heap, growing until it fits (bounded). */
static void ledger_audit_unpack_fn(sqlite3_context *sctx, int argc,
                                   sqlite3_value **argv) {
    (void)argc;
    FsqlState *st = ledger_state_of(sctx);
    if (!st) return;
    if (ledger_ensure_ent(st, sctx) != 0) return;
    if (sqlite3_value_type(argv[0]) == SQLITE_NULL) {
        sqlite3_result_null(sctx);          /* NULL in, NULL out */
        return;
    }
    const void *blob = sqlite3_value_blob(argv[0]);
    int nbytes = sqlite3_value_bytes(argv[0]);
    size_t blob_len = (nbytes > 0) ? (size_t)nbytes : 0;
    if (!blob) blob = "";

    char stackbuf[FSQL_AUDIT_START_CAP + 1];
    char *heap = NULL;
    char *buf = stackbuf;
    size_t cap = FSQL_AUDIT_START_CAP;
    size_t need = cap;
    int rc = st->ent.audit_unpack(blob, blob_len, buf, &need);

    while (rc == FSQL_ETRUNCATED) {
        size_t next = (need > cap) ? need : (cap * 2);
        if (next <= cap || next > FSQL_AUDIT_MAX_CAP) {
            rc = FSQL_ERR_OOM;   /* no progress or absurd requirement */
            break;
        }
        cap = next;
        free(heap);
        heap = (char *)malloc(cap + 1);   /* +1 slack for the NUL */
        if (!heap) { rc = FSQL_ERR_OOM; break; }
        buf = heap;
        need = cap;
        rc = st->ent.audit_unpack(blob, blob_len, buf, &need);
    }
    if (rc != FSQL_OK) {
        free(heap);
        char msg[160];
        snprintf(msg, sizeof msg, "fractalsql: fsql_audit_unpack failed (rc=%d, %s)",
                 rc, ledger_rc_message(rc));
        sqlite3_result_error(sctx, msg, -1);
        return;
    }

    /* Success still trusts the core's reported length for the NUL write:
     * a contract-violating core (or a version mismatch) that returns
     * FSQL_OK with *json_cap > cap would write past the buffer here.
     * Conforming cores per fractalsql_sql.h never do this. */
    if (need > cap) {
        free(heap);
        sqlite3_result_error(sctx,
            "fractalsql: fsql_audit_unpack reported an out-of-range "
            "length -- refusing the result", -1);
        return;
    }

    buf[need] = '\0';   /* the +1 slack guarantees room on every path */
    if (heap) {
        sqlite3_result_text(sctx, heap, (int)need, free);
    } else {
        sqlite3_result_text(sctx, stackbuf, (int)need, SQLITE_TRANSIENT);
    }
}

/* ------------------------------------------------------------------ */
/* fractal_audit_log(entry_type, payload)                              */
/* ------------------------------------------------------------------ */

/* Escape a string as a JSON string literal (RFC 8259: the two mandatory
 * escapes plus the short control-character forms). Returns a malloc'd
 * literal WITHOUT the surrounding quotes included in the write below —
 * the caller wraps it. NULL on OOM. */
static char *ledger_json_escape(const char *s) {
    size_t n = strlen(s);
    /* worst case: every byte becomes \u00XX (6 bytes) */
    char *out = (char *)malloc(n * 6 + 1);
    if (!out) return NULL;
    char *w = out;
    for (size_t i = 0; i < n; i++) {
        unsigned char c = (unsigned char)s[i];
        switch (c) {
        case '"':  *w++ = '\\'; *w++ = '"';  break;
        case '\\': *w++ = '\\'; *w++ = '\\'; break;
        case '\b': *w++ = '\\'; *w++ = 'b';  break;
        case '\f': *w++ = '\\'; *w++ = 'f';  break;
        case '\n': *w++ = '\\'; *w++ = 'n';  break;
        case '\r': *w++ = '\\'; *w++ = 'r';  break;
        case '\t': *w++ = '\\'; *w++ = 't';  break;
        default:
            if (c < 0x20) {
                static const char HEX[] = "0123456789abcdef";
                *w++ = '\\'; *w++ = 'u'; *w++ = '0'; *w++ = '0';
                *w++ = HEX[(c >> 4) & 0xf];
                *w++ = HEX[c & 0xf];
            } else {
                *w++ = (char)c;
            }
        }
    }
    *w = '\0';
    return out;
}

/* fractal_audit_log(entry_type TEXT, payload TEXT) — append a
 * provenance record to the general decision-audit chain (kind=2, an
 * independent chain alongside kind=1's QTL blobs, same table, same
 * append-only machinery — see ledger_chain_insert). The record is NOT
 * QTL-encoded — just JSON: {"type": entry_type, "entry": payload}.
 * Query back directly:
 *   SELECT id, payload, updated_at FROM fractalsql_ledger
 *    WHERE kind = 2 ORDER BY id;
 * or walk/verify it with fractal_ledger_verify(2).
 *
 * Each kind is its own chain (WHERE kind=? throughout), so a core write
 * on kind=2 (Shadow) and an audit_log write never collide the way they
 * could under the old last-writer-wins snapshot — every write appends
 * its own row, linked into its own kind's chain.
 *
 * Enterprise-gated: unlike fractal_ledger_verify, this is a WRITE into
 * the audit trail, not a read-only forensic query, so it carries the
 * same license gate as the rest of the ledger surface.
 *
 * NULL args are a no-op (NULL result). The payload is stored verbatim
 * (SQLite has no jsonb to normalize it into). */
static void ledger_audit_log_fn(sqlite3_context *sctx, int argc,
                                sqlite3_value **argv) {
    (void)argc;
    FsqlState *st = ledger_state_of(sctx);
    if (!st) return;
    if (ledger_ensure_ent(st, sctx) != 0) return;
    FsqlLedgerCtx *lc = ledger_ctx_of(st->ledger_ctx);
    if (!lc) {
        sqlite3_result_error(sctx, "fractalsql: ledger context invalid", -1);
        return;
    }
    if (sqlite3_value_type(argv[0]) == SQLITE_NULL ||
        sqlite3_value_type(argv[1]) == SQLITE_NULL) {
        sqlite3_result_null(sctx);          /* NULL in, no-op */
        return;
    }
    if (sqlite3_value_type(argv[0]) != SQLITE_TEXT ||
        sqlite3_value_type(argv[1]) != SQLITE_TEXT) {
        sqlite3_result_error(sctx,
            "fractal_audit_log(entry_type, payload) expects 2 TEXT args "
            "(payload is a JSON object/text)", -1);
        return;
    }
    const char *entry_type = (const char *)sqlite3_value_text(argv[0]);
    const char *payload    = (const char *)sqlite3_value_text(argv[1]);
    if (!entry_type || !payload) {
        sqlite3_result_null(sctx);
        return;
    }

    char *etype = ledger_json_escape(entry_type);
    if (!etype) {
        sqlite3_result_error(sctx, "fractalsql: out of memory", -1);
        return;
    }
    size_t plen = strlen(payload);
    /* {"type":"E","entry":P} — the literal carries empty E/P plus its
     * NUL; grow by the actual E/P lengths. */
    size_t js_len = sizeof("{\"type\":\"\",\"entry\":}") + strlen(etype) + plen;
    char *js = (char *)malloc(js_len);
    if (!js) {
        free(etype);
        sqlite3_result_error(sctx, "fractalsql: out of memory", -1);
        return;
    }
    snprintf(js, js_len, "{\"type\":\"%s\",\"entry\":%s}", etype, payload);
    free(etype);

    /* Same BEGIN IMMEDIATE substitution as ledger_materialize (see its
     * comment / the file header): grab the write lock before ensure_table
     * or the chain's read-latest-then-insert sequence, so this append
     * can't race a concurrent flush/audit_log write. */
    char err[256] = "";
    if (ledger_tx_exec(lc, "BEGIN IMMEDIATE", err, sizeof err) != 0) {
        free(js);
        sqlite3_result_error(sctx, err, -1);
        return;
    }
    if (ledger_ensure_table(lc, err, sizeof err) != 0 ||
        ledger_chain_insert(lc, 2, js, strlen(js), err, sizeof err) != 0) {
        ledger_tx_exec(lc, "ROLLBACK", err, sizeof err);
        free(js);
        sqlite3_result_error(sctx, err, -1);
        return;
    }
    free(js);
    if (ledger_tx_exec(lc, "COMMIT", err, sizeof err) != 0) {
        sqlite3_result_error(sctx, err, -1);
        return;
    }
    sqlite3_result_text(sctx, "ok", -1, SQLITE_STATIC);
}

/* ------------------------------------------------------------------ */
/* fractal_ledger_verify([kind]) -> TEXT (JSON)                        */
/* ------------------------------------------------------------------ */

/* Full-chain audit (storage seam, O(n)). Unlike ledger_verify_tip
 * (called on every fractal_ledger_load, O(1), tip-only), this walks
 * the ENTIRE persisted chain for `kind`: every entry_hash recomputes
 * from its own (prev_hash, payload, mac), every prev_hash matches its
 * predecessor's entry_hash, and the id sequence has no gaps (a gap
 * means a row was deleted). Stops and reports the FIRST failure only.
 *
 * A pure read-only forensic query directly over the SQLite table — does
 * NOT call ledger_ensure_ent / touch the enterprise core at all, so it
 * works even when the enterprise library isn't currently loaded.
 * Returns a JSON report rather than raising on a tamper finding,
 * since a caller running this wants a diagnosis, not a thrown error;
 * setup failures (can't create/read the table) still raise a SQL error,
 * same convention as the rest of this file.
 *
 * Registered at both 0 and 1 args: NULL/omitted kind defaults to 1 (the
 * QTL Truth/Shadow stream); kind=2 walks the fractal_audit_log stream
 * independently — each kind is a separate chain (WHERE kind=? below). */
static void ledger_verify_fn(sqlite3_context *sctx, int argc,
                             sqlite3_value **argv) {
    FsqlState *st = ledger_state_of(sctx);
    if (!st) return;
    FsqlLedgerCtx *lc = ledger_ctx_of(st->ledger_ctx);
    if (!lc) {
        sqlite3_result_error(sctx, "fractalsql: ledger context invalid", -1);
        return;
    }
    int kind = 1;
    if (argc >= 1 && sqlite3_value_type(argv[0]) != SQLITE_NULL)
        kind = sqlite3_value_int(argv[0]);

    char err[256] = "";
    if (ledger_ensure_table(lc, err, sizeof err) != 0) {
        sqlite3_result_error(sctx, err, -1);
        return;
    }

    static const char SQL[] =
        "SELECT id, payload, mac, prev_hash, entry_hash FROM fractalsql_ledger "
        "WHERE kind=?1 ORDER BY id ASC";
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(st->db, SQL, -1, &stmt, NULL) != SQLITE_OK) {
        snprintf(err, sizeof err, "fractalsql: fractal_ledger_verify: read prepare failed: %s",
                 sqlite3_errmsg(st->db));
        sqlite3_result_error(sctx, err, -1);
        return;
    }
    sqlite3_bind_int(stmt, 1, kind);

    uint8_t expect_prev[32];
    memset(expect_prev, 0, 32);
    sqlite3_int64 expect_id = -1;
    sqlite3_int64 rows = 0;
    int failed = 0;
    sqlite3_int64 fail_id = 0;
    const char *fail_reason = NULL;
    int rc;

    while ((rc = sqlite3_step(stmt)) == SQLITE_ROW) {
        sqlite3_int64 row_id = sqlite3_column_int64(stmt, 0);
        const void *payload = sqlite3_column_blob(stmt, 1);
        int plen = sqlite3_column_bytes(stmt, 1);
        size_t payload_len = (size_t)(plen > 0 ? plen : 0);
        int mac_null = (sqlite3_column_type(stmt, 2) == SQLITE_NULL);
        const void *mac_blob = sqlite3_column_blob(stmt, 2);
        int mac_len = sqlite3_column_bytes(stmt, 2);
        const void *prev_blob = sqlite3_column_blob(stmt, 3);
        int prev_len = sqlite3_column_bytes(stmt, 3);
        const void *hash_blob = sqlite3_column_blob(stmt, 4);
        int hash_len = sqlite3_column_bytes(stmt, 4);

        rows++;

        if (prev_len != 32 || hash_len != 32 || (!mac_null && mac_len != 32)) {
            failed = 1; fail_id = row_id;
            fail_reason = "malformed row (bad hash/mac length)";
            break;
        }

        /* Sequence-gap check: after the first row, every id must be
         * exactly one more than the previous -- a gap means a row was
         * deleted, visible even though we never saw the missing row. */
        if (expect_id >= 0 && row_id != expect_id) {
            failed = 1; fail_id = row_id;
            fail_reason = "sequence gap (a row was deleted)";
            break;
        }

        /* Chain-link check: this row's prev_hash must equal the previous
         * row's entry_hash (all-zero sentinel for the first row). */
        if (memcmp(prev_blob, expect_prev, 32) != 0) {
            failed = 1; fail_id = row_id;
            fail_reason = "chain-link break (prev_hash mismatch)";
            break;
        }

        /* Structural check: entry_hash must recompute from this row's
         * own (prev_hash, payload, mac). */
        uint8_t recomputed[32];
        {
            size_t buflen = 32 + payload_len + (mac_null ? 0 : 32);
            uint8_t *buf = (uint8_t *)malloc(buflen ? buflen : 1);
            if (!buf) {
                failed = 1; fail_id = row_id;
                fail_reason = "out of memory";
                break;
            }
            memcpy(buf, expect_prev, 32);
            if (payload_len) memcpy(buf + 32, payload, payload_len);
            if (!mac_null) memcpy(buf + 32 + payload_len, mac_blob, 32);
            fsql_sha256(buf, buflen, recomputed);
            free(buf);
        }
        if (memcmp(recomputed, hash_blob, 32) != 0) {
            failed = 1; fail_id = row_id;
            fail_reason = "entry_hash mismatch (blob or mac tampered)";
            break;
        }

        memcpy(expect_prev, hash_blob, 32);
        expect_id = row_id + 1;
    }
    if (!failed && rc != SQLITE_DONE) {
        sqlite3_finalize(stmt);
        snprintf(err, sizeof err, "fractalsql: fractal_ledger_verify: read failed: %s",
                 sqlite3_errmsg(st->db));
        sqlite3_result_error(sctx, err, -1);
        return;
    }
    sqlite3_finalize(stmt);

    char json[256];
    if (rows == 0)
        snprintf(json, sizeof json, "{\"ok\":true,\"rows_verified\":0}");
    else if (failed)
        snprintf(json, sizeof json,
                 "{\"ok\":false,\"first_failure_id\":%lld,\"reason\":\"%s\"}",
                 (long long)fail_id, fail_reason);
    else
        snprintf(json, sizeof json, "{\"ok\":true,\"rows_verified\":%lld}",
                 (long long)rows);
    sqlite3_result_text(sctx, json, -1, SQLITE_TRANSIENT);
}

/* ------------------------------------------------------------------ */
/* Registration                                                        */
/* ------------------------------------------------------------------ */

/* Enterprise gating (do not "fix" blindly):
 *
 *   - fractal_ledger_flush/load/compact/reset_soft/reset_hard,
 *     fractal_ledger_truth_count/shadow_count, fractal_audit_log,
 *     fractal_audit_unpack are ALL gated behind ensure_enterprise_lib()
 *     because the community sovereign archive does not compile the
 *     core ledger symbols (vendor header: "absent from a
 *     community-compiled object"; MSVC LNK2001 proved it), so every
 *     function in this group resolves its core symbol through
 *     fsql_enterprise_ensure() and reports "enterprise tier not loaded"
 *     until cfg.enterprise_lib is configured. Registration is
 *     unconditional; the gate is per-call.
 *
 *   - fractal_ledger_verify is the one exception in this file: it
 *     carries no ensure_enterprise_lib() call (a pure read-only
 *     forensic query over the storage table), so it works even with
 *     no enterprise_lib configured at all.
 *
 *   - fractal_isolate_background, fractal_store_morphology,
 *     fractal_mine_topology_negatives are NOT enterprise-gated (no
 *     ensure_enterprise_lib in their bodies; they are plain community
 *     SQL functions). They belong to the reasoning/feature-store TUs,
 *     not the ledger, and are not part of this TU's surface.
 *
 *   - The optional portfolio-multimodal symbols
 *     (fsql_optimize_portfolio_multimodal{,_ex,_pareto}) are core
 *     library symbols, not SQL functions; they are not registered here.
 */
int fsql_ledger_register(sqlite3 *db, FsqlState *st) {
    const int flags = SQLITE_UTF8 | SQLITE_INNOCUOUS;  /* stateful: NOT deterministic */

    static const struct {
        const char *name;
        void (*fn)(sqlite3_context *, int, sqlite3_value **);
        int nargs;
    } FUNCS[] = {
        { "fractal_ledger_flush",        ledger_flush_fn,        0 },
        { "fractal_ledger_load",         ledger_load_fn,         0 },
        { "fractal_ledger_compact",      ledger_compact_fn,      0 },
        { "fractal_ledger_reset_soft",   ledger_reset_soft_fn,   0 },
        { "fractal_ledger_reset_hard",   ledger_reset_hard_fn,   0 },
        { "fractal_ledger_truth_count",  ledger_truth_count_fn,  0 },
        { "fractal_ledger_shadow_count", ledger_shadow_count_fn, 0 },
        { "fractal_audit_unpack",        ledger_audit_unpack_fn, 1 },
        { "fractal_audit_log",           ledger_audit_log_fn,    2 },
        { "fractal_ledger_verify",       ledger_verify_fn,       0 },
        { "fractal_ledger_verify",       ledger_verify_fn,       1 },
    };

    for (size_t i = 0; i < sizeof(FUNCS) / sizeof(FUNCS[0]); i++) {
        int rc = sqlite3_create_function_v2(db, FUNCS[i].name, FUNCS[i].nargs,
                                            flags, st, FUNCS[i].fn,
                                            NULL, NULL, NULL);
        if (rc != SQLITE_OK) return rc;
    }
    return SQLITE_OK;
}