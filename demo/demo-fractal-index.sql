-- demo/demo-fractal-index.sql
-- Walkthrough of the IVF index: fractal_index_create / _info (status and advice) / _list / _refresh / _rebuild / _drop, the indexed fractal_search and its ids option.
-- Self-contained: 2,000 synthetic 16-dimensional vectors in 20 clusters, no endpoint or plugin needed.
--
-- fractal_search(table, column, query, k [, options]) probes a few IVF cells instead of scanning every row, then VERIFIES
-- every candidate against the stored vectors, so the distances it returns are exact cosine distances, never approximations.
-- fractal_search_telemetry is the exact brute-force scan (ground truth); fractal_search falls back to it when no index exists.
-- (The old two-argument fractal_search(vector, query) is now fractal_sfs_converge.)
--
-- Re-runnable: the tables are dropped and recreated at the top.

.print === 1. A table of vectors (2,000 rows, 20 clusters) ===
DROP TABLE IF EXISTS idx_demo;
CREATE TABLE idx_demo(id INTEGER PRIMARY KEY, label TEXT, embedding BLOB);
WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 2000)
INSERT INTO idx_demo
SELECT i, 'row ' || i,
       fractal_vector_from_text(
         printf('%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f',
           (i % 20) * 0.37 + (abs(random()) % 1000) / 4000.0,  (i % 20) * -0.21 + (abs(random()) % 1000) / 4000.0,
           (i % 20) * 0.11 + (abs(random()) % 1000) / 4000.0,  ((i % 20) % 7) * 0.5 + (abs(random()) % 1000) / 4000.0,
           ((i % 20) % 5) * -0.4 + (abs(random()) % 1000) / 4000.0, (i % 20) * 0.05 + (abs(random()) % 1000) / 4000.0,
           ((i % 20) % 3) * 0.9 + (abs(random()) % 1000) / 4000.0,  (i % 20) * -0.09 + (abs(random()) % 1000) / 4000.0,
           ((i % 20) % 11) * 0.3 + (abs(random()) % 1000) / 4000.0, (i % 20) * 0.15 + (abs(random()) % 1000) / 4000.0,
           ((i % 20) % 4) * -0.6 + (abs(random()) % 1000) / 4000.0, (i % 20) * 0.02 + (abs(random()) % 1000) / 4000.0,
           ((i % 20) % 9) * 0.25 + (abs(random()) % 1000) / 4000.0, (i % 20) * -0.17 + (abs(random()) % 1000) / 4000.0,
           ((i % 20) % 6) * 0.35 + (abs(random()) % 1000) / 4000.0, (i % 20) * 0.08 + (abs(random()) % 1000) / 4000.0))
FROM n;
SELECT count(*) AS rows, fractal_vector_dims(embedding) AS dim FROM idx_demo LIMIT 1;

.print
.print === 2. Build an index (FP32 here so the demo recall is exact; INT8 is the default and 4x-8x smaller) ===
.print The build samples rows as queries, compares the index with exact search at nprobe 1, 2, 4 ... and stores the
.print smallest nprobe whose 95% lower bound reaches target_recall as this index's default.
SELECT fractal_index_create('idx_demo', 'embedding', '{"vector_format":"FP32","name":"idx_demo_ix","target_recall":0.95,"calibration_samples":100}');

.print
.print === 3. fractal_index_info: format, size, staleness, calibration, last search ===
SELECT json_extract(i, '$.format') AS format, json_extract(i, '$.nlist') AS cells, json_extract(i, '$.rows_indexed') AS rows_indexed,
       json_extract(i, '$.stale') AS stale, json_extract(i, '$.nprobe_default') AS default_nprobe,
       json_extract(i, '$.calibration.reaches_target') AS reaches_target
  FROM (SELECT fractal_index_info('idx_demo_ix') AS i);
.print The verdict: status is ready / stale / degraded / empty / orphaned, and advice says what to do about it (nothing yet):
SELECT json_extract(i, '$.status') AS status, json_extract(i, '$.advice') AS advice FROM (SELECT fractal_index_info('idx_demo_ix') AS i);
.print The catalog, one entry per index (use json_each to read it as rows):
SELECT json_extract(value, '$.name') AS name, json_extract(value, '$.table') AS tbl, json_extract(value, '$.format') AS format,
       json_extract(value, '$.rows') AS rows, json_extract(value, '$.status') AS status FROM json_each(fractal_index_list());

.print
.print === 4. Search: the index versus the exact scan ===
.print Same query, same distances (the index verifies every candidate), far fewer rows scanned:
SELECT json_extract(value, '$.doc_id') AS doc_id, json_extract(value, '$.distance') AS distance
  FROM json_each(fractal_search('idx_demo', 'embedding', (SELECT embedding FROM idx_demo WHERE id = 42), 5));
