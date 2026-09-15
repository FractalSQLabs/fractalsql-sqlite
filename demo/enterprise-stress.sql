-- demo/enterprise-stress.sql
--
-- Enterprise Tier -- QTL Ledger under stress + tamper-evidence.
--
-- Companion to enterprise-qtl-audit.sql (which walks the 8 functions one
-- call at a time). This demo hammers the same surface: it fills the
-- in-memory Truth/Shadow ledgers to their capacity bound (64 each), churns
-- repeated flush/load cycles, and probes the ledger's tamper-evidence by
-- corrupting the persisted QTL blob and confirming load rejects it.
--
-- Like the audit demo, this runs in BOTH states:
--
--   * Enterprise ACTIVE  -- fills to cap (128 events), round-trips them
--     through the QTL encode -> fractalsql_ledger table -> decode path,
--     churns 5 flush/load cycles, confirms a structurally corrupted
--     (truncated) blob is rejected on load (Phase C), an HMAC-tagged
--     payload byte-flip is rejected even when structurally valid (Phase
--     D), and walks the append-only chain: multi-row
--     fractal_ledger_verify(), a middle-row tamper that load()'s O(1)
--     tip-only check cannot see but verify()'s full walk catches (Phase
--     E).
--
--   * Enterprise DORMANT -- the first enterprise call fails with a clean
--     "enterprise tier not loaded" error. SQLite has no exception handling
--     in plain SQL, so this demo can't catch that and print one summary
--     message -- every subsequent
--     enterprise call below prints its own copy of the same error and the
--     sqlite3 shell (per its default `.bail off`) carries on. Community
--     search is unaffected either way, but the process will exit non-zero
--     on a dormant run -- read the output, don't rely on the exit code.
--
-- The invariant checks this demo prints expected values for (e.g. "expect
-- truth=64 shadow=64 events=128") are informational, not enforced: SQLite
-- has no IF/procedural assertion construct in plain SQL to assert them, so on the active
-- path you confirm them by eye against what's printed.
--
-- Concurrency / cross-session persistence (parallel last-writer-wins
-- flush, and load-in-a-fresh-connection) are exercised by build_test gate
-- 25 (gate_25_enterprise_stress), which drives a real enterprise core via
-- Python's sqlite3 stdlib -- not something a single `.read` script can do
-- without a scripting language's control flow.
--
-- Activate for this demo (enterprise assets are not shipped in this repo --
-- point at wherever your licensed core landed):
--
--   sqlite3 mydb.sqlite -cmd ".load ./dist/amd64/fractalsql" \
--     -cmd "SELECT fractalsql_set('enterprise_lib', '/path/to/libfractalsql-enterprise-sovereign-c.so');" \
--     ".read demo/enterprise-stress.sql"
--
-- Omit the fractalsql_set line entirely to see the dormant path.
--
-- Safe to re-run: the persisted ledger table is dropped up front and the
-- in-memory ledger context is per-connection (a fresh connection starts
-- empty).

-- Re-runnable: clear any prior persisted QTL blob.
DROP TABLE IF EXISTS fractalsql_ledger;

.print === Enterprise QTL Ledger -- stress + tamper-evidence ===
.print fractal_feedback_report() is a COMMUNITY primitive used to seed the
.print in-memory Truth/Shadow ledgers that the enterprise tier later seals
.print into a QTL blob. Caps: 64 Truth + 64 Shadow (FSQL_TRUTH/SHADOW_DEFAULT_CAP).
.print Each fractal_feedback_report() call below returns NULL on success --
.print the NULL rows printed by the fill loops ARE the 64/64/128 successful
.print writes, not noise to ignore.

-- The diversify/repulsion path is the documented precondition for
-- engagement recording; the inserts themselves are ledger-level.
SELECT fractal_diversify_enable();

.print
.print --- Phase A: fill to capacity bound + audit round-trip ---
-- The first enterprise call below (reset_hard) is the dormant probe: it
-- succeeds under the enterprise tier and errors otherwise.
SELECT fractal_ledger_reset_hard();

-- 64 distinct Truth events (doc_ids 1..64) + 64 distinct Shadow events
-- (doc_ids 65..128). Disjoint doc_ids => no QTL dedup => the blob encodes
-- all 128. Beyond 64 of either kind the ledger evicts the lowest-weight
-- entry, so 64/64 is the cap.
WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 64)
SELECT fractal_feedback_report(n, 'positive') FROM seq;
WITH RECURSIVE seq(n) AS (SELECT 65 UNION ALL SELECT n + 1 FROM seq WHERE n < 128)
SELECT fractal_feedback_report(n, 'negative') FROM seq;

.print (expect truth_count=64 shadow_count=64)
SELECT fractal_ledger_truth_count() AS truth_count, fractal_ledger_shadow_count() AS shadow_count;

