-- demo/demo.sql
--
-- FractalSQL basic demo (SQLite edition): Sniper/Scout search feeding
-- LLM reasoning.
--
-- Prerequisites (see demo/README.md for the full walkthrough):
--   1. The extension is built/installed and loaded into THIS connection.
--      SQLite extensions load per connection -- run one of the .load
--      lines in the preamble block below (or pass it with -cmd) before
--      the statements here.
--   2. Reasoning configured per ../docs/reasoning-setup.md -- this script
--      assumes the reasoning_plugin / http_url / http_model config keys
--      are already set for the connection (fractalsql_set -- no server
--      config to reload; changes apply immediately). Any
--      OpenAI-compatible endpoint works (Ollama, Bedrock, Azure, GCP
--      Vertex, ...) -- this script doesn't care which.
--
-- Run:
--   sqlite3 mydb.sqlite -cmd ".load /usr/local/lib/sqlite3/fractalsql" \
--     ".read demo/demo.sql"
--
-- Safe to re-run: the demo tables are dropped and recreated each time.
-- Nothing here is destructive to anything outside the two demo_* tables.

-- ---------------------------------------------------------------------------
-- Load the extension first (per connection). From inside the sqlite3 shell:
--   .load /usr/local/lib/sqlite3/fractalsql
--   (Windows: .load C:/Program Files/FractalSQL/fractalsql)
-- or, in SQL:  SELECT load_extension('/usr/local/lib/sqlite3/fractalsql');
-- ---------------------------------------------------------------------------

.timer on

.print === 0. Sanity check: extension loaded? ===
SELECT fractalsql_edition(), fractalsql_version();

.print
.print === 1. Set up a small alerts table with something worth noticing ===
DROP TABLE IF EXISTS demo_alerts;
CREATE TABLE demo_alerts (
    id          INTEGER PRIMARY KEY,
    service     TEXT,
    message     TEXT,
    severity    TEXT,
    created_at  TEXT DEFAULT (datetime('now'))
);

INSERT INTO demo_alerts (service, message, severity, created_at) VALUES
    ('api-gateway',  'request latency p99 245ms',              'info',     datetime('now', '-55 minutes')),
    ('api-gateway',  'request latency p99 260ms',              'info',     datetime('now', '-50 minutes')),
    ('payments',     'transaction processed successfully',     'info',     datetime('now', '-45 minutes')),
    ('payments',     'transaction processed successfully',     'info',     datetime('now', '-40 minutes')),
    ('auth-service', '3 failed login attempts, user_id=8821',  'warning',  datetime('now', '-30 minutes')),
    ('auth-service', '3 failed login attempts, user_id=8821',  'warning',  datetime('now', '-29 minutes')),
    ('auth-service', '17 failed login attempts, user_id=8821', 'warning',  datetime('now', '-28 minutes')),
    ('payments',     'transaction processed successfully',     'info',     datetime('now', '-20 minutes')),
    ('api-gateway',  'request latency p99 4200ms',              'critical', datetime('now', '-10 minutes')),
    ('api-gateway',  'request latency p99 3900ms',              'critical', datetime('now',  '-9 minutes'));

.print
.print === 2. Sniper Search: converge to a single best point ===
-- fractal_search(vector, query) is a per-row scalar over a stored column --
-- it converges each stored vector toward the query point, fixed at the
-- SFS defaults (fractal_search_debug(query, ...) exposes the tunable
-- abstract-space form). The SFS engine runs once per distinct query per
-- scan, so order a small corpus by distance and take the top row.
DROP TABLE IF EXISTS demo_points;
CREATE TABLE demo_points (label TEXT, pt TEXT);   -- CSV TEXT vectors
INSERT INTO demo_points (label, pt) VALUES
    ('a', '0.6,0.8,0.0'),
    ('b', '0.1,0.2,0.0'),
    ('c', '-0.9,0.4,0.0'),
    ('d', '0.0,0.0,1.0');
SELECT label, fractal_search(pt, '0.6,0.8,0.0') AS dist
  FROM demo_points
 ORDER BY dist
 LIMIT 3;

.print
.print === 3. Ask the LLM to analyze the alerts table (real context, not a bare ping) ===
-- json_group_array over json_object builds the JSON context payload.
SELECT fractal_reason(
    'summarize what happened in the last hour and flag anything that needs attention',
    (SELECT json_group_array(json_object('service',     service,
                                         'message',    message,
                                         'severity',   severity,
                                         'created_at', created_at))
       FROM (SELECT service, message, severity, created_at
               FROM demo_alerts
              WHERE created_at > datetime('now', '-1 hour')
              ORDER BY created_at))
);

.print
.print === 4. Scout Discovery feeding reasoning: search + reason in one pipeline ===
-- fractal_search_explore(emb, query[, params]) is an AGGREGATE here --
-- scan your own column and the population comes back as one JSON
-- document (its $.population key). Because it is an aggregate, the
-- Scout result can feed fractal_reason() in the same statement.
DROP TABLE IF EXISTS demo_embeddings;
CREATE TABLE demo_embeddings (id INTEGER PRIMARY KEY, emb TEXT);
-- 500 random 3D rows. SQLite's random() returns a signed 64-bit int;
-- dividing by 2^63 maps it into [-1, 1). There is no seedable global
-- RNG, so the fixture is not reproducibly seeded. (Each term MUST be
-- parenthesized before concatenation -- SQLite's || binds tighter than
-- /, so an unparenthesized `a / b || ',' || c / d` parses as
-- `a / (b || ',' || c) / d`, silently producing garbage.)
WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 500)
INSERT INTO demo_embeddings (emb)
SELECT (random() / 9223372036854775808.0) || ',' ||
       (random() / 9223372036854775808.0) || ',' ||
       (random() / 9223372036854775808.0)
  FROM seq;

SELECT fractal_reason(
    'these are points from a 3D embedding space sampled by Scout Discovery -- describe the spread',
    (SELECT fractal_search_explore(emb, '0.0,0.0,0.0',
                            '{"population_size": 10, "iterations": 8}')
       FROM demo_embeddings)
);

.print
.print === Demo complete ===
.print Tables demo_alerts, demo_points and demo_embeddings were left in place
.print for you to inspect further. Clean up with:
.print   DROP TABLE demo_alerts, demo_points, demo_embeddings;