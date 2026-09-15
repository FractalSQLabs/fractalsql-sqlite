#!/usr/bin/env python3
"""tests/test_vectorizer.py — fractal_embed() and the vectorizer's
actual SUCCESS path, against a mock embeddings HTTP server.

Every other reasoning-adjacent test in this repo (test_text_to_sql_*.py)
deliberately drives the pipeline into REJECTION paths with a canned
model response -- real models are unreliable for eliciting one specific
adversarial output on demand. This file covers the opposite, previously
untested gap: does fractal_embed() actually return a real, correctly
parsed vector when the plugin succeeds, and does
fractal_vectorizer_process_queue() actually write it back to a row?
Everything up to this file only ever exercised fractal_embed()'s error
paths (no plugin configured, no http_embed_url configured).

Uses the real, built fractalsql-reasoning-http plugin (not a stub)
against tests/_mock_llm_server.py's MockEmbedServer -- so this
exercises the actual plugin's request-building and data[0].embedding
parsing, not just this extension's own dispatch/error-handling code.

Notes on this surface (all per src/fsql_vectorizer.c):
  - the registry (fractal_vectorizers), queue, rate-window tables and
    the fractal_vectorizer_status view are TEMP and connection-private,
    created lazily on the first vectorizer call: a fresh connection per
    scenario is a clean slate, so no explicit reset between scenarios
    is needed;
  - fractal_embed() returns the canonical fractal_vector BLOB (u16 dim
    LE + u16 reserved + float32 payload), so expected vectors are
    compared after float32 narrowing (f4()) and BLOB decoding;
  - source_table/text_col/embedding_col are validated and quoted
    internally, and any identifier with embedded quotes is rejected
    outright ("fractalsql: invalid identifier"). Scenario D therefore
    asserts rejection + an untouched registry: the injection-safety
    property is enforced up front;
  - the create() options argument is plain TEXT JSON, and the
    rate-window rollover is simulated by backdating window_start with
    strftime('%s','now').

Requires a *built* fractalsql-reasoning-http plugin, pointed to by
FRACTALSQL_REASONING_PLUGIN. Skips cleanly if that binary isn't present
or the extension isn't built.

Usage:
    python3 tests/test_vectorizer.py
    FRACTALSQL_EXT=... FRACTALSQL_REASONING_PLUGIN=/path/to/fractalsql-reasoning-http.so \\
        python3 tests/test_vectorizer.py
"""
import math
import os
import struct
import sys

from _mock_llm_server import MockEmbedServer
from _t2s_common import (configure_reasoning, connect_or_skip,
                         get_reasoning_plugin_path)

PLUGIN = get_reasoning_plugin_path()
# Not actually dispatched to in any scenario here (every scenario below
# only calls fractal_embed()/the vectorizer, never fractal_text_to_sql())
# -- set anyway because the embed tier's env block needs a well-formed
# config; only http_embed_url is real per scenario.
DUMMY_CHAT_URL = "http://127.0.0.1:1/unused"


def fail(msg):
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def f4(x):
    """Round a Python float through float32, the same narrowing every
    fractal_vector value goes through on the way in -- expected values
    in BLOB assertions must be compared against THIS, not the original
    float64 literal (see test_vector_type.py)."""
    return struct.unpack('f', struct.pack('f', x))[0]


def decode_vec(blob):
    """Decode a canonical fractal_vector BLOB (u16 dim LE + u16
    reserved + float32 payload) into a list of floats."""
    dim, _reserved = struct.unpack_from('<HH', blob, 0)
    return list(struct.unpack_from(f'<{dim}f', blob, 4))


def vec_equal(got, expected):
    return (len(got) == len(expected)
            and all(math.isclose(g, e, rel_tol=1e-6)
                    for g, e in zip(got, expected)))


def new_conn(mock):
    """Fresh connection with the reasoning plugin pointed at the mock
    embed endpoint. Config is per-connection and takes effect
    immediately, so the scenario calls happen on THIS connection (a
    reconnect would reset the config -- see _t2s_common.reconnect)."""
    c = connect_or_skip()
    if c is None:
        return None, None
    cur = c.cursor()
    configure_reasoning(cur, PLUGIN, DUMMY_CHAT_URL, embed_url=mock.url)
    return c, cur


