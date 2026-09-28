-- demo/demo-vertical-biotech-genomics.sql
--
-- Industry vertical: Biotech & Genomics (structural biology / single-cell
-- transcriptomics).
--
-- A synthetic point cloud standing in for two shapes this vertical
-- actually analyzes: (a) a protein backbone's 3D atomic coordinates
-- traced through a folding trajectory, and (b) a low-dimensional
-- embedding of scRNA-seq cells (e.g. a UMAP/PCA projection) clustering
-- into two cell-type populations. Both are "does this point cloud have
-- interesting topological structure -- clusters, loops" questions, which
-- is exactly what a persistence diagram answers. Lp distance is shown
-- separately as the generic point-to-point metric this domain uses at
-- different p (L1/Manhattan for robust feature comparison, L2/Euclidean
-- for raw coordinate distance) rather than being hardcoded to one norm.
--
-- Prerequisites: extension loaded (no reasoning-plugin dependency in
-- this demo).
--
-- Run:
--   sqlite3 -cmd ".load /usr/local/lib/sqlite3/fractalsql" ":memory:" \
--     ".read demo/demo-vertical-biotech-genomics.sql"
--
-- Notes:
--   * There is no seedable global RNG -- the synthetic fixtures use
--     plain random() (a signed 64-bit integer here, mapped into [0,1)
--     with (random()/2^63 + 1)/2), so exact coordinates differ run to
--     run; the topological structure (number of clusters/loops) is
--     built to be robust to that noise.
--   * points arrives as flat, row-major CSV TEXT: [p0.x,p0.y,p0.z,
--     p1.x,p1.y,p1.z,...] for dim=3, exactly what
--     fractal_tda_persistence_diagram(points, dim, max_dim, max_thresh)
--     expects.
--
-- *** SCOPE NOTE (carried forward from fractal_tda_persistence_diagram's
-- own doc comment -- read this before treating betti1 as a full TDA
-- result): the 0-dimensional persistence diagram (h0_bars, birth/death)
-- is an EXACT, complete computation -- single-linkage clustering is
-- mathematically equivalent to 0-dim persistent homology of the
-- Vietoris-Rips filtration. betti1 (requested via max_dim=1) is the bare
-- 1-skeleton GRAPH's cycle rank, NOT full simplicial H1 of the
-- Vietoris-Rips complex -- it over-counts true H1 whenever a filled
-- triangle exists in the point cloud. A real TDA library (Ripser/GUDHI)
-- computes full H1 via boundary-matrix reduction; this primitive
-- deliberately doesn't attempt that. Treat betti1 here as "how many
-- independent cycles exist in the neighbor graph at this threshold", a
-- useful but strictly weaker signal than true H1 -- not as a drop-in
-- replacement for a real TDA library's loop count. ***
--
-- Safe to re-run: vbg_* tables are dropped and recreated each time.

.timer on

.print === 0. Sanity check: extension loaded? ===
SELECT fractalsql_edition(), fractalsql_version();

-- ------------------------------------------------------------------
-- 1. scRNA-seq-style point cloud: 60 cells in a 3D embedding, two
-- well-separated clusters (30 "T-cell-like" + 30 "B-cell-like") plus 6
-- points bridging them in a rough ring -- deliberately built so both
-- H0 (two clusters merging at some threshold) and the graph-cycle-rank
-- betti1 (the bridging ring) have real, non-degenerate structure to find.
-- ------------------------------------------------------------------
.print
.print === 1. Synthetic scRNA-seq embedding: two clusters + a bridging ring ===

DROP TABLE IF EXISTS vbg_cells;
CREATE TABLE vbg_cells (
    id       INTEGER PRIMARY KEY,
    cell_type TEXT,
    coord    TEXT NOT NULL CHECK (fractal_vector_dims(coord) = 3)
);

-- Cluster A, centered at (0,0,0). Kept small (8 points) deliberately --
-- see the betti1 note in Section 2: any cluster whose own internal
-- spread falls entirely inside the chosen threshold becomes a
-- near-complete subgraph, and a complete graph's cycle rank grows
-- combinatorially with point count (C(n,2)-(n-1)), which would swamp
-- the ring's real signal if the clusters were large.
INSERT INTO vbg_cells (cell_type, coord)
WITH RECURSIVE gs(g) AS (SELECT 1 UNION ALL SELECT g + 1 FROM gs WHERE g < 8)
SELECT 'T-cell-like',
       '[' || printf('%.4f,%.4f,%.4f',
             (random() / 9223372036854775808.0) * 0.6,
             (random() / 9223372036854775808.0) * 0.6,
             (random() / 9223372036854775808.0) * 0.6) || ']'
FROM gs;

-- Cluster B, centered at (6,6,0) -- far enough that H0 sees two
-- components at any reasonable threshold before the bridge is added.
INSERT INTO vbg_cells (cell_type, coord)
WITH RECURSIVE gs(g) AS (SELECT 1 UNION ALL SELECT g + 1 FROM gs WHERE g < 8)
SELECT 'B-cell-like',
       '[' || printf('%.4f,%.4f,%.4f',
             6.0 + (random() / 9223372036854775808.0) * 0.6,
             6.0 + (random() / 9223372036854775808.0) * 0.6,
             (random() / 9223372036854775808.0) * 0.6) || ']'
FROM gs;

