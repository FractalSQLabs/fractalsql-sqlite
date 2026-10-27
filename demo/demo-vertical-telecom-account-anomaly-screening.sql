-- demo/demo-vertical-telecom-account-anomaly-screening.sql
--
-- Industry vertical: telecom -- anomalous account-change screening (SIM
-- swap, port-out, plan change, unusual device or location changes).  A
-- general-purpose pre-commit safety check, not a fraud-specific product.
-- DOMAIN kit built on one installed agent,
-- fractal_agent_outlier_intercept, reused verbatim: it screens a
-- PROPOSED event against a history of known-anomalous change patterns,
-- exactly its designed contract (the same shape as the ADAS kit's
-- known-bad-state history, applied to account activity).
--
-- Prerequisites: extension loaded.  The hand-composed screen needs no
-- model; the shipped agent returns a reasoned `reason` (clean hint
-- without a plugin; see ../docs/reasoning-setup.md).
--
-- Run (one invocation):
--   sqlite3 -cmd ".load /usr/local/lib/sqlite3/fractalsql" ":memory:" \
--     ".read demo/demo-vertical-telecom-account-anomaly-screening.sql"
--
-- Notes:
--   * Fully deterministic fixture (no random()).
--   * Event vectors are [sim_change, port_out, new_device, geo_jump,
--     off_hours] intensities in 0..1, CSV TEXT, guarded by
--     CHECK(fractal_vector_dims(...) = 5).
--   * Cosine distance (the default) compares the SHAPE of an event, not
--     its overall intensity: a faint version of a known pattern is
--     flagged too.  Use 'l2' when intensity should count (Section 4).
--   * telemetry doc_id IS the row's rowid.
--
-- Safe to re-run: the taa_* tables are dropped and recreated each time.

.timer on

.print === 0. Sanity check: extension loaded? ===
SELECT fractalsql_edition(), fractalsql_version();

-- ------------------------------------------------------------------
-- 1. History of known-anomalous change patterns, and four proposed
-- account events awaiting commit.
-- ------------------------------------------------------------------
.print
.print === 1. Known-anomalous patterns + proposed account events ===

DROP TABLE IF EXISTS taa_known_anomalous;
CREATE TABLE taa_known_anomalous (
    id      INTEGER PRIMARY KEY,
    pattern TEXT,
    event   TEXT NOT NULL CHECK (fractal_vector_dims(event) = 5)
);
INSERT INTO taa_known_anomalous (pattern, event) VALUES
    ('SIM swap + port-out + new device',      '0.95,0.90,0.85,0.10,0.20'),
    ('SIM swap from a distant location',      '0.90,0.05,0.30,0.95,0.40'),
    ('rapid plan changes off-hours',          '0.05,0.05,0.10,0.10,0.95'),
    ('new device + location jump + port-out', '0.10,0.80,0.90,0.85,0.30');

DROP TABLE IF EXISTS taa_proposed;
CREATE TABLE taa_proposed (
    id    INTEGER PRIMARY KEY,
    label TEXT,
    event TEXT NOT NULL CHECK (fractal_vector_dims(event) = 5)
);
INSERT INTO taa_proposed (label, event) VALUES
    ('E1 swap + port-out + new handset', '0.92,0.88,0.80,0.12,0.18'),
    ('E2 routine plan upgrade',          '0.02,0.00,0.05,0.00,0.05'),
    ('E3 new handset, same city',        '0.00,0.02,0.70,0.04,0.05'),
    ('E4 faint SIM swap, far away',      '0.40,0.02,0.12,0.42,0.16');

SELECT count(*) AS known_patterns FROM taa_known_anomalous;

-- ------------------------------------------------------------------
-- 2. Hand-composed screen: nearest known-anomalous pattern per event,
-- threshold 0.10 (cosine).
-- ------------------------------------------------------------------
.print
.print === 2. Hand-composed screen (cosine, threshold 0.10) ===

SELECT p.label,
       (SELECT k.pattern FROM taa_known_anomalous k
         WHERE k.id = json_extract(je.value, '$.doc_id')) AS nearest_pattern,
       round(json_extract(je.value, '$.distance'), 4) AS distance,
       (json_extract(je.value, '$.distance') < 0.10) AS intercepted
FROM taa_proposed p,
     json_each(fractal_search_telemetry('taa_known_anomalous', 'event', p.event, 1)) je
ORDER BY p.id;

-- ------------------------------------------------------------------
-- 3. The shipped agent (reasoning plugin for the `reason` field).
-- ------------------------------------------------------------------
.print
.print === 3. fractal_agent_outlier_intercept (cosine) ===

SELECT p.label,
       fractal_agent_outlier_intercept(p.event, 'taa_known_anomalous', 'event', 0.10) AS verdict
FROM taa_proposed p ORDER BY p.id;

-- ------------------------------------------------------------------
-- 4. When intensity should count: exact Euclidean distance.  E4 is a
-- faint SIM swap with a location jump -- the same shape as a known
-- pattern but at under half the intensity -- so cosine flags it while
-- l2 lets it through to a lower-severity review queue.
-- ------------------------------------------------------------------
.print
.print === 4. Same screen under exact Euclidean distance (threshold 0.30) ===

SELECT p.label,
       json_extract(fractal_agent_outlier_intercept(
           p.event, 'taa_known_anomalous', 'event', 0.30, 'l2'), '$.intercepted') AS intercepted_l2
FROM taa_proposed p ORDER BY p.id;

-- ------------------------------------------------------------------
-- 5. Reasoning: the justification an analyst sees next to the held
-- event (plugin-gated; the clean hint is the expected output without
-- one).
-- ------------------------------------------------------------------
.print
.print === 5. Reasoning: justification for holding E1 ===

SELECT fractal_reason(
    'one-line justification for holding this account change for review',
    json_object(
      'event', (SELECT label FROM taa_proposed WHERE id = 1),
      'screen', json((SELECT fractal_search_telemetry(
            'taa_known_anomalous', 'event', event, 2) FROM taa_proposed WHERE id = 1))));

.print
.print === Demo complete ===
.print Tables left in place for inspection. Clean up with:
.print   DROP TABLE taa_known_anomalous; DROP TABLE taa_proposed;
