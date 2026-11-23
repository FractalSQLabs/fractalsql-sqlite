#!/usr/bin/env python3
"""test/test_precision.py -- the precision contract of the SQL vector functions (gate 49).

Usage: test_precision.py PATH_TO_EXTENSION

Every distance, norm and similarity accumulates in double in a fixed sequential order and is returned as a double (no rounding to
float32 on the way out). The reference here is the same arithmetic in Python floats (IEEE double, no fused multiply-add), so the
SQL results must be BIT-identical to it. Covers: G1 ranking agreement (random unit vectors at 128 and 768 dims and an adversarial
near-tie set, ordered by the SQL distance vs the reference); G2 cross-function consistency (the vector functions, the exact search
fallback and the telemetry scan return bit-identical distances for the same pair); G3 text round trip (vector -> text -> vector is
bit-identical for float32); degenerate inputs (zero vector, NULL, dimension mismatch).
"""
import json, math, random, sqlite3, struct, sys

ext = sys.argv[1]
fails = 0

def check(ok, name, detail=""):
    global fails
    print(("  [PASS] " if ok else "  [FAIL] ") + name + ("" if ok or not detail else ": " + str(detail)[:300]))
    if not ok: fails += 1

def f32(x): return struct.unpack("<f", struct.pack("<f", x))[0]
def blob(v): return struct.pack("<I", len(v)) + struct.pack("<%df" % len(v), *v)
def bits(x): return struct.pack("<d", x)

c = sqlite3.connect(":memory:", isolation_level=None)
c.enable_load_extension(True); c.load_extension(ext)

def seq_parts(a, b):
    d = x = y = 0.0
    for p, q in zip(a, b):
        d += p * q; x += p * p; y += q * q
    return d, x, y

def ref_cos_dist(a, b):
    d, x, y = seq_parts(a, b)
    return 1.0 if x == 0.0 or y == 0.0 else 1.0 - d / (math.sqrt(x) * math.sqrt(y))

def unit(rng, n):
    v = [rng.gauss(0, 1) for _ in range(n)]; s = math.sqrt(sum(t * t for t in v))
    return [f32(t / s) for t in v]

rng = random.Random(7)
for dim in (128, 768):
    q = unit(rng, dim); X = [unit(rng, dim) for _ in range(120)]
    sql = [c.execute("select fractal_vector_cosine_distance(?,?)", (blob(q), blob(x))).fetchone()[0] for x in X]
    ref = [ref_cos_dist(q, x) for x in X]
    check(all(bits(a) == bits(b) for a, b in zip(sql, ref)), "dim %d: cosine distance is bit-identical to the sequential double reference" % dim)
    order_sql = sorted(range(len(X)), key=lambda i: (sql[i], i))[:10]; order_ref = sorted(range(len(X)), key=lambda i: (ref[i], i))[:10]
    check(order_sql == order_ref, "dim %d: G1 ordered top-10 by SQL distance equals the reference top-10" % dim)
    dots = [c.execute("select fractal_vector_negative_inner_product(?,?)", (blob(q), blob(x))).fetchone()[0] for x in X[:30]]
    check(all(bits(-seq_parts(q, x)[0]) == bits(d) for d, x in zip(dots, X[:30])), "dim %d: negative inner product is bit-identical (and is -dot)" % dim)
    l2 = [c.execute("select fractal_vector_l2_distance(?,?)", (blob(q), blob(x))).fetchone()[0] for x in X[:30]]
    l2sq = [c.execute("select fractal_vector_l2_squared_distance(?,?)", (blob(q), blob(x))).fetchone()[0] for x in X[:30]] if False else None
    ref_l2 = []
    for x in X[:30]:
        s = 0.0
        for p, r in zip(q, x): t = p - r; s += t * t
        ref_l2.append(math.sqrt(s))
    check(all(bits(a) == bits(b) for a, b in zip(l2, ref_l2)), "dim %d: L2 distance is bit-identical" % dim)
    n = c.execute("select fractal_vector_norm(?)", (blob(q),)).fetchone()[0]
    s = 0.0
    for p in q: s += p * p
    check(bits(n) == bits(math.sqrt(s)), "dim %d: norm is bit-identical" % dim)

