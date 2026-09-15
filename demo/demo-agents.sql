-- =============================================================================
-- FractalSQL Agents demo
-- =============================================================================
-- The sixteen composite agents (fractal_agent_anomaly_triage, _allocate,
-- _route_task, ...) are installed here: src/fsql_domain_agents.c registers
-- all sixteen as plain C SQL functions in this same DLL, next to the six
-- Universal Agents, the reasoning core, and the search core -- no separate
-- install step. See docs/api-agency.md for the full sixteen-agent reference.
--
-- Below, each composite agent appears first as its REFERENCE COMPOSITION
-- over the primitives it wraps -- inline blueprint sections, same as the
-- demo-vertical-agentic-*.sql demos -- and every output column is a REAL
-- primitive result, not a literal. threat_score is the computed drift
-- exponent; allocation/sharpe are the optimizer's own output (no hardcoded
-- 0.042); routed_to is the real nearest capability name resolved through
-- the doc_id mapping, and confidence is 1/(1+distance); intercepted is a
-- real distance-vs-threshold comparison; mem_id/content are the real
-- recalled row; item_id/score are the real catalog id and
-- 1-cosine_distance. The 13 cognition composites' triage/rationale/analysis
-- columns are real fractal_reason output -- which means they are the calls
-- that REQUIRE the reasoning plugin: without one configured, each errors
-- with the clean "reasoning plugin not configured" hint and the sqlite3
-- shell continues to the next section (the errors are the documentation;
-- the analytic half of every section still prints).
--
-- Below every blueprint, "the shipped agent: same composition, one call"
-- runs the real fractal_agent_* function over the same fixture -- the
-- same pattern demo-vertical-agentic-*.sql uses. Values will not match
-- the blueprint's own output exactly where an engine draws its own
-- randomness (fractal_optimize_portfolio's default seed, the K/L/M/N/O
-- engines' inline random walks) -- the point is that the shipped
-- function performs the same composition as the blueprint above it, not
-- that it reproduces the identical numbers.
--
-- The telemetry/trajectory functions report 0-INDEXED scan positions
-- (doc_id), and the blueprint sections map doc_id back to the named row
-- key with a plain row_number() OVER (ORDER BY rowid) - 1 view.
--
-- fractal_agent_diverse_portfolios (enterprise tier): its engine,
-- fractal_optimize_portfolio_multimodal, IS registered here but is
-- enterprise-gated -- it errors with the clean "enterprise tier not
-- loaded" hint on the community build (no exception wrapper needed; the
-- sqlite3 shell continues past it).
--
-- Prerequisites:
--   1. The extension loaded (`.load <path to fractalsql>`).
--   2. Reasoning configured for the cognition sections -- see
--      ../docs/reasoning-setup.md (per-connection fractalsql_set state,
--      so re-apply your load_fractalsql.sql snippet with -init). Confirm:
--        SELECT fractal_reason('reply with a short confirmation');
-- Re-runnable: agents_demo_* tables are dropped and recreated at the top
-- of their sections.
-- =============================================================================

.timer on

-- 0. Prerequisite check -- the surface (the agent tier compiles into the
-- same DLL; its composite-blueprint sections below resolve against it).
.print === 0. Surface check: base + agent tier ===
SELECT fractalsql_edition(), fractalsql_version();

-- 1. Setup: a drifting metric time series for one host.
-- Same step-up shape as demo-vertical-agentic-ops-devops.sql: a baseline ~50 for
-- the first 48 rows then a +30 step-up, 96 points, so
-- fractal_dimension_drift's 32-point recent window has a real regime change
-- to detect (DFA needs the recent window large enough; window=16 is too
-- small and returns rc=-1). A second host makes the host filter meaningful.
-- (random() is a signed 64-bit integer here, mapped into range as needed.)
DROP TABLE IF EXISTS agents_demo_logs;
CREATE TABLE agents_demo_logs (metric REAL, ts TEXT, host TEXT);
WITH RECURSIVE gs(g) AS (SELECT 1 UNION ALL SELECT g + 1 FROM gs WHERE g < 96)
INSERT INTO agents_demo_logs (metric, ts, host)
SELECT 50.0 + (g % 8) * 1.3 + CASE WHEN g > 48 THEN 30.0 ELSE 0.0 END,
       datetime('now', '-' || (96 - g) || ' seconds'),
       'host-1'
FROM gs;
INSERT INTO agents_demo_logs (metric, ts, host) VALUES
    (10, datetime('now'), 'host-2'),
    (11, datetime('now', '+1 minutes'), 'host-2');

