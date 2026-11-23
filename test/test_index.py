#!/usr/bin/env python3
"""test/test_index.py -- fractal_index_* and the indexed fractal_search (gate 50).

Usage: test_index.py PATH_TO_EXTENSION

Covers: create / info / search / rebuild / drop for every vector_format; the "index actually used" check (rows scanned below the
row count); recall against exact search; rows added after the build (delta) and rows deleted (verify drops them); staleness;
generation atomicity (a failed rebuild leaves the previous generation serving); corruption refusal (damaged model blob, missing
cell); hostile identifiers; the old two-argument fractal_search error that explains the rename; fractal_index_candidates for
Scout; calibration recorded in info; the catalog (fractal_index_list); the verdict and advice in info (ready / stale / degraded /
empty); fractal_index_refresh (rows added since the build folded into the cells, a new generation, nothing retrained); the ids option
of fractal_search (a short set scanned exactly, a long one through the index and filtered, the exact fallback). Needs no network and
no plugin.
"""
import json, math, os, random, sqlite3, struct, sys, tempfile

ext = sys.argv[1]
fails = 0

def check(ok, name, detail=""):
    global fails
    print(("  [PASS] " if ok else "  [FAIL] ") + name + ("" if ok or not detail else ": " + str(detail)[:300]))
    if not ok: fails += 1

def blob(v): return struct.pack("<I", len(v)) + struct.pack("<%df" % len(v), *v)

DBFILE = os.path.join(tempfile.mkdtemp(prefix="fsql_idx_"), "t.db")

def connect():
    c = sqlite3.connect(DBFILE, isolation_level=None)
    c.enable_load_extension(True); c.load_extension(ext)
    return c

def one(c, sql, *a):
    try: return True, c.execute(sql, a).fetchone()[0]
    except sqlite3.Error as e: return False, str(e)

random.seed(11)
D, N, CL = 24, 1500, 25
cent = [[random.gauss(0, 1) for _ in range(D)] for _ in range(CL)]
rows = [[x + 0.3 * random.gauss(0, 1) for x in random.choice(cent)] for _ in range(N)]
c = connect()
c.execute("create table t(id integer primary key, emb blob, label text)")
c.executemany("insert into t(id,emb,label) values(?,?,?)", [(i + 1, blob(r), "r%d" % i) for i, r in enumerate(rows)])

def search(q, k, opts):
    ok, r = one(c, "select fractal_search('t','emb',?,?,?)", blob(q), k, json.dumps(opts))
    return json.loads(r) if ok else r

def exact(q, k): return search(q, k, {"use_index": False})

def recall(index, nq=30, k=10, **extra):
    hit = 0
    for qi in range(nq):
        q = rows[qi * 37 % N]
        truth = {x["doc_id"] for x in exact(q, k)}
        got = {x["doc_id"] for x in search(q, k, dict(index=index, **extra))}
        hit += len(truth & got)
    return hit / (nq * k)

# --- every format builds, reports, searches ---------------------------------------------------------------------------------
for fmt, floor in (("FP32", 0.99), ("FP16", 0.98), ("INT8", 0.60), ("INT4", 0.50)):
    ok, r = one(c, "select fractal_index_create('t','emb',?)", json.dumps({"vector_format": fmt, "name": "ix_" + fmt, "calibration_samples": 60}))
    check(ok, "create %s" % fmt, r)
    if not ok: continue
    info = json.loads(r)
    check(info["rows"] == N and info["format"] == fmt and info["generation"] == 1 and info["nlist"] >= 1, "create %s reports rows, format, generation, nlist" % fmt, info)
    rc = recall("ix_" + fmt, nprobe=info["nlist"])
    check(rc >= floor, "%s recall@10 at every cell is at least %.2f (got %.3f)" % (fmt, floor, rc))

