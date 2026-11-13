#!/usr/bin/env python3
"""test/plugin_gate.py -- every way the reasoning plugin can be refused before it is loaded (src/fsql_plugin_verify.h).

A plugin needs a detached Ed25519 signature (<plugin>.sig, exactly 64 bytes) unless the process environment says
FSQL_REASONING_REQUIRE_SIGNATURE=0; a .sig that is present is always checked and a wrong one is always refused. A valid signature needs
the vendor's private key, so what is driven here is every refusal, and the unsigned load the operator can opt into.
Env: FSQL_EXT (the extension, default ./fractalsql.so), SQLITE3. Exit status is nonzero when a check fails."""
import os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.dirname(HERE)
SQLITE3 = os.environ.get("SQLITE3") or shutil.which("sqlite3")
EXT = os.path.abspath(os.environ.get("FSQL_EXT") or os.path.join(ROOT, "fractalsql.so"))
if not SQLITE3 or not os.path.exists(EXT):
    print("  FAIL need the sqlite3 shell and the built extension (FSQL_EXT)"); sys.exit(1)
W = os.path.realpath(tempfile.mkdtemp(prefix="fsql_plugate_"))
PLUG = os.path.join(W, "plug.so")
# The compiler runs unsanitized: this process carries the sanitizer runtime (preloaded, so the
# instrumented extension under test can be loaded into the host), and a preloaded runtime in the
# compiler trips the leak checker over the toolchain's own allocations.
BUILD_ENV = {k: v for k, v in os.environ.items() if k != "LD_PRELOAD"}
if subprocess.run(["cc", "-shared", "-fPIC", "-std=c99", "-I" + os.path.join(ROOT, "include"), os.path.join(ROOT, "tests", "mock_reasoning_plugin.c"), "-o", PLUG], capture_output=True, env=BUILD_ENV).returncode != 0:
    print("  FAIL the mock plugin did not build"); sys.exit(1)
passes = fails = 0
def run(plugin, env=None, sig=None):
    if sig is not None: open(plugin + ".sig", "wb").write(sig)
    e = {k: v for k, v in os.environ.items() if not k.startswith("FSQL_REASONING") and not k.startswith("FRACTALSQL_ENTERPRISE")}
    e.update(env or {})
    script = ".load %s\nSELECT fractal_config_set('reasoning_plugin','%s');\nSELECT fractal_reason('ping');\nSELECT fractal_reason('ping');\n" % (EXT, plugin)
    p = subprocess.run([SQLITE3, "-batch", ":memory:"], input=script, capture_output=True, text=True, env=e, timeout=60)
    return p.stdout + p.stderr
def check(out, want, what, absent=False):
    global passes, fails
    good = (want not in out) if absent else (want in out)
    if good: passes += 1
    else: fails += 1; print("  FAIL %s -- wanted %s%r in %r" % (what, "no " if absent else "", want, out[-300:]))
def clean(path):
    try: os.remove(path + ".sig")
    except OSError: pass

OFF = {"FSQL_REASONING_REQUIRE_SIGNATURE": "0"}
out = run(PLUG, sig=b"\0" * 64);               check(out, "failed signature verification", "a 64-byte .sig that does not verify is refused")
out = run(PLUG, env=OFF, sig=b"\0" * 64);      check(out, "failed signature verification", "...even when signatures are optional")
out = run(PLUG, sig=b"\1" * 10);               check(out, "failed signature verification", "a short .sig is refused")
out = run(PLUG, sig=b"\1" * 65);               check(out, "failed signature verification", "a long .sig is refused")
out = run(PLUG, sig=b"");                      check(out, "failed signature verification", "an empty .sig is refused")
clean(PLUG)
out = run(PLUG);                               check(out, "no signature found", "a missing .sig is refused by default")
out = run(PLUG, env={"FSQL_REASONING_REQUIRE_SIGNATURE": "1"}); check(out, "no signature found", "...and when required explicitly")
out = run(PLUG, env=OFF);                      check(out, "without a signature", "an unsigned plugin loads when the operator opts out, with a warning"); check(out, "no signature found", "(and is not refused)", absent=True)
GONE = os.path.join(W, "gone.so")
out = run(GONE);                               check(out, "cannot be read for verification", "a plugin that does not exist fails closed")
out = run(GONE, env=OFF);                      check(out, "cannot be read for verification", "(opted out it is the loader's error instead)", absent=True)
os.mkdir(os.path.join(W, "adir.so"))
out = run(os.path.join(W, "adir.so"));         check(out, "cannot be read for verification", "a directory is not a plugin")
out = run(os.path.join(W, "adir.so"), env=OFF); check(out, "rror", "...nor when signatures are optional")
LONG = os.path.join(W, "y" * 1100 + ".so")
out = run(LONG, env=OFF);                      check(out, "rror", "a plugin path too long to name its .sig is not accepted")
shutil.rmtree(W, ignore_errors=True)
print("plugin gate: %d checks passed, %d failed" % (passes, fails))
sys.exit(1 if fails else 0)
