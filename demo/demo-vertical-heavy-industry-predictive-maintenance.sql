-- demo/demo-vertical-heavy-industry-predictive-maintenance.sql
--
-- Industry vertical: heavy machinery and fleet predictive maintenance --
-- commercial marine vessels, construction / mining equipment, industrial
-- powertrains, hull and structural sensor networks.  AGENTIC kit: two
-- installed agents are chained, shown hand-composed first and then as the
-- shipped one-call agents.
--
--   1. fractal_agent_anomaly_triage -- the DFA drift exponent of one
--      asset's vibration series, flagging a shift into a new (pre-
--      failure) regime.
--   2. fractal_agent_patient_deterioration_triage -- baseline-vs-current
--      trajectory drift against the asset's intake baseline, with a
--      same-class cohort search (an asset plays the patient).
--   3. A closing fractal_reason() produces a maintenance-window
--      recommendation.
--
-- Prerequisites: extension loaded.  The hand-composed sections need no
-- model; the shipped agents and the closing recommendation are
-- reasoning-bearing (clean hint without a plugin; see
-- ../docs/reasoning-setup.md).
--
-- Run (one invocation):
--   sqlite3 -cmd ".load /usr/local/lib/sqlite3/fractalsql" ":memory:" \
--     ".read demo/demo-vertical-heavy-industry-predictive-maintenance.sql"
--
-- Notes:
--   * Fully deterministic fixture (no random()).
--   * State vectors are [vib_rms_z, kurtosis_z, bearing_temp_z, order1_amp_z]
--     in CSV TEXT guarded by CHECK(fractal_vector_dims(...) = 4).
--   * The drift window is 32 points, so each asset needs >= 48 readings.
--     The failure signature is an ACCELERATING vibration ramp (a growing
--     bearing defect), not a level shift: DFA removes a constant offset,
--     so only a change in the series' dynamics moves the exponent.
--   * trajectory doc_id is the 0-based scan position; hpm_readings ids are
--     contiguous from 1 in insertion order, so doc_id = id - 1.
--   * This is the WEAR / LIFECYCLE half of heavy-industry monitoring.  A
--     CAD / structural-defect (3D mesh) kit is a separate topic.
--
-- Safe to re-run: the hpm_* tables are dropped and recreated each time.

.timer on

.print === 0. Sanity check: extension loaded? ===
SELECT fractalsql_edition(), fractalsql_version();

-- ------------------------------------------------------------------
-- 1. Four pumps / drives x 96 readings.  PUMP-07 develops a bearing
-- defect at reading 65 (accelerating vibration, rising temperature);
-- the others age gently.  'class' groups comparable assets.
-- ------------------------------------------------------------------
.print
.print === 1. Asset telemetry: 4 assets x 96 readings ===

DROP TABLE IF EXISTS hpm_readings;
CREATE TABLE hpm_readings (
    id     INTEGER PRIMARY KEY,
    asset  TEXT,
    class  TEXT,
    seq    INTEGER,
    vib    REAL,                -- vibration RMS, mm/s
    temp_c REAL,                -- bearing temperature
    state  TEXT NOT NULL CHECK (fractal_vector_dims(state) = 4)
);

WITH RECURSIVE gs(g) AS (SELECT 1 UNION ALL SELECT g + 1 FROM gs WHERE g < 96),
     a(ai, asset, class) AS (VALUES
         (1, 'PUMP-03', 'centrifugal'), (2, 'PUMP-05', 'centrifugal'),
         (3, 'PUMP-07', 'centrifugal'), (4, 'DRIVE-12', 'gearbox')),
     r AS (
       SELECT ai, asset, class, g,
              2.1 + (g % 8) * 0.05
                + CASE WHEN asset = 'PUMP-07' AND g > 64
                       THEN 0.004 * (g - 64) * (g - 64) ELSE 0 END AS vib,
              58.0 + (g % 6) * 0.4
                + CASE WHEN asset = 'PUMP-07' AND g > 64 THEN 0.35 * (g - 64) ELSE 0 END AS temp_c
         FROM a, gs)
INSERT INTO hpm_readings (asset, class, seq, vib, temp_c, state)
SELECT asset, class, g, vib, temp_c,
       printf('%.4f,%.4f,%.4f,%.4f',
              (vib - 2.3) / 1.0,
              ((g % 8) * 0.05 + CASE WHEN asset = 'PUMP-07' AND g > 64 THEN 0.08 * (g - 64) ELSE 0 END) - 0.2,
              (temp_c - 60.0) / 10.0,
              (vib - 2.1) * 0.5)
  FROM r ORDER BY ai, g;

