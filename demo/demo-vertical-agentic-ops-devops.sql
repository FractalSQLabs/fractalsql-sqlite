-- =============================================================================
-- FractalSQL Industry Vertical Demo: Autonomous Incident Triage & Self-Healing
-- =============================================================================
-- End-to-end demo for the embed-coupled agents. Exercises:
--   * fractal_agent_detect_loop   -- period-2 loop detection (a REAL installed
--                                    agent function; the state_hash toggle
--                                    flags via the short-period check even
--                                    though its DFA alpha is ~0.04)
--   * fractal_search_agent        -- real call, gated on the reasoning plugin
--                                    (clean hint without one; without the
--                                    plugin the analytic sections still run)
--   * fractal_rag_agent           -- retrieve-then-reason, same plugin gate
--   * fractal_dimension_drift     -- non-degenerate drifting latency series
--                                    (the anomaly_triage blueprint)
--   * fractal_vectorizer_*        -- vectorizes the incident text (TEMP
--                                    registry/queue per connection)
--   * route_task / outlier_intercept / anomaly_triage blueprints -- task
--     routing, outlier interception, and drift+reason threat triage
--     compositions (the fractal_agent_* composites; see demo-agents.sql
--     for the same pattern with commentary)
-- Re-runnable: the vectorizer registry/queue are TEMP objects per
-- connection -- a fresh sqlite3 invocation starts clean, and the
-- conditional spool teardown below is only needed for a same-session
-- re-run -- then the demo tables are dropped.
-- =============================================================================

.timer on

.timer off
.once ops_vectorizer_teardown.sql
SELECT 'SELECT fractal_vectorizer_drop(id) FROM fractal_vectorizers
     WHERE source_table = ''incident_logs'';'
 WHERE EXISTS (SELECT 1 FROM sqlite_temp_master
                WHERE name = 'fractal_vectorizers');
.read ops_vectorizer_teardown.sql
.timer on

DROP TABLE IF EXISTS incident_logs;
DROP TABLE IF EXISTS agent_capabilities;
DROP TABLE IF EXISTS known_bad_states;

-- 1. Setup synthetic incident telemetry
CREATE TABLE incident_logs (
    id          INTEGER PRIMARY KEY,
    agent_id    TEXT,
    state_hash  INTEGER,        -- period-2 loop indicator (12345 / 67890)
    latency_ms  REAL,           -- drifting metric -> fractal_dimension_drift
    body        TEXT,           -- human-readable event line, vectorized below
    embedding   BLOB,           -- populated by the vectorizer (a
                                -- CHECK(fractal_vector_dims(...)=n) guard
                                -- is the pattern when you need one)
    event_ts    TEXT,
    payload     TEXT            -- JSON
);

-- Simulate a deployment bot stuck in an infinite retry loop: the state_hash
-- toggles 12345<->67890 every cycle (a clean period-2 sequence -- detect_loop
-- flags it via the short-period check even though its DFA alpha is ~0.04,
-- well below the 0.9 threshold). The latency_ms series is a genuinely
-- drifting (non-degenerate) signal -- a baseline ~50ms for the first 64
-- cycles, then a +30ms step-up over the most recent 32 cycles (the loop
-- degrading latency) -- so fractal_dimension_drift succeeds with a 32-point
-- recent window (DFA needs the recent window large enough; window=16 is too
-- small). The body text is what the vectorizer embeds for search_agent /
-- rag_agent. (A recursive CTE generates the cycle index.)
WITH RECURSIVE gs(g) AS (SELECT 1 UNION ALL SELECT g + 1 FROM gs WHERE g < 96)
INSERT INTO incident_logs (id, agent_id, state_hash, latency_ms, body, event_ts, payload)
SELECT g, 'bot-deploy-01',
       CASE WHEN g % 2 = 1 THEN 12345 ELSE 67890 END,
       50.0 + (g % 8) * 1.3 + CASE WHEN g > 64 THEN 30.0 ELSE 0.0 END,
       CASE WHEN g % 2 = 1
            THEN 'bot-deploy-01 retrying authentication: identity service refused connection (attempt ' || g || ')'
            ELSE 'bot-deploy-01 health check completed: all subsystems nominal (cycle ' || g || ')'
       END,
       datetime('now', '-' || (96 - g) || ' seconds'),
       CASE WHEN g % 2 = 1 THEN '{"event": "retry_auth"}'
            ELSE '{"event": "check_health"}' END
