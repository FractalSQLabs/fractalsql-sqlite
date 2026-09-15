#!/usr/bin/env python3
"""
bench/head_to_head.py — sqlite-vec vs FractalSQL Scout Mode.

sqlite-vec's vec0 virtual table is the closest thing SQLite has to
pgvector, but unlike pgvector's HNSW index it does EXACT brute-force
KNN (SIMD-accelerated, not approximate) -- see
https://github.com/asg017/sqlite-vec/issues/25. The fast/single-cluster
vs. slow/diverse story below still holds: exact top-k by distance
collapses to whichever one cluster is geometrically closest to the
query, same as an approximate index would, just without approximation
error. Label it "vec" below, not "HNSW".

Metrics
    Latency       Wall time per search, milliseconds.
    Island recall Distinct clusters (of K=50 Gaussian islands) represented
                  in the returned point set. A cluster is "discovered" if
                  at least one returned coordinate is nearest to that
                  cluster's center.

Evaluation is symmetric: for BOTH methods we take the returned coords
and map each one to its nearest cluster center. This treats vec-returned
stored vectors and Scout Mode's MMR-selected rows with the same
labeling rule, so we're not giving either side an unfair advantage from
how it handles ground-truth labels.

Usage:
    python3 bench/head_to_head.py --db bench/fractalsql_bench.db \\
        --n-queries 5 --top-k 50 --sfs-iter 8
"""

import argparse
import json
import os
import sqlite3
import sys
import time
from contextlib import contextmanager

import numpy as np
import sqlite_vec


@contextmanager
def timed():
    """Yield a callable returning elapsed ms since entry."""
    t0 = time.perf_counter()
    yield lambda: (time.perf_counter() - t0) * 1000.0


