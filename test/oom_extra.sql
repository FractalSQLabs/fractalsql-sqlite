-- test/oom_extra.sql: self-contained statements for test/oom_sweep.py (every allocation of every SELECT that calls a fractal* function is failed in turn).
-- They need no provider: chunking in every mode (UTF-8, emoji, a long text, paragraph and sentence packing), the index tier on a local table
-- (create, info, list, search with and without ids, ensure, refresh, rebuild, drop), and float32 BLOB vectors through the vector functions.
CREATE TABLE oe_docs (id INTEGER PRIMARY KEY, body TEXT, emb TEXT);
WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i < 60)
  INSERT INTO oe_docs SELECT i, 'row ' || i || ' héllo wörld ✓ ' || printf('%.*c', 40, 'x'),
    printf('%.4f,%.4f,%.4f,%.4f', 0.1 + i*0.013, 0.9 - i*0.007, (i % 7) * 0.11, (i % 5) * 0.09) FROM n;
SELECT fractal_chunk_text('abcdefghij', 4, 1, 'fixed');
SELECT fractal_chunk_text('First paragraph here.' || char(10) || char(10) || 'Second one is short.' || char(10) || char(10) || 'Third paragraph is a bit longer than the others are.', 30, 5, 'paragraph');
SELECT fractal_chunk_text('One. Two sentences! Is this three? Yes.  Four is a long one that keeps on going and going.', 30, 5, 'sentence');
SELECT fractal_chunk_text('héllo wörld ✓ 👩‍👩‍👧 🇨🇦 日本語のテキスト', 5, 1, 'fixed');
SELECT fractal_chunk_text((SELECT group_concat(body, ' ') FROM oe_docs), 200, 20, 'sentence');
SELECT fractal_chunk_text((SELECT group_concat(body, char(10) || char(10)) FROM oe_docs), 300, 30, 'paragraph');
SELECT fractal_index_create('oe_docs', 'emb', '{"vector_format":"FP32","name":"oe_ix","nlist":4}');
SELECT fractal_index_info('oe_ix');
SELECT fractal_index_list();
SELECT fractal_search('oe_docs', 'emb', (SELECT emb FROM oe_docs WHERE id = 7), 5);
SELECT fractal_search('oe_docs', 'emb', (SELECT emb FROM oe_docs WHERE id = 7), 5, '{"ids":[1,2,3,7,9]}');
SELECT fractal_index_ensure('oe_docs', 'emb');
SELECT fractal_index_refresh('oe_ix');
SELECT fractal_index_rebuild('oe_ix');
SELECT fractal_index_create('oe_docs', 'emb', '{"vector_format":"INT8","name":"oe_ix8","nlist":4}');
SELECT fractal_index_create('oe_docs', 'emb', '{"vector_format":"INT4","name":"oe_ix4","nlist":4}');
SELECT fractal_index_create('oe_docs', 'emb', '{"vector_format":"FP16","name":"oe_ix16","nlist":4}');
SELECT fractal_search('oe_docs', 'emb', (SELECT emb FROM oe_docs WHERE id = 30), 3, '{"index":"oe_ix8"}');
SELECT fractal_index_drop('oe_ix8');
SELECT fractal_vector_cosine_distance(x'0000803f0000003f', x'0000003f0000803f');
SELECT fractal_vector_to_json(x'0000803f0000003f');
SELECT fractal_vector_quantize_int8(x'0000803f0000003f');
SELECT fractal_vector_quantize_binary(x'0000803f0000003f');
SELECT fractal_vector_normalize(x'0000803f0000803f');
