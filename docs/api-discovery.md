<p align="center">
  <img src="../FractalSQLforSQLite.jpg" alt="FractalSQL for SQLite" width="720">
</p>

# Discovery API Reference

The Discovery tier provides high-precision and diverse retrieval mechanisms. Unlike traditional vector search, it treats the embedding space as a continuous optimization problem.

> **SQLite conventions for this page.** Vector arguments arrive as **TEXT**
> — a CSV string (`'0.6,0.8,0.0,0.0'`) or a bracketed JSON array — or as a
> canonical `fractal_vector` BLOB (u16 dim LE + u16 reserved + float32
> payload; construct with `fractal_vector(dim)` / `fractal_vector_from_text()`).
> Where the server edition returned `jsonb` or a composite/set-returning
> result, the same JSON document comes back as TEXT (SQLite scalar functions
> cannot return sets; per-row results are JSON arrays in result order). All
> functions register at `.load` time — no separate install/activation step.

---

## `fractal_search`
**Sniper Mode Convergence**

Converges to the single best point minimizing cosine distance to a query over the unit box $[-1, 1]^d$. It is a precision tool for finding the absolute global minimum.

### Signature
```sql
fractal_search(
    vector  TEXT-or-BLOB,   -- stored vector (CSV/JSON text or canonical BLOB)
    query   TEXT-or-BLOB    -- the target vector to converge toward
) RETURNS REAL
```

### Arguments
| Argument | Type | Default | Range | Description |
| --- | --- | --- | --- | --- |
| `vector` | TEXT / BLOB | (Required) | — | The stored vector to score. |
| `query` | TEXT / BLOB | (Required) | — | The target vector to converge toward. |

*SQLite difference:* the `iterations` / `population_size` / `diffusion_factor` tuning arguments are fixed at their SFS defaults here (`fractal_search` is a per-row scalar run once per distinct query per scan). Use `fractal_search_debug(query, ...)` when you need the tunable form.

---

## `fractal_search_debug`
**Sniper Mode with Trajectory Trace**

Same convergence as `fractal_search`, but returns a detailed trace of the process, with the full tuning arguments intact.

### Signature
```sql
fractal_search_debug(
    query            TEXT-or-BLOB,
    iterations       INTEGER DEFAULT 30,
    population_size  INTEGER DEFAULT 50,
    diffusion_factor INTEGER DEFAULT 2
) RETURNS TEXT (JSON)   -- 1 to 4 args
```

### Return Value
Returns a JSON document (TEXT) with the following keys:
- `dim`: Vector dimensionality.
- `generations`: Total iterations run.
- `population_size`: Particles per generation.
- `best_point`: The final converged vector.
- `best_fit`: Final cosine distance.
- `best_fit_per_gen`: Array of best fits across all generations.
- `paths`: Full particle trajectories for visualization.

---

## `fractal_search_explore`
**Scout Discovery Mode**

Scans a stored corpus and returns a diverse population of results. It uses a brute-force relevance scan followed by **Maximal Marginal Relevance (MMR)** to prevent "mode collapse."

*SQLite difference:* the server edition's `fractal_search_explore(table_name, vector_col, query, options)` set-returning function becomes the **aggregate** `fractal_search_explore(emb, query[, params])` — you scan your own column and the aggregate folds the whole Scout population into one JSON result.

### Signature
```sql
fractal_search_explore(
    emb     TEXT-or-BLOB,       -- aggregate over your embedding column
    query   TEXT-or-BLOB,
    params  TEXT DEFAULT NULL   -- JSON object of tuning parameters
) RETURNS TEXT (JSON)           -- aggregate; one row, JSON with the final SFS population
```

### Usage
```sql
SELECT fractal_search_explore(embedding, '0.6,0.8,0.0,0.0',
                       '{"population_size": 20, "iterations": 10, "walk": 0}')
FROM vectors;
```