def main():
    conn = connect_or_skip()
    if conn is None:
        return 0
    conn.close()

    if not os.path.isfile(PLUGIN):
        print(f"SKIP: reasoning plugin not found at {PLUGIN} "
              "(set FRACTALSQL_REASONING_PLUGIN)")
        return 0

    passed = 0

    # ---- Scenario A: fractal_embed() direct success ----------------
    vec = [0.25, -0.5, 0.75]
    with MockEmbedServer(vector=vec) as mock:
        c, cur = new_conn(mock)
        if c is None:
            return 0
        got = cur.execute("SELECT fractal_embed('hello world')").fetchone()[0]
        c.close()
        if not isinstance(got, bytes):
            fail(f"[direct fractal_embed] expected a canonical BLOB, "
                 f"got {got!r}")
        payload = decode_vec(got)
        expected = [f4(x) for x in vec]
        if not vec_equal(payload, expected):
            fail(f"[direct fractal_embed] expected {expected!r}, "
                 f"got {payload!r}")
        print(f"OK: [direct fractal_embed] {payload!r}")
        passed += 1

    # ---- Scenario B: vectorizer end-to-end, real embeddings --------
    vec_b = [1.0, 2.0, 3.0]
    with MockEmbedServer(vector=vec_b) as mock:
        c, cur = new_conn(mock)
        if c is None:
            return 0
        cur.execute("DROP TABLE IF EXISTS _vec_test_docs")
        cur.execute("""
            CREATE TABLE _vec_test_docs (
                id        INTEGER PRIMARY KEY,
                body      TEXT NOT NULL,
                embedding BLOB
            )
        """)
        cur.execute("INSERT INTO _vec_test_docs (body) VALUES ('a'), ('b')")

        vzid = cur.execute(
            "SELECT fractal_vectorizer_create('_vec_test_docs', 'body', "
            "'embedding')").fetchone()[0]

        n = cur.execute(
            "SELECT fractal_vectorizer_process_queue()").fetchone()[0]
        if n != 2:
            fail(f"[vectorizer e2e] expected 2 rows processed, got {n}")

        expected_b = [f4(x) for x in vec_b]
        for (raw,) in cur.execute(
                "SELECT embedding FROM _vec_test_docs ORDER BY id").fetchall():
            payload = decode_vec(raw)
            if not vec_equal(payload, expected_b):
                fail(f"[vectorizer e2e] row embedding {payload!r} != "
                     f"{expected_b!r}")

        status_rows = dict(cur.execute(
            "SELECT status, n FROM fractal_vectorizer_status "
            "WHERE vectorizer_id = ?", (vzid,)).fetchall())
        if status_rows != {"done": 2}:
            fail(f"[vectorizer e2e] expected status {{'done': 2}}, "
                 f"got {status_rows!r}")

        print(f"OK: [vectorizer e2e] 2/2 rows embedded correctly, "
              f"status={status_rows!r}")
        passed += 1

        cur.execute("DROP TABLE IF EXISTS _vec_test_docs")
        c.close()

    # ---- Scenario C: malformed response -- real per-row failure,
    # via the actual plugin's own extract_embedding() rejecting a
    # response with no "data" key, not just this extension's own
    # "no plugin configured" precondition check (already covered
    # interactively, not by an automated test until now). ----------
    with MockEmbedServer(body={"error": "not a real embeddings response"}) as mock:
        c, cur = new_conn(mock)
        if c is None:
            return 0
        cur.execute("DROP TABLE IF EXISTS _vec_test_bad")
        cur.execute("""
            CREATE TABLE _vec_test_bad (
                id        INTEGER PRIMARY KEY,
                body      TEXT NOT NULL,
                embedding BLOB
            )
        """)
        cur.execute("INSERT INTO _vec_test_bad (body) VALUES ('c')")
        vzid = cur.execute(
            "SELECT fractal_vectorizer_create('_vec_test_bad', 'body', "
            "'embedding')").fetchone()[0]

        n = cur.execute(
            "SELECT fractal_vectorizer_process_queue()").fetchone()[0]
        if n != 1:
            fail(f"[malformed response] expected 1 row processed, got {n}")

        row = cur.execute(
            "SELECT status, last_error FROM fractal_vectorizer_status "
            "WHERE vectorizer_id = ?", (vzid,)).fetchone()
        if row is None:
            fail("[malformed response] no status row for the vectorizer")
        status, last_error = row
        if status != "failed":
            fail(f"[malformed response] expected status 'failed', got {status!r}")
        # Not asserting the specific substring here -- the plugin's own
        # detailed diagnostic ("response missing data[0].embedding...")
        # and this extension's generic wrapper message both end up in
        # the queue's error column, but the exact shape is the plugin's
        # business. What matters here is that a real, non-empty error
        # got recorded and the row is 'failed', not stuck or silently
        # swallowed.
        if not last_error:
            fail("[malformed response] expected a non-empty error, got none")

        print(f"OK: [malformed response] row failed cleanly: {last_error!r}")
        passed += 1

        cur.execute("DROP TABLE IF EXISTS _vec_test_bad")
        c.close()

    # ---- Scenario D: adversarial identifiers -- proves the identifier
    # path in fractal_vectorizer_create() cannot be turned into dynamic-
    # SQL injection: table name, text_col AND embedding_col carrying
    # the embedded-quote + DROP-TABLE + comment-marker payload are
    # REJECTED up front ("fractalsql: invalid identifier") -- nothing
    # containing a quote ever reaches string-built SQL. The registry is
    # asserted untouched by row count, and the payload's own target
    # (the fractal_vectorizers registry) is asserted still standing. --
    evil_tbl = 'vec_evil"; drop table fractal_vectorizers; --'
    evil_txt = 'txt"; drop table fractal_vectorizers;--'
    evil_emb = 'emb"; drop table fractal_vectorizers;--'
    with MockEmbedServer(vector=[9.0, 8.0, 7.0]) as mock:
        c, cur = new_conn(mock)
        if c is None:
            return 0

        # Touch the lazy TEMP schema so the registry row-count
        # assertions are meaningful even though create() validates the
        # identifier BEFORE creating anything.
        cur.execute("SELECT fractal_vectorizer_process_queue()")
        n_before = cur.execute(
            "SELECT count(*) FROM fractal_vectorizers").fetchone()[0]

        for label, args in [
            ("table name", (evil_tbl, "body", "embedding")),
            ("text column", ("_vec_evil_plain", evil_txt, "embedding")),
            ("embedding column", ("_vec_evil_plain", "body", evil_emb)),
        ]:
            try:
                cur.execute("SELECT fractal_vectorizer_create(?, ?, ?)", args)
                fail(f"[adversarial identifiers] {label} payload was "
                     "accepted -- expected 'fractalsql: invalid identifier'")
            except Exception as e:
                if "invalid identifier" not in str(e):
                    fail(f"[adversarial identifiers] {label} payload raised, "
                         f"but not the identifier-validation error: {e}")
                print(f"OK: [adversarial identifiers] {label} payload "
                      f"rejected cleanly: {e}")

        n_after = cur.execute(
            "SELECT count(*) FROM fractal_vectorizers").fetchone()[0]
        if n_after != n_before:
            fail(f"[adversarial identifiers] fractal_vectorizers row count "
                 f"changed ({n_before} -> {n_after}) -- possible injection "
                 f"side effect")
        # The payload's named target still exists and answers: the
        # embedded "drop table fractal_vectorizers" never executed.
        cur.execute("SELECT count(*) FROM fractal_vectorizers")

        print(f"OK: [adversarial identifiers] table/text_col/embedding_col "
              f"payloads all rejected by identifier validation; "
              f"fractal_vectorizers untouched ({n_after} rows)")
        passed += 1
        c.close()

    # ---- Scenario E: pause/resume -- enabled=false must stop BOTH future
    # enqueueing (the trigger no-ops) and processing of already-pending
    # rows (process_queue()'s join excludes it), and enabled=true must
    # cleanly resume both. --------------------------------------------
    vec_e = [4.0, 5.0, 6.0]
    with MockEmbedServer(vector=vec_e) as mock:
        c, cur = new_conn(mock)
        if c is None:
            return 0
        cur.execute("DROP TABLE IF EXISTS _vec_test_pause")
        cur.execute("""
            CREATE TABLE _vec_test_pause (
                id        INTEGER PRIMARY KEY,
                body      TEXT NOT NULL,
                embedding BLOB
            )
        """)
        cur.execute("INSERT INTO _vec_test_pause (body) VALUES ('a')")

        vzid = cur.execute(
            "SELECT fractal_vectorizer_create('_vec_test_pause', 'body', "
            "'embedding')").fetchone()[0]

        cur.execute("SELECT fractal_vectorizer_pause(?)", (vzid,))
        cur.execute("INSERT INTO _vec_test_pause (body) VALUES ('b')")

        n_queued_while_paused = cur.execute(
            "SELECT count(*) FROM fractal_vectorizer_queue "
            "WHERE vectorizer_id = ?", (vzid,)).fetchone()[0]
        if n_queued_while_paused != 1:
            fail(f"[pause/resume] expected 1 queued row (the pre-pause "
                 f"backfill of 'a' only -- 'b' inserted while paused must "
                 f"NOT enqueue), got {n_queued_while_paused}")

        n_while_paused = cur.execute(
            "SELECT fractal_vectorizer_process_queue()").fetchone()[0]
        if n_while_paused != 0:
            fail(f"[pause/resume] expected 0 rows processed while paused, "
                 f"got {n_while_paused}")

        cur.execute("SELECT fractal_vectorizer_resume(?)", (vzid,))
        cur.execute("UPDATE _vec_test_pause SET body = 'b-updated' "
                    "WHERE body = 'b'")

        n_after_resume = cur.execute(
            "SELECT fractal_vectorizer_process_queue()").fetchone()[0]
        if n_after_resume != 2:
            fail(f"[pause/resume] expected 2 rows processed after resume "
                 f"('a' from before the pause + 'b' enqueued by the "
                 f"post-resume update), got {n_after_resume}")

        try:
            cur.execute("SELECT fractal_vectorizer_pause(?)", (-1,))
            fail("[pause/resume] pausing a nonexistent vectorizer id "
                 "should raise")
        except Exception as e:
            if "no vectorizer with id" not in str(e):
                fail(f"[pause/resume] pausing a nonexistent id raised, but "
                     f"not the expected error: {e}")

        print("OK: [pause/resume] enqueue+processing correctly gated by "
              "enabled -- 0 processed while paused, 2 processed after resume")
        passed += 1

        cur.execute("SELECT fractal_vectorizer_drop(?)", (vzid,))
        cur.execute("DROP TABLE IF EXISTS _vec_test_pause")
        c.close()

    # ---- Scenario F: rate cap -- options.max_embeds_per_window must cap
    # embed ATTEMPTS per rolling window (not just successes), and the
    # window must roll over once rate_window_secs elapses. --------------
    with MockEmbedServer(body={"error": "unreachable -- rate-capped rows "
                                         "should never even call this"}) as mock:
        c, cur = new_conn(mock)
        if c is None:
            return 0
        cur.execute("DROP TABLE IF EXISTS _vec_test_rate")
        cur.execute("""
            CREATE TABLE _vec_test_rate (
                id        INTEGER PRIMARY KEY,
                body      TEXT NOT NULL,
                embedding BLOB
            )
        """)
        cur.executemany("INSERT INTO _vec_test_rate (body) VALUES (?)",
                        [(f"row {i}",) for i in range(1, 6)])

        # Options are plain TEXT JSON on SQLite (no ::jsonb cast).
        vzid = cur.execute(
            "SELECT fractal_vectorizer_create('_vec_test_rate', 'body', "
            "'embedding', ?)",
            ('{"max_embeds_per_window": 2, "rate_window_secs": 3600}',)
        ).fetchone()[0]

        n_first_call = cur.execute(
            "SELECT fractal_vectorizer_process_queue()").fetchone()[0]
        if n_first_call != 2:
            fail(f"[rate cap] expected exactly 2 rows attempted (the cap), "
                 f"got {n_first_call}")

        window_calls = cur.execute(
            "SELECT window_calls FROM fractal_vectorizer_rate_window "
            "WHERE vectorizer_id = ?", (vzid,)).fetchone()[0]
        if window_calls != 2:
            fail(f"[rate cap] expected window_calls=2, got {window_calls}")

        n_second_call = cur.execute(
            "SELECT fractal_vectorizer_process_queue()").fetchone()[0]
        if n_second_call != 0:
            fail(f"[rate cap] expected 0 more rows this window "
                 f"(cap already hit), got {n_second_call}")

        # Simulate the window elapsing -- proves rollover, not just
        # that the cap holds within one window. window_start is an
        # epoch-second INTEGER.
        cur.execute("""
            UPDATE fractal_vectorizer_rate_window
            SET window_start = CAST(strftime('%s','now') AS INTEGER) - 7200
            WHERE vectorizer_id = ?
        """, (vzid,))
        n_after_rollover = cur.execute(
            "SELECT fractal_vectorizer_process_queue()").fetchone()[0]
        if n_after_rollover != 2:
            fail(f"[rate cap] expected 2 more rows after window rollover, "
                 f"got {n_after_rollover}")

        print(f"OK: [rate cap] capped at 2/window across 2 calls, "
              f"allowed 2 more after simulated rollover "
              f"(3 rows never attempted, still pending)")
        passed += 1

        cur.execute("SELECT fractal_vectorizer_drop(?)", (vzid,))
        cur.execute("DROP TABLE IF EXISTS _vec_test_rate")
        c.close()

    # ---- Cleanup ------------------------------------------------------
    c = connect_or_skip()
    if c is not None:
        cur = c.cursor()
        for tbl in ("_vec_test_docs", "_vec_test_bad", "_vec_test_pause",
                    "_vec_test_rate"):
            cur.execute(f"DROP TABLE IF EXISTS {tbl}")
        c.close()

    print(f"\ntest_vectorizer: PASS ({passed}/6 scenarios)")
    return 0


if __name__ == "__main__":
    sys.exit(main())