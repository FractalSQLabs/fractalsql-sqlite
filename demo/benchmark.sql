-- demo/benchmark.sql
--
-- A quick, reproducible benchmark for FractalSQL: Sniper Search
-- convergence, Scout Discovery's diversity advantage over plain top-K,
-- and real vectorizer throughput -- all runnable straight from the
-- demo in a couple of minutes. For the full large-scale sqlite-vec vs.
-- Scout Discovery evaluation behind the numbers in
-- ../docs/features.md, see ../bench/ (`make bench`).
--
-- Run (one invocation):
--   sqlite3 -cmd ".load /usr/local/lib/sqlite3/fractalsql" ":memory:" \
--     ".read demo/benchmark.sql"
--
-- Notes:
--   * Vector fixtures are built with recursive CTEs and JSON arrays
--     (json_group_array / json_each), and the corpus is CSV/JSON TEXT
--     ('0.1,0.2,...' or '[0.1,0.2,...]'), which every function here
--     parses directly. Canonical fractal_vector BLOBs scan faster
--     still -- see demo/demo-fractal-vector.sql's storage section.
--   * random() is a signed 64-bit INTEGER: dividing by 2^63 maps it
--     into [-1,1), and ABS(random()) % n bounds it to a range. Every
--     seed expression below does one of the two.
--   * fractal_search_debug(query, iterations, population, diffusion)
--     is the abstract-space form, returning one JSON document whose
--     $.best_point key is the converged point.
--   * Scout Discovery is the AGGREGATE fractal_search_explore(col,
--     query, params) -- scan your own column; the population comes
--     back as one JSON document ($.population).
--   * .timer on covers per-statement timing in the sqlite3 CLI output.
--
-- Safe to re-run: all tables here are dropped and recreated each time,
-- prefixed bt_bench_* so they can't collide with demo.sql's own
-- demo_* tables. In-memory (":memory:") is the cleanest throwaway
-- target; a temp file works too.

.timer on

.print ================================================================
.print FractalSQL basic benchmark -- Sniper Search, Scout Discovery,
.print and vectorizer throughput, with real reproducible numbers.
.print ================================================================

-- ------------------------------------------------------------------
-- Section 1: Sniper Search -- convergence latency + accuracy by dim
-- ------------------------------------------------------------------
-- iterations/population_size held constant; only the query dimension
-- changes. cosine_similarity_to_query close to 1.0 confirms SFS
-- actually converged, not just "returned something fast".

.print
.print === Section 1: Sniper Search -- convergence by dimension ===
.print (iterations=50, population_size=50 held constant)

-- dim=8 (the random query is built as a JSON array; random()/2^63
-- maps the signed 64-bit random() into [-1,1))
WITH RECURSIVE g(i, v) AS (
    SELECT 1, random() / 9223372036854775808.0
    UNION ALL SELECT i + 1, random() / 9223372036854775808.0
      FROM g WHERE i < 8
),
q AS (SELECT '[' || group_concat(v, ',') || ']' AS qj FROM g),
dbg AS (SELECT qj, fractal_search_debug(qj, 50, 50, 2) AS d FROM q)
SELECT 8 AS dim,
       (SELECT sum(a.value * b.value)
          FROM json_each(json_extract(d, '$.best_point')) a
          JOIN json_each(qj) b ON b.key = a.key)
         / (sqrt((SELECT sum(value * value)
                    FROM json_each(json_extract(d, '$.best_point'))))
             * sqrt((SELECT sum(value * value) FROM json_each(qj))))
         AS cosine_similarity_to_query
FROM dbg;

-- dim=32
WITH RECURSIVE g(i, v) AS (
    SELECT 1, random() / 9223372036854775808.0
    UNION ALL SELECT i + 1, random() / 9223372036854775808.0
      FROM g WHERE i < 32
),
q AS (SELECT '[' || group_concat(v, ',') || ']' AS qj FROM g),
dbg AS (SELECT qj, fractal_search_debug(qj, 50, 50, 2) AS d FROM q)
SELECT 32 AS dim,
       (SELECT sum(a.value * b.value)
          FROM json_each(json_extract(d, '$.best_point')) a
          JOIN json_each(qj) b ON b.key = a.key)
         / (sqrt((SELECT sum(value * value)
                    FROM json_each(json_extract(d, '$.best_point'))))
             * sqrt((SELECT sum(value * value) FROM json_each(qj))))
         AS cosine_similarity_to_query
FROM dbg;

