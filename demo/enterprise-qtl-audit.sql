-- demo/enterprise-qtl-audit.sql
--
-- Enterprise Tier -- Quantized Ternary Ledger (QTL) + CISO Audit, end to end.
--
-- The QTL ledger and CISO audit surface are enterprise-tier features,
-- runtime-gated behind the enterprise core shared library. The community
-- extension (what the Docker image ships by default) carries all eight SQL
-- signatures, but they are DORMANT until `fractalsql_set('enterprise_lib',
-- ...)` points at a present enterprise core library (libfractalsql-
-- enterprise-sovereign-c.so / .dylib / .dll). There is no server config
-- to reload -- the setting takes effect immediately, per connection.
--
-- This demo runs in BOTH states:
--
--   * Enterprise ACTIVE  -- the eight functions run for real: it seeds real
--     Truth/Shadow engagement events, flushes them to the `fractalsql_ledger`
--     table, decodes the persisted QTL blob back into a tamper-evident CISO
--     audit log, and exercises load/compact/reset.
--
--   * Enterprise DORMANT -- each enterprise call fails with a clean
--     "enterprise tier not loaded" error. SQLite has no exception handling
--     in plain SQL, so this demo can't catch that and summarize it in one
--     message -- the sqlite3 shell just prints each error and, per its
--     default (`.bail off`), carries on to the next statement. The
--     community search engine above is unaffected either way. Because
--     nothing here catches the error, a dormant run also makes the sqlite3
--     process exit non-zero -- read the printed output to see which path
--     ran, don't rely on the exit code.
--
-- Activate for this demo (enterprise assets are not shipped in this repo --
-- point at wherever your licensed core landed):
--
--   sqlite3 mydb.sqlite -cmd ".load ./dist/amd64/fractalsql" \
--     -cmd "SELECT fractalsql_set('enterprise_lib', '/path/to/libfractalsql-enterprise-sovereign-c.so');" \
--     ".read demo/enterprise-qtl-audit.sql"
--
-- Omit the fractalsql_set line entirely to see the dormant path.
--
-- Safe to re-run: the persisted ledger table is dropped up front and the
-- in-memory ledger context is per-connection (a fresh connection starts
-- empty).

.print === 1. Seed real engagement events into the in-memory Truth/Shadow ledgers ===
.print fractal_feedback_report() is a COMMUNITY primitive -- it records search
.print engagement (dwell / positive -> Truth, negative -> Shadow) into the same
.print in-memory context the enterprise ledger later seals. No enterprise tier
.print needed for this step.

-- Re-runnable: clear any prior persisted QTL blob. (fractalsql_ledger is a
-- plain table created lazily by the first successful flush, not an extension
-- member, so a bare DROP IF EXISTS is safe and does not need the enterprise
-- tier loaded.)
DROP TABLE IF EXISTS fractalsql_ledger;

-- Enable the diversify/repulsion path so the documented precondition for
-- engagement recording is met (the inserts themselves are ledger-level, but
-- this matches the contract the SQL comments describe).
SELECT fractal_diversify_enable();

-- Record two Truth events (positive + dwell) and two Shadow events (negative).
-- result_handle is the corpus row index the event refers to; the ledger stores
-- (doc_id, signal, epoch) per event.
SELECT fractal_feedback_report(1, 'positive', 500);   -- Truth: doc 1
SELECT fractal_feedback_report(2, 'dwell',   1200);    -- Truth: doc 2
SELECT fractal_feedback_report(3, 'negative');          -- Shadow: doc 3
SELECT fractal_feedback_report(4, 'negative');          -- Shadow: doc 4

.print
.print === 2. Enterprise QTL Ledger + CISO Audit ===
.print Each call below is enterprise-gated. On the community build (no
.print enterprise_lib set) the first one prints "enterprise tier not loaded"
.print and the rest follow suit -- that is the expected dormant path, not a
.print bug in this demo.

.print --- Phase A: flush (encode Truth+Shadow -> QTL blob -> fractalsql_ledger, kind=1) ---
SELECT fractal_ledger_flush();
SELECT fractal_ledger_truth_count() AS truth_count, fractal_ledger_shadow_count() AS shadow_count;

.print --- Phase B: audit (decode the just-flushed blob into its CISO event log) ---
-- One {"epoch","doc_id","signal"} object per ledger entry, sorted by doc_id.
-- This is the round-trip: in-memory -> QTL blob -> persisted table -> decoded
-- audit log.
SELECT fractal_audit_unpack(payload) AS audit_log
  FROM fractalsql_ledger WHERE kind = 1 ORDER BY id DESC LIMIT 1;

.print --- Phase C: load (rehydrate the in-memory ledgers from the persisted blob) ---
SELECT fractal_ledger_load();

.print --- Phase D: compact (defragment / re-pack the in-memory QTL representation) ---
SELECT fractal_ledger_compact();

.print --- Phase E: reset_soft (clear Shadow, preserve Truth) ---
SELECT fractal_ledger_reset_soft();
SELECT fractal_ledger_truth_count() AS truth_count, fractal_ledger_shadow_count() AS shadow_count;

.print --- Phase F: reset_hard (clear both ledgers) ---
SELECT fractal_ledger_reset_hard();
SELECT fractal_ledger_truth_count() AS truth_count, fractal_ledger_shadow_count() AS shadow_count;

.print
.print === Demo complete ===
.print Enterprise ACTIVE: Phase A shows truth_count=2 shadow_count=2, Phase B
.print shows a 4-entry audit log, Phase E shows truth_count=2 shadow_count=0,
.print Phase F shows truth_count=0 shadow_count=0.
.print Enterprise DORMANT: every Phase above printed its own
.print "enterprise tier not loaded" error and the counts read 0/0 throughout --
.print that is the expected outcome on the community build, not a failure.
