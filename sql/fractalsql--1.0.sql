-- sql/fractalsql--1.0.sql
--
-- fractalsql-sqlite v2.0 — setup snippets, function surface reference,
-- and load instructions.
--
-- SPDX-License-Identifier: Apache-2.0
-- SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
--
-- SQLite loadable extensions register their functions from C at load
-- time (sqlite3_create_function_v2), so there are no CREATE FUNCTION
-- statements to replay and no extension version plumbing. Everything
-- below is either a one-line load command or plain SQL the user runs
-- to try the surface.
--
-- ---------------------------------------------------------------------
-- 1. Loading
-- ---------------------------------------------------------------------
--
-- CLI:  sqlite3 -cmd ".load /usr/local/lib/sqlite3/fractalsql"
-- SQL:  SELECT load_extension('/usr/local/lib/sqlite3/fractalsql');
-- See sql/load_extension.sql for install paths.
--
-- ---------------------------------------------------------------------
-- 2. Function surface (2.0.0, Community sovereign build)
-- ---------------------------------------------------------------------
--
-- Smoke + search:
--   fractalsql_edition() -> TEXT                        -- 'Community'
--   fractalsql_version() -> TEXT                        -- '2.0.0'
--   fractal_search(vector, query) -> REAL               -- Sniper, memoized
--   fractal_search_explore(emb, query[, params]) -> TEXT       -- Scout aggregate
--
-- fractal_vector (BLOB convention: u16 dim LE + u16 reserved + f32[]):
--   fractal_vector(dim)                                  -> BLOB
--   fractal_vector_from_text(t)                          -> BLOB
--   fractal_vector_to_json(v)                            -> TEXT
--   fractal_vector_dims(v)                               -> INT
--   fractal_vector_l2_distance(a,b)                      -> REAL
--   fractal_vector_l2_squared(a,b)                       -> REAL
--   fractal_vector_cosine_distance(a,b)                  -> REAL
--   fractal_vector_cosine_similarity(a,b)                -> REAL
--   fractal_vector_negative_inner_product(a,b)           -> REAL
--   fractal_vector_add(a,b) / _sub(a,b)                  -> BLOB
--   fractal_vector_scale(v,s)                            -> BLOB
--   fractal_vector_norm(v)                               -> REAL
--   fractal_vector_normalize(v)                          -> BLOB
--
-- Configuration (per-connection state; SQLite analog of PG GUCs):
--   fractalsql_set(name, value) -> 'ok'
--   fractalsql_get(name)        -> TEXT|INT
--   Keys: reasoning_plugin, http_url, http_token, http_model,
--         http_allow_plaintext, http_embed_url, http_embed_model,
--         http_think, http_think_provider, http_native_url,
--         http_num_ctx, text_to_sql_max_attempts,
--         text_to_sql_allowed_statements, text_to_sql_use_review,
--         enterprise_lib, enterprise_ledger_key,
--         enterprise_require_signature
--   (Prefix-free names as shown; the 'fractalsql.'-prefixed spelling
--   is accepted for parity with the PG GUC names.)
--
-- Sovereign-only surface (compiled out on a minimal-core build — the
-- names then raise "no such function" from SQLite):
--   fractal_reason(question[, context])                  -> TEXT
--   fractal_schema_context()                             -> TEXT
--   fractal_text_to_sql(question)                        -> TEXT
--   fractal_embed(text)                                  -> BLOB
--   fractal_vectorizer_create(source_table, text_col, embedding_col
--     [, options])                                       -> TEXT
--   fractal_vectorizer_pause/resume(handle)              -> TEXT
--   fractal_vectorizer_drop(handle)                      -> TEXT
--   fractal_vectorizer_process_queue([batch[, stale_after_secs]]) -> INT
--     (rows are enqueued by the TEMP triggers fractal_vectorizer_create
--      installs on INSERT and on UPDATE OF text_col:
--      INSERT INTO fractal_vectorizer_queue(source_pk_value))
--   fractal_search_debug(query[, iterations, population_size,
--     diffusion_factor])                                 -> TEXT
--   fractal_search_agent(query, table_name, vector_col
--     [, pop_size, iterations])                          -> TEXT
--   fractal_sql_agent(question[, table_names, max_retries,
--     auto_execute])                                     -> TEXT
--   fractal_rag_agent(query, table_name, vector_col
--     [, meta_filter])                                   -> TEXT
--   fractal_agent_plan_explore(initial_state, table, col, max_branches)
--                                                        -> TEXT
--   fractal_agent_trajectory_predict(table, col, baseline_id,
--     forecast_steps)                                    -> TEXT
--   fractal_agent_detect_loop(series)                    -> TEXT
--   fractal_search_telemetry(table, col, query, k)       -> TEXT
--   fractal_search_trajectory(table, col, baseline, current, k)  -> TEXT
--   fractal_cross_modal_search(tbl, col, morph, clinic, alpha, k)-> TEXT
--   fractal_hybrid_clinical_search(tbl, col, query, cohort, k)   -> TEXT
--   fractal_explain_result()                             -> TEXT
--   fractal_detect_collapse()                            -> REAL
--   fractal_dimension_dfa(s) / _drift(s,w) / _boxcount(p,d) -> REAL
--   fractal_optimize_portfolio(mu,cov,k,seed) (multimodal variants,
--     multimodal_pareto)                          -> TEXT JSON
--   fractal_vascular_network(c,e,l) / _cortical_folding(v,f)
--     / _nerve_plexus_metric(c,e,d) / _morphological_complexity(p,d)
--   fractal_diversify_enable/disable/set_params/
--     current_dq/overhead_p99_us
--   fractal_feedback_report(handle, kind[, dwell_ms])    -> (null)
--   fractal_isolate_background(handle)                   -> (null)
--   fractal_ledger_flush/load/compact/reset_soft/reset_hard -> TEXT
--   fractal_ledger_truth_count/shadow_count              -> INT
--   fractal_ledger_verify([kind])                        -> TEXT JSON
--     (O(n) append-only chain audit; kind defaults to 1. Pure read-only
--      query over fractalsql_ledger -- unlike the rest of this group,
--      works even with no enterprise_lib configured.)
--   fractal_audit_unpack(blob)                           -> TEXT
--   fractal_audit_log(entry_type, payload)               -> TEXT
--   fractal_store_morphology(doc_id, feature_array)      -> TEXT ('ok')
--   fractal_mine_topology_negatives(surrogate, k)        -> TEXT JSON
--     (named feature store; fractalsql_feature_store table
--      auto-created on first use)
--
-- PG functions with no SQLite counterpart (structural N/A):
--   CREATE EXTENSION / ALTER EXTENSION plumbing — .load replaces it
--   Data-modifying-CTE readonly analysis — sqlite3_stmt_readonly covers
--     the policy; SQLite cannot parse CTE modification chains the way
--     PG's raw_parser could
--   Role-based GUC ownership — replaced by set-time path validation
--   FOR UPDATE SKIP LOCKED queue claims — replaced by BEGIN IMMEDIATE
--     claim + stale-claim reclaim in fractal_vectorizer_process_queue
--
-- ---------------------------------------------------------------------
-- 3. Try it
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS vectors(
    id        INTEGER PRIMARY KEY,
    embedding TEXT                    -- '0.1,0.2,-0.3,0.4' or BLOB
);
INSERT INTO vectors(embedding) VALUES
    ('0.6,0.8,0.0,0.0'),
    ('0.1,0.2,-0.3,0.4'),
    ('0.9,0.1,0.0,0.0'),
    ('0.5,0.5,0.5,0.5');

