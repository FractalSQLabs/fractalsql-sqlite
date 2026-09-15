-- demo/demo-vertical-fleet-logistics.sql
--
-- Industry vertical: Autonomous Fleet Management & Last-Mile Delivery.
--
-- A 40-vehicle delivery fleet with route-embedding vectors, one vehicle
-- running a deliberately-detouring route. Diverse depot-coverage
-- clustering, a cohort-restricted search (today's route-3 vehicles
-- only), current-vs-baseline detour detection, and GPS-trace
-- complexity via box-counting.
--
-- Prerequisites: extension loaded (sections 0-4 need nothing else).
-- Section 5's rationale call needs the reasoning plugin -- see
-- ../docs/reasoning-setup.md (per-connection fractalsql_set state, so
-- re-apply your load_fractalsql.sql snippet with -init).
--
-- Run (one invocation):
--   sqlite3 -cmd ".load /usr/local/lib/sqlite3/fractalsql" ":memory:" \
--     ".read demo/demo-vertical-fleet-logistics.sql"
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
--   * The fractal_agent_* presets are blueprint compositions over the
--     primitives (see demo-agents.sql for the pattern).
--   * doc_id is the row's 0-based position in the search's own scan
--     order, and in SQLite that order IS rowid order (UPDATE keeps a
--     rowid table's physical position on UPDATE);
--     vfl_vehicles' rowid aliases its INTEGER PRIMARY KEY id, so doc_id
--     = id - 1 exactly, stable across the section-1 UPDATE.
--
-- Safe to re-run: vfl_* tables are dropped and recreated each time.

.timer on

.print === 0. Sanity check: extension loaded? ===
SELECT fractalsql_edition(), fractalsql_version();

-- ------------------------------------------------------------------
-- 1. 40 delivery vehicles across 4 routes, each with a BASELINE route
-- vector (planned stop sequence, embedded) and a CURRENT route vector
-- (today's actual telemetry). Vehicle 5 gets a deliberate large
-- detour; everyone else's current stays close to baseline (normal
-- traffic/timing noise).
-- ------------------------------------------------------------------
.print
.print === 1. 40 delivery vehicles: baseline vs. current route vectors ===

DROP TABLE IF EXISTS vfl_vehicles;
CREATE TABLE vfl_vehicles (
    id        INTEGER PRIMARY KEY,
    van_id    TEXT,
    route_no  INTEGER,
    baseline  TEXT NOT NULL
              CHECK (fractal_vector_dims(baseline) = 4),
    current   TEXT NOT NULL
              CHECK (fractal_vector_dims(current) = 4)
);

-- Baselines are four random components per vehicle; current is the same
-- shape plus ordinary traffic/timing noise, generated with a recursive CTE.
INSERT INTO vfl_vehicles (van_id, route_no, baseline, current)
WITH RECURSIVE gs(g) AS (SELECT 1 UNION ALL SELECT g + 1 FROM gs WHERE g < 40)
SELECT 'VAN-' || g, ((g - 1) % 4) + 1,
       '[' || printf('%.4f,%.4f,%.4f,%.4f', b1, b2, b3, b4) || ']',
       '[' || printf('%.4f,%.4f,%.4f,%.4f',
                     b1 + (random() / 9223372036854775808.0 - 0.5) * 0.06,
                     b2 + (random() / 9223372036854775808.0 - 0.5) * 0.06,
                     b3 + (random() / 9223372036854775808.0 - 0.5) * 0.06,
                     b4 + (random() / 9223372036854775808.0 - 0.5) * 0.06) || ']'
FROM (SELECT g,
             random() / 9223372036854775808.0 AS b1,
             random() / 9223372036854775808.0 AS b2,
             random() / 9223372036854775808.0 AS b3,
             random() / 9223372036854775808.0 AS b4
        FROM gs);

-- Vehicle 5's deliberate detour: current route vector far from its plan.
UPDATE vfl_vehicles
   SET current = printf('[%.4f,%.4f,%.4f,%.4f]',
                        json_extract(baseline, '$[0]') - 0.7,
                        json_extract(baseline, '$[1]') + 0.6,
                        json_extract(baseline, '$[2]') + 0.5,
                        json_extract(baseline, '$[3]') - 0.4)
 WHERE id = 5;

-- ------------------------------------------------------------------
-- 2. Scout Discovery: diverse route/zone clustering across the fleet --
-- depot coverage planning ("what KINDS of routes are actually running
-- today") without scanning all 40 by hand.
-- ------------------------------------------------------------------
.print
.print === 2. Diverse route/zone clustering ===
.print --- raw explore form (query-agnostic -- explore samples the space) ---
WITH e AS (SELECT fractal_search_explore(current, '0,0.2,0,0',
                                  '{"population_size": 6, "iterations": 8, "walk": 0}') AS res
             FROM vfl_vehicles)
SELECT value AS particle
  FROM e, json_each(e.res, '$.population');

-- Productized preset (the recommend_diverse composition): real vehicle
-- ids + scores (1 - cosine_distance) with session-global repulsion
-- enabled, then we restore the session so the section-3 cohort search
-- below sees the same diversify-off state as before (the composition
-- leaves diversify on -- the caller owns that policy). The raw explore
-- above is query-agnostic; the telemetry form is query-anchored, so
-- anchor on the first vehicle's own current vector.
.print --- recommend_diverse composition (query-anchored, repulsion on) ---
WITH t AS (SELECT json_extract(value, '$.doc_id')   AS doc_id,
                  json_extract(value, '$.distance') AS dist
             FROM json_each(fractal_search_telemetry(
                      'vfl_vehicles', 'current',
                      (SELECT current FROM vfl_vehicles ORDER BY id LIMIT 1), 6)))
SELECT m.id       AS item_id,
       m.van_id   AS van_id,
       1.0 - t.dist AS score
FROM t
JOIN (SELECT id, van_id, (row_number() OVER (ORDER BY rowid) - 1) AS doc_id
        FROM vfl_vehicles) m USING (doc_id)
ORDER BY t.dist;
SELECT fractal_diversify_disable();

-- ------------------------------------------------------------------
-- 3. Cohort-restricted search: "today's route-3 vehicles only" -- a
-- cohort filter composes by searching a filtered temp table (the same
-- cohort-then-search shape fractal_hybrid_clinical_search uses
-- internally for its doc_ids allowlist). doc_id is the row's 0-based
-- position in the search's own scan, which for a rowid table is rowid
-- order -- and the temp cohort carries the real ids (SELECT * keeps
-- them), so the row_number mapping below resolves doc_id back to
-- van_id without assuming id - 1.
-- ------------------------------------------------------------------
.print
.print === 3. Cohort-restricted search: route-3 vehicles only ===

DROP TABLE IF EXISTS vfl_route3_cohort;
CREATE TEMP TABLE vfl_route3_cohort AS
SELECT * FROM vfl_vehicles WHERE route_no = 3;

WITH t AS (SELECT json_extract(value, '$.doc_id')   AS doc_id,
                  json_extract(value, '$.distance') AS dist
             FROM json_each(fractal_search_telemetry(
                      'vfl_route3_cohort', 'current', '0.3,-0.3,0.2,0.1', 5)))
SELECT v.van_id, t.dist AS distance
FROM t
JOIN (SELECT van_id, (row_number() OVER (ORDER BY rowid) - 1) AS doc_id
        FROM vfl_route3_cohort) v ON v.doc_id = t.doc_id
ORDER BY t.dist;

-- ------------------------------------------------------------------
-- 4. fractal_search_trajectory: current vs. baseline DELTA for vehicle
-- 5 -- detour detection, "what changed" not "what's closest". The
-- baseline/current TEXT columns resolve the vector primitives
-- directly. This scans the FULL vfl_vehicles table (which includes
-- vehicle 5's own row); the rowid mapping resolves doc_id back to
-- van_id.
-- ------------------------------------------------------------------
.print
.print === 4. Vehicle 5 detour vs. the fleet (fractal_search_trajectory) ===

WITH tr AS (SELECT fractal_search_trajectory(
                    'vfl_vehicles', 'current',
                    (SELECT baseline FROM vfl_vehicles WHERE id = 5),
                    (SELECT current  FROM vfl_vehicles WHERE id = 5),
                    5) AS tj)
SELECT v.van_id, json_extract(je.value, '$.distance') AS distance
FROM tr, json_each(tr.tj) je
JOIN (SELECT van_id, (row_number() OVER (ORDER BY rowid) - 1) AS doc_id
        FROM vfl_vehicles) v ON v.doc_id = json_extract(je.value, '$.doc_id')
ORDER BY json_extract(je.value, '$.distance');

-- ------------------------------------------------------------------
-- 5. fractal_dimension_boxcount: GPS-trace complexity for vehicle 5's
-- detoured route (a 2D wandering path, 200 samples) -- a smooth planned
-- route would trace a near-straight path (dimension close to 1); a
-- detour with backtracking/wandering pushes it higher. (A recursive CTE
-- generates the sample index; the running sum is materialized with a
-- window function.)
-- ------------------------------------------------------------------
.print
.print === 5. Vehicle 5 GPS-trace complexity (box counting) ===

-- Raw primitive: the GPS trace's box-counting complexity.
WITH gs(t) AS (SELECT 1 UNION ALL SELECT t + 1 FROM gs WHERE t < 200),
steps AS (SELECT t,
                 (random() / 9223372036854775808.0 - 0.5) * 0.3 AS vx,
                 (random() / 9223372036854775808.0 - 0.5) * 0.3 AS vy
            FROM gs),
walk AS (SELECT printf('%.4f,%.4f',
                       sum(vx) OVER (ORDER BY t),
                       sum(vy) OVER (ORDER BY t)) AS p
           FROM steps)
SELECT fractal_dimension_boxcount(
           '[' || (SELECT group_concat(p) FROM walk) || ']', 2)
           AS gps_trace_dimension;

-- Composition (the detour_classify shape): the real nearest fleet
-- vehicle (fractal_search_trajectory over vehicle 5's
-- baseline->current, resolved through the rowid mapping), the real
-- trajectory_distance, the real GPS-trace box-counting complexity, plus
-- a real rationale (plugin-gated: the clean hint is the expected output
-- without one).
.print --- detour_classify composition (trajectory + trace + reason) ---
WITH tr AS (SELECT fractal_search_trajectory(
                    'vfl_vehicles', 'current',
                    (SELECT baseline FROM vfl_vehicles WHERE id = 5),
                    (SELECT current  FROM vfl_vehicles WHERE id = 5),
                    5) AS tj),
gs(t) AS (SELECT 1 UNION ALL SELECT t + 1 FROM gs WHERE t < 200),
steps AS (SELECT t,
                 (random() / 9223372036854775808.0 - 0.5) * 0.3 AS vx,
                 (random() / 9223372036854775808.0 - 0.5) * 0.3 AS vy
            FROM gs),
walk AS (SELECT printf('%.4f,%.4f',
                       sum(vx) OVER (ORDER BY t),
                       sum(vy) OVER (ORDER BY t)) AS p
           FROM steps)
SELECT (SELECT v.id FROM tr, json_each(tr.tj) je
         JOIN (SELECT id, van_id, (row_number() OVER (ORDER BY rowid) - 1) AS doc_id
                 FROM vfl_vehicles) v ON v.doc_id = json_extract(je.value, '$.doc_id')
        ORDER BY json_extract(je.value, '$.distance') LIMIT 1) AS nearest_fleet_id,
       (SELECT json_extract(je.value, '$.distance') FROM tr, json_each(tr.tj) je
        ORDER BY json_extract(je.value, '$.distance') LIMIT 1) AS trajectory_distance,
       fractal_dimension_boxcount(
           '[' || (SELECT group_concat(p) FROM walk) || ']', 2) AS trace_complexity;
SELECT fractal_reason('one-line detour classification for this fleet vehicle');

-- ------------------------------------------------------------------
-- 6. Reasoning: the dispatch narrative for vehicle 5 is carried by the
-- detour composition's rationale above (the same trajectory deviation +
-- GPS-trace complexity, folded into one reasoning step).
-- ------------------------------------------------------------------
.print
.print === 6. Reasoning: carried by the detour composition rationale above ===

.print
.print === Demo complete ===
.print Tables left in place for inspection. Clean up with:
.print   DROP TABLE vfl_vehicles;
.print (the vfl_* TEMP tables evaporate with the connection.)
.print ================================================================