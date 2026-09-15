-- demo/demo-vectorizer.sql
-- Runnable walkthrough of fractal_vectorizer_create() /
-- fractal_vectorizer_process_queue() / the fractal_vectorizer_status
-- TEMP view. See ../docs/vectorizer-setup.md for the full API
-- reference, the BYO-scheduler options, and the queue architecture.
--
-- Prerequisites: extension loaded, reasoning AND embedding configured.
-- Configuration is per-connection fractalsql_set() state -- the
-- standard way to apply it is the load_fractalsql.sql
-- snippet from the easy_install wizard, passed with -init. Local
-- Ollama example pairing a chat model with a real embedding model from
-- the same host (never reuse the chat model for embeddings -- a
-- purpose-trained model matters):
--
--   ollama pull gpt-oss:20b
--   ollama pull nomic-embed-text
--
--   SELECT fractalsql_set('reasoning_plugin',  'C:\Program Files\FractalSQL\fractalsql-reasoning-http.dll');
--   SELECT fractalsql_set('http_url',          'http://127.0.0.1:11434/v1/chat/completions');
--   SELECT fractalsql_set('http_model',        'gpt-oss:20b');
--   SELECT fractalsql_set('http_embed_url',    'http://127.0.0.1:11434/v1/embeddings');
--   SELECT fractalsql_set('http_embed_model',  'nomic-embed-text');
--   SELECT fractalsql_set('http_allow_plaintext', 'on');
--
-- Confirm before running this script:
--   SELECT fractal_vector_to_json(fractal_embed('reply with a short confirmation that this connection works'));
--
-- Notes on this demo:
--   * The vectorizer registry/queue are TEMP objects visible to exactly
--     this connection, and fractal_vectorizer_status is a TEMP view
--     created alongside them (see docs/vectorizer-setup.md) -- so every
--     statement here must run in ONE sqlite3 invocation, and a prior
--     run against this database file leaves nothing behind: the
--     teardown block below is only for a re-run inside the SAME
--     session.
--   * The embedding column holds the canonical fractal_vector BLOB
--     (what the vectorizer writes) instead of float8[] -- see
--     ../docs/vectorizer-setup.md's "Storage" section.
--   * fractal_vectorizer_create(source_table, text_col, embedding_col)
--     takes NO pk argument -- the single-column primary key is
--     introspected from the table.
--
-- Run (one invocation -- the queue does not survive the connection):
--   sqlite3 mydb.sqlite -cmd ".load /usr/local/lib/sqlite3/fractalsql" \
--     ".read demo/demo-vectorizer.sql"
--
-- Without an embedding endpoint configured the flow still runs
-- end-to-end, but every queued row is marked failed with a clean
-- last_error instead of embedded -- see Section 4's status readout.

.timer on

-- Re-run guard (same-session only): on a fresh connection the TEMP
-- registry does not exist yet, so the teardown statement is spooled
-- CONDITIONALLY (only when sqlite_temp_master shows the registry) and
-- .read executes it -- an empty spool is a no-op. The drop cascades
-- this vectorizer's queue rows automatically.
.timer off
.once demo_vectorizer_teardown.sql
SELECT 'SELECT fractal_vectorizer_drop(id) FROM fractal_vectorizers
     WHERE source_table = ''docs'' AND text_col = ''body''
       AND embedding_col = ''embedding'';'
 WHERE EXISTS (SELECT 1 FROM sqlite_temp_master
                WHERE name = 'fractal_vectorizers');
.read demo_vectorizer_teardown.sql
.timer on

DROP TABLE IF EXISTS docs;

CREATE TABLE docs (
    id        INTEGER PRIMARY KEY,
    body      TEXT NOT NULL,
    embedding BLOB              -- canonical fractal_vector BLOB
);
-- (SQLite has no COMMENT ON; the docstring travels as a comment.)
-- docs: toy document store -- one row per short passage

.print === Section 1: some rows BEFORE the vectorizer exists ===
.print fractal_vectorizer_create() backfills existing rows automatically --
.print these three will be queued the moment it runs, no separate step needed.
INSERT INTO docs (body) VALUES
    ('FractalSQL runs Stochastic Fractal Search directly inside the SQLite host process.'),
    ('The reasoning plugin speaks the OpenAI chat-completions and embeddings shapes.'),
    ('fractal_text_to_sql never executes what it generates -- that is always separate.');

SELECT id, body FROM docs ORDER BY id ASC;

.print
.print === Section 2: create the vectorizer ===
-- Single-column PK ('id') is introspected; no pk_col argument.
SELECT fractal_vectorizer_create('docs', 'body', 'embedding');

.print
.print Backfilled queue (all 3 rows above -- none had an embedding yet):
SELECT status, count(*) FROM fractal_vectorizer_queue GROUP BY status;

.print
.print === Section 3: a NEW row after the vectorizer exists ===
.print The TEMP trigger queues it automatically -- no manual step.
INSERT INTO docs (body) VALUES
    ('Sniper Search refines a query point; Scout Mode returns a diverse population instead.');

SELECT status, count(*) FROM fractal_vectorizer_queue GROUP BY status;

.print
.print === Section 4: process the queue ===
.print This is the one function you put on a schedule (OS cron, Windows
.print Task Scheduler driving the sqlite3 CLI, your own app -- see
.print docs/vectorizer-setup.md). Running it manually here for the demo:
.print Timing includes real network calls to your embedding endpoint.
SELECT fractal_vectorizer_process_queue();

.print
.print === Section 5: check the results ===
.print fractal_vector_dims() reads the dimension out of the BLOB header.
SELECT id, body,
       embedding IS NOT NULL AS has_embedding,
       CASE WHEN embedding IS NOT NULL THEN fractal_vector_dims(embedding) END AS dim
FROM docs
ORDER BY id ASC;

.print
.print Status view -- what fractal_vectorizer_process_queue() actually did
.print (a TEMP view: monitoring happens on the same connection that
.print created the vectorizer). A row here marked failed with a
.print last_error mentioning the missing plugin means no embedding
.print endpoint was configured for this connection -- re-run with the
.print fractalsql_set block from the header applied.
SELECT vectorizer_id, source_table, status, n, last_error
FROM fractal_vectorizer_status
ORDER BY status ASC;

.print
.print === Section 6: edit a row, watch it get re-queued ===
UPDATE docs SET body = body || ' (edited)' WHERE id = 1;
SELECT status, count(*) FROM fractal_vectorizer_queue GROUP BY status;
SELECT fractal_vectorizer_process_queue();
SELECT vectorizer_id, status, n FROM fractal_vectorizer_status ORDER BY status ASC;

.print
.print ================================================================
.print Next: docs/vectorizer-setup.md for the BYO-scheduler examples --
.print nothing here ran fractal_vectorizer_process_queue() on a schedule,
.print this demo called it manually once per section.
.print
.print Clean up (fractal_vectorizer_drop() removes the TEMP trigger +
.print registry row -- its queue rows cascade automatically -- then drop
.print the table; a prior RUN leaves nothing behind at all, because the
.print registry/queue are TEMP objects private to the connection that
.print created them. This demo's top-of-file guard does exactly this on
.print every re-run):
.print   SELECT fractal_vectorizer_drop(<id from fractal_vectorizer_status above>);
.print   DROP TABLE docs;
.print
.print (demo_vectorizer_teardown.sql is the top-of-file guard's spool
.print file in the current directory -- overwritten each run, delete
.print whenever.)
.print ================================================================