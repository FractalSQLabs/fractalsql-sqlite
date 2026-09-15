-- demo/demo-vertical-maritime-defense.sql
--
-- Industry vertical: Maritime, Aviation & Defense (AIS & Radar Tracking).
--
-- A synthetic AIS-style vessel fleet (30 vessels, lat/lon/speed/heading
-- track vectors) with one vessel given a deliberate course deviation --
-- fractal_search_trajectory's "current vs. baseline" delta search is a
-- direct fit for track-deviation detection ("what changed"), and DFA's
-- scaling exponent on a heading-change series is a real fit for
-- maneuvering-pattern irregularity (smooth transit vs. erratic track).
--
-- Prerequisites: extension loaded (sections 0-3 need nothing else).
-- Section 4's rationale call needs the reasoning plugin -- see
-- ../docs/reasoning-setup.md (per-connection fractalsql_set state, so
-- re-apply your load_fractalsql.sql snippet with -init).
--
-- Run (one invocation):
--   sqlite3 -cmd ".load /usr/local/lib/sqlite3/fractalsql" ":memory:" \
--     ".read demo/demo-vertical-maritime-defense.sql"
--
-- Notes:
--   * There is no seedable global RNG -- the fixture's noise is plain
--     random() (a signed 64-bit integer here, mapped into [-1,1) with
--     /2^63), so the noise pattern differs run to run; every analysis
--     output stays structurally identical.
--   * Vector columns are CSV TEXT guarded by a
--     CHECK(fractal_vector_dims(...) = 4) constraint: a feature-
--     extraction bug that silently changed the vector's width is
--     still a hard write-time error.
--   * The fractal_agent_* preset is a blueprint composition over the
--     primitives (see demo-agents.sql for the pattern).
--   * doc_id is the row's 0-based position in the search's own scan
--     order, and in SQLite that order IS rowid order (UPDATE keeps a
--     rowid table's physical position on UPDATE);
--     vmd_vessels' rowid aliases its INTEGER PRIMARY KEY id, so doc_id
--     = id - 1 exactly, stable across the section-1 UPDATE.
--
-- Safe to re-run: vmd_* tables are dropped and recreated each time.

.timer on

.print === 0. Sanity check: extension loaded? ===
SELECT fractalsql_edition(), fractalsql_version();

-- ------------------------------------------------------------------
-- 1. 30 vessels, each with a BASELINE track vector (their filed/typical
-- route: [lat_norm, lon_norm, speed_norm, heading_norm]) and a CURRENT
-- track vector. Vessel 7 gets a deliberate large deviation (course
-- change + speed drop -- a classic "gone dark then reappeared off
-- track" pattern); everyone else's current stays close to baseline
-- (normal transit noise), generated with a recursive CTE.
-- ------------------------------------------------------------------
.print
.print === 1. 30 vessels: baseline vs. current AIS track vectors ===

DROP TABLE IF EXISTS vmd_vessels;
CREATE TABLE vmd_vessels (
    id        INTEGER PRIMARY KEY,
    mmsi      TEXT,
    baseline  TEXT NOT NULL
              CHECK (fractal_vector_dims(baseline) = 4),
                                                          -- a fixed-width AIS track
                                                          -- state ([lat_norm, lon_norm,
                                                          -- speed_norm, heading_norm]),
                                                          -- the same dimension-safety
                                                          -- argument as vitals in
                                                          -- demo-vertical-medtech-
                                                          -- clinical.sql
    current   TEXT NOT NULL
              CHECK (fractal_vector_dims(current) = 4)
);

-- Baselines are four random components per vessel; current is the same
-- shape plus transit noise (the speed/heading components get a wider
-- 0.1-amplitude noise).
INSERT INTO vmd_vessels (mmsi, baseline, current)
WITH RECURSIVE gs(g) AS (SELECT 1 UNION ALL SELECT g + 1 FROM gs WHERE g < 30)
SELECT 'MMSI-' || (100000000 + g),
       '[' || printf('%.4f,%.4f,%.4f,%.4f', b1, b2, b3, b4) || ']',
       '[' || printf('%.4f,%.4f,%.4f,%.4f',
                     b1 + (random() / 9223372036854775808.0 - 0.5) * 0.05,
                     b2 + (random() / 9223372036854775808.0 - 0.5) * 0.05,
                     b3 + (random() / 9223372036854775808.0 - 0.5) * 0.1,
                     b4 + (random() / 9223372036854775808.0 - 0.5) * 0.1) || ']'
FROM (SELECT g,
             random() / 9223372036854775808.0 AS b1,
             random() / 9223372036854775808.0 AS b2,
             random() / 9223372036854775808.0 AS b3,
             random() / 9223372036854775808.0 AS b4
        FROM gs);

-- Vessel 7's deliberate deviation: large heading/speed change from
-- baseline.
UPDATE vmd_vessels
   SET current = printf('[%.4f,%.4f,%.4f,%.4f]',
                        json_extract(baseline, '$[0]') + 0.6,
                        json_extract(baseline, '$[1]') - 0.5,
                        json_extract(baseline, '$[2]') - 0.9,
                        json_extract(baseline, '$[3]') + 0.8)
 WHERE id = 7;

-- ------------------------------------------------------------------
-- 2. fractal_search_trajectory: current vs. baseline DELTA for the
-- flagged vessel -- which stored tracks does this deviation most
-- resemble? "What changed", not "what's closest" -- see that
-- function's own doc comment. The baseline/current TEXT columns
-- resolve the vector primitives directly -- no cast needed at the
-- call site. doc_id is the row's 0-based position in the search's own
-- scan (rowid order here), mapped back to mmsi through the row_number
-- view.
-- ------------------------------------------------------------------
.print
.print === 2. Vessel 7 deviation vs. the fleet (fractal_search_trajectory) ===

WITH tr AS (SELECT fractal_search_trajectory(
                    'vmd_vessels', 'current',
                    (SELECT baseline FROM vmd_vessels WHERE id = 7),
                    (SELECT current  FROM vmd_vessels WHERE id = 7),
                    5) AS tj)
SELECT v.mmsi, json_extract(je.value, '$.distance') AS distance
FROM tr, json_each(tr.tj) je
JOIN (SELECT mmsi, (row_number() OVER (ORDER BY rowid) - 1) AS doc_id
        FROM vmd_vessels) v ON v.doc_id = json_extract(je.value, '$.doc_id')
ORDER BY json_extract(je.value, '$.distance');

-- ------------------------------------------------------------------
-- 3. fractal_search_telemetry / fractal_search_explore: nearest-track lookup
-- (who's near a contact-of-interest position) and diverse-track
-- clustering (representative traffic patterns across the whole fleet).
-- ------------------------------------------------------------------
.print
.print === 3. Nearest vessels to a contact position, and diverse fleet traffic patterns ===

.print Nearest vessels to a contact-of-interest position:
WITH t AS (SELECT json_extract(value, '$.doc_id')   AS doc_id,
                  json_extract(value, '$.distance') AS dist
             FROM json_each(fractal_search_telemetry(
                      'vmd_vessels', 'current', '0.2,0.2,0.5,0.0', 5)))
SELECT v.mmsi, t.dist AS distance
FROM t
JOIN (SELECT mmsi, (row_number() OVER (ORDER BY rowid) - 1) AS doc_id
        FROM vmd_vessels) v ON v.doc_id = t.doc_id
ORDER BY t.dist;

.print
.print Diverse representative traffic patterns across the fleet:
.print --- raw explore form (query-agnostic -- explore samples the space) ---
WITH e AS (SELECT fractal_search_explore(current, '0,0.2,0,0',
                                  '{"population_size": 6, "iterations": 8, "walk": 0}') AS res
             FROM vmd_vessels)
SELECT value AS particle
  FROM e, json_each(e.res, '$.population');

-- recommend_diverse composition: real vessel ids + scores
-- (1 - cosine_distance) with session-global repulsion enabled, then we
-- restore the session (the composition leaves diversify on -- the caller
-- owns that policy) so later sections see the same diversify-off state
-- as before. The raw explore above is query-agnostic; the telemetry form
-- is query-anchored, so anchor on the first vessel's own current vector.
.print --- recommend_diverse composition (query-anchored, repulsion on) ---
WITH t AS (SELECT json_extract(value, '$.doc_id')   AS doc_id,
                  json_extract(value, '$.distance') AS dist
             FROM json_each(fractal_search_telemetry(
                      'vmd_vessels', 'current',
                      (SELECT current FROM vmd_vessels ORDER BY id LIMIT 1), 6)))
SELECT v.id       AS item_id,
       v.mmsi     AS mmsi,
       1.0 - t.dist AS score
FROM t
JOIN (SELECT id, mmsi, (row_number() OVER (ORDER BY rowid) - 1) AS doc_id
        FROM vmd_vessels) v ON v.doc_id = t.doc_id;
SELECT fractal_diversify_disable();

-- ------------------------------------------------------------------
-- 4. fractal_dimension_dfa: maneuvering-pattern irregularity. A smooth
-- transit heading series (vessel on a steady course) vs. vessel 7's
-- erratic heading series (evasive/anomalous maneuvering) -- DFA's
-- alpha separates the two: near-random-walk (smooth, ~1.3-1.5) vs.
-- much rougher/anti-persistent behavior for erratic maneuvering.
-- (A recursive CTE generates the sample index; the running sum is
-- materialized with a window function.)
-- ------------------------------------------------------------------
.print
.print === 4. DFA: heading-change series, normal vs. flagged vessel ===

.print Normal vessel (smooth heading drift over 120 samples):
WITH gs(t) AS (SELECT 1 UNION ALL SELECT t + 1 FROM gs WHERE t < 120),
steps AS (SELECT t, (random() / 9223372036854775808.0 - 0.5) * 0.03 AS v FROM gs),
walk AS (SELECT printf('%.6f', sum(v) OVER (ORDER BY t)) AS s FROM steps)
SELECT fractal_dimension_dfa('[' || (SELECT group_concat(s) FROM walk) || ']')
           AS normal_vessel_alpha;

.print
.print Vessel 7 (erratic heading swings over the same window):
-- Raw primitive: the flagged vessel's heading-change DFA exponent -- a
-- comparison baseline the composition below, which takes a single
-- heading series, has no home for.
WITH gs(t) AS (SELECT 1 UNION ALL SELECT t + 1 FROM gs WHERE t < 120),
steps AS (SELECT t, (random() / 9223372036854775808.0 - 0.5)
                   * (CASE WHEN t BETWEEN 60 AND 90 THEN 0.35 ELSE 0.03 END) AS v FROM gs),
walk AS (SELECT printf('%.6f', sum(v) OVER (ORDER BY t)) AS s FROM steps)
SELECT fractal_dimension_dfa('[' || (SELECT group_concat(s) FROM walk) || ']')
           AS flagged_vessel_alpha;

-- track_anomaly composition: the real nearest fleet vessel
-- (fractal_search_trajectory over vessel 7's baseline->current,
-- resolved through the rowid mapping), the real trajectory_distance,
-- the real heading-series DFA exponent, plus a real rationale
-- (plugin-gated: the clean hint is the expected output without one).
.print --- track_anomaly composition (trajectory + heading DFA) ---
WITH tr AS (SELECT fractal_search_trajectory(
                    'vmd_vessels', 'current',
                    (SELECT baseline FROM vmd_vessels WHERE id = 7),
                    (SELECT current  FROM vmd_vessels WHERE id = 7),
                    5) AS tj),
gs(t) AS (SELECT 1 UNION ALL SELECT t + 1 FROM gs WHERE t < 120),
steps AS (SELECT t, (random() / 9223372036854775808.0 - 0.5)
                   * (CASE WHEN t BETWEEN 60 AND 90 THEN 0.35 ELSE 0.03 END) AS v FROM gs),
walk AS (SELECT printf('%.6f', sum(v) OVER (ORDER BY t)) AS s FROM steps)
SELECT (SELECT v.id FROM tr, json_each(tr.tj) je
         JOIN (SELECT id, mmsi, (row_number() OVER (ORDER BY rowid) - 1) AS doc_id
                 FROM vmd_vessels) v ON v.doc_id = json_extract(je.value, '$.doc_id')
        ORDER BY json_extract(je.value, '$.distance') LIMIT 1) AS nearest_fleet_id,
       (SELECT json_extract(je.value, '$.distance') FROM tr, json_each(tr.tj) je
        ORDER BY json_extract(je.value, '$.distance') LIMIT 1) AS trajectory_distance,
       fractal_dimension_dfa('[' || (SELECT group_concat(s) FROM walk) || ']')
           AS dfa_exponent;
SELECT fractal_reason('one-line track-anomaly read for this vessel');

-- ------------------------------------------------------------------
-- 5. Reasoning: the "does vessel 7's track need attention?" narrative
-- is carried by the track_anomaly composition's rationale above (the
-- same trajectory deviation + heading DFA, folded into one reasoning
-- step).
-- ------------------------------------------------------------------
.print
.print === 5. Reasoning: carried by the track_anomaly composition rationale above ===

.print
.print === Demo complete ===
.print Tables left in place for inspection. Clean up with:
.print   DROP TABLE vmd_vessels;
.print ================================================================