SELECT fractal_ledger_flush();
.print (expect a 128-element CISO audit array)
SELECT json_array_length(fractal_audit_unpack(payload)) AS audit_events
  FROM fractalsql_ledger WHERE kind = 1 ORDER BY id DESC LIMIT 1;

.print
.print --- Phase B: churn (5 flush/load cycles at capacity) ---
-- Each cycle: reset_hard, refill 64+64 with a cycle-unique doc_id offset
-- (so no cross-cycle dedup), flush, load. SQLite has no loop construct in
-- plain SQL, so the 5 cycles are unrolled explicitly below.

SELECT fractal_ledger_reset_hard();
WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 64)
SELECT fractal_feedback_report(n + 1000, 'positive') FROM seq;
WITH RECURSIVE seq(n) AS (SELECT 65 UNION ALL SELECT n + 1 FROM seq WHERE n < 128)
SELECT fractal_feedback_report(n + 1000, 'negative') FROM seq;
SELECT fractal_ledger_flush();
SELECT fractal_ledger_load();

SELECT fractal_ledger_reset_hard();
WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 64)
SELECT fractal_feedback_report(n + 2000, 'positive') FROM seq;
WITH RECURSIVE seq(n) AS (SELECT 65 UNION ALL SELECT n + 1 FROM seq WHERE n < 128)
SELECT fractal_feedback_report(n + 2000, 'negative') FROM seq;
SELECT fractal_ledger_flush();
SELECT fractal_ledger_load();

SELECT fractal_ledger_reset_hard();
WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 64)
SELECT fractal_feedback_report(n + 3000, 'positive') FROM seq;
WITH RECURSIVE seq(n) AS (SELECT 65 UNION ALL SELECT n + 1 FROM seq WHERE n < 128)
SELECT fractal_feedback_report(n + 3000, 'negative') FROM seq;
SELECT fractal_ledger_flush();
SELECT fractal_ledger_load();

SELECT fractal_ledger_reset_hard();
WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 64)
SELECT fractal_feedback_report(n + 4000, 'positive') FROM seq;
WITH RECURSIVE seq(n) AS (SELECT 65 UNION ALL SELECT n + 1 FROM seq WHERE n < 128)
SELECT fractal_feedback_report(n + 4000, 'negative') FROM seq;
SELECT fractal_ledger_flush();
SELECT fractal_ledger_load();

SELECT fractal_ledger_reset_hard();
WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 64)
SELECT fractal_feedback_report(n + 5000, 'positive') FROM seq;
WITH RECURSIVE seq(n) AS (SELECT 65 UNION ALL SELECT n + 1 FROM seq WHERE n < 128)
SELECT fractal_feedback_report(n + 5000, 'negative') FROM seq;
SELECT fractal_ledger_flush();
SELECT fractal_ledger_load();

.print (expect truth_count=64 shadow_count=64 after 5 churn cycles)
SELECT fractal_ledger_truth_count() AS truth_count, fractal_ledger_shadow_count() AS shadow_count;
.print (expect a 128-element CISO audit array)
SELECT json_array_length(fractal_audit_unpack(payload)) AS audit_events
  FROM fractalsql_ledger WHERE kind = 1 ORDER BY id DESC LIMIT 1;

.print
.print --- Phase C: tamper-evidence (structural) ---
-- Flush a small clean blob, then truncate it in the table below the
-- 24-byte QTL header. load() must reject it (FSQL_ELEDGER_INTEGRITY).
-- NOTE: by default (no enterprise_ledger_key) the QTL format carries no
-- MAC, so this phase is STRUCTURAL tamper-evidence only (truncation /
-- count-length mismatch); a targeted payload byte-flip is NOT detected by
-- the structural check alone -- Phase D below adds the HMAC envelope that
-- DOES catch that.
SELECT fractal_ledger_reset_hard();
SELECT fractal_feedback_report(1, 'positive');
SELECT fractal_feedback_report(2, 'negative');
SELECT fractal_ledger_flush();
UPDATE fractalsql_ledger
   SET payload = substr(payload, 1, 5)   -- 5 bytes < 24-byte header
 WHERE id = (SELECT max(id) FROM fractalsql_ledger WHERE kind = 1);

.print (expect an "enterprise:" / integrity error here -- tamper detected.
.print  If this succeeds silently instead, that is a tamper-evidence FAILURE.)
SELECT fractal_ledger_load();

.print
.print === Phase D: MAC-authenticated tamper-evidence (enterprise_ledger_key) ===
.print fractal_ledger_load() verifies an HMAC-SHA256 tag over the persisted blob
.print before the core decodes it, so a payload byte-flip the structural check
.print cannot see (length + count preserved) is now rejected.

