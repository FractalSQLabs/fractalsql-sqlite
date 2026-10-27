-- demo/demo-vertical-climatech-emissions-monitoring.sql
--
-- Industry vertical: Climate Tech -- industrial emissions and utility-
-- leak detection (methane / CO2 sensor networks, water-distribution
-- pressure and flow monitoring).  DOMAIN kit built on one installed
-- agent, fractal_agent_anomaly_triage, reused verbatim: the drift
-- exponent of a single sensor's series flags a shift into a new
-- (leak / over-emission) regime, closing with a reasoned narrative.
--
-- Prerequisites: extension loaded.  The hand-composed drift needs no
-- model; the shipped agent and the closing narrative are reasoning-
-- bearing (clean hint without a plugin; see ../docs/reasoning-setup.md).
--
-- Run (one invocation):
--   sqlite3 -cmd ".load /usr/local/lib/sqlite3/fractalsql" ":memory:" \
--     ".read demo/demo-vertical-climatech-emissions-monitoring.sql"
--
-- Notes:
--   * Fully deterministic fixture (no random()).
--   * Each sensor has a baseline reading; the drift window is 32 points,
--     so each sensor needs >= 48 readings.  A leak is an ACCELERATING
--     concentration ramp downstream of the source, not a level shift:
--     DFA removes a constant offset, so only a change in the series'
--     dynamics moves the exponent.
--   * The network mixes gases and a pipeline-pressure sensor (PRS-07): the
--     agent is indifferent to the physical quantity, so the same call
--     screens a water-distribution pressure series for leaks.
--
-- Safe to re-run: the cem_* tables are dropped and recreated each time.

.timer on

.print === 0. Sanity check: extension loaded? ===
SELECT fractalsql_edition(), fractalsql_version();

-- ------------------------------------------------------------------
-- 1. Four sensors x 96 readings.  CH4-02 (methane, downstream of a
-- compressor) starts leaking at reading 65: concentration ramps up
-- quadratically.  CH4-01 and CO2-01 are steady; PRS-07 is a pipeline
-- pressure sensor, steady here.
-- ------------------------------------------------------------------
.print
.print === 1. Sensor network: 4 sensors x 96 readings ===

DROP TABLE IF EXISTS cem_readings;
CREATE TABLE cem_readings (
    sensor   TEXT,
    quantity TEXT,
    seq      INTEGER,
    value    REAL,
    baseline REAL
);
WITH RECURSIVE gs(g) AS (SELECT 1 UNION ALL SELECT g + 1 FROM gs WHERE g < 96),
     s(sensor, quantity, base) AS (VALUES
         ('CH4-01', 'methane_ppm',  1.9), ('CH4-02', 'methane_ppm',  1.9),
         ('CO2-01', 'co2_ppm',    412.0), ('PRS-07', 'pressure_kpa', 620.0))
INSERT INTO cem_readings (sensor, quantity, seq, value, baseline)
SELECT sensor, quantity, g,
       base * (1.0 + 0.004 * (g % 8))
         + CASE WHEN sensor = 'CH4-02' AND g > 64
                THEN 0.0045 * (g - 64) * (g - 64) ELSE 0 END,
       base
FROM s, gs;

SELECT sensor, quantity, round(max(value), 3) AS peak, baseline
  FROM cem_readings GROUP BY sensor ORDER BY sensor;

-- ------------------------------------------------------------------
-- 2. Hand-composed: emissions-regime drift per sensor.
-- ------------------------------------------------------------------
.print
.print === 2. Hand-composed: regime drift per sensor ===

SELECT sensor,
       round(json_extract(d, '$.drift'), 4)          AS drift,
       round(json_extract(d, '$.recent_alpha'), 4)   AS recent_alpha,
       round(json_extract(d, '$.baseline_alpha'), 4) AS baseline_alpha
FROM (SELECT sensor,
             fractal_dimension_drift(
               (SELECT '[' || group_concat(printf('%.5f', value), ',') || ']'
                  FROM (SELECT value FROM cem_readings r2
                         WHERE r2.sensor = r.sensor ORDER BY seq)), 32) AS d
        FROM (SELECT DISTINCT sensor FROM cem_readings) r)
ORDER BY sensor;

-- ------------------------------------------------------------------
-- 3. The shipped agent on the leaking sensor, and on a steady one for
-- contrast (reasoning plugin).
-- ------------------------------------------------------------------
.print
.print === 3. fractal_agent_anomaly_triage: leaking vs steady sensor ===

SELECT 'CH4-02 (leaking)' AS sensor,
       fractal_agent_anomaly_triage('cem_readings', 'value', 'seq', 'sensor', 'CH4-02', 32) AS triage;
SELECT 'CH4-01 (steady)' AS sensor,
       fractal_agent_anomaly_triage('cem_readings', 'value', 'seq', 'sensor', 'CH4-01', 32) AS triage;

-- ------------------------------------------------------------------
-- 4. Reasoning: the leak narrative (plugin-gated; the clean hint is the
-- expected output without one).
-- ------------------------------------------------------------------
.print
.print === 4. Reasoning: leak / over-emission narrative ===

SELECT fractal_reason(
    'one-line leak-detection narrative and recommended field response for this sensor',
    (SELECT fractal_dimension_drift(
        (SELECT '[' || group_concat(printf('%.5f', value), ',') || ']'
           FROM (SELECT value FROM cem_readings WHERE sensor = 'CH4-02' ORDER BY seq)), 32)));

.print
.print === Demo complete ===
.print Tables left in place for inspection. Clean up with:
.print   DROP TABLE cem_readings;
