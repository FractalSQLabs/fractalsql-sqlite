-- demo/benchmark-api-reference.sql
--
-- A timed pass over EVERY callable function in
-- sql/fractalsql--1.0.sql (the SQLite surface the file documents),
-- grouped the same way that file groups them. Distinct from
-- demo/benchmark.sql, which stays scoped to its own narrower
-- Sniper/Scout/vectorizer comparison (see that file's own header
-- comment) -- this one's job is coverage, not a head-to-head
-- comparison.
--
-- Fixtures are deliberately small and reused across sections -- this is
-- a correctness-plus-latency smoke pass over the whole API surface, not
-- a scale benchmark (see ../bench/ for the real sqlite-vec-vs-Scout scale
-- evaluation behind docs/features.md's numbers). Reasoning-dependent
-- calls (fractal_reason, fractal_text_to_sql, fractal_embed and the
-- agent family) are expected to FAIL here without a configured plugin,
-- with the clean "reasoning plugin not configured" hint -- the sqlite3
-- shell continues past the error, and each guarded call prints its
-- own '-- <name> skipped: <error>' marker row instead of aborting the
-- benchmark. SQLite has no procedural exception-handling construct, so
-- this is a plain pass over the calls: the errors are the
-- documentation.
--
-- Run (one invocation):
--   sqlite3 -cmd ".load /usr/local/lib/sqlite3/fractalsql" ":memory:" \
--     ".read demo/benchmark-api-reference.sql"
--
-- API surface notes:
--   * Edition/version: fractalsql_edition() / fractalsql_version().
--   * fractal_schema_context() takes no arguments and walks
--     sqlite_master.
--   * fractal_text_to_sql(question) takes only the question; scoping
--     lives on fractal_sql_agent(question, table_names JSON).
--   * fractal_vectorizer_create(source_table, text_col, embedding_col
--     [, options]) -- pk_col is introspected, NOT an argument.
--   * The vectorizer registry/queue are TEMP objects; the conditional
--     spool teardown below is only needed for a same-session re-run.
--   * The feature-store pair (fractal_store_morphology /
--     fractal_mine_topology_negatives) stores each vector as a
--     canonical fractal_vector BLOB; the backing
--     fractalsql_feature_store table is created automatically on
--     first use.
--   * fractal_diversify_set_params(params) takes one argument: a JSON
--     object text.
--   * The registry/queue are per-connection TEMP: bmk_* tables are
--     still permanent, so this file re-runs against a file database
--     without colliding.
--
-- Safe to re-run: bmk_* tables are dropped and recreated each time.

.timer on

.print ================================================================
.print FractalSQL full-API-reference benchmark -- one pass over the
.print callable surface, grouped by category.
.print ================================================================

-- ------------------------------------------------------------------
-- 0. Meta (2 functions)
-- ------------------------------------------------------------------
.print
.print === Meta: fractalsql_edition, fractalsql_version ===
SELECT fractalsql_edition(), fractalsql_version();

-- ------------------------------------------------------------------
-- 1. Search (3 functions)
-- ------------------------------------------------------------------
.print
.print === Search: fractal_search, fractal_search_debug, fractal_search_explore ===

DROP TABLE IF EXISTS bmk_corpus;
CREATE TABLE bmk_corpus (id INTEGER PRIMARY KEY, emb TEXT);
WITH RECURSIVE gs(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM gs WHERE n < 100)
INSERT INTO bmk_corpus (emb)
WITH RECURSIVE d(dim_idx) AS (SELECT 1 UNION ALL SELECT dim_idx + 1 FROM d WHERE dim_idx < 8)
SELECT '[' || group_concat(printf('%.4f', random() / 9223372036854775808.0) ORDER BY d.dim_idx) || ']'
FROM gs CROSS JOIN d
GROUP BY gs.n;

SELECT fractal_search(emb, '0.6,0.8,0,0,0,0,0,0') AS fractal_search FROM bmk_corpus LIMIT 3;
SELECT json_extract(fractal_search_debug('[0.6,0.8,0,0,0,0,0,0]', 10), '$.best_fit') AS search_debug_best_fit;
SELECT count(*) AS fractal_search_explore_population
  FROM (SELECT fractal_search_explore(emb, '[0,0,0,0,0,0,0,0]',
                               '{"population_size": 6, "iterations": 6, "walk": 0}') AS res
          FROM bmk_corpus),
       json_each(res, '$.population');

-- ------------------------------------------------------------------
-- 2. Reasoning / text-to-SQL / embedding (plugin-required; guarded)
-- ------------------------------------------------------------------
.print
.print === Reasoning: fractal_reason, fractal_schema_context, ===
.print === fractal_text_to_sql, fractal_embed, fractal_sql_agent ===

SELECT 'fractal_reason ->' AS guarded, fractal_reason('reply with a one-word confirmation', '{}');
SELECT 'fractal_schema_context ->' AS guarded,
       substr(fractal_schema_context(), 1, 80) AS schema_context_result;
SELECT 'fractal_text_to_sql ->' AS guarded,
       fractal_text_to_sql('how many rows are in bmk_corpus?');
SELECT 'fractal_embed ->' AS guarded,
       fractal_vector_dims(fractal_embed('a short benchmark sentence')) AS embed_dim;
SELECT 'fractal_sql_agent ->' AS guarded,
       substr(fractal_sql_agent('how many rows are in bmk_corpus?',
                                '["bmk_corpus"]'), 1, 120) AS sql_agent_result;

-- ------------------------------------------------------------------
-- 3. Vectorizer (4 functions)
-- ------------------------------------------------------------------
.print
.print === Vectorizer: fractal_vectorizer_create, process_queue, pause, resume ===
.print '(a missing embedding endpoint makes the queued rows fail with a'
.print ' clean last_error -- the call itself still returns row counts)'

.timer off
.once bmk_docs_teardown.sql
SELECT 'SELECT fractal_vectorizer_drop(id) FROM fractal_vectorizers
     WHERE source_table = ''bmk_docs'';'
 WHERE EXISTS (SELECT 1 FROM sqlite_temp_master
                WHERE name = 'fractal_vectorizers');
.read bmk_docs_teardown.sql
.timer on

DROP TABLE IF EXISTS bmk_docs;
CREATE TABLE bmk_docs (id INTEGER PRIMARY KEY, body TEXT NOT NULL, embedding BLOB);
WITH RECURSIVE gs(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM gs WHERE n < 5)
INSERT INTO bmk_docs (body) SELECT 'benchmark document ' || n FROM gs;
-- The create returns the new vectorizer id; pause/resume below reuse it
-- (single vectorizer -> id 1 here; adjust if you created others first).
SELECT fractal_vectorizer_create('bmk_docs', 'body', 'embedding') AS bmk_vzid;
SELECT fractal_vectorizer_process_queue();
-- pause: further writes to bmk_docs stop queueing, process_queue() skips
-- this vectorizer's remaining pending rows -- resume immediately after so
-- the rest of this script (and a re-run) sees normal behavior again.
SELECT fractal_vectorizer_pause(1);
SELECT fractal_vectorizer_resume(1);

-- ------------------------------------------------------------------
-- 4. Diversify / Repulsion + Feedback (7 functions)
-- ------------------------------------------------------------------
.print
.print === Diversify/Repulsion + Feedback: enable, set_params, detect_collapse, ===
.print === explain_result, feedback_report, isolate_background, disable ===

SELECT fractal_diversify_enable() AS diversify_enable;
SELECT fractal_diversify_set_params('{"population_size": 8, "mmr_lambda": 0.5}')
       AS diversify_set_params;
SELECT fractal_detect_collapse() AS dq;
SELECT fractal_explain_result() AS diagnostics;
-- Telemetry feeds the diversify engine its per-search data:
WITH RECURSIVE gs(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM gs WHERE n < 6)
SELECT count(*) AS telemetry_calls
  FROM (SELECT fractal_search_telemetry('bmk_corpus', 'emb',
                                        '[0,0,0,0,0,0,0,0]', 3) FROM gs);
SELECT fractal_feedback_report(1, 'positive', 4000) AS feedback_report;
SELECT fractal_isolate_background(2) AS isolate_background;
SELECT fractal_diversify_disable() AS diversify_disable;

-- ------------------------------------------------------------------
-- 5. Fractal dimension analysis (3 functions)
-- ------------------------------------------------------------------
.print
.print === Dimension analysis: fractal_dimension_dfa, _boxcount, _drift ===

-- DFA over a 200-step random walk. (A running sum can't be carried
-- through a recursive CTE's own SELECT, and an aggregate can't nest a
-- window function -- so the walk is a generated series and the running
-- sum is materialized in a second CTE with a window sum.)
WITH RECURSIVE gs(t) AS (SELECT 1 UNION ALL SELECT t + 1 FROM gs WHERE t < 200),
steps AS (SELECT t, (random() / 9223372036854775808.0 - 0.5) * 0.05 AS v FROM gs),
walk AS (SELECT printf('%.6f', sum(v) OVER (ORDER BY t)) AS s FROM steps)
SELECT fractal_dimension_dfa('[' || (SELECT group_concat(s) FROM walk) || ']')
       AS dfa_alpha;

-- 20x20 jittered grid (400 points) -- box-counting needs a
-- space-filling, not scattered, fixture to find >= 3 valid
-- eps-octaves. (The grid CTE stops at the last cell, NOT on r < 20 --
-- the row-literal form leaves exactly one overshoot row behind, and
-- the C-side flat-coordinate parser rejects any odd count: "points
-- length must be a positive multiple of dim".)
WITH RECURSIVE
g(r, c) AS (
    SELECT 0, 0 UNION ALL
    SELECT CASE WHEN c = 19 THEN r + 1 ELSE r END,
           CASE WHEN c = 19 THEN 0 ELSE c + 1 END FROM g WHERE NOT (r = 19 AND c = 19)
)
SELECT fractal_dimension_boxcount(
    '[' || group_concat(printf('%.4f', v) ORDER BY r, c) || ']',
    2) AS boxcount_dimension
FROM (SELECT r, c, r + 0.3 * random() / 9223372036854775808.0 AS v FROM g);

-- Drift report over the same random-walk shape, 100 steps, window 32:
WITH RECURSIVE gs(t) AS (SELECT 1 UNION ALL SELECT t + 1 FROM gs WHERE t < 100),
steps AS (SELECT t, (random() / 9223372036854775808.0 - 0.5) * 0.05 AS v FROM gs),
walk AS (SELECT printf('%.6f', sum(v) OVER (ORDER BY t)) AS s FROM steps)
SELECT fractal_dimension_drift('[' || (SELECT group_concat(s) FROM walk) || ']',
                               32) AS drift_report;

-- ------------------------------------------------------------------
-- 6. Portfolio optimization (1 function)
-- ------------------------------------------------------------------
.print
.print === Portfolio: fractal_optimize_portfolio ===

SELECT fractal_optimize_portfolio(
    '0.05,0.08,0.03,0.12,0.07,0.01',
    '0.02,0,0,0,0,0, 0,0.03,0,0,0,0, 0,0,0.04,0,0,0,
          0,0,0,0.05,0,0, 0,0,0,0,0.06,0, 0,0,0,0,0,0.07',
    2, 42) AS allocation;

-- ------------------------------------------------------------------
-- 7. Domain-specific geometry (4 functions)
-- ------------------------------------------------------------------
.print
.print === Domain geometry: fractal_vascular_network, _cortical_folding, ===
.print === _nerve_plexus_metric, fractal_morphological_complexity ===

-- 28-node chain + 2 branch leaves -- this scale (not a handful of
-- nodes) is what the internal box-counting step needs to succeed.
-- Nodes/edges/arc-lengths are CSV arrays built with recursive CTEs;
-- the C side validates the cross-product: arc-length count must equal
-- edge count exactly (29 edges here).
WITH RECURSIVE gs(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM gs WHERE i < 27)
SELECT fractal_vascular_network(
    (SELECT group_concat(printf('%.1f,0,0', i), ',') FROM gs) || ',10,1,0,10,0,1',
    (SELECT group_concat(printf('%d,%d', i, i + 1), ',') FROM gs WHERE i < 27) || ',10,28,10,29',
    (WITH ls(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM ls WHERE i < 28)
       SELECT group_concat('1.02', ',') FROM ls)
) AS vascular;

-- Unit cube surface mesh (8 vertices, 12 faces) -- known-answer
-- reference (GI ~1.0):
SELECT fractal_cortical_folding(
    '0,0,0, 1,0,0, 1,1,0, 0,1,0, 0,0,1, 1,0,1, 1,1,1, 0,1,1',
    '0,1,2, 0,2,3,   4,5,6, 4,6,7,   0,1,5, 0,5,4,
          3,2,6, 3,6,7,   0,3,7, 0,7,4,   1,2,6, 1,6,5'
) AS cortical;

-- 80-node plexus chain:
WITH RECURSIVE gs(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM gs WHERE i < 79)
SELECT fractal_nerve_plexus_metric(
    (SELECT group_concat(printf('%.2f,%.2f', i * 1.0, 0.05 * (i % 4 - 1.5)), ',')
       FROM gs WHERE i < 80),
    2,
    (SELECT group_concat(printf('%d,%d', i, i + 1), ',')
       FROM gs WHERE i < 79)
) AS nerve;

-- 20x20 jittered grid morphology (same fixture shape as box-counting):
WITH RECURSIVE
g(r, c) AS (
    SELECT 0, 0 UNION ALL
    SELECT CASE WHEN c = 19 THEN r + 1 ELSE r END,
           CASE WHEN c = 19 THEN 0 ELSE c + 1 END FROM g WHERE NOT (r = 19 AND c = 19)
)
SELECT fractal_morphological_complexity(
    '[' || group_concat(printf('%.4f', v) ORDER BY r, c) || ']',
    2) AS morphology
FROM (SELECT r, c, r + 0.3 * random() / 9223372036854775808.0 AS v FROM g);

-- ------------------------------------------------------------------
-- 8. Named feature store (2 functions)
-- ------------------------------------------------------------------
.print
.print === Feature store: fractal_store_morphology, fractal_mine_topology_negatives ===

WITH RECURSIVE gs(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM gs WHERE i < 10)
SELECT fractal_store_morphology(i,
    printf('%.4f,%.4f,%.4f',
           random() / 9223372036854775808.0,
           random() / 9223372036854775808.0,
           random() / 9223372036854775808.0))
  FROM gs;

SELECT json_extract(value, '$.doc_id') AS doc_id,
       json_extract(value, '$.distance') AS distance
  FROM json_each(fractal_mine_topology_negatives('0.5,0.5,0.5', 3));

-- ------------------------------------------------------------------
-- 9. Table-backed telemetry search family (4 functions)
-- ------------------------------------------------------------------
.print
.print === Telemetry search: fractal_search_telemetry, _hybrid_clinical_search, ===
.print === fractal_search_trajectory, fractal_cross_modal_search ===

SELECT json_extract(value, '$.doc_id') AS doc_id,
       json_extract(value, '$.distance') AS distance
  FROM json_each(fractal_search_telemetry('bmk_corpus', 'emb',
                                          '[0,0,0,0,0,0,0,0]', 3));

SELECT json_extract(value, '$.doc_id') AS doc_id,
       json_extract(value, '$.distance') AS distance
  FROM json_each(fractal_hybrid_clinical_search(
      'bmk_corpus', 'emb', '[0,0,0,0,0,0,0,0]',
      (SELECT group_concat(id - 1, ',') FROM bmk_corpus WHERE id <= 20), 3));

SELECT json_extract(value, '$.doc_id') AS doc_id,
       json_extract(value, '$.distance') AS distance
  FROM json_each(fractal_search_trajectory(
      'bmk_corpus', 'emb', '[0,0,0,0,0,0,0,0]', '[0.5,0.5,0,0,0,0,0,0]', 3));

DROP TABLE IF EXISTS bmk_modal;
CREATE TABLE bmk_modal (id INTEGER PRIMARY KEY, combined_vec TEXT);
WITH RECURSIVE gs(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM gs WHERE n < 20)
INSERT INTO bmk_modal (combined_vec)
SELECT '[' || printf('%.4f', random() / 9223372036854775808.0) || ',' ||
       printf('%.4f', random() / 9223372036854775808.0) || ',' ||
       printf('%.4f', random() / 9223372036854775808.0) || ',' ||
       printf('%.4f', random() / 9223372036854775808.0) || ']'
FROM gs;

SELECT json_extract(value, '$.doc_id') AS doc_id,
       json_extract(value, '$.distance') AS distance
  FROM json_each(fractal_cross_modal_search('bmk_modal', 'combined_vec',
                                            '0.5,0.5', '-0.5,-0.5', 0.5, 3));

.print
.print ================================================================
.print Benchmark complete. Tables left in place for inspection.
.print Clean up with:
.print   DROP TABLE bmk_corpus, bmk_docs, bmk_modal;
.print   DELETE FROM fractalsql_feature_store WHERE doc_id BETWEEN 1 AND 10;
.print (bmk_docs_teardown.sql is the vectorizer section's spool file in
.print the current directory -- overwritten each run, delete whenever.)
.print ================================================================