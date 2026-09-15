-- =============================================================================
-- FractalSQL Industry Vertical Demo: Stateful Session & Churn Drift
-- =============================================================================
-- End-to-end demo for the trajectory-forecast agent tier. Exercises:
--   * fractal_agent_trajectory_predict  -- a REAL installed agent function:
--     it reads the baseline vector (by rowid = baseline_id) and the latest
--     vector (max rowid) from the table, derives dim from the data, computes
--     a real delta, and searches the corpus for the nearest predicted state.
--     (The column must hold CSV/JSON vector text -- float8[] does not exist
--     in SQLite.)
--   * fractal_search_explore                   -- pure-C Scout search on a literal vector
--   * hybrid cohort recall blueprint    -- the fractal_agent_recall_hybrid
--                                         composition (hybrid search + doc_id
--                                         -> row key mapping)
--   * recommend_diverse blueprint       -- the fractal_agent_recommend_diverse
--                                         composition (diversify + telemetry)
--   * fractal_diversify_enable
-- Re-runnable (DROP at the top).
-- =============================================================================

.timer on

DROP TABLE IF EXISTS customer_sessions;
DROP TABLE IF EXISTS customer_playbook;
DROP TABLE IF EXISTS product_catalog;

-- 1. Setup customer session telemetry -- a single customer (cust-abc) drifting
-- from onboarding toward churn across five sessions. session_id is an INTEGER
-- PRIMARY KEY, which in SQLite ALIASES the rowid -- so the agent's
-- baseline_id lookup (by rowid = PK) resolves session 100 directly. The
-- latest row (max rowid, session 103) is "current", and session 100 is
-- "baseline".
CREATE TABLE customer_sessions (
    session_id        INTEGER PRIMARY KEY,
    customer_id       TEXT,
    state_vector      TEXT,          -- CSV vector (was float8[])
    sentiment_score   REAL,
    last_interaction  TEXT
);

INSERT INTO customer_sessions (session_id, customer_id, state_vector, sentiment_score, last_interaction)
VALUES
(100, 'cust-abc', '0.1,0.1,0.1', 0.8, datetime('now', '-30 days')),
(101, 'cust-abc', '0.3,0.15,0.1', 0.6, datetime('now', '-20 days')),
(102, 'cust-abc', '0.6,0.2,0.1', 0.4, datetime('now', '-10 days')),
(103, 'cust-abc', '0.8,0.2,0.1', 0.2, datetime('now'));

