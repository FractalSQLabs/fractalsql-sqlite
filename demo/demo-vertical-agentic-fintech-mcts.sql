-- =============================================================================
-- FractalSQL Industry Vertical Demo: Scenario Exploration & Safe Execution
-- =============================================================================
-- End-to-end demo for the planning + text-to-sql agents. Exercises:
--   * fractal_agent_plan_explore     -- a REAL installed agent function: embeds
--                                       the seed state and Scout-searches an
--                                       embedding column (gated on the
--                                       reasoning plugin -- clean hint without
--                                       one, as with every cognition agent)
--   * fractal_sql_agent              -- auto-executes model-generated SQL (in-
--                                       process, no server round trip; a thrown
--                                       execution error is captured into
--                                       execution_status='execution_failed',
--                                       not propagated to abort the call)
--   * rebalance_sibling blueprint    -- portfolio rebalance (optimizer +
--                                       telemetry search) composition
--   * fractal_reason                 -- rationale synthesis (plugin-gated)
--   * fractal_vectorizer_*           -- vectorizes strategy descriptions
-- Re-runnable: the vectorizer registry/queue are TEMP objects per
-- connection -- a fresh sqlite3 invocation starts clean, and the
-- conditional spool teardown below is only needed for a same-session
-- re-run -- then the demo tables are dropped.
-- =============================================================================

.timer on

.timer off
.once fint_vectorizer_teardown.sql
SELECT 'SELECT fractal_vectorizer_drop(id) FROM fractal_vectorizers
     WHERE source_table = ''trade_strategies'';'
 WHERE EXISTS (SELECT 1 FROM sqlite_temp_master
                WHERE name = 'fractal_vectorizers');
.read fint_vectorizer_teardown.sql
.timer on

DROP TABLE IF EXISTS trade_strategies;
DROP TABLE IF EXISTS portfolios;
DROP TABLE IF EXISTS assets;
DROP TABLE IF EXISTS restrictions;
DROP TABLE IF EXISTS historical_allocations;

-- 1. Setup financial strategy space
CREATE TABLE trade_strategies (
    strategy_id     INTEGER PRIMARY KEY,
    description     TEXT,                 -- vectorized below
    embedding       BLOB,                 -- populated by the vectorizer
    trajectory      TEXT,                 -- CSV vector
    constraints     TEXT,                 -- JSON
    expected_return REAL
);

INSERT INTO trade_strategies (strategy_id, description, trajectory, constraints, expected_return)
VALUES
(1, 'low-volatility mean-reversion strategy targeting ESG-compliant equities with tight risk bounds',
        '0.1,0.2', '{"max_risk": 0.05}', 0.08),
(2, 'momentum strategy riding medium-term trends with moderate risk tolerance and diversified sector exposure',
        '0.5,0.1', '{"max_risk": 0.10}', 0.12),
(3, 'high-conviction concentrated strategy with strict risk budget and low expected turnover',
        '0.9,0.8', '{"max_risk": 0.02}', 0.04);

-- 2. Vectorize the strategy descriptions. This is the embedding-width column
-- fractal_agent_plan_explore needs (it embeds the initial_state text and
-- Scout-searches this column). Without an embedding endpoint configured the
-- queued rows fail with a clean last_error and the gated agent calls below
-- carry the plugin hint instead -- either way the script completes.
.print === 2. Vectorize the strategy descriptions ===
SELECT fractal_vectorizer_create('trade_strategies', 'description', 'embedding') AS vectorizer_id;
SELECT fractal_vectorizer_process_queue();

-- 3. Portfolio/asset/restriction tables referenced by the fractal_sql_agent
-- regulatory-audit step. Minimal seed so the agent's schema context
-- (fractal_schema_context) can resolve the table_names it is given.
CREATE TABLE portfolios (
    portfolio_id INTEGER PRIMARY KEY,
    name TEXT NOT NULL
);
CREATE TABLE assets (
    asset_id INTEGER PRIMARY KEY,
    portfolio_id INTEGER NOT NULL,
    value NUMERIC NOT NULL,
    esg_restricted INTEGER NOT NULL DEFAULT 0     -- boolean (0/1)
);
CREATE TABLE restrictions (
    restriction_id INTEGER PRIMARY KEY,
    asset_id INTEGER NOT NULL,
    restriction_type TEXT NOT NULL
);
INSERT INTO portfolios (portfolio_id, name) VALUES
    (1, 'Global Growth'), (2, 'ESG Core'), (3, 'High Yield');
INSERT INTO assets (asset_id, portfolio_id, value, esg_restricted) VALUES
    (101, 1, 250000, 0),
    (102, 1, 120000, 1),
    (103, 2,  80000, 1),
    (104, 3, 310000, 0);
INSERT INTO restrictions (restriction_id, asset_id, restriction_type) VALUES
    (1, 102, 'ESG-fossil-fuel'),
    (2, 103, 'ESG-weapons');