# --- the index is actually used -----------------------------------------------------------------------------------------------
search(rows[3], 10, {"index": "ix_FP32", "nprobe": 2})
ok, r = one(c, "select fractal_index_info('ix_FP32')"); inf = json.loads(r)
ls = inf["last_search"]
check(ls["used_index"] and ls["rows_scanned"] < N and ls["cells_probed"] == 2, "info: the last search used the index and scanned fewer rows than the table (index actually used)", ls)
check(inf["nprobe_default"] >= 1 and inf["calibration"].get("recommended_nprobe", 0) >= 1, "info: calibration recorded the recommended nprobe", inf["calibration"])
search(rows[3], 10, {"use_index": False})
ls = json.loads(one(c, "select fractal_index_info('ix_FP32')")[1])["last_search"]
check(not ls["used_index"] and ls["rows_scanned"] == N, "info: use_index=false scans every row and reports not used")

# --- results are verified: exact distances, ties on rowid -------------------------------------------------------------------
q = rows[10]
a = search(q, 5, {"index": "ix_INT4", "nprobe": 25}); e = exact(q, 5)
exact_dist = {x["doc_id"]: x["distance"] for x in exact(q, 1000)}
check(all(x["doc_id"] in exact_dist and x["distance"] == exact_dist[x["doc_id"]] for x in a), "indexed results carry EXACT distances (bit-identical to the exact scan), even for INT4", [x["distance"] for x in a][:3])
check(a[0]["doc_id"] == 11 and a[0]["distance"] < 1e-9, "the query row is its own nearest neighbour")

# --- delta, delete, stale -----------------------------------------------------------------------------------------------------
c.execute("insert into t(id,emb,label) values(9000,?, 'new')", (blob(rows[10]),))
r = search(rows[10], 3, {"index": "ix_FP32"})
check(9000 in [x["doc_id"] for x in r], "a row added after the build is found (exact delta scan)", r)
c.execute("delete from t where id=11")
r = search(rows[10], 3, {"index": "ix_FP32"})
check(11 not in [x["doc_id"] for x in r], "a deleted row is dropped by the verify step", r)
inf = json.loads(one(c, "select fractal_index_info('ix_FP32')")[1])
check(inf["stale"] and inf["has_delta"], "info reports stale and has_delta", inf)
ok, r = one(c, "select fractal_index_rebuild('ix_FP32')")
check(ok and json.loads(r)["generation"] == 2, "rebuild produces generation 2", r)
inf = json.loads(one(c, "select fractal_index_info('ix_FP32')")[1])
check(not inf["stale"] and not inf["has_delta"] and inf["rows_indexed"] == N, "after rebuild nothing is stale", inf)

# --- atomicity: a failed rebuild leaves the previous generation serving ------------------------------------------------------
c.execute("insert into t(id,emb,label) values(9500, 'not a vector', 'bad')")
ok, r = one(c, "select fractal_index_rebuild('ix_FP32')")
check(not ok, "a rebuild over a malformed vector fails cleanly", r)
gen_rows = c.execute("select count(distinct generation) from fractal_index_cells where name='ix_FP32'").fetchone()[0]
check(gen_rows == 1 and json.loads(one(c, "select fractal_index_info('ix_FP32')")[1])["generation"] == 2, "the failed rebuild left generation 2 intact and wrote nothing", gen_rows)
check(isinstance(search(rows[5], 3, {"index": "ix_FP32"}), list), "the old generation still serves searches")
c.execute("delete from t where id=9500")

