-- demo/demo-vertical-event-stream-anomaly-triage.sql
--
-- Industry vertical: High-frequency event-stream latency and rate anomaly
-- triage. DOMAIN kit: Four endpoints x 96 one-minute intervals of request
-- latency; one endpoint (EP-C) develops an accelerating latency ramp (a
-- timeout cascade) and a second (EP-B) has a retry-storm oscillation in its
-- request rate. `fractal_agent_anomaly_triage` flags the latency regime
-- shift, `fractal_periodogram` finds the retry-storm period, and
-- `fractal_search_trajectory` finds which endpoints' success-rate / latency
-- / timeout / fill health has moved the same way EP-C's did.
--
--   1. fractal_dimension_drift / fractal_agent_anomaly_triage: which
--      endpoint's latency changed regime.
--   2. fractal_periodogram: the dominant period of each endpoint's request
--      rate (a retry loop shows as a sharp line).
--   3. fractal_search_trajectory: endpoints whose health moved like the
--      degraded one (baseline -> current).
--   4. A closing fractal_reason() writes the triage line.
--
-- Prerequisites: the fractalsql extension loaded (.load ./fractalsql); the
-- agents ship inside it. The closing fractal_reason() narrative and any
-- shipped-agent rationale columns need the reasoning plugin
-- (docs/reasoning-setup.md); every other step runs with no model.
--
-- Run:
--   sqlite3 -cmd ".load ./fractalsql" :memory: ".read demo/demo-vertical-event-stream-anomaly-triage.sql"
--
-- Safe to re-run: esa_* tables are dropped and recreated each time.
--
-- Notes:
--   * Fully deterministic fixtures (no random()).
--   * Latency is a steady base with a small cycle; EP-C ramps quadratically
--     from interval 65.
--   * Request rate: EP-B carries a 12-interval oscillation; the others are
--     flat with a faint 7-interval ripple.
--   * Ends with a HEADLINE line computed from the kit's own results (HEADLINE kit=<name> ok);
--     the build_test kit gate greps for it.

.print === 0. Sanity check: extension loaded? ===
SELECT fractalsql_edition(), fractalsql_version();

.print
.print === 1. Event-stream telemetry: 4 endpoints x 96 intervals ===
DROP TABLE IF EXISTS esa_latency;
CREATE TABLE esa_latency (
    ent TEXT,
    seq INTEGER,
    val REAL
);
WITH RECURSIVE gs(g) AS (SELECT 1 UNION ALL SELECT g + 1 FROM gs WHERE g < 96),
     s(ent, base, p2) AS (VALUES
         ('EP-A', 42, 0),
         ('EP-B', 55, 0),
         ('EP-C', 48, 0.0024),
         ('EP-D', 61, 0))
INSERT INTO esa_latency (ent, seq, val)
SELECT ent, g, base * (1.0 + 0.004 * (g % 8)) + CASE WHEN p2 > 0 AND g > 64 THEN base * p2 * (g - 64) * (g - 64) ELSE 0 END
FROM s, gs;
DROP TABLE IF EXISTS esa_rate;
CREATE TABLE esa_rate (
    ent TEXT,
    seq INTEGER,
    val REAL
);
WITH RECURSIVE gs(g) AS (SELECT 1 UNION ALL SELECT g + 1 FROM gs WHERE g < 96),
     s(ent, base, p1, p2) AS (VALUES
         ('EP-A', 900, 0, 0),
         ('EP-B', 800, 0.3, 0),
         ('EP-C', 950, 0, 0),
         ('EP-D', 700, 0, 0))
INSERT INTO esa_rate (ent, seq, val)
SELECT ent, g, base * (1.0 + 0.02 * sin(2 * pi() * g / 7.0) + p1 * sin(2 * pi() * g / 12.0))
FROM s, gs;
SELECT ent, count(*) AS intervals FROM esa_latency GROUP BY ent ORDER BY ent;

.print
.print === 2. Hand-composed: latency regime drift per endpoint ===
DROP TABLE IF EXISTS esa_lprof;
CREATE TABLE esa_lprof AS
SELECT row_number() OVER (ORDER BY a.ent) AS pid, a.ent AS ent, round(m.mean_v, 4) AS mean_v, round(m.var_v, 4) AS var_v, fractal_dimension_dfa(a.arr) AS dfa_alpha, json_extract(a.dj, '$.drift') AS drift, json_extract(a.dj, '$.recent_alpha') AS recent_alpha, json_extract(a.dj, '$.baseline_alpha') AS baseline_alpha
FROM (SELECT ent, arr, fractal_dimension_drift(arr, 32) AS dj FROM (SELECT e.ent AS ent, (SELECT '[' || group_concat(printf('%.5f', v), ',') || ']' FROM (SELECT val AS v FROM esa_latency s2 WHERE s2.ent = e.ent ORDER BY seq)) AS arr FROM (SELECT DISTINCT ent FROM esa_latency) e)) a
JOIN (SELECT ent, avg(val) AS mean_v, avg(val * val) - avg(val) * avg(val) AS var_v
        FROM esa_latency GROUP BY ent) m ON m.ent = a.ent
ORDER BY a.ent;
SELECT ent, mean_v, var_v, round(dfa_alpha, 3) AS dfa_alpha, round(drift, 4) AS drift, round(recent_alpha, 4) AS recent_alpha, round(baseline_alpha, 4) AS baseline_alpha
  FROM esa_lprof ORDER BY ent;

