#!/usr/bin/env python3
"""tests/test_text_to_sql_schema_context.py — unit test for
fractal_schema_context().

No LLM involved -- this function is pure catalog introspection, so this
is a real, fast, deterministic unit test (unlike the rest of the
text-to-sql suite, which needs a reasoning plugin configured one way or
another). Covers: column/type/PK/NOT NULL rendering, foreign-key
rendering, and the auto-discovery path.

Notes on the SQLite surface (see src/fsql_t2s.c):
  - the function is arity-0: it always auto-discovers every non-sqlite_
    table/view. There is no explicit table_names argument, and so no
    "named table not found" error path either -- kept below as visible
    skips.
  - there is no per-table/column comment support, so the rendered
    context carries no comment text -- also kept as a visible skip.
  - no schema prefix: the header is exactly "Table: <name>".

Skips cleanly (exit 0) if the extension isn't built or
fractal_schema_context isn't deployed yet.

Usage:
    python3 tests/test_text_to_sql_schema_context.py
    FRACTALSQL_EXT=... FRACTALSQL_DB=... \\
        python3 tests/test_text_to_sql_schema_context.py
"""
import sys

from _t2s_common import connect_or_skip


def fail(msg):
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def main():
    conn = connect_or_skip()
    if conn is None:
        return 0
    cur = conn.cursor()

    cur.execute("DROP TABLE IF EXISTS _t2s_order_items")
    cur.execute("DROP TABLE IF EXISTS _t2s_orders")
    cur.execute("DROP TABLE IF EXISTS _t2s_customers")

    cur.execute("""
        CREATE TABLE _t2s_customers (
            id     INTEGER PRIMARY KEY,
            name   TEXT NOT NULL,
            status TEXT
        )
    """)
    # No comment support: there is nothing for fractal_schema_context
    # to render for table/column comments -- see the explicit skips below.

    cur.execute("""
        CREATE TABLE _t2s_orders (
            id          INTEGER PRIMARY KEY,
            customer_id INTEGER NOT NULL REFERENCES _t2s_customers(id),
            total_cents INTEGER NOT NULL
        )
    """)

    try:
        ctx = cur.execute("SELECT fractal_schema_context()").fetchone()[0]
    except Exception as e:
        print(f"SKIP: fractal_schema_context unavailable "
              f"(text-to-sql not deployed?): {e}")
        cur.execute("DROP TABLE IF EXISTS _t2s_orders")
        cur.execute("DROP TABLE IF EXISTS _t2s_customers")
        return 0

    print("=== fractal_schema_context output ===")
    print(ctx)
    print("=========================================")

    # Kept visible: cases that don't apply to this surface at all --
    #   (a) a schema-qualified table header,
    #   (b) table/column comment text rendered into the context,
    #   (c) an explicit table_names=['_t2s_does_not_exist'] argument
    #       raising a clear "not found" error.
    # The SQLite surface is arity-0 (auto-discovery only) and has no
    # comment support, so none of those cases can exist here:
    print("SKIP: no schema-qualified table header on this surface "
          "(rendered as \"Table: <name>\")")
    print("SKIP: no comment support on this surface; "
          "fractal_schema_context emits no comment text")
    print("SKIP: the explicit table_names argument "
          "(and its named-table-not-found error path) does not exist -- "
          "the SQLite function is arity-0 and always auto-discovers")

    checks = [
        ("Table: _t2s_customers" in ctx,
         "customers table header present"),
        ("Table: _t2s_orders" in ctx,
         "orders table header present"),
        ("id INTEGER PK" in ctx,
         "PK marker rendered for customers.id"),
        ("name TEXT NOT NULL" in ctx,
         "NOT NULL marker rendered for customers.name"),
        # The FK section is emitted once per table that has foreign
        # keys; the orders line must land inside it.
        ("Foreign keys:" in ctx and
         "_t2s_orders: FOREIGN KEY (customer_id) REFERENCES "
         "_t2s_customers(id)" in ctx.split("Foreign keys:")[-1],
         "foreign key rendered for orders.customer_id -> customers"),
    ]
    for ok, desc in checks:
        if not ok:
            cur.execute("DROP TABLE IF EXISTS _t2s_orders")
            cur.execute("DROP TABLE IF EXISTS _t2s_customers")
            fail(desc)
        print(f"OK: {desc}")

    # Auto-discovery path (the ONLY path on SQLite -- no table_names
    # argument to contrast it with): both test tables must be present
    # among the visible tables.
    auto_ctx = cur.execute("SELECT fractal_schema_context()").fetchone()[0]
    if "_t2s_customers" not in auto_ctx or "_t2s_orders" not in auto_ctx:
        cur.execute("DROP TABLE IF EXISTS _t2s_orders")
        cur.execute("DROP TABLE IF EXISTS _t2s_customers")
        fail("auto-discovery did not include both test tables")
    print("OK: auto-discovery includes both test tables")

    cur.execute("DROP TABLE IF EXISTS _t2s_orders")
    cur.execute("DROP TABLE IF EXISTS _t2s_customers")
    conn.close()

    print("OK: text-to-sql schema_context unit tests passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())