# --- corruption refusal (a FRESH connection loads the stored index; a resident copy is by design only reloaded on a generation change) ---
c.execute("update fractal_index_meta set model_blob = substr(model_blob,1,40) where name='ix_FP16'")
c2 = connect()
ok, r = one(c2, "select fractal_search('t','emb',?,3,'{\"index\":\"ix_FP16\"}')", blob(rows[1]))
check(not ok and ("corrupt" in r or "model" in r), "a truncated model blob is refused with a clean error", r)
c2.close()
c.execute("update fractal_index_meta set model_blob = model_blob where name='ix_FP16'")   # (left damaged: dropped below)
c.execute("delete from fractal_index_cells where name='ix_INT8' and cell=0")
c3 = connect()
ok, r = one(c3, "select fractal_search('t','emb',?,3,'{\"index\":\"ix_INT8\",\"nprobe\":2}')", blob(rows[1]))
check(not ok and ("incomplete" in r or "corrupt" in r), "an index with a missing cell is refused with a clean error", r)
c3.close()
c4 = connect()
c4.execute("update fractal_index_cells set codes = substr(codes,1,3) where name='ix_FP32' and generation=2 and cell=0")
ok, r = one(c4, "select fractal_search('t','emb',?,3,'{\"index\":\"ix_FP32\"}')", blob(rows[1]))
check(not ok and "corrupt" in r, "a cell whose code length does not match its row count is refused", r)
c4.close()
for nm in ("ix_FP16", "ix_INT8"):
    one(c, "select fractal_index_drop('%s')" % nm)
c.execute("update fractal_index_cells set codes = codes where 0")
ok, r = one(c, "select fractal_index_rebuild('ix_FP32')")
check(ok, "a damaged index is repaired by a rebuild", r)

# --- hostile input ---------------------------------------------------------------------------------------------------------------
for name, sql, args in (
    ("an injection-shaped table name is refused", "select fractal_index_create(?, 'emb')", ("t; drop table t; --",)),
    ("an injection-shaped index name is refused", "select fractal_index_create('t','emb',?)", (json.dumps({"name": "x\" ; drop table t; --"}),)),
    ("an unknown vector_format is refused", "select fractal_index_create('t','emb',?)", (json.dumps({"vector_format": "PQ4", "name": "z"}),)),
    ("nlist above the limit is refused", "select fractal_index_create('t','emb',?)", (json.dumps({"nlist": 99999, "name": "z"}),)),
    ("a duplicate index name is refused", "select fractal_index_create('t','emb',?)", (json.dumps({"name": "ix_FP32"}),)),
    ("rebuild of a missing index is refused", "select fractal_index_rebuild('nope')", ()),
    ("info of a missing index is refused", "select fractal_index_info('nope')", ()),
):
    ok, r = one(c, sql, *args); check(not ok, name, r)
ok, r = one(c, "select fractal_search('t','emb',?,0)", blob(rows[0])); check(not ok, "k = 0 is refused", r)
ok, r = one(c, "select fractal_search('t','emb',?,3,?)", blob(rows[0][:5]), json.dumps({"index": "ix_FP32"})); check(not ok and "dimension" in r, "a wrong-dimension query is refused", r)
ok, r = one(c, "select fractal_search('t','emb',NULL,3)"); check(ok and r is None, "a NULL query returns NULL")
ok, r = one(c, "select fractal_search(emb, ?) from t limit 1", blob(rows[0]))
check(not ok and "fractal_sfs_converge" in r, "the old two-argument fractal_search errors and names fractal_sfs_converge", r)
ok, r = one(c, "select fractal_sfs_converge(emb, ?) from t limit 1", blob(rows[2])); check(ok and isinstance(r, float), "fractal_sfs_converge(vector, query) works", r)

# --- candidates for Scout ----------------------------------------------------------------------------------------------------------
ok, r = one(c, "select fractal_index_candidates('t','emb',?,'{\"near\":2,\"per_cell\":1}')", blob(rows[5]))
ids = json.loads(r) if ok else []
check(ok and 0 < len(ids) < N and len(set(ids)) == len(ids), "fractal_index_candidates returns a distinct subset of the rows", len(ids))
ok, r = one(c, "select fractal_search_explore(emb, ?, '{\"population_size\":8}') from t where id in (%s)" % ",".join(str(i) for i in ids[:200]), blob(rows[5]))
check(ok, "Scout runs over the candidate rows", r)


# --- the catalog, the verdict, refresh and the ids option --------------------------------------------------------------------------
def info(name):
    return json.loads(one(c, "select fractal_index_info(?)", name)[1])

