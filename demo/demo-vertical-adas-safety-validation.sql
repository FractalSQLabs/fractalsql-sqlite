-- demo/demo-vertical-adas-safety-validation.sql
--
-- Industry vertical: ADAS / autonomous-driving safety validation --
-- edge-case interception before a maneuver is committed.  AGENTIC kit:
-- two signals are composed, shown hand-composed first and then as the
-- shipped one-call agent.
--
--   1. fractal_agent_outlier_intercept -- a pre-commit safety barrier:
--      screens a PROPOSED vehicle state vector against a history of
--      known-bad states (prior disengagements and near-misses), exactly
--      its designed contract.
--   2. fractal_search_trajectory -- flags when the vehicle's current
--      routing vector has moved away from the fleet baseline.
--   3. A closing fractal_reason() turns both signals into one verdict.
--
-- Prerequisites: extension loaded.  The hand-composed sections (2, 4) run
-- with no reasoning endpoint; the shipped outlier_intercept agent returns
-- a reasoned `reason`, so Sections 3 and 5 need the plugin (clean hint
-- without one) -- see ../docs/reasoning-setup.md.
--
-- Run (one invocation):
--   sqlite3 -cmd ".load /usr/local/lib/sqlite3/fractalsql" ":memory:" \
--     ".read demo/demo-vertical-adas-safety-validation.sql"
--
-- Notes:
--   * Fully deterministic fixture (no random()).
--   * State vectors are [speed_z, lateral_accel_z, brake_z, steer_rate_z]
--     in CSV TEXT.  The intercept distance is COSINE by default, which
--     ignores magnitude: a mild maneuver in the same direction as a known-
--     bad one is intercepted too.  Pass 'l2' as the fifth argument when
--     magnitude should count (Section 3).
--   * telemetry doc_id IS the row's rowid; trajectory doc_id is the
--     0-based scan position, and asv_routes ids are contiguous from 1 in
--     insertion order, so there doc_id = id - 1.
--
-- Safe to re-run: the asv_* tables are dropped and recreated each time.

.timer on

.print === 0. Sanity check: extension loaded? ===
SELECT fractalsql_edition(), fractalsql_version();

-- ------------------------------------------------------------------
-- 1. Known-bad state history and three proposed maneuvers.
-- ------------------------------------------------------------------
.print
.print === 1. Known-bad history + proposed maneuvers ===

DROP TABLE IF EXISTS asv_known_bad;
CREATE TABLE asv_known_bad (
    id       INTEGER PRIMARY KEY,
    scenario TEXT,
    state    TEXT NOT NULL CHECK (fractal_vector_dims(state) = 4)
);
INSERT INTO asv_known_bad (scenario, state) VALUES
    ('hard brake at highway speed',   '0.90,0.10,0.95,0.10'),
    ('evasive swerve',                '0.50,0.90,0.20,0.95'),
    ('late brake approaching a stop', '0.40,0.05,0.90,0.05'),
    ('lane drift under load',         '0.70,0.60,0.05,0.30');

DROP TABLE IF EXISTS asv_proposed;
CREATE TABLE asv_proposed (
    id    INTEGER PRIMARY KEY,
    label TEXT,
    state TEXT NOT NULL CHECK (fractal_vector_dims(state) = 4)
);
INSERT INTO asv_proposed (label, state) VALUES
    ('P1 firm brake, high speed',   '0.88,0.12,0.90,0.15'),
    ('P2 steady cruise',            '0.55,0.02,0.02,0.01'),
    ('P3 gentle lane change',       '0.45,0.35,0.05,0.30');

SELECT count(*) AS known_bad_states FROM asv_known_bad;

-- ------------------------------------------------------------------
-- 2. Step 1, hand-composed: nearest known-bad state per proposal.
-- ------------------------------------------------------------------
.print
.print === 2. Step 1 (hand-composed): nearest known-bad state, threshold 0.15 ===

