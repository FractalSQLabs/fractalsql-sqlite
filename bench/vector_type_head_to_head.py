#!/usr/bin/env python3
"""
bench/vector_type_head_to_head.py — fractal_vector BLOB vs plain JSON
TEXT storage, at data_gen.py's actual scale (100k rows / dim 128 by
default -- pass --dim 768 to data_gen.py for realistic-embedding
scale), not a hand-picked single row.

Distinct from bench/head_to_head.py (vec-vs-Scout algorithm comparison,
unrelated to storage type). Requires bench_vectors.emb_fv, i.e. run
data_gen.py --with-fractal-vector first.

Measures:
  (a) On-disk size per row, JSON TEXT vs fractal_vector BLOB, at real
      scale.
  (b) Bulk insert throughput for both column types.
  (c) fractal_search_trajectory query latency, old (JSON TEXT) vs new
      (fractal_vector BLOB) overload -- isolates the "no JSON-parse
      step" claim at scale, the one number a small demo can't
      credibly produce on its own.
  (d) Process RSS delta during a full-corpus fractal_vector scan. The
      extension runs in-process (there is no separate server to
      inspect), so this reads this same Python process's own
      /proc/self/status -- a regression tripwire for the scan loop
      actually freeing each row's decoded buffer rather than
      accumulating them.

Usage:
    python3 bench/vector_type_head_to_head.py --db bench/fractalsql_bench.db
"""

import argparse
import json
import os
import sqlite3
import struct
import sys
import time


def fractal_vector_blob(vec) -> bytes:
    """Canonical fractal_vector BLOB -- see src/fsql_vector.h."""
    dim = len(vec)
    return struct.pack(f"<HH{dim}f", dim, 0, *(float(x) for x in vec))


def read_rss_kb() -> int | None:
    """This process's own VmRSS -- None if unavailable (non-Linux)."""
    try:
        with open("/proc/self/status") as f:
            for line in f:
                if line.startswith("VmRSS:"):
                    return int(line.split()[1])  # kB
    except OSError:
        return None
    return None


def bench_storage_size(conn) -> None:
    print("\n-- (a) storage size (avg over 200 sampled rows) --")
    fv_avg, arr_avg = conn.execute("""
        SELECT avg(length(emb_fv)), avg(length(CAST(emb_arr AS BLOB)))
        FROM (SELECT emb_fv, emb_arr FROM bench_vectors
              ORDER BY random() LIMIT 200) s
    """).fetchone()
    ratio = arr_avg / fv_avg if fv_avg else float("nan")
    print(f"  fractal_vector: {fv_avg:.0f} bytes")
    print(f"  JSON TEXT     : {arr_avg:.0f} bytes")
    print(f"  ratio         : {ratio:.2f}x")
    print("  Note: JSON TEXT stores ASCII decimal digits (float64 precision, "
          "~7 bytes/coord at dim=128); fractal_vector stores raw float32 "
          "(4 bytes/coord + a 4-byte header). The gap grows with dimension "
          "and shrinks if you round-trip through a more compact text "
          "encoding -- measure on your own data before treating this as a "
          "promise.")


def bench_insert_throughput(conn, n: int, dim: int) -> None:
    print(f"\n-- (b) bulk insert throughput ({n} rows, dim={dim}) --")
    import numpy as np
    rng = np.random.default_rng(7)
    vecs = np.clip(rng.normal(0.0, 0.3, (n, dim)), -1.0, 1.0)

    for label, table, col, coltype, encode in [
        ("JSON TEXT", "_bt_ins_arr", "v", "TEXT",
         lambda v: json.dumps(v.tolist())),
        ("fractal_vector", "_bt_ins_fv", "v", "BLOB",
         fractal_vector_blob),
    ]:
        conn.execute(f"DROP TABLE IF EXISTS {table}")
        conn.execute(f"CREATE TABLE {table} (id INTEGER, {col} {coltype})")
        rows = [(i, encode(vecs[i])) for i in range(n)]
        t0 = time.perf_counter()
        conn.execute("BEGIN")
        conn.executemany(f"INSERT INTO {table} (id, {col}) VALUES (?, ?)", rows)
        conn.commit()
        elapsed = time.perf_counter() - t0
        print(f"  {label:16s}: {elapsed:.2f}s ({n / elapsed:.0f} rows/s)")
        conn.execute(f"DROP TABLE {table}")


