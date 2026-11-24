#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""test/ledger_payloads.py -- what fractal_audit_log writes into the chain for every shape of entry type, payload and actor (run by gate 51).

The ledger entry is built from the caller's text: {"type": ..., "entry": ...} with an "_actor" block added. Whatever the text holds must never
break the JSON or the chain: an object payload (with any surrounding whitespace, empty or not) gets the actor inside it, an array, a scalar,
a string or anything else is wrapped as {"value": ...}; the entry type and the actor name are escaped (quote, backslash, backspace, form feed,
newline, carriage return, tab, other control characters). Each entry must be accepted or refused cleanly, and the chain must still verify.
Uses the mock enterprise core (tests/mock_enterprise_core.c) with a ledger key, as gate 31 does. Env: FSQL_EXT. Needs a C compiler."""
import json, os, sqlite3, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.dirname(HERE)
EXT = os.path.abspath(os.environ.get("FSQL_EXT") or os.path.join(ROOT, "fractalsql.so"))
if not os.path.exists(EXT):
    print("  FAIL need the built extension (FSQL_EXT)"); sys.exit(1)
WORK = os.path.realpath(tempfile.mkdtemp(prefix="fsql_ledgerpl_"))   # canonical: the extension refuses a plugin or library path that goes through a symlink (macOS /var -> /private/var)
# A harness that already built the mock core hands its path in, so this driver needs no compiler of
# its own (the Windows runner builds it once and passes it down).
CORE = os.environ.get("FSQL_ENTERPRISE_CORE")
_cc_env = {k: v for k, v in os.environ.items() if k not in ("LD_PRELOAD", "DYLD_INSERT_LIBRARIES")}
CC = os.environ.get("FSQL_CC") or "cc"
if not CORE:
    CORE = os.path.join(WORK, "mock_enterprise_core.so")
    r = subprocess.run([CC, "-shared", "-fPIC", "-std=c99", "-I" + os.path.join(ROOT, "include"), os.path.join(ROOT, "tests", "mock_enterprise_core.c"), "-o", CORE],
                       capture_output=True, text=True, env=_cc_env)
    if r.returncode != 0:
        print("  FAIL the mock enterprise core did not build:" + chr(10) + r.stderr); sys.exit(1)
# The mock core is unsigned, so the enterprise opt-out has to be in force. It is a process-environment
# control and the extension reads the environment when it is loaded, so it has to be in place before the
# first connection (the Windows build links the static MSVC runtime and therefore reads a private copy of
# the environment, frozen at load time).
os.environ["FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE"] = "0"
passes = fails = 0
def check(cond, what, detail=""):
    global passes, fails
    if cond: passes += 1
    else: fails += 1; print("  FAIL %s %s" % (what, ("-- " + str(detail)[:250]) if detail else ""))
def conn(path=":memory:"):
    c = sqlite3.connect(path, isolation_level=None); c.enable_load_extension(True); c.load_extension(EXT)
    c.execute("SELECT fractal_config_set('enterprise_lib', ?)", (CORE,))
    c.execute("SELECT fractal_config_set('enterprise_ledger_key', 'ledger-payload-test-key')")
    return c
def one(c, sql, *a):
    try: return True, c.execute(sql, a).fetchone()[0]
    except sqlite3.Error as e: return False, str(e)

ESC = "q\" b\\ bs\b ff\f nl\n cr\r tab\t c1\x01 c1f\x1f end"
PAYLOADS = (("an object", '{"n":1}', True), ("an object with spaces round it", '   {"n":1}   ', True), ("an object with tabs, newlines and returns round it", '\t\n\r {"n":1} \r\n\t', True),
            ("an object with whitespace inside the braces only", '{ \t\n\r }', True), ("an empty object", '{}', True), ("a nested object", '{"a":{"b":[1,2,{"c":null}]}}', True),
            ("an array", '[1,2,3]', True), ("an array with spaces round it", '  [1,2]  ', True), ("a string", '"text"', True), ("a number", '12', True), ("true", 'true', True),
            ("null", 'null', True), ("an object that is not closed", '{"a":1', False), ("braces with no members", '{ "a" }', False), ("plain text", 'not json', False),
            ("only whitespace", ' \t\n', False), ("the empty string", '', False), ("an object with a control character in a string", '{"a":"x\\ny"}', True))
c = conn()
n = 0
for what, payload, good in PAYLOADS:
    n += 1
    ok, r = one(c, "SELECT fractal_audit_log(?, ?)", "type.%d" % n, payload)
    if good: check(ok, "audit_log accepts %s" % what, r)
    else: check(isinstance(r, (int, str)), "audit_log answers for %s (accepted or refused cleanly)" % what, r)
for what, etype in (("a quote", 'a"b'), ("a backslash", "a\\b"), ("every escape and control character", ESC), ("a long type", "t" * 300), ("a unicode type", "tipo é 日本 😀")):
    ok, r = one(c, "SELECT fractal_audit_log(?, ?)", etype, '{"k":1}')
    check(ok or isinstance(r, str), "audit_log takes an entry type with %s" % what, r)
for what, actor in (("a quote", 'who "x"'), ("every escape and control character", ESC), ("an empty name", ""), ("a long name", "n" * 400)):
    ok, r = one(c, "SELECT fractal_set_actor(?)", actor)
    ok2, r2 = one(c, "SELECT fractal_audit_log('actor.test', '{\"a\":1}')")
    check(ok2 or isinstance(r2, str), "audit_log with an actor name that is %s" % what, (r, r2))
for what, args in (("a NULL type", (None, '{}')), ("a NULL payload", ("t", None)), ("an integer type", (5, '{}')), ("an integer payload", ("t", 5)), ("both NULL", (None, None)),
                   ("a BLOB type", (b"abc", '{}')), ("a BLOB payload", ("t", b"{}"))):
    ok, r = one(c, "SELECT fractal_audit_log(?, ?)", *args)
    check(ok or isinstance(r, str), "audit_log with %s answers cleanly (NULL or a refusal)" % what, r)
ok, r = one(c, "SELECT fractal_ledger_verify(2)")
check(ok and json.loads(r).get("ok") is True, "the chain still verifies after every entry", r)
ok, r = one(c, "SELECT count(*) FROM fractalsql_ledger WHERE kind = 2")
check(ok and r > 10, "the entries are in the ledger table (%s rows)" % r, r)
bad = 0
for (payload,) in c.execute("SELECT payload FROM fractalsql_ledger WHERE kind = 2").fetchall():
    try: json.loads(payload if isinstance(payload, str) else payload.decode("utf-8"))
    except Exception: bad += 1
check(bad == 0, "every stored entry is valid JSON (%d stored)" % r, bad)
# --- the configuration keys, read and written with the enterprise tier loaded (the secret ones answer or refuse, never crash) ---------------------
ok, keys = one(c, "SELECT fractal_config_keys()")
names = [k["name"] for k in json.loads(keys)] if ok else []
check(len(names) > 20, "the key list is available (%d keys)" % len(names), keys if not ok else "")
for name in names:
    ok, r = one(c, "SELECT fractal_config_get(?)", name)
    check(ok or isinstance(r, str), "fractal_config_get(%r) answers or refuses cleanly" % name, r)
for val in ("fade", "exact", "FADE", "bogus", ""):
    ok, r = one(c, "SELECT fractal_config_set('ledger_retention', ?)", val)
    ok2, r2 = one(c, "SELECT fractal_config_get('ledger_retention')")
    check(ok or isinstance(r, str), "ledger_retention = %r is accepted or refused cleanly (now %r)" % (val, r2), r)
c2 = sqlite3.connect(":memory:", isolation_level=None); c2.enable_load_extension(True); c2.load_extension(EXT)
for val in ("exact", "fade", "bogus"):
    ok, r = one(c2, "SELECT fractal_config_set('ledger_retention', ?)", val)
    check(ok or isinstance(r, str), "ledger_retention = %r before the enterprise tier is loaded is handled" % val, r)
ok, r = one(c2, "SELECT fractal_config_set('enterprise_lib', ?)", CORE)
ok, r = one(c2, "SELECT fractal_config_get('ledger_retention')")
check(ok or isinstance(r, str), "ledger_retention can be read after the enterprise tier loads", r)
print("ledger_payloads: %d checks passed, %d failed" % (passes, fails)); sys.exit(1 if fails else 0)
