#!/usr/bin/env python3
"""test/test_ledger_roundtrip.py -- QTL v2 through the REAL enterprise core library (gate 55, G5 of the precision plan).

Usage: test_ledger_roundtrip.py PATH_TO_EXTENSION [PATH_TO_ENTERPRISE_CORE_LIBRARY]
       (the library may also come from the FSQL_ENTERPRISE_LIB environment variable; without one the driver uses the mock core named by
       FSQL_MOCK_ENTERPRISE_LIB and runs only the checks a mock can answer: flush and load, the chain, the retention key)

The mock enterprise core cannot show what the real flush writes, so with the real library this driver:
feedback on one connection, flush into the chain, a brand-new connection loads it. It asserts that the reload restores the exact entry
counts, that fractal_audit_unpack of the persisted blob shows the weight, lambda and sigma of every entry (QTL v2; a handle with both
a positive and a negative report appears twice), that a repeated load does not inflate anything (load replaces), that the compact
step decays the Shadow weights and that the chain verifies. It never writes outside a temporary directory.
"""
import json, os, sqlite3, sys, tempfile

ext = os.path.realpath(sys.argv[1])
lib = sys.argv[2] if len(sys.argv) > 2 else os.environ.get("FSQL_ENTERPRISE_LIB", "")
lib = os.path.realpath(lib) if lib else ""
mock = False
if not lib or not os.path.isfile(lib):
    lib = os.environ.get("FSQL_MOCK_ENTERPRISE_LIB", "")
    lib = os.path.realpath(lib) if lib else ""
    mock = True
    if not lib or not os.path.isfile(lib):
        print("test_ledger_roundtrip: SKIP (no enterprise core library; set FSQL_ENTERPRISE_LIB, or FSQL_MOCK_ENTERPRISE_LIB for the mock core)")
        sys.exit(0)
fails = 0
if mock or not os.path.exists(lib + ".sig"):
    # an unsigned local build: the operator opt-out (a process-environment variable no SQL statement can touch) lets it load
    os.environ["FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE"] = "0"
def check(ok, name, detail=""):
    global fails
    print(("  [PASS] " if ok else "  [FAIL] ") + name + ("" if ok or not detail else ": " + str(detail)[:300]))
    if not ok: fails += 1

db = os.path.join(tempfile.mkdtemp(prefix="fsql_ledger_"), "l.db")
def conn():
    c = sqlite3.connect(db, isolation_level=None); c.enable_load_extension(True); c.load_extension(ext)
    c.execute("select fractal_config_set('enterprise_lib', ?)", (lib,))
    return c
def q(c, sql, *a): return c.execute(sql, a).fetchone()[0]
def latest(c):   # the newest QTL blob (kind 1) of the chain, unpacked by the core
    return json.loads(q(c, "select fractal_audit_unpack((select payload from fractalsql_ledger where kind=1 order by id desc limit 1))"))

if mock:
    c = conn()
    q(c, "select fractal_diversify_enable()")
    for h in range(4): q(c, "select fractal_feedback_report(?, 'negative', 0)", h)
    check(q(c, "select fractal_ledger_flush()") is not None, "flush writes a chain record (mock core)")
    c2 = conn()
    check(q(c2, "select fractal_ledger_load()") is not None, "a brand-new connection loads it (mock core)")
    check(q(c2, "select fractal_ledger_flush()") is not None and q(c2, "select fractal_ledger_load()") is not None, "flush and load again (mock core)")
    check(json.loads(q(c2, "select fractal_ledger_verify()")).get("ok") is True, "the chain verifies (mock core)")
    check(q(c2, "select fractal_ledger_reset_soft()") is not None, "reset_soft answers (mock core)")
    c0 = sqlite3.connect(":memory:"); c0.enable_load_extension(True); c0.load_extension(ext)
    check(q(c0, "select fractal_config_get('ledger_retention')") == "fade", "ledger_retention defaults to fade")
    try:
        c0.execute("select fractal_config_set('ledger_retention', 'forever')"); bad = False
    except sqlite3.Error as e:
        bad = "fade|exact" in str(e)
    check(bad, "an unknown ledger_retention value is refused and names the choices")
    print("test_ledger_roundtrip: %s (mock core)" % ("PASS" if fails == 0 else "%d FAILED" % fails))
    sys.exit(1 if fails else 0)

c = conn()
q(c, "select fractal_diversify_enable()")
for h in range(10): q(c, "select fractal_feedback_report(?, 'negative', 0)", h)
for h in range(5, 8): q(c, "select fractal_feedback_report(?, 'negative', 0)", h)     # weight 2.0 on 5, 6, 7
for h in range(100, 104): q(c, "select fractal_feedback_report(?, 'positive', 0)", h)
q(c, "select fractal_feedback_report(5, 'positive', 0)")                                  # handle 5 in BOTH ledgers
check(q(c, "select fractal_ledger_shadow_count()") == 10 and q(c, "select fractal_ledger_truth_count()") == 5, "live counts: 10 shadows, 5 truths")
q(c, "select fractal_ledger_compact()"); q(c, "select fractal_ledger_compact()")
check(q(c, "select fractal_ledger_flush()") is not None, "flush writes a chain record")

