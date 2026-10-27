-- demo/demo-vertical-v2x-warranty-triage.sql
--
-- Industry vertical: connected-vehicle (V2X) diagnostics -- routing an
-- incoming trouble-code event to the right repair workflow and recalling
-- similar historical warranty claims.  AGENTIC kit: two installed agents
-- are chained, shown hand-composed first and then as the shipped
-- one-call agents.
--
--   1. fractal_agent_route_task -- matches the incoming telemetry event
--      to the best-capable sub-agent / repair workflow under a token
--      budget, exactly its designed contract.
--   2. fractal_agent_recall_hybrid -- fuses a strict metadata filter
--      (component) with drift-vector search to recall similar historical
--      claims; a two-predicate cohort (model year AND component) is shown
--      with fractal_hybrid_clinical_search.
--   3. A closing fractal_reason() produces the dispatch + claim-context
--      summary.
--
-- Prerequisites: extension loaded.  route_task and the closing summary
-- are reasoning-bearing (clean hint without a plugin; see
-- ../docs/reasoning-setup.md); recall_hybrid is pure retrieval and the
-- hand-composed sections need no model at all.
--
-- Run (one invocation):
--   sqlite3 -cmd ".load /usr/local/lib/sqlite3/fractalsql" ":memory:" \
--     ".read demo/demo-vertical-v2x-warranty-triage.sql"
--
-- Notes:
--   * Fully deterministic fixture (no random()).
--   * Capability and claim vectors are CSV TEXT; the DTC event embedding
--     shares the capability table's 3 dimensions.  In production the
--     embeddings come from your embedding endpoint (see
--     ../docs/vectorizer-setup.md); here they are hand-placed so the
--     routing and recall answers are readable.
--   * telemetry/hybrid doc_id IS the row's rowid.
--
-- Safe to re-run: the v2x_* tables are dropped and recreated each time.

.timer on

.print === 0. Sanity check: extension loaded? ===
SELECT fractalsql_edition(), fractalsql_version();

-- ------------------------------------------------------------------
-- 1. Repair-workflow capability table and the historical claims table.
-- ------------------------------------------------------------------
.print
.print === 1. Capability table + historical warranty claims ===

DROP TABLE IF EXISTS v2x_capabilities;
CREATE TABLE v2x_capabilities (
    id       INTEGER PRIMARY KEY,
    workflow TEXT,
    emb      TEXT NOT NULL CHECK (fractal_vector_dims(emb) = 3)
);
INSERT INTO v2x_capabilities (workflow, emb) VALUES
    ('battery-thermal-service',  '0.90,0.10,0.10'),
    ('powertrain-inverter-swap', '0.10,0.90,0.10'),
    ('adas-sensor-recalibration','0.10,0.10,0.90'),
    ('software-ota-reflash',     '0.50,0.50,0.50');

DROP TABLE IF EXISTS v2x_claims;
CREATE TABLE v2x_claims (
    id         INTEGER PRIMARY KEY,
    vin        TEXT,
    model_year INTEGER,
    component  TEXT,
    note       TEXT,
    drift_vec  TEXT NOT NULL CHECK (fractal_vector_dims(drift_vec) = 4)
);
INSERT INTO v2x_claims (vin, model_year, component, note, drift_vec) VALUES
    ('VIN-A01', 2023, 'battery-pack', 'coolant pump intermittent, pack temp spike on fast charge', '0.80,0.60,0.10,0.10'),
    ('VIN-A02', 2023, 'battery-pack', 'cell imbalance after winter, SoH below threshold',          '0.70,0.20,0.60,0.10'),
    ('VIN-A03', 2024, 'battery-pack', 'pack temp spike on fast charge, coolant valve stuck',       '0.82,0.58,0.12,0.08'),
    ('VIN-A04', 2024, 'battery-pack', 'contactor chatter at low state of charge',                  '0.20,0.10,0.90,0.30'),
    ('VIN-B01', 2023, 'inverter',     'inverter overtemp derate under tow load',                   '0.55,0.85,0.10,0.20'),
    ('VIN-B02', 2024, 'inverter',     'phase current ripple, NVH complaint',                       '0.15,0.30,0.20,0.90'),
    ('VIN-C01', 2023, 'adas-sensor',  'forward radar misalignment after windshield replacement',   '0.10,0.20,0.30,0.70'),
    ('VIN-C02', 2024, 'adas-sensor',  'camera calibration drift, lane-keep disengages',            '0.12,0.18,0.28,0.75');

