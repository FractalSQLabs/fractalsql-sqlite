-- demo/demo-vertical-ev-battery-lifecycle.sql
--
-- Industry vertical: Electric-vehicle fleet battery lifecycle -- state-of-
-- health (SoH) and thermal-regime monitoring.  AGENTIC kit: two installed
-- agents are chained, shown hand-composed first and then as the shipped
-- one-call agents.
--
--   1. fractal_agent_patient_deterioration_triage -- cohort search plus
--      baseline-vs-current trajectory drift.  Its contract is domain-
--      neutral (a vehicle's intake baseline plays the patient's admission
--      baseline), so the kit only supplies different columns.
--   2. fractal_agent_anomaly_triage -- the DFA drift exponent of one
--      vehicle's temperature series, flagging a shift into a new regime
--      (pre-thermal-runaway) independently of the SoH comparison.
--   3. A closing fractal_reason() synthesizes both signals into one
--      maintenance / safety recommendation.
--
-- Prerequisites: extension loaded.  Sections 1-4 need nothing else; the
-- rationale columns and Section 5 need the reasoning plugin -- see
-- ../docs/reasoning-setup.md (clean error hint without one; the analytic
-- sections still run).
--
-- Run (one invocation):
--   sqlite3 -cmd ".load /usr/local/lib/sqlite3/fractalsql" ":memory:" \
--     ".read demo/demo-vertical-ev-battery-lifecycle.sql"
--
-- Notes:
--   * Fully deterministic: the fixture is built from a recursive CTE with
--     fixed wobble, no random(), so every run returns the same numbers.
--   * Readings are CSV TEXT guarded by CHECK(fractal_vector_dims(...)=4):
--     [soh, temp_z, volt_z, fade_rate] is a fixed-width record, so a
--     malformed write from a telematics integration fails loudly at write
--     time instead of silently corrupting a vehicle's history.
--   * The temperature series needs >= 48 points per vehicle for the 32-
--     point drift window (DFA needs the recent window large enough).
--     The fault is an accelerating ramp, not a level shift: DFA removes a
--     constant offset, so only a change in the series' dynamics registers.
--   * telemetry/trajectory doc_id is the 0-based scan position; ebl_*
--     ids are contiguous from 1 in insertion order, so doc_id = id - 1.
--
-- Safe to re-run: the ebl_* tables are dropped and recreated each time.

.timer on

.print === 0. Sanity check: extension loaded? ===
SELECT fractalsql_edition(), fractalsql_version();

-- ------------------------------------------------------------------
-- 1. Fleet telemetry: 3 vehicles x 96 readings.  EV-101 and EV-102 age
-- gently.  EV-203 develops a fault at reading 65: an accelerating
-- (quadratic) thermal ramp, a voltage sag and an accelerating SoH fade.
-- ------------------------------------------------------------------
.print
.print === 1. Fleet telemetry: 3 vehicles x 96 readings ===

DROP TABLE IF EXISTS ebl_telemetry;
CREATE TABLE ebl_telemetry (
    id         INTEGER PRIMARY KEY,
    vin        TEXT,
    model_year INTEGER,
    seq        INTEGER,          -- reading order within the vehicle
    soh        REAL,             -- state of health, fraction of nominal capacity
    temp_c     REAL,             -- pack temperature
    volt       REAL,             -- mean cell voltage under load
    state      TEXT NOT NULL
               CHECK (fractal_vector_dims(state) = 4)
);

WITH RECURSIVE gs(g) AS (SELECT 1 UNION ALL SELECT g + 1 FROM gs WHERE g < 96),
     v(vi, vin, my) AS (VALUES (1, 'EV-101', 2024), (2, 'EV-102', 2024), (3, 'EV-203', 2023)),
     r AS (
       SELECT vi, vin, my, g,
              0.99 - 0.0004 * g
                - CASE WHEN vin = 'EV-203' AND g > 64 THEN 0.004 * (g - 64) ELSE 0 END AS soh,
              31.0 + (g % 8) * 0.6
                + CASE WHEN vin = 'EV-203' AND g > 64
                       THEN 0.02 * (g - 64) * (g - 64) ELSE 0 END AS temp_c,
              3.72 - (g % 5) * 0.004
                - CASE WHEN vin = 'EV-203' AND g > 64 THEN 0.09 ELSE 0 END AS volt
         FROM v, gs)
INSERT INTO ebl_telemetry (vin, model_year, seq, soh, temp_c, volt, state)
SELECT vin, my, g, soh, temp_c, volt,
       printf('%.4f,%.4f,%.4f,%.4f',
              soh, (temp_c - 35.0) / 10.0, (volt - 3.70) / 0.10,
              (0.99 - soh) / g)
  FROM r
 ORDER BY vi, g;

SELECT vin, count(*) AS readings, round(min(soh), 3) AS min_soh,
       round(max(temp_c), 1) AS max_temp_c
  FROM ebl_telemetry GROUP BY vin ORDER BY vin;