-- 4. A snapshot of past allocation decisions, for the rebalance blueprint's
-- trajectory-search half: "which prior allocation is this new one closest
-- to." Weight vectors match mu/cov's 2-asset shape below.
CREATE TABLE historical_allocations (
    alloc_id  INTEGER PRIMARY KEY,
    label     TEXT,
    weights   TEXT                               -- CSV vector (was float8[])
);
INSERT INTO historical_allocations (alloc_id, label, weights) VALUES
(1, 'Q1-2025 momentum tilt',  '0.6,0.4'),
(2, 'Q2-2025 defensive tilt', '0.3,0.7'),
(3, 'Q3-2025 balanced',       '0.5,0.5');

-- -----------------------------------------------------------------------------
-- DEMONSTRATION
-- -----------------------------------------------------------------------------

-- 5. MCTS-style strategy exploration
-- Explore N non-overlapping execution paths starting from a seed market
-- state. fractal_agent_plan_explore embeds the initial_state text and
-- Scout-searches the trade_strategies.embedding column for diverse branches.
-- Gated on the reasoning plugin: the clean hint is the expected output
-- without one.
.print
.print === 5. fractal_agent_plan_explore (MCTS-style branching) ===
SELECT fractal_agent_plan_explore(
    'momentum strategy with moderate risk',
    'trade_strategies', 'embedding',
    3) AS plan;
-- Expected with a plugin: 3 diverse branch_ids with confidence scores

-- 6. Self-correcting Text-to-SQL for regulatory audit
-- Ask for a complex regulatory report, with auto-execution and retries. The
-- generated SQL runs inside the agent: a thrown execution ERROR is captured
-- and returned as execution_status='execution_failed' + the error in
-- result_json, rather than aborting the whole agent call. On a working model
-- it returns execution_status='executed' and the row count in result_json.
.print
.print === 6. fractal_sql_agent (regulatory audit; reasoning plugin) ===
SELECT fractal_sql_agent(
    'Calculate the total exposure to ESG-restricted assets across all portfolios',
    '["portfolios", "assets", "restrictions"]',
    3,
    1);

-- 7. Portfolio Rebalance (the rebalance_sibling composition)
-- Runs the SFS optimizer (cov must be a FLATTENED 1-D CSV of length
-- n_assets^2 -- the 2x2 identity here is '1,0,0,1' row-major, see
-- demo-vertical-quant-finance.sql for the pattern at real scale), then finds
-- the nearest prior allocation to an equal-weight baseline via
-- fractal_search_telemetry (doc_id mapped back to alloc_id), then reasons
-- over both.
.print
.print === 7. Portfolio rebalance (optimizer + nearest prior allocation) ===
WITH opt AS (SELECT fractal_optimize_portfolio('0.05,0.1', '1,0,0,1', 2, 42) AS j),
     t AS (SELECT json_extract(value, '$.doc_id')   AS doc_id,
                  json_extract(value, '$.distance') AS dist
             FROM json_each(fractal_search_telemetry(
                      'historical_allocations', 'weights',
                      (SELECT json_extract(j, '$.weights') FROM opt), 5))
            ORDER BY json_extract(value, '$.distance')
            LIMIT 1)
SELECT (SELECT json_extract(j, '$.sharpe') FROM opt)   AS sharpe,
       (SELECT json_extract(j, '$.weights') FROM opt)  AS weights,
       m.alloc_id     AS nearest_alloc_id,
       t.dist         AS nearest_distance
FROM t
JOIN (SELECT alloc_id, (row_number() OVER (ORDER BY rowid) - 1) AS doc_id
        FROM historical_allocations) m USING (doc_id);
.print --- rationale (fractal_reason over both halves) ---
SELECT fractal_reason('one-line rebalance rationale for this portfolio');
.print --- the shipped agent: same idea, one call (fractal_search_trajectory's
.print baseline->current drift in place of the blueprint's plain telemetry
.print search on the optimizer's own weights) ---
SELECT fractal_agent_rebalance_sibling(
    '0.05,0.1', '1,0,0,1', 2, 'historical_allocations', 'weights', '0.5,0.5', 42, 5, 'alloc_id');

-- 8. Safe Execution: the auto_execute path above runs the generated SQL
-- inside the agent call and captures any late-stage constraint violation
-- into execution_status/result_json instead of aborting the session.

-- Reset nothing: no session-global flags were left enabled by this demo.

.print
.print ================================================================
.print Demo complete. Tables left in place for inspection -- drop them
.print to re-run:
.print   DROP TABLE trade_strategies, portfolios, assets, restrictions,
.print   historical_allocations;
.print (fint_vectorizer_teardown.sql is the teardown spool file in the
.print current directory -- overwritten each run, delete whenever.)
.print ================================================================