-- Top 3 nearest to a query (SFS runs once per distinct query per scan):
SELECT id, fractal_search(embedding, '0.6,0.8,0.0,0.0') AS dist
FROM vectors
ORDER BY dist
LIMIT 3;

-- Canonical vector BLOBs — construct, measure, store:
CREATE TABLE IF NOT EXISTS vec_store(
    id  INTEGER PRIMARY KEY,
    vec BLOB                            -- canonical fractal_vector BLOB
);
INSERT INTO vec_store(vec)
SELECT fractal_vector_from_text('0.25,0.75,-0.5');

SELECT fractal_vector_dims(vec),
       fractal_vector_cosine_similarity(
           vec, fractal_vector_from_text('0.25,0.75,-0.5'))
FROM vec_store;

-- Scout-mode aggregate over a whole corpus (JSON result with the
-- final SFS population):
-- SELECT fractal_search_explore(embedding, '0.6,0.8,0.0,0.0') FROM vectors;

-- Reasoning tier (requires a configured plugin + LLM endpoint):
-- SELECT fractalsql_set('reasoning_plugin',
--                       '/usr/local/lib/sqlite3/fractalsql-reasoning-http.so');
-- SELECT fractalsql_set('http_url', 'http://localhost:11434/v1');
-- SELECT fractal_reason('Explain the cosine distance metric.');