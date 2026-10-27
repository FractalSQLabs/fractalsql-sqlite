-- demo/demo-vertical-satellite-constellation-coverage.sql
--
-- Industry vertical: space and satellite communications -- constellation
-- coverage monitoring.  DOMAIN kit built on two installed agents:
--
--   * fractal_agent_network_coverage_alert -- spatial morphology of the
--     constellation's footprint grid (box-counting dimension + lacunarity)
--     plus drift of a link-quality telemetry series, flagging coverage
--     gaps and dead zones.  This is the COVERAGE-GAP angle only; orbital
--     drift and collision detection are a different problem and are not
--     covered here.
--   * fractal_agent_schedule_workload -- a secondary branch that models
--     launch-manifest / payload-slot scheduling as a resource-allocation
--     problem (vector-refine + nearest-slot match).
--
-- Prerequisites: extension loaded.  Section 2 and the hand-composed
-- parts need no model; the shipped agents and the closing narrative are
-- reasoning-bearing (clean hint without a plugin; see
-- ../docs/reasoning-setup.md).
--
-- Run (one invocation):
--   sqlite3 -cmd ".load /usr/local/lib/sqlite3/fractalsql" ":memory:" \
--     ".read demo/demo-vertical-satellite-constellation-coverage.sql"
--
-- Notes:
--   * Fully deterministic fixture: jitter and noise come from an integer
--     LCG in recursive CTEs, not random().
--   * The footprint grid is a 20 x 20 lattice of footprint centers (400
--     points, flat interleaved x,y).  The morphology estimator needs a
--     few hundred points for a stable answer, which is why the grid is
--     this size.  The degraded constellation loses a block of footprints
--     (a dead zone), which raises lacunarity (gappiness).
--   * The link-quality series is 96 samples with a regime change at 49:
--     a stable carrier followed by a fast oscillation as a relay degrades.
--   * telemetry doc_id IS the row's rowid.
--
-- Safe to re-run: the scc_* tables are dropped and recreated each time.

.timer on

.print === 0. Sanity check: extension loaded? ===
SELECT fractalsql_edition(), fractalsql_version();

-- ------------------------------------------------------------------
-- 1. Footprint grids: a healthy 20 x 20 lattice and a degraded copy
-- missing an 8 x 8 block (rows 6-13, columns 6-13).
-- ------------------------------------------------------------------
.print
.print === 1. Footprint lattices: healthy (400) vs degraded (336) ===

DROP TABLE IF EXISTS scc_footprints;
CREATE TABLE scc_footprints (
    r INTEGER, c INTEGER, x REAL, y REAL
);
WITH RECURSIVE g(r, c) AS (
    SELECT 0, 0 UNION ALL
    SELECT CASE WHEN c = 19 THEN r + 1 ELSE r END,
           CASE WHEN c = 19 THEN 0 ELSE c + 1 END
      FROM g WHERE NOT (r = 19 AND c = 19))
INSERT INTO scc_footprints (r, c, x, y)
SELECT r, c, c + 0.06 * (((r * 7 + c * 13) % 10) - 5) / 5.0,
             r + 0.06 * (((r * 11 + c * 3) % 10) - 5) / 5.0
  FROM g;

SELECT count(*) AS healthy_footprints,
       sum(NOT (r BETWEEN 6 AND 13 AND c BETWEEN 6 AND 13)) AS degraded_footprints
  FROM scc_footprints;

-- ------------------------------------------------------------------
-- 2. Hand-composed: morphology of each lattice.  The dead zone shows up
-- as higher lacunarity in the degraded constellation.
-- ------------------------------------------------------------------
.print
.print === 2. Morphology: healthy vs degraded constellation ===

SELECT 'healthy' AS constellation,
       round(json_extract(m, '$.dimension'), 3)  AS dimension,
       round(json_extract(m, '$.lacunarity'), 3) AS lacunarity
FROM (SELECT fractal_morphological_complexity(
        '[' || (SELECT group_concat(printf('%.4f,%.4f', x, y), ',') FROM
                  (SELECT x, y FROM scc_footprints ORDER BY r, c)) || ']', 2) AS m);

SELECT 'degraded' AS constellation,
       round(json_extract(m, '$.dimension'), 3)  AS dimension,
       round(json_extract(m, '$.lacunarity'), 3) AS lacunarity
FROM (SELECT fractal_morphological_complexity(
        '[' || (SELECT group_concat(printf('%.4f,%.4f', x, y), ',') FROM
                  (SELECT x, y FROM scc_footprints
                    WHERE NOT (r BETWEEN 6 AND 13 AND c BETWEEN 6 AND 13)
                    ORDER BY r, c)) || ']', 2) AS m);

