-- demo/demo-text-to-sql.sql
-- Runnable walkthrough of the REAL fractal_text_to_sql() feature,
-- against a richer schema with real foreign keys -- distinct from
-- demo/text-to-sql-spike-*.sql, which were throwaway hand-rolled
-- validation spikes run before this function existed (single-table,
-- no FKs, driving fractal_reason() directly). See
-- ../docs/text-to-sql-setup.md for the full pipeline explanation, the
-- config-key reference, and the security model.
--
-- Prerequisites: extension loaded, reasoning configured -- see
-- ../docs/reasoning-setup.md and confirm with:
--   SELECT fractal_reason('reply with a short confirmation that this connection works');
-- before running this script.
--
-- Notes:
--   * fractal_text_to_sql(question) takes ONLY the question -- there is
--     no scoping argument (SQLite has no array type). Scoping
--     the LLM's view is fractal_sql_agent's job
--     (fractal_sql_agent(question, '["orders", "customers"]')), and
--     plain fractal_text_to_sql() always auto-discovers the whole
--     database -- audit that discovery with fractal_schema_context()
--     below.
--   * fractal_schema_context() takes no arguments and walks sqlite_master.
--   * The generated statement is captured with the CLI's .once/.read
--     spool trick. (Keep .timer OFF around the spool SELECT; its "Run
--     Time:" line would otherwise be spooled too.) The spool file
--     t2s_generated.sql lands in the current directory; delete it
--     whenever, it is overwritten per run.
--   * Schema documentation travels in the CREATE TABLE comments and
--     the column names themselves (what fractal_schema_context() reads).
--
-- Safe to re-run: the schema is dropped and recreated at the top.
-- Without a plugin configured the reasoning calls error with the clean
-- "reasoning plugin not configured" hint and the file carries on to
-- the next section.

.timer on

DROP TABLE IF EXISTS order_items;
DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS customers;

CREATE TABLE customers (
    id      INTEGER PRIMARY KEY,
    name    TEXT NOT NULL,
    status  TEXT NOT NULL DEFAULT 'active'   -- one of: active, churned
);

CREATE TABLE orders (
    id          INTEGER PRIMARY KEY,
    customer_id INTEGER NOT NULL REFERENCES customers(id),
    placed_at   TEXT NOT NULL DEFAULT (datetime('now')),
    status      TEXT NOT NULL DEFAULT 'pending'  -- pending, paid, refunded, cancelled
);

CREATE TABLE order_items (
    id          INTEGER PRIMARY KEY,
    order_id    INTEGER NOT NULL REFERENCES orders(id),
    sku         TEXT NOT NULL,
    quantity    INTEGER NOT NULL,
    unit_cents  INTEGER NOT NULL
    -- Line items within an order; total = quantity * unit_cents
);

INSERT INTO customers (name, status) VALUES
    ('acme',       'active'),
    ('globex',     'active'),
    ('initech',    'churned');

INSERT INTO orders (customer_id, status) VALUES
    (1, 'paid'), (1, 'paid'), (1, 'refunded'),
    (2, 'paid'),
    (3, 'cancelled');

INSERT INTO order_items (order_id, sku, quantity, unit_cents) VALUES
    (1, 'widget-a', 3, 500),
    (1, 'widget-b', 1, 1200),
    (2, 'widget-a', 2, 500),
    (3, 'widget-c', 1, 4000),
    (4, 'widget-b', 5, 1200);

.print === Section 1: schema context (what GENERATE actually sees) ===
.print 'Auto-discovery walks sqlite_master -- this is the exact text the'
.print 'LLM sees, and SQLite auto-discovers the whole database (no per-'
.print 'role grants to hide a table; see docs/text-to-sql-setup.md for'
.print 'the host-boundary authorizer pattern that replaces them).'
SELECT fractal_schema_context();

.print
.print === Section 2: a simple single-table question ===
.print '(table-scoping lives on fractal_sql_agent(question, JSON'
.print ' table_names) instead -- plain fractal_text_to_sql() has no'
.print ' scoping argument)'
SELECT fractal_text_to_sql(
    'How many customers have status active?'
);

.print
.print === Section 3: a question requiring a join across the FK chain ===
SELECT fractal_text_to_sql(
    'List the names of customers who have at least one paid order, '
    || 'with how many paid orders each has.'
);

.print
.print === Section 4: a question requiring all three tables ===
SELECT fractal_text_to_sql(
    'For each customer, what is the total value in cents of their paid orders '
    || '(quantity times unit price, summed across all line items)?'
);

.print
.print === Section 5: run the generated SQL yourself ===
.print fractal_text_to_sql() never executes what it generates -- that is
.print always a separate, explicit step. Spool a result and .read it:
.timer off
.once t2s_generated.sql
SELECT fractal_text_to_sql(
    'What is the average number of line items per order?'
);
.read t2s_generated.sql
.timer on

.print
.print ================================================================
.print Next: docs/text-to-sql-setup.md for the config-key reference
.print (text_to_sql_allowed_statements etc. via fractalsql_set), the
.print host-boundary execution guard (do not run generated SQL on a
.print connection that can see tables the answer should not touch --
.print SQLite has no superuser/role split; bound the connection's file
.print and authorizer instead), and how to validate against your own
.print local models with test/test_text_to_sql_shadow.py.
.print
.print Clean up: DROP TABLE order_items, orders, customers;
.print (t2s_generated.sql is this section's spool file in the current
.print directory -- overwritten each run, delete whenever.)
.print ================================================================