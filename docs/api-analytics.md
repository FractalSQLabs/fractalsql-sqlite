<p align="center">
  <img src="../FractalSQLforSQLite.jpg" alt="FractalSQL for SQLite" width="720">
</p>

# Analytics API Reference

The Analytics tier provides mathematical primitives for analyzing the "shape" of data and state, turning raw vectors into structural insights.

> **SQLite array convention.** The server edition's `float8[]`/`int4[]`
> arguments arrive here as **TEXT** — a CSV string (`'0.6,0.8,0.0,0.0'`) or a
> bracketed JSON array (`'[0.6,0.8,0.0,0.0]'`) — or as a BLOB of packed
> little-endian float32 (the canonical `fractal_vector` convention).
> Where the server edition returned `jsonb`, the same JSON document comes back
> as TEXT (use SQLite's `json()` / `json_extract()` on it). These are plain
> scalar functions registered by the extension at `.load` time — no separate
> install/activation step.

---

## Fractal Dimension Analysis

### `fractal_dimension_dfa`
**Detrended Fluctuation Analysis**
Calculates the scaling exponent ($\alpha$) of a time-ordered series to distinguish between white noise, pink noise, and Brownian motion.

**Signature**: `fractal_dimension_dfa(series) RETURNS REAL` — `series` is a CSV/JSON TEXT array or packed float32 BLOB.
**Requirement**: $\ge 16$ points.

### `fractal_dimension_boxcount`
**Minkowski-Bouligand Dimension**
Measures the spatial complexity of a point cloud using box-counting.

**Signature**: `fractal_dimension_boxcount(points, dim) RETURNS REAL`
**Requirement**: $\ge 8$ points and a non-degenerate bounding box.

### `fractal_dimension_drift`
**Regime Change Detection**
Detects changes in the DFA exponent between a recent window and the baseline.

**Signature**: `fractal_dimension_drift(series, win) RETURNS TEXT (JSON)`
**Return**: `{"drift":..,"recent_alpha":..,"baseline_alpha":..}` as a JSON document.

---

## Domain-Specific Geometry

These functions take **pre-extracted geometry** (graphs, meshes, skeletons) as input.

| Function | Input | Output | Description |
| --- | --- | --- | --- |
| `fractal_vascular_network` | `node_coords`, `edges`, `arc_length` | `{mean_tortuosity, branch_density, fractal_dimension}` | Vessel network complexity. |
| `fractal_cortical_folding` | `vertices`, `faces` | `{mesh_area, hull_area, gyrification_index}` | Brain surface folding. |
| `fractal_nerve_plexus_metric` | `node_coords`, `dim`, `edges` | `{fiber_length_density, branch_density, fractal_dimension}` | Nerve fiber density. |
| `fractal_morphological_complexity` | `points`, `dim` | `{dimension, lacunarity}` | Pre-segmented mask complexity. |

---

## Portfolio Optimization

### `fractal_optimize_portfolio`
**Cardinality-Constrained Sharpe-Ratio Maximization**

Finds the best $K$ assets in a large universe without brute-force exponential cost.

**Signature**: `fractal_optimize_portfolio(mu, cov, k [, seed [, use_obl [, diffusion_mode]]]) RETURNS TEXT (JSON)` — `mu`/`cov` are flat CSV/JSON TEXT or float32 BLOB arrays (`cov` flattened row-major); omitted trailing arguments take the server edition's defaults exactly (the function is registered at several arities).
**Return**: `{"sharpe":..,"weights":[..]}`.
**`use_obl`**: apply Opposition-Based Learning to each SFS trial candidate. Also evaluate its bound-reflected opposite and keep whichever fits better. Off by default; doubles the fitness-eval cost of the affected diffusion step when enabled.
**`diffusion_mode`**: `'gaussian'` (default, canonical SFS) or `'levy'`: substitutes a heavy-tailed Lévy-flight step (Mantegna's algorithm) for the Gaussian walk, which can help escape local optima on highly multimodal problems at the cost of occasional very large steps.

### `fractal_optimize_portfolio_multimodal`
**Enterprise tier.** Diverse-candidate variant of `fractal_optimize_portfolio`: runs `n_restarts` independent single-best searches and greedy-selects up to `n_restarts` structurally distinct candidates instead of one.

**Signature**: `fractal_optimize_portfolio_multimodal(mu, cov, k [, n_restarts [, overlap_threshold [, quality_frac [, seed [, use_obl [, diffusion_mode]]]]]]) RETURNS TEXT (JSON)`
**Return**: `{"candidates": [{"sharpe":..,"weights":[..]}, ...], "n_found":N}`.
**`overlap_threshold`**: max allowed selected-asset overlap (0.0–1.0, Jaccard-style) between any two returned candidates.
**`quality_frac`**: a candidate must reach at least `quality_frac` × the best Sharpe found to be kept.
**`use_obl`/`diffusion_mode`**: same knobs as `fractal_optimize_portfolio`, applied uniformly to every restart. Requires an enterprise core build with OBL/Lévy-flight support: errors with a clear "predates support" hint against an older `enterprise_lib` if you pass non-default values (same fallback the server edition uses — the plain symbol still serves default-args calls against an older core).

### `fractal_optimize_portfolio_multimodal_pareto`
**Enterprise tier.** Pareto-front sibling of `fractal_optimize_portfolio_multimodal`: runs the same `n_restarts` independent searches, but scores each by decomposed **(return, risk)** instead of scalar Sharpe and reduces them to a genuine non-dominated Pareto front (NSGA-II crowding-distance truncation if the front exceeds `max_front`). This is not the sharpe-threshold + asset-overlap selection the sibling above uses. Purely additive: does not change that function's selection semantics.

**Signature**: `fractal_optimize_portfolio_multimodal_pareto(mu, cov, k [, n_restarts [, max_front [, seed [, use_obl [, diffusion_mode]]]]]) RETURNS TEXT (JSON)`
**Return**: `{"candidates": [{"return":..,"risk":..,"sharpe":..,"weights":[..]}, ...], "n_found":N}`: `sharpe = return/risk` is informational, not the selection criterion.
**`max_front`**: cap on returned front size, `1 <= max_front <= n_restarts`.

---

## Named Feature Store

A generic per-item vector store for custom metadata or flagged examples.
The backing table (`fractalsql_feature_store`) is created automatically
on first use — nothing to migrate or set up beforehand.

### `fractal_store_morphology`
Upserts a vector against a `doc_id` (last-writer-wins). The vector is
stored as a canonical `fractal_vector` BLOB.

**Signature**: `fractal_store_morphology(doc_id, feature_array) RETURNS TEXT ('ok')`

### `fractal_mine_topology_negatives`
Brute-force k-NN (true Euclidean distance, ascending) scan over the
feature store. A stored row whose dimension doesn't match
`surrogate_vector`'s is skipped, not an error — the scan doesn't abort.
No index: intended for a curated store (per-item features, flagged
negative examples), not a full corpus.

**Signature**: `fractal_mine_topology_negatives(surrogate_vector, k) RETURNS TEXT (JSON)`
**Return**: `[{"doc_id":..,"distance":..}, ...]`, nearest first.
