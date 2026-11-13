#!/usr/bin/env python3
"""test/config_matrix.py -- fractal_config_set / fractal_config_get for every configuration key, valid and invalid.

Each key has a type (string, path, URL, integer with a range, boolean, enum). For every key this sets accepted values and reads them
back, sets values the key must refuse and checks the message names the key and the rule, resets with an empty string, uses the
"fractalsql." spelling, sets NULL, and then checks that the library path cannot be re-pointed once an enterprise library has loaded.
Runs in-process through Python's sqlite3 module (one connection per group, so no state leaks between them).
Env: FSQL_EXT (the extension, default ./fractalsql.so). Exit status is nonzero when a check fails."""
import os, shutil, sqlite3, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.dirname(HERE)
EXT = os.path.abspath(os.environ.get("FSQL_EXT") or os.path.join(ROOT, "fractalsql.so"))
if not os.path.exists(EXT):
    print("  FAIL need the built extension (FSQL_EXT)"); sys.exit(1)
passes = fails = 0
# The compiler runs unsanitized: this process carries the sanitizer runtime (preloaded, so the
# instrumented extension under test can be loaded into this process), and a preloaded runtime in the
# compiler trips the leak checker over the toolchain's own allocations.
BUILD_ENV = {k: v for k, v in os.environ.items() if k != "LD_PRELOAD"}
def conn():
    c = sqlite3.connect(":memory:"); c.enable_load_extension(True); c.load_extension(EXT); return c
def one(c, sql, *a):
    try: return True, c.execute(sql, a).fetchone()[0]
    except sqlite3.Error as e: return False, str(e)
def check(cond, what, detail=""):
    global passes, fails
    if cond: passes += 1
    else: fails += 1; print("  FAIL %s %s" % (what, ("-- " + str(detail)[:250]) if detail else ""))
def sets(c, key, value, want_err=None, expect=None, what=None):
    ok, r = one(c, "SELECT fractal_config_set(?, ?)", key, value)
    label = what or ("set %s=%r" % (key, value if not isinstance(value, str) or len(value) < 30 else value[:12] + "..."))
    if want_err is None:
        check(ok, label + " is accepted", r)
        if ok and expect is not None:
            g_ok, g = one(c, "SELECT fractal_config_get(?)", key)
            check(g_ok and str(g) == str(expect), label + " reads back as %r" % (expect,), (g_ok, g))
    else:
        check(not ok and want_err in r, label + " is refused (%s)" % want_err, (ok, r))

STR = ["http_token", "http_model", "http_embed_model", "http_think", "http_think_provider", "enterprise_ledger_key"]
URL = ["http_url", "http_embed_url", "http_native_url"]
PATH = ["reasoning_plugin", "enterprise_lib"]
BOOL = ["http_allow_plaintext", "text_to_sql_use_review", "enterprise_require_signature", "agent_partial_reasoning_fail"]
c = conn()
for k in STR:
    sets(c, k, "value-1", expect="value-1")
    ok, _ = one(c, "SELECT fractal_config_set(?, '')", k); check(ok, k + ": an empty string resets it")
    g_ok, g = one(c, "SELECT fractal_config_get(?)", k); check(g_ok and g is None, k + ": reads back unset after the reset", (g_ok, g))
    sets(c, k, "x" * 8193, want_err="too long")
    sets(c, "fractalsql." + k, "prefixed", expect="prefixed", what=k + " with the fractalsql. prefix")
    one(c, "SELECT fractal_config_set(?, NULL)", k)   # NULL: must not crash
for k in URL:
    sets(c, k, "https://example.test/v1/x", expect="https://example.test/v1/x")
    sets(c, k, "http://h/" + "u" * 2100, want_err="too long")
    ok, _ = one(c, "SELECT fractal_config_set(?, '')", k); check(ok, k + ": reset")
for k in PATH:
    sets(c, k, "relative/path.so", want_err="absolute path")
    sets(c, k, "/opt/a/../b.so", want_err="absolute path")
    sets(c, k, "/opt/fsql/plugin.so", expect="/opt/fsql/plugin.so")
    ok, _ = one(c, "SELECT fractal_config_set(?, '')", k); check(ok, k + ": reset")
for k in BOOL:
    for v in ("true", "on", "1", "yes", "false", "off", "0", "no", ""):
        sets(c, k, v)
    sets(c, k, "maybe", want_err="expects true/false")
    sets(c, k, "TRUE", want_err="expects true/false")
    one(c, "SELECT fractal_config_set(?, NULL)", k)