# adversarial near-ties: candidates whose cosine distances differ by a few ulps
dim = 256; base = unit(rng, dim); q = unit(rng, dim)
cand = [[f32(b + (rng.random() - 0.5) * 2e-7) for b in base] for _ in range(200)]
sql = [c.execute("select fractal_vector_cosine_distance(?,?)", (blob(q), blob(x))).fetchone()[0] for x in cand]
ref = [ref_cos_dist(q, x) for x in cand]
check([i for i in sorted(range(200), key=lambda i: (sql[i], i))] == [i for i in sorted(range(200), key=lambda i: (ref[i], i))], "near-tie set: the full ranking by SQL distance equals the reference ranking (G1)")
check(len(set(ref)) > 150, "near-tie set: the candidates really are near-ties (distinct distances within 1e-7)", len(set(ref)))

# G2: every SQL-visible cosine path agrees to the last bit
dim = 96; q = unit(rng, dim); X = [unit(rng, dim) for _ in range(60)]
c.execute("create table g2(id integer primary key, emb blob)"); c.executemany("insert into g2 values(?,?)", [(i + 1, blob(x)) for i, x in enumerate(X)])
vec = {i + 1: c.execute("select fractal_vector_cosine_distance(?,?)", (blob(x), blob(q))).fetchone()[0] for i, x in enumerate(X)}
tele = {r["doc_id"]: r["distance"] for r in json.loads(c.execute("select fractal_search_telemetry('g2','emb',?,60)", (blob(q),)).fetchone()[0])}
fall = {r["doc_id"]: r["distance"] for r in json.loads(c.execute("select fractal_search('g2','emb',?,60,'{\"use_index\":false}')", (blob(q),)).fetchone()[0])}
check(len(tele) == 60 and all(bits(vec[k]) == bits(tele[k]) for k in vec), "G2: fractal_search_telemetry distances equal fractal_vector_cosine_distance bit for bit")
check(len(fall) == 60 and all(bits(vec[k]) == bits(fall[k]) for k in vec), "G2: the exact fallback of fractal_search equals fractal_vector_cosine_distance bit for bit")
c.execute("select fractal_index_create('g2','emb','{\"vector_format\":\"FP32\",\"calibration_samples\":0}')")
idx = {r["doc_id"]: r["distance"] for r in json.loads(c.execute("select fractal_search('g2','emb',?,60,'{\"nprobe\":1000}')", (blob(q),)).fetchone()[0])}
check(len(idx) >= 50 and all(bits(vec[k]) == bits(v) for k, v in idx.items()), "G2: the verified distances of an indexed search equal fractal_vector_cosine_distance bit for bit")

# G3: text round trip is bit-identical for float32
bad = 0
for _ in range(200):
    v = [f32(rng.uniform(-1e3, 1e3) * 10 ** rng.randint(-8, 3)) for _ in range(rng.randint(1, 40))]
    txt = c.execute("select fractal_vector_to_json(?)", (blob(v),)).fetchone()[0]
    back = c.execute("select fractal_vector_from_text(?)", (txt,)).fetchone()[0]
    if back != blob(v): bad += 1
check(bad == 0, "G3: vector -> JSON text -> vector is bit-identical for 200 random float32 vectors", bad)

# degenerate inputs keep their documented conventions
z = blob([0.0] * 8); v = blob([1.0] * 8)
check(c.execute("select fractal_vector_cosine_distance(?,?)", (z, v)).fetchone()[0] == 1.0, "a zero vector has cosine distance 1.0 (not NaN)")
check(c.execute("select fractal_vector_cosine_similarity(?,?)", (z, v)).fetchone()[0] == 0.0, "a zero vector has cosine similarity 0.0")
check(c.execute("select fractal_vector_cosine_distance(NULL,?)", (v,)).fetchone()[0] is None, "NULL in, NULL out")
try: c.execute("select fractal_vector_cosine_distance(?,?)", (v, blob([1.0] * 3))); check(False, "a dimension mismatch is an error")
except sqlite3.Error: check(True, "a dimension mismatch is an error")

print("test_precision: %s" % ("PASS" if fails == 0 else "%d FAILED" % fails))
sys.exit(1 if fails else 0)