-- ------------------------------------------------------------------
-- 2. Step 1, hand-composed: baseline-vs-current trajectory search.
-- EV-203's intake baseline vs its latest reading; the nearest fleet
-- readings to each end show which vehicles it has moved away from /
-- toward.  (fractal_search_trajectory returns nearest rows to the
-- baseline and to the current state.)
-- ------------------------------------------------------------------
.print
.print === 2. Step 1 (hand-composed): EV-203 baseline -> current trajectory ===

WITH tr AS (SELECT fractal_search_trajectory(
                    'ebl_telemetry', 'state',
                    (SELECT state FROM ebl_telemetry WHERE vin = 'EV-203' AND seq = 1),
                    (SELECT state FROM ebl_telemetry WHERE vin = 'EV-203' AND seq = 96),
                    5) AS tj)
SELECT t.vin, t.seq,
       round(json_extract(je.value, '$.distance'), 4) AS distance
FROM tr, json_each(tr.tj) je
JOIN ebl_telemetry t ON t.id - 1 = json_extract(je.value, '$.doc_id')
ORDER BY json_extract(je.value, '$.distance');

-- ------------------------------------------------------------------
-- 3. Step 1, productized: the shipped agent.  The cohort is caller-
-- built with ordinary SQL (model year 2023, the cohort EV-203 belongs
-- to); nearest_cohort_id / cohort_distance / drift_distance are real.
-- Reasoning-bearing: needs the plugin (clean hint without one).
-- ------------------------------------------------------------------
.print
.print === 3. Step 1 (shipped agent): fractal_agent_patient_deterioration_triage ===

SELECT fractal_agent_patient_deterioration_triage(
    'ebl_telemetry', 'state',
    (SELECT state FROM ebl_telemetry WHERE vin = 'EV-203' AND seq = 96),
    (SELECT state FROM ebl_telemetry WHERE vin = 'EV-203' AND seq = 1),
    (SELECT state FROM ebl_telemetry WHERE vin = 'EV-203' AND seq = 96),
    (SELECT group_concat(id) FROM ebl_telemetry WHERE model_year = 2023),
    5) AS soh_triage;

-- ------------------------------------------------------------------
-- 4. Step 2, hand-composed then productized: temperature-regime drift.
-- fractal_dimension_drift on each vehicle's temperature series; the
-- healthy pair sits near zero (slightly negative), EV-203's accelerating
-- ramp pushes the recent-window exponent far above its baseline.  (DFA
-- measures how the series' fluctuation scales, so the regime change is a
-- change in dynamics -- a pure level shift would not move it.)
-- ------------------------------------------------------------------
.print
.print === 4. Step 2 (hand-composed): temperature-regime drift per vehicle ===

SELECT vin,
       round(json_extract(d, '$.drift'), 4)          AS drift,
       round(json_extract(d, '$.recent_alpha'), 4)   AS recent_alpha,
       round(json_extract(d, '$.baseline_alpha'), 4) AS baseline_alpha
FROM (SELECT vin,
             fractal_dimension_drift(
               (SELECT '[' || group_concat(printf('%.4f', temp_c), ',') || ']'
                  FROM (SELECT temp_c FROM ebl_telemetry e2
                         WHERE e2.vin = e.vin ORDER BY seq)), 32) AS d
        FROM (SELECT DISTINCT vin FROM ebl_telemetry) e)
ORDER BY vin;

.print --- the shipped agent: same composition, one call (reasoning plugin) ---
SELECT fractal_agent_anomaly_triage(
    'ebl_telemetry', 'temp_c', 'seq', 'vin', 'EV-203', 32) AS thermal_triage;

-- ------------------------------------------------------------------
-- 5. Reasoning: one maintenance / safety recommendation over BOTH
-- signals (plugin-gated; the clean hint is the expected output
-- without one).
-- ------------------------------------------------------------------
.print
.print === 5. Reasoning: maintenance / safety recommendation for EV-203 ===

SELECT fractal_reason(
    'one-line maintenance and safety recommendation for an EV pack showing '
    || 'both an accelerating state-of-health fade and a thermal regime shift',
    json_object(
      'soh_trajectory', json((SELECT fractal_search_trajectory(
            'ebl_telemetry', 'state',
            (SELECT state FROM ebl_telemetry WHERE vin = 'EV-203' AND seq = 1),
            (SELECT state FROM ebl_telemetry WHERE vin = 'EV-203' AND seq = 96), 3))),
      'thermal_drift', json((SELECT fractal_dimension_drift(
            (SELECT '[' || group_concat(printf('%.4f', temp_c), ',') || ']'
               FROM (SELECT temp_c FROM ebl_telemetry
                      WHERE vin = 'EV-203' ORDER BY seq)), 32)))));

.print
.print === Demo complete ===
.print Tables left in place for inspection. Clean up with:
.print   DROP TABLE ebl_telemetry;
