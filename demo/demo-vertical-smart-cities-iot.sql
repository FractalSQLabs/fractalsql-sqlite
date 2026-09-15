-- demo/demo-vertical-smart-cities-iot.sql
--
-- Industry vertical: Smart Cities & IoT Sensor Grids.
--
-- A 400-sensor city grid (traffic/air-quality/noise, jittered 20x20
-- placement) for spatial coverage-complexity analysis, one sensor's
-- reading series carrying a deliberate regime shift (an air-quality
-- event) for DFA/drift detection, and diverse representative-zone
-- sampling across the grid.
--
-- Prerequisites: extension installed (sections 0-4 need nothing else).
-- Section 5's closing rationale call needs the reasoning plugin -- see
-- ../docs/reasoning-setup.md (per-connection fractalsql_set state, so
-- re-apply your load_fractalsql.sql snippet with -init).
--
-- Run (one invocation -- fractalsql_set state is per-connection):
--   sqlite3 -cmd ".load /usr/local/lib/sqlite3/fractalsql" ":memory:" \
--     ".read demo/demo-vertical-smart-cities-iot.sql"
--
-- Notes:
--   * There is no seedable global RNG -- the fixtures are plain
--     random() (a signed 64-bit integer here, mapped into [0,1) with
--     (random()/2^63 + 1)/2), so the sensor placement differs run to
--     run; every analysis output stays structurally identical.
--   * The point cloud is flattened into one CSV TEXT string via a
--     window-sum over the (row, col) grid pass (built with recursive
--     CTEs).
--   * The fractal_agent_network_coverage_alert / _regime_triage /
--     _recommend_diverse presets are blueprint compositions over the
--     primitives (morphology+drift; dfa+drift; explore+scores) -- see
--     demo-agents.sql for the pattern.
--   * doc_id is the row's 0-based scan position; sensors' rowid aliases
--     the INTEGER PRIMARY KEY id, so doc_id = id - 1 exactly (rowid
--     tables keep their physical position).
--
-- Safe to re-run: vsc_* tables are dropped and recreated each time.

.timer on

.print === 0. Sanity check: extension loaded? ===
SELECT fractalsql_edition(), fractalsql_version();

-- ------------------------------------------------------------------
-- 1. 400 sensors: a jittered 20x20 grid placement (lat/lon-style x,y
-- position) plus a 3-dim reading vector [traffic, air_quality, noise].
-- A grid-like layout, not sparse random scatter, is what the box-
-- counting-based functions below need to find enough occupied-cell
-- structure across eps scales (same requirement
-- demo/demo-vertical-sovereign-edge-ai.sql's facility-grid section
-- documents).
-- ------------------------------------------------------------------
.print
.print === 1. 400 sensors: jittered 20x20 city grid + readings ===

DROP TABLE IF EXISTS vsc_sensors;
CREATE TABLE vsc_sensors (
    id        INTEGER PRIMARY KEY,
    sensor_id TEXT,
    pos       TEXT NOT NULL CHECK (fractal_vector_dims(pos) = 2),
    -- [x, y] placement as CSV TEXT -- the flat point-cloud input for
    -- fractal_dimension_boxcount / fractal_morphological_complexity
    -- below is group_concat over this column in rowid order.
    reading   TEXT NOT NULL CHECK (fractal_vector_dims(reading) = 3)
    -- a fixed-width [traffic, air_quality, noise] vector where
    -- dimension safety matters (it's read as a vector_col search corpus
    -- by fractal_search_explore below), same argument as the other updated
    -- verticals.
);

-- The jittered grid in one recursive pass. The grid CTE stops at the
-- last cell (r = 19 AND c = 19) so the overshoot row can't break the
-- box-counting even-count rule (exactly 400 points = 800 flat coords).
WITH RECURSIVE
g(r, c) AS (
    SELECT 0, 0
    UNION ALL
    SELECT CASE WHEN c = 19 THEN r + 1 ELSE r END,
           CASE WHEN c = 19 THEN 0 ELSE c + 1 END
    FROM g WHERE NOT (r = 19 AND c = 19))