-- 2. A playbook of past churn-recovery cases: what worked (or didn't) for
-- other customers whose state vector, at the point of intervention, looked
-- like this. The recall blueprint below searches this by real vector
-- similarity against session 103's current state.
CREATE TABLE customer_playbook (
    case_id       INTEGER PRIMARY KEY,
    customer_id   TEXT,
    state_vector  TEXT,
    resolution    TEXT
);

INSERT INTO customer_playbook (case_id, customer_id, state_vector, resolution) VALUES
(1, 'cust-def', '0.75,0.22,0.12', 'Escalated to a retention specialist with a loyalty discount; saved'),
(2, 'cust-ghi', '0.30,0.10,0.05', 'Proactive check-in call resolved early-stage frustration'),
(3, 'cust-jkl', '0.82,0.18,0.09', 'Offered a downgrade path instead of cancellation; saved'),
(4, 'cust-mno', '0.05,0.05,0.05', 'No intervention needed, healthy customer');

-- 3. A retention-offer catalog for the diverse-recommendation blueprint to
-- pick a diverse, non-redundant set of interventions from.
CREATE TABLE product_catalog (
    item_id  INTEGER PRIMARY KEY,
    name     TEXT,
    emb      TEXT
);

INSERT INTO product_catalog (item_id, name, emb) VALUES
(1, 'Loyalty Discount 20%',      '0.80,0.20,0.10'),
(2, 'Free Premium Upgrade',      '0.75,0.25,0.15'),
(3, 'Dedicated Support Line',    '0.60,0.30,0.20'),
(4, 'Downgrade to Basic Plan',   '0.40,0.10,0.05'),
(5, 'Early Renewal Bonus',       '0.20,0.10,0.10');

-- -----------------------------------------------------------------------------
-- DEMONSTRATION
-- -----------------------------------------------------------------------------

-- 4. Enable stateful diversification to avoid repeating failed scripts
.print === 4. Enable stateful diversification ===
SELECT fractal_diversify_enable();

-- 5. Forecast trajectory drift toward churn
-- The REAL installed agent: searches the corpus for the nearest predicted
-- state to the delta between the baseline session (100 -- the INTEGER
-- PRIMARY KEY aliases the rowid the agent resolves by) and the latest
-- session (103). Returns a real predicted_state_vector (length 3, derived
-- from the data) and a projected_drift_delta.
.print
.print === 5. fractal_agent_trajectory_predict (baseline = onboarding) ===
SELECT fractal_agent_trajectory_predict('customer_sessions', 'state_vector',
                                        100, 5)
           AS forecast;

-- 6. Hybrid Memory Recall (the recall_hybrid composition: cohort-restricted
-- hybrid search over the playbook, doc_id mapped back to case_id)
-- Recall past playbook cases whose state vector, at intervention time, was
-- close to this customer's current drifting state (session 103).
.print
.print === 6. Hybrid memory recall over the playbook ===
WITH hs AS (SELECT fractal_hybrid_clinical_search(
                    'customer_playbook', 'state_vector', '0.8,0.2,0.1',
                    (SELECT group_concat(pos, ',') FROM
                       (SELECT row_number() OVER (ORDER BY rowid) - 1 AS pos
                          FROM customer_playbook)), 5) AS rj)
SELECT m.case_id  AS mem_id,
       m.resolution AS content
  FROM hs, json_each(hs.rj) je
  JOIN (SELECT case_id, resolution,
               (row_number() OVER (ORDER BY rowid) - 1) AS doc_id
          FROM customer_playbook) m
    ON m.doc_id = json_extract(je.value, '$.doc_id')
 ORDER BY json_extract(je.value, '$.distance');
.print --- the shipped agent: same composition, one call ---
SELECT fractal_agent_recall_hybrid(
    'customer_playbook', 'state_vector', '0.8,0.2,0.1',
    NULL, NULL, 5, 'case_id', 'resolution');

-- 7. Repulsion-guided intervention
-- Scout Discovery over the session states: the most diverse (non-redundant)
-- recovery strategies for this customer's current state -- the aggregate
-- fractal_search_explore over your own column; the population comes back
-- as one JSON document ($.population).
.print
.print === 7. Scout Discovery over the session states ===
WITH e AS (SELECT fractal_search_explore(state_vector, '0.8,0.2,0.1',
                                  '{"population_size": 5}') AS res
             FROM customer_sessions)
SELECT value AS particle
  FROM e, json_each(e.res, '$.population');

-- 8. Diverse Recommendations (the recommend_diverse composition)
-- Repulsion-diverse top-k retention offers for this customer's current
-- state. item_id is the REAL catalog id (doc_id resolved back via the
-- rowid ordering); score is 1-cosine_distance (real, from the primitive).
.print
.print === 8. Repulsion-diverse retention offers ===
WITH t AS (SELECT json_extract(value, '$.doc_id')   AS doc_id,
                  json_extract(value, '$.distance') AS dist
             FROM json_each(fractal_search_telemetry(
                      'product_catalog', 'emb', '0.8,0.2,0.1', 5)))
SELECT m.item_id     AS item_id,
       m.name        AS name,
       1.0 - t.dist  AS score
FROM t
JOIN (SELECT item_id, name, (row_number() OVER (ORDER BY rowid) - 1) AS doc_id
        FROM product_catalog) m USING (doc_id)
ORDER BY t.dist;
.print --- the shipped agent: same composition, one call ---
SELECT fractal_agent_recommend_diverse('product_catalog', 'emb', '0.8,0.2,0.1', 5, 'item_id');

-- Reset the session-global diversify flag enabled in section 4.
SELECT fractal_diversify_disable();

.print
.print ================================================================
.print Demo complete. Tables left in place for inspection -- drop them
.print to re-run:
.print   DROP TABLE customer_sessions, customer_playbook, product_catalog;
.print ================================================================