### Options (JSON keys of `params`)
| Key | Type | Default | Range | Description |
| --- | --- | --- | --- | --- |
| `population_size` | `int` | `50` | — | Number of results to return. |
| `mmr_lambda` | `float` | `0.5` | $[0, 1]$ | Tradeoff between relevance ($1.0$) and diversity ($0.0$). Lower it when a query lands inside a dense cluster. |
| `iterations` | `int` | `15` | — | SFS generations per search. |
| `diffusion_factor` | `int` | `2` | — | SFS MDN (walk-per-particle count). |

---

## `fractal_search_telemetry`
**Ground-Truth Row Retrieval**

A deterministic primitive that returns the $K$ nearest real table rows to a query. This is the foundation for all higher-order agency functions.

### Signature
```sql
fractal_search_telemetry(
    table_name  text,
    vector_col  text,
    query       TEXT-or-BLOB,
    k           int
) RETURNS TEXT (JSON)   -- [{"doc_id":..,"distance":..}, ...] in nearest-first order
```

### Arguments
| Argument | Type | Description |
| --- | --- | --- |
| `table_name` | `text` | The table containing the embeddings. |
| `vector_col` | `text` | The CSV/JSON-TEXT or `fractal_vector` BLOB column. |
| `query` | TEXT / BLOB | The target vector. |
| `k` | `int` | Number of nearest neighbors to return. |