INSERT INTO vsc_sensors (sensor_id, pos, reading)
SELECT 'SENSOR-' || (r * 20 + c + 1),
       printf('%.4f,%.4f',
              r + ((random() / 9223372036854775808.0 + 1) / 2 - 0.5) * 0.3,
              c + ((random() / 9223372036854775808.0 + 1) / 2 - 0.5) * 0.3),
       printf('%.4f,%.4f,%.4f',
              (random() / 9223372036854775808.0 + 1) / 2 * 2 - 1,
              (random() / 9223372036854775808.0 + 1) / 2 * 2 - 1,
              (random() / 9223372036854775808.0 + 1) / 2 * 2 - 1)
FROM g;

SELECT (SELECT count(*) FROM vsc_sensors) AS sensors;

-- ------------------------------------------------------------------
-- 2. fractal_dimension_boxcount / fractal_morphological_complexity over
-- the sensor grid's spatial layout -- coverage-density diagnostics
-- (a HIGHER dimension + moderate lacunarity means denser, more even
-- coverage; a lower dimension or high lacunarity would flag sparse or
-- clustered deployment -- a jittered 20x20 grid lands between the
-- sparse-scatter and perfect-plane cases, and that's the point: the
-- number moves with how the grid actually covers space).
-- ------------------------------------------------------------------
.print
.print === 2. Sensor grid spatial coverage: dimension + morphological complexity ===

-- The flat point cloud: each pos is already 'x,y' CSV, so
-- group_concat over the grid's insertion order IS the flat 800-coordinate
-- sequence in (row, col) order.
SELECT fractal_dimension_boxcount(
    (SELECT group_concat(pos, ',') FROM vsc_sensors),
    2) AS coverage_dimension;

-- Blueprint (raw primitive): the sensor grid's morphological complexity
-- (box-counting dimension + lacunarity). Generalized by the network_
-- coverage_alert composition below, which folds this together with the
-- air-quality drift series and a reasoning step (plugin-gated).
.print --- coverage complexity (morphological) ---
SELECT fractal_morphological_complexity(
    (SELECT group_concat(pos, ',') FROM vsc_sensors),
    2) AS coverage_complexity;

-- The air-quality event series (240 samples, regime change at t=150:
-- readings hover around a baseline, then an event drives an
-- accumulating drift for the final 90 samples) -- built once here;
-- Section 2's coverage alert and Section 3's dfa+drift read the same
-- series. (A pure volatility rescale wouldn't work here -- the DFA
-- exponent is scale-invariant, so what the drift report reliably flags
-- is exactly this memory-structure change, hovering -> accumulating,
-- in the recent window.)
DROP TABLE IF EXISTS vsc_aq_series;
CREATE TEMP TABLE vsc_aq_series AS
WITH RECURSIVE gs(t, x) AS (
    SELECT 1, (random() / 9223372036854775808.0) * 0.1
    UNION ALL
    SELECT t + 1,
           CASE WHEN t < 150 THEN (random() / 9223372036854775808.0) * 0.1
                ELSE x + (random() / 9223372036854775808.0) * 0.1 END
      FROM gs WHERE t < 240)
SELECT group_concat(printf('%.6f', x), ',') AS series FROM gs;

-- network_coverage_alert composition: the coverage morphological
-- complexity (Section 2), the air-quality drift report (Section 3's
-- primitive), and a reasoning pass (plugin-gated: the clean hint is the
-- expected output without one). The coverage boxcount above stays raw
-- (boxcount-only, no drift/reason step of its own).
.print --- network_coverage_alert composition (morphology + drift + reason) ---
WITH mx AS (SELECT fractal_morphological_complexity(
                    (SELECT group_concat(pos, ',') FROM vsc_sensors),
                    2) AS mj),
     dr AS (SELECT fractal_dimension_drift(
                    (SELECT series FROM vsc_aq_series), 48) AS dj)
