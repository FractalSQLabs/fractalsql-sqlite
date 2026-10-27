-- demo/demo-vertical-avionics-fault-prediction.sql
--
-- Industry vertical: aerospace -- avionics and flight-path fault
-- prediction across a fleet.  DOMAIN kit built on one installed agent,
-- fractal_agent_track_anomaly, which generalizes directly from the
-- maritime-defense kit's 2D tracks to 3D flight paths: same agent, same
-- contract (trajectory deviation search + heading-change DFA exponent),
-- closing with a reasoned classification of the deviation.
--
-- Prerequisites: extension loaded.  Sections 1-3 need no model; the
-- shipped agent and the closing classification are reasoning-bearing
-- (clean hint without a plugin; see ../docs/reasoning-setup.md).
--
-- Run (one invocation):
--   sqlite3 -cmd ".load /usr/local/lib/sqlite3/fractalsql" ":memory:" \
--     ".read demo/demo-vertical-avionics-fault-prediction.sql"
--
-- Notes:
--   * Fully deterministic fixture: heading noise comes from an integer
--     LCG in a recursive CTE, not random().
--   * Each flight carries a planned-path vector and its latest-state
--     vector, [x_km, y_km, altitude_km] in CSV TEXT guarded by
--     CHECK(fractal_vector_dims(...) = 3).  Flight AC-09 has a stuck
--     control surface: its path has drifted off plan and its heading
--     changes become erratic for a stretch of the flight.
--   * trajectory doc_id is the 0-based scan position; afp_flights ids are
--     contiguous from 1 in insertion order, so doc_id = id - 1.
--   * DFA needs a reasonable series length (a few dozen points at
--     minimum); the heading series here is 120 samples.
--
-- Safe to re-run: the afp_* tables are dropped and recreated each time.

.timer on

.print === 0. Sanity check: extension loaded? ===
SELECT fractalsql_edition(), fractalsql_version();

-- ------------------------------------------------------------------
-- 1. A 12-aircraft fleet: planned path vs current state in 3D.  Eleven
-- are on plan to within small offsets; AC-09 has drifted far off plan
-- (lateral and vertical).
-- ------------------------------------------------------------------
.print
.print === 1. Fleet: planned path vs current state (3D) ===

DROP TABLE IF EXISTS afp_flights;
CREATE TABLE afp_flights (
    id        INTEGER PRIMARY KEY,
    flight    TEXT,
    baseline  TEXT NOT NULL CHECK (fractal_vector_dims(baseline) = 3),
    current   TEXT NOT NULL CHECK (fractal_vector_dims(current) = 3)
);

WITH RECURSIVE gs(g) AS (SELECT 1 UNION ALL SELECT g + 1 FROM gs WHERE g < 12)
INSERT INTO afp_flights (flight, baseline, current)
SELECT printf('AC-%02d', g),
       printf('%.3f,%.3f,%.3f', 0.20 + 0.05 * g, 0.40 + 0.02 * (g % 4), 0.80),
       printf('%.3f,%.3f,%.3f', 0.20 + 0.05 * g + 0.004 * (g % 3),
              0.40 + 0.02 * (g % 4) + 0.003 * (g % 2), 0.80 - 0.002 * (g % 3))
FROM gs;

-- AC-09: far off plan.
UPDATE afp_flights SET current = '0.900,1.400,0.350' WHERE flight = 'AC-09';

SELECT flight, baseline, current FROM afp_flights WHERE flight IN ('AC-01', 'AC-09');

-- ------------------------------------------------------------------
-- 2. Heading-change series: a steady transit (small noise) vs AC-09's
-- erratic stretch (large swings between samples 60 and 90).  The
-- running sum is the heading walk the DFA exponent is computed on.
-- ------------------------------------------------------------------
.print
.print === 2. DFA of the heading walk: steady flight vs AC-09 ===