SELECT component, count(*) AS claims FROM v2x_claims GROUP BY component ORDER BY component;

-- ------------------------------------------------------------------
-- 2. Step 1, hand-composed: route the incoming event.  The DTC event is
-- a battery thermal fault -- its embedding sits nearest the battery-
-- thermal workflow.  confidence = 1/(1+distance).
-- ------------------------------------------------------------------
.print
.print === 2. Step 1 (hand-composed): route the incoming DTC event ===

WITH t AS (SELECT json_extract(value, '$.doc_id')   AS doc_id,
                  json_extract(value, '$.distance') AS dist
             FROM json_each(fractal_search_telemetry(
                      'v2x_capabilities', 'emb', '0.85,0.15,0.12', 1))
            LIMIT 1)
SELECT c.workflow                      AS routed_to,
       round(1.0 / (1.0 + t.dist), 4) AS confidence,
       1000 - 150                      AS remaining_budget   -- budget less one routing decision
FROM t JOIN v2x_capabilities c ON c.rowid = t.doc_id;

.print --- the shipped agent: same composition, one call (reasoning plugin) ---
SELECT fractal_agent_route_task(
    '0.85,0.15,0.12', 'v2x_capabilities', 'emb', 'workflow', 1000) AS routing;

-- ------------------------------------------------------------------
-- 3. Step 2, hand-composed: two-predicate cohort (model year 2024 AND
-- battery pack), then a vector search restricted to it -- the cohort a
-- single (filter_col, filter_val) pair cannot express.
-- ------------------------------------------------------------------
.print
.print === 3. Step 2 (hand-composed): similar 2024 battery-pack claims ===

WITH hs AS (SELECT fractal_hybrid_clinical_search(
                    'v2x_claims', 'drift_vec', '0.80,0.60,0.10,0.10',
                    (SELECT group_concat(id) FROM v2x_claims
                      WHERE model_year = 2024 AND component = 'battery-pack'), 3) AS rj)
SELECT c.vin, c.model_year, c.note,
       round(json_extract(je.value, '$.distance'), 4) AS distance
FROM hs, json_each(hs.rj) je
JOIN v2x_claims c ON c.rowid = json_extract(je.value, '$.doc_id')
ORDER BY json_extract(je.value, '$.distance');

-- ------------------------------------------------------------------
-- 4. Step 2, productized: fractal_agent_recall_hybrid with a strict
-- metadata filter (component = 'battery-pack'); pure retrieval, no
-- model.  mem_id / content are the real claim id and note.
-- ------------------------------------------------------------------
.print
.print === 4. Step 2 (shipped agent): fractal_agent_recall_hybrid ===

SELECT fractal_agent_recall_hybrid(
    'v2x_claims', 'drift_vec', '0.80,0.60,0.10,0.10',
    'component', 'battery-pack', 3, 'id', 'note') AS similar_claims;

-- ------------------------------------------------------------------
-- 5. Reasoning: the dispatch + claim-context summary (plugin-gated; the
-- clean hint is the expected output without one).
-- ------------------------------------------------------------------
.print
.print === 5. Reasoning: dispatch + claim-context summary ===

SELECT fractal_reason(
    'one-line dispatch recommendation plus warranty context for this connected-vehicle fault',
    json_object(
      'routing', json((SELECT fractal_agent_route_task(
            '0.85,0.15,0.12', 'v2x_capabilities', 'emb', 'workflow', 1000))),
      'similar_claims', json((SELECT fractal_agent_recall_hybrid(
            'v2x_claims', 'drift_vec', '0.80,0.60,0.10,0.10',
            'component', 'battery-pack', 3, 'id', 'note')))));

.print
.print === Demo complete ===
.print Tables left in place for inspection. Clean up with:
.print   DROP TABLE v2x_capabilities; DROP TABLE v2x_claims;
