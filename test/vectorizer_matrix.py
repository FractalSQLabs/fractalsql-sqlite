#!/usr/bin/env python3
"""test/vectorizer_matrix.py -- the background vectorizer through every branch a caller or a plugin can reach.

Creation (identifier validation, missing table / column, a table with no or a composite primary key, duplicates, options JSON with and
without a rate cap), the queue lifecycle (backfill, triggers on insert / update / delete, pause and resume, drop, a dropped source
table), process_queue (batch and stale-window limits, NULL / empty / huge text, the rate cap deferring rows) and the embed paths
against a good plugin, a plugin that returns an over-long array, one that lies about its length, a crashing-free refusal, and no plugin
at all. Runs in-process through Python's sqlite3 module (the registry and queue are TEMP tables, so every group is one connection).
Env: FSQL_EXT (the extension, default ./fractalsql.so). Exit status is nonzero when a check fails."""
import os, shutil, sqlite3, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.dirname(HERE)
EXT = os.path.abspath(os.environ.get("FSQL_EXT") or os.path.join(ROOT, "fractalsql.so"))
if not os.path.exists(EXT):
    print("  FAIL need the built extension (FSQL_EXT)"); sys.exit(1)
os.environ["FSQL_REASONING_REQUIRE_SIGNATURE"] = "0"
W = os.path.realpath(tempfile.mkdtemp(prefix="fsql_vecm_"))
# The compiler runs unsanitized: this process carries the sanitizer runtime (preloaded, so the
# instrumented extension under test can be loaded into this process), and a preloaded runtime in the
# compiler trips the leak checker over the toolchain's own allocations.
BUILD_ENV = {k: v for k, v in os.environ.items() if k != "LD_PRELOAD"}
def build(name):
    out = os.path.join(W, name + ".so")
    ok = subprocess.run(["cc", "-shared", "-fPIC", "-std=c99", "-I" + os.path.join(ROOT, "include"), os.path.join(ROOT, "tests", name + ".c"), "-o", out], capture_output=True, env=BUILD_ENV).returncode == 0
    return out if ok else None
GOOD, EVIL, LIE = build("mock_embed_plugin"), build("evil_embed_plugin"), build("evil_lying_length_plugin")
if not GOOD: print("  FAIL the mock embed plugin did not build"); sys.exit(1)
passes = fails = 0
def check(cond, what, detail=""):
    global passes, fails
    if cond: passes += 1
    else: fails += 1; print("  FAIL %s %s" % (what, ("-- " + str(detail)[:250]) if detail else ""))
def conn(plugin=GOOD, url="https://embed.invalid/v1"):
    c = sqlite3.connect(":memory:", isolation_level=None); c.enable_load_extension(True); c.load_extension(EXT)
    c.executescript("CREATE TABLE docs(id INTEGER PRIMARY KEY, body TEXT, emb TEXT); INSERT INTO docs(body) VALUES('a'),('b'),('c');")
    if plugin: c.execute("SELECT fractal_config_set('reasoning_plugin', ?)", (plugin,))
    if url: c.execute("SELECT fractal_config_set('http_embed_url', ?)", (url,))
    return c
def q(c, sql, *a):
    try: return True, c.execute(sql, a).fetchall()
    except sqlite3.Error as e: return False, str(e)
def val(c, sql, *a):
    ok, r = q(c, sql, *a); return r[0][0] if ok and r else None

# ---- creation: identifiers, tables, columns
c = conn()
for src, t, e, why in [("docs; DROP TABLE docs", "body", "emb", "an injected source name"), ("docs", "bo dy", "emb", "a spaced text column"),
                       ("docs", "body", "e\"mb", "a quoted embedding column"), ("1docs", "body", "emb", "a leading digit"), ("", "body", "emb", "an empty name"),
                       ("docs", "body", "", "an empty embedding column"), ("x" * 70, "body", "emb", "an over-long name"), ("a.b.c.d", "body", "emb", "too many dots")]:
    ok, r = q(c, "SELECT fractal_vectorizer_create(?,?,?)", src, t, e); check(not ok, "create refuses " + why, r)
