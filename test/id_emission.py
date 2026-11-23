#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""test/id_emission.py -- how the domain agents write a row's id into their JSON result (run by gate 51).

The id column is the caller's data, so what the agent writes must never become JSON structure: an id is written as a JSON number only when
the WHOLE text is one (RFC 8259: no leading zero, a digit after '.', a digit in an exponent), otherwise as a string carrying the text exactly,
with every control character, quote and backslash escaped. fractal_agent_track_anomaly writes the id of the nearest track, and its
reasoning step is answered by tests/embed_then_fail_plugin.c (scripted: one short reply per call).
Env: FSQL_EXT (the extension). Needs a C compiler for the plugin. Exit status is nonzero when a check fails."""
import json, os, sqlite3, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.dirname(HERE)
EXT = os.path.abspath(os.environ.get("FSQL_EXT") or os.path.join(ROOT, "fractalsql.so"))
if not os.path.exists(EXT):
    print("  FAIL need the built extension (FSQL_EXT)"); sys.exit(1)
WORK = os.path.realpath(tempfile.mkdtemp(prefix="fsql_idemit_"))   # canonical: the extension refuses a plugin or library path that goes through a symlink (macOS /var -> /private/var)
PLUG = os.path.join(WORK, "embed_then_fail_plugin.so")
_cc_env = {k: v for k, v in os.environ.items() if k not in ("LD_PRELOAD", "DYLD_INSERT_LIBRARIES")}
r = subprocess.run(["cc", "-shared", "-fPIC", "-std=c99", "-I" + os.path.join(ROOT, "include"), os.path.join(ROOT, "tests", "embed_then_fail_plugin.c"), "-o", PLUG],
                   capture_output=True, text=True, env=_cc_env)
if r.returncode != 0:
    print("  FAIL the scripted plugin did not build:\n" + r.stderr); sys.exit(1)
import math
HEADING = ",".join("%.4f" % (math.sin(i * 0.37) + (i % 7) * 0.05) for i in range(64))
os.environ["FSQL_REASONING_REQUIRE_SIGNATURE"] = "0"
os.environ["FSQL_ETF_SCRIPT"] = "\x1e".join(["the routing is sound"] * 400)     # one reply per reasoning call; the plugin counts calls per process
passes = fails = 0
def conn():
    c = sqlite3.connect(":memory:"); c.enable_load_extension(True); c.load_extension(EXT)
    for k, v in (("reasoning_plugin", PLUG), ("http_url", "https://l.invalid/v1"), ("http_model", "m")):
        c.execute("SELECT fractal_config_set(?, ?)", (k, v))
    return c
def check(cond, what, detail=""):
    global passes, fails
    if cond: passes += 1
    else: fails += 1; print("  FAIL %s %s" % (what, ("-- " + str(detail)[:250]) if detail else ""))

# (id text, written as a number?)
IDS = (("42", True), ("0", True), ("-0", True), ("-7", True), ("10.5", True), ("-0.25", True), ("1e5", True), ("1E-3", True), ("2.5e+10", True), ("0.5", True),
       ("007", False), ("00", False), ("-", False), ("+5", False), (".5", False), ("1.", False), ("1e", False), ("1e+", False), ("0x10", False),
       ("12abc", False), ("abc", False), (" 5", False), ("5 ", False), ("", False), ("true", False), ("null", False), ("NaN", False), ("Infinity", False),
       ('{"x":1', False), ('["a"', False), ('quote " and backslash \\', False), ("tab\there", False), ("line\nbreak", False), ("cr\rhere", False),
       ("back\bspace and form\ffeed", False), ("ctl\x01\x02\x1f end", False), ("slash / and unicode é 日本 😀", False), ("-" + "9" * 400, True), ("1" + "0" * 400, True))
for text, as_number in IDS:
    c = conn()
    c.execute("CREATE TABLE trk(id TEXT, cur TEXT)"); c.execute("INSERT INTO trk VALUES (?, '0.1,0.1,0.1,0.1')", (text,))
    try:
        raw = c.execute("SELECT fractal_agent_track_anomaly('trk','cur','0.1,0.1,0.1,0.1','0.7,-0.4,-0.8,0.9',?,5,'id')", (HEADING,)).fetchone()[0]
        got = json.loads(raw)["nearest_fleet_id"]
    except Exception as e:
        check(False, "id %r: the result is valid JSON" % text[:40], e); continue
    if as_number: check(isinstance(got, (int, float)) and not isinstance(got, bool), "id %r is written as a JSON number" % text[:40], (got, raw[:120]))
    else: check(got == text, "id %r is written as the same string" % text[:40], (got, raw[:120]))
c = conn()
c.execute("CREATE TABLE trk(id TEXT, cur TEXT)"); c.execute("INSERT INTO trk VALUES (NULL, '0.1,0.1,0.1,0.1')")
raw = c.execute("SELECT fractal_agent_track_anomaly('trk','cur','0.1,0.1,0.1,0.1','0.7,-0.4,-0.8,0.9',?,5,'id')", (HEADING,)).fetchone()[0]
check(json.loads(raw)["nearest_fleet_id"] is None, "a NULL id is written as null", raw[:120])
print("id_emission: %d checks passed, %d failed" % (passes, fails)); sys.exit(1 if fails else 0)
