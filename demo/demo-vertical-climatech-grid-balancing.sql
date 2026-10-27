-- demo/demo-vertical-climatech-grid-balancing.sql
--
-- Industry vertical: Climate Tech -- renewable and storage generation
-- balancing on a distribution grid.  AGENTIC kit: a hand-composed chain,
-- then the shipped agents doing each step in one call.
--
--   1. fractal_dimension_dfa / _drift over grid-frequency telemetry --
--      detects a stability regime change (the same recipe the quant-
--      finance kit uses for volatility regimes, applied to a grid).
--   2. fractal_optimize_portfolio (SFS) -- reallocates generation and
--      storage dispatch across nodes under a cardinality constraint,
--      using a ramp-risk matrix in which correlated renewables carry
--      shared weather risk.
--   3. A closing fractal_reason() gives the dispatch-plan rationale.
--
-- Prerequisites: extension loaded.  Sections 1-3 run with no model; the
-- shipped agents and the closing rationale are reasoning-bearing (clean
-- hint without a plugin; see ../docs/reasoning-setup.md).
--
-- Run (one invocation):
--   sqlite3 -cmd ".load /usr/local/lib/sqlite3/fractalsql" ":memory:" \
--     ".read demo/demo-vertical-climatech-grid-balancing.sql"
--
-- Notes:
--   * Fully deterministic fixture (no random()).
--   * The drift window is 32 points, so each area needs >= 48 readings.
--     The instability is an ACCELERATING oscillation envelope, not a
--     level shift: DFA removes a constant offset, so only a change in the
--     series' dynamics moves the exponent.
--   * The optimizer maximizes a Sharpe-style ratio: mu is dispatch value
--     per unit of capacity moved, the matrix is ramp risk.  Two variable
--     renewables (solar, wind) share weather risk (correlation 0.6);
--     batteries and hydro are nearly independent.
--
-- Safe to re-run: the cgb_* tables are dropped and recreated each time.

.timer on

.print === 0. Sanity check: extension loaded? ===
SELECT fractalsql_edition(), fractalsql_version();

-- ------------------------------------------------------------------
-- 1. Grid-frequency telemetry for three balancing areas, 96 samples
-- each (deviation from nominal, mHz).  AREA-C loses damping from sample
-- 65: its oscillation envelope grows quadratically.
-- ------------------------------------------------------------------
.print
.print === 1. Grid-frequency deviation: 3 areas x 96 samples ===

DROP TABLE IF EXISTS cgb_freq;
CREATE TABLE cgb_freq (
    area   TEXT,
    sample INTEGER,
    dev_mhz REAL
);
WITH RECURSIVE gs(g) AS (SELECT 1 UNION ALL SELECT g + 1 FROM gs WHERE g < 96),
     a(area) AS (VALUES ('AREA-A'), ('AREA-B'), ('AREA-C'))
INSERT INTO cgb_freq (area, sample, dev_mhz)
SELECT area, g,
       4.0 + (g % 8) * 0.8
         + CASE WHEN area = 'AREA-C' AND g > 64
                THEN 0.02 * (g - 64) * (g - 64) ELSE 0 END
FROM a, gs;

SELECT area, count(*) AS samples, round(max(dev_mhz), 2) AS peak_dev_mhz
  FROM cgb_freq GROUP BY area ORDER BY area;

-- ------------------------------------------------------------------
-- 2. Step 1, hand-composed: stability-regime drift per area.
-- ------------------------------------------------------------------
.print
.print === 2. Step 1 (hand-composed): frequency-stability drift per area ===

SELECT area,
       round(json_extract(d, '$.drift'), 4)          AS drift,
       round(json_extract(d, '$.recent_alpha'), 4)   AS recent_alpha,
       round(json_extract(d, '$.baseline_alpha'), 4) AS baseline_alpha
FROM (SELECT area,
             fractal_dimension_drift(
               (SELECT '[' || group_concat(printf('%.4f', dev_mhz), ',') || ']'
                  FROM (SELECT dev_mhz FROM cgb_freq f2
                         WHERE f2.area = f.area ORDER BY sample)), 32) AS d
        FROM (SELECT DISTINCT area FROM cgb_freq) f)
ORDER BY area;

.print --- the shipped agent: same composition, one call (reasoning plugin) ---
SELECT fractal_agent_anomaly_triage(
    'cgb_freq', 'dev_mhz', 'sample', 'area', 'AREA-C', 32) AS stability_triage;