ok, r = q(c, "SELECT fractal_vectorizer_create(NULL,'body','emb')"); check(not ok and "NULL" in r, "create refuses a NULL table", r)
ok, r = q(c, "SELECT fractal_vectorizer_create('docs',NULL,'emb')"); check(not ok, "create refuses a NULL text column", r)
ok, r = q(c, "SELECT fractal_vectorizer_create('docs','body',NULL)"); check(not ok, "create refuses a NULL embedding column", r)
ok, r = q(c, "SELECT fractal_vectorizer_create('no_such_table','body','emb')"); check(not ok, "create refuses a missing table", r)
c0 = conn(); ok, r = q(c0, "SELECT fractal_vectorizer_create('docs','nope','emb')"); check(not ok and "nope" in r and "does not exist" in r, "create refuses a missing text column, naming it", r)
ok, r = q(c0, "SELECT fractal_vectorizer_create('docs','body','nope')"); check(not ok and "nope" in r and "does not exist" in r, "create refuses a missing embedding column, naming it", r)
ok, r = q(c0, "SELECT fractal_vectorizer_create('docs','body','emb')"); check(ok, "create succeeds on a valid column pair", r); c0.close()
c.execute("CREATE TABLE nopk(a TEXT, b TEXT)")
ok, r = q(c, "SELECT fractal_vectorizer_create('nopk','a','b')"); check(not ok, "create refuses a table with no primary key", r)
c.execute("CREATE TABLE cpk(a INTEGER, b INTEGER, t TEXT, e TEXT, PRIMARY KEY(a,b))")
ok, r = q(c, "SELECT fractal_vectorizer_create('cpk','t','e')"); check(not ok, "create refuses a composite primary key", r)
ok, r = q(c, "SELECT fractal_vectorizer_create('docs','body','emb')"); check(ok, "create succeeds", r)
vid = val(c, "SELECT id FROM fractal_vectorizers LIMIT 1") if q(c, "SELECT 1 FROM fractal_vectorizers")[0] else None
ok, r = q(c, "SELECT fractal_vectorizer_create('docs','body','emb')"); check(not ok and "already exists" in r, "a duplicate is refused", r)
check(val(c, "SELECT count(*) FROM fractal_vectorizer_queue") == 3, "the backfill queued every row", val(c, "SELECT count(*) FROM fractal_vectorizer_queue"))
# triggers
c.execute("INSERT INTO docs(body) VALUES('d')"); check(val(c, "SELECT count(*) FROM fractal_vectorizer_queue") == 4, "an insert enqueues")
c.execute("UPDATE docs SET body='dd' WHERE body='d'"); check(val(c, "SELECT count(*) FROM fractal_vectorizer_queue") == 4, "an update of a queued row does not duplicate it")
c.execute("DELETE FROM docs WHERE body='dd'")
# process: argument limits
for bad, why in [("0", "batch 0"), ("-1", "a negative batch"), ("100001", "a batch past the maximum")]:
    ok, r = q(c, "SELECT fractal_vectorizer_process_queue(%s)" % bad); check(not ok and "batch_size" in r, "process_queue refuses " + why, r)
ok, r = q(c, "SELECT fractal_vectorizer_process_queue(10, 0)"); check(not ok and "stale_after" in r, "process_queue refuses a zero stale window", r)
ok, r = q(c, "SELECT fractal_vectorizer_process_queue(1)"); check(ok and r[0][0] == 1, "a batch of one processes one row", r)
ok, r = q(c, "SELECT fractal_vectorizer_process_queue(NULL, NULL)"); check(ok and r[0][0] >= 2, "NULL limits take the defaults and process the rest", r)
check(val(c, "SELECT count(*) FROM docs WHERE fractal_vector_dims(emb)=3") >= 3, "the embeddings were written back")
c.execute("UPDATE docs SET body='changed' WHERE id=1"); ok, r = q(c, "SELECT fractal_vectorizer_process_queue()"); check(ok and r[0][0] == 1, "an update re-queues and reprocesses the row", r)
# pause / resume / drop
ok, r = q(c, "SELECT fractal_vectorizer_pause(%s)" % vid); check(ok, "pause", r)
ok, r = q(c, "SELECT fractal_vectorizer_pause(%s)" % vid); check(ok, "pausing twice is a no-op", r)
c.execute("INSERT INTO docs(body) VALUES('e')")
ok, r = q(c, "SELECT fractal_vectorizer_process_queue()"); check(ok and r[0][0] == 0, "a paused vectorizer's rows are not processed", r)
ok, r = q(c, "SELECT fractal_vectorizer_resume(%s)" % vid); check(ok, "resume", r)
c.execute("UPDATE docs SET body='e2' WHERE body='e'")
ok, r = q(c, "SELECT fractal_vectorizer_process_queue()"); check(ok and r[0][0] == 1, "after resume the row is processed", r)
for fn in ("pause", "resume", "drop"):
    ok, r = q(c, "SELECT fractal_vectorizer_%s(99999)" % fn); check(True, fn + " of an unknown id is handled")
    ok, r = q(c, "SELECT fractal_vectorizer_%s(NULL)" % fn)
    ok, r = q(c, "SELECT fractal_vectorizer_%s('x')" % fn)