un = latest(c)
check(len(un) == 15 and all("weight" in e for e in un), "audit_unpack of the persisted blob lists all 15 entries with a weight (QTL v2)", len(un))
sh = [e for e in un if e["signal"] == "shadow"]; tr = [e for e in un if e["signal"] == "truth"]
check(len(sh) == 10 and len(tr) == 5 and all("lambda" in e and "sigma" in e for e in sh), "shadows carry lambda and sigma, truths do not")
w = {e["doc_id"]: e["weight"] for e in sh}
check(abs(w[0] - 0.81) < 1e-12 and abs(w[5] - 1.62) < 1e-12, "Shadow weights decayed x0.9 twice are persisted exactly (1.0 -> 0.81, 2.0 -> 1.62)", (w[0], w[5]))
check([e["doc_id"] for e in un].count(5) == 2, "the handle in BOTH ledgers is persisted twice (a v1 blob had to drop one)")

c2 = conn()
q(c2, "select fractal_ledger_load()")
check(q(c2, "select fractal_ledger_shadow_count()") == 10 and q(c2, "select fractal_ledger_truth_count()") == 5, "a brand-new connection restores the exact counts")
q(c2, "select fractal_ledger_flush()")
un2 = latest(c2)
strip = lambda L: [{k: v for k, v in e.items() if k != "epoch"} for e in L]
check(strip(un) == strip(un2), "reload -> flush writes bit-identical entries (weights, lambda, sigma): nothing resets or inflates")
q(c2, "select fractal_ledger_load()"); q(c2, "select fractal_ledger_load()")
check(q(c2, "select fractal_ledger_shadow_count()") == 10, "loading twice does not duplicate or inflate (load replaces)")
v = json.loads(q(c2, "select fractal_ledger_verify()"))
check(v.get("ok") is True, "the chain verifies", v)
q(c2, "select fractal_ledger_reset_soft()")
check(q(c2, "select fractal_ledger_shadow_count()") == 0 and q(c2, "select fractal_ledger_truth_count()") == 5, "reset_soft clears the Shadow ledger and keeps Truth")

# ---- ledger_retention: the host's config key reaches the core's retention mode
c0 = sqlite3.connect(":memory:"); c0.enable_load_extension(True); c0.load_extension(ext)
check(q(c0, "select fractal_config_get('ledger_retention')") == "fade", "ledger_retention defaults to fade")
try:
    c0.execute("select fractal_config_set('ledger_retention', 'forever')"); bad = False
except sqlite3.Error as e:
    bad = "fade|exact" in str(e)
check(bad, "an unknown ledger_retention value is refused and names the choices")
c0.close()

db = os.path.join(tempfile.mkdtemp(prefix="fsql_ledger_x_"), "x.db")
cx = conn()
q(cx, "select fractal_config_set('ledger_retention', 'exact')")        # before the enterprise tier loads: applied when it does
q(cx, "select fractal_diversify_enable()")
for h in range(3): q(cx, "select fractal_feedback_report(?, 'negative', 0)", h)
q(cx, "select fractal_ledger_compact()"); q(cx, "select fractal_ledger_compact()")
q(cx, "select fractal_ledger_flush()")
wx = {e["doc_id"]: e["weight"] for e in latest(cx) if e["signal"] == "shadow"}
check(all(abs(v - 1.0) < 1e-12 for v in wx.values()) and len(wx) == 3, "exact retention: compaction does not decay the Shadow weights", wx)
cy = conn()                                                               # default config (fade): the flushed header's mode is adopted at load
q(cy, "select fractal_ledger_load()")
q(cy, "select fractal_ledger_compact()")
q(cy, "select fractal_ledger_flush()")
wy = {e["doc_id"]: e["weight"] for e in latest(cy) if e["signal"] == "shadow"}
check(len(wy) == 3 and all(abs(v - 1.0) < 1e-12 for v in wy.values()), "a ledger flushed in exact mode stays exact after a reload on a connection configured fade", wy)
q(cy, "select fractal_config_set('ledger_retention', 'fade')")             # the loaded tier: a change takes effect at once
q(cy, "select fractal_ledger_compact()")
q(cy, "select fractal_ledger_flush()")
wz = {e["doc_id"]: e["weight"] for e in latest(cy) if e["signal"] == "shadow"}
check(all(abs(v - 0.9) < 1e-12 for v in wz.values()), "switching to fade on a live connection decays again", wz)
print("test_ledger_roundtrip: %s" % ("PASS" if fails == 0 else "%d FAILED" % fails))
sys.exit(1 if fails else 0)
