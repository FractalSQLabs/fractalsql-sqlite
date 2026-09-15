#!/usr/bin/env python3
"""
bench/data_gen.py — Generate the synthetic "Island" dataset for the
head-to-head benchmark.

Creates N points in d dimensions, organized into K Gaussian clusters.
Cluster centers are placed uniformly in [-1, 1]^d; each point is sampled
from a Gaussian around its assigned center with per-component std=sigma.
Values are clipped to [-1, 1] so they fall within FractalSQL's default
search bounds.

Writes two tables in the target SQLite database file:
    bench_vectors (id INTEGER PK, cluster_id INTEGER, emb_arr TEXT
                   [, emb_fv BLOB if --with-fractal-vector])
    bench_centers (cluster_id INTEGER PK, center_arr TEXT)

emb_arr is a JSON array (fractal_search_explore's own input convention
-- see tests/test_scout.py). --with-fractal-vector adds an emb_fv
column holding the canonical fractal_vector BLOB encoding (see
src/fsql_vector.h) of the SAME underlying values, modulo the
deliberate float64->float32 narrowing -- one corpus backing a fair
storage/latency comparison in bench/vector_type_head_to_head.py.
Default off so the existing head_to_head.py run is unaffected.

Also builds a sqlite-vec `vec0` virtual table (bench_vec_index) over
the same vectors, the comparison partner for head_to_head.py. sqlite-vec
is the closest thing SQLite has to pgvector; unlike pgvector's HNSW
index, sqlite-vec's vec0 does exact brute-force KNN (SIMD-accelerated),
not approximate search -- see bench/README.md.

Usage:
    python3 bench/data_gen.py --db bench/fractalsql_bench.db \\
        --n 100000 --dim 768 --clusters 50

Defaults: 100k points, dim=128, 50 clusters.
"""

import argparse
import json
import os
import sqlite3
import struct
import sys
import time

import numpy as np
import sqlite_vec


def fractal_vector_blob(vec) -> bytes:
    """Canonical fractal_vector BLOB: uint16 dim LE, uint16 reserved=0,
    float32[dim] payload -- see src/fsql_vector.h."""
    dim = len(vec)
    return struct.pack(f"<HH{dim}f", dim, 0, *(float(x) for x in vec))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--db", default="bench/fractalsql_bench.db",
                    help="SQLite database file (default: %(default)s); "
                         "removed and recreated on each run")
    ap.add_argument("--ext", default=os.environ.get("FRACTALSQL_EXT", "fractalsql.so"),
                    help="path to the built fractalsql extension "
                         "(default: %(default)s, or $FRACTALSQL_EXT)")
    ap.add_argument("--n", type=int, default=100_000,
                    help="number of points (default: %(default)s)")
    ap.add_argument("--dim", type=int, default=128,
                    help="vector dimension (default: %(default)s). Use --dim 768 "
                         "for realistic-embedding scale; note that sqlite-vec "
                         "insert time and SFS fitness cost both scale linearly "
                         "with dim.")
    ap.add_argument("--clusters", type=int, default=50,
                    help="number of Gaussian clusters (default: %(default)s)")
    ap.add_argument("--sigma", type=float, default=0.05,
                    help="per-component std of intra-cluster noise "
                         "(default: %(default)s)")
    ap.add_argument("--with-fractal-vector", action="store_true",
                    help="also add an emb_fv fractal_vector BLOB column, "
                         "for bench/vector_type_head_to_head.py "
                         "(default: off, keeps the existing head_to_head.py "
                         "run unaffected)")
    ap.add_argument("--seed", type=int, default=42,
                    help="RNG seed (default: %(default)s)")
    args = ap.parse_args()

    rng = np.random.default_rng(args.seed)

    print(f"Generating {args.n} points in R^{args.dim}, "
          f"{args.clusters} clusters, sigma={args.sigma}")
    t0 = time.perf_counter()

    # Cluster centers in [-1, 1]^dim.
    centers = rng.uniform(-1.0, 1.0, (args.clusters, args.dim))

    # Assign each point to a cluster, generate coords around the center,
    # and clip to the search box.
    labels  = rng.integers(0, args.clusters, size=args.n)
    noise   = rng.normal(0.0, args.sigma, (args.n, args.dim))
    vectors = np.clip(centers[labels] + noise, -1.0, 1.0)

    print(f"  generated in {time.perf_counter() - t0:.1f}s "
          f"({vectors.nbytes / 1e6:.1f} MB)")

    # ---- load into SQLite -----------------------------------------------
    if os.path.exists(args.db):
        os.remove(args.db)
    print(f"Creating {args.db} ...")
    conn = sqlite3.connect(args.db)
    conn.isolation_level = None  # manual BEGIN/COMMIT control below
    conn.enable_load_extension(True)
    conn.load_extension(os.path.abspath(args.ext))
    sqlite_vec.load(conn)
    conn.enable_load_extension(False)

    fv_col = ", emb_fv BLOB NOT NULL" if args.with_fractal_vector else ""
    conn.execute(f"""
        CREATE TABLE bench_vectors (
            id         INTEGER PRIMARY KEY,
            cluster_id INTEGER NOT NULL,
            emb_arr    TEXT    NOT NULL{fv_col}
        )
    """)
    conn.execute("""
        CREATE TABLE bench_centers (
            cluster_id INTEGER PRIMARY KEY,
            center_arr TEXT    NOT NULL
        )
    """)
    conn.execute(
        f"CREATE VIRTUAL TABLE bench_vec_index USING vec0("
        f"embedding float[{args.dim}], +coords TEXT)")

    print(f"  inserting {args.clusters} cluster centers ...")
    conn.executemany(
        "INSERT INTO bench_centers VALUES (?, ?)",
        [(i, json.dumps(centers[i].tolist())) for i in range(args.clusters)])

    print(f"  bulk-loading {args.n} vectors ...")
    t0 = time.perf_counter()
    conn.execute("BEGIN")
    fv_cols  = ", emb_fv" if args.with_fractal_vector else ""
    fv_qmark = ", ?" if args.with_fractal_vector else ""
    insert_sql = (f"INSERT INTO bench_vectors (id, cluster_id, emb_arr{fv_cols}) "
                  f"VALUES (?, ?, ?{fv_qmark})")
    vec_rows = []
    for i in range(args.n):
        v = vectors[i]
        coords = json.dumps([round(float(x), 6) for x in v])
        row = [i, int(labels[i]), coords]
        if args.with_fractal_vector:
            row.append(fractal_vector_blob(v))
        conn.execute(insert_sql, row)
        vec_rows.append((i, sqlite_vec.serialize_float32(v.astype(np.float32).tolist()), coords))
    conn.executemany(
        "INSERT INTO bench_vec_index (rowid, embedding, coords) VALUES (?, ?, ?)",
        vec_rows)
    conn.commit()
    print(f"    bulk load done in {time.perf_counter() - t0:.1f}s")

    n = conn.execute("SELECT count(*) FROM bench_vectors").fetchone()[0]
    k = conn.execute("SELECT count(*) FROM bench_centers").fetchone()[0]
    print(f"\nDone. bench_vectors={n} rows, bench_centers={k} rows")

    conn.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
