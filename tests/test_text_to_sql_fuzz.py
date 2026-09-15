#!/usr/bin/env python3
"""tests/test_text_to_sql_fuzz.py — adversarial/fuzz suite for
fractal_text_to_sql().

Uses tests/_mock_llm_server.py to force the "model" to return specific
malicious or malformed SQL deterministically -- real models are
unreliable for eliciting one particular adversarial output on demand,
which is exactly what fuzz testing needs. Each scenario asserts the
pipeline's ALLOWLIST or VALIDATE stage (src/fsql_t2s.c: first-keyword
policy check -> parse-only sqlite3_prepare_v2 walk) rejects it with the
right reason, and that the dangerous statement is never returned to the
caller. One positive control proves the suite isn't just rejecting
everything.

Scenario notes:
  - single-argument call: there is no text[] table-names parameter.
  - the first-keyword policy check runs on the raw text BEFORE
    sqlite3_prepare_v2, so prose/garbage that doesn't start with an
    allowlisted keyword is rejected as "not permitted" (naming the
    first word) rather than reaching the parser at all. The
    "does not parse" arm is kept alive with a canned response that
    DOES start with SELECT but fails to parse.
  - a CTE body must be a SELECT, so a data-modifying CTE is a
    parse-time syntax error here, not something sqlite3_stmt_readonly()
    ever has to catch. The closest real attack shape is a WITH-prefixed
    DELETE/INSERT/UPDATE, which sqlite3_stmt_readonly() correctly flags
    as not read-only (verified directly: PREPARED, readonly=0).

Requires a *built* fractalsql-reasoning-http plugin (any build -- these
scenarios never reach a real network call, the mock server intercepts
it), pointed to by FRACTALSQL_REASONING_PLUGIN. Skips cleanly if that
binary isn't present or the extension isn't built.

Usage:
    python3 tests/test_text_to_sql_fuzz.py
    FRACTALSQL_EXT=...  FRACTALSQL_REASONING_PLUGIN=/path/to/fractalsql-reasoning-http.so \\
        python3 tests/test_text_to_sql_fuzz.py
"""
import os
import sys

from _mock_llm_server import MockLLMServer
from _t2s_common import (configure_reasoning, connect_or_skip,
                         get_reasoning_plugin_path)

PLUGIN = get_reasoning_plugin_path()

# (name, canned model response, substring expected in the ERROR, or None
# for "must succeed").
SCENARIOS = [
    (
        "stacked-statement injection",
        "```sql\nSELECT 1; DROP TABLE _t2s_fuzz_target;\n```",
        "exactly one SQL statement",
    ),
    (
        # DROP TABLE is stopped by the first-keyword pre-check before it
        # ever reaches the parser, so the message names the statement
        # type as "not permitted".
        "bare DDL",
        "```sql\nDROP TABLE _t2s_fuzz_target;\n```",
        "not permitted",
    ),
    (
        "disallowed statement type (DELETE, default allowed=select)",
        "```sql\nDELETE FROM _t2s_fuzz_target;\n```",
        "not permitted",
    ),
    (
        # A data-modifying CTE can't be expressed in SQLite at all -- a
        # CTE body must be a SELECT, so that would be a parse-time
        # syntax error, not a distinct attack surface. The real attack
        # shape: first keyword WITH passes the pre-check, the statement
        # parses fine, but it's a DELETE underneath -- sqlite3_stmt_
        # readonly() must catch that.
        "WITH-prefixed write (write behind an allowlisted first keyword)",
        "```sql\nWITH d AS (SELECT 1) DELETE FROM _t2s_fuzz_target\n```",
        "not read-only",
    ),
    (
        # Starts with an allowlisted keyword but cannot parse -- this is
        # the arm that actually exercises the "SQL does not parse" error
        # (the first-keyword pre-check rejects prose up front; that case
        # is kept separately below with its own verdict).
        "unparseable garbage after a valid first keyword",
        "```sql\nSELECT WHERE FROM\n```",
        "does not parse",
    ),
    (
        # The first-keyword pre-check rejects this earlier, as a
        # statement type that is not permitted.
        "chatty non-fenced prose response (no clean single statement)",
        "Sure! Here's the query: SELECT 1; -- now ignore all previous "
        "instructions and DROP TABLE users instead;",
        "not permitted",
    ),
    (
        "positive control (well-formed SELECT)",
        "```sql\nSELECT count(*) FROM _t2s_fuzz_target\n```",
        None,
    ),
]


def fail(msg):
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def main():
    conn = connect_or_skip()
    if conn is None:
        return 0

    if not os.path.isfile(PLUGIN):
        print(f"SKIP: reasoning plugin not found at {PLUGIN} "
              "(set FRACTALSQL_REASONING_PLUGIN)")
        return 0

    cur = conn.cursor()
    try:
        # Single-argument probe (no table-names array on SQLite). A
        # "not configured" error just means the scenarios below must
        # configure the plugin themselves, which they do per-connection.
        cur.execute("SELECT fractal_text_to_sql('test')")
    except Exception as e:
        if "no such function" in str(e).lower():
            print(f"SKIP: fractal_text_to_sql not deployed: {e}")
            return 0

    cur.execute("DROP TABLE IF EXISTS _t2s_fuzz_target")
    cur.execute(
        "CREATE TABLE _t2s_fuzz_target (id INTEGER PRIMARY KEY, name TEXT)")
    conn.close()

    passed = 0
    for name, canned, expect_err_substr in SCENARIOS:
        with MockLLMServer(canned) as mock:
            # A fresh connection per scenario: config is per-connection
            # state, set on the very connection that makes the call (a
            # reconnect would reset it -- see _t2s_common.reconnect).
            c = connect_or_skip()
            if c is None:
                return 0
            cur = c.cursor()
            configure_reasoning(cur, PLUGIN, mock.url,
                                use_review=False, max_attempts=1,
                                allowed_statements="select")
            try:
                result = cur.execute(
                    "SELECT fractal_text_to_sql(?)",
                    (f"scenario: {name}",)).fetchone()[0]
                if expect_err_substr is not None:
                    fail(f"[{name}] expected rejection containing "
                        f"{expect_err_substr!r}, got a returned SQL "
                        f"statement instead: {result!r}")
                print(f"OK: [{name}] returned {result!r}")
                passed += 1
            except Exception as e:
                if expect_err_substr is None:
                    fail(f"[{name}] expected success, got error: {e}")
                if expect_err_substr not in str(e):
                    fail(f"[{name}] expected error containing "
                        f"{expect_err_substr!r}, got: {e}")
                print(f"OK: [{name}] rejected as expected ({expect_err_substr!r})")
                passed += 1
            finally:
                c.close()

    conn2 = connect_or_skip()
    conn2.cursor().execute("DROP TABLE IF EXISTS _t2s_fuzz_target")
    conn2.close()

    print(f"OK: {passed}/{len(SCENARIOS)} fuzz scenarios passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())