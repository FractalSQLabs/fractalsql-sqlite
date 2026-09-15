-- sql/load_extension.sql
--
-- Example usage for fractalsql-sqlite (Community Edition).
--
-- Load the extension. Adjust the path if your install is elsewhere.
-- Release-package install paths:
--   Debian / Ubuntu : /usr/local/lib/sqlite3/fractalsql
--   RPM-based       : /usr/local/lib/sqlite3/fractalsql
--   Windows (MSI)   : C:\Program Files\FractalSQL\fractalsql.dll
--   Local / edge    : ./fractalsql
--
-- SQLite strips the .so / .dll / .dylib suffix automatically.

.load /usr/local/lib/sqlite3/fractalsql

-- Or inside SQL:
-- SELECT load_extension('/usr/local/lib/sqlite3/fractalsql');

-- ---------------------------------------------------------------
-- Edition + version metadata.
-- ---------------------------------------------------------------
SELECT fractalsql_edition();        -- 'Community'
SELECT fractalsql_version();        -- '2.0.0'

-- ---------------------------------------------------------------
-- fractal_search(vector, query) — cosine distance between `vector`
-- and an SFS-refined projection of `query`. Per-row scalar; use it
-- in an ORDER BY + LIMIT for top-k retrieval.
-- ---------------------------------------------------------------

-- Toy table of stored vectors (CSV or BLOB accepted).
CREATE TABLE IF NOT EXISTS vectors(
    id        INTEGER PRIMARY KEY,
    embedding TEXT                    -- '0.1,0.2,-0.3,0.4'
);
INSERT INTO vectors(embedding) VALUES
    ('0.6,0.8,0.0,0.0'),
    ('0.1,0.2,-0.3,0.4'),
    ('0.9,0.1,0.0,0.0'),
    ('0.5,0.5,0.5,0.5');

-- Top 3 nearest to a query:
SELECT id, fractal_search(embedding, '0.6,0.8,0.0,0.0') AS dist
FROM vectors
ORDER BY dist
LIMIT 3;

-- The query can also be a BLOB of packed float32 — handy when the
-- application already has numpy/arrow-encoded vectors:
-- SELECT id, fractal_search(embedding, :query_blob) AS dist
-- FROM vectors ORDER BY dist LIMIT 3;
