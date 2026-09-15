<p align="center">
  <img src="../FractalSQLforSQLite.jpg" alt="FractalSQL for SQLite" width="720">
</p>

# Vectorizer Setup Guide

The Vectorizer is the Cognition tier's automation engine. It keeps raw text and semantic embeddings in sync automatically, so your data is always "search-ready" without external middleware or a separate ETL pipeline.

By running the embedding sync directly inside your SQLite process, FractalSQL eliminates the "data shuffle" and ensures that your semantic index is a real-time reflection of your data.

---

## Prerequisites

To enable automated embeddings, the following configuration is required (Community edition, no separate tier or license needed). There are no global config keys and no system-wide config file — configuration is **per-connection** state set with `fractalsql_set(key, value)` (the easy_install wizard's `load_fractalsql.sql` snippet, applied per session via `sqlite3 -init load_fractalsql.sql mydb.sqlite` or `.read load_fractalsql.sql`, is the standard way to apply it):

1. **Reasoning Plugin**: the `reasoning_plugin` key must point at the compiled `fractalsql-reasoning-http` plugin (`SELECT fractalsql_set('reasoning_plugin', '/usr/local/lib/sqlite3/fractalsql-reasoning-http.so');` — see [reasoning-setup.md](reasoning-setup.md)).
2. **Embeddings Endpoint**: the `http_embed_url` key must be set to your provider's **embeddings** endpoint. This is a distinct path from the chat endpoint (e.g., `/v1/embeddings` vs `/v1/chat/completions`).
3. **Embedding Model**: the `http_embed_model` key specifies the purpose-trained model. If left unset, the plugin defaults to `text-embedding-3-small`. **Important**: Never reuse a chat model for embeddings; they are mathematically distinct tasks.

**Connectivity Check**:
Confirm the embed path is active before creating a vectorizer:
```sql
SELECT fractal_vector_to_json(fractal_embed('hello world'));
--  [0.0023064255,-0.009327292,...]
```

---

## Quick Start: Automated Sync

### 1. Define your table
Store embeddings in a column holding the canonical `fractal_vector` BLOB (u16 dim LE + u16 reserved + float32 payload) instead of CSV-TEXT, so embeddings round-trip byte-exact through the vectorizer and the linear scan skips the text parse.

```sql
CREATE TABLE docs (
    id        INTEGER PRIMARY KEY,
    body      text NOT NULL,
    -- canonical fractal_vector BLOB (your model's dimension, e.g. 1536)
    embedding BLOB
);

INSERT INTO docs (body) VALUES ('first doc'), ('second doc');
```

*SQLite difference:* SQLite has no typed column of fixed width, so a `fractal_vector(n)`-style column type with built-in **dimension-drift protection** (rejecting a 384-dim vector written into a 1536-dim column) has no direct counterpart here — a wrong-width vector from a misconfigured model is stored, not rejected. Guard the width at write time instead, e.g. `CHECK (fractal_vector_dims(embedding) = 1536)`.

### 2. Create the Vectorizer
This installs an `AFTER INSERT OR UPDATE` trigger and immediately queues existing rows missing an embedding.

```sql
SELECT fractal_vectorizer_create('docs', 'body', 'embedding');
```

### 3. Process the Queue
Since FractalSQL respects your resource boundaries, it does not run a background worker. You trigger the embedding process on your own schedule (e.g., a cron job driving the `sqlite3` CLI, or a task in your application).

```sql
SELECT fractal_vectorizer_process_queue();
-- returns the number of rows processed (done + failed)
```

### 4. Monitor Progress
```sql
SELECT * FROM fractal_vectorizer_status WHERE vectorizer_id = 1;
-- vectorizer_id | source_table | text_col | embedding_col | enabled | status | n | last_failure_at | last_error
```
`fractal_vectorizer_status` is a view, not a function: one row per `(vectorizer_id, status)` pair, with the count of rows currently in that status and the most recent failure detail.

*SQLite difference:* the registry/queue are **TEMP objects** (visible to exactly this connection), and `fractal_vectorizer_status` is a TEMP view created alongside them — so monitoring happens on the same connection that created the vectorizer.

---

## Storage: CSV TEXT vs the `fractal_vector` BLOB

FractalSQL stores and searches embeddings in one of two column shapes:

- **CSV TEXT** (`'0.6,0.8,0.0,0.0'`, bracketed JSON accepted too): the plain,
  portable form — any SQLite tool can read it. But the linear scan must parse
  the string into floats for every row, and the dimension is *unchecked*: a
  TEXT column happily accepts a 384-dim vector one day and a 1536-dim vector
  the next, silently corrupting your index.
- **The canonical `fractal_vector` BLOB**: u16 dim (little-endian) + u16
  reserved + packed little-endian float32 payload. The reader validates the
  header on decode, and the dimension rides in the blob itself. Construct with
  `fractal_vector(dim)` / `fractal_vector_from_text()`; the linear scan reads
  the float32 payload directly: close to a **~2x** speedup over CSV TEXT for
  embeddings at the widths real models emit. The realized gap depends on your
  actual dimension and row count. See `bench/README.md` before treating any
  number as a promise.

Prefer the canonical BLOB whenever the embedding width is fixed by your model
(which it almost always is: `768` for `nomic-embed-text`, `1536` for
`text-embedding-3-small`, `3072` for `text-embedding-3-large`). Use CSV TEXT
only when you genuinely need human-inspectable or variable-width vectors in
one column. Unlike a fixed-width typed column enforced at the schema level, the BLOB header
does **not** enforce a column-wide fixed width — add a `CHECK
(fractal_vector_dims(embedding) = <n>)` if you want dimension-drift protection.

### Functions & helpers
The vector surface carries its own distance functions and vector arithmetic, so
a query can stay entirely in `fractal_vector` without round-tripping through
TEXT (SQLite has no custom operators — the operator syntax below maps to these
functions):

| Operator syntax elsewhere | SQLite function | Meaning |
| --- | --- | --- |
| `a <-> b` | `fractal_vector_l2_distance(a, b)` | L2 (Euclidean) distance |
| `a <=> b` | `fractal_vector_cosine_distance(a, b)` | Cosine distance |
| `a <#> b` | `fractal_vector_negative_inner_product(a, b)` | Negative inner product (for max-inner-product ranking) |
| `fractal_vector_l2_squared(a, b)` | same | Squared L2 distance (no `sqrt`, cheaper for ordering) |
| `fractal_vector_cosine_similarity(a, b)` | same | Cosine *similarity* (1 − cosine distance) |
| `fractal_vector_norm(a)` / `fractal_vector_normalize(a)` | same | L2 norm / unit vector |
| `a + b`, `a - b`, `a * s` | `fractal_vector_add(a, b)` / `fractal_vector_sub(a, b)` / `fractal_vector_scale(v, s)` | Element-wise add / subtract / scalar-multiply |
| — | `fractal_vector_dims(v)` / `fractal_vector_to_json(v)` | Dimension / JSON-array dump of a stored vector |

### Constructors
`fractal_vector(dim)` builds a zero vector; `fractal_vector_from_text(t)`
converts CSV/JSON TEXT into the canonical BLOB:

```sql
-- canonical BLOB from CSV text (also the form the vectorizer writes)
SELECT fractal_vector_from_text('1,0,0');
-- dimension of a stored vector
SELECT fractal_vector_dims(embedding) FROM docs LIMIT 1;
```

Write your embeddings through `fractal_vector_from_text()` (or read them back
with `fractal_vector_to_json()`), and a wrong-width vector fails decode with a
clean `malformed vector` error rather than silently poisoning the index. See
the dimension-mismatch assertions in `demo/demo-fractal-vector.sql`, already
adapted to this integration's real syntax (not carried over unmodified from the original port).

---

## Endpoint Providers

The Vectorizer leverages the same auth-bridge as the Cognition tier's reasoning endpoint. Credentials and region settings are shared; only the URL and model change. Each block below is the `fractalsql_set` lines to put in your per-session `load_fractalsql.sql` snippet (the `fractalsql.`-prefixed key spelling from the original edition's docs is accepted too, but the bare spelling is canonical here).

