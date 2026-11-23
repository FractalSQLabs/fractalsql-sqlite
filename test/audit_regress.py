#!/usr/bin/env python3
"""test/audit_regress.py -- regression tests for the security findings reachable from SQL.

Each check asserts the behaviour the finding said was missing: secrets are write-only through SQL, the functions that change state
or reach the reasoning endpoint cannot run from a view in a database file, generated SQL cannot call fractal_set_actor, the numeric
arguments that size allocations or drive work are bounded, NaN/Inf never reach an integer conversion or a JSON document, and
fractal_agent_feedback_audit rejects an unbounded warmup_count before it touches the session-global Diversify switch.
Env: FSQL_EXT (the extension, default ./fractalsql.so). Exit status is nonzero when a check fails."""
import json, os, sqlite3, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.dirname(HERE)
EXT = os.path.abspath(os.environ.get("FSQL_EXT") or os.path.join(ROOT, "fractalsql.so"))
if not os.path.exists(EXT):
    print("  FAIL need the built extension (FSQL_EXT)"); sys.exit(1)
os.environ["FSQL_REASONING_REQUIRE_SIGNATURE"] = "0"
W = os.path.realpath(tempfile.mkdtemp(prefix="fsql_audit_")); PLUG = os.path.join(W, "mock.so")
BUILD_ENV = {k: v for k, v in os.environ.items() if k != "LD_PRELOAD"}
if subprocess.run(["cc", "-shared", "-fPIC", "-std=c99", "-I" + os.path.join(ROOT, "include"), os.path.join(ROOT, "tests", "mock_reasoning_plugin.c"), "-o", PLUG], capture_output=True, env=BUILD_ENV).returncode != 0:
    print("  FAIL the mock plugin did not build"); sys.exit(1)
SQLFILE = "/tmp/fractalsql_bt_sql.txt"
passes = fails = 0
def check(cond, what, detail=""):
    global passes, fails
    if cond: passes += 1
    else: fails += 1; print("  FAIL %s %s" % (what, ("-- " + str(detail)[:250]) if detail else ""))
def conn(trusted=True):
    c = sqlite3.connect(":memory:", isolation_level=None); c.enable_load_extension(True); c.load_extension(EXT)
    c.executescript("CREATE TABLE docs(id INTEGER PRIMARY KEY, label TEXT, emb TEXT);"
                    "INSERT INTO docs VALUES(1,'a','1.0,0.0,0.0'),(2,'b','0.0,1.0,0.0'),(3,'c','0.0,0.0,1.0');")
    return c
def one(c, sql, *a):
    try: return True, c.execute(sql, a).fetchone()[0]
    except sqlite3.Error as e: return False, str(e)
def reply(text):
    with open(SQLFILE, "w") as f: f.write(text)

# ---- F-01: secrets are write-only; the getter cannot run from a view ----
c = conn()
for k in ("http_token", "enterprise_ledger_key"):
    ok, r = one(c, "SELECT fractal_config_set(?, 'top-secret-value')", k); check(ok, "F-01 set " + k, r)
    ok, r = one(c, "SELECT fractal_config_get(?)", k); check(ok and r is None, "F-01 get(%s) must not return the secret" % k, (ok, r))
ok, r = one(c, "SELECT fractal_config_set('http_model', 'm-1')"); ok, r = one(c, "SELECT fractal_config_get('http_model')")
check(ok and r == "m-1", "F-01 non-secret keys still read back", (ok, r))
c.execute("CREATE VIEW steal AS SELECT fractal_config_get('http_model') AS v")
ok, r = one(c, "SELECT v FROM steal"); check(not ok and "unsafe use" in r, "F-01 fractal_config_get is DIRECTONLY (refused in a view)", (ok, r))