SELECT asset, class, count(*) AS readings, round(max(vib), 2) AS max_vib_mm_s,
       round(max(temp_c), 1) AS max_bearing_temp_c
  FROM hpm_readings GROUP BY asset ORDER BY asset;

-- ------------------------------------------------------------------
-- 2. Step 1, hand-composed: vibration-regime drift per asset.  The
-- healthy assets sit near zero; PUMP-07's accelerating ramp pushes its
-- recent-window exponent far above its baseline.
-- ------------------------------------------------------------------
.print
.print === 2. Step 1 (hand-composed): vibration drift per asset ===

SELECT asset,
       round(json_extract(d, '$.drift'), 4)          AS drift,
       round(json_extract(d, '$.recent_alpha'), 4)   AS recent_alpha,
       round(json_extract(d, '$.baseline_alpha'), 4) AS baseline_alpha
FROM (SELECT asset,
             fractal_dimension_drift(
               (SELECT '[' || group_concat(printf('%.4f', vib), ',') || ']'
                  FROM (SELECT vib FROM hpm_readings h2
                         WHERE h2.asset = h.asset ORDER BY seq)), 32) AS d
        FROM (SELECT DISTINCT asset FROM hpm_readings) h)
ORDER BY asset;

.print --- the shipped agent: same composition, one call (reasoning plugin) ---
SELECT fractal_agent_anomaly_triage(
    'hpm_readings', 'vib', 'seq', 'asset', 'PUMP-07', 32) AS vibration_triage;

-- ------------------------------------------------------------------
-- 3. Step 2, hand-composed: PUMP-07's intake baseline vs its latest
-- state.  The nearest fleet readings show where in the fleet's history
-- the pump now sits.
-- ------------------------------------------------------------------
.print
.print === 3. Step 2 (hand-composed): PUMP-07 baseline -> current trajectory ===

WITH tr AS (SELECT fractal_search_trajectory(
                    'hpm_readings', 'state',
                    (SELECT state FROM hpm_readings WHERE asset = 'PUMP-07' AND seq = 1),
                    (SELECT state FROM hpm_readings WHERE asset = 'PUMP-07' AND seq = 96),
                    5) AS tj)
SELECT h.asset, h.seq, round(json_extract(je.value, '$.distance'), 4) AS distance
FROM tr, json_each(tr.tj) je
JOIN hpm_readings h ON h.id - 1 = json_extract(je.value, '$.doc_id')
ORDER BY json_extract(je.value, '$.distance');

.print --- the shipped agent: cohort = same-class (centrifugal) assets (reasoning plugin) ---
SELECT fractal_agent_patient_deterioration_triage(
    'hpm_readings', 'state',
    (SELECT state FROM hpm_readings WHERE asset = 'PUMP-07' AND seq = 96),
    (SELECT state FROM hpm_readings WHERE asset = 'PUMP-07' AND seq = 1),
    (SELECT state FROM hpm_readings WHERE asset = 'PUMP-07' AND seq = 96),
    (SELECT group_concat(id) FROM hpm_readings WHERE class = 'centrifugal'),
    5) AS baseline_triage;

-- ------------------------------------------------------------------
-- 4. Reasoning: the maintenance-window recommendation (plugin-gated;
-- the clean hint is the expected output without one).
-- ------------------------------------------------------------------
.print
.print === 4. Reasoning: maintenance-window recommendation for PUMP-07 ===

SELECT fractal_reason(
    'one-line maintenance-window recommendation for a pump showing an accelerating '
    || 'vibration regime shift and drift from its intake baseline',
    json_object(
      'vibration_drift', json((SELECT fractal_dimension_drift(
            (SELECT '[' || group_concat(printf('%.4f', vib), ',') || ']'
               FROM (SELECT vib FROM hpm_readings WHERE asset = 'PUMP-07' ORDER BY seq)), 32))),
      'baseline_trajectory', json((SELECT fractal_search_trajectory(
            'hpm_readings', 'state',
            (SELECT state FROM hpm_readings WHERE asset = 'PUMP-07' AND seq = 1),
            (SELECT state FROM hpm_readings WHERE asset = 'PUMP-07' AND seq = 96), 3)))));

.print
.print === Demo complete ===
.print Tables left in place for inspection. Clean up with:
.print   DROP TABLE hpm_readings;