-- 6-point bridging ring: a rough circle in the plane connecting the two
-- clusters, spaced so consecutive points are close (graph edges form)
-- but the ring as a whole encloses a gap -- the graph-cycle-rank source.
INSERT INTO vbg_cells (cell_type, coord)
WITH RECURSIVE gs(g) AS (SELECT 0 UNION ALL SELECT g + 1 FROM gs WHERE g < 5)
SELECT 'transitional',
       '[' || printf('%.4f,%.4f,%.4f',
             3.0 + 3.2 * cos(g * 2 * 3.14159265 / 6.0),
             3.0 + 3.2 * sin(g * 2 * 3.14159265 / 6.0),
             0.0) || ']'
FROM gs;

SELECT count(*) AS n_cells FROM vbg_cells;

-- ------------------------------------------------------------------
-- 2. fractal_tda_persistence_diagram: topology of the embedding. H0
-- bars show the clusters/ring merging into fewer components as the
-- threshold grows (a real, exact single-linkage result). max_thresh=3.3
-- is chosen just above the ring's own point spacing (~3.2) and its
-- shortest links into each cluster, so the ring bridges A and B and
-- closes its own 6-point cycle -- but stays below the much larger A-to-B
-- direct distance (~8.5), so the bridge runs through the ring, not a
-- direct shortcut.
--
-- betti1 will read noticeably higher than "1 loop": each cluster's
-- internal spread (~0.5) is well inside 3.3, so every cluster becomes a
-- near-complete subgraph on its own points, and a complete graph's cycle
-- rank grows combinatorially (C(n,2)-(n-1) per cluster) -- this is
-- exactly the scope note's over-counting behavior in practice, not a
-- bug: betti1 is the raw 1-skeleton graph's cycle rank, and a densely-
-- sampled cluster IS full of graph cycles at any threshold wide enough
-- to connect it, even though it isn't a topological "loop" in any
-- meaningful sense. A real TDA library's full H1 (via boundary-matrix
-- reduction) would correctly collapse a filled-in cluster's cycles away;
-- this primitive deliberately doesn't attempt that -- read betti1 here
-- as "how connected the neighbor graph is", not "how many real loops
-- exist in the data".
-- Citation: Edelsbrunner, H., Letscher, D., & Zomorodian, A. (2002).
-- "Topological persistence and simplification." Discrete &
-- Computational Geometry, 28(4), 511-533.
-- ------------------------------------------------------------------
.print
.print === 2. fractal_tda_persistence_diagram: cluster + loop structure ===

WITH pts AS (SELECT group_concat(coord_flat, ',') AS flat
               FROM (SELECT replace(replace(coord, '[', ''), ']', '') AS coord_flat
                       FROM vbg_cells ORDER BY id))
SELECT fractal_tda_persistence_diagram((SELECT flat FROM pts), 3, 1, 3.3, 32) AS diagram;

.print --- H0 bar count and betti1 (graph cycle rank), read separately ---
WITH pts AS (SELECT group_concat(coord_flat, ',') AS flat
               FROM (SELECT replace(replace(coord, '[', ''), ']', '') AS coord_flat
                       FROM vbg_cells ORDER BY id)),
     d AS (SELECT fractal_tda_persistence_diagram((SELECT flat FROM pts), 3, 1, 3.3, 32) AS dj)
SELECT json_extract(d.dj, '$.n_h0_bars') AS n_h0_bars,
       json_extract(d.dj, '$.betti1')    AS betti1_graph_cycle_rank
FROM d;

-- ------------------------------------------------------------------
-- 3. fractal_vector_lp_distance: pairwise distance between the two
-- cluster centroids at p=1 (Manhattan -- robust to per-feature outliers,
-- a common choice for noisy expression-derived features) and p=2
-- (Euclidean -- raw embedding distance). p must be > 0; the triangle
-- inequality only holds for p >= 1, a property of Lp spaces themselves
-- (not an approximation in this implementation) -- both values used here
-- are >= 1.
-- Lp distance is a standard, widely-used metric family, not attributed
-- to a single originating paper.
-- ------------------------------------------------------------------
.print
.print === 3. fractal_vector_lp_distance: cluster centroids, p=1 vs p=2 ===

DROP TABLE IF EXISTS vbg_centroids;
CREATE TEMP TABLE vbg_centroids AS
SELECT cell_type,
       '[' || printf('%.6f,%.6f,%.6f',
             avg(json_extract(coord, '$[0]')),
             avg(json_extract(coord, '$[1]')),
             avg(json_extract(coord, '$[2]'))) || ']' AS centroid
FROM vbg_cells
WHERE cell_type IN ('T-cell-like', 'B-cell-like')
GROUP BY cell_type;

SELECT fractal_vector_lp_distance(
           (SELECT centroid FROM vbg_centroids WHERE cell_type = 'T-cell-like'),
           (SELECT centroid FROM vbg_centroids WHERE cell_type = 'B-cell-like'),
           1.0) AS centroid_distance_l1_manhattan;
SELECT fractal_vector_lp_distance(
           (SELECT centroid FROM vbg_centroids WHERE cell_type = 'T-cell-like'),
           (SELECT centroid FROM vbg_centroids WHERE cell_type = 'B-cell-like'),
           2.0) AS centroid_distance_l2_euclidean;

.print
.print === Demo complete ===
.print Tables left in place for inspection. Clean up with:
.print   DROP TABLE vbg_cells;
.print (the vbg_* TEMP tables evaporate with the connection.)
.print ================================================================