### Ollama (Local or Private Network)
Ideal for fully air-gapped deployments where data never leaves your VPC.

```sql
-- chat / text-to-sql
SELECT fractalsql_set('http_url',     'http://127.0.0.1:11434/v1/chat/completions');
SELECT fractalsql_set('http_model',   'gpt-oss:20b');
SELECT fractalsql_set('http_allow_plaintext', 'on');

-- embeddings
SELECT fractalsql_set('http_embed_url',   'http://127.0.0.1:11434/v1/embeddings');
SELECT fractalsql_set('http_embed_model', 'nomic-embed-text');
```
*Note: You must run `ollama pull nomic-embed-text` separately.*

### OpenAI-Compatible (OpenAI, Together AI, Fireworks, vLLM)
```sql
SELECT fractalsql_set('http_url',   'https://api.openai.com/v1/chat/completions');
SELECT fractalsql_set('http_token', 'sk-...');
SELECT fractalsql_set('http_model', 'gpt-4o-mini');

SELECT fractalsql_set('http_embed_url',   'https://api.openai.com/v1/embeddings');
SELECT fractalsql_set('http_embed_model', 'text-embedding-3-small');
```

### AWS Bedrock
Uses `AUTH_TYPE=aws-sigv4` via environment variables (see `docs/reasoning-setup.md`).

```sql
SELECT fractalsql_set('http_url',       'https://bedrock-runtime.us-east-1.amazonaws.com/openai/v1/chat/completions');
SELECT fractalsql_set('http_embed_url', 'https://bedrock-runtime.us-east-1.amazonaws.com/openai/v1/embeddings');
SELECT fractalsql_set('http_embed_model', 'amazon.titan-embed-text-v2:0');
```