# ---- F-02 / F-29: state-changing and endpoint-reaching functions cannot run from a view ----
for name, call in (("fractal_audit_log", "fractal_audit_log('t','{}')"), ("fractal_ledger_load", "fractal_ledger_load()"),
                   ("fractal_agent_allocate", "fractal_agent_allocate(1,2,3)"), ("fractal_agent_route_task", "fractal_agent_route_task(1,2,3)"),
                   ("fractal_agent_feedback_audit", "fractal_agent_feedback_audit(1,2,3,4,5)"), ("fractal_agent_recall_hybrid", "fractal_agent_recall_hybrid(1,2,3,4)")):
    c.execute("CREATE VIEW v_%s AS SELECT %s AS x" % (name, call))
    ok, r = one(c, "SELECT x FROM v_%s" % name)
    check(not ok and "unsafe use" in r, "F-02/F-29 %s is refused in a view" % name, (ok, r))

# ---- F-03: generated SQL cannot call fractal_set_actor ----
c = conn()
for k, v in (("reasoning_plugin", PLUG),):
    c.execute("SELECT fractal_config_set(?, ?)", (k, v))
ok, r = one(c, "SELECT fractal_set_actor('legit')"); check(ok and r == "legit", "F-03 a direct call still works", (ok, r))
reply("SELECT fractal_set_actor('admin-bot')")
ok, r = one(c, "SELECT fractal_text_to_sql('who am i')")
check((not ok) and "fractal_set_actor" in r, "F-03 text-to-SQL refuses a statement calling fractal_set_actor", (ok, r))
reply("SELECT fractal_set_actor('admin-bot')")
ok, r = one(c, "SELECT fractal_sql_agent('who am i', NULL, 1, 1)")
check((not ok) or "admin-bot" not in str(r).split("generated_sql")[0], "F-03 the agent never executes fractal_set_actor", (ok, r))

# ---- F-07 / F-26: bounds on the values that drive work ----
ok, r = one(c, "SELECT fractal_search_agent('q','docs','emb',2147483647,15)"); check(not ok and "population_size" in r, "F-07 fractal_search_agent bounds population_size", (ok, r))
ok, r = one(c, "SELECT fractal_search_agent('q','docs','emb',50,2147483647)"); check(not ok and "iterations" in r, "F-07 fractal_search_agent bounds iterations", (ok, r))
reply("this is not sql at all")
t0 = time.time(); ok, r = one(c, "SELECT fractal_sql_agent('q', NULL, 2147483647)"); dt = time.time() - t0
check(dt < 60, "F-26 max_retries is clamped (an unbounded value would loop ~2 billion times)", "%.1fs" % dt)

# ---- F-06: a huge k is bounded ----
ok, r = one(c, "SELECT fractal_search_telemetry('docs','emb','1.0,0.0,0.0',2147483647)")
check(ok or "out of memory" not in r, "F-06 k=INT_MAX does not attempt a multi-gigabyte allocation", (ok, r))

# ---- F-08: NaN / Inf / out-of-range cohort ids are refused before the integer conversion ----
for bad in ("[nan]", "[inf]", "[-inf]", "[1e300]"):
    ok, r = one(c, "SELECT fractal_hybrid_clinical_search('docs','emb','1.0,0.0,0.0',?,2)", bad)
    check(not ok and "finite" in r, "F-08 cohort %s is refused" % bad, (ok, r))

# ---- F-10: a non-finite REAL in generated-SQL output is valid JSON ----
reply("SELECT 1e999 AS big, 2.5 AS ok")
ok, r = one(c, "SELECT fractal_sql_agent('numbers', NULL, 1, 1)")
valid = False
try: json.loads(r); valid = True
except Exception: pass
check(ok and valid and "inf" not in r.lower().replace("information", ""), "F-10 an Inf result column is emitted as JSON null", (ok, r))

# ---- F-24 / F-25: warmup_count is bounded and rejected before Diversify is touched ----
for bad in (-1, 0, 100000):
    ok, r = one(c, "SELECT fractal_agent_feedback_audit('docs','emb','1.0,0.0,0.0','docs','emb',?,2)", bad)
    check(not ok and "warmup_count" in r, "F-25 warmup_count=%d is refused" % bad, (ok, r))

print("audit_regress: %d checks passed, %d failed" % (passes, fails))
sys.exit(1 if fails else 0)