-- dim=128
WITH RECURSIVE g(i, v) AS (
    SELECT 1, random() / 9223372036854775808.0
    UNION ALL SELECT i + 1, random() / 9223372036854775808.0
      FROM g WHERE i < 128
),
q AS (SELECT '[' || group_concat(v, ',') || ']' AS qj FROM g),
dbg AS (SELECT qj, fractal_search_debug(qj, 50, 50, 2) AS d FROM q)
SELECT 128 AS dim,
       (SELECT sum(a.value * b.value)
          FROM json_each(json_extract(d, '$.best_point')) a
          JOIN json_each(qj) b ON b.key = a.key)
         / (sqrt((SELECT sum(value * value)
                    FROM json_each(json_extract(d, '$.best_point'))))
             * sqrt((SELECT sum(value * value) FROM json_each(qj))))
         AS cosine_similarity_to_query
FROM dbg;

-- ------------------------------------------------------------------
-- Section 2: Scout Discovery vs. naive top-K -- cluster diversity
-- ------------------------------------------------------------------
-- 20 synthetic clusters x 250 points in R^8 (5000 rows). Both methods
-- return K=50; we count how many of the 20 clusters each method's
-- results actually represent. This is the mode-collapse problem Scout
-- Discovery exists to fix: a method returning near-duplicates from one
-- cluster scores low here even though every individual result is
-- technically "close" to the query. "Naive top-K" is brute-force
-- cosine distance in plain SQL -- the same ranking a real ANN index
-- would return, just unindexed.
--
-- Every returned point, from either method, gets mapped to its
-- nearest cluster center (matches ../bench/head_to_head.py's own
-- methodology) so both sides are scored the same way.

.print
.print === Section 2: Scout Discovery vs. naive top-K -- cluster diversity ===
.print 20 synthetic clusters x 250 points in R^8 (5000 rows), K=50 returned.

DROP TABLE IF EXISTS bt_bench_clusters;
DROP TABLE IF EXISTS bt_bench_corpus;
CREATE TABLE bt_bench_clusters (cluster_id INTEGER PRIMARY KEY, center TEXT);
CREATE TABLE bt_bench_corpus (id INTEGER PRIMARY KEY, cluster_id INTEGER, emb TEXT);

-- Centers spread uniformly across [-0.9, 0.9] with +/-0.1 noise per
-- point, matching ../bench/data_gen.py's own approach (centers
-- uniform in [-1, 1]^dim) rather than clustering them narrowly in the
-- middle -- a corpus that only fills the center of SFS's [-1, 1]^dim
-- operating box leaves the edges empty, and walk=0's diversity fitness
-- (maximize distance to the nearest stored point) will correctly race
-- particles to that empty space instead of spreading them across the
-- real clusters, understating the real result.
--
-- Recursive CTEs generate the per-cluster index ranges; group_concat
-- ORDER BY assembles the per-cluster vectors afterward. SQLite
-- evaluates the volatile random() once per row of the flat cross
-- join, so no special care is needed to avoid re-evaluating it per
-- dimension.
WITH RECURSIVE
d(dim_idx) AS (SELECT 1 UNION ALL SELECT dim_idx + 1 FROM d WHERE dim_idx < 8),
c(cluster_id) AS (SELECT 1 UNION ALL SELECT cluster_id + 1 FROM c WHERE cluster_id < 20)
INSERT INTO bt_bench_clusters (cluster_id, center)
SELECT c.cluster_id,
       '[' || group_concat(printf('%.4f', 0.9 * random() / 9223372036854775808.0)
                           ORDER BY d.dim_idx) || ']'
FROM c CROSS JOIN d
GROUP BY c.cluster_id;

INSERT INTO bt_bench_corpus (cluster_id, emb)
WITH RECURSIVE
d(dim_idx) AS (SELECT 1 UNION ALL SELECT dim_idx + 1 FROM d WHERE dim_idx < 8),
p(point_n) AS (SELECT 1 UNION ALL SELECT point_n + 1 FROM p WHERE point_n < 250)
SELECT c.cluster_id,
       '[' || group_concat(printf('%.4f',
                    json_extract(c.center, '$[' || (d.dim_idx - 1) || ']')
                    + 0.1 * random() / 9223372036854775808.0)
                    ORDER BY d.dim_idx) || ']'
FROM bt_bench_clusters c CROSS JOIN p CROSS JOIN d
GROUP BY c.cluster_id, p.point_n;

-- Query is a small fixed off-center point, NOT a literal corpus row --
-- a query sitting almost exactly on a cluster center is a known
-- adversarial case for cosine-based MMR (see the fractalsql-core
-- unit tests' header comment: near-degenerate relevance ties can make
-- even mmr_lambda=0.0 fail to escape the dominant basin). The origin
-- (all zeros) doesn't work either -- cosine similarity is undefined
-- for a zero vector.
.print
.print --- naive top-K (brute-force cosine distance, plain SQL, K=50) ---
-- Nearest cluster per top-K row is computed as a join + window function
-- rather than a subquery nested inside another correlated subquery:
-- SQLite does not resolve a reference to the outermost alias (t.emb)
-- through two levels of subquery nesting (confirmed: "no such column"
-- even though the same reference resolves fine one level up).
WITH q(i, v) AS (SELECT key, value FROM json_each('[0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1]')),
top_k AS (
    SELECT bc.id, bc.emb
    FROM bt_bench_corpus bc, q
    ORDER BY 1 - ((SELECT sum(e.value * q.v)
                     FROM json_each(bc.emb) e JOIN q ON q.i = e.key)
                / (sqrt((SELECT sum(value * value) FROM json_each(bc.emb)))
                   * sqrt((SELECT sum(v * v) FROM q))) + 1e-9)
    LIMIT 50),