lst = json.loads(one(c, "select fractal_index_list()")[1])
names = [x["name"] for x in lst]
check(names == sorted(names) and "ix_FP32" in names and "ix_INT4" in names, "list: one entry per index, ordered by name", names)
e = next(x for x in lst if x["name"] == "ix_FP32")
check(e["table"] == "t" and e["column"] == "emb" and e["format"] == "FP32" and e["rows"] == e["rows_now"] and e["stale"] is False and e["status"] == "ready" and e["generation"] >= 3,
      "list: an entry carries table, column, format, rows, stale, status and generation", e)
mem = sqlite3.connect(":memory:"); mem.enable_load_extension(True); mem.load_extension(ext)
check(mem.execute("select fractal_index_list()").fetchone()[0] == "[]", "list: a database that never built an index lists as []")
mem.close()
inf = info("ix_FP32")
check(inf["status"] == "ready" and inf["advice"] == [] and inf["rows_added_since_build"] == 0 and inf["rows_deleted_since_build"] == 0, "info: a fresh index is ready, with no advice", inf)

# rows added: stale, with refresh advice; refresh folds them in
base = inf["rows_indexed"]; gen0 = inf["generation"]; add = base // 10
for i in range(add): c.execute("insert into t(id,emb,label) values(?,?,'add')", (20000 + i, blob(rows[i])))
inf = info("ix_FP32")
check(inf["status"] == "stale" and inf["rows_added_since_build"] == add and inf["has_delta"] and any(a.startswith("refresh:") for a in inf["advice"]),
      "info: rows added since the build make it stale and the advice says refresh", inf)
check(next(x for x in json.loads(one(c, "select fractal_index_list()")[1]) if x["name"] == "ix_FP32")["status"] == "stale", "list: the same index shows as stale")
ok, r = one(c, "select fractal_index_refresh('ix_FP32')")
rj = json.loads(r) if ok else {}
check(ok and rj.get("added") == add and rj.get("refreshed") is True and rj.get("generation") == gen0 + 1 and rj.get("rows") == base + add, "refresh folds the added rows in and writes the next generation", r)
inf = info("ix_FP32")
check(not inf["stale"] and not inf["has_delta"] and inf["rows_indexed"] == base + add and inf["status"] == "ready" and inf["generation"] == gen0 + 1, "after a refresh nothing is stale", inf)
n_gen = c.execute("select count(distinct generation) from fractal_index_cells where name='ix_FP32'").fetchone()[0]
check(n_gen == 1, "refresh leaves one generation of cells behind", n_gen)
r = search(rows[3], 5, {"index": "ix_FP32"})
ls = info("ix_FP32")["last_search"]
check(20003 in [x["doc_id"] for x in r] and 4 in [x["doc_id"] for x in r], "a refreshed row is found beside the original it copies", r)
check(ls["used_index"] and ls["rows_scanned"] < base + add, "refreshed rows are served from the cells: the index scanned fewer rows than the table", ls)
rc = recall("ix_FP32")
check(rc >= 0.97, "recall after a refresh is still at least 0.97 (got %.3f)" % rc)
ok, r = one(c, "select fractal_index_refresh('ix_FP32')")
check(ok and json.loads(r)["added"] == 0 and json.loads(r)["refreshed"] is False and info("ix_FP32")["generation"] == gen0 + 1, "a refresh with nothing to add changes nothing", r)
for name, sql in (("refresh of a missing index is refused", "select fractal_index_refresh('nope')"), ("refresh with an injection-shaped name is refused", "select fractal_index_refresh('x\"; drop table t; --')")):
    ok, r = one(c, sql); check(not ok, name, r)