### Azure OpenAI
Requires a **separate deployment resource** for the embedding model.

```sql
SELECT fractalsql_set('http_url',       'https://<resource>.openai.azure.com/openai/deployments/<chat-deploy>/chat/completions?api-version=2024-02-01');
SELECT fractalsql_set('http_embed_url', 'https://<resource>.openai.azure.com/openai/deployments/<embed-deploy>/embeddings?api-version=2024-02-01');
```

### Google Vertex AI
Uses the same OAuth access token as the reasoning endpoint (see
`docs/reasoning-setup.md`, Vertex AI block), only the URL and model change.
Point the embed path at the `openapi/v1/embeddings` surface of your project's
region endpoint.

```sql
SELECT fractalsql_set('http_embed_url',   'https://{LOCATION}-aiplatform.googleapis.com/v1/projects/{PROJECT}/locations/{LOCATION}/endpoints/openapi/embeddings');
SELECT fractalsql_set('http_embed_model', 'text-embedding-005');
```

---

## SQL API Reference

### `fractal_vectorizer_create(source_table, text_col, embedding_col, options DEFAULT '{}')`
Sets up the automation trigger and backfills the queue. Requires a single-column primary key. `options` is a JSON object TEXT (no explicit JSON-type cast needed — SQLite has no native binary JSON type, only TEXT).

### `fractal_vectorizer_pause(id)` / `fractal_vectorizer_resume(id)`
Toggles the `enabled` state. When paused, new writes are not queued and the processor skips existing pending rows. Raises a clean exception on a nonexistent id. Idempotent: pausing an already-paused vectorizer is a no-op.

### `fractal_vectorizer_drop(id)`
Permanently deregisters the vectorizer: drops its trigger and deletes its config/queue history (`fractal_vectorizer_queue` and `fractal_vectorizer_rate_window` rows are deleted explicitly, not via a DB-level FK cascade). Raises a clean exception on a nonexistent id. Irreversible -- for a temporary stop, use `fractal_vectorizer_pause()` instead. Needed before re-creating a vectorizer on the same `(source_table, text_col, embedding_col)`, since that triple is unique.

### `fractal_vectorizer_process_queue(batch_size DEFAULT 100, stale_after DEFAULT 600)`
The engine that drives the synchronization. Safe for concurrent execution: the claim transaction runs under `BEGIN IMMEDIATE` (SQLite's analog of the skip-locked-row claim pattern other databases use for this), with stale claims reclaimed after `stale_after` seconds — a plain seconds INTEGER here, since SQLite has no `interval` type.

### Rate Capping
To prevent provider throttling, set `options.max_embeds_per_window` (int) and `options.rate_window_secs` (default 3600) during creation. Tracked per-vectorizer in `fractal_vectorizer_rate_window`: the cap holds attempts (not just successes) within a window, and rolls over once `rate_window_secs` elapses since the window started.
```sql
SELECT fractal_vectorizer_create(
    'documents', 'body', 'embedding',
    '{"max_embeds_per_window": 500, "rate_window_secs": 3600}'
);
```

---

## Design & Safety

### The "No-Worker" Architecture
Unlike traditional extensions that spawn background workers (which can be unstable on Windows or conflict with managed cloud environments), FractalSQL uses a **pull-based queue**. You control exactly when and how often the embedder runs, making it compatible with every SQLite deployment from a laptop to an edge device.

### Crash Safety & Authorization
- **Atomic Recovery**: `process_queue` runs in a single transaction. If the process crashes mid-batch, all changes revert, and the rows remain `pending` for the next run.
- **Sovereign Authorization**: The registry/queue are connection-private TEMP objects, so a vectorizer never leaks between connections. (A `SECURITY INVOKER`-style grant check has no SQLite counterpart — there are no in-engine grants; bound the host process instead.)
- **Identifier Safety**: All table and column names are validated (alphanumerics + underscore per segment) and double-quoted before interpolation to prevent SQL injection.

---

## Known Constraints & Roadmap

- **Text Chunking**: Current version sends the full text of the column to the provider. For documents exceeding model context limits, we recommend pre-chunking into a separate "chunks" table.
- **Spend Caps**: Rate capping is based on call count, not dollar cost.
- **Automatic Retries**: Failed rows are not retried automatically; they must be reset to `pending` by the administrator.
- **Backfill Batching**: Initial backfill for very large tables (millions of rows) happens in a single transaction.

---

## When to use the Vectorizer

The Vectorizer is the right choice when you need **seamless semantic synchronization**. If your application requires that every single text update is immediately reflected in your vector index without managing external Python/Node.js workers, the Vectorizer closes that gap.

If you already have a robust external ETL pipeline, you can skip the Vectorizer and use `fractal_embed()` directly to populate your `fractal_vector` columns.
