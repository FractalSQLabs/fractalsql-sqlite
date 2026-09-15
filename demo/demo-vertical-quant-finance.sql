-- demo/demo-vertical-quant-finance.sql
--
-- Industry vertical: Quantitative Finance & Algorithmic Trading.
--
-- A cardinality-constrained portfolio problem (25 synthetic assets, a
-- 4-factor covariance model, optimize down to an 8-asset book) plus a
-- price series with a deliberate volatility regime change for DFA-based
-- regime detection -- a real, established DFA application (detecting
-- when a market series stops behaving like its own recent history).
--
-- Prerequisites: extension installed (sections 0-4 need nothing else).
-- Section 5's closing rationale call needs the reasoning plugin -- see
-- ../docs/reasoning-setup.md (per-connection fractalsql_set state, so
-- re-apply your load_fractalsql.sql snippet with -init).
--
-- Run (one invocation -- fractalsql_set state is per-connection):
--   sqlite3 -cmd ".load /usr/local/lib/sqlite3/fractalsql" ":memory:" \
--     ".read demo/demo-vertical-quant-finance.sql"
--
-- Notes:
--   * There is no seedable global RNG -- the synthetic fixtures are
--     plain random() (a signed 64-bit integer here, mapped into [0,1)
--     with (random()/2^63 + 1)/2), so the asset book differs run to
--     run; the optimizer itself stays deterministic via its seed
--     argument.
--   * mu/cov arrive as flat CSV TEXT -- same row-major n*n layout the
--     optimizer expects.
--   * The fractal_agent_regime_triage / _rebalance_sibling presets are
--     blueprint compositions over the primitives (raw dfa+drift;
--     optimizer + trajectory + reason) -- see demo-agents.sql for the
--     pattern.
--   * doc_id is the row's 0-based scan position; snapshots' rowid
--     aliases their INTEGER PRIMARY KEY id, so doc_id = id - 1 exactly
--     (rowid tables keep their physical position, so this mapping is
--     stable).
--
-- Safe to re-run: vqf_* tables are dropped and recreated each time.

.timer on

.print === 0. Sanity check: extension loaded? ===
SELECT fractalsql_edition(), fractalsql_version();

-- ------------------------------------------------------------------
-- 1. 25 synthetic assets, 4-factor covariance model (same construction
-- style as fractalsql-core's own portfolio-optimizer factor-model test
-- fixture): cov[i,j] = sum_f loadings[i,f]*loadings[j,f] + idio[i] on
-- the diagonal. mu is each asset's expected return.
-- ------------------------------------------------------------------
.print
.print === 1. 25 synthetic assets, 4-factor covariance model ===

DROP TABLE IF EXISTS vqf_assets;
DROP TABLE IF EXISTS vqf_loadings;
CREATE TABLE vqf_assets (
    asset_id INTEGER PRIMARY KEY,
    symbol   TEXT,
    mu       REAL,
    idio     REAL
);
CREATE TABLE vqf_loadings (
    asset_id  INTEGER,
    factor_id INTEGER,
    loading   REAL,
    PRIMARY KEY (asset_id, factor_id)
);

WITH RECURSIVE gs(a) AS (SELECT 1 UNION ALL SELECT a + 1 FROM gs WHERE a < 25)
INSERT INTO vqf_assets (asset_id, symbol, mu, idio)
SELECT a, 'TICK' || a,
       ((random() / 9223372036854775808.0 + 1) / 2) * 0.17 - 0.02,
       0.02 + ((random() / 9223372036854775808.0 + 1) / 2) * 0.06
FROM gs;

WITH RECURSIVE gf(f) AS (SELECT 1 UNION ALL SELECT f + 1 FROM gf WHERE f < 4)
INSERT INTO vqf_loadings (asset_id, factor_id, loading)
SELECT a.asset_id, f, ((random() / 9223372036854775808.0 + 1) / 2 - 0.5) * 0.6
FROM vqf_assets a CROSS JOIN gf;

-- Flat, row-major n*n covariance array -- exactly what
-- fractal_optimize_portfolio(mu, cov, k, seed) expects, built as
-- CSV TEXT with recursive CTEs.
DROP TABLE IF EXISTS vqf_cov_flat;
CREATE TEMP TABLE vqf_cov_flat AS
SELECT ai.asset_id AS i, aj.asset_id AS j,
       (SELECT sum(li.loading * lj.loading)
          FROM vqf_loadings li, vqf_loadings lj
         WHERE li.asset_id = ai.asset_id AND lj.asset_id = aj.asset_id
           AND li.factor_id = lj.factor_id)
       + CASE WHEN ai.asset_id = aj.asset_id THEN ai.idio ELSE 0 END AS cov_ij
