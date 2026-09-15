-- demo/response-modes.sql
--
-- FractalSQL reasoning response modes: text | code | json.
--
-- Unlike demo.sql, this is NOT meant to be run start-to-finish in one
-- `.read` pass. FSQL_REASONING_HTTP_RESPONSE_MODE is an env-var-only
-- setting read once when the reasoning plugin initializes -- switching
-- modes on an already-running install needs an OS-level environment
-- variable change plus a restart of the HOST PROCESS (the sqlite3 CLI
-- or your application -- in SQLite the plugin runs in-process, so
-- there is no separate server to restart; a new sqlite3 session does
-- NOT pick up the variable unless its environment changed). See
-- "Switching modes on an already-running install" in
-- ../docs/reasoning-setup.md for the exact commands on your platform
-- (Windows/Linux/macOS all differ here).
--
-- Prerequisites:
--   1. Run demo.sql first -- this reuses its demo_alerts table.
--   2. Reasoning already configured per ../docs/reasoning-setup.md
--      (per-connection fractalsql_set state, so re-apply your
--      load_fractalsql.sql snippet with -init for each section run).
--
-- Workflow for each section below:
--   1. Set FSQL_REASONING_HTTP_RESPONSE_MODE to that section's mode.
--   2. Restart the host process that loads the extension.
--   3. Run ONLY that section's query -- not the whole file at once.
--      e.g.:  sqlite3 mydb.sqlite -cmd ".load /usr/local/lib/sqlite3/fractalsql" \
--              ".read demo/response-modes.sql"
--      (select the section by running it from a copy, or feed it with
--      a here-doc / a second .read of a one-statement file.)

.timer on

-- ============================================================
-- MODE: text (the default -- nothing to configure or restart for)
-- ============================================================
-- Raw model output, unchanged. This is what demo.sql and every other
-- example in the docs already use.

SELECT fractal_reason(
    'summarize what happened in demo_alerts in one sentence',
    (SELECT json_group_array(json_object('service',     service,
                                         'message',    message,
                                         'severity',   severity,
                                         'created_at', created_at))
       FROM (SELECT service, message, severity, created_at FROM demo_alerts))
);

-- ============================================================
-- MODE: code   (FSQL_REASONING_HTTP_RESPONSE_MODE=code, then restart)
-- ============================================================
-- The plugin auto-appends an instruction telling the model to answer
-- with a single fenced code block, then strips the fence markers on
-- extraction. Expect back a bare SQL statement -- no "Here's a query
-- that does that:" preamble, no explanation, no visible ``` markers.

SELECT fractal_reason(
    'write a SQLite query that selects all rows from demo_alerts where severity is critical'
);

-- ============================================================
-- MODE: json   (FSQL_REASONING_HTTP_RESPONSE_MODE=json, then restart)
-- ============================================================
-- Same fenced-block extraction as code mode, plus a structural
-- validity check (balanced braces/brackets) on the plugin side before
-- it's returned. Wrapping the result in json() below is a second,
-- independent proof: if the plugin's own validation somehow let
-- something malformed through, SQLite's own JSON parser catches it
-- here instead of silently accepting bad output (json() raises on
-- malformed input).

SELECT json(fractal_reason(
    'return a JSON object with keys critical_count, warning_count, and info_count summarizing the severities present',
    (SELECT json_group_array(json_object('severity', severity))
       FROM (SELECT severity FROM demo_alerts))
)) AS parsed_json;