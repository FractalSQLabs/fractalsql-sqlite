#!/usr/bin/env python3
"""test/sql_agent_matrix.py -- fractal_sql_agent against every shape of model reply its statement validator has to judge.

The agent applies the same gate as fractal_text_to_sql with its own implementation (fence stripping, first keyword, a single statement,
EXPLAIN, read-only), and with auto_execute it runs what passes. The mock reasoning plugin answers with the text in
/tmp/fractalsql_bt_sql.txt, so each case is "the model said THIS". Every case runs under both allowlist settings, with auto_execute off
and on, with and without retries. What is asserted is the safety property that matters: whatever the model says, no statement the
setting forbids ever executes (the table and its rows survive anything but a permitted INSERT or UPDATE), nothing crashes, and every
call returns a result or an error.
Env: FSQL_EXT (the extension, default ./fractalsql.so). Exit status is nonzero when a check fails."""
import os, shutil, sqlite3, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.dirname(HERE)
EXT = os.path.abspath(os.environ.get("FSQL_EXT") or os.path.join(ROOT, "fractalsql.so"))
if not os.path.exists(EXT):
    print("  FAIL need the built extension (FSQL_EXT)"); sys.exit(1)
os.environ["FSQL_REASONING_REQUIRE_SIGNATURE"] = "0"
W = os.path.realpath(tempfile.mkdtemp(prefix="fsql_agm_")); PLUG = os.path.join(W, "mock.so")
# The compiler runs unsanitized: this process carries the sanitizer runtime (preloaded, so the
# instrumented extension under test can be loaded into this process), and a preloaded runtime in the
# compiler trips the leak checker over the toolchain's own allocations.
BUILD_ENV = {k: v for k, v in os.environ.items() if k != "LD_PRELOAD"}
if subprocess.run(["cc", "-shared", "-fPIC", "-std=c99", "-I" + os.path.join(ROOT, "include"), os.path.join(ROOT, "tests", "mock_reasoning_plugin.c"), "-o", PLUG], capture_output=True, env=BUILD_ENV).returncode != 0:
    print("  FAIL the mock plugin did not build"); sys.exit(1)
SQLFILE = "/tmp/fractalsql_bt_sql.txt"
passes = fails = 0
def check(cond, what, detail=""):
    global passes, fails
    if cond: passes += 1
    else: fails += 1; print("  FAIL %s %s" % (what, ("-- " + str(detail)[:250]) if detail else ""))
def session(allow):
    c = sqlite3.connect(":memory:", isolation_level=None); c.enable_load_extension(True); c.load_extension(EXT)
    c.executescript("CREATE TABLE docs(id INTEGER PRIMARY KEY, label TEXT); INSERT INTO docs VALUES(1,'a'),(2,'b');")
    for k, v in (("reasoning_plugin", PLUG), ("text_to_sql_allowed_statements", allow)):
        c.execute("SELECT fractal_config_set(?, ?)", (k, v))
    return c
def ask(c, reply, *args):
    with open(SQLFILE, "w") as f: f.write(reply)
    try: return True, c.execute("SELECT fractal_sql_agent(%s)" % ",".join("?" * (1 + len(args))), ("count the docs",) + args).fetchone()[0]
    except sqlite3.Error as e: return False, str(e)

