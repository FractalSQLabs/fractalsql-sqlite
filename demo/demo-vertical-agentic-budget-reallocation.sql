-- demo/demo-vertical-agentic-budget-reallocation.sql
--
-- Industry vertical: Agentic allocation: multi-source attribution and
-- dynamic cross-channel budget reallocation. AGENTIC kit: Six channels x 64
-- days of attributed outcomes. `fractal_dimension_dfa` finds the channel
-- whose response is accelerating (a non-linear surge a plain average would
-- hide); `fractal_optimize_portfolio` picks which 3 channels receive the
-- scheduled budget increase with the risk matrix inflated by the DFA
-- exponent; the surging channel is flagged for a capped, monitored test
-- instead. `fractal_agent_allocate` is the shipped one-call form of the
-- optimizer step, and `fractal_agent_route_task` dispatches each journey to
-- the best-matching model under a token budget.
--
--   1. fractal_dimension_dfa over each channel's daily outcomes: non-linear
--      response vs merely high.
--   2. fractal_optimize_portfolio (SFS): 3-of-6 budget increase, risk =
--      variance x DFA exponent.
--   3. fractal_agent_allocate: the same optimizer plus a reasoned
--      rationale, one call.
--   4. fractal_agent_route_task: each journey routed to the best-capable
--      model.
--   5. A closing fractal_reason() gives the reallocation rationale.
--
-- Prerequisites: the fractalsql extension loaded (.load ./fractalsql); the
-- agents ship inside it. The closing fractal_reason() narrative and any
-- shipped-agent rationale columns need the reasoning plugin
-- (docs/reasoning-setup.md); every other step runs with no model.
--
-- Run:
--   sqlite3 -cmd ".load ./fractalsql" :memory: ".read demo/demo-vertical-agentic-budget-reallocation.sql"
--
-- Safe to re-run: abr_* tables are dropped and recreated each time.
--
-- Notes:
--   * Fully deterministic fixtures (no random()).
--   * The optimizer maximizes a Sharpe-style ratio: mu is the mean daily
--     outcomes per unit of spend, the matrix is the response risk (variance
--     x DFA exponent).
--   * Model capability vectors = [single-step, recency-weighted, mid-path-
--     heavy, cross-device].
--   * Ends with a HEADLINE line computed from the kit's own results (HEADLINE kit=<name> ok);
--     the build_test kit gate greps for it.

.print === 0. Sanity check: extension loaded? ===
SELECT fractalsql_edition(), fractalsql_version();

.print
.print === 1. Six channels x 64 days of attributed outcomes ===
DROP TABLE IF EXISTS abr_outcome;
CREATE TABLE abr_outcome (
    ent TEXT,
    seq INTEGER,
    val REAL
);
WITH RECURSIVE gs(g) AS (SELECT 1 UNION ALL SELECT g + 1 FROM gs WHERE g < 64),
     s(ent, base, p1, p2) AS (VALUES
         ('channel-a', 120, 1, 0),
         ('channel-b', 95, 2, 0),
         ('channel-c', 140, 3, 0),
         ('channel-d', 110, 4, 0.45),
         ('channel-e', 160, 5, 0),
         ('channel-f', 85, 6, 0))
INSERT INTO abr_outcome (ent, seq, val)
SELECT ent, g, base * (1.0 + 0.06 * ((g + p1) % 7) / 7.0) + CASE WHEN p2 > 0 AND g > 40 THEN p2 * (g - 40) * (g - 40) ELSE 0 END
FROM s, gs;

.print
.print === 2. DFA exponent of each channel ===
DROP TABLE IF EXISTS abr_prof;
CREATE TABLE abr_prof AS
SELECT row_number() OVER (ORDER BY a.ent) AS pid, a.ent AS ent, round(m.mean_v, 4) AS mean_v, round(m.var_v, 4) AS var_v, fractal_dimension_dfa(a.arr) AS dfa_alpha
FROM (SELECT ent, arr FROM (SELECT e.ent AS ent, (SELECT '[' || group_concat(printf('%.5f', v), ',') || ']' FROM (SELECT val AS v FROM abr_outcome s2 WHERE s2.ent = e.ent ORDER BY seq)) AS arr FROM (SELECT DISTINCT ent FROM abr_outcome) e)) a
JOIN (SELECT ent, avg(val) AS mean_v, avg(val * val) - avg(val) * avg(val) AS var_v
        FROM abr_outcome GROUP BY ent) m ON m.ent = a.ent
ORDER BY a.ent;
SELECT ent, mean_v, var_v, round(dfa_alpha, 3) AS dfa_alpha
  FROM abr_prof ORDER BY ent;

.print
.print === 3. fractal_optimize_portfolio: pick 3 channels ===
DROP TABLE IF EXISTS abr_result;
CREATE TABLE abr_result AS
SELECT fractal_optimize_portfolio(
    (SELECT group_concat(round(p.mean_v / 100.0, 4), ',')
       FROM (SELECT * FROM abr_prof ORDER BY pid) p),
    (SELECT group_concat(CASE WHEN a.pid = b.pid THEN round(a.var_v * a.dfa_alpha / 100.0, 4) ELSE 0 END, ',')
       FROM (SELECT * FROM abr_prof ORDER BY pid) a,
            (SELECT pid FROM abr_prof ORDER BY pid) b),
    3, 42) AS rj;