WITH RECURSIVE n(t, x) AS (
       SELECT 1, 7919 UNION ALL
       SELECT t + 1, (x * 1103515245 + 12345) % 2147483648 FROM n WHERE t < 120),
     steps AS (SELECT t, ((x / 65536) % 1000 - 500) / 1000.0 AS u FROM n),
     walk AS (SELECT t, sum(u * 0.03) OVER (ORDER BY t) AS s FROM steps)
SELECT 'steady flight' AS series,
       round(fractal_dimension_dfa(
         '[' || (SELECT group_concat(printf('%.6f', s), ',') FROM walk) || ']'), 3) AS dfa_alpha;

WITH RECURSIVE n(t, x) AS (
       SELECT 1, 7919 UNION ALL
       SELECT t + 1, (x * 1103515245 + 12345) % 2147483648 FROM n WHERE t < 120),
     steps AS (SELECT t, ((x / 65536) % 1000 - 500) / 1000.0 AS u FROM n),
     walk AS (SELECT t, sum(u * CASE WHEN t BETWEEN 60 AND 90 THEN 0.35 ELSE 0.03 END)
                        OVER (ORDER BY t) AS s FROM steps)
SELECT 'AC-09 erratic stretch' AS series,
       round(fractal_dimension_dfa(
         '[' || (SELECT group_concat(printf('%.6f', s), ',') FROM walk) || ']'), 3) AS dfa_alpha;

-- ------------------------------------------------------------------
-- 3. Hand-composed: trajectory deviation of AC-09 -- the fleet members
-- nearest to its planned path and to where it is now.
-- ------------------------------------------------------------------
.print
.print === 3. AC-09 baseline -> current trajectory search ===

WITH tr AS (SELECT fractal_search_trajectory(
                    'afp_flights', 'current',
                    (SELECT baseline FROM afp_flights WHERE flight = 'AC-09'),
                    (SELECT current  FROM afp_flights WHERE flight = 'AC-09'),
                    5) AS tj)
SELECT f.flight, round(json_extract(je.value, '$.distance'), 4) AS distance
FROM tr, json_each(tr.tj) je
JOIN afp_flights f ON f.id - 1 = json_extract(je.value, '$.doc_id')
ORDER BY json_extract(je.value, '$.distance');

-- ------------------------------------------------------------------
-- 4. The shipped agent: trajectory deviation + heading DFA + a reasoned
-- classification in one call (reasoning plugin).
-- ------------------------------------------------------------------
.print
.print === 4. fractal_agent_track_anomaly (3D flight path) ===

WITH RECURSIVE n(t, x) AS (
       SELECT 1, 7919 UNION ALL
       SELECT t + 1, (x * 1103515245 + 12345) % 2147483648 FROM n WHERE t < 120),
     steps AS (SELECT t, ((x / 65536) % 1000 - 500) / 1000.0 AS u FROM n),
     walk AS (SELECT t, sum(u * CASE WHEN t BETWEEN 60 AND 90 THEN 0.35 ELSE 0.03 END)
                        OVER (ORDER BY t) AS s FROM steps)
SELECT fractal_agent_track_anomaly(
    'afp_flights', 'current',
    (SELECT baseline FROM afp_flights WHERE flight = 'AC-09'),
    (SELECT current  FROM afp_flights WHERE flight = 'AC-09'),
    '[' || (SELECT group_concat(printf('%.6f', s), ',') FROM walk) || ']') AS flight_anomaly;

-- ------------------------------------------------------------------
-- 5. Reasoning: classify the deviation (plugin-gated; the clean hint is
-- the expected output without one).
-- ------------------------------------------------------------------
.print
.print === 5. Reasoning: classify the deviation ===

SELECT fractal_reason(
    'one-line classification of this flight-path deviation: sensor fault, control-surface fault, or weather',
    (SELECT fractal_search_trajectory('afp_flights', 'current',
            (SELECT baseline FROM afp_flights WHERE flight = 'AC-09'),
            (SELECT current  FROM afp_flights WHERE flight = 'AC-09'), 3)));

.print
.print === Demo complete ===
.print Tables left in place for inspection. Clean up with:
.print   DROP TABLE afp_flights;