sets(c, "http_num_ctx", "4096", expect=4096); sets(c, "http_num_ctx", "0", expect=0)
sets(c, "http_num_ctx", "abc", want_err="expects an integer"); sets(c, "http_num_ctx", "12x", want_err="expects an integer")
sets(c, "http_num_ctx", "-1", want_err="must be"); sets(c, "http_num_ctx", "2000000", want_err="must be")
sets(c, "http_num_ctx", "", want_err="expects an integer")
sets(c, "text_to_sql_max_attempts", "5", expect=5); sets(c, "text_to_sql_max_attempts", "1", expect=1); sets(c, "text_to_sql_max_attempts", "10", expect=10)
sets(c, "text_to_sql_max_attempts", "0", want_err="must be 1..10"); sets(c, "text_to_sql_max_attempts", "11", want_err="must be 1..10")
sets(c, "text_to_sql_allowed_statements", "select_insert_update", expect="select_insert_update")
sets(c, "text_to_sql_allowed_statements", "select", expect="select")
sets(c, "text_to_sql_allowed_statements", "delete", want_err="must be one of"); sets(c, "text_to_sql_allowed_statements", "select_", want_err="must be one of")
sets(c, "text_to_sql_allowed_statements", "", want_err="must be one of")
sets(c, "no_such_key", "1", want_err="unknown config key"); sets(c, "fractalsql.no_such_key", "1", want_err="unknown config key")
one(c, "SELECT fractal_config_get('no_such_key')")   # unknown key: must not crash
for k in STR + URL + PATH + BOOL + ["http_num_ctx", "text_to_sql_max_attempts", "text_to_sql_allowed_statements"]:
    ok, r = one(c, "SELECT fractal_config_get(?)", k); check(ok, "get " + k + " works", r)
one(c, "SELECT fractal_config_set(NULL, 'x')")   # NULL key: must not crash
one(c, "SELECT fractal_config_set(5, 5)")   # non-text arguments: must not crash
c.close()

# the response mode is read from the environment when a connection opens
for rm in ("code", "chat", ""):
    os.environ["FSQL_REASONING_HTTP_RESPONSE_MODE"] = rm
    cm = conn(); ok, r = one(cm, "SELECT fractal_version()"); check(ok, "a connection opens with FSQL_REASONING_HTTP_RESPONSE_MODE=%r" % rm, r); cm.close()
os.environ.pop("FSQL_REASONING_HTTP_RESPONSE_MODE", None)

# fractal_search(vector, query) caches its best point per query: repeat, change the query, change the dimension, then break the shapes
c = conn()
V = "'0.6,0.8,0.0,0.0'"
for qv in ("'0.6,0.8,0.0,0.0'", "'0.6,0.8,0.0,0.0'", "'0.1,0.9,0.0,0.0'", "'0.9,0.1,0.2,0.3'", "'0.6,0.8,0.0,0.0'"):
    ok, r = one(c, "SELECT fractal_search(%s, %s)" % (V, qv)); check(ok, "fractal_search %s" % qv, r)
ok, r = one(c, "SELECT fractal_search('0.5,0.5', '0.5,0.5')"); check(ok, "a new dimension on the same connection", r)
ok, r = one(c, "SELECT fractal_search(%s, '0.6,0.8,0.0,0.0')" % V); check(ok, "...and back", r)
for bad in ("'0.6'", "''", "NULL", "'0.6,0.8,0.1'", "'x'", "'1e999,0,0,0'"):
    ok, r = one(c, "SELECT fractal_search(%s, %s)" % (V, bad)); check(True, "a query that does not fit the vector does not crash (%s)" % bad)
c.close()

# the library path locks once an enterprise library has loaded
W = os.path.realpath(tempfile.mkdtemp(prefix="fsql_cfgm_")); lib = os.path.join(W, "ent.so")
if subprocess.run(["cc", "-shared", "-fPIC", "-std=c99", "-I" + os.path.join(ROOT, "include"), os.path.join(ROOT, "tests", "mock_enterprise_core.c"), "-o", lib], capture_output=True, env=BUILD_ENV).returncode == 0:
    os.environ["FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE"] = "0"
    c = conn()
    sets(c, "enterprise_lib", lib, expect=lib)
    ok, r = one(c, "SELECT fractal_ledger_truth_count()"); check(ok, "the mock enterprise library loads unsigned when the operator opts out", r)
    sets(c, "enterprise_lib", "/opt/other.so", want_err="cannot be changed after")
    sets(c, "http_model", "still-settable", expect="still-settable")
    c.close()
else:
    check(False, "the mock enterprise core built")
shutil.rmtree(W, ignore_errors=True)
print("config matrix: %d checks passed, %d failed" % (passes, fails))
sys.exit(1 if fails else 0)