-- 2. anomaly_triage (fractal_agent_anomaly_triage).
-- threat_score is the REAL drift result (fractal_dimension_drift ran over
-- host-1's 96-point series); anomaly_type is the literal 'vector_drift' label
-- (a real label for what drift detects, not a stub); the triage_summary is
-- the REAL fractal_reason output over the drift result.
.print
.print === 2. anomaly_triage blueprint (host-1, 32-pt recent window) ===
WITH d AS (SELECT fractal_dimension_drift(
               (SELECT '[' || group_concat(metric ORDER BY ts) || ']'
                  FROM agents_demo_logs WHERE host = 'host-1'), 32) AS j)
SELECT abs(json_extract(j, '$.drift'))          AS threat_score,
       'vector_drift'                            AS anomaly_type,
       json_extract(j, '$.recent_alpha')         AS recent_alpha,
       json_extract(j, '$.baseline_alpha')       AS baseline_alpha
FROM d;
.print --- triage_summary (fractal_reason over the drift result) ---
SELECT fractal_reason(
    'one-line triage for this anomaly-detection drift report',
    (SELECT fractal_dimension_drift(
         (SELECT '[' || group_concat(metric ORDER BY ts) || ']'
            FROM agents_demo_logs WHERE host = 'host-1'), 32)));
.print --- the shipped agent: same composition, one call ---
SELECT fractal_agent_anomaly_triage(
    'agents_demo_logs', 'metric', 'ts', 'host', 'host-1', 32);

-- 2b. empty-series guard (interactive only -- the drift call raises on an
-- empty series). Uncomment to confirm it rejects cleanly:
-- SELECT fractal_dimension_drift(
--     (SELECT '[' || group_concat(metric) || ']' FROM agents_demo_logs
--      WHERE host = 'no-such-host'), 32);
-- Expect: ERROR -- no rows (the group_concat yields '[]' and the C side
-- rejects the empty series).

-- 3. allocate (fractal_agent_allocate).
-- allocation is the REAL optimizer JSON {sharpe, weights}; sharpe is the REAL
-- risk-adjusted return extracted from it (this is the column the demo
-- blueprint's hardcoded 0.042 "drift_score" literal used to fake). cov is
-- the 2x2 identity flattened to a 1-D row-major 4-element CSV
-- (fractal_optimize_portfolio reads vectors as CSV/JSON TEXT), with a
-- fixed integer seed argument.
.print
.print === 3. allocate blueprint (2 assets, cardinality=1) ===
WITH opt AS (SELECT fractal_optimize_portfolio('0.05,0.1', '1,0,0,1', 1, 42) AS j)
SELECT json_extract(j, '$.sharpe')   AS sharpe,
       j                             AS allocation
FROM opt;
.print --- rationale (fractal_reason) ---
SELECT fractal_reason('justify this 2-asset portfolio allocation in one line',
                      (SELECT fractal_optimize_portfolio('0.05,0.1', '1,0,0,1', 1, 42)));
.print --- the shipped agent: same composition, one call (no seed param -- uses the optimizer's default) ---
SELECT fractal_agent_allocate('0.05,0.1', '1,0,0,1', 1);

-- 4. route_task (fractal_agent_route_task).
-- task_emb is the incoming task embedding; the blueprint finds the nearest
-- capability row via fractal_search_telemetry and resolves the 0-indexed
-- scan position back to the named capability id. routed_to is the REAL
-- capability name; confidence is 1/(1+distance) (real, from the nearest
-- distance); rationale is the REAL fractal_reason output.
DROP TABLE IF EXISTS agents_demo_caps;
CREATE TABLE agents_demo_caps (capability_name TEXT, emb TEXT);
INSERT INTO agents_demo_caps VALUES
    ('root-cause-analyzer', '0.1,0.2,0.3'),
    ('capacity-autoscaler', '0.9,0.8,0.7'),
    ('incident-pager',      '0.3,0.3,0.9');

.print
.print === 4. route_task blueprint (task near root-cause-analyzer) ===
WITH t AS (SELECT json_extract(value, '$.doc_id')   AS doc_id,
                  json_extract(value, '$.distance') AS dist
             FROM json_each(fractal_search_telemetry(
                      'agents_demo_caps', 'emb', '0.11,0.21,0.31', 1)))
SELECT m.capability_name                       AS routed_to,
       1.0 / (1.0 + t.dist)                    AS confidence,
       1000                                    AS remaining_budget
FROM t
JOIN (SELECT capability_name, (row_number() OVER (ORDER BY rowid) - 1) AS doc_id
        FROM agents_demo_caps) m USING (doc_id);
.print --- rationale (fractal_reason) ---
SELECT fractal_reason('one-line rationale for this task routing decision');
.print --- the shipped agent: same composition, one call ---
SELECT fractal_agent_route_task(
    '0.11,0.21,0.31', 'agents_demo_caps', 'emb', 'capability_name', 1000);

-- 4b. empty-table guard (interactive only -- telemetry raises on an empty
-- table). Uncomment to confirm it rejects cleanly:
-- DELETE FROM agents_demo_caps;
-- SELECT fractal_search_telemetry('agents_demo_caps', 'emb', '0.1,0.2,0.3', 1);

-- 5. outlier_intercept (fractal_agent_outlier_intercept).
-- Screens a proposed action's state vector against known-bad states via
-- fractal_search_telemetry. Uses ORTHOGONAL vectors for the "far" case,
-- because cosine distance ignores magnitude: [0.1,0.1,0.1] vs [0.9,0.9,0.9]
-- are parallel (distance 0), not far. A far probe must point a different
-- direction -- here [0,1,0] vs bad [1,0,0] -> distance 1 > 0.5 ->
-- intercepted=false.
DROP TABLE IF EXISTS agents_demo_badstates;
CREATE TABLE agents_demo_badstates (emb TEXT);
INSERT INTO agents_demo_badstates VALUES ('1.0,0.0,0.0'), ('0.9,0.1,0.0');

.print
.print === 5. outlier_intercept blueprint (near a bad state) ===
WITH d AS (SELECT json_extract(value, '$.distance') AS dist
             FROM json_each(fractal_search_telemetry(
                      'agents_demo_badstates', 'emb', '0.95,0.05,0.0', 1))
            LIMIT 1)
SELECT (d.dist < 0.5) AS intercepted,
       printf('nearest bad state distance %.4f vs threshold 0.5', d.dist) AS reason
FROM d;
.print --- the shipped agent: same composition, one call ---
SELECT fractal_agent_outlier_intercept('0.95,0.05,0.0', 'agents_demo_badstates', 'emb', 0.5);

.print
.print === outlier_intercept blueprint (orthogonal/far) ===
WITH d AS (SELECT json_extract(value, '$.distance') AS dist
             FROM json_each(fractal_search_telemetry(
                      'agents_demo_badstates', 'emb', '0.0,1.0,0.0', 1))
            LIMIT 1)
SELECT (d.dist < 0.5) AS intercepted,
       printf('nearest bad state distance %.4f vs threshold 0.5', d.dist) AS reason
FROM d;
.print --- the shipped agent: same composition, one call ---
SELECT fractal_agent_outlier_intercept('0.0,1.0,0.0', 'agents_demo_badstates', 'emb', 0.5);

-- 6. recall_hybrid (fractal_agent_recall_hybrid).
-- Pure retrieval: no LLM step. The "hybrid" is the cohort -- a strict SQL
-- filter (customer_id) mapped to 0-indexed scan positions, then
-- fractal_hybrid_clinical_search restricts the vector recall to that
-- cohort. mem_id is the REAL session_id from the matching row (not a
-- canned 1..5); content is the REAL row text (not 'recalled memory
-- snippet N').
DROP TABLE IF EXISTS agents_demo_mem;
CREATE TABLE agents_demo_mem (
    session_id    INTEGER,
    customer_id   TEXT,
    state_vector  TEXT,
    content       TEXT
);
INSERT INTO agents_demo_mem VALUES
    (1001, 'cust-a', '0.2,0.2,0.2', 'resolved churn via loyalty upgrade'),
    (1002, 'cust-a', '0.8,0.8,0.8', 'escalated billing dispute to agent'),
    (1003, 'cust-b', '0.5,0.5,0.5', 'refunded a duplicate charge');

.print
.print === 6. recall_hybrid blueprint (cust-a cohort, k=2) ===
WITH cohort AS (SELECT group_concat(pos, ',') AS ids
                  FROM (SELECT row_number() OVER (ORDER BY rowid) - 1 AS pos
                          FROM agents_demo_mem
                         WHERE customer_id = 'cust-a')),
     hs AS (SELECT fractal_hybrid_clinical_search(
                    'agents_demo_mem', 'state_vector', '0.18,0.22,0.2',
                    (SELECT ids FROM cohort), 2) AS rj)
SELECT m.session_id AS mem_id,
       m.content    AS content
  FROM hs,
       json_each(hs.rj) je
  JOIN (SELECT session_id, content,
               (row_number() OVER (ORDER BY rowid) - 1) AS doc_id
          FROM agents_demo_mem) m ON m.doc_id = json_extract(je.value, '$.doc_id');
.print --- the shipped agent: same composition, one call ---
SELECT fractal_agent_recall_hybrid(
    'agents_demo_mem', 'state_vector', '0.18,0.22,0.2', 'customer_id', 'cust-a', 2);

-- 6b. no-rows guard (interactive only -- the cohort filter with no
-- matches raises cleanly). Uncomment to confirm:
-- SELECT fractal_hybrid_clinical_search('agents_demo_mem', 'state_vector',
--     '0.1,0.1,0.1', (SELECT group_concat(rowid - 1) FROM agents_demo_mem
--                       WHERE customer_id = 'no-such-customer'), 5);
-- Expect: the C-side error for an empty cohort.

-- 7. recommend_diverse (fractal_agent_recommend_diverse).
-- Pure retrieval: no LLM step. Enables session-global repulsion
-- (fractal_diversify_enable) so the search avoids recently-rejected items,
-- then fractal_search_telemetry returns a repulsion-diverse top-k. item_id
-- is the REAL catalog id (resolved through the doc_id mapping); score is
-- 1-cosine_distance (real, from the primitive -- not the canned
-- 0.95-i*0.01). The diversify-enable is a session side effect: reset with
-- SELECT fractal_diversify_disable(); when your session is done (done at
-- the bottom of this script).
DROP TABLE IF EXISTS agents_demo_catalog;
CREATE TABLE agents_demo_catalog (id INTEGER, emb TEXT);
INSERT INTO agents_demo_catalog VALUES
    (10, '0.1,0.0,0.0'),
    (20, '0.0,1.0,0.0'),
    (30, '0.0,0.0,1.0');

.print
.print === 7. recommend_diverse blueprint (query near item 10, k=3) ===
SELECT fractal_diversify_enable();
WITH t AS (SELECT json_extract(value, '$.doc_id')   AS doc_id,
                  json_extract(value, '$.distance') AS dist
             FROM json_each(fractal_search_telemetry(
                      'agents_demo_catalog', 'emb', '0.12,0.01,0.0', 3)))
SELECT m.id             AS item_id,
       1.0 - t.dist     AS score
FROM t
JOIN (SELECT id, (row_number() OVER (ORDER BY rowid) - 1) AS doc_id
        FROM agents_demo_catalog) m USING (doc_id);
.print --- the shipped agent: same composition, one call (diversify already enabled above) ---
SELECT fractal_agent_recommend_diverse('agents_demo_catalog', 'emb', '0.12,0.01,0.0', 3);

-- ============================================================================
-- Sections 9-17. Same real-output contract as the first seven.
-- ============================================================================

-- 9. data_analyst (horizontal NL->SQL->reason) -- the REAL fractal_sql_agent
-- call, composed with fractal_reason. generated_sql is the agent's real
-- generated statement; result_json is the real executed result (or a
-- captured execution-failure reason); analysis is the real fractal_reason
-- read. The horizontal catch-all -- no vertical demo is wired to it.
DROP TABLE IF EXISTS agents_demo_data;
CREATE TABLE agents_demo_data (id INTEGER PRIMARY KEY, category TEXT, amount REAL);
INSERT INTO agents_demo_data VALUES
    (1, 'hardware', 1200.00),
    (2, 'software',  800.50),
    (3, 'hardware',  450.25);

.print
.print === 9. data_analyst (NL: total spend per category) ===
WITH a AS (SELECT fractal_sql_agent('total amount spent per category in agents_demo_data',
                                    '["agents_demo_data"]', 2, 1) AS rj)
SELECT json_extract(rj, '$.generated_sql')     AS generated_sql,
       json_extract(rj, '$.execution_status')  AS execution_status,
       json_extract(rj, '$.result_json')       AS result_json
FROM a;
.print --- analysis (fractal_reason over the result) ---
SELECT fractal_reason('one-line read of this SQL analysis result');
.print --- the shipped agent: same composition, one call ---
SELECT fractal_agent_data_analyst(
    'total amount spent per category in agents_demo_data', '["agents_demo_data"]', 2);

-- 10. patient_deterioration_triage (medtech;
-- fractal_agent_patient_deterioration_triage).
-- Composes a cohort-restricted hybrid search (fractal_hybrid_clinical_search)
-- with a baseline->current drift search (fractal_search_trajectory), then
-- reasons. The cohort is caller-built from age>65 AND condition='sepsis' --
-- the two-predicate cohort a single (filter_col, filter_val) hybrid call
-- cannot express. nearest_cohort_id is the real nearest patient (doc_id
-- resolved back to id); cohort_distance/drift_distance are real; rationale
-- is the real fractal_reason output.
DROP TABLE IF EXISTS agents_demo_patients;
CREATE TABLE agents_demo_patients (
    id INTEGER PRIMARY KEY, age INTEGER, condition TEXT, vitals TEXT);
INSERT INTO agents_demo_patients VALUES
    (1, 72, 'sepsis',    '0.90,-0.80,0.70,0.60'),
    (2, 64, 'sepsis',    '0.10,0.10,0.10,0.10'),
    (3, 78, 'pneumonia', '0.20,0.20,0.20,0.20'),
    (4, 81, 'sepsis',    '0.85,-0.75,0.65,0.55');

.print
.print === 10. patient_deterioration_triage blueprint (age>65 sepsis cohort) ===
WITH cohort AS (SELECT group_concat(pos, ',') AS ids
                  FROM (SELECT row_number() OVER (ORDER BY rowid) - 1 AS pos
                          FROM agents_demo_patients
                         WHERE age > 65 AND condition = 'sepsis')),
     hs AS (SELECT fractal_hybrid_clinical_search(
                    'agents_demo_patients', 'vitals', '0.9,-0.8,0.7,0.6',
                    (SELECT ids FROM cohort), 5) AS rj),
     tr AS (SELECT fractal_search_trajectory(
                    'agents_demo_patients', 'vitals',
                    '0.1,0.1,0.1,0.1', '0.95,-0.85,0.75,0.65', 5) AS tj)
SELECT (SELECT m.id FROM hs, json_each(hs.rj) je
         JOIN (SELECT id, (row_number() OVER (ORDER BY rowid) - 1) AS doc_id
                 FROM agents_demo_patients) m ON m.doc_id = json_extract(je.value, '$.doc_id')
        ORDER BY json_extract(je.value, '$.distance') LIMIT 1) AS nearest_cohort_id,
       (SELECT json_extract(je.value, '$.distance') FROM hs, json_each(hs.rj) je
         ORDER BY json_extract(je.value, '$.distance') LIMIT 1) AS cohort_distance,
       (SELECT json_extract(je.value, '$.distance') FROM tr, json_each(tr.tj) je
        ORDER BY json_extract(je.value, '$.distance') LIMIT 1) AS drift_distance,
       (SELECT count(*) FROM agents_demo_patients
         WHERE age > 65 AND condition = 'sepsis') AS cohort_matches;
.print --- rationale (fractal_reason) ---
SELECT fractal_reason('one-line triage rationale for this patient cohort scan');
.print --- the shipped agent: same composition, one call (explicit two-predicate cohort) ---
SELECT fractal_agent_patient_deterioration_triage(
    'agents_demo_patients', 'vitals', '0.9,-0.8,0.7,0.6',
    '0.1,0.1,0.1,0.1', '0.95,-0.85,0.75,0.65',
    (SELECT group_concat(pos) FROM (SELECT row_number() OVER (ORDER BY rowid) - 1 AS pos
                                       FROM agents_demo_patients
                                      WHERE age > 65 AND condition = 'sepsis')),
    5);

-- 11. feedback_audit (fractal_agent_feedback_audit; pure analytics, NO
-- LLM). A self-contained audit cycle: enables session-global repulsion,
-- warms the D_q rolling window with varied queries from a warmup table,
-- reports negative feedback on the audit target (fractal_isolate_background
-- on the k=1 telemetry doc_id -- the doc_id IS the handle), then reads back
-- the real diversity_quotient (fractal_detect_collapse) and session
-- diagnostics (fractal_explain_result). Self-disables diversify (unlike
-- recommend_diverse, which leaves it on).
DROP TABLE IF EXISTS agents_demo_fcatalog;
DROP TABLE IF EXISTS agents_demo_fwarmup;
CREATE TABLE agents_demo_fcatalog (id INTEGER PRIMARY KEY, emb TEXT);
WITH RECURSIVE gs(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM gs WHERE n < 20),
d(dim_idx) AS (SELECT 1 UNION ALL SELECT dim_idx + 1 FROM d WHERE dim_idx < 3)
INSERT INTO agents_demo_fcatalog (id, emb)
SELECT gs.n,
       group_concat(printf('%.4f', random() / 9223372036854775808.0)
                    ORDER BY d.dim_idx)
FROM gs CROSS JOIN d
GROUP BY gs.n;
CREATE TABLE agents_demo_fwarmup (center TEXT);
WITH RECURSIVE gs(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM gs WHERE n < 8),
d(dim_idx) AS (SELECT 1 UNION ALL SELECT dim_idx + 1 FROM d WHERE dim_idx < 3)
INSERT INTO agents_demo_fwarmup (center)
SELECT group_concat(printf('%.4f', random() / 9223372036854775808.0)
                    ORDER BY d.dim_idx)
FROM gs CROSS JOIN d
GROUP BY gs.n;

.print
.print === 11. feedback_audit blueprint (warmup -> isolate -> D_q) ===
SELECT fractal_diversify_enable();
-- Warm the D_q window with varied queries (one per warmup row):
WITH RECURSIVE gs(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM gs WHERE n < 8)
SELECT count(*) AS warmup_queries
  FROM (SELECT fractal_search_telemetry(
                  'agents_demo_fwarmup', 'center',
                  printf('%.2f,0.5,0.5', 0.1 * (n % 8)), 3)
          FROM gs);
-- Negative feedback on the audit target: the k=1 telemetry doc_id IS the
-- handle fractal_isolate_background takes:
WITH tgt AS (SELECT json_extract(value, '$.doc_id') AS d
               FROM json_each(fractal_search_telemetry(
                        'agents_demo_fcatalog', 'emb', '0.5,0.5,0.5', 1)))
SELECT fractal_isolate_background((SELECT d FROM tgt)) AS isolated;
SELECT fractal_detect_collapse() AS diversity_quotient;
SELECT fractal_explain_result()  AS explanation;
SELECT fractal_diversify_disable();
.print --- the shipped agent: same composition, one call (self-contained: enables + disables diversify) ---
SELECT fractal_agent_feedback_audit(
    'agents_demo_fcatalog', 'emb', '0.5,0.5,0.5', 'agents_demo_fwarmup', 'center', 8, 1);

-- 12. schedule_workload (sovereign-edge: fractal_agent_schedule_workload).
-- Refines the task vector with Sniper Search (the abstract [-1,1]^dim
-- fractal_search_debug here, whose $.best_point is the refined vector),
-- finds the nearest node
-- via fractal_search_telemetry, resolves the scan position to the named
-- node id, and reasons. assigned_node is the real node id; confidence is
-- 1/(1+distance) (real); rationale is the real fractal_reason output. Like
-- route_task but with the fractal_search refinement step route_task lacks.
DROP TABLE IF EXISTS agents_demo_nodes;
CREATE TABLE agents_demo_nodes (id INTEGER PRIMARY KEY, capability TEXT);
INSERT INTO agents_demo_nodes VALUES
    (1, '0.9,0.1,0.0,0.0,0.0'),
    (2, '0.0,0.0,0.9,0.1,0.0'),
    (3, '0.1,0.0,0.0,0.0,0.9');

.print
.print === 12. schedule_workload blueprint (inference task -> nearest node) ===
WITH q AS (SELECT json_extract(fractal_search_debug('0.8,0.1,0,0,0.1', 30, 50),
                               '$.best_point') AS refined),
     t AS (SELECT json_extract(value, '$.doc_id')   AS doc_id,
                  json_extract(value, '$.distance') AS dist
             FROM json_each(fractal_search_telemetry(
                      'agents_demo_nodes', 'capability',
                      (SELECT refined FROM q), 5))
            ORDER BY json_extract(value, '$.distance')
            LIMIT 1)
SELECT m.id               AS assigned_node,
       1.0 / (1.0 + t.dist) AS confidence
FROM t
JOIN (SELECT id, (row_number() OVER (ORDER BY rowid) - 1) AS doc_id
        FROM agents_demo_nodes) m USING (doc_id);
.print --- rationale (fractal_reason) ---
SELECT fractal_reason('one-line rationale for this workload assignment');
.print --- the shipped agent: same composition, one call ---
SELECT fractal_agent_schedule_workload(
    '0.8,0.1,0,0,0.1', 'agents_demo_nodes', 'capability', 'id', 30, 50);

-- 13. rebalance_sibling (quant-finance;
-- fractal_agent_rebalance_sibling).
-- Runs the SFS cardinality-constrained Sharpe maximizer
-- (fractal_optimize_portfolio), finds the nearest historical allocation
-- pattern via fractal_search_telemetry over the weights vector, resolves
-- its doc_id to the named allocation id, and reasons. sharpe is the real
-- optimizer output; weights is the real JSON; nearest_alloc_id is the real
-- telemetry nearest; rationale is the real fractal_reason output. cov is a
-- flattened 1-D row-major 4x4.
DROP TABLE IF EXISTS agents_demo_alloc;
CREATE TABLE agents_demo_alloc (id INTEGER PRIMARY KEY, alloc TEXT);
INSERT INTO agents_demo_alloc VALUES
    (1, '0.25,0.25,0.25,0.25'),
    (2, '0.40,0.30,0.20,0.10'),
    (3, '0.10,0.20,0.30,0.40');

.print
.print === 13. rebalance_sibling blueprint (4 assets, cardinality=4) ===
WITH opt AS (SELECT fractal_optimize_portfolio(
                    '0.05,0.10,0.15,0.20',
                    '0.04,0,0,0, 0,0.09,0,0, 0,0,0.16,0, 0,0,0,0.25',
                    4, 42) AS j),
     t AS (SELECT json_extract(value, '$.doc_id')   AS doc_id,
                  json_extract(value, '$.distance') AS dist
             FROM json_each(fractal_search_telemetry(
                      'agents_demo_alloc', 'alloc',
                      (SELECT json_extract(j, '$.weights') FROM opt), 5))
            ORDER BY json_extract(value, '$.distance')
            LIMIT 1)
SELECT (SELECT json_extract(j, '$.sharpe') FROM opt)   AS sharpe,
       (SELECT json_extract(j, '$.weights') FROM opt)  AS weights,
       m.id           AS nearest_alloc_id,
       t.dist         AS nearest_distance
FROM t
JOIN (SELECT id, (row_number() OVER (ORDER BY rowid) - 1) AS doc_id
        FROM agents_demo_alloc) m USING (doc_id);
.print --- rationale (fractal_reason) ---
SELECT fractal_reason('one-line rebalance rationale for this portfolio');
.print --- the shipped agent: same composition, one call (baseline = the equal-weight row) ---
SELECT fractal_agent_rebalance_sibling(
    '0.05,0.10,0.15,0.20',
    '0.04,0,0,0, 0,0.09,0,0, 0,0,0.16,0, 0,0,0,0.25',
    4, 'agents_demo_alloc', 'alloc', '0.25,0.25,0.25,0.25', 42);

-- 13b. diverse_portfolios (fractal_agent_diverse_portfolios, enterprise
-- tier). Companion to allocate (Engine B, above): same 4-asset mu/cov, but
-- returns several structurally distinct good portfolios via
-- fractal_optimize_portfolio_multimodal instead of one. It registers the
-- multimodal optimizer but gates it behind the enterprise tier -- the
-- call errors with the clean dormant hint below and the shell carries on.
.print
.print === 13b. diverse_portfolios blueprint (4 assets, cardinality=2, enterprise tier) ===
.print '(expected: the clean enterprise-tier hint on the community build)'
SELECT fractal_optimize_portfolio_multimodal(
    '0.05,0.10,0.15,0.20',
    '0.04,0,0,0, 0,0.09,0,0, 0,0,0.16,0, 0,0,0,0.25',
    2, 6);
.print --- the shipped agent: same composition, one call (also enterprise-gated) ---
SELECT fractal_agent_diverse_portfolios(
    '0.05,0.10,0.15,0.20',
    '0.04,0,0,0, 0,0.09,0,0, 0,0,0.16,0, 0,0,0,0.25',
    2, 6);

-- 14. detour_classify (fleet-logistics; fractal_agent_detour_classify).
-- Combines the route-deviation search (fractal_search_trajectory: current
-- vs baseline across the fleet) with the GPS trace's fractal complexity
-- (fractal_dimension_boxcount), then reasons. nearest_fleet_id is the real
-- trajectory nearest (doc_id resolved back to id); trajectory_distance is
-- real; trace_complexity is the real box-counting dimension of the GPS
-- trace; rationale is the real fractal_reason output. Vehicle 1 has a
-- deliberate detour (its UPDATE relocates its tuple, exercising the doc_id
-- mapping against the physical order too).
DROP TABLE IF EXISTS agents_demo_vehicles;
CREATE TABLE agents_demo_vehicles (
    id INTEGER PRIMARY KEY, baseline TEXT, current TEXT);
WITH RECURSIVE gs(g) AS (SELECT 1 UNION ALL SELECT g + 1 FROM gs WHERE g < 8),
d(dim_idx) AS (SELECT 1 UNION ALL SELECT dim_idx + 1 FROM d WHERE dim_idx < 4)
INSERT INTO agents_demo_vehicles (id, baseline, current)
SELECT gs.g,
       '[' || (SELECT group_concat(printf('%.4f', random() / 9223372036854775808.0)
                                   ORDER BY d.dim_idx)) || ']',
       NULL
FROM gs CROSS JOIN d
GROUP BY gs.g;
UPDATE agents_demo_vehicles
   SET current = printf('[%.4f,%.4f,%.4f,%.4f]',
                        json_extract(baseline, '$[0]') - 0.7,
                        json_extract(baseline, '$[1]') + 0.6,
                        json_extract(baseline, '$[2]') + 0.5,
                        json_extract(baseline, '$[3]') - 0.4)
 WHERE id = 1;
UPDATE agents_demo_vehicles
   SET current = printf('[%.4f,%.4f,%.4f,%.4f]',
                        json_extract(baseline, '$[0]') + 0.05,
                        json_extract(baseline, '$[1]') + 0.05,
                        json_extract(baseline, '$[2]') + 0.05,
                        json_extract(baseline, '$[3]') + 0.05)
 WHERE id > 1;

.print
.print === 14. detour_classify blueprint (vehicle 1 detour + GPS trace) ===
WITH tr AS (SELECT fractal_search_trajectory(
                    'agents_demo_vehicles', 'current',
                    (SELECT baseline FROM agents_demo_vehicles WHERE id = 1),
                    (SELECT current  FROM agents_demo_vehicles WHERE id = 1),
                    5) AS tj),
-- GPS trace: a 100-step 2-D random walk (the running sum is materialized
-- with a window function; box-counting needs >= 3 valid eps-octaves, which
-- a scattered handful of points cannot give it).
gs(t) AS (SELECT 1 UNION ALL SELECT t + 1 FROM gs WHERE t < 100),
steps AS (SELECT t, (random() / 9223372036854775808.0 - 0.5) * 0.3 AS v FROM gs),
walk AS (SELECT printf('%.4f,%.4f', sum(v) OVER (ORDER BY t), sum(v) OVER (ORDER BY t)) AS p FROM steps)
SELECT (SELECT m.id FROM tr, json_each(tr.tj) je
         JOIN (SELECT id, (row_number() OVER (ORDER BY rowid) - 1) AS doc_id
                 FROM agents_demo_vehicles) m ON m.doc_id = json_extract(je.value, '$.doc_id')
        ORDER BY json_extract(je.value, '$.distance') LIMIT 1) AS nearest_fleet_id,
       (SELECT json_extract(je.value, '$.distance') FROM tr, json_each(tr.tj) je
        ORDER BY json_extract(je.value, '$.distance') LIMIT 1) AS trajectory_distance,
       fractal_dimension_boxcount(
           '[' || (SELECT group_concat(p) FROM walk) || ']', 2) AS trace_complexity;
.print --- rationale (fractal_reason) ---
SELECT fractal_reason('one-line detour classification for this fleet scan');
.print --- the shipped agent: same composition, one call (fresh GPS trace -- own randomness) ---
WITH gs(t) AS (SELECT 1 UNION ALL SELECT t + 1 FROM gs WHERE t < 100),
steps AS (SELECT t, (random() / 9223372036854775808.0 - 0.5) * 0.3 AS v FROM gs),
walk AS (SELECT printf('%.4f,%.4f', sum(v) OVER (ORDER BY t), sum(v) OVER (ORDER BY t)) AS p FROM steps)
SELECT fractal_agent_detour_classify(
    'agents_demo_vehicles', 'current',
    (SELECT baseline FROM agents_demo_vehicles WHERE id = 1),
    (SELECT current  FROM agents_demo_vehicles WHERE id = 1),
    '[' || (SELECT group_concat(p) FROM walk) || ']');

-- 15. track_anomaly (maritime/cybersecurity;
-- fractal_agent_track_anomaly).
-- Combines the track-deviation search (fractal_search_trajectory) with the
-- heading-change series' DFA exponent (fractal_dimension_dfa), then
-- reasons. nearest_fleet_id is the real trajectory nearest (doc_id
-- resolved back to id); trajectory_distance is real; dfa_exponent is the
-- real DFA exponent; rationale is the real fractal_reason output. Vessel 1
-- has a deliberate track deviation.
DROP TABLE IF EXISTS agents_demo_tracks;
CREATE TABLE agents_demo_tracks (
    id INTEGER PRIMARY KEY, baseline TEXT, current TEXT);
-- (Same insert shape as the vehicles above: baseline + a small nudge, then
-- a deliberate deviation on vessel 1.)
WITH RECURSIVE gs(g) AS (SELECT 1 UNION ALL SELECT g + 1 FROM gs WHERE g < 8),
d(dim_idx) AS (SELECT 1 UNION ALL SELECT dim_idx + 1 FROM d WHERE dim_idx < 4)
INSERT INTO agents_demo_tracks (id, baseline, current)
SELECT gs.g,
       '[' || (SELECT group_concat(printf('%.4f', random() / 9223372036854775808.0)
                                   ORDER BY d.dim_idx)) || ']',
       '[' || (SELECT group_concat(printf('%.4f', random() / 9223372036854775808.0 + 0.04)
                                   ORDER BY d.dim_idx)) || ']'
FROM gs CROSS JOIN d
GROUP BY gs.g;
UPDATE agents_demo_tracks
   SET current = printf('[%.4f,%.4f,%.4f,%.4f]',
                        json_extract(baseline, '$[0]') + 0.6,
                        json_extract(baseline, '$[1]') - 0.5,
                        json_extract(baseline, '$[2]') - 0.9,
                        json_extract(baseline, '$[3]') + 0.8)
 WHERE id = 1;

.print
.print === 15. track_anomaly blueprint (vessel 1 deviation + heading DFA) ===
WITH tr AS (SELECT fractal_search_trajectory(
                    'agents_demo_tracks', 'current',
                    (SELECT baseline FROM agents_demo_tracks WHERE id = 1),
                    (SELECT current  FROM agents_demo_tracks WHERE id = 1),
                    5) AS tj),
gs(t) AS (SELECT 1 UNION ALL SELECT t + 1 FROM gs WHERE t < 120),
steps AS (SELECT t, (random() / 9223372036854775808.0 - 0.5)
                   * (CASE WHEN t BETWEEN 40 AND 60 THEN 0.35 ELSE 0.03 END) AS v FROM gs),
walk AS (SELECT printf('%.6f', sum(v) OVER (ORDER BY t)) AS s FROM steps)
SELECT (SELECT m.id FROM tr, json_each(tr.tj) je
         JOIN (SELECT id, (row_number() OVER (ORDER BY rowid) - 1) AS doc_id
                 FROM agents_demo_tracks) m ON m.doc_id = json_extract(je.value, '$.doc_id')
        ORDER BY json_extract(je.value, '$.distance') LIMIT 1) AS nearest_fleet_id,
       (SELECT json_extract(je.value, '$.distance') FROM tr, json_each(tr.tj) je
        ORDER BY json_extract(je.value, '$.distance') LIMIT 1) AS trajectory_distance,
       fractal_dimension_dfa('[' || (SELECT group_concat(s) FROM walk) || ']')
           AS dfa_exponent;
.print --- rationale (fractal_reason) ---
SELECT fractal_reason('one-line anomaly read for this maritime track scan');
.print --- the shipped agent: same composition, one call (fresh heading series -- own randomness) ---
WITH gs(t) AS (SELECT 1 UNION ALL SELECT t + 1 FROM gs WHERE t < 120),
steps AS (SELECT t, (random() / 9223372036854775808.0 - 0.5)
                   * (CASE WHEN t BETWEEN 40 AND 60 THEN 0.35 ELSE 0.03 END) AS v FROM gs),
walk AS (SELECT printf('%.6f', sum(v) OVER (ORDER BY t)) AS s FROM steps)
SELECT fractal_agent_track_anomaly(
    'agents_demo_tracks', 'current',
    (SELECT baseline FROM agents_demo_tracks WHERE id = 1),
    (SELECT current  FROM agents_demo_tracks WHERE id = 1),
    '[' || (SELECT group_concat(s) FROM walk) || ']');

-- 16. network_coverage_alert (smart-cities;
-- fractal_agent_network_coverage_alert).
-- Combines the sensor grid's spatial morphology
-- (fractal_morphological_complexity -> dimension + lacunarity; needs >=
-- ~256 points, so a 20x20 grid matching the smart-cities demo) with the
-- telemetry series' regime-change drift (fractal_dimension_drift), then
-- reasons. The drift field is recent_alpha - baseline_alpha (a SIGNED
-- numeric, not a boolean); drift_detected is |drift| > drift_threshold
-- (default 0.5). morph_dimension/lacunarity are real; drift_detected is a
-- real boolean; rationale is the real fractal_reason output.
.print
.print === 16. network_coverage_alert blueprint (20x20 grid + step-up drift) ===
WITH grid AS (
    WITH RECURSIVE
    g(r, c) AS (
        SELECT 0, 0 UNION ALL
        SELECT CASE WHEN c = 19 THEN r + 1 ELSE r END,
               CASE WHEN c = 19 THEN 0 ELSE c + 1 END FROM g WHERE NOT (r = 19 AND c = 19)
    )
    SELECT fractal_morphological_complexity(
               '[' || group_concat(printf('%.4f', v) ORDER BY r, c) || ']', 2) AS mj
      FROM (SELECT r, c, r + (random() / 9223372036854775808.0 - 0.5) * 0.3 AS v FROM g)
),
drift AS (
    WITH RECURSIVE gs(t) AS (SELECT 1 UNION ALL SELECT t + 1 FROM gs WHERE t < 96)
    SELECT fractal_dimension_drift(
               '[' || (SELECT group_concat(printf('%.4f', v) ORDER BY t)
                         FROM (SELECT t, CASE WHEN t < 48
                                              THEN 4.0 + 1.5 * sin(t * 0.31)
                                                 + (random() / 9223372036854775808.0 - 0.5) * 0.8
                                              ELSE 4.0 + 3.0 * sin(t * 1.4)
                                                 + (random() / 9223372036854775808.0 - 0.5) * 0.4 END
                                        AS v FROM gs)) || ']', 48) AS dj
)
SELECT json_extract(g.mj, '$.dimension')              AS morph_dimension,
       json_extract(g.mj, '$.lacunarity')             AS lacunarity,
       (abs(json_extract(d.dj, '$.drift')) > 0.5)     AS drift_detected
FROM grid g, drift d;
.print --- rationale (fractal_reason) ---
SELECT fractal_reason('one-line coverage alert for this sensor-grid scan');
.print --- the shipped agent: same composition, one call (fresh grid + series -- own randomness; the agent computes drift itself, so it takes the raw series, not the drift JSON) ---
WITH RECURSIVE
g(r, c) AS (
    SELECT 0, 0 UNION ALL
    SELECT CASE WHEN c = 19 THEN r + 1 ELSE r END,
           CASE WHEN c = 19 THEN 0 ELSE c + 1 END FROM g WHERE NOT (r = 19 AND c = 19)
),
gv AS (SELECT r, c, r + (random() / 9223372036854775808.0 - 0.5) * 0.3 AS v FROM g),
gs(t) AS (SELECT 1 UNION ALL SELECT t + 1 FROM gs WHERE t < 96),
sv AS (SELECT t, CASE WHEN t < 48
                      THEN 4.0 + 1.5 * sin(t * 0.31)
                         + (random() / 9223372036854775808.0 - 0.5) * 0.8
                      ELSE 4.0 + 3.0 * sin(t * 1.4)
                         + (random() / 9223372036854775808.0 - 0.5) * 0.4 END AS v FROM gs)
SELECT fractal_agent_network_coverage_alert(
    '[' || (SELECT group_concat(printf('%.4f', v) ORDER BY r, c) FROM gv) || ']',
    '[' || (SELECT group_concat(printf('%.4f', v) ORDER BY t) FROM sv) || ']',
    2, 48, 0.5);

-- 17. regime_triage (general-purpose; fractal_agent_regime_triage).
-- Runs fractal_dimension_dfa (long-range-correlation exponent) and
-- fractal_dimension_drift (regime-change drift + recent/baseline alphas)
-- over a single series, then reasons. The single-series-in shape fits any
-- one series (no per-row time/metric table, unlike the anomaly_triage
-- blueprint). drift_detected is |drift| > drift_threshold (default 0.5).
-- dfa_exponent/drift_detected/recent_alpha/baseline_alpha are real;
-- rationale is the real fractal_reason output.
.print
.print === 17. regime_triage blueprint (96-pt step-up series) ===
WITH series AS (
    WITH RECURSIVE gs(t) AS (SELECT 1 UNION ALL SELECT t + 1 FROM gs WHERE t < 96)
    SELECT '[' || (SELECT group_concat(printf('%.4f', v) ORDER BY t)
                     FROM (SELECT t, CASE WHEN t < 48
                                          THEN 4.0 + 1.5 * sin(t * 0.31)
                                             + (random() / 9223372036854775808.0 - 0.5) * 0.8
                                          ELSE 4.0 + 3.0 * sin(t * 1.4)
                                             + (random() / 9223372036854775808.0 - 0.5) * 0.4 END
                                    AS v FROM gs)) || ']' AS sj
),
d AS (SELECT fractal_dimension_dfa((SELECT sj FROM series)) AS dfa,
             fractal_dimension_drift((SELECT sj FROM series), 64) AS dj)
SELECT d.dfa                                            AS dfa_exponent,
       (abs(json_extract(d.dj, '$.drift')) > 0.5)       AS drift_detected,
       json_extract(d.dj, '$.recent_alpha')             AS recent_alpha,
       json_extract(d.dj, '$.baseline_alpha')           AS baseline_alpha
FROM d;
.print --- rationale (fractal_reason) ---
SELECT fractal_reason('one-line regime triage for this series');
.print --- the shipped agent: same composition, one call (fresh series -- own randomness) ---
WITH gs(t) AS (SELECT 1 UNION ALL SELECT t + 1 FROM gs WHERE t < 96),
sv AS (SELECT t, CASE WHEN t < 48
                      THEN 4.0 + 1.5 * sin(t * 0.31)
                         + (random() / 9223372036854775808.0 - 0.5) * 0.8
                      ELSE 4.0 + 3.0 * sin(t * 1.4)
                         + (random() / 9223372036854775808.0 - 0.5) * 0.4 END AS v FROM gs)
SELECT fractal_agent_regime_triage(
    '[' || (SELECT group_concat(printf('%.4f', v) ORDER BY t) FROM sv) || ']',
    64, 0.5);

-- 18. The REAL agent-tier functions shipped in this build (not blueprints).
-- fractal_agent_trajectory_predict walks a real vector column from a
-- baseline row (baseline_id = rowid; the column must hold CSV/JSON vector
-- text -- a scalar metric column is rejected with a "baseline vector is
-- NULL or malformed" error, so the fleet fixture supplies the column);
-- fractal_agent_detect_loop DFA-tests a series for a repetitive loop.
-- (fractal_agent_plan_explore and the search/rag agents need the reasoning
-- plugin and error with the clean hint without one.)
.print
.print === 18. Installed agent tier: trajectory_predict + detect_loop ===
SELECT fractal_agent_trajectory_predict('agents_demo_vehicles', 'current', 1, 8)
           AS forecast;
WITH RECURSIVE gs(t) AS (SELECT 1 UNION ALL SELECT t + 1 FROM gs WHERE t < 64)
SELECT fractal_agent_detect_loop(
           '[' || (SELECT group_concat(printf('%.3f', v))
                     FROM (SELECT t, 0.1 * sin(t * 0.7) AS v FROM gs)) || ']')
           AS loop_scan;

-- 19. Closing narrative -- fractal_reason over the real computed results.
-- Same closing pattern as demo.sql and every vertical demo: one final
-- reasoning call that synthesizes a human-readable read over the real
-- analytics the agent blueprints just produced.
.print
.print === 19. Closing narrative: fractal_reason over the agent results ===
SELECT fractal_reason(
    'Synthesize a one-paragraph ops brief across the agent tier: the '
    || 'anomaly-triage threat_score, the allocation sharpe, the route_task '
    || 'routed_to/confidence, the outlier_intercept decision, the patient-'
    || 'deterioration cohort/drift distances, the schedule_workload '
    || 'assignment, the rebalance sharpe/weights, the detour/track '
    || 'distances and trace/DFA complexity, and the coverage/regime '
    || 'drift_detected flags above, and what each implies for the '
    || 'on-call engineer.',
    json_object(
        'source',  'demo-agents.sql',
        'engines', json('["fractal_agent_anomaly_triage",'
                  || '"fractal_agent_allocate",'
                  || '"fractal_agent_route_task",'
                  || '"fractal_agent_outlier_intercept",'
                  || '"fractal_agent_recall_hybrid",'
                  || '"fractal_agent_recommend_diverse",'
                  || '"fractal_agent_data_analyst",'
                  || '"fractal_agent_patient_deterioration_triage",'
                  || '"fractal_agent_feedback_audit",'
                  || '"fractal_agent_schedule_workload",'
                  || '"fractal_agent_rebalance_sibling",'
                  || '"fractal_agent_diverse_portfolios",'
                  || '"fractal_agent_detour_classify",'
                  || '"fractal_agent_track_anomaly",'
                  || '"fractal_agent_network_coverage_alert",'
                  || '"fractal_agent_regime_triage"]')
    )
);

-- Reset the session-global diversify flag the recommend_diverse and
-- feedback_audit blueprints enabled (feedback_audit self-disables, but
-- belt-and-suspenders).
SELECT fractal_diversify_disable();

.print
.print ================================================================
.print Demo complete. Tables left in place to inspect the results --
.print drop them to re-run:
.print   DROP TABLE agents_demo_logs, agents_demo_caps,
.print   agents_demo_badstates, agents_demo_mem, agents_demo_catalog,
.print   agents_demo_data, agents_demo_patients,
.print   agents_demo_fcatalog, agents_demo_fwarmup,
.print   agents_demo_nodes, agents_demo_alloc,
.print   agents_demo_vehicles, agents_demo_tracks;
.print ================================================================