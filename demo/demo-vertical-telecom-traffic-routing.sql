-- demo/demo-vertical-telecom-traffic-routing.sql
--
-- Industry vertical: telecom -- dynamic traffic and bandwidth dispatch to
-- the best-capable network node under a capacity budget.  DOMAIN kit
-- built on one installed agent, fractal_agent_route_task, reused
-- verbatim: it matches each incoming request to the best-capable node
-- under a token budget, exactly its designed contract.
--
-- Scope note: this is nearest-capable-node dispatch, not multi-hop
-- rerouting around a failed node (graph routing is a different problem).
-- Load awareness comes from routing over a table of only the nodes that
-- still have headroom.
--
-- Prerequisites: extension loaded.  The hand-composed routing needs no
-- model; the shipped agent returns a reasoned rationale (clean hint
-- without a plugin; see ../docs/reasoning-setup.md).
--
-- Run (one invocation):
--   sqlite3 -cmd ".load /usr/local/lib/sqlite3/fractalsql" ":memory:" \
--     ".read demo/demo-vertical-telecom-traffic-routing.sql"
--
-- Notes:
--   * Fully deterministic fixture (no random()).
--   * Vectors are [bandwidth, latency_sensitivity, loss_tolerance,
--     region_affinity] in CSV TEXT.  A request vector says what the
--     session needs; a node vector says what the node is good at.
--   * telemetry doc_id IS the row's rowid.  The agent reads a table, so
--     the available-nodes set is materialized into a TEMP table each time
--     it changes.
--
-- Safe to re-run: the ttr_* tables are dropped and recreated each time.

.timer on

.print === 0. Sanity check: extension loaded? ===
SELECT fractalsql_edition(), fractalsql_version();

-- ------------------------------------------------------------------
-- 1. Network nodes (capability vector + current load) and five
-- incoming session requests.
-- ------------------------------------------------------------------
.print
.print === 1. Nodes and incoming requests ===

DROP TABLE IF EXISTS ttr_nodes;
CREATE TABLE ttr_nodes (
    id       INTEGER PRIMARY KEY,
    node     TEXT,
    capacity INTEGER,        -- sessions
    load     INTEGER,        -- sessions now
    caps     TEXT NOT NULL CHECK (fractal_vector_dims(caps) = 4)
);
INSERT INTO ttr_nodes (node, capacity, load, caps) VALUES
    ('edge-core-east',   400, 120, '0.95,0.20,0.10,0.90'),   -- bulk bandwidth, east region
    ('edge-lowlat-west', 150,  60, '0.30,0.95,0.15,0.10'),   -- low latency, west region
    ('edge-mobile-hub',  250, 200, '0.50,0.50,0.85,0.50'),   -- loss-tolerant mobile traffic
    ('edge-backup-west', 200,  20, '0.55,0.55,0.40,0.15');   -- general purpose, west

DROP TABLE IF EXISTS ttr_requests;
CREATE TABLE ttr_requests (
    id    INTEGER PRIMARY KEY,
    label TEXT,
    need  TEXT NOT NULL CHECK (fractal_vector_dims(need) = 4)
);
INSERT INTO ttr_requests (label, need) VALUES
    ('R1 bulk video backhaul, east',     '0.90,0.15,0.10,0.85'),
    ('R2 cloud-gaming session, west',    '0.35,0.92,0.12,0.12'),
    ('R3 mobile handover burst',         '0.45,0.50,0.88,0.45'),
    ('R4 enterprise VPN, west',          '0.50,0.60,0.30,0.12'),
    ('R5 software update fan-out, east', '0.92,0.10,0.20,0.88');

SELECT node, capacity, load, round(100.0 * load / capacity) AS pct_loaded FROM ttr_nodes;

-- ------------------------------------------------------------------
-- 2. Hand-composed dispatch: nearest node by capability, per request.
-- confidence = 1/(1+distance).
-- ------------------------------------------------------------------
.print
.print === 2. Hand-composed dispatch: nearest capable node per request ===

SELECT r.label,
       (SELECT n.node FROM ttr_nodes n
         WHERE n.rowid = json_extract(je.value, '$.doc_id')) AS routed_to,
       round(1.0 / (1.0 + json_extract(je.value, '$.distance')), 4) AS confidence
FROM ttr_requests r,
     json_each(fractal_search_telemetry('ttr_nodes', 'caps', r.need, 1)) je
ORDER BY r.id;

-- ------------------------------------------------------------------
-- 3. The shipped agent, one call per request, under a 1000-token budget
-- (reasoning plugin for the rationale).  remaining_budget shows each
-- routing decision's cost.
-- ------------------------------------------------------------------
.print
.print === 3. fractal_agent_route_task (budget 1000) ===

SELECT r.label,
       fractal_agent_route_task(r.need, 'ttr_nodes', 'caps', 'node', 1000) AS routing
FROM ttr_requests r ORDER BY r.id;

-- ------------------------------------------------------------------
-- 4. Load awareness: edge-mobile-hub is at 80% load.  Route over only
-- the nodes with headroom (below 75% loaded) and R3 is re-homed.
-- ------------------------------------------------------------------
.print
.print === 4. Route over nodes with headroom (< 75% loaded) ===

DROP TABLE IF EXISTS ttr_available;
CREATE TEMP TABLE ttr_available AS
SELECT node, caps FROM ttr_nodes WHERE 100.0 * load / capacity < 75 ORDER BY id;

SELECT r.label,
       json_extract(fractal_agent_route_task(
           r.need, 'ttr_available', 'caps', 'node', 1000), '$.routed_to') AS routed_to
FROM ttr_requests r ORDER BY r.id;

-- ------------------------------------------------------------------
-- 5. Reasoning: the dispatch summary (plugin-gated; the clean hint is
-- the expected output without one).
-- ------------------------------------------------------------------
.print
.print === 5. Reasoning: dispatch summary ===

SELECT fractal_reason(
    'one-line summary of how these session requests were dispatched and why one was re-homed',
    (SELECT group_concat(r.label || ' -> ' ||
              json_extract(fractal_agent_route_task(r.need, 'ttr_available', 'caps', 'node', 1000),
                           '$.routed_to'), '; ')
       FROM ttr_requests r));

.print
.print === Demo complete ===
.print Tables left in place for inspection. Clean up with:
.print   DROP TABLE ttr_nodes; DROP TABLE ttr_requests;
.print (the ttr_available TEMP table evaporates with the connection.)