FROM gs;

-- A few healthy logs from a second bot (ids 97-99, outside bot-deploy-01's range).
INSERT INTO incident_logs (id, agent_id, state_hash, latency_ms, body, event_ts, payload) VALUES
(97, 'bot-deploy-02', 11111, 42.0, 'bot-deploy-02 deployed configuration v2.3 successfully', datetime('now'), '{"event": "init"}'),
(98, 'bot-deploy-02', 22222, 45.0, 'bot-deploy-02 applied rolling update to worker pool',    datetime('now'), '{"event": "config"}'),
(99, 'bot-deploy-02', 33333, 48.0, 'bot-deploy-02 deployment finalized, rollout green',      datetime('now'), '{"event": "deploy"}');

-- 2. Vectorize the incident body text into embeddings (your configured
-- embedding endpoint's width -- nomic-embed-text -> 768 dims). The
-- vectorizer backfills the already-inserted rows into its queue, then
-- process_queue embeds them. Without an endpoint configured, the queued rows
-- fail with a clean last_error (see demo-vectorizer.sql) and the
-- embed-coupled agent calls below carry the plugin hint instead -- either
-- way the script completes.
.print === 2. Vectorize the incident body text ===
SELECT fractal_vectorizer_create('incident_logs', 'body', 'embedding') AS vectorizer_id;
SELECT fractal_vectorizer_process_queue();   -- returns the number of rows embedded

-- 3. Setup capabilities map for routing
CREATE TABLE agent_capabilities (
    capability_name TEXT PRIMARY KEY,
    embedding TEXT                 -- CSV vector (was float8[])
);

INSERT INTO agent_capabilities (capability_name, embedding)
VALUES
('root-cause-analyzer', '0.1,0.2,0.3'),
('rollback-executor',   '0.9,0.8,0.7');

-- A small library of known-bad deployment states for the outlier_intercept
-- blueprint to screen proposed actions against.
CREATE TABLE known_bad_states (
    state_id     INTEGER PRIMARY KEY,
    description  TEXT,
    state_vec    TEXT
);
INSERT INTO known_bad_states (state_id, description, state_vec) VALUES
(1, 'auth-service unreachable, retry storm',  '0.5,0.5,0.5'),
(2, 'disk pressure cascading restarts',       '0.9,0.1,0.2');

-- -----------------------------------------------------------------------------
-- DEMONSTRATION
-- -----------------------------------------------------------------------------

-- 4. Loop Detection via DFA + short-period check
-- The state_hash sequence is a clean 12345<->67890 period-2 toggle. Its DFA
-- scaling exponent is ~0.04 (below the 0.9 threshold), so the DFA path alone
-- would NOT flag it -- but the short-period check does. Result:
-- is_loop_detected = true.
.print
.print === 4. fractal_agent_detect_loop (period-2 state toggle) ===
SELECT fractal_agent_detect_loop(
    '[' || (SELECT group_concat(state_hash ORDER BY event_ts)
              FROM incident_logs WHERE agent_id = 'bot-deploy-01') || ']')
           AS loop_scan;

-- 5. Task Routing (the route_task composition)
-- Real nearest-capability search over agent_capabilities.embedding via
-- fractal_search_telemetry, doc_id mapped back to the named capability;
-- confidence is 1/(1+distance) (real).
.print
.print === 5. Task routing over the capability map ===
WITH t AS (SELECT json_extract(value, '$.doc_id')   AS doc_id,
                  json_extract(value, '$.distance') AS dist
             FROM json_each(fractal_search_telemetry(
                      'agent_capabilities', 'embedding', '0.15,0.25,0.35', 1))
            ORDER BY json_extract(value, '$.distance')
            LIMIT 1)
SELECT m.capability_name  AS routed_to,
       1.0 / (1.0 + t.dist) AS confidence,
       1000               AS remaining_budget
FROM t
JOIN (SELECT capability_name,
             (row_number() OVER (ORDER BY rowid) - 1) AS doc_id
        FROM agent_capabilities) m USING (doc_id);
.print --- rationale (fractal_reason) ---
SELECT fractal_reason('one-line rationale for this task routing decision');
.print --- the shipped agent: same composition, one call ---
SELECT fractal_agent_route_task(
    '0.15,0.25,0.35', 'agent_capabilities', 'embedding', 'capability_name', 1000);

-- 6. Outlier Interception (the outlier_intercept composition)
-- Real cosine distance to the nearest known_bad_states row. This state_vec
-- matches state_id 1 exactly (distance 0), so intercepted = true.
.print
.print === 6. Outlier interception (state matches a known-bad state) ===
WITH d AS (SELECT json_extract(value, '$.distance') AS dist
             FROM json_each(fractal_search_telemetry(
                      'known_bad_states', 'state_vec', '0.5,0.5,0.5', 1))
            LIMIT 1)
SELECT (d.dist < 0.8) AS intercepted,
       printf('nearest bad state distance %.4f vs threshold 0.8', abs(d.dist)) AS reason
FROM d;
.print --- the shipped agent: same composition, one call ---
SELECT fractal_agent_outlier_intercept('0.5,0.5,0.5', 'known_bad_states', 'state_vec', 0.8);

-- 7. Threat Triage on the drifting latency metric (the anomaly_triage
-- composition: the latency_ms series is a non-degenerate step-up signal
-- with a 32-point recent window, so fractal_dimension_drift succeeds --
-- window=16 would be too small for DFA on the recent window and return
-- rc=-1).
.print
.print === 7. Threat triage on the drifting latency metric ===
WITH d AS (SELECT fractal_dimension_drift(
               (SELECT '[' || group_concat(printf('%.4f', latency_ms) ORDER BY event_ts) || ']'
                  FROM incident_logs WHERE agent_id = 'bot-deploy-01'), 32) AS j)
SELECT abs(json_extract(d.j, '$.drift'))     AS threat_score,
       'vector_drift'                        AS anomaly_type,
       json_extract(d.j, '$.recent_alpha')   AS recent_alpha,
       json_extract(d.j, '$.baseline_alpha') AS baseline_alpha
FROM d;
.print --- triage_summary (fractal_reason over the drift result) ---
SELECT fractal_reason(
    'one-line triage for this anomaly-detection drift report',
    (SELECT fractal_dimension_drift(
         (SELECT '[' || group_concat(printf('%.4f', latency_ms) ORDER BY event_ts) || ']'
            FROM incident_logs WHERE agent_id = 'bot-deploy-01'), 32)));
.print --- the shipped agent: same composition, one call ---
SELECT fractal_agent_anomaly_triage(
    'incident_logs', 'latency_ms', 'event_ts', 'agent_id', 'bot-deploy-01', 32);

-- 8. Localized Root-Cause Synthesis via Search Agent
-- Embeds the query and runs a diverse Scout search over the
-- incident_logs.embedding column, then reasons over the retrieved context.
-- Gated on the reasoning plugin: the clean hint below is the expected
-- output without one (there is no column-type crash to guard against --
-- SQLite resolves names statically; pointing at a non-vector column is a
-- host-side schema decision, and a CHECK on dims is the guard).
.print
.print === 8. fractal_search_agent (root-cause synthesis; reasoning plugin) ===
SELECT fractal_search_agent(
    'Why is bot-deploy-01 looping on auth?',
    'incident_logs', 'embedding',
    10, 5);

-- 9. RAG Agent: retrieve-then-reason over the incident corpus.
.print
.print === 9. fractal_rag_agent (retrieve-then-reason; reasoning plugin) ===
SELECT fractal_rag_agent(
    'What events led to the auth retry loop on bot-deploy-01?',
    'incident_logs', 'embedding');

.print
.print ================================================================
.print Demo complete. Tables left in place for inspection -- drop them
.print to re-run:
.print   DROP TABLE incident_logs, agent_capabilities, known_bad_states;
.print (ops_vectorizer_teardown.sql is the teardown spool file in the
.print current directory -- overwritten each run, delete whenever.)
.print ================================================================