-- ------------------------------------------------------------------
-- 3. Step 2: the dispatch set.  Six resources; pick the 4 that carry
-- the AREA-C instability response with the best risk-adjusted value.
-- ------------------------------------------------------------------
.print
.print === 3. Step 2: fractal_optimize_portfolio -- pick 4 of 6 resources ===

DROP TABLE IF EXISTS cgb_resources;
CREATE TABLE cgb_resources (
    id        INTEGER PRIMARY KEY,
    name      TEXT,
    class     TEXT,
    value_mu  REAL,      -- dispatch value per unit of capacity moved
    ramp_risk REAL       -- ramp-rate risk, MW/min scaled
);
INSERT INTO cgb_resources (name, class, value_mu, ramp_risk) VALUES
    ('solar-farm-north',  'variable', 0.090, 0.30),
    ('wind-park-ridge',   'variable', 0.100, 0.35),
    ('battery-4h-east',   'storage',  0.070, 0.08),
    ('battery-2h-west',   'storage',  0.060, 0.07),
    ('pumped-hydro',      'dispatch', 0.080, 0.10),
    ('gas-peaker',        'dispatch', 0.110, 0.20);

-- Flat row-major risk matrix: ramp_i * ramp_j * rho, with rho = 1 on the
-- diagonal, 0.6 between two variable renewables, 0.1 otherwise.
DROP TABLE IF EXISTS cgb_result;
CREATE TABLE cgb_result AS
SELECT fractal_optimize_portfolio(
    (SELECT group_concat(value_mu, ',') FROM (SELECT value_mu FROM cgb_resources ORDER BY id)),
    (SELECT group_concat(round(a.ramp_risk * b.ramp_risk *
                CASE WHEN a.id = b.id THEN 1.0
                     WHEN a.class = 'variable' AND b.class = 'variable' THEN 0.6
                     ELSE 0.1 END, 6), ',')
       FROM (SELECT * FROM cgb_resources ORDER BY id) a,
            (SELECT * FROM cgb_resources ORDER BY id) b),
    4, 42) AS rj;

SELECT round(json_extract(rj, '$.sharpe'), 4) AS sharpe FROM cgb_result;

.print --- the dispatch set (weight > 0; weights are in resource id order) ---
SELECT r.name, r.class, round(json_extract(je.value, '$'), 4) AS dispatch_weight
FROM cgb_result c, json_each(json_extract(c.rj, '$.weights')) je
JOIN cgb_resources r ON r.id = je.key + 1
WHERE json_extract(je.value, '$') > 0
ORDER BY dispatch_weight DESC;

.print --- the shipped agent: optimizer + reasoned rationale, one call (reasoning plugin) ---
SELECT fractal_agent_allocate(
    (SELECT group_concat(value_mu, ',') FROM (SELECT value_mu FROM cgb_resources ORDER BY id)),
    (SELECT group_concat(round(a.ramp_risk * b.ramp_risk *
                CASE WHEN a.id = b.id THEN 1.0
                     WHEN a.class = 'variable' AND b.class = 'variable' THEN 0.6
                     ELSE 0.1 END, 6), ',')
       FROM (SELECT * FROM cgb_resources ORDER BY id) a,
            (SELECT * FROM cgb_resources ORDER BY id) b),
    4) AS dispatch_plan;

-- ------------------------------------------------------------------
-- 4. Reasoning: the dispatch-plan rationale (plugin-gated; the clean
-- hint is the expected output without one).
-- ------------------------------------------------------------------
.print
.print === 4. Reasoning: dispatch-plan rationale ===

SELECT fractal_reason(
    'one-line rationale for this grid dispatch plan given the frequency-stability drift in AREA-C',
    json_object(
      'area_c_drift', json((SELECT fractal_dimension_drift(
            (SELECT '[' || group_concat(printf('%.4f', dev_mhz), ',') || ']'
               FROM (SELECT dev_mhz FROM cgb_freq WHERE area = 'AREA-C' ORDER BY sample)), 32))),
      'dispatch', json((SELECT rj FROM cgb_result))));

.print
.print === Demo complete ===
.print Tables left in place for inspection. Clean up with:
.print   DROP TABLE cgb_freq; DROP TABLE cgb_resources; DROP TABLE cgb_result;