# a refresh over a malformed vector fails cleanly and leaves the serving generation alone
c.execute("insert into t(id,emb,label) values(30000, 'not a vector', 'bad')")
ok, r = one(c, "select fractal_index_refresh('ix_FP32')")
check(not ok and info("ix_FP32")["generation"] == gen0 + 1, "a refresh over a malformed vector fails cleanly and leaves the generation intact", r)
check(isinstance(search(rows[5], 3, {"index": "ix_FP32"}), list), "the index still serves after a failed refresh")
c.execute("delete from t where id=30000")
# a few deleted rows need no action: the raw stale flag is true, the verdict stays ready, and the count is reported
c.execute("delete from t where id=20001")
inf = info("ix_FP32")
check(inf["stale"] and inf["status"] == "ready" and inf["advice"] == [] and inf["rows_deleted_since_build"] == 1, "info: one deleted row sets the stale flag but the verdict stays ready, with no advice", inf)
# many deletions: the advice is a rebuild, and a rebuild clears it
c.execute("delete from t where id % 3 = 0")
inf = info("ix_FP32")
check(inf["status"] == "stale" and inf["rows_deleted_since_build"] > 0 and any(a.startswith("rebuild:") and "deleted" in a for a in inf["advice"]), "info: many deleted rows make the advice a rebuild", inf)
ok, r = one(c, "select fractal_index_rebuild('ix_FP32')")
inf = info("ix_FP32")
check(ok and inf["status"] == "ready" and inf["advice"] == [], "a rebuild clears the stale verdict", inf)
# an index over rows that all disappeared reports empty
c.execute("create table gone(id integer primary key, v blob)")
c.executemany("insert into gone values(?,?)", [(i, blob(rows[i])) for i in range(1, 60)])
one(c, "select fractal_index_create('gone','v',?)", json.dumps({"name": "ix_gone", "vector_format": "FP32"}))
c.execute("delete from gone")
inf = info("ix_gone")
check(inf["status"] == "empty" and any("no vectors" in a for a in inf["advice"]), "info: a table with no vectors left reports empty", inf)
one(c, "select fractal_index_drop('ix_gone')"); c.execute("drop table gone")

# the catalog outlives the table it indexes: a dropped table is reported as orphaned, never an error
c.execute("create table orph(id integer primary key, v blob)")
c.executemany("insert into orph values(?,?)", [(i, blob(rows[i])) for i in range(1, 60)])
one(c, "select fractal_index_create('orph','v',?)", json.dumps({"name": "ix_orph", "vector_format": "FP32"}))
c.execute("drop table orph")
lst = json.loads(one(c, "select fractal_index_list()")[1])
check(next((x for x in lst if x["name"] == "ix_orph"), {}).get("status") == "orphaned", "list: an index whose table was dropped is orphaned, and the list does not fail", lst)
inf = info("ix_orph")
check(inf["status"] == "orphaned" and any("no longer exists" in a for a in inf["advice"]), "info: an orphaned index says the table is gone and recommends dropping it", inf)
one(c, "select fractal_index_drop('ix_orph')")

# degraded: INT8 codes on tight clusters cannot reach the recall target, and the build's own calibration says so
random.seed(5)
TD, TN, TC = 64, 1200, 20
tcent = [[random.gauss(0, 1) for _ in range(TD)] for _ in range(TC)]
tnorm = [math.sqrt(sum(x * x for x in v)) for v in tcent]
tcent = [[x / n for x in v] for v, n in zip(tcent, tnorm)]
trows = [[x + 0.05 * random.gauss(0, 1) for x in random.choice(tcent)] for _ in range(TN)]
c.execute("create table tight(id integer primary key, v blob)")
c.executemany("insert into tight values(?,?)", [(i + 1, blob(r)) for i, r in enumerate(trows)])
ok, r = one(c, "select fractal_index_create('tight','v',?)", json.dumps({"name": "ix_tight8", "vector_format": "INT8"}))
inf = info("ix_tight8") if ok else {}
check(ok and inf.get("status") == "degraded" and any("calibration reached recall" in a and "FP32" in a for a in inf.get("advice", [])), "info: an INT8 index whose calibration missed its target is degraded, and the advice names FP32", inf.get("advice"))
ok, r = one(c, "select fractal_index_create('tight','v',?)", json.dumps({"name": "ix_tight32", "vector_format": "FP32"}))
inf = info("ix_tight32") if ok else {}
check(ok and inf.get("status") == "ready", "info: the same data as FP32 reaches its target and is ready", inf.get("advice"))
one(c, "select fractal_index_drop('ix_tight8')"); one(c, "select fractal_index_drop('ix_tight32')"); c.execute("drop table tight")

