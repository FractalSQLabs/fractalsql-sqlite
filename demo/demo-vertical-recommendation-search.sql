-- demo/demo-vertical-recommendation-search.sql
--
-- Industry vertical: Advanced Recommendation, Search & Discovery Engines.
--
-- A product/content catalog for diverse "you might also like" discovery,
-- a table-backed top-k telemetry search, the full stateful-diversity
-- loop (enable Diversify, search, report negative feedback on a result,
-- read back the session state -- the real differentiator over plain
-- top-K or MMR: it's stateful and feedback-learning, not a one-shot
-- re-ranking heuristic), and cross-modal search (content + behavior
-- vectors, weighted).
--
-- Prerequisites: extension installed (sections 0-5 need nothing else).
-- Section 6 calls fractal_reason() -- see ../docs/reasoning-setup.md
-- (per-connection fractalsql_set state, so re-apply your
-- load_fractalsql.sql snippet with -init).
--
-- Run (one invocation -- fractalsql_set state is per-connection):
--   sqlite3 -cmd ".load /usr/local/lib/sqlite3/fractalsql" ":memory:" \
--     ".read demo/demo-vertical-recommendation-search.sql"
--
-- Notes:
--   * There is no seedable global RNG -- the catalog fixtures are
--     plain random() (a signed 64-bit integer here, mapped into [0,1)
--     with (random()/2^63 + 1)/2), so the genre centers differ run to
--     run; every analysis output stays structurally identical.
--   * Vector columns are CSV TEXT guarded by a
--     CHECK(fractal_vector_dims(...) = 8) constraint; the per-dimension
--     jitter rebuilds the CSV with printf.
--   * The fractal_agent_recommend_diverse / _feedback_audit presets are
--     blueprint compositions over the primitives (Scout population +
--     telemetry; diversify loop + diagnostics) -- see demo-agents.sql
--     for the pattern.
--   * doc_id is the row's 0-based scan position; catalog rowid aliases
--     the INTEGER PRIMARY KEY id, so doc_id = id - 1 exactly (rowid
--     tables keep their physical position).
--
-- Safe to re-run: vrs_* tables are dropped and recreated each time.

.timer on

.print === 0. Sanity check: extension loaded? ===
SELECT fractalsql_edition(), fractalsql_version();

-- ------------------------------------------------------------------
-- 1. 300-item catalog, 6 genre clusters x 50 items in R^8. Centers
-- spread uniformly across [-0.9, 0.9] with per-item jitter -- matching
-- demo/benchmark.sql's own approach (narrow clustering in the box
-- center would silently understate Scout's real diversity result, per
-- that file's own load-bearing comment). One recursive pass, not an
-- uncorrelated subquery: every row's random() call is its own.
-- ------------------------------------------------------------------
.print
.print === 1. 300-item catalog: 6 genre clusters in R^8 ===

DROP TABLE IF EXISTS vrs_genres;
DROP TABLE IF EXISTS vrs_catalog;
CREATE TABLE vrs_genres (
    genre_id INTEGER PRIMARY KEY,
    name     TEXT,
    center   TEXT NOT NULL CHECK (fractal_vector_dims(center) = 8)
);
CREATE TABLE vrs_catalog (
    id      INTEGER PRIMARY KEY,
    genre_id INTEGER,
    title   TEXT,
    emb_arr TEXT NOT NULL CHECK (fractal_vector_dims(emb_arr) = 8)
);

-- Genre centers live first in a long (genre, dim, value) form so both
-- the center CSV and every item's jittered CSV are built from the SAME
-- random draw per dimension (printf concatenates in dim order).
DROP TABLE IF EXISTS vrs_center_dims;
CREATE TEMP TABLE vrs_center_dims AS
WITH gv(g, name) AS (VALUES (1,'sci-fi'),(2,'documentary'),(3,'true-crime'),
                            (4,'comedy'),(5,'strategy-games'),(6,'cooking')),
     d(dim) AS (SELECT 1 UNION ALL SELECT dim + 1 FROM d WHERE dim < 8)
SELECT g, name, dim, random() / 9223372036854775808.0 * 0.9 AS cval
FROM gv CROSS JOIN d;

INSERT INTO vrs_genres (genre_id, name, center)
SELECT g, name, group_concat(printf('%.4f', cval), ',')
FROM vrs_center_dims
GROUP BY g
ORDER BY g;

-- Per-item jitter around the genre center: one row per (item, dim), each
-- dimension perturbed independently around its genre's center draw.
DROP TABLE IF EXISTS vrs_item_dims;
CREATE TEMP TABLE vrs_item_dims AS
WITH RECURSIVE pt(item_n) AS (SELECT 1 UNION ALL SELECT item_n + 1 FROM pt WHERE item_n < 50)
SELECT cd.g AS gid, pt.item_n, cd.dim,
       cd.cval + ((random() / 9223372036854775808.0 + 1) / 2 - 0.5) * 0.25 AS v
FROM vrs_center_dims cd CROSS JOIN pt;

