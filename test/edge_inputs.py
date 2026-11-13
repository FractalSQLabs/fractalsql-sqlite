#!/usr/bin/env python3
"""test/edge_inputs.py -- edge-input matrix for every registered fractal* SQL function.

For each overload in pragma_function_list it builds calls that vary ONE argument at a time through a pool of awkward values (NULL,
empty, huge, NaN/Infinity, negative, malformed JSON, vectors of the wrong shape, ...) while the others hold a plausible value, plus an
all-NULL call and an all-typical call. A variadic function (arity -1) is tried at 1 to 5 arguments. Each function runs in its own
sqlite3 shell session (state a call leaves behind cannot mask the next function); statements that raise an error do not stop the
session, so every statement executes.

What is asserted: no statement may crash the process, trip a sanitizer, or leave the session unable to finish. Ordinary SQL errors are
the expected outcome for most of these inputs and are not failures. The point is branch coverage of the argument-validation and error
paths, and a robustness floor. SQLite has no INTERNAL-error class, so a crash (a signal, an abort, a sanitizer report) is the failure.

Configurations (each a full pass over the catalog):
  configured   mock reasoning plugin + mock embedding plugin + mock enterprise core loaded (the deep paths)
  bare         nothing configured (the not-configured / dormant-tier paths)
Then a short pass with the mock plugin set to misbehave (rc / empty / garbage), driving the agents, text_to_sql and the vectorizer
through their outage and bad-reply handling.

Env: FSQL_EXT (the extension; default ./fractalsql.so), SQLITE3, EDGE_CONFIGS=configured,bare,fail (default all), EDGE_MAX_OVERLOADS
(debug), EDGE_ENT=<mock enterprise variant>, plus any process environment to run the whole matrix under (FSQL_AUDIT_REDACT, ...).
Exit status is nonzero when any function crashed."""
import os, re, shutil, subprocess, sys, tempfile, time
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SQLITE3 = os.environ.get("SQLITE3") or shutil.which("sqlite3")
EXT = os.path.abspath(os.environ.get("FSQL_EXT") or os.path.join(ROOT, "fractalsql.so"))
if not SQLITE3 or not os.path.exists(EXT):
    print("  FAIL need the sqlite3 shell and the built extension (FSQL_EXT)"); sys.exit(1)
CONFIGS = os.environ.get("EDGE_CONFIGS", "configured,bare,fail").split(",")
MAXO = int(os.environ.get("EDGE_MAX_OVERLOADS", "0") or 0)
WORKERS = int(os.environ.get("EDGE_WORKERS", "4"))
BAD = re.compile(r"Segmentation fault|Aborted|AddressSanitizer|UndefinedBehavior|runtime error:|Sanitizer|double free|corrupted|"
                 r"stack smashing|free\(\): invalid|core dumped|Assertion .* failed")

WORK = os.path.realpath(tempfile.mkdtemp(prefix="fsql_edge_"))
MOCKS = {}
for name in ("mock_reasoning_plugin", "mock_embed_plugin", "mock_enterprise_core"):
    src = os.path.join(ROOT, "tests", name + ".c")
    out = os.path.join(WORK, name + ".so")
    if os.path.exists(src) and subprocess.run(["cc", "-shared", "-fPIC", "-std=c99", "-I" + os.path.join(ROOT, "include"), src, "-o", out],
                                              capture_output=True).returncode == 0:
        MOCKS[name] = out
MOCK_FILES = {"sql": "/tmp/fractalsql_bt_sql.txt", "review": "/tmp/fractalsql_bt_review.txt", "fail": "/tmp/fractalsql_bt_fail.txt"}

PRELUDE = """
CREATE TABLE docs (id INTEGER PRIMARY KEY, label TEXT, emb TEXT);
INSERT INTO docs VALUES (1,'a','0.1,0.2,0.3'),(2,'b','0.9,0.1,0.0'),(3,'c','0.0,0.8,0.5'),(4,'d','0.3,0.3,0.3');
CREATE TABLE telemetry (ts INTEGER, host TEXT, cpu REAL, emb TEXT);
WITH RECURSIVE n(i) AS (SELECT 0 UNION ALL SELECT i+1 FROM n WHERE i < 59)
  INSERT INTO telemetry SELECT i, 'h1', sin(i*0.37)+(i%7)*0.05, '0.1,0.2,0.3' FROM n;
CREATE TABLE tiny (id INTEGER, emb TEXT);
"""
# plausible values, rotated across positions so different overloads get a sensible context
TYPICAL = ["'0.1,0.2,0.3'", "5", "10", "'docs'", "'emb'", "'{\"a\":1}'", "0.5", "'label'", "'id'", "3"]
POOL = ["NULL", "''", "' '", "'{'", "'[]'", "'{\"a\":'", "'it''s'", "'x;DROP TABLE docs'", "'SELECT 1'", "'nope'",
        "printf('%.*c', 5000, 'x')", "'üñï'", "'-1'", "'1e400'", "0", "-1", "1", "2147483647", "-2147483648", "100000",
        "9223372036854775807", "0.0", "-1.0", "1e308", "-1e308", "1e999", "-1e999", "'nan'", "'[nan]'", "'[1e999]'",
        "'[0.1,0.2'", "'0.1,0.2,0.3'", "'[0.1,0.2,0.3,0.4,0.5]'", "'[]'", "x''", "x'FF'", "x'0001'", "zeroblob(3000)",
        "'[' || replace(hex(zeroblob(2000)), '00', '1,') || '1]'", "'1,2,3,4,5,6'", "'[[1,2],[3,4]]'", "'{\"population_size\":5,\"iterations\":3}'"]
