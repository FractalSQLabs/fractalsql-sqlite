-- demo/demo-vertical-scenario-planning-simulation.sql
--
-- Industry vertical: strategic scenario planning and simulation training
-- -- business continuity, logistics contingency, tabletop and training
-- exercises.  DOMAIN kit built on one installed agent,
-- fractal_agent_plan_explore (MCTS-style exploration), reused verbatim:
-- its designed job is to produce a SPREAD of distinct, non-overlapping
-- strategy trajectories from a seed state, which is exactly a scenario
-- variant set.
--
--   1. A strategy / scenario space (24 candidate scenarios placed in a
--      4-dimension option space: cost, risk, speed, resilience).
--   2. fractal_search_explore (Scout, the diversity-first search) over
--      the raw option space -- pure analytics, no model -- to pick six
--      deliberately different scenarios.
--   3. fractal_agent_plan_explore -- the shipped agent: embeds a seed
--      state description and Scout-searches the vectorized scenario
--      descriptions for diverse branches (needs an embedding endpoint
--      and the reasoning plugin; clean hint without them).
--   4. A closing fractal_reason() summarizes the generated scenario set.
--
-- Prerequisites: extension loaded.  Sections 1-3 need nothing else.
-- Section 4 needs an embedding endpoint and Section 5 the reasoning
-- plugin -- see ../docs/vectorizer-setup.md and ../docs/reasoning-setup.md.
--
-- Run (one invocation):
--   sqlite3 -cmd ".load /usr/local/lib/sqlite3/fractalsql" ":memory:" \
--     ".read demo/demo-vertical-scenario-planning-simulation.sql"
--
-- Notes:
--   * Fully deterministic fixture (no random()).
--   * Scout (fractal_search_explore) is a MMR diversity search: lowering
--     mmr_lambda trades relevance to the seed for spread.  Its result is
--     the final population as vectors; Section 3 maps each back to its
--     scenario row by exact option-space coordinates.
--   * The vectorizer registry / queue are TEMP objects per connection; a
--     fresh sqlite3 invocation starts clean, and the conditional spool
--     teardown below is only needed for a same-session re-run.
--
-- Safe to re-run: the sps_* tables are dropped and recreated each time.

.timer on

.timer off
.once sps_vectorizer_teardown.sql
SELECT 'SELECT fractal_vectorizer_drop(id) FROM fractal_vectorizers
     WHERE source_table = ''sps_scenarios'';'
 WHERE EXISTS (SELECT 1 FROM sqlite_temp_master
                WHERE name = 'fractal_vectorizers');
.read sps_vectorizer_teardown.sql
.timer on

.print === 0. Sanity check: extension loaded? ===
SELECT fractalsql_edition(), fractalsql_version();

-- ------------------------------------------------------------------
-- 1. 24 candidate scenarios in four clusters of six.  Coordinates are
-- [cost, risk, speed, resilience], each in 0..1.
-- ------------------------------------------------------------------
.print
.print === 1. Scenario space: 24 candidates in four clusters ===

DROP TABLE IF EXISTS sps_scenarios;
CREATE TABLE sps_scenarios (
    id          INTEGER PRIMARY KEY,
    description TEXT,
    cost        REAL,
    risk        REAL,
    speed       REAL,
    resilience  REAL,
    opt_vec     TEXT NOT NULL CHECK (fractal_vector_dims(opt_vec) = 4),
    embedding   BLOB                       -- populated by the vectorizer
);

WITH RECURSIVE gs(g) AS (SELECT 1 UNION ALL SELECT g + 1 FROM gs WHERE g < 24),
     c(g, cluster, label, c0, c1, c2, c3) AS (
       SELECT g, g % 4,
              CASE g % 4 WHEN 0 THEN 'dual-source suppliers with safety stock'
                         WHEN 1 THEN 'nearshore relocation of critical lines'
                         WHEN 2 THEN 'regional hub-and-spoke redistribution'
                         ELSE 'expedited air-freight surge capacity' END,
              CASE g % 4 WHEN 0 THEN 0.70 WHEN 1 THEN 0.85 WHEN 2 THEN 0.40 ELSE 0.90 END,
              CASE g % 4 WHEN 0 THEN 0.20 WHEN 1 THEN 0.35 WHEN 2 THEN 0.30 ELSE 0.55 END,
              CASE g % 4 WHEN 0 THEN 0.40 WHEN 1 THEN 0.25 WHEN 2 THEN 0.65 ELSE 0.95 END,
              CASE g % 4 WHEN 0 THEN 0.85 WHEN 1 THEN 0.80 WHEN 2 THEN 0.60 ELSE 0.35 END
         FROM gs)
