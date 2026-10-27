-- demo/demo-vertical-simulated-economy-drift.sql
--
-- Industry vertical: Simulated-economy balancing: market inflation loops
-- and automated-actor detection. AGENTIC kit: Six markets x 96 days of
-- price index; every market carries a weekly demand cycle, and one (mkt-d)
-- enters an accelerating inflation spiral. `fractal_periodogram` confirms
-- the weekly cycle, `fractal_dimension_dfa` flags the market that is
-- inflating non-linearly, and `fractal_optimize_portfolio` picks the 3
-- markets for the scheduled sink program (the inflating market goes to an
-- emergency price-cap instead). `fractal_agent_detect_loop` then watches
-- trade-state logs: an automated actor that flips between the same two item
-- states is detected while a varied actor is not.
--
--   1. fractal_periodogram: the dominant period of each market (a 7-day
--      weekly cycle is expected).
--   2. fractal_dimension_dfa: the market whose price index is accelerating.
--   3. fractal_optimize_portfolio (SFS): 3-of-6 sink program, risk =
--      variance x DFA exponent.
--   4. fractal_agent_detect_loop: SimHash + Brent cycle detection on trade-
--      state logs, automated vs varied actor.
--   5. A closing fractal_reason() writes the balance note.
--
-- Prerequisites: the fractalsql extension loaded (.load ./fractalsql); the
-- agents ship inside it. The closing fractal_reason() narrative and any
-- shipped-agent rationale columns need the reasoning plugin
-- (docs/reasoning-setup.md); every other step runs with no model.
--
-- Run:
--   sqlite3 -cmd ".load ./fractalsql" :memory: ".read demo/demo-vertical-simulated-economy-drift.sql"
--
-- Safe to re-run: sed_* tables are dropped and recreated each time.
--
-- Notes:
--   * Fully deterministic fixtures (no random()).
--   * The trade-state logs follow the edge-swarm kit's fixtures: a
--     3-component state flipping between two directions (the automated
--     actor) against an 8-component varied walk.
--   * Ends with a HEADLINE line computed from the kit's own results (HEADLINE kit=<name> ok);
--     the build_test kit gate greps for it.

.print === 0. Sanity check: extension loaded? ===
SELECT fractalsql_edition(), fractalsql_version();

.print
.print === 1. Six markets x 96 days of price index ===
DROP TABLE IF EXISTS sed_price;
CREATE TABLE sed_price (
    ent TEXT,
    seq INTEGER,
    val REAL
);
WITH RECURSIVE gs(g) AS (SELECT 1 UNION ALL SELECT g + 1 FROM gs WHERE g < 96),
     s(ent, base, p1, p2) AS (VALUES
         ('mkt-a', 100, 0.12, 0),
         ('mkt-b', 80, 0.15, 0),
         ('mkt-c', 140, 0.1, 0),
         ('mkt-d', 120, 0.14, 0.0024),
         ('mkt-e', 90, 0.12, 0),
         ('mkt-f', 200, 0.08, 0))
INSERT INTO sed_price (ent, seq, val)
SELECT ent, g, base * (1.0 + p1 * sin(2 * pi() * g / 7.0) + 0.004 * (g % 5)) + CASE WHEN p2 > 0 AND g > 64 THEN base * p2 * (g - 64) * (g - 64) ELSE 0 END
FROM s, gs;

.print
.print === 2. Weekly cycle and non-linearity per market ===
DROP TABLE IF EXISTS sed_prof;
CREATE TABLE sed_prof AS
SELECT row_number() OVER (ORDER BY a.ent) AS pid, a.ent AS ent, round(m.mean_v, 4) AS mean_v, round(m.var_v, 4) AS var_v, fractal_dimension_dfa(a.arr) AS dfa_alpha, json_extract(a.pj, '$.freqs[0]') AS freq
FROM (SELECT ent, arr, fractal_periodogram(arr, 1) AS pj FROM (SELECT e.ent AS ent, (SELECT '[' || group_concat(printf('%.5f', v), ',') || ']' FROM (SELECT val AS v FROM sed_price s2 WHERE s2.ent = e.ent ORDER BY seq)) AS arr FROM (SELECT DISTINCT ent FROM sed_price) e)) a
JOIN (SELECT ent, avg(val) AS mean_v, avg(val * val) - avg(val) * avg(val) AS var_v
        FROM sed_price GROUP BY ent) m ON m.ent = a.ent
ORDER BY a.ent;
SELECT ent, mean_v, var_v, round(dfa_alpha, 3) AS dfa_alpha, round(freq, 4) AS top_freq, round(1.0 / freq, 1) AS samples_per_cycle
  FROM sed_prof ORDER BY ent;

