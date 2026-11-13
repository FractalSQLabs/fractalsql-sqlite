#!/usr/bin/env python3
"""test/enterprise_errors.py -- every way the enterprise library can be refused, through the real extension in the sqlite3 shell.

The loader checks a detached Ed25519 signature (<lib>.sig, exactly 64 bytes) before and after loading, then requires the eight ledger and
audit symbols. A valid signature needs FractalSQLabs' private key, so what can be driven from outside is every refusal: a wrong-sized or
wrong .sig (always fatal, even when signatures are optional), a missing .sig (fatal only when required, which is the default), a
library that cannot be read, one that is not an enterprise core, an attempt that is not retried, and the unsigned load the operator can
opt into with FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE=0.
Env: FSQL_EXT (the extension, default ./fractalsql.so), SQLITE3. Exit status is nonzero when a check fails."""
import os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.dirname(HERE)
SQLITE3 = os.environ.get("SQLITE3") or shutil.which("sqlite3")
EXT = os.path.abspath(os.environ.get("FSQL_EXT") or os.path.join(ROOT, "fractalsql.so"))
if not SQLITE3 or not os.path.exists(EXT):
    print("  FAIL need the sqlite3 shell and the built extension (FSQL_EXT)"); sys.exit(1)
W = os.path.realpath(tempfile.mkdtemp(prefix="fsql_enterr_"))
# The compiler runs unsanitized: this process carries the sanitizer runtime (preloaded, so the
# instrumented extension under test can be loaded into the host), and a preloaded runtime in the
# compiler trips the leak checker over the toolchain's own allocations.
BUILD_ENV = {k: v for k, v in os.environ.items() if k != "LD_PRELOAD"}
def build(src, out, extra=()):
    return subprocess.run(["cc", "-shared", "-fPIC", "-std=c99", "-I" + os.path.join(ROOT, "include"), src, "-o", out, *extra], capture_output=True, env=BUILD_ENV).returncode == 0
ENT = os.path.join(W, "ent.so"); NOSYM = os.path.join(W, "nosym.so")
open(os.path.join(W, "nosym.c"), "w").write("int fsql_nothing(void){return 0;}\n")
if not build(os.path.join(ROOT, "tests", "mock_enterprise_core.c"), ENT) or not build(os.path.join(W, "nosym.c"), NOSYM):
    print("  FAIL the test libraries did not build"); sys.exit(1)

passes = fails = 0
def run(lib, calls=1, env=None, sig=None):
    """One shell session: set enterprise_lib, call a ledger function `calls` times. Returns the combined output."""
    if sig is not None: open(lib + ".sig", "wb").write(sig)
    e = {k: v for k, v in os.environ.items() if not k.startswith("FRACTALSQL_ENTERPRISE")}
    e.update(env or {})
    script = ".load %s\nSELECT fractal_config_set('enterprise_lib','%s');\n%s" % (EXT, lib, "SELECT fractal_ledger_truth_count();\n" * calls)
    p = subprocess.run([SQLITE3, "-batch", ":memory:"], input=script, capture_output=True, text=True, env=e, timeout=60)
    return p.stdout + p.stderr
def check(out, want, what, absent=False):
    global passes, fails
    good = (want not in out) if absent else (want in out)
    if good: passes += 1
    else: fails += 1; print("  FAIL %s -- wanted %s%r in %r" % (what, "no " if absent else "", want, out[-300:]))
def clean(path):
    for p in (path + ".sig",):
        try: os.remove(p)
        except OSError: pass

OPT_OUT = {"FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE": "0"}
check(run("", env=OPT_OUT), "not loaded", "an empty enterprise_lib is reported")
out = run(ENT, sig=b"\0" * 64);               check(out, "failed signature verification", "a 64-byte .sig that does not verify is refused")
out = run(ENT, env=OPT_OUT, sig=b"\0" * 64);  check(out, "failed signature verification", "...even when signatures are optional")
out = run(ENT, sig=b"\1" * 10);               check(out, "failed signature verification", "a short .sig is refused")
out = run(ENT, sig=b"\1" * 65);               check(out, "failed signature verification", "a long .sig is refused (not silently truncated)")
out = run(ENT, sig=b"");                      check(out, "failed signature verification", "an empty .sig is refused")
clean(ENT)
out = run(ENT);                               check(out, "no signature found", "a missing .sig is refused by default")
out = run(ENT, env={"FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE": "1"}); check(out, "no signature found", "...and when required explicitly")
out = run(ENT, env=OPT_OUT);                  check(out, "not initialized", "an unsigned library loads when the operator opts out", absent=True); check(out, "refus", "(and is not refused)", absent=True)
out = run(ENT, calls=2);                      check(out, "earlier attempt failed", "a failed attempt is not retried on the same connection")
GONE = os.path.join(W, "gone.so")
out = run(GONE, sig=b"\2" * 64);              check(out, "could not read enterprise library", "an unreadable library with a well-formed .sig fails closed")
out = run(GONE, env=OPT_OUT, sig=b"\2" * 64); check(out, "could not load enterprise library", "...and, opted out, fails at the loader")
out = run(GONE, env=OPT_OUT);                 check(out, "could not load enterprise library", "a library that does not exist and has no .sig")
out = run(NOSYM, env=OPT_OUT);                check(out, "missing expected enterprise symbols", "a library that is not an enterprise core is refused")
LONG = os.path.join(W, "x" * 1100 + ".so")
out = run(LONG, env=OPT_OUT);                 check(out, "rror", "a path too long to name its .sig is refused somewhere, not silently accepted")
shutil.rmtree(W, ignore_errors=True)
print("enterprise errors: %d checks passed, %d failed" % (passes, fails))
sys.exit(1 if fails else 0)