FROM vqf_assets ai
CROSS JOIN vqf_assets aj;

SELECT (SELECT count(*) FROM vqf_assets) AS assets,
       (SELECT count(*) FROM vqf_cov_flat) AS cov_entries;

-- ------------------------------------------------------------------
-- 2. Cardinality-constrained Sharpe-ratio optimization: pick the best
-- 8 of 25 assets. ~28x faster than scipy differential_evolution at
-- near-equal quality on this problem class (validated separately,
-- see fractalsql-core's optimizer work) -- the one place the SFS
-- engine has a proven edge.
-- ------------------------------------------------------------------
.print
.print === 2. fractal_optimize_portfolio: best 8-of-25 asset book ===

-- The engine here IS the shipped optimizer (productized into the
-- fractal_agent_rebalance_sibling preset, composed in Section 4's
-- rebalance blueprint over the Section 4 snapshot fixture). mu/cov are
-- flat CSV: row-major n*n for cov, one mu per asset in asset_id order.
DROP TABLE IF EXISTS vqf_result;
CREATE TEMP TABLE vqf_result AS
SELECT fractal_optimize_portfolio(
    (SELECT group_concat(mu, ',')
       FROM (SELECT mu FROM vqf_assets ORDER BY asset_id)),
    (SELECT group_concat(cov_ij, ',')
       FROM (SELECT cov_ij FROM vqf_cov_flat ORDER BY i, j)),
    8, 42) AS rj;

SELECT json_extract(rj, '$.sharpe') AS sharpe FROM vqf_result;

-- The 8-book: nonzero weights (asset_id = position in the weights
-- array, 0-based -- json_each walks the array in document order).
.print --- the optimized 8-asset book ---
SELECT a.symbol, json_extract(je.value, '$') AS weight
FROM vqf_result r, json_each(r.rj, '$.weights') je
JOIN vqf_assets a ON a.asset_id = (je.key + 1)
WHERE json_extract(je.value, '$') > 1e-9
ORDER BY json_extract(je.value, '$') DESC;

-- ------------------------------------------------------------------
-- 3. A 300-point price series with a deliberate regime change at
-- t=240: range-bound (mean-reverting, stationary) for most of its
-- history, then a genuine trending run for the final 60 bars --
-- fractal_dimension_dfa's self-check pattern (white noise ~0.5, random
-- walk ~1.5) applied to something with an actual regime change baked
-- in, and fractal_dimension_drift(series, win) to detect it
-- automatically rather than eyeballing the exponent. (A pure volatility
-- rescale wouldn't work here -- the DFA exponent is scale-invariant, so
-- a variance change barely moves it; what the drift report reliably
-- flags is exactly this memory-structure change, mean reversion ->
-- trend, in the recent window.)
-- ------------------------------------------------------------------
.print
.print === 3. Price series: range-bound -> trending regime change at t=240 ===

DROP TABLE IF EXISTS vqf_price_series;
CREATE TEMP TABLE vqf_price_series AS
WITH RECURSIVE gs(t, x) AS (
    SELECT 1, (random() / 9223372036854775808.0) * 0.1
    UNION ALL
    SELECT t + 1,
           CASE WHEN t < 240 THEN (random() / 9223372036854775808.0) * 0.1
                ELSE x + (random() / 9223372036854775808.0) * 0.1 END
      FROM gs WHERE t < 300)
SELECT group_concat(printf('%.6f', x), ',') AS series FROM gs;

-- Blueprint (raw primitives): the price series' DFA exponent (long-range
-- correlation) and its drift report (regime-change detection). The
-- fractal_agent_regime_triage preset generalizes exactly this pair; the
-- composition's rationale is the section-5 closing reason call.
SELECT fractal_dimension_dfa(series) AS whole_series_alpha
  FROM vqf_price_series;
SELECT fractal_dimension_drift(series, 64) AS drift_report
  FROM vqf_price_series;
SELECT json_extract(fractal_dimension_drift(series, 64), '$.drift') > 0.5
           AS drift_detected
  FROM vqf_price_series;

