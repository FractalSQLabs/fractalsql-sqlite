-- demo/response-modes.sql
--
-- FractalSQL reasoning response modes: text | code | json.
--
-- The mode is the per-connection config key http_response_mode, so one
-- pass through this file shows all three: each section sets the key and
-- then runs its query. The FSQL_REASONING_HTTP_RESPONSE_MODE environment
-- variable of the host process is only the starting value a new
-- connection reads. See "Response Modes" in ../docs/reasoning-setup.md.
--
-- Prerequisites:
--   1. Run demo.sql first -- this reuses its demo_alerts table.
--   2. Reasoning already configured per ../docs/reasoning-setup.md
--      (per-connection fractal_config_set state, applied by your
--      load_fractalsql.sql snippet with -init).
--
-- Run it with:  sqlite3 mydb.sqlite -init load_fractalsql.sql ".read demo/response-modes.sql"

.timer on

-- ============================================================
-- MODE: text (the default)
-- ============================================================
-- Raw model output, unchanged. This is what demo.sql and every other
-- example in the docs already use.

SELECT fractal_config_set('http_response_mode', 'text');

SELECT fractal_reason(
    'summarize what happened in demo_alerts in one sentence',
    (SELECT json_group_array(json_object('service',     service,
                                         'message',    message,
                                         'severity',   severity,
                                         'created_at', created_at))
       FROM (SELECT service, message, severity, created_at FROM demo_alerts))
);

-- ============================================================
-- MODE: code
-- ============================================================
-- The plugin auto-appends an instruction telling the model to answer
-- with a single fenced code block, then strips the fence markers on
-- extraction. Expect back a bare SQL statement -- no "Here's a query
-- that does that:" preamble, no explanation, no visible ``` markers.

SELECT fractal_config_set('http_response_mode', 'code');

SELECT fractal_reason(
    'write a SQLite query that selects all rows from demo_alerts where severity is critical'
);

-- ============================================================
-- MODE: json
-- ============================================================
-- Same fenced-block extraction as code mode, plus a structural
-- validity check (balanced braces/brackets) on the plugin side before
-- it's returned. Wrapping the result in json() below is a second,
-- independent proof: if the plugin's own validation somehow let
-- something malformed through, SQLite's own JSON parser catches it
-- here instead of silently accepting bad output (json() raises on
-- malformed input).

SELECT fractal_config_set('http_response_mode', 'json');

SELECT json(fractal_reason(
    'return a JSON object with keys critical_count, warning_count, and info_count summarizing the severities present',
    (SELECT json_group_array(json_object('severity', severity))
       FROM (SELECT severity FROM demo_alerts))
)) AS parsed_json;

-- Back to the default for anything run after this.
SELECT fractal_config_set('http_response_mode', '');
