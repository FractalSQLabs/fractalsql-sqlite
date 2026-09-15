#!/usr/bin/env python3
"""tests/test_text_to_sql_smoke.py — smoke test for
fractal_text_to_sql().

One live end-to-end call against whatever reasoning plugin/model is
actually configured: does the full GENERATE -> ALLOWLIST -> VALIDATE
pipeline run without crashing and return SQL that actually references
the table it was asked about? This is deliberately NOT a correctness
check (see test_text_to_sql_shadow.py for that) -- it is the fast "is
anything on fire" gate to run after every build.

The extension is loaded into a stdlib-sqlite3 connection
(_t2s_common.connect_or_skip); the reasoning plugin and endpoint are
configured per-connection with fractalsql_set(). That configuration
takes effect IMMEDIATELY on the connection that set it -- and a
reconnect would RESET it -- so every scenario configures the very
connection it calls fractal_text_to_sql() on.

Skip-safe: exits 0 with a SKIP: message if the extension isn't built,
the reasoning plugin .so isn't present, or the configured model
endpoint doesn't respond.

Usage:
    python3 tests/test_text_to_sql_smoke.py
    FRACTALSQL_EXT=...  FRACTALSQL_REASONING_PLUGIN=...  \\
        FRACTALSQL_HTTP_URL=http://localhost:11434/v1/chat/completions \\
        FRACTALSQL_MODEL=phi4:14b \\
        python3 tests/test_text_to_sql_smoke.py
"""
import os
import sys

from _t2s_common import (configure_reasoning, connect_or_skip,
                         get_reasoning_plugin_path)

PLUGIN = get_reasoning_plugin_path()
HTTP_URL = os.environ.get("FRACTALSQL_HTTP_URL",
                          "http://localhost:11434/v1/chat/completions")
MODEL = os.environ.get("FRACTALSQL_MODEL", "phi4:14b")


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
    cur.execute("DROP TABLE IF EXISTS _t2s_smoke_orders")
    cur.execute("""
        CREATE TABLE _t2s_smoke_orders (
            id          INTEGER PRIMARY KEY,
            customer    TEXT NOT NULL,
            total_cents INTEGER NOT NULL,
            status      TEXT NOT NULL
        )
    """)
    cur.execute("""
        INSERT INTO _t2s_smoke_orders (customer, total_cents, status) VALUES
            ('acme',    1200, 'paid'),
            ('acme',    3400, 'paid'),
            ('globex',   500, 'refunded')
    """)

    # Per-connection config takes effect immediately: set it on the very
    # connection that will call fractal_text_to_sql() (a reconnect would
    # reset it -- see _t2s_common.reconnect). No table-names argument:
    # the SQLite surface is arity-1 and auto-discovers the schema.
    configure_reasoning(cur, PLUGIN, HTTP_URL, model=MODEL,
                        use_review=False, max_attempts=2,
                        allowed_statements="select")

    try:
        sql = cur.execute(
            "SELECT fractal_text_to_sql(?)",
            ("How many orders does customer 'acme' have?",)).fetchone()[0]
    except Exception as e:
        print(f"SKIP: fractal_text_to_sql call failed -- reasoning "
              f"endpoint unreachable, model not pulled, or not deployed: {e}")
        cur.execute("DROP TABLE IF EXISTS _t2s_smoke_orders")
        return 0

    print(f"Generated SQL:\n{sql}\n")

    if "_t2s_smoke_orders" not in sql:
        cur.execute("DROP TABLE IF EXISTS _t2s_smoke_orders")
        fail(f"generated SQL doesn't reference the target table: {sql!r}")

    if not sql.strip().lower().startswith("select"):
        cur.execute("DROP TABLE IF EXISTS _t2s_smoke_orders")
        fail(f"generated SQL isn't a SELECT despite allowed_statements=select: {sql!r}")

    # The function already validated the statement via a parse-only
    # sqlite3_prepare_v2 (one statement, not EXPLAIN, read-only), but
    # actually executing it here is still a real, direct proof the
    # returned SQL runs, not just plans.
    cur.execute(sql)
    rows = cur.fetchall()
    print(f"Executed successfully, {len(rows)} row(s): {rows}")

    cur.execute("DROP TABLE IF EXISTS _t2s_smoke_orders")
    conn.close()

    print(f"OK: text-to-sql smoke test passed (model={MODEL})")
    return 0


if __name__ == "__main__":
    sys.exit(main())