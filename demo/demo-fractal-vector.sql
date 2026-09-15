-- demo/demo-fractal-vector.sql
-- Runnable walkthrough of the canonical fractal_vector BLOB type
-- (u16 dim LE + u16 reserved + packed little-endian float32 payload):
-- dimension enforcement, the vectorizer writing into a guarded
-- fractal_vector column, fractal_search_trajectory's BLOB reads, and a
-- storage comparison against the same vectors in CSV-TEXT form.
-- See ../docs/vectorizer-setup.md's "Storage" section for the full
-- writeup this demo walks through interactively.
--
-- Prerequisites: extension loaded, reasoning AND embedding configured
-- -- same setup as demo/demo-vectorizer.sql (see that file's header
-- for the local-Ollama example). Confirm before running:
--   SELECT fractal_vector_to_json(fractal_embed('hello world'));
--
-- Dimension safety notes:
--   * SQLite has no typed fixed-width columns, so a wrong-width vector
--     from a misconfigured model would be STORED, not rejected. The
--     demo guards the width with a CHECK constraint instead
--     (CHECK (fractal_vector_dims(embedding) = <dim>)), which fails
--     the write with the same "malformed vector"-family hard error.
--     See docs/vectorizer-setup.md's "Storage" section.
--   * The dimension is a constant in the DDL (SQLite cannot build a
--     table from a runtime value): probe YOUR model's dimension with
--     SELECT fractal_vector_dims(fractal_embed('fractalsql dimension probe'));
--     and put it in the CHECK below (768 for nomic-embed-text, 1536
--     for text-embedding-3-small, ...), or generate the DDL from your
--     host application. This demo uses a 4-dim stand-in so the
--     mechanics run without a live endpoint; swap the CHECK and the
--     synthetic fixtures for your model's width.
--   * Distance/arithmetic is function-based, not operator-based:
--     fractal_vector_add(a, b) / fractal_vector_sub(a, b) /
--     fractal_vector_scale(v, s) for element-wise add/subtract/scalar-
--     multiply (docs/vectorizer-setup.md's function table).
--   * Use length() for a BLOB's byte size and typeof() for its storage
--     class.
--
-- Safe to re-run: the tables are dropped and recreated at the top, and
-- the vectorizer registry/queue are TEMP objects (see
-- demo-vectorizer.sql's header), guarded conditionally below.
--
-- Run:
--   sqlite3 mydb.sqlite -cmd ".load /usr/local/lib/sqlite3/fractalsql" \
--     ".read demo/demo-fractal-vector.sql"

.timer on

-- Re-run guard, same as demo-vectorizer.sql's (same-session only; on a
-- fresh connection the TEMP registry does not exist and the spool is
-- empty, so the .read below is a no-op).
.timer off
.once docs_fv_teardown.sql
SELECT 'SELECT fractal_vectorizer_drop(id) FROM fractal_vectorizers
     WHERE source_table = ''docs_fv'';'
 WHERE EXISTS (SELECT 1 FROM sqlite_temp_master
                WHERE name = 'fractal_vectorizers');
.read docs_fv_teardown.sql
.timer on

DROP TABLE IF EXISTS docs_fv;
DROP TABLE IF EXISTS docs_fv_text;

-- docs_fv: same shape as demo/demo-vectorizer.sql's docs table, but
-- embedding is the canonical fractal_vector BLOB guarded by a width
-- CHECK instead of an untyped column. (SQLite has no COMMENT ON.)
CREATE TABLE docs_fv (
    id        INTEGER PRIMARY KEY,
    body      TEXT NOT NULL,
    -- canonical fractal_vector BLOB; set the width to YOUR model's
    -- embedding dimension (768 for nomic-embed-text, 1536 for
    -- text-embedding-3-small, ...). The CHECK is what makes a
    -- dimension mismatch a hard error instead of silent corruption.
    embedding BLOB CHECK (fractal_vector_dims(embedding) = 4)
);

.print === Section 1: dimension enforcement is automatic ===
.print fractal_vectorizer_create() and process_queue() below need ZERO
.print changes from the CSV-TEXT version in demo-vectorizer.sql -- the
.print CHECK constraint alone is what makes a dimension mismatch a hard
.print error instead of silent index corruption.
INSERT INTO docs_fv (body) VALUES
    ('FractalSQL runs Stochastic Fractal Search directly inside the SQLite host process.'),
    ('The reasoning plugin speaks the OpenAI chat-completions and embeddings shapes.');

SELECT id, body FROM docs_fv ORDER BY id ASC;

.print
.print === Section 2: create the vectorizer -- exactly like the CSV-TEXT demo ===
.print With an embedding endpoint configured (see the file header),
.print process_queue() fills these rows with real model embeddings.
.print Without one, the queue marks every row failed with a clean
.print last_error -- and the synthetic stand-in vectors below keep the
.print rest of the demo runnable either way.
SELECT fractal_vectorizer_create('docs_fv', 'body', 'embedding');
SELECT fractal_vectorizer_process_queue();

SELECT id, body,
       embedding IS NOT NULL AS has_embedding,
       CASE WHEN embedding IS NOT NULL THEN fractal_vector_dims(embedding) END AS dim
FROM docs_fv
ORDER BY id ASC;

-- Stand-in fixtures so the rest of the demo runs without a live
-- endpoint (a no-op if process_queue() above already filled the rows,
-- since these two ids are exactly the ones it embedded):
UPDATE docs_fv SET embedding = fractal_vector_from_text('0.6,0.8,0.0,0.0')
 WHERE id = 1 AND embedding IS NULL;
UPDATE docs_fv SET embedding = fractal_vector_from_text('0.1,0.2,-0.3,0.4')
 WHERE id = 2 AND embedding IS NULL;

.print
.print === Section 3: the hard-fail, live ===
.print A dimension mismatch on this column fails immediately -- no separate
.print validation step, no silent truncation. The INSERT below is
.print INTENTIONAL and its error is expected output; the sqlite3 shell
.print continues past it, which is the point.
INSERT INTO docs_fv (body, embedding)
VALUES ('deliberately wrong dimension', fractal_vector_from_text('0.1,0.2'));

.print
.print === Section 4: fractal_search_trajectory over a fractal_vector column ===
.print Same function as the CSV-TEXT demos -- the linear scan reads the
.print packed float32 payload directly instead of parsing text, which is
.print where the ~2x scan speedup over CSV-TEXT comes from (see
.print docs/vectorizer-setup.md's Storage section; bench/ has the scale
.print comparison).
-- fractal_search_trajectory is a scalar function returning one JSON
-- document of {doc_id, distance} rows.
SELECT fractal_search_trajectory(
    'docs_fv', 'embedding',
    (SELECT embedding FROM docs_fv ORDER BY id LIMIT 1),
    (SELECT embedding FROM docs_fv ORDER BY id LIMIT 1),
    2
) AS trajectory;

.print
.print === Section 5: fractal_vector functions (function-based, not operators) ===
.print Exercise the vector-type surface the other demos do not reach:
.print distance is l2_distance / cosine_distance / negative_inner_product,
.print and arithmetic is _add / _sub / _scale.
SELECT
    fractal_vector_l2_distance(a.embedding, b.embedding)            AS l2_distance,
    fractal_vector_cosine_distance(a.embedding, b.embedding)        AS cosine_distance,
    fractal_vector_negative_inner_product(a.embedding, b.embedding) AS neg_inner_product,
    fractal_vector_l2_squared(a.embedding, b.embedding)             AS l2_squared,
    fractal_vector_cosine_similarity(a.embedding, b.embedding)      AS cosine_similarity,
    fractal_vector_norm(a.embedding)                                AS norm_a,
    fractal_vector_norm(b.embedding)                                AS norm_b
FROM docs_fv a, docs_fv b
WHERE a.id = 1 AND b.id = 2;

-- Arithmetic and normalize return canonical BLOBs; fractal_vector_dims
-- confirms the element count is preserved.
SELECT
    fractal_vector_dims(fractal_vector_add(a.embedding, b.embedding))       AS add_dims,
    fractal_vector_dims(fractal_vector_sub(a.embedding, b.embedding))       AS sub_dims,
    fractal_vector_dims(fractal_vector_scale(a.embedding, 2.0))             AS scale_dims,
    fractal_vector_dims(fractal_vector_normalize(a.embedding))              AS normalize_dims
FROM docs_fv a, docs_fv b
WHERE a.id = 1 AND b.id = 2;

-- fractal_vector_to_json converts BLOB -> readable JSON array, and
-- fractal_vector_from_text converts any CSV/JSON text -> BLOB.
-- typeof() reports the underlying SQLite storage class.
SELECT
    typeof(a.embedding)                            AS stored_as,
    typeof(fractal_vector_to_json(a.embedding))    AS to_json_type,
    typeof(fractal_vector_from_text(fractal_vector_to_json(a.embedding))) AS from_json_type
FROM docs_fv a
WHERE a.id = 1;

.print
.print === Section 6: storage comparison ===
.print Same vector, both column shapes, side by side.
CREATE TABLE docs_fv_text (id INTEGER PRIMARY KEY, embedding TEXT);
INSERT INTO docs_fv_text (embedding) VALUES ('0.6,0.8,0.0,0.0');

SELECT
    (SELECT length(embedding) FROM docs_fv WHERE embedding IS NOT NULL LIMIT 1)
        AS fractal_vector_blob_bytes,
    (SELECT length(embedding) FROM docs_fv_text LIMIT 1)
        AS csv_text_bytes;
.print (At real model widths the canonical BLOB wins big: packed float32
.print is ~4 bytes/dim regardless of magnitude, while CSV-TEXT spends
.print roughly 8-20 characters per float. See docs/vectorizer-setup.md's
.print Storage section, and bench/ for the same comparison at 100k-row scale.)

.print
.print ================================================================
.print Next: docs/vectorizer-setup.md's "Storage" section and
.print demo/demo-vectorizer.sql for the vectorizer walkthrough.
.print
.print This demo is re-runnable: the vectorizer guard + table drops at
.print the top tear down a prior run, no manual cleanup needed.
.print (docs_fv_teardown.sql is the guard's spool file in the current
.print directory -- overwritten each run, delete whenever.)
.print ================================================================