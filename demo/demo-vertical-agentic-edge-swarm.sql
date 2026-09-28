-- demo/demo-vertical-agentic-edge-swarm.sql
--
-- Industry vertical: Agentic Edge / Robotics Swarm Coordination.
--
-- A fleet of 10 battery-constrained edge agents (drones/robots), each
-- carrying a small local memory vector that must be compressed for
-- radio-constrained inter-agent sync, plus one agent stuck oscillating
-- between two headings ("cognitive wobble" -- a control-loop bug, not a
-- real patrol pattern) that a fleet health monitor needs to catch from
-- its raw state stream. A battery-constrained task-routing pass closes
-- the demo: which k agents should take on high-value tasks given each
-- agent's remaining-battery cap.
--
-- Prerequisites: extension loaded (no reasoning-plugin dependency in
-- this demo).
--
-- Run:
--   sqlite3 -cmd ".load /usr/local/lib/sqlite3/fractalsql" ":memory:" \
--     ".read demo/demo-vertical-agentic-edge-swarm.sql"
--
-- Notes:
--   * There is no seedable global RNG -- the synthetic fixtures use
--     plain random() (a signed 64-bit integer here, mapped into [0,1)
--     with (random()/2^63 + 1)/2), so exact values differ run to run;
--     the fleet-level story (compression ratio, wobble detection, which
--     agents get routed) stays structurally the same.
--   * fractal_state_fingerprint is direction-based (random-hyperplane
--     SimHash over the raw state vector) -- it is magnitude-invariant,
--     so a 1-dimensional state only has two possible directions and any
--     same-signed sequence collapses to one fingerprint regardless of
--     its actual values. The heading state used for wobble detection
--     below is genuinely 2-dimensional (a real (dx, dy) heading vector)
--     specifically to avoid that degenerate case -- a 1-D "toggle
--     between two numbers" state would give a false positive on any
--     same-signed sequence, not just a real loop.
--
-- Safe to re-run: vae_* tables are dropped and recreated each time.

.timer on

.print === 0. Sanity check: extension loaded? ===
SELECT fractalsql_edition(), fractalsql_version();

