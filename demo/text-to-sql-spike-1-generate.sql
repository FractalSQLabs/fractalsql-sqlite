-- demo/text-to-sql-spike-1-generate.sql
-- Part 1 of 3 of the text-to-sql validation spike (see
-- text-to-sql-spike-2-review.sql and -3-validate.sql for the rest).
--
-- Generates one candidate using whichever model fractalsql_get('http_model')
-- is currently pointed at -- a quality-control check on
-- fractal_text_to_sql() for YOUR configured model (gpt-oss:20b by
-- default, or whatever you've switched to, local or cloud), not a
-- fixed model comparison.
--
-- REQUIRES FSQL_REASONING_HTTP_RESPONSE_MODE=code -- set it and
-- restart the HOST PROCESS (the sqlite3 CLI or your application; the
-- plugin reads the variable once at initialization) BEFORE running
-- this file. See "Switching modes on an already-running install" in
-- ../docs/reasoning-setup.md.
--
-- Config is per-connection fractalsql_set() state, read back with
-- fractalsql_get('http_model') -- and it only survives inside THIS
-- session, so parts 1-3 must each be pointed at the model they intend
-- to test (a fresh invocation re-applies the config from your
-- load_fractalsql.sql snippet via -init).
--
-- Prerequisites: reasoning configured, demo_alerts table present (run
-- demo.sql against THIS database first if you haven't).
--
-- Run:
--   sqlite3 mydb.sqlite -cmd ".load /usr/local/lib/sqlite3/fractalsql" \
--     ".read demo/text-to-sql-spike-1-generate.sql"
--
-- Safe to re-run: spike_candidates is dropped and recreated each time.
-- Without a plugin configured the fractal_reason() statement below is
-- the intended first failure, and its error is the clean
-- "reasoning plugin not configured" hint rather than a crash.

.timer on

DROP TABLE IF EXISTS spike_candidates;
CREATE TABLE spike_candidates (
    model    TEXT PRIMARY KEY,
    sql_text TEXT,
    review   TEXT
);

INSERT INTO spike_candidates (model, sql_text) VALUES (
    COALESCE(fractalsql_get('http_model'), '(model-unset)'),
    fractal_reason(
        'Write a single SQLite SELECT statement that answers this question: for each service, show the count of alerts broken down by severity level, but only include services that have logged at least one critical-severity alert. Return only the SQL, no explanation.',
        'Schema: demo_alerts(id INTEGER PRIMARY KEY, service TEXT, message TEXT, severity TEXT CHECK (severity IN (''info'',''warning'',''critical'')), created_at TEXT DEFAULT (datetime(''now''))). No foreign keys, this is the only table.'
    )
);

.print === Candidate ===
SELECT model, sql_text FROM spike_candidates;

.print
.print ================================================================
.print Next: set FSQL_REASONING_HTTP_RESPONSE_MODE=text, restart the
.print host process, then run demo/text-to-sql-spike-2-review.sql
.print ================================================================