INSERT INTO sps_scenarios (description, cost, risk, speed, resilience, opt_vec)
SELECT label || ' (variant ' || g || ')',
       round(c0 + 0.01 * (g % 5), 3), round(c1 + 0.01 * (g % 3), 3),
       round(c2 + 0.01 * (g % 4), 3), round(c3 - 0.01 * (g % 5), 3),
       printf('%.3f,%.3f,%.3f,%.3f', c0 + 0.01 * (g % 5), c1 + 0.01 * (g % 3),
              c2 + 0.01 * (g % 4), c3 - 0.01 * (g % 5))
  FROM c ORDER BY g;

SELECT count(*) AS scenarios FROM sps_scenarios;

-- ------------------------------------------------------------------
-- 2. Scout over the raw option space: six deliberately different
-- scenarios around the seed "current plan" (cost 0.6, risk 0.3,
-- speed 0.5, resilience 0.7).  A low mmr_lambda favors spread.
-- ------------------------------------------------------------------
.print
.print === 2. Scout (diversity-first): six different scenarios ===

DROP TABLE IF EXISTS sps_scout;
CREATE TABLE sps_scout AS
SELECT fractal_search_explore(opt_vec, '0.6,0.3,0.5,0.7',
           '{"population_size": 6, "iterations": 8, "mmr_lambda": 0.15}') AS rj
  FROM sps_scenarios;

SELECT s.id, s.description
FROM sps_scout t, json_each(json_extract(t.rj, '$.population')) pt
JOIN sps_scenarios s
  ON abs(s.cost       - json_extract(pt.value, '$[0]')) < 1e-6
 AND abs(s.risk       - json_extract(pt.value, '$[1]')) < 1e-6
 AND abs(s.speed      - json_extract(pt.value, '$[2]')) < 1e-6
 AND abs(s.resilience - json_extract(pt.value, '$[3]')) < 1e-6
ORDER BY pt.key;

.print --- coverage: scenario clusters represented in the six picks ---
SELECT count(DISTINCT s.id % 4) AS clusters_covered_of_4
FROM sps_scout t, json_each(json_extract(t.rj, '$.population')) pt
JOIN sps_scenarios s
  ON abs(s.cost       - json_extract(pt.value, '$[0]')) < 1e-6
 AND abs(s.risk       - json_extract(pt.value, '$[1]')) < 1e-6
 AND abs(s.speed      - json_extract(pt.value, '$[2]')) < 1e-6
 AND abs(s.resilience - json_extract(pt.value, '$[3]')) < 1e-6;

-- ------------------------------------------------------------------
-- 3. Vectorize the scenario descriptions (your configured embedding
-- endpoint's width).  Without an endpoint the queued rows fail with a
-- clean last_error (see demo-vectorizer.sql) and the agent call below
-- carries the hint instead -- either way the script completes.
-- ------------------------------------------------------------------
.print
.print === 3. Vectorize the scenario descriptions ===
SELECT fractal_vectorizer_create('sps_scenarios', 'description', 'embedding') AS vectorizer_id;
SELECT fractal_vectorizer_process_queue();

-- ------------------------------------------------------------------
-- 4. The shipped agent: MCTS-style exploration from a seed state.
-- ------------------------------------------------------------------
.print
.print === 4. fractal_agent_plan_explore (MCTS-style scenario branches) ===

SELECT fractal_agent_plan_explore(
    'regional supply disruption with a two-week port closure',
    'sps_scenarios', 'embedding',
    4) AS scenario_branches;

-- ------------------------------------------------------------------
-- 5. Reasoning: a summary of the generated scenario set (plugin-gated;
-- the clean hint is the expected output without one).
-- ------------------------------------------------------------------
.print
.print === 5. Reasoning: summary of the scenario set ===

SELECT fractal_reason(
    'one-line summary of how these continuity scenarios differ and when to use each',
    (SELECT group_concat(s.description, '; ')
       FROM sps_scout t, json_each(json_extract(t.rj, '$.population')) pt
       JOIN sps_scenarios s
         ON abs(s.cost       - json_extract(pt.value, '$[0]')) < 1e-6
        AND abs(s.risk       - json_extract(pt.value, '$[1]')) < 1e-6
        AND abs(s.speed      - json_extract(pt.value, '$[2]')) < 1e-6
        AND abs(s.resilience - json_extract(pt.value, '$[3]')) < 1e-6));

.print
.print === Demo complete ===
.print Tables left in place for inspection. Clean up with:
.print   DROP TABLE sps_scenarios; DROP TABLE sps_scout;
.print (sps_vectorizer_teardown.sql is the teardown spool file in the
.print current directory -- overwritten each run, delete whenever.)