-- ------------------------------------------------------------------
-- 3. The shipped agent on the degraded constellation: morphology plus
-- link-quality drift plus a reasoned coverage alert (reasoning plugin).
-- ------------------------------------------------------------------
.print
.print === 3. fractal_agent_network_coverage_alert (degraded constellation) ===

WITH RECURSIVE n(t, x) AS (
       SELECT 1, 4242 UNION ALL
       SELECT t + 1, (x * 1103515245 + 12345) % 2147483648 FROM n WHERE t < 96),
     sv AS (SELECT t,
                   CASE WHEN t < 49
                        THEN 4.0 + 1.5 * sin(t * 0.31) + (((x / 65536) % 1000) - 500) / 1250.0
                        ELSE 4.0 + 3.0 * sin(t * 1.4)  + (((x / 65536) % 1000) - 500) / 2500.0
                   END AS v FROM n)
SELECT fractal_agent_network_coverage_alert(
    '[' || (SELECT group_concat(printf('%.4f,%.4f', x, y), ',') FROM
              (SELECT x, y FROM scc_footprints
                WHERE NOT (r BETWEEN 6 AND 13 AND c BETWEEN 6 AND 13)
                ORDER BY r, c)) || ']',
    '[' || (SELECT group_concat(printf('%.4f', v), ',') FROM (SELECT v FROM sv ORDER BY t)) || ']',
    2, 48, 0.5) AS coverage_alert;

-- ------------------------------------------------------------------
-- 4. Secondary branch: launch-manifest scheduling.  Each launch slot
-- has a capability vector [mass_margin, plane_A, plane_B, plane_C,
-- rideshare]; a replacement-satellite payload is placed on the nearest
-- slot.  Vector-refine + nearest-node match, one call.
-- ------------------------------------------------------------------
.print
.print === 4. Launch-slot scheduling: fractal_agent_schedule_workload ===

DROP TABLE IF EXISTS scc_slots;
CREATE TABLE scc_slots (id INTEGER PRIMARY KEY, capability TEXT);
INSERT INTO scc_slots VALUES
    (1, '0.9,0.8,0.0,0.0,0.1'),    -- heavy lift, plane A
    (2, '0.5,0.0,0.9,0.1,0.4'),    -- medium lift, plane B
    (3, '0.3,0.0,0.1,0.9,0.9'),    -- rideshare, plane C
    (4, '0.6,0.1,0.8,0.1,0.2');    -- medium lift, plane B

.print --- hand-composed: nearest slot to the replacement payload ---
WITH t AS (SELECT json_extract(value, '$.doc_id')   AS doc_id,
                  json_extract(value, '$.distance') AS dist
             FROM json_each(fractal_search_telemetry(
                      'scc_slots', 'capability', '0.5,0.0,0.85,0.1,0.35', 1))
            LIMIT 1)
SELECT m.id AS assigned_slot, round(1.0 / (1.0 + t.dist), 4) AS confidence
FROM t JOIN scc_slots m ON m.rowid = t.doc_id;

.print --- the shipped agent: same composition plus refinement, one call (reasoning plugin) ---
SELECT fractal_agent_schedule_workload(
    '0.5,0.0,0.85,0.1,0.35', 'scc_slots', 'capability', 'id', 30, 50) AS slot_assignment;

-- ------------------------------------------------------------------
-- 5. Reasoning: the combined narrative (plugin-gated; the clean hint is
-- the expected output without one).
-- ------------------------------------------------------------------
.print
.print === 5. Reasoning: coverage gap and replacement-launch narrative ===

SELECT fractal_reason(
    'one-line summary of this constellation coverage gap and the launch slot chosen to fill it',
    json_object(
      'coverage', json((SELECT fractal_morphological_complexity(
            '[' || (SELECT group_concat(printf('%.4f,%.4f', x, y), ',') FROM
                      (SELECT x, y FROM scc_footprints
                        WHERE NOT (r BETWEEN 6 AND 13 AND c BETWEEN 6 AND 13)
                        ORDER BY r, c)) || ']', 2))),
      'nearest_slot', json((SELECT fractal_search_telemetry(
            'scc_slots', 'capability', '0.5,0.0,0.85,0.1,0.35', 1)))));

.print
.print === Demo complete ===
.print Tables left in place for inspection. Clean up with:
.print   DROP TABLE scc_footprints; DROP TABLE scc_slots;