SELECT fractalsql_set('enterprise_ledger_key', 'demo-mac-key');

-- Tag a fresh blob, then load (MAC verifies -> ok).
SELECT fractal_ledger_reset_hard();
SELECT fractal_feedback_report(1, 'positive');
SELECT fractal_ledger_flush();
.print (expect this load to succeed -- HMAC-SHA256 tagged and verified)
SELECT fractal_ledger_load();

-- Tamper: flip a MIDDLE payload byte. Length and the 24-byte header count
-- field are preserved, so the structural decode check cannot see it (it
-- would decode to a corrupted doc_id). The MAC must catch it.
UPDATE fractalsql_ledger
   SET payload = CAST(substr(payload, 1, length(payload) / 2) || X'FE' ||
                       substr(payload, length(payload) / 2 + 2) AS BLOB)
 WHERE id = (SELECT max(id) FROM fractalsql_ledger WHERE kind = 1);

.print (expect an HMAC mismatch error here -- payload byte-flip detected.
.print  If this succeeds silently instead, that is a MAC-verification FAILURE.)
SELECT fractal_ledger_load();

-- Recovery: re-flush re-tags a fresh, consistent blob; load verifies ok.
SELECT fractal_ledger_reset_hard();
SELECT fractal_feedback_report(1, 'positive');
SELECT fractal_ledger_flush();
.print (expect this load to succeed -- re-flush re-tagged a clean blob)
SELECT fractal_ledger_load();

-- Empty string resets a CFG_STR key back to unset.
SELECT fractalsql_set('enterprise_ledger_key', '');

.print
.print === Phase E: append-only chain ===
.print The ledger is an append-only hash chain, not a last-writer-wins
.print snapshot: every row links to its predecessor via
.print entry_hash = SHA256(prev_hash || payload || mac). fractal_ledger_load()
.print only checks the chain TIP (O(1), cheap, every load) --
.print fractal_ledger_verify() walks the WHOLE chain (O(n), on demand) and
.print catches tampering anywhere in history, not just the latest row.
.print (Fresh chain for this phase -- Phase C left a deliberately corrupted
.print row in history above, and verify() correctly never forgets that; a
.print clean slate here isolates this phase's own tamper demonstration.)

DROP TABLE IF EXISTS fractalsql_ledger;

SELECT fractal_ledger_reset_hard();
SELECT fractal_feedback_report(1, 'positive');
SELECT fractal_ledger_flush();
SELECT fractal_ledger_reset_hard();
SELECT fractal_feedback_report(2, 'positive');
SELECT fractal_ledger_flush();
SELECT fractal_ledger_reset_hard();
SELECT fractal_feedback_report(3, 'positive');
SELECT fractal_ledger_flush();

.print (expect ok=true, rows_verified=3)
SELECT fractal_ledger_verify();

-- Tamper a MIDDLE row (id=2), not the latest (id=3).
UPDATE fractalsql_ledger
   SET payload = CAST(X'FE' || substr(payload, 2) AS BLOB)
 WHERE id = 2;

-- load() only checks the tip (id=3) -- still succeeds. This is the
-- documented O(1) scope boundary, not a bug: it's the same tradeoff every
-- load() has always made (cheap check on the hot path), now made visible
-- because there's finally history to have a boundary against.
.print (expect this load to still succeed -- O(1) tip-only scope, id=3 is clean)
SELECT fractal_ledger_load();

.print (expect ok=false, first_failure_id=2 -- verify()'s full walk catches it)
SELECT fractal_ledger_verify();

-- There is no in-place "recovery" from a tampered row: reset_hard only
-- clears the IN-MEMORY ledgers, not the persisted table, so a new flush
-- appends on top of the still-corrupted history -- verify() correctly
-- keeps reporting the historical break. That is the point of an
-- append-only chain: it does not forget. Genuine recovery means starting a
-- fresh chain (DROP the table -- in a real deployment, archive the old one
-- first with a documented incident record).
SELECT fractal_ledger_reset_hard();
SELECT fractal_feedback_report(1, 'positive');
SELECT fractal_ledger_flush();
.print (expect still ok=false -- new activity does NOT erase history)
SELECT fractal_ledger_verify();

.print
.print Deletion is also visible: DELETE any row but the latest and
.print fractal_ledger_verify() reports a sequence gap at that id (try it --
.print "DELETE FROM fractalsql_ledger WHERE id = 2;" then re-run
.print "SELECT fractal_ledger_verify();"). Concurrency (parallel append-only
.print writers staying one unforked chain) and detached-signature
.print verification of the enterprise library itself
.print (enterprise_require_signature) are exercised by build_test gates 25
.print and 26 -- not something a single .read script can drive.

.print
.print === Demo complete ===