SELECT round(json_extract(rj, '$.sharpe'), 4) AS sharpe FROM abr_result;

.print --- the chosen entries (weight > 0; weights are in ent order) ---
SELECT p.ent, round(json_extract(je.value, '$'), 4) AS weight
FROM abr_result r, json_each(json_extract(r.rj, '$.weights')) je
JOIN abr_prof p ON p.pid = je.key + 1
WHERE json_extract(je.value, '$') > 0
ORDER BY weight DESC;
.print --- channels flagged from Step 1 for a capped test (DFA exponent > 1.2) ---
SELECT ent, round(dfa_alpha, 3) AS dfa_alpha
  FROM abr_prof WHERE dfa_alpha > 1.2 ORDER BY dfa_alpha DESC;
.print --- the shipped agent: optimizer + reasoned rationale, one call (reasoning plugin) ---
SELECT fractal_agent_allocate(
    (SELECT group_concat(round(p.mean_v / 100.0, 4), ',')
       FROM (SELECT * FROM abr_prof ORDER BY pid) p),
    (SELECT group_concat(CASE WHEN a.pid = b.pid THEN round(a.var_v * a.dfa_alpha / 100.0, 4) ELSE 0 END, ',')
       FROM (SELECT * FROM abr_prof ORDER BY pid) a,
            (SELECT pid FROM abr_prof ORDER BY pid) b),
    3) AS allocation;

.print
.print === 4. Dispatch each journey to a routing model ===
DROP TABLE IF EXISTS abr_models;
CREATE TABLE abr_models (
    id INTEGER PRIMARY KEY,
    label TEXT,
    vec TEXT NOT NULL CHECK (fractal_vector_dims(vec) = 4)
);
INSERT INTO abr_models (id, label, vec) VALUES
    (1, 'single-step', '0.95,0.2,0.1,0.1'),
    (2, 'time-decay', '0.3,0.95,0.2,0.15'),
    (3, 'mid-path-weighted', '0.2,0.3,0.9,0.2'),
    (4, 'cross-device', '0.35,0.4,0.45,0.95');
DROP TABLE IF EXISTS abr_events;
CREATE TABLE abr_events (
    id INTEGER PRIMARY KEY,
    label TEXT,
    vec TEXT NOT NULL CHECK (fractal_vector_dims(vec) = 4)
);
INSERT INTO abr_events (id, label, vec) VALUES
    (1, 'J1 one-step direct path', '0.92,0.15,0.1,0.1'),
    (2, 'J2 week-long path, recent contact', '0.3,0.92,0.2,0.15'),
    (3, 'J3 multi-channel path, mid-touch heavy', '0.2,0.3,0.88,0.2'),
    (4, 'J4 cross-device path', '0.35,0.4,0.45,0.92'),
    (5, 'J5 direct return visit', '0.9,0.25,0.1,0.12');
DROP TABLE IF EXISTS abr_routed;
CREATE TABLE abr_routed AS
SELECT r.id AS req_id, r.label, json_extract(r.a, '$.routed_to') AS routed_to,
       json_extract(r.a, '$.confidence') AS confidence, json_extract(r.a, '$.remaining_budget') AS remaining_budget
FROM (SELECT id, label, fractal_agent_route_task(vec, 'abr_models', 'vec', 'label', 1000) AS a
        FROM abr_events) r
ORDER BY r.id;

SELECT req_id, label, routed_to, round(confidence, 4) AS confidence, remaining_budget FROM abr_routed ORDER BY req_id;

.print
.print === 5. Reasoning: reallocation rationale ===
SELECT fractal_reason(
    'one-line rationale for this cross-channel budget reallocation and the capped test on the surging channel',
    json_object('surging_channel', (SELECT ent FROM abr_prof ORDER BY dfa_alpha DESC LIMIT 1), 'top_dfa', (SELECT max(dfa_alpha) FROM abr_prof), 'journeys_routed', (SELECT count(*) FROM abr_routed))) AS narrative;

.print
.print === 6. Headline check ===
SELECT 'HEADLINE kit=agentic-budget-reallocation ' || CASE WHEN (SELECT dfa_alpha FROM abr_prof WHERE ent = 'channel-d') > 1.2 AND (SELECT count(*) FROM abr_prof WHERE dfa_alpha > 1.2) = 1 AND (SELECT count(*) FROM abr_routed) = 5 AND (SELECT routed_to FROM abr_routed WHERE req_id = 1) = 'single-step' AND (SELECT routed_to FROM abr_routed WHERE req_id = 4) = 'cross-device' THEN 'ok' ELSE 'MISS' END AS headline;

.print
.print === Demo complete ===
.print Tables left in place for inspection. Clean up with:
.print   DROP TABLE abr_outcome; DROP TABLE abr_prof; DROP TABLE abr_result; DROP TABLE abr_models; DROP TABLE abr_events; DROP TABLE abr_routed;