SELECT json_extract(value, '$.doc_id') AS doc_id, json_extract(value, '$.distance') AS exact_distance
  FROM json_each(fractal_search_telemetry('idx_demo', 'embedding', (SELECT embedding FROM idx_demo WHERE id = 42), 5));
.print The "index actually used" check (rows scanned is far below the 2,000 rows):
SELECT json_extract(i, '$.last_search.used_index') AS used_index, json_extract(i, '$.last_search.rows_scanned') AS rows_scanned,
       json_extract(i, '$.last_search.cells_probed') AS cells_probed
  FROM (SELECT fractal_index_info('idx_demo_ix') AS i);

.print
.print === 5. Rows added after the build are found; deleted rows are dropped ===
-- Delete the nearest neighbour of row 42 (rank 2; rank 1 is row 42 itself), so its absence below is visible.
DELETE FROM idx_demo WHERE id = (SELECT json_extract(value, '$.doc_id')
  FROM json_each(fractal_search('idx_demo', 'embedding', (SELECT embedding FROM idx_demo WHERE id = 42), 2)) LIMIT 1 OFFSET 1);
INSERT INTO idx_demo VALUES (9001, 'late arrival', (SELECT embedding FROM idx_demo WHERE id = 42));
INSERT INTO idx_demo SELECT 9100 + id, 'late copy ' || id, embedding FROM idx_demo WHERE id BETWEEN 100 AND 199;
SELECT json_extract(value, '$.doc_id') AS doc_id FROM json_each(fractal_search('idx_demo', 'embedding', (SELECT embedding FROM idx_demo WHERE id = 42), 3));
SELECT json_extract(i, '$.stale') AS stale, json_extract(i, '$.has_delta') AS has_delta FROM (SELECT fractal_index_info('idx_demo_ix') AS i);
.print The verdict now says what changed and what to do (the added rows are scanned exactly on every search until you refresh):
SELECT json_extract(i, '$.status') AS status, json_extract(i, '$.rows_added_since_build') AS added, json_extract(i, '$.advice') AS advice
  FROM (SELECT fractal_index_info('idx_demo_ix') AS i);

.print
.print === 6. Refresh: fold the added rows into the cells, with no retraining ===
SELECT json_extract(r, '$.added') AS added, json_extract(r, '$.rows') AS rows, json_extract(r, '$.generation') AS generation
  FROM (SELECT fractal_index_refresh('idx_demo_ix') AS r);
SELECT json_extract(i, '$.status') AS status, json_extract(i, '$.has_delta') AS has_delta, json_extract(i, '$.rows_indexed') AS rows_indexed,
       json_extract(i, '$.advice') AS advice FROM (SELECT fractal_index_info('idx_demo_ix') AS i);
.print The late arrival is now served from the cells, not by the exact delta scan:
SELECT json_extract(value, '$.doc_id') AS doc_id FROM json_each(fractal_search('idx_demo', 'embedding', (SELECT embedding FROM idx_demo WHERE id = 42), 3));
.print
.print === 6b. One call that keeps an index fit to use: fractal_index_ensure ===
.print It looks at the index on a table and column and does only what is needed (created, refreshed, rebuilt or unchanged), so it suits a setup script or a scheduled job:
SELECT fractal_index_ensure('idx_demo', 'embedding') AS ensured;

.print
.print === 7. Index plus filter in one call: the ids option ===
.print Pick the rows with ordinary SQL (here: every tenth row), pass their rowids, and search only those:
SELECT json_extract(value, '$.doc_id') AS doc_id, round(json_extract(value, '$.distance'), 6) AS distance
  FROM json_each(fractal_search('idx_demo', 'embedding', (SELECT embedding FROM idx_demo WHERE id = 42), 4,
         json_object('ids', (SELECT json_group_array(id) FROM idx_demo WHERE id % 10 = 2))));
.print Every row returned ends in 2, so the filter held; row 42 is in the set and is its own nearest neighbour.

.print
.print === 8. Rebuild (new generation, switched in atomically), then drop ===
SELECT json_extract(r, '$.generation') AS generation FROM (SELECT fractal_index_rebuild('idx_demo_ix') AS r);
SELECT json_extract(i, '$.stale') AS stale FROM (SELECT fractal_index_info('idx_demo_ix') AS i);
SELECT fractal_index_drop('idx_demo_ix') AS dropped;
.print Without an index the same call falls back to the exact scan:
SELECT json_extract(value, '$.doc_id') AS doc_id FROM json_each(fractal_search('idx_demo', 'embedding', (SELECT embedding FROM idx_demo WHERE id = 42), 3));
DROP TABLE idx_demo;
