#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""test/scripted_replies.py -- the extension against a model that answers exactly what the test scripts (run by gate 51).

tests/embed_then_fail_plugin.c answers each call with the next reply of FSQL_ETF_SCRIPT (and fails once the script is used up), so a test
chooses what the extension has to parse. Every scenario runs in its own sqlite3 shell (the plugin counts calls per process).
  * embedding replies: a vector in every shape the parser takes or refuses (brackets, spacing, trailing text, an empty reply, nested arrays);
  * text-to-SQL replies: the SQL in a fenced block in every shape (case, no language tag, unterminated, a second block), bare SQL with
    leading comments, and the statements the allowlist refuses (EXPLAIN in each form, DML, two statements, an empty reply);
  * model-generated SQL that calls a function which must not run from generated SQL: refused or failed (at validation, or at execution; the
    agent's result carries the status, not the error text) and nothing changed;
  * the vectorizer's chunking options, each out of range and each mode, and the chunk size and output limits;
  * the environment variable that sets the ledger row limit at start.
Env: FSQL_EXT (the extension), SQLITE3. Needs a C compiler for the plugin."""
import json, os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.dirname(HERE)
EXT = os.path.abspath(os.environ.get("FSQL_EXT") or os.path.join(ROOT, "fractalsql.so"))
# The shell's .load tokenizer splits on spaces, so a path with a space in it has to be handed in the
# form the CLI can read (the harness knows both forms; FSQL_EXT_LOAD is the CLI-safe one).
EXT_LOAD = os.environ.get("FSQL_EXT_LOAD") or EXT
SQLITE3 = os.environ.get("SQLITE3") or shutil.which("sqlite3")
if not SQLITE3 or not os.path.exists(EXT):
    print("  FAIL need the sqlite3 shell and the built extension (FSQL_EXT)"); sys.exit(1)
WORK = os.path.realpath(tempfile.mkdtemp(prefix="fsql_scripted_"))   # canonical: the extension refuses a plugin or library path that goes through a symlink (macOS /var -> /private/var)
# A harness that already built the plugin hands its path in, so this driver needs no compiler of its
# own (the Windows runner builds it once and passes it down).
PLUG = os.environ.get("FSQL_EMBED_THEN_FAIL_PLUGIN")
# (a sanitizer runtime preloaded for the shells below must not be preloaded into the compiler)
_cc_env = {k: v for k, v in os.environ.items() if k not in ("LD_PRELOAD", "DYLD_INSERT_LIBRARIES")}
CC = os.environ.get("FSQL_CC") or "cc"
if not PLUG:
    PLUG = os.path.join(WORK, "embed_then_fail_plugin.so")
    r = subprocess.run([CC, "-shared", "-fPIC", "-std=c99", "-I" + os.path.join(ROOT, "include"), os.path.join(ROOT, "tests", "embed_then_fail_plugin.c"), "-o", PLUG],
                       capture_output=True, text=True, env=_cc_env)
    if r.returncode != 0:
        print("  FAIL the scripted plugin did not build:\n" + r.stderr); sys.exit(1)
RS = "\x1e"
passes = fails = 0
def check(cond, what, detail=""):
    global passes, fails
    if cond: passes += 1
    else: fails += 1; print("  FAIL %s %s" % (what, ("-- " + str(detail)[:260]) if detail else ""))

BAD = ("Segmentation fault", "Aborted", "AddressSanitizer", "runtime error:", "Sanitizer", "double free", "corrupted")
def run(script, stmts, env=None, plugin=True, timeout=120):
    """Runs the statements in a fresh shell; returns (returncode, stdout, stderr). The plugin is the model, scripted by `script` (a list of replies)."""
    e = dict(os.environ, FSQL_REASONING_REQUIRE_SIGNATURE="0", FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE="0")
    if script is not None: e["FSQL_ETF_SCRIPT"] = RS.join(script)
    e.update(env or {})
    pre = [".load " + EXT_LOAD, "CREATE TABLE a(x INTEGER, y TEXT); INSERT INTO a VALUES (1,'one');"]
    if plugin:
        pre += ["SELECT fractal_config_set('reasoning_plugin','%s');" % PLUG, "SELECT fractal_config_set('http_url','https://l.invalid/v1');",
                "SELECT fractal_config_set('http_embed_url','https://e.invalid/v1');", "SELECT fractal_config_set('http_model','m');"]
    try:
        p = subprocess.run([SQLITE3, ":memory:"], input="\n".join(pre + [".print ==="] + stmts), capture_output=True, text=True, env=e, timeout=timeout)
    except subprocess.TimeoutExpired:
        # The statement did not finish inside its budget: it is bounded (the process was
        # killed, not crashed), which is what this case asserts.
        return 124, "", ""   # 124 is the timeout convention, and crashed() reads it as "bounded"
    out = p.stdout.split("===\n", 1)[-1].strip()
    return p.returncode, out, p.stderr
def crashed(rc, err): return rc < 0 or any(b in err for b in BAD)

# --- embedding replies -----------------------------------------------------------------------------------------------------------------
EMB = (("[0.1,0.2,0.3]", "03000000"), ("[1]", "01000000"), ("][0.1]", "01000000"), ("[0.1,0.2", "02000000"), (" [ 0.1 , 0.2 ] ", "02000000"),
       ("[0.1,0.2,0.3] trailing", "03000000"), ("[1e999]", None),
       ("no vector", "ERR"), ("[]", "ERR"), ("", "ERR"), ('{"data":[{"embedding":[0.1,0.2]}]}', "ERR"), ("[0.1,abc]", "ERR"), ("0.1,0.2]", "ERR"),
       ("[[1,2],[3,4]]", "ERR"))
for reply, want in EMB:
    rc, out, err = run([reply], ["SELECT hex(substr(fractal_embed('x'),1,4));"])
    if crashed(rc, err): check(False, "embedding reply %r: the shell survived" % reply, err); continue
    if want is None: check(True, "embedding reply %r: handled" % reply)
    elif want == "ERR": check(rc != 0 and "fractalsql" in err, "embedding reply %r is refused with a clean error" % reply, (rc, out, err[-160:]))
    else: check(rc == 0 and out.startswith(want), "embedding reply %r is a %d-dim vector" % (reply, int(want[:2], 16)), (rc, out, err[-160:]))

# --- text-to-SQL replies ---------------------------------------------------------------------------------------------------------------
T2S = (("```sql\nSELECT 1\n```", "SELECT 1"), ("```SQL\nSELECT 1```", "SELECT 1"), ("```sqlx\nSELECT 1\n```", "SELECT 1"), ("```\nSELECT 1\n```", "SELECT 1"),
       ("```sql\nSELECT 1", "SELECT 1"), ("SELECT 1", "SELECT 1"), ("```text\nSELECT 1\n```", "SELECT 1"), ("  -- c\n SELECT 1", "-- c"),
       ("/* c */ SELECT 1", "/* c */ SELECT 1"), ("here: ```sql\nSELECT x FROM a\n``` done", "SELECT x FROM a"),
       ("```sql\nSELECT 1```\n```sql\nSELECT 2```", "SELECT 1"),
       ("```sql", "ERR"), ("```sql\n```", "ERR"), ("EXPLAIN QUERY PLAN SELECT 1", "ERR"), ("explain select 1", "ERR"), ("EXPLAIN", "ERR"),
       ("EXPLAIN QUERY SELECT 1", "ERR"), ("", "ERR"), ("   ", "ERR"), ("DELETE FROM a", "ERR"), ("SELECT 1; SELECT 2", "ERR"))
for reply, want in T2S:
    rc, out, err = run([reply], ["SELECT fractal_text_to_sql('q');"])
    if crashed(rc, err): check(False, "text-to-SQL reply %r: the shell survived" % reply, err); continue
    if want == "ERR": check(rc != 0 and "fractalsql" in err, "text-to-SQL reply %r is refused" % reply, (rc, out, err[-160:]))
    else: check(rc == 0 and want in out, "text-to-SQL reply %r returns the statement" % reply, (rc, out, err[-160:]))

# --- fractal_sql_agent: the reply the model gave, and the table_names argument ----------------------------------------------------------------
AGENT_OK = ("```sql\nSELECT x FROM a\n```", "  \n\t\r```sql\nSELECT 1```", "```\nSELECT 1\n```", "\fSELECT 1", "SELECT 1 \f\v ", "-- note\nSELECT 1",
            "/* c */SELECT 1", "SELECT 1 -- tail", "SELECT 1;\n\t ", "SELECT 1; ")
AGENT_REFUSED = ("```sqlSELECT 1```", "```sql", "```", "\vSELECT 1", "/* unterminated SELECT 1", "SELECT 1; SELECT 2", "SELECT 1; /* c */",
                 "PRAGMA writable_schema=ON", "ATTACH 'x' AS y", "BEGIN", "", "SELECT 1 ```")
for reply in AGENT_OK + AGENT_REFUSED:
    rc, out, err = run([reply], ["SELECT fractal_sql_agent('q', NULL, 1, 0);"])
    if crashed(rc, err): check(False, "sql_agent reply %r: the shell survived" % reply, err); continue
    want = "success" if reply in AGENT_OK else "validation_failed"
    check(rc == 0 and ('"execution_status":"%s"' % want) in out, "sql_agent reply %r is %s" % (reply, want), (rc, out[:140], err[-120:]))
TN_OK = ('["a"]', '  \n\t\r["a","b2"]', '[ "a" , "b2" ]', '[]', '', '["a" "b2"]', '["a",]', '["a"]x')
TN_SHAPE = ('"a"', '["a",', '[1]', '[null]', '{"a":1}')
TN_NONE = ('["a\\n"]', '["a\\"q"]', '["a\\\\"]', '["a\\u0041"]', '["nope"]')
for tn in TN_OK + TN_SHAPE + TN_NONE:
    arg = "'%s'" % tn.replace("'", "''")
    rc, out, err = run(["SELECT 1"], ["SELECT fractal_sql_agent('q', %s, 1, 0);" % arg])
    if crashed(rc, err): check(False, "sql_agent table_names %r: the shell survived" % tn, err); continue
    if tn in TN_OK: check(rc == 0 and '"execution_status":"success"' in out, "sql_agent table_names %r is accepted" % tn, (rc, out[:120], err[-120:]))
    elif tn in TN_SHAPE: check(rc != 0 and "table_names must be a JSON array" in err, "sql_agent table_names %r is refused as not a JSON array of names" % tn, (rc, err[-160:]))
    else: check(rc != 0 and "no matching tables" in err, "sql_agent table_names %r names no table" % tn, (rc, err[-160:]))

# --- rag_agent's meta_filter: what the parser accepts (and which rows each filter keeps), and what it refuses before any embedding is asked for ----------
# rows: id 1 tag a n 1.5 | id 2 tag b n -3 | id 3 tag a n 100 | id 4 tag NULL n NULL
FILTER_SETUP = ["CREATE TABLE d(id INTEGER PRIMARY KEY, tag TEXT, n REAL, emb TEXT); INSERT INTO d VALUES (1,'a',1.5,'0.1,0.2,0.3'),(2,'b',-3,'0.9,0.1,0.0'),(3,'a',100,'0.0,0.8,0.5'),(4,NULL,NULL,'0.2,0.2,0.2');"]
FILTERS = (("{}", {1, 2, 3, 4}), ("{ }", {1, 2, 3, 4}), ("{}  ", {1, 2, 3, 4}), ("  ", {1, 2, 3, 4}), ("", {1, 2, 3, 4}),
           ('{"tag":"a"}', {1, 3}), ('{"id":1}', {1}), ('{"n":1.5}', {1}), ('{"n":-3}', {2}), ('{"n":1e2}', {3}), ('{"n":null}', {4}), ('{"tag":null}', {4}),
           ('{"id":1,"tag":"a"}', {1}), ('{"tag":"a","tag":"a"}', {1, 3}),
           ('{"n":true}', "NOROWS"), ('{"tag":false}', "NOROWS"), ('{"id":1,"tag":"b"}', "NOROWS"), ('{"tag":"\\u0061"}', "NOROWS"), ('{"n":1.}', "NOROWS"),
           ("{} x", "FLAT"), ("[1]", "FLAT"), ('{"id":2,}', "FLAT"), ('{"tag":"a" "n":1}', "FLAT"), ('{"tag":}', "FLAT"), ('{"tag" "a"}', "FLAT"),
           ('{"tag":"a"', "FLAT"), ('{"n":+1}', "FLAT"), ('{"n":.5}', "FLAT"), ('{"n":--1}', "FLAT"), ('{"n":1e}', "FLAT"))
for flt, want in FILTERS:
    rc, out, err = run(["[0.1,0.2,0.3]", "ok"], FILTER_SETUP + ["SELECT fractal_rag_agent('q','d','emb','%s');" % flt.replace("'", "''")])
    if crashed(rc, err): check(False, "meta_filter %r: the shell survived" % flt, err); continue
    if isinstance(want, set):
        try: got = set(json.loads(out)["source_row_ids"])
        except Exception as e: got = ("unparsed", out[:100], e)
        check(got == want, "meta_filter %r keeps rows %s" % (flt, sorted(want)), (got, err[-120:]))
    elif want == "NOROWS": check(rc != 0 and "no rows found" in err, "meta_filter %r matches no row and says so" % flt, (rc, out[:80], err[-140:]))
    else: check(rc != 0 and "meta_filter must be a flat JSON object" in err, "meta_filter %r is refused as not a flat object of pairs" % flt, (rc, out[:80], err[-140:]))

# --- generated SQL that calls what generated SQL must not call: refused (at validation, or at execution), the shell survives -------------
CALLS = ("fractal_embed('x')", "fractal_sql_agent('q')", "fractal_index_create('a','y')", "fractal_index_rebuild('ix')", "fractal_index_drop('ix')",
         "fractal_index_refresh('ix')", "fractal_index_ensure('a','y')", "fractal_vectorizer_create('a','y','x')", "fractal_vectorizer_drop(1)",
         "fractal_vectorizer_process_queue(1)", "fractal_vectorizer_pause(1)", "fractal_vectorizer_resume(1)", "fractal_store_morphology(1,'[1,2]')",
         "fractal_mine_topology_negatives('[1]','a','y',1)", "fractal_set_actor('x')", "fractal_lock_destructive()", "fractal_isolate_background(1)",
         "fractal_feedback_report(1,'positive')", "fractal_diversify_set_params('{}')", "fractal_diversify_enable()", "fractal_diversify_disable()",
         "fractal_config_set('text_to_sql_max_attempts','9')", "fractal_audit_log('k','{}')", "fractal_ledger_flush()", "fractal_ledger_compact()",
         "fractal_ledger_reset_soft()", "fractal_ledger_reset_hard()", "fractal_ledger_load()")
MARK = ("not permitted from model-generated SQL", "changes state", "execution_failed", "not permitted", "validation_failed")
for call in CALLS:
    rc, out, err = run(["SELECT " + call], ["SELECT fractal_sql_agent('q', NULL, 1, 1);", "SELECT fractal_config_get('text_to_sql_max_attempts');"])
    if crashed(rc, err): check(False, "generated SQL calling %s: the shell survived" % call.split("(")[0], err); continue
    blob = out + err
    check(any(m in blob for m in MARK) and not out.rstrip().endswith("9"), "generated SQL calling %s is refused and changes nothing" % call.split("(")[0], (rc, out[-160:], err[-160:]))

# --- the vectorizer's chunking options -------------------------------------------------------------------------------------------------
def vz(opts, tag):
    return ["CREATE TABLE v%s(id INTEGER PRIMARY KEY, body TEXT, emb BLOB); INSERT INTO v%s(body) VALUES ('First paragraph here.\n\nSecond one is short. Third, a bit longer.');" % (tag, tag),
            "SELECT fractal_vectorizer_create('v%s','body','emb','%s');" % (tag, opts)]
BADOPT = (("size 0", '{"chunk_size":0}'), ("size past 100000", '{"chunk_size":100001}'), ("overlap below 0", '{"chunk_size":10,"chunk_overlap":-1}'),
          ("overlap equal to size", '{"chunk_size":10,"chunk_overlap":10}'), ("an unknown mode", '{"chunk_size":10,"chunk_mode":"bogus"}'),
          ("a chunk table name that is not an identifier", '{"chunk_size":10,"chunk_table":"bad name"}'),
          ("a chunk table name that starts with a digit", '{"chunk_size":10,"chunk_table":"1abc"}'),
          ("a chunk table name that is too long to quote", '{"chunk_size":10,"chunk_table":"%s"}' % ("t" * 120)))
for i, (what, opts) in enumerate(BADOPT):
    rc, out, err = run(None, vz(opts, "b%d" % i), plugin=False)
    check(not crashed(rc, err) and rc != 0 and "fractal" in err, "a vectorizer with %s is refused" % what, (rc, out, err[-160:]))
for i, mode in enumerate(("fixed", "paragraph", "sentence")):
    rc, out, err = run(None, vz('{"chunk_size":20,"chunk_overlap":3,"chunk_mode":"%s"}' % mode, "g%d" % i) + ["SELECT count(*) > 0 FROM v%s_chunks;" % ("g%d" % i)], plugin=False)
    check(rc == 0 and out.strip().endswith("1"), "a vectorizer with chunk_mode %s chunks the existing rows" % mode, (rc, out, err[-160:]))

# --- chunk size and output limits ------------------------------------------------------------------------------------------------------
rc, out, err = run(None, ["SELECT length(fractal_chunk_text(printf('%.*c', 100200, 'x'), 1, 0, 'fixed'));"], plugin=False)
check(not crashed(rc, err), "more than 100000 chunks is bounded, not a crash", (rc, out[-80:], err[-120:]))
rc, out, err = run(None, ["SELECT length(fractal_chunk_text(printf('%.*c', 150000, 'x'), 100000, 99999, 'fixed'));"], plugin=False, timeout=45)
check(not crashed(rc, err), "a result past the output limit is bounded, not a crash", (rc, out[-80:], err[-120:]))
rc, out, err = run(None, ["SELECT length(fractal_chunk_text('a  b' || char(10) || char(10) || '   ' || char(10) || 'c. d!  ', 3, 1, 'paragraph'));",
                          "SELECT length(fractal_chunk_text('  one.   two!  ', 4, 1, 'sentence'));"], plugin=False)
check(rc == 0 and not crashed(rc, err), "chunking text with blank paragraphs and runs of spaces is handled", (rc, out, err[-160:]))

# --- FSQL_LEDGER_MAX_ROWS: the value a connection starts with -------------------------------------------------------------------------
for val, ok in (("500", True), ("abc", False), ("", False), ("-5", False), ("99999999999999999999", False)):
    rc, out, err = run(None, ["SELECT fractal_config_get('ledger_max_rows');"], env={"FSQL_LEDGER_MAX_ROWS": val}, plugin=False)
    check(rc == 0 and not crashed(rc, err) and (out.strip() == "500" if ok else out.strip() != "500"),
          "FSQL_LEDGER_MAX_ROWS=%r %s" % (val, "sets the starting value" if ok else "leaves the default"), (rc, out, err[-120:]))

print("scripted_replies: %d checks passed, %d failed" % (passes, fails)); sys.exit(1 if fails else 0)
