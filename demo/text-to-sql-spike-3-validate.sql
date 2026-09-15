-- demo/text-to-sql-spike-3-validate.sql
-- Part 3 of 3 of the text-to-sql validation spike. Requires Parts 1
-- and 2 to have already run. No mode dependency, no restart needed --
-- EXPLAIN and EXECUTE are mechanical, not reasoning calls.
--
-- The sqlite3 shell has no \gexec, so the stored candidate is spooled
-- to ./spike_candidate.sql with .once and executed with .read. The
-- EXECUTE step runs inside BEGIN/ROLLBACK as a safety net so nothing
-- the candidate does can persist. The spool file is overwritten on
-- every run; delete it when the spike is done.
--
-- Correct result: exactly 2 rows in the EXECUTE output,
-- service=api-gateway, (severity=info, count=2) and
-- (severity=critical, count=2). payments and auth-service must NOT
-- appear.
--
-- Prerequisite: demo_alerts populated (run demo.sql against THIS
-- database first).

.timer on

-- ================================================================
-- EXPLAIN (mechanical). The spooled text is "EXPLAIN <candidate>",
-- so .read runs the EXPLAIN rather than the statement itself. SQLite
-- EXPLAIN compiles the candidate without executing it: a syntactically
-- broken candidate errors here, a valid one prints its bytecode
-- program.
-- ================================================================

-- (.timer must be OFF around the spool SELECTs -- its "Run Time:" line
-- would otherwise be captured into the spool file and break the .read.)
.timer off
.once spike_candidate.sql
SELECT 'EXPLAIN ' || sql_text FROM spike_candidates
 WHERE model = COALESCE(fractalsql_get('http_model'), '(model-unset)');

.read spike_candidate.sql

-- ================================================================
-- EXECUTE (manual validation only -- the real feature never
-- auto-executes; this is us checking the answer is actually correct,
-- not just syntactically valid). BEGIN + .read + ROLLBACK: the
-- candidate's result rows still print, but nothing it did can stick.
-- ================================================================

BEGIN;
.timer off
.once spike_candidate.sql
SELECT sql_text FROM spike_candidates
 WHERE model = COALESCE(fractalsql_get('http_model'), '(model-unset)');
.read spike_candidate.sql
.timer on
ROLLBACK;

.print
.print ================================================================
.print Done. Interpretation:
.print   - EXPLAIN failed -> syntactically broken SQL, a real problem
.print     (prepare-only validation would have caught it).
.print   - EXPLAIN passed but EXECUTE shows payments/auth-service rows
.print     -> syntactically valid, semantically WRONG. This is exactly
.print     the gap review exists to catch -- check whether review said
.print     PASS or FAIL for this (wrong) candidate.
.print   - Review said PASS on a candidate that executes wrong -> the
.print     review step itself is not reliable for this model.
.print   - EXPLAIN passes, EXECUTE shows only api-gateway (info=2,
.print     critical=2) -> strong go signal for this model.
.print
.print Clean up when done: DROP TABLE spike_candidates;  (and delete
.print the spike_candidate.sql spool file left in the current dir)
.print ================================================================