def bench_search_latency(conn, n_queries: int) -> None:
    print("\n-- (c) fractal_search_trajectory latency: JSON TEXT vs fractal_vector overload --")
    row = conn.execute("SELECT emb_arr, emb_fv FROM bench_vectors LIMIT 1").fetchone()
    if row is None or row[1] is None:
        print("  SKIP -- bench_vectors.emb_fv is empty (run data_gen.py "
              "--with-fractal-vector first)")
        return
    baseline_arr, baseline_fv = row

    for label, col, baseline in [
        ("JSON TEXT", "emb_arr", baseline_arr),
        ("fractal_vector", "emb_fv", baseline_fv),
    ]:
        times = []
        for _ in range(n_queries):
            t0 = time.perf_counter()
            conn.execute(
                "SELECT fractal_search_trajectory("
                "'bench_vectors', ?, ?, ?, 10)",
                (col, baseline, baseline)
            ).fetchall()
            times.append((time.perf_counter() - t0) * 1000.0)
        avg = sum(times) / len(times)
        print(f"  {label:16s}: {avg:.1f} ms avg over {n_queries} queries "
              f"(min {min(times):.1f}, max {max(times):.1f})")


def bench_peak_rss(conn, n: int) -> None:
    print(f"\n-- (d) process RSS delta during a {n}-row fractal_vector scan --")
    row = conn.execute("SELECT emb_fv FROM bench_vectors LIMIT 1").fetchone()
    if row is None or row[0] is None:
        print("  SKIP -- bench_vectors.emb_fv is empty (run data_gen.py "
              "--with-fractal-vector first)")
        return
    baseline = row[0]

    rss_before = read_rss_kb()
    if rss_before is None:
        print("  SKIP -- /proc/self/status not readable (non-Linux)")
        return

    conn.execute(
        "SELECT fractal_search_trajectory("
        "'bench_vectors', 'emb_fv', ?, ?, 10)",
        (baseline, baseline)
    ).fetchall()
    rss_after = read_rss_kb()

    delta_mb = (rss_after - rss_before) / 1024.0
    print(f"  RSS before: {rss_before / 1024:.1f} MB, after: {rss_after / 1024:.1f} MB, "
          f"delta: {delta_mb:+.1f} MB (n={n} rows scanned)")
    if delta_mb > 50.0:
        print(f"  WARNING: >{50}MB growth from a single scan -- check the "
              f"fractal_vector corpus-scan path is actually freeing each "
              f"decoded row rather than accumulating them")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--db", default="bench/fractalsql_bench.db")
    ap.add_argument("--ext", default=os.environ.get("FRACTALSQL_EXT", "fractalsql.so"),
                    help="path to the built fractalsql extension "
                         "(default: %(default)s, or $FRACTALSQL_EXT)")
    ap.add_argument("--insert-n", type=int, default=20_000,
                    help="row count for the insert-throughput sub-benchmark "
                         "(default: %(default)s -- smaller than the full "
                         "corpus, this arm is O(n) by design so a subset "
                         "is representative)")
    ap.add_argument("--search-queries", type=int, default=10,
                    help="queries to average for the latency sub-benchmark "
                         "(default: %(default)s)")
    args = ap.parse_args()

    conn = sqlite3.connect(args.db)
    conn.isolation_level = None  # manual BEGIN/COMMIT control below
    conn.enable_load_extension(True)
    conn.load_extension(os.path.abspath(args.ext))
    conn.enable_load_extension(False)

    n_total, sample = conn.execute(
        "SELECT count(*), (SELECT emb_arr FROM bench_vectors LIMIT 1) FROM bench_vectors"
    ).fetchone()
    if n_total == 0:
        print("bench_vectors is empty -- run data_gen.py --with-fractal-vector first",
              file=sys.stderr)
        return 1
    dim = len(json.loads(sample))
    print(f"vector_type_head_to_head: {n_total} rows, dim={dim}")

    bench_storage_size(conn)
    bench_insert_throughput(conn, args.insert_n, dim)
    bench_search_latency(conn, args.search_queries)
    bench_peak_rss(conn, n_total)

    conn.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