.print
.print === 3. fractal_optimize_portfolio: pick 3 markets for the sink program ===
DROP TABLE IF EXISTS sed_result;
CREATE TABLE sed_result AS
SELECT fractal_optimize_portfolio(
    (SELECT group_concat(round(p.mean_v / 100.0, 4), ',')
       FROM (SELECT * FROM sed_prof ORDER BY pid) p),
    (SELECT group_concat(CASE WHEN a.pid = b.pid THEN round(a.var_v * a.dfa_alpha / 100.0, 4) ELSE 0 END, ',')
       FROM (SELECT * FROM sed_prof ORDER BY pid) a,
            (SELECT pid FROM sed_prof ORDER BY pid) b),
    3, 42) AS rj;

SELECT round(json_extract(rj, '$.sharpe'), 4) AS sharpe FROM sed_result;

.print --- the chosen entries (weight > 0; weights are in ent order) ---
SELECT p.ent, round(json_extract(je.value, '$'), 4) AS weight
FROM sed_result r, json_each(json_extract(r.rj, '$.weights')) je
JOIN sed_prof p ON p.pid = je.key + 1
WHERE json_extract(je.value, '$') > 0
ORDER BY weight DESC;
.print --- markets flagged for an emergency price cap (DFA exponent > 1.2) ---
SELECT ent, round(dfa_alpha, 3) AS dfa_alpha
  FROM sed_prof WHERE dfa_alpha > 1.2 ORDER BY dfa_alpha DESC;

.print
.print === 4. fractal_agent_detect_loop: automated actor vs varied actor ===
DROP TABLE IF EXISTS sed_loop;
CREATE TABLE sed_loop AS
WITH RECURSIVE walk(t) AS (SELECT 1 UNION ALL SELECT t + 1 FROM walk WHERE t < 24),
     a AS (SELECT fractal_agent_detect_loop(
               'varied-actor',
               (SELECT group_concat(v)
                  FROM (SELECT printf('%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f',
                          sin(t * 1.41421356), sin(t * 1.73205081), sin(t * 2.23606798),
                          sin(t * 2.64575131), sin(t * 3.31662479), sin(t * 3.60555128),
                          sin(t * 3.87298335), sin(t * 4.12310563)) AS v
                          FROM walk ORDER BY t)),
               8) AS j),
     b AS (SELECT fractal_agent_detect_loop(
               'auto-actor',
               (SELECT group_concat(v)
                  FROM (SELECT CASE WHEN t % 2 = 0 THEN '1,0,0' ELSE '0,1,0' END AS v
                          FROM walk ORDER BY t)),
               3) AS j)
SELECT json_extract(j, '$.agent_id') AS agent_id, json_extract(j, '$.is_loop_detected') AS is_loop,
       json_extract(j, '$.dfa_exponent') AS dfa_exponent FROM a
UNION ALL
SELECT json_extract(j, '$.agent_id'), json_extract(j, '$.is_loop_detected'),
       json_extract(j, '$.dfa_exponent') FROM b;

SELECT agent_id, is_loop, dfa_exponent FROM sed_loop ORDER BY agent_id;

.print
.print === 5. Reasoning: balance note ===
SELECT fractal_reason(
    'one-line balance note: the inflating market, the sink program, and the actor to block',
    json_object('inflating_market', (SELECT ent FROM sed_prof ORDER BY dfa_alpha DESC LIMIT 1), 'bot_loops', (SELECT count(*) FROM sed_loop WHERE is_loop = 1))) AS narrative;

.print
.print === 6. Headline check ===
SELECT 'HEADLINE kit=simulated-economy-drift ' || CASE WHEN (SELECT dfa_alpha FROM sed_prof WHERE ent = 'mkt-d') > 1.2 AND (SELECT count(*) FROM sed_prof WHERE dfa_alpha > 1.2) = 1 AND (SELECT freq FROM sed_prof WHERE ent = 'mkt-b') > 0.13 AND (SELECT freq FROM sed_prof WHERE ent = 'mkt-b') < 0.16 AND (SELECT is_loop FROM sed_loop WHERE agent_id = 'auto-actor') = 1 AND (SELECT is_loop FROM sed_loop WHERE agent_id = 'varied-actor') = 0 THEN 'ok' ELSE 'MISS' END AS headline;

.print
.print === Demo complete ===
.print Tables left in place for inspection. Clean up with:
.print   DROP TABLE sed_price; DROP TABLE sed_prof; DROP TABLE sed_result; DROP TABLE sed_loop;