.print
.print === 3. fractal_agent_anomaly_triage: degraded vs healthy endpoint ===
SELECT 'EP-C (degraded)' AS entity,
       fractal_agent_anomaly_triage('esa_latency', 'val', 'seq', 'ent', 'EP-C', 32) AS triage;
SELECT 'EP-A (healthy)' AS entity,
       fractal_agent_anomaly_triage('esa_latency', 'val', 'seq', 'ent', 'EP-A', 32) AS triage;

.print
.print === 4. Retry-storm period: fractal_periodogram on the request rate ===
DROP TABLE IF EXISTS esa_rprof;
CREATE TABLE esa_rprof AS
SELECT row_number() OVER (ORDER BY a.ent) AS pid, a.ent AS ent, round(m.mean_v, 4) AS mean_v, round(m.var_v, 4) AS var_v, json_extract(a.pj, '$.freqs[0]') AS freq
FROM (SELECT ent, arr, fractal_periodogram(arr, 1) AS pj FROM (SELECT e.ent AS ent, (SELECT '[' || group_concat(printf('%.5f', v), ',') || ']' FROM (SELECT val AS v FROM esa_rate s2 WHERE s2.ent = e.ent ORDER BY seq)) AS arr FROM (SELECT DISTINCT ent FROM esa_rate) e)) a
JOIN (SELECT ent, avg(val) AS mean_v, avg(val * val) - avg(val) * avg(val) AS var_v
        FROM esa_rate GROUP BY ent) m ON m.ent = a.ent
ORDER BY a.ent;
SELECT ent, mean_v, var_v, round(freq, 4) AS top_freq, round(1.0 / freq, 1) AS samples_per_cycle
  FROM esa_rprof ORDER BY ent;

.print
.print === 5. Endpoint health trajectory: who moved like EP-C ===
DROP TABLE IF EXISTS esa_health;
CREATE TABLE esa_health (
    id INTEGER PRIMARY KEY,
    label TEXT,
    vec TEXT NOT NULL CHECK (fractal_vector_dims(vec) = 4)
);
INSERT INTO esa_health (id, label, vec) VALUES
    (1, 'EP-01', '0.05,-0.06,0.03,-0.04'),
    (2, 'EP-02', '0.1,-0.02,0.06,0.02'),
    (3, 'EP-03 (degraded)', '1.4,0.9,1.1,1.2'),
    (4, 'EP-04', '0.2,0.06,0,0.14'),
    (5, 'EP-05', '0,0.1,0.03,0.2'),
    (6, 'EP-06', '0.05,0.14,0.06,-0.1'),
    (7, 'EP-07 (degraded)', '1.4,0.9,1.1,1.2'),
    (8, 'EP-08', '0.15,-0.06,0,0.02'),
    (9, 'EP-09', '0.2,-0.02,0.03,0.08'),
    (10, 'EP-10', '0,0.02,0.06,0.14'),
    (11, 'EP-11 (degraded)', '1.4,0.9,1.1,1.2'),
    (12, 'EP-12', '0.1,0.1,0,-0.1'),
    (13, 'EP-13', '0.15,0.14,0.03,-0.04'),
    (14, 'EP-14', '0.2,-0.1,0.06,0.02'),
    (15, 'EP-15', '0,-0.06,0.09,0.08'),
    (16, 'EP-16', '0.05,-0.02,0,0.14');
DROP TABLE IF EXISTS esa_traj;
CREATE TABLE esa_traj AS
WITH tr AS (SELECT fractal_search_trajectory(
                    'esa_health', 'vec',
                    '0.05,0,0.03,0',    -- baseline
                    '1.4,0.9,1.1,1.2',    -- current
                    5) AS tj)
SELECT row_number() OVER (ORDER BY json_extract(je.value, '$.distance'), w.id) AS rk, w.id, w.label AS label,
       round(json_extract(je.value, '$.distance'), 4) AS distance
FROM tr, json_each(tr.tj) je
JOIN esa_health w ON w.id - 1 = json_extract(je.value, '$.doc_id');

SELECT rk, id, label, distance FROM esa_traj ORDER BY rk;

.print
.print === 6. Reasoning: triage line ===
SELECT fractal_reason(
    'one-line event-stream triage: which endpoint is degrading, since when, and the likely cause',
    json_object('worst_endpoint', (SELECT ent FROM esa_lprof ORDER BY drift DESC LIMIT 1), 'retry_storm_endpoint', (SELECT ent FROM esa_rprof ORDER BY freq DESC LIMIT 1), 'nearest_degraded_health', (SELECT label FROM esa_traj WHERE rk = 1))) AS narrative;

.print
.print === 7. Headline check ===
SELECT 'HEADLINE kit=event-stream-anomaly-triage ' || CASE WHEN (SELECT drift FROM esa_lprof WHERE ent = 'EP-C') > 0.5 AND (SELECT drift FROM esa_lprof WHERE ent = 'EP-A') < 0 AND (SELECT freq FROM esa_rprof WHERE ent = 'EP-B') > 0.07 AND (SELECT freq FROM esa_rprof WHERE ent = 'EP-B') < 0.10 AND (SELECT count(*) FROM esa_traj WHERE distance < 0.001) >= 3 THEN 'ok' ELSE 'MISS' END AS headline;

.print
.print === Demo complete ===
.print Tables left in place for inspection. Clean up with:
.print   DROP TABLE esa_latency; DROP TABLE esa_rate; DROP TABLE esa_lprof; DROP TABLE esa_rprof; DROP TABLE esa_health; DROP TABLE esa_traj;