INSERT INTO vrs_catalog (genre_id, title, emb_arr)
SELECT gid, gc.name || '-item-' || item_n,
       group_concat(printf('%.4f', v), ',')
FROM vrs_item_dims
JOIN vrs_genres gc ON gc.genre_id = gid
GROUP BY gid, item_n
ORDER BY gid, item_n;

SELECT (SELECT count(*) FROM vrs_catalog) AS items,
       (SELECT count(DISTINCT genre_id) FROM vrs_catalog) AS genres;

-- ------------------------------------------------------------------
-- 2. Scout Discovery: diverse "you might also like" -- a spread across
-- distinct genre basins, not K near-duplicates from one genre.
-- ------------------------------------------------------------------
.print
.print === 2. fractal_search_explore: diverse recommendations ===
.print --- recommend_diverse blueprint (explore + query anchor + scores) ---

-- Blueprint (raw primitive): Scout returns a diverse spread of
-- representative catalog embeddings across distinct genre basins (not K
-- near-duplicates from one genre); the fractal_agent_recommend_diverse
-- preset anchors it on a real query and scores the population. Here:
-- anchor on the first catalog item's
-- own embedding (recommend_diverse is query-anchored, unlike the
-- blueprint's query-agnostic zero query), walk the population, and
-- score each member 1 - cosine distance to the anchor. (The aggregate
-- fractal_search_explore over your own column runs once per distinct query per
-- scan -- the same memoized form demo/benchmark.sql uses.)
WITH anchor AS (SELECT emb_arr AS a FROM vrs_catalog ORDER BY id LIMIT 1),
     e AS (SELECT fractal_search_explore(emb_arr, '0,0,0,0,0,0,0,0',
                                  '{"population_size": 6, "iterations": 8, "walk": 0}') AS res
             FROM vrs_catalog),
     pop AS (SELECT DISTINCT value AS member FROM e, json_each(e.res, '$.population'))
SELECT member
  FROM pop;

.print --- scored against the anchor (1 - cosine distance) ---
WITH anchor AS (SELECT emb_arr AS a FROM vrs_catalog ORDER BY id LIMIT 1),
     e AS (SELECT fractal_search_explore(emb_arr, '0,0,0,0,0,0,0,0',
                                  '{"population_size": 6, "iterations": 8, "walk": 0}') AS res
             FROM vrs_catalog),
     pop AS (SELECT DISTINCT value AS member FROM e, json_each(e.res, '$.population'))
SELECT member, 1.0 - fractal_vector_cosine_distance(anchor.a, member) AS score
FROM anchor, pop
ORDER BY score DESC;

SELECT fractal_diversify_disable();

-- ------------------------------------------------------------------
-- 3. fractal_search_telemetry: real top-k rows (doc_id + distance) --
-- the primitive fractal_search_explore/fractal_search don't provide on their
-- own (see that function's own doc comment).
-- ------------------------------------------------------------------
.print
.print === 3. fractal_search_telemetry: top-5 nearest catalog items ===

WITH tj AS (SELECT fractal_search_telemetry('vrs_catalog', 'emb_arr',
                    (SELECT center FROM vrs_genres WHERE genre_id = 1), 5) AS rj)
SELECT c.title, json_extract(je.value, '$.distance') AS distance
FROM tj, json_each(tj.rj) je
JOIN vrs_catalog c ON c.id - 1 = json_extract(je.value, '$.doc_id')
ORDER BY json_extract(je.value, '$.distance');

-- ------------------------------------------------------------------
-- 4. Diversify/Repulsion session state: enable it, report NEGATIVE
-- feedback on a result, and confirm the session picks it up.
--
-- fractal_diversify_enable()'s own doc comment scopes this to
-- "fractal_search results" specifically -- fractal_search_telemetry's
-- top_k (and hybrid_clinical_search/search_trajectory/cross_modal_
-- search, which all share it) is deliberately a literal, ground-truth
-- "k nearest REAL rows to this query" list, not repulsion-adjusted --
-- that's what makes it trustworthy for the doc_id/distance pairs the
-- rest of this demo joins back to real catalog rows. Repulsion state
-- from fractal_isolate_background is real (see the diagnostics below),
-- but today it only steers fractal_search()'s own single converged
-- point in the abstract [-1,1]^dim space, not this table-backed top-k
-- list -- so re-running the SAME fractal_search_telemetry query below
-- correctly returns the SAME top result, not a different one.
-- ------------------------------------------------------------------
.print
.print === 4. Diversify/Repulsion: session-level feedback state ===

-- Blueprint (raw primitive, the fractal_agent_feedback_audit preset's
-- audit cycle): enable repulsion, set params, warm the D_q
-- rolling window with varied genre-center queries, report negative
-- feedback on the genre-3 top result (fractal_isolate_background on its
-- doc_id -- the doc_id IS the handle), read back the real
-- diversity_quotient + session diagnostics, and self-disable.
SELECT fractal_diversify_enable();
SELECT fractal_diversify_set_params('{"window_n": 5, "repulsion_sigma": 0.3, "repulsion_weight": 0.5}');

-- Warm the D_q rolling window with varied genre-center queries (one
-- telemetry call per genre center, via a recursive CTE).
WITH tj AS (SELECT fractal_search_telemetry('vrs_catalog', 'emb_arr',
                    (SELECT center FROM vrs_genres WHERE genre_id = g), 3) AS rj
              FROM (WITH RECURSIVE gs(g) AS (SELECT 1 UNION ALL SELECT g + 1 FROM gs WHERE g < 8)
                    SELECT (g % 6) + 1 AS g FROM gs))
SELECT json_extract(je.value, '$.doc_id') AS warmed_doc_id
FROM tj, json_each(tj.rj) je
ORDER BY warmed_doc_id LIMIT 8;

-- Negative feedback on the genre-3 audit target.
WITH tj AS (SELECT fractal_search_telemetry('vrs_catalog', 'emb_arr',
                    (SELECT center FROM vrs_genres WHERE genre_id = 3), 1) AS rj)
SELECT c.title AS audit_target, json_extract(je.value, '$.doc_id') AS audit_doc_id
FROM tj, json_each(tj.rj) je
JOIN vrs_catalog c ON c.id - 1 = json_extract(je.value, '$.doc_id');

WITH tj AS (SELECT fractal_search_telemetry('vrs_catalog', 'emb_arr',
                    (SELECT center FROM vrs_genres WHERE genre_id = 3), 1) AS rj)
SELECT fractal_isolate_background(
    (SELECT json_extract(je.value, '$.doc_id') FROM tj, json_each(tj.rj) je));

SELECT fractal_detect_collapse() AS diversity_quotient,
       fractal_explain_result()  AS diagnostics;
SELECT fractal_diversify_disable();

-- ------------------------------------------------------------------
-- 5. Cross-modal search: content embedding + behavior embedding,
-- weighted (weighted CONCATENATION, not a blend -- each modality keeps
-- its own dimensions; vector_col must already be stored in this
-- combined shape).
-- ------------------------------------------------------------------
.print
.print === 5. fractal_cross_modal_search: content + behavior, weighted ===

DROP TABLE IF EXISTS vrs_modal_items;
CREATE TABLE vrs_modal_items (
    id           INTEGER PRIMARY KEY,
    title        TEXT,
    combined_vec TEXT NOT NULL CHECK (fractal_vector_dims(combined_vec) = 8)
);
WITH RECURSIVE gs(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM gs WHERE n < 60)
INSERT INTO vrs_modal_items (title, combined_vec)
SELECT 'modal-item-' || n,
       printf('%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f',
              (random() / 9223372036854775808.0 + 1) / 2 * 2 - 1,
              (random() / 9223372036854775808.0 + 1) / 2 * 2 - 1,
              (random() / 9223372036854775808.0 + 1) / 2 * 2 - 1,
              (random() / 9223372036854775808.0 + 1) / 2 * 2 - 1,   -- content (4d)
              (random() / 9223372036854775808.0 + 1) / 2 * 2 - 1,
              (random() / 9223372036854775808.0 + 1) / 2 * 2 - 1,
              (random() / 9223372036854775808.0 + 1) / 2 * 2 - 1,
              (random() / 9223372036854775808.0 + 1) / 2 * 2 - 1)   -- behavior (4d)
FROM gs;

WITH tj AS (SELECT fractal_cross_modal_search(
                    'vrs_modal_items', 'combined_vec',
                    '0.6,0.6,-0.6,0.0',   -- content query
                    '0.2,-0.2,0.2,0.2',   -- behavior query
                    0.7, 5) AS rj)
SELECT m.title, json_extract(je.value, '$.distance') AS distance
FROM tj, json_each(tj.rj) je
JOIN vrs_modal_items m ON m.id - 1 = json_extract(je.value, '$.doc_id')
ORDER BY json_extract(je.value, '$.distance');

-- ------------------------------------------------------------------
-- 6. Reasoning: explain the recommendation set in plain language.
-- ------------------------------------------------------------------
.print
.print === 6. Reasoning over the recommendation set ===

WITH tj AS (SELECT fractal_search_telemetry('vrs_catalog', 'emb_arr',
                    '0,0,0,0,0,0,0,0', 8) AS rj)
SELECT fractal_reason(
    'each item is a catalog title with a distance score from a diverse discovery search -- explain what kind of viewer/listener would want this mix and why the spread across genres matters',
    (SELECT json_group_object(c.title, json_object('genre_id', c.genre_id,
                                                   'distance', json_extract(je.value, '$.distance')))
       FROM tj, json_each(tj.rj) je
       JOIN vrs_catalog c ON c.id - 1 = json_extract(je.value, '$.doc_id')));

.print
.print === Demo complete ===
.print Tables left in place for inspection. Clean up with:
.print   DROP TABLE vrs_genres, vrs_catalog, vrs_modal_items;
.print (the vrs_* TEMP tables evaporate with the connection.)
.print ================================================================