-- ------------------------------------------------------------------
-- 1. 10 swarm agents: a local 16-dim memory embedding (stand-in for a
-- compact learned local-terrain/task-context feature vector), current
-- battery percentage, and a proposed task value (what completing a
-- pending task at this agent's location is worth).
-- ------------------------------------------------------------------
.print
.print === 1. 10 swarm agents: memory vector, battery, task value ===

DROP TABLE IF EXISTS vae_agents;
CREATE TABLE vae_agents (
    id          INTEGER PRIMARY KEY,
    agent_id    TEXT,
    battery_pct REAL,
    task_value  REAL,
    memory_vec  TEXT NOT NULL CHECK (fractal_vector_dims(memory_vec) = 16)
);

-- Agent-level fields first (battery/task_value need only one random()
-- draw per agent, so a plain recursive CTE is fine here).
DROP TABLE IF EXISTS vae_agent_base;
CREATE TEMP TABLE vae_agent_base AS
WITH RECURSIVE gs(g) AS (SELECT 1 UNION ALL SELECT g + 1 FROM gs WHERE g < 10)
SELECT g AS agent_num,
       'drone-' || printf('%02d', g) AS agent_id,
       20.0 + (random() / 9223372036854775808.0 + 1) / 2 * 75.0 AS battery_pct,
       (random() / 9223372036854775808.0 + 1) / 2 * 10.0 AS task_value
FROM gs;

-- The (agent, dim) grid materialized in one pass (the same
-- CROSS-JOIN-then-group_concat shape used for the covariance loadings
-- in demo-vertical-quant-finance.sql): a scalar subquery over an
-- uncorrelated dims CTE would get evaluated once and reused for every
-- agent, giving every agent the SAME memory vector -- CROSS JOIN forces
-- one random() draw per (agent, dim) pair instead.
DROP TABLE IF EXISTS vae_memory_raw;
CREATE TEMP TABLE vae_memory_raw AS
WITH RECURSIVE dims(d) AS (SELECT 1 UNION ALL SELECT d + 1 FROM dims WHERE d < 16)
SELECT a.agent_num, d.d AS dim_idx,
       (random() / 9223372036854775808.0 + 1) / 2 * 2.0 - 1.0 AS v
FROM vae_agent_base a CROSS JOIN dims d;

INSERT INTO vae_agents (agent_id, battery_pct, task_value, memory_vec)
SELECT b.agent_id, b.battery_pct, b.task_value,
       '[' || (SELECT group_concat(printf('%.4f', r.v), ',')
                 FROM vae_memory_raw r
                WHERE r.agent_num = b.agent_num
                ORDER BY r.dim_idx) || ']'
FROM vae_agent_base b
ORDER BY b.agent_num;

SELECT count(*) AS n_agents FROM vae_agents;
SELECT count(DISTINCT memory_vec) AS n_distinct_memory_vecs FROM vae_agents;

-- ------------------------------------------------------------------
-- 2. Compressed swarm memory: quantize each agent's 16-dim memory
-- vector both ways this primitive family supports -- int8 (4x
-- compression, dequantizable via codes[i]*scale) for a lossy-but-usable
-- sync payload, and binary sign-quantization (1 bit/dim, pairs with
-- Hamming distance) for a cheap approximate-similarity radio beacon.
-- Lp distance / quantization: no single originating paper -- int8 and
-- binary (1-bit sign) quantization for approximate-search
-- pre-filtering follow the general "compress, then Hamming/popcount
-- filter" pattern common in the vector-search literature.
-- ------------------------------------------------------------------
.print
.print === 2. Quantized swarm memory (int8 + binary) ===

.print --- int8 quantization: scale + codes for the first 3 agents ---
SELECT agent_id,
       json_extract(fractal_vector_quantize_int8(memory_vec), '$.scale') AS scale,
       fractal_vector_quantize_int8(memory_vec) AS quantized_int8
FROM vae_agents ORDER BY id LIMIT 3;

.print --- binary quantization + Hamming distance between two agents ---
DROP TABLE IF EXISTS vae_binary_mem;
CREATE TEMP TABLE vae_binary_mem AS
SELECT agent_id, fractal_vector_quantize_binary(memory_vec) AS bin_mem
FROM vae_agents ORDER BY id;

SELECT a.agent_id, b.agent_id,
       fractal_vector_hamming_distance(a.bin_mem, b.bin_mem) AS hamming_bits_differing
FROM vae_binary_mem a, vae_binary_mem b
WHERE a.agent_id = 'drone-01' AND b.agent_id = 'drone-02';

-- ------------------------------------------------------------------
-- 3. Cognitive-wobble loop detection: drone-05's heading over the last
-- 20 control cycles is a genuine period-2 toggle between two headings
-- (a stuck control loop, not a real patrol) -- (dx,dy) = (1,0) <->
-- (0,1) with small noise. fractal_state_fingerprint turns each 2-D
-- heading into a SimHash bit-fingerprint, then fractal_cycle_detect
-- (the single-call wrapper: feed it a JSON array of hex-encoded
-- fingerprints) streams through them via Brent's tortoise-and-hare
-- schedule.
-- Citations: SimHash -- Charikar, M. S. (2002). "Similarity estimation
-- techniques from rounding algorithms." STOC, pp. 380-388.
-- Cycle detection -- Brent, R. P. (1980). "An improved Monte Carlo
-- factorization algorithm." BIT Numerical Mathematics, 20(2), 176-184.
-- ------------------------------------------------------------------
.print
.print === 3. Cognitive-wobble detection (state-fingerprint + cycle-detect) ===

DROP TABLE IF EXISTS vae_heading_log;
CREATE TABLE vae_heading_log (
    cycle INTEGER PRIMARY KEY,
    heading TEXT
);
INSERT INTO vae_heading_log (cycle, heading)
WITH RECURSIVE gs(g) AS (SELECT 1 UNION ALL SELECT g + 1 FROM gs WHERE g < 20)
SELECT g,
       CASE WHEN g % 2 = 1
            THEN printf('%.4f,%.4f', 1.0 + (random()/9223372036854775808.0)*0.02, 0.0)
            ELSE printf('%.4f,%.4f', 0.0, 1.0 + (random()/9223372036854775808.0)*0.02)
       END
FROM gs;

DROP TABLE IF EXISTS vae_heading_fp;
CREATE TEMP TABLE vae_heading_fp AS
SELECT cycle, fractal_state_fingerprint(heading, 64, 42.0) AS fp
FROM vae_heading_log ORDER BY cycle;

.print --- raw primitives: fingerprint stream fed to cycle_detect ---
SELECT fractal_cycle_detect(
    (SELECT json_group_array(hex(fp)) FROM vae_heading_fp ORDER BY cycle),
    64) AS wobble_scan;

.print --- the shipped agent: the same composition, one call ---
-- fractal_agent_detect_loop(agent_id, state_log, dim) fingerprints each
-- state vector itself and streams the fingerprints through Brent's
-- detector internally, then adds the DFA drift check over the per-state
-- L2 norms -- the productized form of the two calls above.
SELECT fractal_agent_detect_loop(
    'drone-05',
    (SELECT '[' || group_concat(heading ORDER BY cycle) || ']'
       FROM vae_heading_log),
    2) AS wobble_scan_agent;

-- The contrast fixture (pg parity: the reference demo's "bot-explorer"):
-- a genuinely exploring agent whose trajectory must NOT be flagged. A
-- naive preset here trips three false-positive modes: unbounded random
-- walks wander in magnitude (the DFA read them as persistent), low-
-- dimensional states hash into the same SimHash cell (colliding
-- fingerprints read as a period), and random() makes the run
-- irreproducible. The explorer trajectory below sidesteps all three:
-- bounded per-dimension (no magnitude drift -> no false DFA
-- persistence), a wider 8-dim state (more directional resolution ->
-- far lower incidental collision odds), and deterministic
-- multi-frequency sinusoids with pairwise-incommensurate
-- (irrational-ratio) frequencies rather than random() -- guarantees no
-- exact periodicity within any finite window. drone-05 above, by
-- contrast, oscillates between two fixed headings -- an exact period-2
-- cycle, the textbook "cognitive wobble" trap this preset is built to
-- catch.
WITH explorer_walk(t) AS (
    SELECT 1 UNION ALL SELECT t + 1 FROM explorer_walk WHERE t < 24
)
SELECT fractal_agent_detect_loop(
    'bot-explorer',
    (SELECT group_concat(v)
       FROM (SELECT printf('%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f',
               sin(t * 1.41421356), sin(t * 1.73205081), sin(t * 2.23606798),
               sin(t * 2.64575131), sin(t * 3.31662479), sin(t * 3.60555128),
               sin(t * 3.87298335), sin(t * 4.12310563)) AS v
             FROM explorer_walk)),
    8) AS explorer_scan;

-- ------------------------------------------------------------------
-- 4. Battery-constrained task routing: fractal_optimize_subset's
-- hardcoded SQL-level objective is value-weighted allocation --
-- maximize sum(weight[i] * task_value[i]) subject to per-agent upper
-- bounds and the k-cardinality constraint. Each agent's upper bound is
-- capped by its own battery fraction, so a low-battery drone can still
-- be selected but only take on a proportionally smaller share of the
-- task -- the natural fit for "route k tasks across a fleet without
-- draining anyone past what they can afford."
-- ------------------------------------------------------------------
.print
.print === 4. Battery-constrained task routing (fractal_optimize_subset) ===

WITH agents AS (SELECT agent_id, battery_pct, task_value,
                       min(battery_pct / 100.0, 1.0) AS upper_bound
                  FROM vae_agents ORDER BY id)
SELECT fractal_optimize_subset(
    (SELECT group_concat(task_value, ',') FROM agents),
    (SELECT group_concat(upper_bound, ',') FROM agents),
    4, NULL, 0.0, 42) AS routing_plan;

.print --- routed agents: nonzero allocation weight, joined back to agent_id ---
WITH agents AS (SELECT agent_id, battery_pct, task_value,
                       min(battery_pct / 100.0, 1.0) AS upper_bound,
                       (row_number() OVER (ORDER BY id) - 1) AS item_idx
                  FROM vae_agents ORDER BY id),
     r AS (SELECT fractal_optimize_subset(
               (SELECT group_concat(task_value, ',') FROM agents),
               (SELECT group_concat(upper_bound, ',') FROM agents),
               4, NULL, 0.0, 42) AS rj)
SELECT a.agent_id, a.battery_pct, a.task_value,
       json_extract(je.value, '$') AS allocation_weight
FROM r, json_each(r.rj, '$.weights') je
JOIN agents a ON a.item_idx = je.key
WHERE json_extract(je.value, '$') > 1e-9
ORDER BY json_extract(je.value, '$') DESC;

.print
.print === Demo complete ===
.print Tables left in place for inspection. Clean up with:
.print   DROP TABLE vae_agents, vae_heading_log;
.print (the vae_* TEMP tables evaporate with the connection.)
.print ================================================================