def nearest_cluster(points: np.ndarray, centers: np.ndarray) -> np.ndarray:
    """
    For each point in `points` (N x D), return the index of its nearest
    center in `centers` (K x D). Uses the ||a - b||^2 = ||a||^2 + ||b||^2
    - 2 a.b identity, computed via matrix multiply.
    """
    # pn: (N,)   cn: (K,)   ab: (N, K)
    pn = (points  * points ).sum(axis=1, keepdims=True)   # (N, 1)
    cn = (centers * centers).sum(axis=1, keepdims=True).T # (1, K)
    ab = points @ centers.T                                # (N, K)
    d2 = pn + cn - 2.0 * ab
    return np.argmin(d2, axis=1)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--db", default="bench/fractalsql_bench.db")
    ap.add_argument("--ext", default=os.environ.get("FRACTALSQL_EXT", "fractalsql.so"),
                    help="path to the built fractalsql extension "
                         "(default: %(default)s, or $FRACTALSQL_EXT)")
    ap.add_argument("--n-queries", type=int, default=5,
                    help="number of queries to average over (default: %(default)s)")
    ap.add_argument("--top-k", type=int, default=50,
                    help="#returned points per method; also SFS population_size "
                         "(default: %(default)s)")
    ap.add_argument("--sfs-iter", type=int, default=8,
                    help="SFS generations (default: %(default)s)")
    ap.add_argument("--sfs-mdn", type=int, default=2,
                    help="SFS diffusion factor (default: %(default)s)")
    ap.add_argument("--seed", type=int, default=1,
                    help="RNG seed for query selection (default: %(default)s)")
    ap.add_argument("--vector-col", default="emb_arr", choices=["emb_arr", "emb_fv"],
                    help="which bench_vectors column Scout scans: emb_arr "
                         "(JSON text, original) or emb_fv (fractal_vector BLOB, "
                         "requires data_gen.py --with-fractal-vector). The vec "
                         "arm always queries the separate bench_vec_index table "
                         "built by data_gen.py, independent of this choice "
                         "(default: %(default)s)")
    ap.add_argument("--quiet", action="store_true",
                    help="print only the final averages line (for sweep drivers)")
    args = ap.parse_args()

    conn = sqlite3.connect(args.db)
    conn.enable_load_extension(True)
    conn.load_extension(os.path.abspath(args.ext))
    sqlite_vec.load(conn)
    conn.enable_load_extension(False)

    # ----- load centers into memory (K is small) -----
    rows = conn.execute(
        "SELECT cluster_id, center_arr FROM bench_centers ORDER BY cluster_id"
    ).fetchall()
    centers = np.array([json.loads(r[1]) for r in rows], dtype=np.float64)
    K, dim = centers.shape
    n_total = conn.execute("SELECT count(*) FROM bench_vectors").fetchone()[0]

    if not args.quiet:
        print(f"Benchmark: {n_total} stored vectors, {K} clusters, dim={dim}")
        print(f"  vec: sqlite-vec brute-force KNN, k={args.top_k}")
        print(f"  Scout: population={args.top_k}, iterations={args.sfs_iter}, "
              f"mdn={args.sfs_mdn}, walk=0.0 (brute-force relevance scan + MMR), "
              f"col={args.vector_col}")
        print()

    # ----- pick queries: one per randomly chosen cluster, slightly noised -----
    rng = np.random.default_rng(args.seed)
    qci     = rng.integers(0, K, size=args.n_queries)
    queries = centers[qci] + rng.normal(0.0, 0.02, (args.n_queries, dim))
    queries = np.clip(queries, -1.0, 1.0)

    # ----- run ---------------------------------------------------------
    hdr = ("qi  anchor      |        vec ms    vec recall     |"
           "     Scout ms   Scout recall")
    if not args.quiet:
        print(hdr)
        print("-" * len(hdr))

    vec_ms_list, vec_recall_list = [], []
    sfs_ms_list, sfs_recall_list = [], []

    for qi in range(args.n_queries):
        q_anchor = int(qci[qi])
        q = queries[qi]
        q_vec32 = sqlite_vec.serialize_float32(q.astype(np.float32).tolist())
        q_json  = json.dumps(q.tolist())

        # -- sqlite-vec brute-force top-K
        with timed() as clk:
            rows = conn.execute(
                "SELECT coords FROM bench_vec_index "
                "WHERE embedding MATCH ? AND k = ? ORDER BY distance",
                (q_vec32, int(args.top_k))
            ).fetchall()
        vec_ms = clk()
        vec_pts = np.array([json.loads(r[0]) for r in rows], dtype=np.float64)
        vec_clusters = len(set(nearest_cluster(vec_pts, centers).tolist()))

        # -- FractalSQL Scout Mode
        opts = json.dumps({
            "population_size":   int(args.top_k),
            "iterations":        int(args.sfs_iter),
            "diffusion_factor":  int(args.sfs_mdn),
        })
        with timed() as clk:
            result = conn.execute(
                f"SELECT fractal_search_explore({args.vector_col}, ?, ?) "
                f"FROM bench_vectors",
                (q_json, opts)
            ).fetchone()[0]
        sfs_ms = clk()
        sfs_pts = np.array(json.loads(result)["population"], dtype=np.float64)
        sfs_clusters = len(set(nearest_cluster(sfs_pts, centers).tolist()))

        vec_ms_list.append(vec_ms);   vec_recall_list.append(vec_clusters)
        sfs_ms_list.append(sfs_ms);   sfs_recall_list.append(sfs_clusters)

        if not args.quiet:
            print(f"{qi:2d}  cluster {q_anchor:3d} | "
                  f"{vec_ms:10.1f}   {vec_clusters:4d} / {K}     | "
                  f"{sfs_ms:10.1f}   {sfs_clusters:4d} / {K}")

    lat_ratio = np.mean(sfs_ms_list) / max(np.mean(vec_ms_list), 1e-9)
    rec_ratio = np.mean(sfs_recall_list) / max(np.mean(vec_recall_list), 1e-9)
    if not args.quiet:
        print()
        print("Averages over", args.n_queries, "queries:")
        print(f"  vec:   {np.mean(vec_ms_list):>8.1f} ms   "
              f"recall {np.mean(vec_recall_list):>4.1f} / {K}")
        print(f"  Scout: {np.mean(sfs_ms_list):>8.1f} ms   "
              f"recall {np.mean(sfs_recall_list):>4.1f} / {K}")
        print(f"  Scout is {lat_ratio:.1f}x slower and discovers "
              f"{rec_ratio:.1f}x more distinct clusters")
    else:
        print(f"n={n_total:<7d} col={args.vector_col:<8s} "
              f"vec={np.mean(vec_ms_list):7.2f}ms/{np.mean(vec_recall_list):4.1f}  "
              f"Scout={np.mean(sfs_ms_list):7.2f}ms/{np.mean(sfs_recall_list):4.1f}  "
              f"({lat_ratio:.1f}x slower, {rec_ratio:.1f}x recall)")

    conn.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
