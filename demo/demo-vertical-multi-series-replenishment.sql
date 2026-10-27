-- demo/demo-vertical-multi-series-replenishment.sql
--
-- Industry vertical: Multi-location replenishment: stockout prevention and
-- non-linear demand forecasting. AGENTIC kit: Six locations x 64 days of
-- unit demand. `fractal_dimension_dfa` finds the location whose demand is
-- accelerating (a viral item or a local event) rather than merely high;
-- `fractal_optimize_portfolio` picks which 3 locations get the scheduled
-- replenishment from the central hub with the risk matrix inflated by the
-- DFA exponent; the surging location is flagged for an expedited pick
-- instead. `fractal_agent_allocate` is the shipped one-call form of the
-- optimizer step.
--
--   1. fractal_dimension_dfa over each location's daily units: non-linear
--      vs merely high.
--   2. fractal_optimize_portfolio (SFS): 3-of-6 scheduled replenishment,
--      risk = variance x DFA exponent.
--   3. fractal_agent_allocate: the same optimizer plus a reasoned
--      rationale, one call.
--   4. A closing fractal_reason() writes the redistribution rationale.
--
-- Prerequisites: the fractalsql extension loaded (.load ./fractalsql); the
-- agents ship inside it. The closing fractal_reason() narrative and any
-- shipped-agent rationale columns need the reasoning plugin
-- (docs/reasoning-setup.md); every other step runs with no model.
--
-- Run:
--   sqlite3 -cmd ".load ./fractalsql" :memory: ".read demo/demo-vertical-multi-series-replenishment.sql"
--
-- Safe to re-run: msr_* tables are dropped and recreated each time.
--
-- Notes:
--   * Fully deterministic fixtures (no random()).
--   * mu is mean daily units per unit of stock moved; the matrix is demand
--     variance x DFA exponent.
--   * Ends with a HEADLINE line computed from the kit's own results (HEADLINE kit=<name> ok);
--     the build_test kit gate greps for it.

.print === 0. Sanity check: extension loaded? ===
SELECT fractalsql_edition(), fractalsql_version();

.print
.print === 1. Six locations x 64 days of unit demand ===
DROP TABLE IF EXISTS msr_units;
CREATE TABLE msr_units (
    ent TEXT,
    seq INTEGER,
    val REAL
);
WITH RECURSIVE gs(g) AS (SELECT 1 UNION ALL SELECT g + 1 FROM gs WHERE g < 64),
     s(ent, base, p1, p2) AS (VALUES
         ('loc-a', 130, 1, 0),
         ('loc-b', 105, 2, 0),
         ('loc-c', 150, 3, 0),
         ('loc-d', 115, 4, 0.4),
         ('loc-e', 170, 5, 0),
         ('loc-f', 90, 6, 0))
INSERT INTO msr_units (ent, seq, val)
SELECT ent, g, base * (1.0 + 0.10 * ((g + p1) % 7) / 7.0) + CASE WHEN p2 > 0 AND g > 40 THEN p2 * (g - 40) * (g - 40) ELSE 0 END
FROM s, gs;

.print
.print === 2. DFA exponent of each location ===
DROP TABLE IF EXISTS msr_prof;
CREATE TABLE msr_prof AS
SELECT row_number() OVER (ORDER BY a.ent) AS pid, a.ent AS ent, round(m.mean_v, 4) AS mean_v, round(m.var_v, 4) AS var_v, fractal_dimension_dfa(a.arr) AS dfa_alpha
FROM (SELECT ent, arr FROM (SELECT e.ent AS ent, (SELECT '[' || group_concat(printf('%.5f', v), ',') || ']' FROM (SELECT val AS v FROM msr_units s2 WHERE s2.ent = e.ent ORDER BY seq)) AS arr FROM (SELECT DISTINCT ent FROM msr_units) e)) a
JOIN (SELECT ent, avg(val) AS mean_v, avg(val * val) - avg(val) * avg(val) AS var_v
        FROM msr_units GROUP BY ent) m ON m.ent = a.ent
ORDER BY a.ent;
SELECT ent, mean_v, var_v, round(dfa_alpha, 3) AS dfa_alpha
  FROM msr_prof ORDER BY ent;

.print
.print === 3. fractal_optimize_portfolio: pick 3 locations ===
DROP TABLE IF EXISTS msr_result;
CREATE TABLE msr_result AS
SELECT fractal_optimize_portfolio(
    (SELECT group_concat(round(p.mean_v / 100.0, 4), ',')
       FROM (SELECT * FROM msr_prof ORDER BY pid) p),
    (SELECT group_concat(CASE WHEN a.pid = b.pid THEN round(a.var_v * a.dfa_alpha / 100.0, 4) ELSE 0 END, ',')
       FROM (SELECT * FROM msr_prof ORDER BY pid) a,
            (SELECT pid FROM msr_prof ORDER BY pid) b),
    3, 42) AS rj;

SELECT round(json_extract(rj, '$.sharpe'), 4) AS sharpe FROM msr_result;

.print --- the chosen entries (weight > 0; weights are in ent order) ---
SELECT p.ent, round(json_extract(je.value, '$'), 4) AS weight
FROM msr_result r, json_each(json_extract(r.rj, '$.weights')) je
JOIN msr_prof p ON p.pid = je.key + 1
WHERE json_extract(je.value, '$') > 0
ORDER BY weight DESC;
.print --- locations flagged for an expedited pick (DFA exponent > 1.2) ---
SELECT ent, round(dfa_alpha, 3) AS dfa_alpha
  FROM msr_prof WHERE dfa_alpha > 1.2 ORDER BY dfa_alpha DESC;
.print --- the shipped agent: optimizer + reasoned rationale, one call (reasoning plugin) ---
SELECT fractal_agent_allocate(
    (SELECT group_concat(round(p.mean_v / 100.0, 4), ',')
       FROM (SELECT * FROM msr_prof ORDER BY pid) p),
    (SELECT group_concat(CASE WHEN a.pid = b.pid THEN round(a.var_v * a.dfa_alpha / 100.0, 4) ELSE 0 END, ',')
       FROM (SELECT * FROM msr_prof ORDER BY pid) a,
            (SELECT pid FROM msr_prof ORDER BY pid) b),
    3) AS allocation;

.print
.print === 4. Reasoning: redistribution rationale ===
SELECT fractal_reason(
    'one-line redistribution rationale: which locations get scheduled stock and which needs an expedited pick',
    json_object('surging_location', (SELECT ent FROM msr_prof ORDER BY dfa_alpha DESC LIMIT 1), 'top_dfa', (SELECT max(dfa_alpha) FROM msr_prof))) AS narrative;

.print
.print === 5. Headline check ===
SELECT 'HEADLINE kit=multi-series-replenishment ' || CASE WHEN (SELECT dfa_alpha FROM msr_prof WHERE ent = 'loc-d') > 1.2 AND (SELECT count(*) FROM msr_prof WHERE dfa_alpha > 1.2) = 1 THEN 'ok' ELSE 'MISS' END AS headline;

.print
.print === Demo complete ===
.print Tables left in place for inspection. Clean up with:
.print   DROP TABLE msr_units; DROP TABLE msr_prof; DROP TABLE msr_result;