SELECT json_extract(mx.mj, '$.dimension')   AS morph_dimension,
       json_extract(mx.mj, '$.lacunarity')  AS lacunarity,
       json_extract(dr.dj, '$.drift')       AS drift,
       json_extract(dr.dj, '$.drift') < -0.5
           OR json_extract(dr.dj, '$.drift') > 0.5 AS drift_detected
FROM mx, dr;
SELECT fractal_reason('city-ops alert rationale over this sensor-grid coverage complexity and air-quality drift reading');

-- ------------------------------------------------------------------
-- 3. fractal_dimension_dfa / fractal_dimension_drift: the air-quality
-- reading series carries a deliberate regime shift (an event) at
-- t=150 of 240 samples -- the same series the Section 2 coverage-alert
-- composition reads. The fractal_agent_regime_triage preset generalizes
-- exactly this dfa+drift pair; the composition's rationale is that
-- composition's reason call.
-- ------------------------------------------------------------------
.print
.print === 3. fractal_dimension_dfa/_drift: air-quality event detection ===

-- Blueprint (raw primitives): the air-quality series' long-range-
-- correlation exponent (DFA) and its regime-change drift report. The
-- fractal_agent_regime_triage preset generalizes exactly this pair;
-- the composition's rationale is the Section 2 coverage-alert reason
-- call.
SELECT fractal_dimension_dfa((SELECT series FROM vsc_aq_series))
           AS whole_series_alpha;
SELECT fractal_dimension_drift((SELECT series FROM vsc_aq_series), 48)
           AS drift_report;
SELECT json_extract(fractal_dimension_drift((SELECT series FROM vsc_aq_series), 48),
                    '$.drift') > 0.5 AS drift_detected;

-- ------------------------------------------------------------------
-- 4. Scout Discovery: diverse representative sample of reading
-- profiles across the grid -- "what KINDS of zones do we actually
-- have" (quiet-residential vs. high-traffic-commercial vs. ...) rather
-- than scanning all 400 sensors by hand.
-- ------------------------------------------------------------------
.print
.print === 4. fractal_search_explore: diverse zone reading-profiles ===
.print --- recommend_diverse blueprint (explore + query anchor + scores) ---

-- Blueprint (raw primitive): Scout returns a diverse representative set
-- of reading-profile embeddings -- "what KINDS of zones do we have".
-- The fractal_agent_recommend_diverse preset anchors it on a real
-- query and scores the population. Here: anchor on the first
-- sensor's own reading (the nearest result is itself, score 1) and
-- score each member 1 - cosine distance to the anchor. (The aggregate
-- fractal_search_explore over your own column runs once per distinct query per
-- scan -- the same memoized form demo/benchmark.sql uses.)
WITH anchor AS (SELECT reading AS a FROM vsc_sensors ORDER BY id LIMIT 1),
     e AS (SELECT fractal_search_explore(reading, '0,0,0',
                                  '{"population_size": 6, "iterations": 8, "walk": 0}') AS res
             FROM vsc_sensors),
     pop AS (SELECT DISTINCT value AS member FROM e, json_each(e.res, '$.population'))
SELECT member, 1.0 - fractal_vector_cosine_distance(anchor.a, member) AS score
FROM anchor, pop
ORDER BY score DESC;
SELECT fractal_diversify_disable();

-- ------------------------------------------------------------------
-- 5. Reasoning: the city-ops narrative over coverage + drift is the
-- network_coverage_alert composition's reason call in Section 2 (the
-- same coverage morphological complexity + air-quality drift, folded
-- into one reasoning step).
-- ------------------------------------------------------------------
.print
.print === 5. Reasoning: carried by the Section 2 network_coverage_alert rationale ===

.print
.print === Demo complete ===
.print Tables left in place for inspection. Clean up with:
.print   DROP TABLE vsc_sensors;
.print (the vsc_* TEMP tables evaporate with the connection.)
.print ================================================================