dists AS (
    SELECT t.id AS row_id, c2.cluster_id,
           row_number() OVER (PARTITION BY t.id ORDER BY
               (SELECT sum((a.value - b.value) * (a.value - b.value))
                  FROM json_each(c2.center) a JOIN json_each(t.emb) b ON b.key = a.key)
           ) AS rn
      FROM top_k t, bt_bench_clusters c2)
SELECT count(DISTINCT cluster_id) AS distinct_clusters_of_20
  FROM dists WHERE rn = 1;

-- Same query as naive top-K above (see that section's comment on why
-- it's a fixed off-center point, not a literal corpus row).
-- mmr_lambda 0.2 weights diversity more heavily than the 0.5 default.
-- On this small fixture the spread is several clusters of 20 (e.g.
-- 7-13) -- treat this section as measuring the GAP vs. naive top-K,
-- not as a headline number; ../bench/ runs the real scale evaluation.
.print
.print --- Scout Discovery (fractal_search_explore aggregate, population_size=50) ---
-- Same join + window-function restructuring as the naive top-K section
-- above, for the same reason (see that section's comment).
WITH s AS (
    SELECT fractal_search_explore(emb, '[0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1]',
                           '{"population_size": 50, "iterations": 8, "walk": 0, "mmr_lambda": 0.2}')
           AS res
    FROM bt_bench_corpus),
pts AS (SELECT je.key AS point_idx, je.value AS point FROM s, json_each(s.res, '$.population') je),
dists AS (
    SELECT p.point_idx AS row_id, c2.cluster_id,
           row_number() OVER (PARTITION BY p.point_idx ORDER BY
               (SELECT sum((a.value - b.value) * (a.value - b.value))
                  FROM json_each(c2.center) a JOIN json_each(p.point) b ON b.key = a.key)
           ) AS rn
      FROM pts p, bt_bench_clusters c2)
SELECT count(DISTINCT cluster_id) AS distinct_clusters_of_20
  FROM dists WHERE rn = 1;

-- ------------------------------------------------------------------
-- Section 3: vectorizer/embed throughput
-- ------------------------------------------------------------------
-- Real, end-to-end vectorizer throughput -- backfilling 50 rows
-- through your configured embedding endpoint. This number reflects
-- your embedding endpoint's own latency as much as FractalSQL's.
-- Without an endpoint configured, process_queue() marks the rows
-- failed with a clean last_error (see demo-vectorizer.sql) and the
-- timing is only meaningful with one configured.
--
-- The registry/queue are TEMP objects (per connection), so a fresh
-- invocation starts clean with no teardown needed; the conditional
-- spool guard below is only for a re-run inside the SAME session.

.print
.print === Section 3: vectorizer/embed throughput ===

.timer off
.once bt_bench_teardown.sql
SELECT 'SELECT fractal_vectorizer_drop(id) FROM fractal_vectorizers
     WHERE source_table = ''bt_bench_docs'';'
 WHERE EXISTS (SELECT 1 FROM sqlite_temp_master
                WHERE name = 'fractal_vectorizers');
.read bt_bench_teardown.sql
.timer on

DROP TABLE IF EXISTS bt_bench_docs;
CREATE TABLE bt_bench_docs (id INTEGER PRIMARY KEY, body TEXT NOT NULL, embedding BLOB);
WITH RECURSIVE gs(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM gs WHERE n < 50)
INSERT INTO bt_bench_docs (body)
SELECT 'benchmark document number ' || n || ': FractalSQL runs vector search directly inside the SQLite host process.'
FROM gs;

SELECT fractal_vectorizer_create('bt_bench_docs', 'body', 'embedding');

.print
.print Processing 50 rows through the vectorizer (this timing includes
.print real network calls to your embedding endpoint):
SELECT fractal_vectorizer_process_queue();

.print
.print ================================================================
.print Benchmark complete. Tables left in place for inspection --
.print safe to re-run this script any time. Clean up with:
.print   SELECT fractal_vectorizer_drop(<id from fractal_vectorizer_status>);
.print   DROP TABLE bt_bench_docs, bt_bench_corpus, bt_bench_clusters;
.print (bt_bench_teardown.sql is Section 3's spool file in the current
.print directory -- overwritten each run, delete whenever.)
.print ================================================================