-- ------------------------------------------------------------------
-- 4. fractal_search_trajectory: which of 10 historical quarterly
-- rebalance snapshots does THIS rebalance (equal-weight baseline ->
-- the optimized book from Section 2) most resemble? "What changed",
-- not "what's closest" -- the natural query shape for drift.
-- ------------------------------------------------------------------
.print
.print === 4. fractal_search_trajectory: nearest historical rebalance pattern ===

DROP TABLE IF EXISTS vqf_allocation_snapshots;
-- CSV TEXT guarded by a CHECK(fractal_vector_dims(alloc) = 25)
-- constraint: one weight per asset is a fixed, known-width vector
-- where dimension-drift protection actually matters -- a malformed
-- snapshot write (wrong field count) still raises loudly at write time.
CREATE TABLE vqf_allocation_snapshots (
    id     INTEGER PRIMARY KEY,
    quarter TEXT,
    alloc  TEXT NOT NULL CHECK (fractal_vector_dims(alloc) = 25)
);

-- The (snapshot, asset) grid in one recursive pass -- rows arrive in
-- (snapshot_id, asset_id) order, so the per-snapshot group_concat below
-- emits weights in asset order. Every row's random() call is
-- independently evaluated.
CREATE TEMP TABLE vqf_snapshot_raw AS
WITH RECURSIVE gs(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM gs WHERE n < 250)
SELECT (n - 1) / 25 + 1 AS snapshot_id,
       (n - 1) % 25 + 1 AS asset_id,
       CASE WHEN (random() / 9223372036854775808.0 + 1) / 2 < 0.35
            THEN (random() / 9223372036854775808.0 + 1) / 2
            ELSE 0 END AS raw_val
FROM gs;

CREATE TEMP TABLE vqf_snapshot_sums AS
SELECT snapshot_id, max(sum(raw_val), 1e-9) AS total
FROM vqf_snapshot_raw
GROUP BY snapshot_id;

INSERT INTO vqf_allocation_snapshots (quarter, alloc)
SELECT 'Q' || r.snapshot_id || '-hist',
       group_concat(printf('%.6f', r.raw_val / s.total), ',')
FROM vqf_snapshot_raw r
JOIN vqf_snapshot_sums s ON s.snapshot_id = r.snapshot_id
GROUP BY r.snapshot_id
ORDER BY r.snapshot_id ASC;

-- Blueprint (raw primitive): the nearest historical rebalance pattern to
-- the optimized book (equal-weight baseline -> the Section 2 optimized
-- weights, both flattened to CSV). The fractal_agent_rebalance_sibling
-- preset generalizes exactly this trajectory search (plus the optimizer
-- itself); the composition's rationale is the section-5 closing reason
-- call.
WITH w AS (SELECT je.value AS weight
             FROM vqf_result r, json_each(r.rj, '$.weights') je),
     cur AS (SELECT group_concat(weight, ',') AS csv FROM w),
     base AS (WITH RECURSIVE g(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM g WHERE i < 25)
              SELECT group_concat('0.04', ',') AS csv FROM g),
     tj AS (SELECT fractal_search_trajectory(
                    'vqf_allocation_snapshots', 'alloc',
                    (SELECT csv FROM base), (SELECT csv FROM cur), 3) AS rj)
SELECT s.quarter, json_extract(je.value, '$.distance') AS distance
FROM tj, json_each(tj.rj) je
JOIN vqf_allocation_snapshots s ON s.id - 1 = json_extract(je.value, '$.doc_id')
ORDER BY json_extract(je.value, '$.distance');

-- ------------------------------------------------------------------
-- 5. Reasoning: the regime-shift + optimized-allocation narrative the
-- presets above carry in their rationale columns closes the
-- demo as one reasoning pass over the same two facts (the Section 3
-- drift report and the Section 2/4 optimized book + its nearest
-- historical pattern). Plugin-gated: the clean hint is the expected
-- output without one.
-- ------------------------------------------------------------------
.print
.print === 5. Reasoning: regime shift + rebalance rationale ===
SELECT fractal_reason('one-line rationale tying this market regime shift to the optimized 8-asset rebalance and its nearest historical pattern');

.print
.print === Demo complete ===
.print Tables left in place for inspection. Clean up with:
.print   DROP TABLE vqf_assets, vqf_loadings, vqf_allocation_snapshots;
.print (the vqf_* TEMP tables evaporate with the connection.)
.print ================================================================