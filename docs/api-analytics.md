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

## Time-Series and Topology

### `fractal_change_point_detect`
**Change-Point Localization**
DFA's complement: localizes *where* a series' mean and/or variance shifted, instead of only characterizing its overall scaling behavior.

**Signature**: `fractal_change_point_detect(series, window, threshold [, max_points]) RETURNS TEXT (JSON)` — `series` is a CSV/JSON TEXT array or packed float32 BLOB; `threshold` defaults to the server edition's 2.0 pooled-stddev units and `max_points` to 16 (the function is registered at arities 3 and 4, omitted trailing arguments take the documented defaults).
**Return**: `{"indices":[..]}` — ascending boundary indices, up to `max_points`.
Sliding two-sample test over adjacent windows of `window` samples; flags a boundary when the mean differs by more than `threshold` pooled-standard-deviation units or the variance ratio exceeds `threshold` squared. Requires at least `2 * window` points.

### `fractal_periodogram`
**Classical Periodogram**
Power at each positive Fourier frequency, computed by direct $O(n^2)$ DFT (exact, not an FFT approximation).

**Signature**: `fractal_periodogram(series [, max_peaks]) RETURNS TEXT (JSON)` — `max_peaks` defaults to 8 (arity 1 or 2).
**Return**: `{"freqs":[..],"power":[..]}` — only the `max_peaks` bins with highest power, sorted descending. Each `freqs` entry is cycles per sample in $(0, 0.5]$; `1.0/freq` is samples per cycle. Useful for network-beaconing and retry-loop cadence detection that DFA alone is blind to. Requires at least 4 points.

### `fractal_tda_persistence_diagram`
**Topological Persistence**
Topological analysis over a point cloud's Vietoris-Rips filtration, capped at 512 points.

**Signature**: `fractal_tda_persistence_diagram(points, dim, max_dim, max_thresh [, max_h0_bars]) RETURNS TEXT (JSON)` — `points` is a flat CSV/JSON TEXT array or packed float32 BLOB, `dim` points per row (`points` length must divide evenly); `max_dim` is 0 (birth/death bars only) or 1 (also computes `betti1`); `max_h0_bars` defaults to 64 (arity 4 or 5).
**Return**: `{"n_h0_bars":N,"h0_bars":[{"birth":..,"death":..},...],"betti1":N|null}`. `h0_bars` is an exact 0-dimensional persistence computation (single-linkage clustering), sorted by death ascending. `betti1` (only computed when `max_dim = 1`) is the underlying graph's cycle rank, **not** full simplicial $H_1$: it over-counts true $H_1$ whenever a filled triangle exists in the data. A full simplicial computation (what Ripser/GUDHI do via boundary-matrix reduction) is out of scope.

### `fractal_state_fingerprint`
**SimHash State Fingerprint**
Random-hyperplane SimHash (Charikar 2002): projects a state vector onto `n_bits` random hyperplanes (deterministic from `seed`) and packs the sign of each projection MSB-first into bytes.

**Signature**: `fractal_state_fingerprint(vec, n_bits [, seed]) RETURNS BLOB` — `vec` is a CSV/JSON TEXT array or packed float32 BLOB; `seed` defaults to 0.0 (arity 2 or 3). Returns `(n_bits + 7) / 8` bytes.
Two nearly-identical states collapse to the same or a very low Hamming-distance fingerprint, unlike an exact hash's all-or-nothing sensitivity to floating-point noise.

### `fractal_cycle_detect`
**Streaming Cycle Detection**
Brent's algorithm (1980) run over a stream of `fractal_state_fingerprint` outputs, fed through one detector in order.

**Signature**: `fractal_cycle_detect(fingerprints_json, n_bits [, hamming_threshold]) RETURNS TEXT (JSON)` — `fingerprints_json` is a JSON array of hex-encoded fingerprints, each `(n_bits + 7) / 8` bytes decoded (build it with e.g. `SELECT json_group_array(hex(fp)) FROM t ORDER BY t.rowid`); `hamming_threshold` defaults to 0 (arity 2 or 3).
**Return**: `{"detected":true,"cycle_len":N,"at_index":I}` (or `{"detected":false}`). `at_index` is the position in the stream where the cycle closed, `cycle_len` its length. Every fingerprint must decode to the same `n_bytes` (the `n_bits` argument sets it). The underlying detector re-arms after a closure, but this single-call convenience stops at the **first** cycle found — a caller watching for a second, independent cycle later in a longer stream re-invokes it on the later segment of the stream.

These two pair into tolerant "have I basically been in this state before" loop detection; the shipped agent engines compose them with a DFA drift check (see [api-agency.md](api-agency.md)).

---

## Vector Math and Quantization

Utilities over the `fractal_vector` BLOB type (see [vectorizer-setup.md](vectorizer-setup.md)). These accept any vector argument form `fractal_vector` accepts — the canonical packed float32 BLOB or CSV/JSON TEXT.

### `fractal_vector_lp_distance`
**Generalized $L_p$ Distance**

**Signature**: `fractal_vector_lp_distance(a, b, p) RETURNS REAL`
$(\sum_i |a_i - b_i|^p)^{1/p}$ for $p > 0$. `p = 2` matches `fractal_vector_l2_distance` mathematically but not bit-for-bit (different code path). For $0 < p < 1$ this is **not** a proper metric (the triangle inequality does not hold), so never substitute it silently for the L2 primitives as a default distance; use it explicitly where fractional-$p$ contrast at high dimensionality is wanted, such as high-dimensional genomic or embedding similarity.

### `fractal_vector_quantize_int8` / `fractal_vector_quantize_binary`
**Per-Vector Quantization**

- `fractal_vector_quantize_int8(v) RETURNS TEXT (JSON)` → `{"scale":S,"codes":[..]}`: symmetric int8 quantization, 4x compression. `codes` is one signed integer per dimension, `scale` lets the caller dequantize `v[i] ≈ codes[i] * scale`.
- `fractal_vector_quantize_binary(v) RETURNS BLOB`: 1-bit quantization, 32x compression, `(dim + 7) / 8` bytes. Bit $i$ is 1 if `v[i] >= 0`, packed MSB-first. Pairs with `fractal_vector_hamming_distance(BLOB, BLOB)` for cheap candidate filtering ahead of a full-precision L2/cosine re-rank.

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

### `fractal_optimize_subset`
**Value-Weighted k-Subset Allocation**

Generalizes `fractal_optimize_portfolio`'s cardinality-constrained search into a pluggable-objective optimizer; the SQL entry point hardcodes value-weighted allocation: maximize `sum(weight[i] * item_values[i])` subject to at most `k` of `n_items` nonzero, each `weight <= upper_bounds[i]`, weights summing to 1.0.

**Signature**: `fractal_optimize_subset(item_values, upper_bounds, k [, prev_weights [, turnover_penalty [, seed]]]) RETURNS TEXT (JSON)` — `item_values`/`upper_bounds`/`prev_weights` are CSV/JSON TEXT arrays or packed float32 BLOBs (`upper_bounds` length must match `item_values`); `turnover_penalty` defaults to 0.0 and `seed` to the shared default (arity 3–6, omitted trailing arguments take the documented defaults).
**Return**: `{"score":..,"weights":[..]}` where `score` is the achieved total value (higher is better). `prev_weights` + `turnover_penalty` (both optional) steer the search away from reallocating when set, for rebalancing use cases. Every `upper_bounds[i]` must be in `[0, 1]`, and the sum of the `k` largest `upper_bounds` must reach 1.0 or no feasible k-subset exists.

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
