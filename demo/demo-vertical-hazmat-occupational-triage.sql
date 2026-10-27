-- demo/demo-vertical-hazmat-occupational-triage.sql
--
-- Industry vertical: occupational exposure monitoring -- hazardous-
-- materials response, chemical and nuclear plant crews, wearable-sensor
-- workforce safety.  DOMAIN kit built on one installed agent,
-- fractal_agent_patient_deterioration_triage, reused verbatim: its
-- contract (cohort vector search + baseline-vs-current trajectory drift)
-- is domain-neutral, so the kit only supplies exposure columns in place
-- of clinical vitals and a worker's pre-shift baseline in place of an
-- admission baseline.
--
-- Prerequisites: extension loaded.  Sections 1-3 need no model; the
-- shipped agent and the closing recommendation are reasoning-bearing
-- (clean hint without a plugin; see ../docs/reasoning-setup.md).
--
-- Run (one invocation):
--   sqlite3 -cmd ".load /usr/local/lib/sqlite3/fractalsql" ":memory:" \
--     ".read demo/demo-vertical-hazmat-occupational-triage.sql"
--
-- Notes:
--   * Fully deterministic fixture (no random()).
--   * Exposure vectors are [dose_rate_z, body_temp_z, air_quality_z,
--     heart_rate_z] in CSV TEXT guarded by CHECK(fractal_vector_dims(...)
--     = 4): a wrong-width write from a wearable integration fails loudly
--     at write time, not silently inside a worker record.
--   * telemetry/hybrid doc_id IS the row's rowid; trajectory doc_id is
--     the 0-based scan position (here doc_id = id - 1: ids are contiguous
--     from 1 in insertion order).
--   * The cohort is caller-built with ordinary SQL (same work zone AND
--     same shift) -- the two-predicate cohort a single filter pair cannot
--     express.
--
-- Safe to re-run: the hot_* tables are dropped and recreated each time.

.timer on

.print === 0. Sanity check: extension loaded? ===
SELECT fractalsql_edition(), fractalsql_version();

-- ------------------------------------------------------------------
-- 1. 36 synthetic workers across three work zones and two shifts.
-- Zone 'reactor-bay' on the night shift is the contaminated cohort:
-- workers 7, 15 and 31 show elevated dose rate, temperature and heart
-- rate.
-- ------------------------------------------------------------------
.print
.print === 1. 36 workers: zone, shift and current exposure vector ===

DROP TABLE IF EXISTS hot_workers;
CREATE TABLE hot_workers (
    id       INTEGER PRIMARY KEY,
    zone     TEXT,
    shift    TEXT,
    exposure TEXT NOT NULL CHECK (fractal_vector_dims(exposure) = 4)
);

WITH RECURSIVE gs(g) AS (SELECT 1 UNION ALL SELECT g + 1 FROM gs WHERE g < 36)
INSERT INTO hot_workers (zone, shift, exposure)
SELECT CASE g % 3 WHEN 0 THEN 'reactor-bay' WHEN 1 THEN 'fuel-handling' ELSE 'control-room' END,
       CASE WHEN g % 2 = 0 THEN 'night' ELSE 'day' END,
       printf('%.4f,%.4f,%.4f,%.4f',
              0.05 * (g % 5),                 -- dose rate
              0.04 * (g % 7) - 0.10,          -- body temperature
              0.03 * (g % 4),                 -- air quality
              0.06 * (g % 6) - 0.10)          -- heart rate
FROM gs;

-- Force a deterministic contaminated cohort.
UPDATE hot_workers SET zone = 'reactor-bay', shift = 'night',
       exposure = '1.40,0.90,1.10,1.20' WHERE id IN (7, 15, 31);

SELECT zone, shift, count(*) AS workers FROM hot_workers
 GROUP BY zone, shift ORDER BY zone, shift;

-- ------------------------------------------------------------------
-- 2. Hand-composed: cohort-restricted search.  Nearest reactor-bay
-- night-shift workers to the exposure profile of the worker under
-- review (worker 15, by id).
-- ------------------------------------------------------------------
.print
.print === 2. Cohort-restricted search: reactor-bay, night shift ===

WITH hs AS (SELECT fractal_hybrid_clinical_search(
                    'hot_workers', 'exposure', '1.40,0.90,1.10,1.20',
                    (SELECT group_concat(id) FROM hot_workers
                      WHERE zone = 'reactor-bay' AND shift = 'night'), 5) AS rj)
SELECT w.id AS worker_id, w.zone, w.shift,
       round(json_extract(je.value, '$.distance'), 4) AS distance
FROM hs, json_each(hs.rj) je
JOIN hot_workers w ON w.rowid = json_extract(je.value, '$.doc_id')
ORDER BY json_extract(je.value, '$.distance');

-- ------------------------------------------------------------------
-- 3. Hand-composed: pre-shift baseline vs current exposure.
-- ------------------------------------------------------------------
.print
.print === 3. Baseline -> current exposure trajectory ===

WITH tr AS (SELECT fractal_search_trajectory(
                    'hot_workers', 'exposure',
                    '0.05,0.00,0.03,0.00',    -- pre-shift baseline
                    '1.40,0.90,1.10,1.20',    -- current (escalating)
                    5) AS tj)
SELECT w.id AS worker_id, w.zone, w.shift,
       round(json_extract(je.value, '$.distance'), 4) AS distance
FROM tr, json_each(tr.tj) je
JOIN hot_workers w ON w.id - 1 = json_extract(je.value, '$.doc_id')
ORDER BY json_extract(je.value, '$.distance');

-- ------------------------------------------------------------------
-- 4. The shipped agent: both searches plus a reasoned rationale in one
-- call (reasoning plugin).  The rationale is the countermeasure-
-- dispatch recommendation.
-- ------------------------------------------------------------------
.print
.print === 4. fractal_agent_patient_deterioration_triage (exposure triage) ===

SELECT fractal_agent_patient_deterioration_triage(
    'hot_workers', 'exposure', '1.40,0.90,1.10,1.20',
    '0.05,0.00,0.03,0.00', '1.40,0.90,1.10,1.20',
    (SELECT group_concat(id) FROM hot_workers
      WHERE zone = 'reactor-bay' AND shift = 'night'),
    5) AS exposure_triage;

-- ------------------------------------------------------------------
-- 5. Reasoning: the medical-countermeasure dispatch recommendation
-- (plugin-gated; the clean hint is the expected output without one).
-- ------------------------------------------------------------------
.print
.print === 5. Reasoning: countermeasure dispatch recommendation ===

SELECT fractal_reason(
    'one-line medical-countermeasure dispatch recommendation for this exposed work crew',
    (SELECT fractal_search_trajectory('hot_workers', 'exposure',
            '0.05,0.00,0.03,0.00', '1.40,0.90,1.10,1.20', 3)));

.print
.print === Demo complete ===
.print Tables left in place for inspection. Clean up with:
.print   DROP TABLE hot_workers;
