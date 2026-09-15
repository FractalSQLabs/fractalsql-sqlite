-- demo/text-to-sql-spike-2-review.sql
-- Part 2 of 3 of the text-to-sql validation spike. Requires Part 1 to
-- have already run (reads from spike_candidates).
--
-- REQUIRES FSQL_REASONING_HTTP_RESPONSE_MODE=text -- set it and
-- restart the HOST PROCESS (the sqlite3 CLI or your application) BEFORE
-- running this file (switching back from the code mode Part 1 needed).
-- See "Switching modes on an already-running install" in
-- ../docs/reasoning-setup.md.
--
-- The model reviews its OWN candidate, matching how the real feature
-- would run (same configured endpoint for both steps).
-- fractalsql_get('http_model') must still return the model spike-1
-- generated with -- re-apply the same load_fractalsql.sql snippet
-- (-init) as part 1 used; this doesn't re-check that for you.
--
-- Without a plugin configured the fractal_reason() UPDATE below is the
-- intended first failure: it errors with the clean "reasoning plugin
-- not configured" hint and the SELECTs that follow simply show a NULL
-- review column.

.timer on

UPDATE spike_candidates SET review = fractal_reason(
    'Original request: for each service, show the count of alerts broken down by severity level, but only include services that have logged at least one critical-severity alert.

Candidate SQL:
' || sql_text || '

Does this candidate correctly implement the stated rule -- specifically, does it correctly EXCLUDE services with no critical-severity alerts, not just show all services grouped by severity? Answer PASS or FAIL on the first line, then explain briefly.'
) WHERE model = COALESCE(fractalsql_get('http_model'), '(model-unset)');

.print === Review ===
SELECT model, review FROM spike_candidates;

.print
.print ================================================================
.print Next: run demo/text-to-sql-spike-3-validate.sql (no restart
.print needed -- EXPLAIN and EXECUTE are mechanical steps here).
.print ================================================================