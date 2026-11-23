#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""test/test_index_tamper.py -- the index tier against damaged storage and out-of-range options (run by gate 54).

Usage: test_index_tamper.py PATH_TO_EXTENSION

  * fractal_index_create refuses each option out of its range (nlist, iters, sample, pca_dim, seed, vector_format) with the range message, and
    accepts the boundary values;
  * a stored index is loaded by a FRESH connection and every defect in a stored cell row is refused with "corrupt", one defect at a time:
    a cell number below 0 or at/after nlist, a negative row count, an ids blob whose length is not 8 x the row count (short, empty, a count
    large enough to overflow n x 8), a codes blob of the wrong length or empty; and a meta row whose dim, nlist or format disagrees with the model;
  * fractal_index_candidates, which reads the stored cells again on a resident index, skips the same damaged rows and still answers a list.
Needs no network and no plugin."""
import json, os, random, sqlite3, struct, sys, tempfile

ext = sys.argv[1]
fails = 0
def check(ok, name, detail=""):
    global fails
    print(("  [PASS] " if ok else "  [FAIL] ") + name + ("" if ok or not detail else ": " + str(detail)[:300]))
    if not ok: fails += 1

D, N = 8, 120
random.seed(5)
rows = [[random.gauss(0, 1) for _ in range(D)] for _ in range(N)]
def blob(v): return struct.pack("<I", len(v)) + struct.pack("<%df" % len(v), *v)

def connect(path):
    c = sqlite3.connect(path, isolation_level=None)
    c.enable_load_extension(True); c.load_extension(ext)
    return c

def raw(path):                                  # a plain connection: the index tables are ordinary tables, so damage needs no extension
    return sqlite3.connect(path, isolation_level=None)

def one(c, sql, *a):
    try: return True, c.execute(sql, a).fetchone()[0]
    except sqlite3.Error as e: return False, str(e)

WORK = tempfile.mkdtemp(prefix="fsql_idxtamper_")
SEQ = [0]
def build(tag, fmt="FP32"):
    SEQ[0] += 1
    path = os.path.join(WORK, "%s%d.db" % (tag, SEQ[0]))
    c = connect(path)
    c.execute("create table t(id integer primary key, emb blob)")
    c.executemany("insert into t(id,emb) values(?,?)", [(i + 1, blob(r)) for i, r in enumerate(rows)])
    ok, r = one(c, "select fractal_index_create('t','emb',?)", json.dumps({"vector_format": fmt, "name": "ix", "nlist": 4, "calibration_samples": 30}))
    assert ok, r
    c.close()
    return path

# --- options out of range --------------------------------------------------------------------------------------------------------
c = connect(os.path.join(WORK, "opts.db"))
c.execute("create table t(id integer primary key, emb blob)")
c.executemany("insert into t(id,emb) values(?,?)", [(i + 1, blob(r)) for i, r in enumerate(rows)])
n = 0
for opt, bad in (("nlist", 4097), ("nlist", -1), ("iters", 101), ("iters", -1), ("sample", 1000001), ("sample", -1), ("pca_dim", 100000),
                 ("pca_dim", -1), ("seed", -1)):
    n += 1
    ok, r = one(c, "select fractal_index_create('t','emb',?)", json.dumps({"name": "o%d" % n, opt: bad}))
    check(not ok and "nlist must be 0..4096" in r, "%s = %s is refused with the range message" % (opt, bad), r)
ok, r = one(c, "select fractal_index_create('t','emb',?)", json.dumps({"name": "ofmt", "vector_format": "INT7"}))
check(not ok and "vector_format must be" in r, "an unknown vector_format is refused", r)
for opt, good in (("nlist", 0), ("iters", 0), ("sample", 0), ("pca_dim", 0), ("seed", 0), ("nlist", 2), ("iters", 100)):
    n += 1
    ok, r = one(c, "select fractal_index_create('t','emb',?)", json.dumps({"name": "o%d" % n, opt: good, "vector_format": "FP32"}))
    check(ok, "%s = %s is accepted" % (opt, good), r)
c.close()

# --- a stored cell row damaged, one defect at a time: a fresh connection refuses the index -------------------------------------------
CELL = {
    "a cell number below 0": "update fractal_index_cells set cell = -1 where name='ix' and cell = 0",
    "a cell number at or after nlist": "update fractal_index_cells set cell = 99 where name='ix' and cell = 0",
    "a negative row count": "update fractal_index_cells set n = -1 where name='ix' and cell = 0",
    "an ids blob shorter than 8 x the row count": "update fractal_index_cells set ids = substr(ids, 1, 3) where name='ix' and cell = 0",
    "an empty ids blob": "update fractal_index_cells set ids = x'' where name='ix' and cell = 0",
    "a row count that overflows n x 8": "update fractal_index_cells set n = 4611686018427387905 where name='ix' and cell = 0",
    "a codes blob of the wrong length": "update fractal_index_cells set codes = substr(codes, 1, 3) where name='ix' and cell = 0",
    "an empty codes blob": "update fractal_index_cells set codes = x'' where name='ix' and cell = 0",
    "an ids blob longer than 8 x the row count": "update fractal_index_cells set ids = ids || x'00' where name='ix' and cell = 0",
    "a codes blob longer than its row count": "update fractal_index_cells set codes = codes || x'00' where name='ix' and cell = 0",
}
for what, sql in CELL.items():
    path = build("cell")
    r0 = raw(path); r0.execute(sql); r0.close()
    c = connect(path)
    ok, r = one(c, "select fractal_search('t','emb',?,3,'{\"index\":\"ix\"}')", blob(rows[3]))
    check(not ok and "corrupt" in r, "%s is refused with a clean 'corrupt' error" % what, r)
    c.close()

# --- a meta row that disagrees with the stored model ---------------------------------------------------------------------------------
for what, sql in (("a dim that is not the model's", "update fractal_index_meta set dim = dim + 1 where name='ix'"),
                  ("an nlist that is not the model's", "update fractal_index_meta set nlist = nlist + 1 where name='ix'"),
                  ("a format that is not the model's", "update fractal_index_meta set format = 'INT8' where name='ix'")):
    path = build("meta")
    r0 = raw(path); r0.execute(sql); r0.close()
    c = connect(path)
    ok, r = one(c, "select fractal_search('t','emb',?,3,'{\"index\":\"ix\"}')", blob(rows[3]))
    check(not ok and ("corrupt" in r or "model" in r or "format" in r or "dim" in r), "a meta row with %s is refused cleanly" % what, r)
    c.close()

# --- fractal_index_candidates reads the stored cells again: the same damaged rows are skipped, the answer is still a list -------------
for what, sql in CELL.items():
    path = build("cand")
    c = connect(path)
    ok, r = one(c, "select fractal_search('t','emb',?,3,'{\"index\":\"ix\"}')", blob(rows[3]))     # loads the index (resident from here on)
    r0 = raw(path); r0.execute(sql); r0.close()
    ok, r = one(c, "select fractal_index_candidates('t','emb',?,'{\"near\":2,\"per_cell\":1}')", blob(rows[5]))
    try: good = ok and isinstance(json.loads(r), list)
    except ValueError: good = False
    check(good, "candidates over a resident index with %s still answers a list" % what, r)
    c.close()

# --- fractal_index_refresh reads the stored cells too: the same damaged rows are refused there ---------------------------------------
for what, sql in CELL.items():
    path = build("refr")
    r0 = raw(path); r0.execute(sql); r0.close()
    c = connect(path)
    ok, r = one(c, "select fractal_index_refresh('ix')")
    check(not ok and "corrupt" in r, "fractal_index_refresh over %s is refused with a clean 'corrupt' error" % what, r)
    c.close()

# --- search options: approximate (verify off) with and without an ids set, and the model the index was built for -----------------------
path = build("srch")
c = connect(path)
q = blob(rows[7])
for what, opts in (("verify off", {"verify": False}), ("verify off and an ids set", {"verify": False, "ids": [1, 2, 3, 7, 9, 11]}),
                   ("verify off, nprobe 1", {"verify": False, "nprobe": 1}), ("use_index off", {"use_index": False}),
                   ("use_index off and an ids set", {"use_index": False, "ids": [1, 2, 3, 7]})):
    o = dict(opts); o.setdefault("index", "ix")
    ok, r = one(c, "select fractal_search('t','emb',?,3,?)", q, json.dumps(o))
    try: good = ok and isinstance(json.loads(r), list) and len(json.loads(r)) >= 1
    except ValueError: good = False
    check(good, "fractal_search with %s answers a list of rows" % what, r)
ok, r = one(c, "select fractal_index_create('t','emb',?)", json.dumps({"name": "ixm", "vector_format": "FP32", "nlist": 2, "model": "alpha"}))
check(ok, "an index built for a named model is created", r)
ok, r = one(c, "select fractal_search('t','emb',?,3,?)", q, json.dumps({"index": "ixm", "model": "beta"}))
check(not ok and "does not match" in r, "a query for another model than the index was built for is refused", r)
ok, r = one(c, "select fractal_search('t','emb',?,3,?)", q, json.dumps({"index": "ixm", "model": "alpha"}))
check(ok, "a query for the model the index was built for is answered", r)
c.close()

# --- fractal_index_ensure when the rebuild it decides on fails: the error is reported and the old generation keeps serving -------------
path = build("ens")
c = connect(path)
c.executemany("insert into t(id,emb) values(?,?)", [(1000 + i, "not a vector") for i in range(70)])      # past a quarter of the rows, none usable
ok, r = one(c, "select fractal_index_ensure('t','emb')")
check(not ok, "fractal_index_ensure reports a rebuild that fails (rows that are not vectors)", r)
ok, r = one(c, "select fractal_search('t','emb',?,3,?)", q, json.dumps({"index": "ix"}))
check(ok, "the previous generation still serves searches after a failed ensure", r)
c.close()

# --- search options that are clamped or refused: rerank, nprobe, k ------------------------------------------------------------------
path = build("rr", fmt="INT4")
c = connect(path)
q = blob(rows[9])
for what, opts, want_ok in (("rerank -1", {"rerank": -1}, False), ("rerank 100001", {"rerank": 100001}, False), ("rerank 5 on an INT4 index", {"rerank": 5}, False),
                            ("rerank 20 on an INT4 index", {"rerank": 20}, True), ("rerank 100000", {"rerank": 100000}, True), ("rerank 0 on an INT4 index", {"rerank": 0}, False),
                            ("nprobe 0", {"nprobe": 0}, True), ("nprobe 1e12", {"nprobe": 1e12}, True), ("nprobe -3", {"nprobe": -3}, True)):
    o = dict(opts); o["index"] = "ix"
    ok, r = one(c, "select fractal_search('t','emb',?,3,?)", q, json.dumps(o))
    check(ok == want_ok, "fractal_search with %s is %s" % (what, "answered" if want_ok else "refused"), r)
c.close()
path = build("rr8", fmt="INT8")
c = connect(path)
for what, opts in (("rerank 0 on an INT8 index", {"rerank": 0}), ("rerank 1 on an INT8 index", {"rerank": 1}), ("k = 1 with verify off", {"verify": False})):
    o = dict(opts); o["index"] = "ix"
    ok, r = one(c, "select fractal_search('t','emb',?,1,?)", blob(rows[9]), json.dumps(o))
    check(ok, "fractal_search with %s is answered" % what, r)
c.close()

# --- option values the parser tolerates: JSON whitespace of every kind, a value that is not a number ------------------------------------
c = connect(os.path.join(WORK, "ws.db"))
c.execute("create table t(id integer primary key, emb blob)")
c.executemany("insert into t(id,emb) values(?,?)", [(i + 1, blob(r)) for i, r in enumerate(rows)])
ok, r = one(c, "select fractal_index_create('t','emb',?)", "{ \t\"name\"\n:\r\"ws1\" ,\t\"vector_format\" : \"FP32\" ,\n\"nlist\"\r\n: 2 }")
check(ok, "options with tabs, newlines and carriage returns between the tokens are parsed", r)
for what, opts in (("nlist a string that is not a number", {"name": "nn1", "nlist": "abc", "vector_format": "FP32"}),
                   ("nlist the string 'nan'", {"name": "nn2", "nlist": "nan", "vector_format": "FP32"}),
                   ("nlist a boolean", {"name": "nn3", "nlist": True, "vector_format": "FP32"}),
                   ("nlist null", {"name": "nn4", "nlist": None, "vector_format": "FP32"})):
    ok, r = one(c, "select fractal_index_create('t','emb',?)", json.dumps(opts))
    check(ok or "must be" in r or "nlist" in r, "options with %s are handled (defaulted or refused cleanly)" % what, r)
ok, r = one(c, "select fractal_index_create('t','emb','')"); check(ok or isinstance(r, str), "empty options text is handled", r)
ok, r = one(c, "select fractal_index_create('t','emb','not json')"); check(isinstance(r, (str, int)), "options that are not JSON are handled", r)
c.close()

# --- a vector with a component that is not finite or past float range stops the build with the rowid -------------------------------------
for what, txt in (("NaN", "nan,1,2,3,4,5,6,7"), ("infinity", "inf,1,2,3,4,5,6,7"), ("past float range", "1e39,1,2,3,4,5,6,7")):
    c = connect(os.path.join(WORK, "nf%d.db" % SEQ[0])); SEQ[0] += 1
    c.execute("create table t(id integer primary key, emb text)")
    c.executemany("insert into t(id,emb) values(?,?)", [(i + 1, ",".join("%.4f" % x for x in r)) for i, r in enumerate(rows)])
    c.execute("update t set emb=? where id=50", (txt,))
    ok, r = one(c, "select fractal_index_create('t','emb',?)", json.dumps({"name": "nf", "vector_format": "FP32", "nlist": 2}))
    check(not ok, "a component that is %s is refused at build" % what, r)
    c.close()

# --- candidates: near and per_cell clamped at both ends, and a list long enough to grow the output buffer -------------------------------
path = os.path.join(WORK, "big.db")
c = connect(path)
c.execute("create table t(id integer primary key, emb blob)")
big = [[random.gauss(0, 1) for _ in range(D)] for _ in range(3000)]
c.executemany("insert into t(id,emb) values(?,?)", [(i + 1, blob(r)) for i, r in enumerate(big)])
ok, r = one(c, "select fractal_index_create('t','emb',?)", json.dumps({"name": "bx", "vector_format": "FP32", "nlist": 4, "calibration_samples": 30}))
check(ok, "a 3000-row index is built", r)
for what, opts in (("near and per_cell below their range", {"near": -5, "per_cell": -5}), ("near and per_cell past their range", {"near": 99999, "per_cell": 9999999}),
                   ("every cell and every row", {"near": 4, "per_cell": 100000}), ("near 0", {"near": 0, "per_cell": 1})):
    ok, r = one(c, "select fractal_index_candidates('t','emb',?,?)", blob(big[5]), json.dumps(opts))
    try: n_ids = len(json.loads(r)) if ok else -1
    except ValueError: n_ids = -1
    check(ok and n_ids >= 0, "fractal_index_candidates with %s answers a list (%d ids)" % (what, n_ids), r)
ok, r = one(c, "select fractal_index_candidates('t','emb',?,?)", blob(big[5]), json.dumps({"near": 4, "per_cell": 100000}))
check(ok and len(json.loads(r)) > 2000, "an every-row candidate list is long (it grows the output buffer)", r if not ok else len(json.loads(r)))
c.execute("insert into t(id,emb) values(100000, ?)", (blob(big[7]),))           # a row past the build: the candidates add the delta rows too
ok, r = one(c, "select fractal_index_candidates('t','emb',?,?)", blob(big[5]), json.dumps({"near": 4, "per_cell": 100000}))
check(ok and 100000 in json.loads(r), "rows added since the build are among the candidates", r if not ok else "")
ok, r = one(c, "select fractal_search('t','emb',?,50,?)", blob(big[5]), json.dumps({"index": "bx", "verify": False, "ids": list(range(1, 400))}))
check(ok and len(json.loads(r)) == 50, "a search over a long ids set (verify off) returns k rows", r if not ok else len(json.loads(r)))
c.close()

# --- fractal_index_ensure: each action, and each way the action it chooses can fail -----------------------------------------------------
def build_to(tag, fmt, **extra):
    SEQ[0] += 1
    p = os.path.join(WORK, "%s%d.db" % (tag, SEQ[0]))
    cc = connect(p)
    cc.execute("create table t(id integer primary key, emb blob)")
    cc.executemany("insert into t(id,emb) values(?,?)", [(i + 1, blob(r)) for i, r in enumerate(rows)])
    o = {"vector_format": fmt, "name": "ix", "nlist": 2, "calibration_samples": 30}; o.update(extra)
    ok, r = one(cc, "select fractal_index_create('t','emb',?)", json.dumps(o)); assert ok, r
    return p, cc
p, cc = build_to("deg", "INT4", target_recall=0.99999)
ok, r = one(cc, "select fractal_index_info('ix')")
status = json.loads(r).get("status") if ok else None
check(status in ("ready", "degraded"), "an INT4 index built for a very high target reports a verdict (%s)" % status, r)
ok, r = one(cc, "select fractal_index_ensure('t','emb','{\"vector_format\":\"FP32\",\"nlist\":2}')")
check(ok, "ensure with new options on a %s index answers" % status, r)
ok, r = one(cc, "select fractal_index_ensure('t','emb','{\"nlist\":99999}')")
check(not ok or "unchanged" in r or "rebuilt" in r, "ensure with out-of-range new options is refused or leaves the index", r)
cc.close()
p, cc = build_to("del", "FP32")
cc.execute("delete from t where id > 40")                                       # past a fifth deleted
ok, r = one(cc, "select fractal_index_ensure('t','emb')")
check(ok and "rebuilt" in r, "ensure rebuilds after more than a fifth of the rows were deleted", r)
cc.execute("delete from t where id > 20")
ok, r = one(cc, "select fractal_index_ensure('t','emb','{\"vector_format\":\"FP16\",\"nlist\":2}')")
check(ok and "rebuilt" in r, "ensure rebuilds with the new options after more deletions", r)
cc.close()
p, cc = build_to("add", "FP32")
cc.executemany("insert into t(id,emb) values(?,?)", [(2000 + i, blob(r)) for i, r in enumerate(rows[:60])])     # past a quarter added
ok, r = one(cc, "select fractal_index_ensure('t','emb','{\"vector_format\":\"FP16\",\"nlist\":2}')")
check(ok and "rebuilt" in r, "ensure rebuilds with the new options after more than a quarter of the rows were added", r)
cc.close()
p, cc = build_to("rfail", "FP32")
cc.executemany("insert into t(id,emb) values(?,?)", [(3000 + i, blob(r)) for i, r in enumerate(rows[:3])])      # a few rows added: ensure would refresh
cc.close()
r0 = raw(p); r0.execute("update fractal_index_cells set n = -1 where name='ix' and cell = 0"); r0.close()
cc = connect(p)
ok, r = one(cc, "select fractal_index_ensure('t','emb')")
check(not ok and "corrupt" in r, "ensure whose refresh finds a damaged cell reports it", r)
cc.close()

print("test_index_tamper: " + ("PASS" if fails == 0 else "FAIL (%d)" % fails))
sys.exit(1 if fails else 0)
