-- demo/demo-vertical-climatech-risk-exposure.sql
--
-- Industry vertical: Climate Tech -- physical climate-risk exposure
-- monitoring for insurers and asset managers (wildfire, flood, drought
-- hazard sensor grids).  DOMAIN kit built on one installed agent,
-- fractal_agent_network_coverage_alert, reused verbatim: spatial
-- morphology (box-counting dimension + lacunarity) of the hazard grid
-- plus drift of a telemetry series, closing with a risk-exposure
-- narrative.  The kit is shaped like the smart-cities kit's sensor grid,
-- over climate-hazard readings instead of urban IoT sensors.
--
-- Prerequisites: extension loaded.  The hand-composed morphology and
-- drift need no model; the shipped agent and the closing narrative are
-- reasoning-bearing (clean hint without a plugin; see
-- ../docs/reasoning-setup.md).
--
-- Run (one invocation):
--   sqlite3 -cmd ".load /usr/local/lib/sqlite3/fractalsql" ":memory:" \
--     ".read demo/demo-vertical-climatech-risk-exposure.sql"
--
-- Notes:
--   * Fully deterministic fixture: jitter and noise come from integer
--     arithmetic and an LCG in recursive CTEs, not random().
--   * A 20 x 20 sensor grid (400 cells).  A cell is "high hazard" when its
--     fuel-moisture deficit index exceeds 0.40 in the dry season (0.25 in
--     the wet season, where the index runs about half as high).  In the
--     dry season the high-hazard region is large and clumped toward the
--     south-west; in the wet season it is smaller.  The point cloud handed to
--     the morphology estimator is the set of high-hazard cell centers
--     (flat interleaved x,y); it needs a couple of hundred points for a
--     stable estimate, which is why the dry-season cloud is the one the
--     shipped agent is run on.
--   * The drift series is the regional fuel-moisture telemetry: stable
--     for 48 days, then a rapid oscillation as a heat wave begins.
--
-- Safe to re-run: the cre_* tables are dropped and recreated each time.

.timer on

.print === 0. Sanity check: extension loaded? ===
SELECT fractalsql_edition(), fractalsql_version();

-- ------------------------------------------------------------------
-- 1. Hazard grid: a fuel-moisture deficit index per cell for the dry
-- and wet seasons.
-- ------------------------------------------------------------------
.print
.print === 1. 20 x 20 hazard grid, dry vs wet season ===

DROP TABLE IF EXISTS cre_grid;
CREATE TABLE cre_grid (
    r INTEGER, c INTEGER,
    dry_index REAL,
    wet_index REAL
);
WITH RECURSIVE g(r, c) AS (
    SELECT 0, 0 UNION ALL
    SELECT CASE WHEN c = 19 THEN r + 1 ELSE r END,
           CASE WHEN c = 19 THEN 0 ELSE c + 1 END
      FROM g WHERE NOT (r = 19 AND c = 19))
INSERT INTO cre_grid (r, c, dry_index, wet_index)
SELECT r, c,
       (19 - r) / 19.0 * 0.5 + (19 - c) / 19.0 * 0.3 + ((r * 5 + c * 3) % 7) / 70.0 + 0.05,
       ((19 - r) / 19.0 * 0.5 + (19 - c) / 19.0 * 0.3 + ((r * 5 + c * 3) % 7) / 70.0) * 0.55
  FROM g;

SELECT sum(dry_index > 0.40) AS high_hazard_cells_dry,
       sum(wet_index > 0.25) AS elevated_cells_wet
  FROM cre_grid;

-- ------------------------------------------------------------------
-- 2. Hand-composed: morphology of the elevated-hazard region in each
-- season (dry: index > 0.40; wet: index > 0.25, since the wet-season
-- index runs about half as high).  The dry-season region is large and
-- compact; the wet-season region is smaller and gappier.
-- ------------------------------------------------------------------
.print
.print === 2. Morphology of the high-hazard region ===

SELECT 'dry season' AS season,
       round(json_extract(m, '$.dimension'), 3)  AS dimension,
       round(json_extract(m, '$.lacunarity'), 3) AS lacunarity
FROM (SELECT fractal_morphological_complexity(
        '[' || (SELECT group_concat(printf('%d,%d', c, r), ',') FROM
                  (SELECT r, c FROM cre_grid WHERE dry_index > 0.40 ORDER BY r, c)) || ']', 2) AS m);

SELECT 'wet season' AS season,
       round(json_extract(m, '$.dimension'), 3)  AS dimension,
       round(json_extract(m, '$.lacunarity'), 3) AS lacunarity
FROM (SELECT fractal_morphological_complexity(
        '[' || (SELECT group_concat(printf('%d,%d', c, r), ',') FROM
                  (SELECT r, c FROM cre_grid WHERE wet_index > 0.25 ORDER BY r, c)) || ']', 2) AS m);

-- ------------------------------------------------------------------
-- 3. The shipped agent on the dry season: morphology + fuel-moisture
-- drift + a reasoned exposure alert (reasoning plugin).
-- ------------------------------------------------------------------
.print
.print === 3. fractal_agent_network_coverage_alert (dry-season exposure) ===

WITH RECURSIVE n(t, x) AS (
       SELECT 1, 2718 UNION ALL
       SELECT t + 1, (x * 1103515245 + 12345) % 2147483648 FROM n WHERE t < 96),
     sv AS (SELECT t,
                   CASE WHEN t < 49
                        THEN 4.0 + 1.5 * sin(t * 0.31) + (((x / 65536) % 1000) - 500) / 1250.0
                        ELSE 4.0 + 3.0 * sin(t * 1.4)  + (((x / 65536) % 1000) - 500) / 2500.0
                   END AS v FROM n)
SELECT fractal_agent_network_coverage_alert(
    '[' || (SELECT group_concat(printf('%d,%d', c, r), ',') FROM
              (SELECT r, c FROM cre_grid WHERE dry_index > 0.40 ORDER BY r, c)) || ']',
    '[' || (SELECT group_concat(printf('%.4f', v), ',') FROM (SELECT v FROM sv ORDER BY t)) || ']',
    2, 48, 0.5) AS exposure_alert;

-- ------------------------------------------------------------------
-- 4. Reasoning: the risk-exposure narrative (plugin-gated; the clean
-- hint is the expected output without one).
-- ------------------------------------------------------------------
.print
.print === 4. Reasoning: risk-exposure narrative ===

SELECT fractal_reason(
    'one-line physical-climate-risk exposure narrative for an insured portfolio in this region',
    (SELECT fractal_morphological_complexity(
        '[' || (SELECT group_concat(printf('%d,%d', c, r), ',') FROM
                  (SELECT r, c FROM cre_grid WHERE dry_index > 0.40 ORDER BY r, c)) || ']', 2)));

.print
.print === Demo complete ===
.print Tables left in place for inspection. Clean up with:
.print   DROP TABLE cre_grid;