# the ids option
def cosd(a, b):
    na = math.sqrt(sum(x * x for x in a)); nb = math.sqrt(sum(x * x for x in b))
    return 1.0 - sum(x * y for x, y in zip(a, b)) / (na * nb)
live = {r[0]: [float(x) for x in struct.unpack("<%df" % D, r[1][4:])] for r in c.execute("select id, emb from t")}
q = rows[40]
def truth(idset, k):
    return sorted(((cosd(live[i], q), i) for i in idset if i in live))[:k]
small = sorted(list(live)[::7])[:60]
r = search(q, 5, {"ids": small, "index": "ix_FP32"})
want = truth(small, 5)
check([x["doc_id"] for x in r] == [i for _, i in want] and all(abs(x["distance"] - d) < 1e-6 for x, (d, _) in zip(r, want)), "ids: a short set is scanned exactly and returns the nearest of those rows", r)
check(not info("ix_FP32")["last_search"]["used_index"] and info("ix_FP32")["last_search"]["rows_scanned"] == len(small), "ids: a short set reads only those rows", info("ix_FP32")["last_search"])
r = search(q, 5, {"ids": small, "use_index": False})
check([x["doc_id"] for x in r] == [i for _, i in want], "ids: without an index the same rows come back", r)
check(search(q, 5, {"ids": []}) == [], "ids: an empty set returns no rows")
check(search(q, 5, {"ids": [-5, 10 ** 12]}) == [], "ids: rowids that are not rows are ignored")
check(len(search(q, 5, {"ids": small[:3], "use_index": False})) == 3, "ids: fewer rows than k returns what there is")
big = sorted(i for i in live if i % 2 == 0) + [10 ** 6 + i for i in range(4200)]
r = search(q, 5, {"ids": big, "index": "ix_FP32"})
want = truth([i for i in big if i in live], 5)
check(len(r) == 5 and all(x["doc_id"] % 2 == 0 for x in r) and len({x["doc_id"] for x in r} & {i for _, i in want}) >= 4, "ids: a long set goes through the index and returns rows from the set", r)
check(info("ix_FP32")["last_search"]["used_index"], "ids: a long set used the index", info("ix_FP32")["last_search"])
tiny = sorted(list(live)[5:8])
r = search(q, 5, {"ids": tiny + [10 ** 6 + i for i in range(4200)], "index": "ix_FP32"})
check([x["doc_id"] for x in r] == [i for _, i in truth(tiny, 5)] and not info("ix_FP32")["last_search"]["used_index"], "ids: when the index leaves fewer than k rows the set is scanned exactly", r)
for name, bad in (("a string", "1,2"), ("an object", {"a": 1}), ("a non-integer item", ["x"]), ("a nested array", [[1]])):
    ok, r = one(c, "select fractal_search('t','emb',?,3,?)", blob(q), json.dumps({"ids": bad})); check(not ok and "ids" in r, "ids: %s is refused" % name, r)
check(isinstance(search(q, 3, {"ids": small + small}), list) and len(search(q, 3, {"ids": small + small})) == 3, "ids: duplicates in the set are harmless")

# --- fractal_index_ensure ---------------------------------------------------------------------------------------------------------------
c.execute("create table te(id integer primary key, emb blob)")
c.executemany("insert into te(id,emb) values(?,?)", [(i + 1, blob(r)) for i, r in enumerate(rows[:800])])
ce = connect()          # a fresh connection: the first one already holds as many resident indexes as the cache allows
def ensure(*a):
    ok, r = one(ce, "select fractal_index_ensure(%s)" % ",".join("?" * len(a)), *a)
    return json.loads(r) if ok else r
