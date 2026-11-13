#!/usr/bin/env python3
"""test/t2s_matrix.py -- fractal_text_to_sql against every shape of model reply the validator has to judge.

The mock reasoning plugin answers with the text in /tmp/fractalsql_bt_sql.txt, so each case here is "the model said THIS": plain SQL,
fenced SQL (with and without a language tag, unterminated, several fences), leading comments of both kinds (one unterminated), statements
the allowlist forbids (DDL, PRAGMA, ATTACH, EXPLAIN, writes under the read-only setting), more than one statement, none at all, a
syntax error (which is retried), text that merely resembles SQL. Each is run under both allowlist settings, with and without the review
pass, in plain and fenced reply mode, and with questions that need JSON escaping. Exactly-known outcomes are asserted; everything else
must simply not crash and must return either SQL or an error.
Env: FSQL_EXT (the extension, default ./fractalsql.so). Exit status is nonzero when a check fails."""
import os, shutil, sqlite3, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.dirname(HERE)
EXT = os.path.abspath(os.environ.get("FSQL_EXT") or os.path.join(ROOT, "fractalsql.so"))
if not os.path.exists(EXT):
    print("  FAIL need the built extension (FSQL_EXT)"); sys.exit(1)
os.environ["FSQL_REASONING_REQUIRE_SIGNATURE"] = "0"
W = os.path.realpath(tempfile.mkdtemp(prefix="fsql_t2sm_")); PLUG = os.path.join(W, "mock.so")
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

def session(allow, review, attempts):
    c = sqlite3.connect(":memory:"); c.enable_load_extension(True); c.load_extension(EXT)
    c.executescript("CREATE TABLE docs(id INTEGER PRIMARY KEY, label TEXT); INSERT INTO docs VALUES(1,'a'),(2,'b');")
    for k, v in (("reasoning_plugin", PLUG), ("text_to_sql_allowed_statements", allow), ("text_to_sql_use_review", review), ("text_to_sql_max_attempts", attempts)):
        c.execute("SELECT fractal_config_set(?, ?)", (k, v))
    return c
def ask(c, reply, question="list the docs"):
    with open(SQLFILE, "w") as f: f.write(reply)
    try: return True, c.execute("SELECT fractal_text_to_sql(?)", (question,)).fetchone()[0]
    except sqlite3.Error as e: return False, str(e)

# a leading "!" asks for a refusal (text after it must appear in the message); None leaves the outcome unconstrained.
# (reply, outcome under allow=select, outcome under select_insert_update)  outcome: substring expected in the SQL (ok) or "!substring" in the error, None = unconstrained
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
QUESTIONS = ["list the docs", "", "it's \"quoted\" \\ back\nline\ttab\rret" + chr(1), "x" * 5000, "ünïcode ☃"]
runs = 0
for allow in ("select", "select_insert_update"):
    for review in ("0", "1"):
        for fence in (None, "1"):
            if fence: os.environ["FSQL_MOCK_FLIP_FENCE"] = fence
            else: os.environ.pop("FSQL_MOCK_FLIP_FENCE", None)
            c = session(allow, review, "2")
            for reply, want_sel, want_dml in CASES:
                want = want_sel if allow == "select" else want_dml
                ok, r = ask(c, reply)
                runs += 1
                if fence or review == "1" or want is None:
                    continue                      # fenced reply mode and the review pass change what comes back: robustness only
                if want.startswith("!"):
                    check(not ok and (len(want) == 1 or want[1:] in r), "%s: %r is refused (%s)" % (allow, reply[:40], want[1:]), (ok, r))
                else:
                    check(ok and want in r, "%s: %r is accepted" % (allow, reply[:40]), (ok, r))
            c.close()
c = session("select", "0", "3")
for q in QUESTIONS:
    ask(c, "SELECT label FROM docs", q); runs += 1
for attempts in ("1", "10"):
    c2 = session("select", "1", attempts)
    for reply in ("SELECT label FROM docs", "SELECT FROM", "DROP TABLE docs"):
        ask(c2, reply); runs += 1
    c2.close()
# question NULL / non-text, and the function on a closed-over empty schema
try: c.execute("SELECT fractal_text_to_sql(NULL)").fetchone()   # NULL question: an error or NULL, not a crash
except sqlite3.Error: pass
try: c.execute("SELECT fractal_text_to_sql(5)").fetchone()
except sqlite3.Error: pass
c.close()
try: os.remove(SQLFILE)
except OSError: pass
os.environ.pop("FSQL_MOCK_FLIP_FENCE", None)
shutil.rmtree(W, ignore_errors=True)
print("t2s matrix: %d runs, %d checks passed, %d failed" % (runs, passes, fails))
sys.exit(1 if fails else 0)