SELECT p.label,
       (SELECT k.scenario FROM asv_known_bad k
         WHERE k.id = json_extract(je.value, '$.doc_id')) AS nearest_bad,
       round(json_extract(je.value, '$.distance'), 4) AS distance,
       (json_extract(je.value, '$.distance') < 0.15) AS intercepted
FROM asv_proposed p,
     json_each(fractal_search_telemetry('asv_known_bad', 'state', p.state, 1)) je
ORDER BY p.id;

-- ------------------------------------------------------------------
-- 3. Step 1, productized: the shipped agent (its `reason` field is
-- reasoning-bearing).  Note P3: the cosine check intercepts it (same
-- direction as the known-bad lane drift, just gentler); exact Euclidean
-- distance lets it through because magnitude counts.
-- ------------------------------------------------------------------
.print
.print === 3. Step 1 (shipped agent): fractal_agent_outlier_intercept ===

SELECT p.label,
       fractal_agent_outlier_intercept(p.state, 'asv_known_bad', 'state', 0.15) AS verdict
FROM asv_proposed p ORDER BY p.id;

.print --- same check under exact Euclidean distance (magnitude counts) ---
SELECT p.label,
       json_extract(fractal_agent_outlier_intercept(
           p.state, 'asv_known_bad', 'state', 0.30, 'l2'), '$.intercepted') AS intercepted_l2
FROM asv_proposed p ORDER BY p.id;

-- ------------------------------------------------------------------
-- 4. Step 2: routing deviation from the fleet baseline.  40 fleet
-- vehicles on three lane/speed bands; vehicle V-17's routing vector
-- (lateral offset, heading, speed) is compared against the fleet
-- baseline.  The nearest fleet members to the baseline and to the
-- current vector show how far this vehicle has strayed.
-- ------------------------------------------------------------------
.print
.print === 4. Step 2: routing deviation from the fleet baseline ===

DROP TABLE IF EXISTS asv_routes;
CREATE TABLE asv_routes (
    id      INTEGER PRIMARY KEY,
    vehicle TEXT,
    route   TEXT NOT NULL CHECK (fractal_vector_dims(route) = 3)
);
WITH RECURSIVE gs(g) AS (SELECT 1 UNION ALL SELECT g + 1 FROM gs WHERE g < 40)
INSERT INTO asv_routes (vehicle, route)
SELECT 'V-' || g,
       printf('%.3f,%.3f,%.3f',
              0.10 * (g % 3) + 0.01 * (g % 7),          -- lateral offset
              0.05 * (g % 4),                           -- heading error
              0.60 + 0.05 * (g % 3) + 0.004 * (g % 5))  -- speed band
FROM gs;

WITH tr AS (SELECT fractal_search_trajectory(
                    'asv_routes', 'route',
                    '0.100,0.050,0.650',      -- fleet baseline routing vector
                    '0.900,0.800,0.200',      -- V-17 now: far off its lane/speed band
                    3) AS tj)
SELECT r.vehicle,
       round(json_extract(je.value, '$.distance'), 4) AS distance
FROM tr, json_each(tr.tj) je
JOIN asv_routes r ON r.id - 1 = json_extract(je.value, '$.doc_id')
ORDER BY json_extract(je.value, '$.distance');

-- ------------------------------------------------------------------
-- 5. Reasoning: one go / no-go verdict over both signals (plugin-gated;
-- the clean hint is the expected output without one).
-- ------------------------------------------------------------------
.print
.print === 5. Reasoning: go / no-go verdict for proposal P1 ===

SELECT fractal_reason(
    'one-line go/no-go safety verdict for this proposed ADAS maneuver',
    json_object(
      'intercept', json((SELECT fractal_agent_outlier_intercept(
            state, 'asv_known_bad', 'state', 0.15) FROM asv_proposed WHERE id = 1)),
      'routing_deviation', json((SELECT fractal_search_trajectory(
            'asv_routes', 'route', '0.100,0.050,0.650', '0.900,0.800,0.200', 2)))));

.print
.print === Demo complete ===
.print Tables left in place for inspection. Clean up with:
.print   DROP TABLE asv_known_bad; DROP TABLE asv_proposed; DROP TABLE asv_routes;
