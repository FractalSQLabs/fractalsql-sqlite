-- demo/demo-vertical-sovereign-edge-ai.sql
--
-- Industry vertical: Sovereign, Edge & Autonomous Systems AI.
--
-- FractalSQL's whole story fits this vertical natively: search,
-- reasoning, and optimization all run as pure C inside the same SQLite
-- process -- no external vector-DB service, no cloud API call required
-- for search/optimization, and even fractal_reason() can point at a
-- fully local model (see ../docs/reasoning-setup.md's air-gapped
-- guidance) for environments where a network call out is unacceptable.
-- This script: a fleet of 50 edge-compute nodes, finding the best node
-- for a workload (Sniper), a diverse representative sample of the fleet
-- (Scout), and fractal_optimize_portfolio repurposed as a general
-- on-device black-box resource allocator (its own doc comment already
-- frames it as a generic cardinality-constrained optimizer, not
-- finance-specific).
--
-- Prerequisites: extension installed (sections 0-5 need nothing else).
-- Section 6 calls fractal_reason() -- see ../docs/reasoning-setup.md
-- (per-connection fractalsql_set state, so re-apply your
-- load_fractalsql.sql snippet with -init).
--
-- Run (one invocation -- fractalsql_set state is per-connection):
--   sqlite3 -cmd ".load /usr/local/lib/sqlite3/fractalsql" ":memory:" \
--     ".read demo/demo-vertical-sovereign-edge-ai.sql"
--
-- Notes:
--   * There is no seedable global RNG -- the fixtures are plain
--     random() (a signed 64-bit integer here, mapped into [0,1) with
--     (random()/2^63 + 1)/2), so the fleet differs run to run; the
--     optimizer itself stays deterministic via its seed argument.
--   * The fractal_agent_schedule_workload / _recommend_diverse /
--     _allocate presets are blueprint compositions over the primitives
--     (telemetry refinement; explore + scores; the optimizer) -- see
--     demo-agents.sql for the pattern.
--   * The deployment grid is flattened into one CSV TEXT string via a
--     recursive pass (the boxcount fixture is the same shape
--     demo/demo-vertical-smart-cities-iot.sql uses).
--   * doc_id is the row's 0-based scan position; nodes' rowid aliases
--     the INTEGER PRIMARY KEY id, so doc_id = id - 1 exactly (rowid
--     tables keep their physical position).
--
-- Safe to re-run: vse_* tables are dropped and recreated each time.

.timer on

.print === 0. Sanity check: extension + edition loaded? ===
SELECT fractalsql_edition(), fractalsql_version();

-- ------------------------------------------------------------------
-- 1. 50 edge-compute nodes with a 5-dim resource-capability vector:
-- [cpu_free, mem_free, gpu_avail, net_headroom, battery] each roughly
-- normalized to [-1,1] (1 = plenty of headroom).
-- ------------------------------------------------------------------
.print
.print === 1. 50 edge-compute nodes: resource-capability vectors ===

DROP TABLE IF EXISTS vse_nodes;
-- CSV TEXT with a CHECK(fractal_vector_dims(capability) = 5) guard: a
-- malformed capability report from an edge node is a real operational
-- failure mode this CHECK catches at write time;
-- fractal_search_telemetry / fractal_search_explore below read the CSV TEXT
-- column transparently (the same dispatch the other verticals use).
CREATE TABLE vse_nodes (
    id         INTEGER PRIMARY KEY,
    node_name  TEXT,
    capability TEXT NOT NULL CHECK (fractal_vector_dims(capability) = 5)
);
WITH RECURSIVE gs(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM gs WHERE n < 50)
INSERT INTO vse_nodes (node_name, capability)
SELECT 'edge-node-' || n,
       printf('%.4f,%.4f,%.4f,%.4f,%.4f',
              (random() / 9223372036854775808.0 + 1) / 2 * 2 - 1,
              (random() / 9223372036854775808.0 + 1) / 2 * 2 - 1,
              (random() / 9223372036854775808.0 + 1) / 2 * 2 - 1,
              (random() / 9223372036854775808.0 + 1) / 2 * 2 - 1,
              (random() / 9223372036854775808.0 + 1) / 2 * 2 - 1)
FROM gs;