# functions that are slow with a large integer argument or that must not run for real from a sweep
SKIP = re.compile(r"^fractal_(ledger_reset_hard|ledger_reset_soft|lock_destructive)$")


def run_sql(statements, env_extra=None, timeout=240):
    env = dict(os.environ)
    env.pop("LD_PRELOAD", None) if os.environ.get("EDGE_KEEP_PRELOAD") != "1" else None
    env.update({"FSQL_REASONING_REQUIRE_SIGNATURE": "0", "FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE": "0"})
    env.update(env_extra or {})
    script = ".load %s\n%s" % (EXT, "\n".join(statements))
    try:
        p = subprocess.run([SQLITE3, "-batch", ":memory:"], input=script, capture_output=True, text=True,
                           encoding="utf-8", errors="replace", env=env, timeout=timeout)
    except subprocess.TimeoutExpired:
        return None, "", "timeout"
    return p.returncode, p.stdout, p.stderr


def catalog():
    rc, out, err = run_sql(["SELECT name || '|' || narg || '|' || type FROM pragma_function_list WHERE name LIKE 'fractal%' ORDER BY name, narg;"])
    byname = {}
    for line in out.split("\n"):
        parts = line.split("|")
        if len(parts) == 3 and parts[0].startswith("fractal"):
            byname.setdefault(parts[0], []).append((int(parts[1]), parts[2]))
    return byname


def stmts_for(name, narg, kind, depth):
    arities = [narg] if narg >= 0 else [1, 2, 3, 4, 5]
    out = []
    for n in arities:
        for rot in range(3 if depth == "full" else 1):
            typ = [TYPICAL[(i + rot * 3) % len(TYPICAL)] for i in range(n)]
            nulls = ["NULL"] * n
            for args in (typ, nulls):
                call = "%s(%s)" % (name, ", ".join(args))
                out.append(("SELECT %s FROM docs;" if kind == "a" else "SELECT %s;") % call)
            if depth == "bare" or rot > 0:
                continue
            for i in range(n):
                for bad in POOL:
                    args = list(typ); args[i] = bad
                    call = "%s(%s)" % (name, ", ".join(args))
                    out.append(("SELECT %s FROM docs;" if kind == "a" else "SELECT %s;") % call)
    return out


def sweep(label, depth, only=None, env_extra=None, fail_mode=None):
    cat = catalog()
    names = [n for n in sorted(cat) if not SKIP.match(n) and (not only or only(n))]
    if MAXO: names = names[:MAXO]
    env = dict(env_extra or {})
    pre = [PRELUDE]
    if label == "configured":
        if "mock_reasoning_plugin" in MOCKS: pre.append("SELECT fractal_config_set('reasoning_plugin', '%s');" % MOCKS["mock_reasoning_plugin"])
        ent = os.environ.get("EDGE_ENT")
        lib = MOCKS.get(ent or "mock_enterprise_core")
        if lib: env["FRACTALSQL_ENTERPRISE_LIB"] = lib
    elif label == "fail" and "mock_reasoning_plugin" in MOCKS:
        pre.append("SELECT fractal_config_set('reasoning_plugin', '%s');" % MOCKS["mock_reasoning_plugin"])
    for f in MOCK_FILES.values():
        try: os.remove(f)
        except OSError: pass
    with open(MOCK_FILES["sql"], "w") as fh: fh.write("SELECT count(*) FROM docs;")
    if fail_mode:
        with open(MOCK_FILES["fail"], "w") as fh: fh.write(fail_mode + "\n")

    def one(name):
        sts = []
        for narg, kind in cat[name]:
            sts += stmts_for(name, narg, kind, depth)
        rc, out, err = run_sql(pre + sts, env)
        crashed = rc is None and err != "timeout" or (rc is not None and (rc < 0 or rc >= 128)) or bool(BAD.search(err or ""))
        return name, len(sts), rc, err, crashed

    total = fails = 0
    with ThreadPoolExecutor(max_workers=WORKERS) as ex:
        for name, n, rc, err, crashed in ex.map(one, names):
            total += n
            if crashed:
                fails += 1
                print("  FAIL [%s%s] %s: rc=%s %r" % (label, "/" + fail_mode if fail_mode else "", name, rc, (err or "")[-240:]))
            elif err == "timeout":
                print("  note [%s] %s: the session did not finish in time (not counted)" % (label, name))
    print("  PASS [%s%s] %d functions swept (%s)" % (label, "/" + fail_mode if fail_mode else "", len(names), depth) if not fails else
          "  ---- [%s%s] %d function(s) crashed" % (label, "/" + fail_mode if fail_mode else "", fails))
    return total, fails


t0 = time.time()
total_stmts = fails = 0
AGENTISH = lambda n: re.search(r"agent|reason|embed|vectorizer|text_to_sql|explore|hybrid|rag|plan_|cross_modal|detect_loop|schema_context", n)
if "configured" in CONFIGS:
    t, f = sweep("configured", "full"); total_stmts += t; fails += f
if "bare" in CONFIGS:
    t, f = sweep("bare", "bare"); total_stmts += t; fails += f
if "fail" in CONFIGS:
    for mode in ("rc", "empty", "garbage"):
        t, f = sweep("fail", "bare", only=AGENTISH, fail_mode=mode); total_stmts += t; fails += f
for f in MOCK_FILES.values():
    try: os.remove(f)
    except OSError: pass
shutil.rmtree(WORK, ignore_errors=True)
print()
print("edge inputs: %d statements in %.0fs, %d function sweep(s) with a crash" % (total_stmts, time.time() - t0, fails))
sys.exit(1 if fails else 0)
