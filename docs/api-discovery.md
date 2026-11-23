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
**Indexed approximate nearest-neighbour search** (table-backed)

Finds the `k` nearest rows of a table to a query vector. With an index (`fractal_index_create`) it probes a few IVF cells instead of scanning every row, then **verifies** every candidate against the stored vectors: the returned distances are exact cosine distances and the order is by distance, then rowid. Without an index it falls back to the exact scan (the same distances as `fractal_search_telemetry`).

```sql
fractal_search(
    table   TEXT,     -- plain identifier
    column  TEXT,     -- the embedding column
    query   TEXT-or-BLOB,
    k       INTEGER,  -- 1 .. 1000
    options TEXT      -- optional JSON
) RETURNS TEXT (JSON)  -- [{"doc_id": <rowid>, "distance": <exact cosine distance>, "scan_pos": <rowid>}, ...]
```

| Option | Default | Description |
| --- | --- | --- |
| `index` | the index on (table, column) | Index name when a column has more than one. |
| `nprobe` | calibrated at build time (16 if none) | Cells probed. More cells: higher recall, more rows scanned. |
| `rerank` | INT8 30, INT4 40, FP16/FP32 0 | Candidates fetched and verified (never below k+5). |
| `use_index` | `true` | `false` forces the exact scan. |
| `verify` | `true` | For FP16/FP32, verify the top k+5 candidates against the table. |
| `model` | none | Refuses the search when it differs from the model the index was built for. |
| `ids` | none | Restricts the search to a set of rowids, a JSON array such as `json_group_array(rowid)` over an ordinary `WHERE`: `{"ids":[5,77,100]}`. Rowids that are not rows are ignored. See below. |