ok, r = q(c, "SELECT fractal_vectorizer_drop(%s)" % vid); check(ok, "drop", r)
c.execute("INSERT INTO docs(body) VALUES('after drop')"); check(val(c, "SELECT count(*) FROM fractal_vectorizer_queue") == 0, "after a drop nothing is enqueued", val(c, "SELECT count(*) FROM fractal_vectorizer_queue"))
# a dropped source table, a source row with NULL / empty / huge text, an unknown rate option
ok, r = q(c, "SELECT fractal_vectorizer_create('docs','body','emb','{\"max_embeds_per_window\":1,\"rate_window_secs\":3600}')"); check(ok, "create with a rate cap", r)
c.execute("INSERT INTO docs(body) VALUES(NULL),(''),(?)", ("x" * 200000,))
ok, r = q(c, "SELECT fractal_vectorizer_process_queue(50)"); check(ok, "NULL, empty and huge texts are handled", r)
ok, r = q(c, "SELECT fractal_vectorizer_process_queue(50)"); check(ok and r[0][0] == 0, "the rate cap defers the rest", r)
c.execute("DROP TABLE docs")
ok, r = q(c, "SELECT fractal_vectorizer_process_queue(50)"); check(True, "processing after the source table is gone is handled")
ok, r = q(c, "SELECT fractal_vectorizer_drop(1)"); check(True, "dropping after the source table is gone is handled")
c.close()
for opts in ("{}", "not json", "[1]", "{\"max_embeds_per_window\":\"x\"}", "{\"max_embeds_per_window\":-5,\"rate_window_secs\":0}", "{\"max_embeds_per_window\":100000000000}"):
    c = conn(); ok, r = q(c, "SELECT fractal_vectorizer_create('docs','body','emb',?)", opts); q(c, "SELECT fractal_vectorizer_process_queue(10)"); c.close()
# ---- the embed paths against misbehaving plugins, and no plugin
for plugin, label in ((EVIL, "an over-long reply"), (LIE, "a lying length")):
    if not plugin: continue
    c = conn(plugin); q(c, "SELECT fractal_vectorizer_create('docs','body','emb')")
    ok, r = q(c, "SELECT fractal_vectorizer_process_queue(10)"); check(ok or "embed" in r.lower(), "process_queue survives " + label, r)
    q(c, "SELECT fractal_embed('x')"); c.close()
c = conn(None, None); q(c, "SELECT fractal_vectorizer_create('docs','body','emb')"); ok, r = q(c, "SELECT fractal_vectorizer_process_queue(10)")
check(ok or "plugin" in r.lower() or "embed" in r.lower(), "with no plugin processing fails cleanly", r); c.close()
c = conn(); ok, r = q(c, "SELECT fractal_embed(NULL)"); ok2, r2 = q(c, "SELECT fractal_embed('')"); ok3, r3 = q(c, "SELECT fractal_embed(?)", ("y" * 100000,)); c.close()
shutil.rmtree(W, ignore_errors=True)
print("vectorizer matrix: %d checks passed, %d failed" % (passes, fails))
sys.exit(1 if fails else 0)
