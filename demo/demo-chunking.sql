-- demo/demo-chunking.sql
-- Long text, chunked: split documents into passages, embed the passages, and answer a question from the right passages.
--
--   1. fractal_chunk_text on its own: how a text is cut (no model needed).
--   2. A vectorizer with chunk_size: the chunks go into a table and are embedded.
--   3. A question answered from one document only (meta_filter on parent_id), with the passages it was drawn from.
--   4. The same table through an index: fractal_index_ensure, then agent_use_index.
--
-- Prerequisites: extension loaded, reasoning AND embedding configured (see demo/demo-vectorizer.sql for the local-Ollama example).
-- Confirm before running:   SELECT fractal_vector_dims(fractal_embed('hello world'));
-- Safe to re-run: the demo tables are dropped and recreated.

.print === 1. How fractal_chunk_text cuts a text ===
.print --- paragraphs are packed into a chunk while it stays within the size ---
SELECT value ->> '$.no' AS no, value ->> '$.start' AS start, value ->> '$.end' AS "end", value ->> '$.text' AS chunk
  FROM json_each(fractal_chunk_text('First paragraph here.

Second one is short.

Third paragraph is a bit longer than the others are.', 40, 0));
.print --- sentences, with a long sentence cut into overlapping pieces ---
SELECT value ->> '$.no' AS no, value ->> '$.text' AS chunk
  FROM json_each(fractal_chunk_text('One. Two sentences! Is this three? Yes.  Four is a long one that keeps on going and going.', 30, 5, 'sentence'));

.print
.print === 2. A vectorizer that chunks ===
DROP TABLE IF EXISTS chunk_demo_docs_chunks;
DROP TABLE IF EXISTS chunk_demo_docs;
CREATE TABLE chunk_demo_docs (id INTEGER PRIMARY KEY, title TEXT, body TEXT);
INSERT INTO chunk_demo_docs VALUES
 (1, 'Heartbeat runbook',
  'A node that stops heartbeating is first marked suspect. The coordinator waits for three missed beats before it acts.

If the node is still silent, drain its work to the other nodes and open an incident. Do not restart it until the drain has finished, or its in-flight work is lost.

After the restart, watch the node for ten minutes. If it misses another beat, replace the hardware.'),
 (2, 'Backup runbook',
  'Backups run nightly at two in the morning. Each backup is verified by restoring it into a scratch database and comparing row counts.

A failed verification pages the on-call engineer. Never delete the previous good backup until the next one has verified.'),
 (3, 'Billing runbook',
  'Invoices are generated on the first of the month. A customer who disputes an invoice gets it frozen until the dispute is closed.');
SELECT fractal_vectorizer_create('chunk_demo_docs', 'body', 'embedding',
         '{"chunk_size": 220, "chunk_overlap": 20, "chunk_mode": "paragraph"}') AS vectorizer_id;
SELECT count(*) AS chunks_created FROM chunk_demo_docs_chunks;
SELECT fractal_vectorizer_process_queue(50) AS chunks_embedded;
SELECT parent_id, chunk_no, length(chunk_text) AS chars, fractal_vector_dims(embedding) AS dims
  FROM chunk_demo_docs_chunks ORDER BY parent_id, chunk_no;

.print
.print === 3. A question answered from one document, with the passages it used ===
.print --- the whole corpus ---
SELECT json_extract(a, '$.answer') AS answer, json_extract(a, '$.source_row_ids') AS source_row_ids, json_extract(a, '$.used_index') AS used_index
  FROM (SELECT fractal_rag_agent('What should I do before restarting a silent node?', 'chunk_demo_docs_chunks', 'embedding') AS a);
.print --- only the passages of document 1 (meta_filter) ---
SELECT json_extract(a, '$.answer') AS answer, json_extract(a, '$.source_row_ids') AS source_row_ids
  FROM (SELECT fractal_rag_agent('What should I do before restarting a silent node?', 'chunk_demo_docs_chunks', 'embedding', '{"parent_id": 1}') AS a);
.print The passages those row ids name:
SELECT c.id AS row_id, c.parent_id, c.chunk_no, substr(c.chunk_text, 1, 70) || '...' AS passage
  FROM chunk_demo_docs_chunks c
 WHERE c.id IN (SELECT value FROM json_each(json_extract(
        (SELECT fractal_rag_agent('What should I do before restarting a silent node?', 'chunk_demo_docs_chunks', 'embedding', '{"parent_id": 1}')), '$.source_row_ids')));

.print
.print === 4. The same table through an index ===
SELECT fractal_index_ensure('chunk_demo_docs_chunks', 'embedding', '{"vector_format": "FP32"}') AS ensured;
.print Calling it again changes nothing:
SELECT fractal_index_ensure('chunk_demo_docs_chunks', 'embedding') AS ensured_again;
SELECT fractal_config_set('agent_use_index', 'on');
SELECT json_extract(a, '$.used_index') AS used_index, json_extract(a, '$.source_row_ids') AS source_row_ids
  FROM (SELECT fractal_rag_agent('What should I do before restarting a silent node?', 'chunk_demo_docs_chunks', 'embedding') AS a);
SELECT fractal_config_set('agent_use_index', 'off');

.print
.print Tables left in place for inspection. Clean up with:
.print   DROP TABLE chunk_demo_docs_chunks; DROP TABLE chunk_demo_docs;