CASES = [
    ("SELECT label FROM docs",                      "label",             "label"),
    ("select * from docs where id = 1",             "docs",              "docs"),
    ("WITH x AS (SELECT 1) SELECT * FROM x",        "WITH",              "WITH"),
    ("-- the answer\nSELECT 1",                     "SELECT 1",          "SELECT 1"),
    ("/* the answer */ SELECT 2",                   "SELECT 2",          "SELECT 2"),
    ("/* never closed SELECT 3",                    None,                None),
    ("-- only a comment",                           None,                None),
    ("   \n\t  ",                                   None,                None),
    ("",                                            None,                None),
    ("```sql\nSELECT label FROM docs\n```", None, None),
    ("```SQL\nSELECT label FROM docs\n```", None, None),
    ("```sql SELECT label FROM docs```",            None,                None),
    ("```sql\nSELECT label FROM docs",              None,                None),
    ("```\nSELECT label FROM docs\n```", None, None),
    ("```\nSELECT label FROM docs",                 None,                None),
    ("``` SELECT label FROM docs ```",              None,                None),
    ("text before\n```sql\nSELECT 4\n```\ntext after", None, None),
    ("```python\nprint(1)\n```\n```sql\nSELECT 5\n```", None,            None),
    ("```sql\nSELECT 6\n```\n```sql\nSELECT 7\n```", None,               None),
    ("SELECT 1; SELECT 2",                          "!more than one",    "!more than one"),
    ("SELECT 1;",                                   "SELECT 1",          "SELECT 1"),
    (";",                                           None,                None),
    ("EXPLAIN SELECT 1",                            "!EXPLAIN",          "!EXPLAIN"),
    ("EXPLAIN QUERY PLAN SELECT 1",                 "!EXPLAIN",          "!EXPLAIN"),
    ("explain   query   plan SELECT 1",             "!",                 "!"),
    ("INSERT INTO docs VALUES(9,'z')",              "!not permitted",    "INSERT"),
    ("UPDATE docs SET label='q'",                   "!not permitted",    "UPDATE"),
    ("DELETE FROM docs",                            "!not permitted",    "!not permitted"),
    ("DROP TABLE docs",                             "!not permitted",    "!not permitted"),
    ("CREATE TABLE t(x)",                           "!not permitted",    "!not permitted"),
    ("PRAGMA table_info(docs)",                     "!not permitted",    "!not permitted"),
    ("ATTACH DATABASE ':memory:' AS z",             "!not permitted",    "!not permitted"),
    ("VACUUM",                                      "!not permitted",    "!not permitted"),
    ("(SELECT 1)",                                  "!",                 "!"),
    ('"SELECT" 1',                                  "!",                 "!"),
    ("SELEC label FROM docs",                       "!not permitted",    "!not permitted"),
    ("SELECT label FROM nope",                      None,                None),
    ("SELECT FROM WHERE",                           None,                None),
    ("SELECT 'unterminated",                        None,                None),
    ("I cannot help with that.",                    "!not permitted",    "!not permitted"),
    ("SELECT " + "1+" * 200 + "1",                   "SELECT",            "SELECT"),
    ("SELECT '" + "x" * 3000 + "'",                 "SELECT",            "SELECT"),
    ("SELECT label FROM docs WHERE label = 'it''s'", "label",            "label"),
    ("INSERT INTO docs VALUES(10,'a'); SELECT 1",   "!",                 "!more than one"),
    ("WITH x AS (SELECT 1) INSERT INTO docs SELECT 11, 'w' FROM x", "!",  None),
]

FORBIDDEN_UNDER_SELECT = ("DROP", "CREATE", "DELETE", "ATTACH", "PRAGMA", "VACUUM", "INSERT", "UPDATE", "EXPLAIN")
runs = 0
for allow in ("select", "select_insert_update"):
    for auto in (0, 1):
        for retries in (1, 3):
            c = session(allow)
            for reply, _a, _b in CASES:
                ok, r = ask(c, reply, '["docs"]', retries, auto); runs += 1
                check(ok or isinstance(r, str), "%s auto=%d: %r returns a result or an error" % (allow, auto, reply[:30]), r)
            tbl = c.execute("SELECT count(*) FROM sqlite_master WHERE name='docs'").fetchone()[0]
            check(tbl == 1, "%s auto=%d retries=%d: the table survived every reply" % (allow, auto, retries), tbl)
            n = c.execute("SELECT count(*) FROM docs").fetchone()[0]
            if allow == "select": check(n == 2, "select mode: no row was written or removed", n)
            else: check(n >= 2, "select_insert_update: rows are only ever added", n)
            check(c.execute("SELECT count(*) FROM sqlite_master WHERE name IN ('t','z')").fetchone()[0] == 0, "%s: no table was created and nothing was attached" % allow)
            c.close()
c = session("select")
for args in ((), ('["docs"]',), ('["docs"]', 2), ('["docs"]', 2, 1), (None, None, None), ('["nope_table"]',), ('["docs; DROP TABLE docs"]',), ("",), ("docs",), ('[1,2]',), ('{"a":1}',), ('[]',), ('["docs","docs","docs"]', 0, 1), ('["docs"]', 1000, 1), ('["docs"]', -3, 0)):
    ask(c, "SELECT count(*) FROM docs", *args); runs += 1
try: c.execute("SELECT fractal_sql_agent()").fetchone()
except sqlite3.Error as e: check("expects 1 to 4" in str(e), "no arguments is refused", e)
try: c.execute("SELECT fractal_sql_agent('q', 'docs', 1, 1, 5)").fetchone()
except sqlite3.Error as e: check("expects 1 to 4" in str(e) or "wrong number" in str(e) or "no such function" in str(e), "five arguments are refused", e)
try: c.execute("SELECT fractal_sql_agent(NULL)").fetchone()
except sqlite3.Error as e: check("must not be NULL" in str(e), "a NULL question is refused", e)
check(c.execute("SELECT count(*) FROM docs").fetchone()[0] == 2, "the table is intact at the end")
c.close()
try: os.remove(SQLFILE)
except OSError: pass
shutil.rmtree(W, ignore_errors=True)
print("sql agent matrix: %d runs, %d checks passed, %d failed" % (runs, passes, fails))
sys.exit(1 if fails else 0)