-- ------------------------------------------------------------------
-- 2. fractal_dimension_boxcount over the physical facility layout: a
-- 20x20 grid of candidate rack positions with small placement jitter --
-- a spatial-complexity signal for constrained-compute monitoring, the
-- spatial sibling of DFA's own time-series complexity signal. Needs
-- enough SPACE-FILLING points for the internal box-counting estimator
-- to find >= 3 valid eps-octaves (same validity filter as
-- demo/demo-vertical-medtech-clinical.sql's vessel/nerve fixtures) -- a
-- sparse or purely random scatter (like the 50-node capability table
-- above) is too sparse for this filter, a physical grid isn't.
-- ------------------------------------------------------------------
.print
.print === 2. fractal_dimension_boxcount: facility deployment-grid density ===
.print '(dimension near 2.0 means the deployment fills the available floor'
.print 'space; a lower number would flag a sparse or corner-clustered rollout)'

-- A jittered 20x20 grid in one recursive pass; the grid CTE stops at
-- the last cell so the overshoot row can't break the box-counting
-- even-count rule (exactly 400 points = 800 flat coords).
WITH RECURSIVE
g(r, c) AS (
    SELECT 0, 0
    UNION ALL
    SELECT CASE WHEN c = 19 THEN r + 1 ELSE r END,
           CASE WHEN c = 19 THEN 0 ELSE c + 1 END
    FROM g WHERE NOT (r = 19 AND c = 19)),
cells AS (SELECT printf('%.4f,%.4f',
              r + ((random() / 9223372036854775808.0 + 1) / 2 - 0.5) * 0.3,
              c + ((random() / 9223372036854775808.0 + 1) / 2 - 0.5) * 0.3) AS p FROM g)
SELECT fractal_dimension_boxcount(
    (SELECT group_concat(p, ',') FROM cells),
    2
) AS deployment_grid_dimension;

-- ------------------------------------------------------------------
-- 3. Sniper Search: converge toward the ideal node profile for a
-- GPU-heavy inference workload (high GPU, high mem, moderate CPU).
-- fractal_search_telemetry then maps that ideal profile to a REAL node
-- to actually schedule onto.
-- ------------------------------------------------------------------
.print
.print === 3. Sniper Search: ideal node profile for a GPU-inference workload ===

-- Blueprint (raw primitives): refine the workload vector with
-- fractal_search_debug (the "sniper search" in the abstract space,
-- with documented [iterations, population, diffusion] options), then
-- map the refined profile to a REAL node with
-- fractal_search_telemetry. The schedule_workload composition below
-- folds both steps together and reasons (plugin-gated).
.print --- sniper: refine the ideal node profile (fractal_search_debug) ---
SELECT json_extract(fractal_search_debug('[0.3,0.6,0.9,0.2,0.0]', 50),
                    '$.best_fit')   AS best_fit,
       json_extract(fractal_search_debug('[0.3,0.6,0.9,0.2,0.0]', 50),
                    '$.best_point') AS refined_profile;

.print --- schedule_workload composition: nearest REAL node (telemetry) ---
WITH sj AS (SELECT fractal_search_debug('[0.3,0.6,0.9,0.2,0.0]', 50) AS dj),
     bp AS (SELECT json_extract(dj, '$.best_point') AS refined FROM sj),
     tj AS (SELECT fractal_search_telemetry('vse_nodes', 'capability',
                    (SELECT refined FROM bp), 5) AS rj)
SELECT n.id  AS assigned_node,
       n.node_name,
       json_extract(je.value, '$.distance') AS distance,
       1.0 / (1.0 + json_extract(je.value, '$.distance')) AS confidence
FROM tj, json_each(tj.rj) je
JOIN vse_nodes n ON n.id - 1 = json_extract(je.value, '$.doc_id')
ORDER BY json_extract(je.value, '$.distance');
SELECT fractal_reason('placement rationale for the nearest edge node to this refined workload profile');

-- ------------------------------------------------------------------
-- 4. Scout Discovery: a diverse representative sample of the fleet's
-- distinct capability profiles -- useful for capacity planning ("what
-- KINDS of nodes do we actually have") without scanning all 50 by hand.
-- ------------------------------------------------------------------
.print
.print === 4. Scout Discovery: diverse fleet capability profiles ===
.print --- recommend_diverse blueprint (explore + query anchor + scores) ---

-- Blueprint (raw primitive): Scout returns a diverse representative set
-- of the fleet's distinct capability-profile embeddings. The
-- fractal_agent_recommend_diverse preset anchors it on a real query
-- and scores the population. Here: anchor on the first node's own
-- capability vector (the nearest result is itself, score 1) and score
-- each member 1 - cosine distance to the anchor. (The aggregate
-- fractal_search_explore over your own column runs once per distinct query per
-- scan -- the same memoized form demo/benchmark.sql uses.)
WITH anchor AS (SELECT capability AS a FROM vse_nodes ORDER BY id LIMIT 1),
     e AS (SELECT fractal_search_explore(capability, '0,0,0,0,0',
                                  '{"population_size": 6, "iterations": 8, "walk": 0}') AS res
             FROM vse_nodes),
     pop AS (SELECT DISTINCT value AS member FROM e, json_each(e.res, '$.population'))
SELECT member, 1.0 - fractal_vector_cosine_distance(anchor.a, member) AS score
FROM anchor, pop
ORDER BY score DESC;
SELECT fractal_diversify_disable();

-- ------------------------------------------------------------------
-- 5. fractal_optimize_portfolio as a general on-device black-box
-- resource allocator: which 6 of these 50 nodes should a distributed
-- job land on, maximizing an "efficiency Sharpe" over expected
-- throughput (mu) vs. contention risk (cov, higher between nodes on
-- the same rack/subnet)? Cardinality-constrained, NP-hard in general --
-- exactly the ruggedness class this SFS-backed optimizer targets (see
-- that function's own doc comment).
-- ------------------------------------------------------------------
.print
.print === 5. fractal_optimize_portfolio: pick 6-of-50 nodes for a distributed job ===

DROP TABLE IF EXISTS vse_throughput;
CREATE TABLE vse_throughput (
    node_id             INTEGER PRIMARY KEY,
    expected_throughput REAL,
    rack                INTEGER
);
INSERT INTO vse_throughput (node_id, expected_throughput, rack)
SELECT id, 0.4 + ((random() / 9223372036854775808.0 + 1) / 2) * 0.6, (id - 1) / 10
FROM vse_nodes;

DROP TABLE IF EXISTS vse_contention_flat;
CREATE TEMP TABLE vse_contention_flat AS
SELECT a.node_id AS i, b.node_id AS j,
       CASE WHEN a.node_id = b.node_id THEN 0.05
            WHEN a.rack = b.rack THEN 0.06
            ELSE 0.005 END AS c_ij
FROM vse_throughput a
CROSS JOIN vse_throughput b;

-- The allocation here IS the shipped optimizer (the fractal_agent_allocate
-- preset runs it and reasons a placement rationale over its
-- {sharpe, weights} output; that rationale is the Section 6 closing
-- reason call). mu/cov are flat CSV: row-major n*n for cov, one
-- throughput per node in node_id order.
WITH alloc AS (SELECT fractal_optimize_portfolio(
    (SELECT group_concat(expected_throughput, ',')
       FROM (SELECT expected_throughput FROM vse_throughput ORDER BY node_id)),
    (SELECT group_concat(c_ij, ',')
       FROM (SELECT c_ij FROM vse_contention_flat ORDER BY i, j)),
    6, 7) AS rj)
SELECT json_extract(rj, '$.sharpe') AS sharpe FROM alloc;
WITH alloc AS (SELECT fractal_optimize_portfolio(
    (SELECT group_concat(expected_throughput, ',')
       FROM (SELECT expected_throughput FROM vse_throughput ORDER BY node_id)),
    (SELECT group_concat(c_ij, ',')
       FROM (SELECT c_ij FROM vse_contention_flat ORDER BY i, j)),
    6, 7) AS rj)
SELECT t.node_id, n.node_name, json_extract(je.value, '$') AS weight
FROM alloc, json_each(alloc.rj, '$.weights') je
JOIN vse_throughput t ON t.node_id = (je.key + 1)
JOIN vse_nodes n ON n.id = t.node_id
WHERE json_extract(je.value, '$') > 1e-9
ORDER BY json_extract(je.value, '$') DESC;

-- ------------------------------------------------------------------
-- 6. Reasoning: narrate the placement decision. Runs against whatever
-- endpoint fractalsql http_url points at -- a fully local model on a
-- LAN-only host demonstrates the air-gapped-capable story this
-- vertical cares about (see ../docs/reasoning-setup.md). Plugin-gated:
-- the clean hint is the expected output without one.
-- ------------------------------------------------------------------
.print
.print === 6. Reasoning over the placement decision ===

WITH alloc AS (SELECT fractal_optimize_portfolio(
    (SELECT group_concat(expected_throughput, ',')
       FROM (SELECT expected_throughput FROM vse_throughput ORDER BY node_id)),
    (SELECT group_concat(c_ij, ',')
       FROM (SELECT c_ij FROM vse_contention_flat ORDER BY i, j)),
    6, 7) AS rj)
SELECT fractal_reason(
    'given this cardinality-constrained node allocation (sharpe + weights per node), explain the placement decision and any risk from rack co-location',
    (SELECT rj FROM alloc));

.print
.print === Demo complete ===
.print Tables left in place for inspection. Clean up with:
.print   DROP TABLE vse_nodes, vse_throughput;
.print (the vse_* TEMP tables evaporate with the connection.)
.print ================================================================