*SQLite difference:* `doc_id` values are the 0-indexed scan positions (`row_number() OVER (ORDER BY rowid) - 1`), not primary keys — see [api-agency.md's id-resolution note](api-agency.md#a-note-on-id-resolution).

---

## `fractal_hybrid_clinical_search`
**Cohort-Restricted Telemetry**

Wraps `fractal_search_telemetry` but restricts the search to a specific subset of documents.

### Signature
```sql
fractal_hybrid_clinical_search(
    table_name  text,
    vector_col  text,
    query       TEXT-or-BLOB,
    doc_ids     text,           -- JSON or CSV array of 0-indexed row positions
    k           int
) RETURNS TEXT (JSON)   -- [{"doc_id":..,"distance":..}, ...]
```

### Arguments
| Argument | Type | Description |
| --- | --- | --- |
| `doc_ids` | `text` | The subset of 0-indexed row positions to search, as a JSON or CSV array (e.g. `SELECT json_group_array(doc_id) FROM ...`). |

---

## `fractal_search_trajectory`
**Drift-Vector Search**

Searches near the delta between two states ($\Delta = V_{current} - V_{baseline}$) to find a matching trajectory in historical data.

### Signature
```sql
fractal_search_trajectory(
    table_name       text,
    vector_col       text,
    baseline_vector  TEXT-or-BLOB,
    current_vector   TEXT-or-BLOB,
    k                int
) RETURNS TEXT (JSON)   -- [{"doc_id":..,"distance":..}, ...]
```

### Overloads
The server edition's `float8[]` and `fractal_vector` overloads collapse into one 5-arg registration here: `fsql_vec_decode` accepts both the CSV/JSON-text and canonical-BLOB forms, and the input storage class picks the arithmetic path (BLOB pair → float32 math, otherwise double math) exactly as the server edition's two bodies did.

---

## `fractal_cross_modal_search`
**Weighted Modality Concatenation**

Searches a combined space of two different modalities (e.g., morphology and clinical data) using a weighted concatenation.

### Signature
```sql
fractal_cross_modal_search(
    table_name         text,
    vector_col         text,
    morphology_vector  TEXT-or-BLOB,
    clinical_vector    TEXT-or-BLOB,
    alpha_weight       REAL,
    k                  int
) RETURNS TEXT (JSON)   -- [{"doc_id":..,"distance":..}, ...]
```

### Arguments
| Argument | Type | Range | Description |
| --- | --- | --- | --- |
| `alpha_weight` | `REAL` | $[0, 1]$ | Weight given to the morphology vector. $(1 - \text{alpha})$ is given to the clinical vector. |

### Overloads
Accepts both the CSV/JSON-text and canonical-BLOB vector forms (see `fractal_search_trajectory` above).

---

## Stateful Diversify & Feedback

Scout Discovery (`fractal_search_explore`) is *stateless* diversity: MMR
spreads one result set within a single call. The **Diversify/Repulsion**
layer adds *stateful* diversity **across searches**: a session records which
results the user rejected, and subsequent searches actively avoid the
neighborhoods of those rejected results ("shadows"). This is the real
differentiator over plain top-K or MMR: neither of which is stateful across
searches.

The layer is **off by default** (bit-for-bit identical to v1.0 behavior); it
must be enabled per session, and it is session-scoped. Shadows do not persist
across connections.

### `fractal_diversify_enable()` / `fractal_diversify_disable()`
Turn the Diversify/Repulsion layer on or off for the current connection.
Both return SQL `NULL` (SQLite's uniform "mutator succeeded" shape).

### `fractal_diversify_set_params(params_json)`
Tunes the repulsion layer. The server edition's six named optional
arguments collapse into one **JSON object** argument here; every field is
optional — supplying only some keys keeps the core's current value for the
rest, so you only override the fields you name.

```sql
fractal_diversify_set_params(params_json TEXT)
```

| JSON key | Description |
| --- | --- |
| `window_n` | Search-context window size the repulsion layer tracks. |
| `stall_threshold` | Diversity-stall threshold below which repulsion intensifies. |
| `repulsion_sigma` | Gaussian width of each shadow's repulsion field. |
| `repulsion_weight` | Overall strength of the repulsion penalty. |
| `max_shadows_considered` | Cap on how many recorded shadows influence a search. |
| `tail_buffer_cap` | Cap on the tail buffer of recent results. |

Takes effect on the next `fractal_search` call.

### `fractal_detect_collapse()` → `REAL`
Returns the current **D_q** (diversity quotient) from the last search on this
connection's context. Low values indicate the search population has collapsed
toward a single basin. SQLite has no NaN, so "no search has run yet or
Diversify is disabled" comes back as SQL `NULL` (the same reading is also
exposed under the core name `fractal_diversify_current_dq()`).

### `fractal_explain_result()` → TEXT (JSON)
Session-level Diversify diagnostics: `{"dq":..,"diversify_enabled":..,"overhead_p99_us":..}`.
This is a session health readout, **not** a per-candidate "this result was
penalized by shadow X" trace. The core ABI does not currently expose
shadow attribution at that granularity.

### `fractal_feedback_report(result_handle, kind, dwell_ms)` → SQL `NULL`
Reports engagement on a prior search result, feeding the shadow store when
Diversify is enabled (inert otherwise). The 2-arg (no dwell) form is also
registered.

| Argument | Type | Description |
| --- | --- | --- |
| `result_handle` | `int` | The 0-based corpus row index the result came from (matches the `doc_id` returned by the telemetry search functions). |
| `kind` | `text` | One of `'dwell'`, `'positive'`, `'negative'`. Anything else raises `kind must be one of ...`. |
| `dwell_ms` | `int` | Optional dwell time in ms (omitted for a bare negative report). |

`fractal_isolate_background(result_handle)` is a convenience wrapper that
reports negative engagement with no dwell time.

### The stateful loop
The canonical usage is a feedback-driven re-search loop (exercised end to end
in `demo/demo-vertical-recommendation-search.sql`):

```sql
SELECT fractal_diversify_enable();           -- 1. turn on the repulsion layer
SELECT fractal_search_explore(emb, '0.5,0.5,0.5');  -- 2. first (diverse) search
SELECT fractal_feedback_report(0, 'negative'); -- 3. reject the top result
SELECT fractal_search_explore(emb, '0.5,0.5,0.5');  -- 4. re-search the SAME query
-- 5. confirm the rejected row's neighborhood is now avoided
SELECT fractal_explain_result();             -- -> {"dq":..,"diversify_enabled":..,...}
SELECT fractal_diversify_disable();          -- 6. turn it off when done
```
