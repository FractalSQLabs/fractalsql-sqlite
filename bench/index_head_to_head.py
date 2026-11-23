#!/usr/bin/env python3
"""bench/index_head_to_head.py -- the IVF index (fractal_index_create + the indexed fractal_search) against exact search.

Contestants, all on the same table:
  exact       fractal_search_telemetry (brute-force scan, the ground truth; also what fractal_search does without an index)
  index       fractal_search over an index, for each vector_format, at the build-time calibrated nprobe and at fixed nprobe values
  vec         sqlite-vec's vec0 (exact KNN) when the sqlite_vec module is importable; skipped otherwise
For every contestant it reports recall@10 against the exact top-10, median latency per query, bytes of index per row, build seconds and
rows scanned (the "index actually used" check: below the row count). Distances returned by the index are exact (every candidate is verified).

  bench/index_head_to_head.py [--ext PATH] [--n 20000] [--dim 128] [--clusters 50] [--queries 60]
                              [--formats INT8,INT4,FP16,FP32] [--embeddings FILE.npy]   # real unit-length embeddings, generated at test time
"""
import argparse, json, os, sqlite3, statistics, struct, sys, time
import numpy as np

def blob(v):
    v = np.asarray(v, dtype="<f4"); return struct.pack("<I", v.size) + v.tobytes()

def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser()
    ap.add_argument("--ext", default=os.path.join(here, "..", "fractalsql.so"))
    ap.add_argument("--n", type=int, default=20000); ap.add_argument("--dim", type=int, default=128); ap.add_argument("--clusters", type=int, default=50)
    ap.add_argument("--queries", type=int, default=60); ap.add_argument("--formats", default="INT8,INT4,FP16,FP32")
    ap.add_argument("--embeddings"); ap.add_argument("--seed", type=int, default=7); ap.add_argument("--k", type=int, default=10)
    a = ap.parse_args(); rng = np.random.default_rng(a.seed)
    if a.embeddings: X = np.load(a.embeddings).astype(np.float32)
    else:
        cent = rng.standard_normal((a.clusters, a.dim)); X = (cent[rng.integers(0, a.clusters, a.n)] + 0.25 * rng.standard_normal((a.n, a.dim))).astype(np.float32)
    n, d = X.shape
    con = sqlite3.connect(":memory:", isolation_level=None); con.enable_load_extension(True); con.load_extension(os.path.abspath(a.ext))
    con.execute("create table t(id integer primary key, emb blob)")
    con.executemany("insert into t(id,emb) values(?,?)", ((i + 1, blob(X[i])) for i in range(n)))
    qi = rng.choice(n, size=min(a.queries, n), replace=False); Q = [blob(X[i]) for i in qi]
    print("rows %d dim %d queries %d, recall@%d against the exact top-%d" % (n, d, len(Q), a.k, a.k))
    def run(sql_args, label):
        lat = []; res = []
        for q in Q:
            t0 = time.perf_counter(); r = json.loads(con.execute("select fractal_search('t','emb',?,?,?)", (q, a.k + 1) + sql_args).fetchone()[0]); lat.append((time.perf_counter() - t0) * 1000)
            res.append([x["doc_id"] for x in r])
        return res, statistics.median(lat)
    truth, lat_exact = run(('{"use_index":false}',), "exact")
    truth = [[i for i in r if i != qi[j] + 1][:a.k] for j, r in enumerate(truth)]
    print("%-28s recall %.3f  median %7.2f ms  rows scanned %9d" % ("exact (telemetry scan)", 1.0, lat_exact, n))
    def recall(res): return sum(len(set([i for i in r if i != qi[j] + 1][:a.k]) & set(truth[j])) for j, r in enumerate(res)) / (a.k * len(res))
    try:
        import sqlite_vec  # noqa
        con.enable_load_extension(True); sqlite_vec.load(con)
        con.execute("create virtual table v using vec0(emb float[%d])" % d)
        con.executemany("insert into v(rowid, emb) values(?,?)", ((i + 1, X[i].tobytes()) for i in range(n)))
        lat = []; res = []
        for j in qi:
            t0 = time.perf_counter(); r = con.execute("select rowid from v where emb match ? and k=?", (X[j].tobytes(), a.k + 1)).fetchall(); lat.append((time.perf_counter() - t0) * 1000); res.append([x[0] for x in r])
        print("%-28s recall %.3f  median %7.2f ms  rows scanned %9d" % ("sqlite-vec vec0 (exact)", recall(res), statistics.median(lat), n))
    except Exception:
        print("%-28s skipped (pip install sqlite-vec to include it)" % "sqlite-vec vec0")
    for fmt in [f.strip().upper() for f in a.formats.split(",")]:
        t0 = time.time(); info = json.loads(con.execute("select fractal_index_create('t','emb',?)", (json.dumps({"vector_format": fmt, "name": "ix_" + fmt}),)).fetchone()[0]); build = time.time() - t0
        print("%s: nlist %d pca_dim %d, %.1f bytes/row (%.1f MB), build %.1fs, calibrated nprobe %s" % (fmt, info["nlist"], info["pca_dim"], info["bytes"] / info["rows"], info["bytes"] / 1e6, build, info.get("calibrated_nprobe")))
        for label, np_opt in (("calibrated", None), ("nprobe 4", 4), ("nprobe 16", 16), ("every cell", info["nlist"])):
            opts = {"index": "ix_" + fmt}
            if np_opt: opts["nprobe"] = np_opt
            res, lat = run((json.dumps(opts),), label)
            ls = json.loads(con.execute("select fractal_index_info(?)", ("ix_" + fmt,)).fetchone()[0])["last_search"]
            print("   %-24s recall %.3f  median %7.2f ms  rows scanned %9d (used_index=%s)" % (label, recall(res), lat, ls["rows_scanned"], ls["used_index"]))

if __name__ == "__main__":
    sys.exit(main())
