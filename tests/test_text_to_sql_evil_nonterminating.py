#!/usr/bin/env python3
"""tests/test_text_to_sql_evil_nonterminating.py — memory-safety evil test.

Locks in the fix for a real over-read: the reasoning ABI supplies
summary_len but does NOT promise the response `summary` is
NUL-terminated, and the loadable-extension surface loads out-of-tree
plugins. If fractal_text_to_sql() ever treats `summary` as a C string
again (strstr/strchr/strlen without the length), it will read past the
buffer.

This test builds a hostile plugin (tests/evil_nonterminating_plugin.c)
that returns a non-NUL-terminated `summary` positioned flush against a
PROT_NONE guard page, so ANY read of summary[summary_len] SIGSEGVs the
process deterministically -- not "maybe, off heap slack". It then drives
both the GENERATE path (extract_sql_from_response) and, with review on,
the review path (t2s_review), asserting the process does NOT crash (the
connection stays alive). With the length-bounded handling in place, the
pipeline runs; without it, the process dies here.

SQLite port: the hostile plugin is configured per-connection with
fractal_text_to_sql via fractalsql_set('reasoning_plugin', ...) instead
of a GUC; the deployed-feature probe asks the SQL surface directly (no
pg_proc catalog on SQLite).

POSIX-only (mmap/mprotect). Skip-safe: exits 0 with a SKIP message if
not on a POSIX platform, cc is missing, the extension isn't built, or
the feature isn't deployed.

Usage:
    FRACTALSQL_EXT=... python3 tests/test_text_to_sql_evil_nonterminating.py
"""
import os
import subprocess
import sys
import tempfile

from _t2s_common import configure_reasoning, connect_or_skip

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)


def skip(msg):
    print(f"SKIP: {msg}")
    sys.exit(0)


def fail(msg):
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def connection_alive(conn):
    """True if the process is still usable (no crash), else False."""
    try:
        cur = conn.cursor()
        cur.execute("SELECT 1")
        return cur.fetchone()[0] == 1
    except Exception:
        return False


def build_evil_plugin(outdir):
    src = os.path.join(HERE, "evil_nonterminating_plugin.c")
    inc = os.path.join(REPO, "include")
    if not os.path.isfile(os.path.join(inc, "fractalsql_sql.h")):
        skip(f"ABI header not found under {inc} (run from a source checkout)")
    so = os.path.join(outdir, "evil_nonterminating_plugin.so")
    cc = os.environ.get("CC", "cc")
    try:
        subprocess.run(
            [cc, "-shared", "-fPIC", "-std=c99", f"-I{inc}", src, "-o", so],
            check=True, capture_output=True)
    except FileNotFoundError:
        skip(f"compiler {cc!r} not found")
    except subprocess.CalledProcessError as e:
        skip(f"could not build evil plugin: {e.stderr.decode(errors='replace')}")
    return so


def main():
    if os.name != "posix":
        skip("guard-page technique is POSIX-only")

    conn = connect_or_skip()
    if conn is None:
        return 0
    cur = conn.cursor()

    # Feature present? No pg_proc on SQLite -- probe the SQL surface
    # directly. "no such function" means not deployed; any other error
    # (e.g. reasoning plugin not configured, no visible tables) means
    # deployed, and the scenario configures it itself below.
    try:
        cur.execute("SELECT fractal_text_to_sql('probe')")
    except Exception as e:
        if "no such function" in str(e).lower():
            skip(f"fractal_text_to_sql not deployed: {e}")

    # A table must exist so schema_context succeeds and the pipeline
    # actually reaches the plugin's response (the code path under test).
    cur.execute("CREATE TABLE IF NOT EXISTS _t2s_evil_target (id int)")

    tmp = tempfile.mkdtemp(prefix="fsql_evil_")
    plugin = build_evil_plugin(tmp)
    plugin = os.path.abspath(plugin)

    # The plugin returns its built-in default of bare "SELECT 1" (no
    # fence, no trailing NUL, guard page immediately after the 8 bytes).
    # Bare SQL means the GENERATE extraction has to walk the buffer with
    # no delimiter to stop it early -- an unbounded walk crosses into the
    # guard page. We can't override the default from here: the plugin
    # reads FSQL_EVIL_SQL_FILE from the *process* environment at load
    # time and this test cannot inject env into the host process's
    # dlopen'd plugin portably, so the default is exactly what we assert
    # on.
    passed = 0

    # ---- GENERATE path (review off): extract_sql_from_response ----
    # Per-connection config takes effect immediately; a fresh
    # connection between scenarios keeps the scenarios independent.
    configure_reasoning(cur, plugin, "http://127.0.0.1:1/unused",
                        use_review=False, max_attempts=1,
                        allowed_statements="select")
    try:
        result = cur.execute(
            "SELECT fractal_text_to_sql('q')").fetchone()[0]
    except Exception as e:
        if not connection_alive(conn):
            fail("process CRASHED handling a non-NUL-terminated response "
                 "in the GENERATE path (over-read past summary_len)")
        fail(f"unexpected error (process alive, so not the over-read): {e}")
    if not connection_alive(conn):
        fail("process CRASHED in the GENERATE path (over-read)")
    if "SELECT 1" not in (result or ""):
        fail(f"GENERATE returned unexpected SQL {result!r} (expected to "
             "contain 'SELECT 1')")
    print("OK: GENERATE path handled a guard-paged non-terminated "
          f"response without over-read (returned {result!r})")
    passed += 1

    # ---- REVIEW path (review on): t2s_review ----
    configure_reasoning(cur, plugin, "http://127.0.0.1:1/unused",
                        use_review=True, max_attempts=1,
                        allowed_statements="select")
    # With review on, the review dispatch returns the same guard-paged
    # buffer; t2s_review must copy it length-bounded before inspecting
    # it. The verdict will be FAIL ("SELECT 1" isn't "PASS..."), so this
    # call is EXPECTED to error -- we only assert the process did not
    # CRASH.
    try:
        cur.execute("SELECT fractal_text_to_sql('q')")
        cur.fetchone()
    except Exception:
        pass
    if not connection_alive(conn):
        fail("process CRASHED in the REVIEW path (t2s_review over-read "
             "of a non-NUL-terminated response)")
    print("OK: REVIEW path handled a guard-paged non-terminated response "
          "without over-read (process alive)")
    passed += 1

    cur.execute("DROP TABLE IF EXISTS _t2s_evil_target")
    conn.close()

    print(f"OK: {passed}/2 evil non-terminating-response scenarios passed "
          "(no over-read, process never crashed)")
    return 0


if __name__ == "__main__":
    sys.exit(main())