Rows added after the build (rowid above the index's `max_rowid`) are scanned exactly and merged; rows deleted since the build are dropped by the verify step; a vector that was *changed* in place is only picked up by `fractal_index_rebuild` (`fractal_index_info` reports `stale`). Indexed search does not apply Diversify repulsion; use `fractal_search_telemetry` for stateful diversity.

**Restricting a search to a set of rows (`ids`).** This is the one-call form of "index plus filter": compute the allowed rowids with ordinary SQL, then pass them in.

```sql
SELECT fractal_search('docs', 'embedding', :query, 5,
         json_object('ids', (SELECT json_group_array(rowid) FROM docs WHERE tenant = 'acme')));
```

A short set (up to 4096 rowids), or a table with no index, is scanned exactly: only those rows are read, so the answer is the true nearest of the set. A longer set goes through the index and is filtered, which keeps it fast on a big table; if that leaves fewer than `k` rows, the set is scanned exactly, so the answer is never short just because the index's shortlist missed the set. Every distance is exact either way, and `fractal_index_info`'s `last_search.used_index` says which path ran. A malformed `ids` (not a JSON array of integers) is an error; an empty array returns no rows.

> **Renamed:** the old two-argument scalar `fractal_search(vector, query)` is now `fractal_sfs_converge` (no alias). Calling the old form raises an error that says so.

---

## `fractal_index_create` / `_rebuild` / `_refresh` / `_ensure` / `_drop` / `_info` / `_list`
**IVF index management**

```sql
fractal_index_create(table, column [, options]) RETURNS TEXT (JSON)  -- build and store an index
fractal_index_rebuild(name)                    RETURNS TEXT (JSON)  -- full re-cluster, same options, new generation
fractal_index_refresh(name)                    RETURNS TEXT (JSON)  -- fold the rows added since the build into the cells
fractal_index_ensure(table, column [, options]) RETURNS TEXT (JSON)  -- leave a fit index: build, refresh or rebuild only when needed
fractal_index_drop(name)                       RETURNS INTEGER      -- 1 when dropped
fractal_index_info(name)                       RETURNS TEXT (JSON)  -- format, rows, staleness, status, advice, calibration, last search
fractal_index_list()                           RETURNS TEXT (JSON)  -- one entry per index
```

`fractal_index_create` options: `name` (default `<table>_<column>`), `vector_format` (`INT8` default, `INT4`, `FP16`, `FP32`), `nlist` (cells; default sqrt(rows)), `pca_dim` (INT8/INT4 code width; default dim/4, at least 8), `target_recall` (default 0.95) and `calibration_samples` (default 200; 0 skips), `model` (the embedding model's name, checked on search), `seed`.

| Format | Code per row | Notes |
| --- | --- | --- |
| `INT8` (default) | `pca_dim` bytes (int8 residual on a PCA basis) | 4x smaller than FP32 at `pca_dim = dim/4`; shortlist of 30 verified against the table |
| `INT4` | `pca_dim / 2` bytes | most compact; shortlist of 40 |
| `FP16` | `2 * dim` bytes | no quantisation loss beyond half precision |
| `FP32` | `4 * dim` bytes | the normalised vector itself |

The build samples rows as queries (each left out of its own ground truth), compares the index with exact search at nprobe 1, 2, 4 ... and stores the smallest nprobe whose 95% lower bound reaches `target_recall` as the index's default (`fractal_index_info` shows the whole curve and whether the target was reached). A PCA basis depends on the data's spectrum: on isotropic data the default `pca_dim` can fall short of the target, and the calibration says so; raise `pca_dim` or use FP16/FP32.

**Keeping an index current.** Rows added after the build are scanned exactly and merged into every search, so an index never misses a new row, but each search pays for the unindexed rows. `fractal_index_refresh(name)` folds them into the cells: each new row is encoded with the index's existing model (nothing is retrained) and appended to its cell, in a new generation switched in atomically, and it returns `{"name", "added", "rows", "generation", "refreshed"}`. With nothing to add it changes nothing (`"refreshed": false`). A refresh does not touch deleted rows (they are already dropped from results) or rows whose vector was changed in place; and it keeps the cells the original build trained, so when a large share of the table is new, a rebuild fits the data better than a refresh does.

**Is it healthy? `fractal_index_info` and `fractal_index_list`.** `fractal_index_info(name)` carries a verdict next to the numbers:

| `status` | Meaning |
| --- | --- |
| `ready` | Nothing needs doing: the build's calibration reached its recall target and the table has not outgrown the index. A few deleted rows do not change this (they are dropped from results; `stale` is still `true` and `rows_deleted_since_build` counts them). |
| `stale` | There is something to do: rows were added since the build, or more than a fifth of the rows were deleted. |
| `degraded` | The build's own calibration did not reach its recall target (typical of INT8 or INT4 codes on tightly clustered data). |
| `empty` | The table has no vectors left. |
| `orphaned` | The table, or the vector or key column, the index was built on no longer exists (the catalog outlives it). `fractal_index_drop` removes the index. |

`advice` is a list of plain sentences, most useful first, for example `"refresh: 60 rows (10% of the index) were added since the build; fractal_index_refresh folds them in"`, `"rebuild: 30% of the rows (180) were deleted since the build; they are dropped from results but still held in the cells"` or `"the build's calibration reached recall 0.63 against a target of 0.95; rebuild with vector_format FP16 or FP32, or search with a larger rerank"`. `rows_added_since_build` and `rows_deleted_since_build` give the counts. The advice recommends a refresh while the added rows are a minor share (up to a quarter of the index) and a rebuild beyond that, or when more than a fifth of the rows were deleted. It is advice only, never an error.

`fractal_index_ensure(table, column [, options])` is for a setup script or a scheduled job: it looks at the index on that table and column and does only what is needed. It builds the index when none exists (`created`), folds in the added rows when that is all the advice asks for (`refreshed`), rebuilds when more than a quarter of the rows were added or more than a fifth deleted (`rebuilt`), and otherwise leaves it alone (`unchanged`: the status is `ready`, `empty` or `orphaned`, or it is `degraded` and you passed no new options). It returns `{"name", "action", "status", "generation", "rows"}`. The options are used only when it builds or rebuilds; pass a different `vector_format` to try again on a `degraded` index. An index whose table or column is gone is reported `orphaned` and is never recreated. It is not part of a search: a search never builds or changes an index.

`fractal_index_list()` is the catalog: a JSON array with one object per index, `{"name", "table", "column", "format", "dim", "rows", "rows_now", "stale", "status", "generation"}`, ordered by name, and `[]` when the database has none. Use `json_each` to treat it as rows: `SELECT value ->> '$.name', value ->> '$.status' FROM json_each(fractal_index_list());`.

The agents that find the nearest row (`fractal_agent_route_task`, `fractal_agent_outlier_intercept`, `fractal_agent_schedule_workload`), the cohort recall (`fractal_agent_recall_hybrid`) and the retrieval agents (`fractal_rag_agent`, `fractal_search_agent`) scan exactly by default. `agent_use_index` takes three values: `off` (the default), `on`, and `auto`. In `auto` an agent goes through an index only when the index is `ready` (nothing stale beyond a refresh), calibrated to its target recall, and the table has at least `agent_index_min_rows` rows (default 10000, set with `fractal_config_set('agent_index_min_rows', ...)`); otherwise it scans exactly. Set `fractal_config_set('agent_use_index','on')` and, when a fractal_index exists on the table and column they search, they search through it instead (the key defaults to off because an index can rarely pick a different nearest row than the exact scan; every distance is still exact).

The index lives in two ordinary tables, `fractal_index_meta` and `fractal_index_cells`, so it travels with the database file. A build writes a new generation and switches to it in one savepoint: readers never see a partial index, and a failed build leaves the previous generation serving. `fractal_index_info` reports `rows_indexed` vs `rows_now`, `stale`, `has_delta`, the calibration, and the last search's `used_index`, `rows_scanned` and `cells_probed` (the "index actually used" check).

`fractal_index_candidates(table, column, query [, options])` returns rowids for Scout: every row of the `near` (default 6) nearest cells plus `per_cell` (default 1) representatives from the others, plus rows newer than the index.

The maths (k-means, quantisers, candidate search, recall estimation) is the core's `fsql_ivf_*` functions; results are bit-identical on every platform for the same rows in the same rowid order.

---

## The precision contract

Every SQL-visible distance, norm and similarity in this host is computed by **one**
implementation (`src/fsql_precision.h`):

* the sums accumulate in **double**, in a fixed sequential order, with no fused
  multiply-add and no vectorised reduction (the files that carry a float path are built
  with `-ffp-contract=off -fno-tree-vectorize`, `/fp:precise /Qvec-` on MSVC);
* the result is returned as a **double** -- the one rounding to float32 happens only where
  a float32 result is the contract (the canonical vector text, which round-trips through
  `%.9g`);
* so every SQL-visible cosine, L2 distance, dot product and norm agrees **to the last bit**
  with each other, with the indexed search's verified distances, and with every other
  FractalSQL host;
* the cosine is bounded to **[-1, 1]** by construction, and the comparison is
  cross-platform: the same corpus and the same query give the same ranking on amd64,
  arm64, ppc64le and s390x;
* ties break on the **row id**, so the same corpus and the same query give the same
  ordering everywhere.

The Sniper convergence itself (`fractal_sfs_converge`) runs inside the core, which keeps
its own double-precision accumulation over the unit box [-1, 1]^d; the distances it reports
are the core's.

## `fractal_sfs_converge`
**SFS convergence toward a direction** (formerly `fractal_search(vector, query)`)

Runs SFS over the unit box $[-1, 1]^d$ toward the query direction and returns the cosine distance of the converged point. Because the objective is the cosine to the query itself, the optimum is the query direction rescaled into the box: read the result as a *direction to aim for*, not as a retrieval result and not as a point in your data. It demonstrates and diagnoses the SFS engine; use `fractal_search` for retrieval.

### Signature
```sql
fractal_sfs_converge(
    vector  TEXT-or-BLOB,   -- stored vector (CSV/JSON text or canonical BLOB)
    query   TEXT-or-BLOB    -- the target vector to converge toward
) RETURNS REAL
```

### Arguments
| Argument | Type | Default | Range | Description |
| --- | --- | --- | --- | --- |
| `vector` | TEXT / BLOB | (Required) | — | The stored vector to score. |
| `query` | TEXT / BLOB | (Required) | — | The target vector to converge toward. |

*SQLite difference:* the `iterations` / `population_size` / `diffusion_factor` tuning arguments are fixed at their SFS defaults here (`fractal_sfs_converge` is a per-row scalar run once per distinct query per scan). Use `fractal_sfs_converge_debug(query, ...)` when you need the tunable form.

`iterations` x `population_size` x `diffusion_factor` x the vector length must not exceed 2,147,483,648 (about a minute of work) in one call; each limit is checked on its own and then their product, and a larger search is refused.

---

## `fractal_sfs_converge_debug`
**Sniper Mode with Trajectory Trace**

Same convergence as `fractal_sfs_converge`, but returns a detailed trace of the process, with the full tuning arguments intact.

### Signature
```sql
fractal_sfs_converge_debug(
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
) RETURNS TEXT (JSON)   -- [{"doc_id":..,"distance":..,"scan_pos":..}, ...] in nearest-first order
```

### Arguments
| Argument | Type | Description |
| --- | --- | --- |
| `table_name` | `text` | The table containing the embeddings. |
| `vector_col` | `text` | The CSV/JSON-TEXT or `fractal_vector` BLOB column. |
| `query` | TEXT / BLOB | The target vector. |
| `k` | `int` | Number of nearest neighbors to return. |

*SQLite difference:* `doc_id` is the row's SQLite `rowid` — a real row
locator. Resolve back to the row with `WHERE rowid = doc_id` — see
[api-agency.md's id-resolution note](api-agency.md#a-note-on-id-resolution).

| Field | Description |
| --- | --- |
| `doc_id` | The row's SQLite `rowid`: a real row locator. Resolve back to the row with `WHERE rowid = doc_id`. |
| `distance` | Exact cosine distance from the query (brute-force scan, not approximate). Diversify/Repulsion applies if enabled on the session. |
| `scan_pos` | The raw 0-indexed position within this call's corpus scan. Distinct from `doc_id`: it identifies a result within this call (for example the `result_handle` argument of `fractal_isolate_background`), not a database row. |

**Why `doc_id` is a `rowid` and not an index.** A SQLite `rowid` is stable
under `UPDATE` (only `VACUUM` rewrites can renumber) and still resolves to the
correct row between this search and a followup lookup, unlike a 0-indexed
scan position. This is the analog of the server edition's `ctid`-based
`doc_id`.

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
    doc_ids     text,           -- JSON or CSV array of rowids
    k           int
) RETURNS TEXT (JSON)   -- [{"doc_id":..,"distance":..,"scan_pos":..}, ...]
```

### Arguments
| Argument | Type | Description |
| --- | --- | --- |
| `doc_ids` | `text` | The cohort: a JSON or CSV array of `rowid`s, computed by ordinary SQL, for example `SELECT json_group_array(rowid) FROM patients WHERE age > 65 AND condition = 'sepsis'`. Deliberately a row-id array rather than a raw SQL filter string, so no dynamic-SQL injection surface exists here. |

`doc_id`, `distance`, and `scan_pos` have the same semantics as
`fractal_search_telemetry`, with `scan_pos` counted within this call's
cohort-filtered corpus rather than the whole table. Errors with `doc_ids
cohort matched no rows` if the cohort matches zero rows.

### Example
```sql
SELECT t.doc_id, d.id, t.distance
  FROM (SELECT value AS j FROM json_each(fractal_hybrid_clinical_search(
           'patients', 'vitals',
           '0.4,0.1,0.2',
           (SELECT json_group_array(rowid)
              FROM patients WHERE age > 65 AND condition = 'sepsis'),
           5))) t,
       json_each(t.j)
  JOIN patients d ON d.rowid = json_extract(je.value, '$.doc_id');
```

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

**Note.** `doc_id` here is still the 0-indexed scan position, not the
rowid. Only `fractal_search_telemetry` and `fractal_hybrid_clinical_search`
return `doc_id` as the row's `rowid` (plus `scan_pos`).

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

**Note.** `doc_id` here is still the 0-indexed scan position, not the
rowid. Only `fractal_search_telemetry` and `fractal_hybrid_clinical_search`
return `doc_id` as the row's `rowid` (plus `scan_pos`).

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
across connections unless the enterprise tier flushes them: `fractal_ledger_flush` writes a QTL v2 snapshot (every weight, and for a shadow the lambda and sigma it was recorded with) as an audit record, and `fractal_ledger_load` replaces the in-memory ledgers with it, so a reloaded session repels exactly as the recorded one did.

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
| `tail_buffer_cap` | **Reserved.** Reserved for a future shadow-index release: the value is range-checked (1-1024) and stored, but has no effect on search or the ledger in v2.0.x. |

Takes effect on the next `fractal_sfs_converge` call.

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
| `result_handle` | `int` | The 0-based corpus row index the result came from (matches the `scan_pos` returned by the telemetry search functions, not their `doc_id`). |
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

## Which functions use the index

The `agent_use_index` setting (`off` by default; the key, GUC, module argument or property that carries it on each host is in the settings table in [Reasoning Setup](reasoning-setup.md)) decides whether the agents below search through a `fractal_index` when one covers the table and column. Every distance an indexed search returns is still exact, and rows added after the build are scanned exactly. This table lists what goes through the index and, for the rest, why not.

| Function or agent | Search it does | Index |
| --- | --- | --- |
| `fractal_search` | nearest rows, exact scan or index | Yes: this is the indexed search |
| `fractal_agent_route_task`, `fractal_agent_schedule_workload` | the nearest row | Yes, with `agent_use_index` |
| `fractal_agent_outlier_intercept` (cosine) | the nearest row | Yes, with `agent_use_index` (L2 scans exactly) |
| `fractal_search_agent`, `fractal_rag_agent` | the top rows for a question | Yes, with `agent_use_index`; a metadata filter restricts the indexed search to the matching rows |
| `fractal_agent_recall_hybrid` | the nearest rows within a cohort | Yes where the host has it and the cohort is a list of row ids: the cohort goes to the indexed search as its `ids` option (SQLite, PostgreSQL, DuckDB, MariaDB) |
| `fractal_hybrid_clinical_search` | the nearest rows within a cohort | No: exact scan of the cohort |
| `fractal_agent_rebalance_sibling`, `fractal_agent_detour_classify`, `fractal_agent_track_anomaly`, `fractal_agent_trajectory_predict`, `fractal_search_trajectory`, `fractal_agent_patient_deterioration_triage` | nearest row to a computed vector (current minus baseline) | No: exact scan. The index was tuned with queries taken from the rows themselves, and a computed query has not been measured against it |
| `fractal_cross_modal_search` | nearest rows to a combined vector | No: exact scan, for the same reason |
| `fractal_search_telemetry`, `fractal_agent_recommend_diverse`, `fractal_agent_feedback_audit` | exact scan with Diversify repulsion | No, by design: the repulsion needs every row's distance, and the indexed search does not apply it |
| `fractal_search_explore`, `fractal_agent_plan_explore` | population (Scout) search | No, by design: the search is exploratory, not nearest-row |
| `fractal_index_candidates` | a shortlist of ids from the index | It is the index; the shortlist is for a caller's own follow-up search |
| the other agents (allocate, anomaly triage, regime triage, loop detection, data analyst, SQL agent, and so on) | no vector search | Not applicable |