r = ensure("te", "emb", '{"vector_format":"FP32"}')
check(isinstance(r, dict) and r["action"] == "created" and r["status"] == "ready" and r["generation"] == 1 and r["rows"] == 800 and r["name"] == "te_emb", "ensure: builds the index when none covers the table and column", r)
ok, r = one(ce, "select fractal_index_info('te_emb')"); check(ok and json.loads(r)["format"] == "FP32", "ensure: the build used the options it was given", r)
r = ensure("te", "emb")
check(isinstance(r, dict) and r["action"] == "unchanged" and r["generation"] == 1, "ensure: a second call changes nothing", r)
c.executemany("insert into te(id,emb) values(?,?)", [(1000 + i, blob(r2)) for i, r2 in enumerate(rows[800:840])])
r = ensure("te", "emb", "{}")
check(isinstance(r, dict) and r["action"] == "refreshed" and r["generation"] == 2 and r["rows"] == 840 and r["status"] == "ready", "ensure: a few added rows are folded in (refresh)", r)
c.executemany("insert into te(id,emb) values(?,?)", [(2000 + i, blob(r2)) for i, r2 in enumerate(rows[840:1500])])
r = ensure("te", "emb")
check(isinstance(r, dict) and r["action"] == "rebuilt" and r["generation"] == 3 and r["rows"] == 1500 and r["status"] == "ready", "ensure: more than a quarter added is rebuilt", r)
r = ensure("te", "emb")
check(isinstance(r, dict) and r["action"] == "unchanged" and r["generation"] == 3, "ensure: after the rebuild nothing is left to do", r)
ce.execute("alter table te rename to te_gone")
r = ensure("te", "emb")
check(isinstance(r, dict) and r["action"] == "unchanged" and r["status"] == "orphaned", "ensure: an index whose table is gone is reported orphaned, not recreated", r)
ce.execute("alter table te_gone rename to te")
ok, r = one(ce, "select fractal_index_ensure('no_such_table','emb')"); check(not ok and "no such table" in r, "ensure: a table that does not exist is an error", r)
for bad in ("te; drop table te", "t e"):
    ok, r = one(ce, "select fractal_index_ensure(?, 'emb')", bad); check(not ok and "identifiers" in r, "ensure: a hostile table name is refused", r)
ok, r = one(ce, "select fractal_index_ensure('te','emb','{\"vector_format\":\"BF16\"}')")
check(ok and json.loads(r)["action"] == "unchanged", "ensure: options are only used when a build or rebuild happens", r)
ok, r = one(ce, "select fractal_index_drop('te_emb')")
# the documented two-argument form of create works with the default options
c.execute("create table te2(id integer primary key, emb blob)")
c.executemany("insert into te2(id,emb) values(?,?)", [(i + 1, blob(r2)) for i, r2 in enumerate(rows[:300])])
ok, r = one(ce, "select fractal_index_create('te2','emb')"); check(ok and json.loads(r)["format"] == "INT8", "create(table, column) with no options builds an INT8 index", r)

# --- drop -----------------------------------------------------------------------------------------------------------------------------
ok, r = one(c, "select fractal_index_drop('ix_INT4')"); check(ok and r == 1, "drop returns 1", r)
n = c.execute("select count(*) from fractal_index_cells where name='ix_INT4'").fetchone()[0] + c.execute("select count(*) from fractal_index_meta where name='ix_INT4'").fetchone()[0]
check(n == 0, "drop removes the cells and the metadata", n)
ok, r = one(c, "select fractal_index_info('ix_INT4')"); check(not ok, "info after drop is refused", r)
r = search(rows[2], 3, {"index": "ix_FP32"}); check(isinstance(r, list) and len(r) == 3, "other indexes keep serving after a drop")

print("test_index: %s" % ("PASS" if fails == 0 else "%d FAILED" % fails))
sys.exit(1 if fails else 0)
