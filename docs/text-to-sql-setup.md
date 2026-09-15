<p align="center">
  <img src="../FractalSQLforSQLite.jpg" alt="FractalSQL for SQLite" width="720">
</p>

# Production-Safe Text-to-SQL

`fractal_text_to_sql` is a core primitive of the **Cognition Tier**. It transforms natural-language questions into mechanically validated SQL statements, providing a safe bridge between intent and execution.

Unlike naive LLM-to-SQL wrappers, FractalSQL treats SQL generation as a **hard-constrained engineering problem**, not a probabilistic one. It employs a multi-stage validation pipeline to ensure that every returned statement is syntactically correct, semantically valid, and policy-compliant before it ever reaches your application.

---

## Quick Start

By default, `fractal_text_to_sql` auto-discovers every table in the database (from `sqlite_master`, sqlite_* internals excluded). That's the simplest, most effective default for most use cases.

```sql
SELECT fractal_text_to_sql('How many orders does customer ''acme'' have?');
--  SELECT count(*) FROM orders WHERE customer_id = 
--    (SELECT id FROM customers WHERE name = 'acme')
```

### Scoping the Context
For large schemas, you can explicitly narrow the schema context sent to the LLM. This reduces token cost, minimizes noise, and allows you to strictly control what metadata leaves your database boundary. In the SQLite integration the narrowing knob lives on `fractal_sql_agent`, whose `table_names` argument is a **JSON array TEXT** (there is no `text[]` type):

```sql
SELECT generated_sql, execution_status, result_json FROM fractal_sql_agent(
    'How many orders does customer ''acme'' have?',
    '["orders", "customers"]'
);
```

(Plain `fractal_text_to_sql(question)` always auto-discovers; audit the discovery with `fractal_schema_context()`.)

---

## The Safety Pipeline: How it Works

FractalSQL implements a rigorous verification loop to eliminate "hallucinated" SQL.

```
GENERATE ──▶ ALLOWLIST ──▶ [REVIEW, optional] ──▶ PREPARE-CHECK ──▶ RETURN
   ▲                              │                   │
   └──────────── retry, with the specific failure fed back ──────┘
```

1. **GENERATE**: The question and schema description (from `fractal_schema_context()`, embedded in the prompt) are sent to the LLM.
2. **ALLOWLIST**: The candidate first passes a raw-text first-keyword screen (skip whitespace/comments, case-insensitive) so multi-statement, DDL/utility (`CREATE`, `DROP`, ...), `PRAGMA`, and `ATTACH` shapes never even reach the parser. The candidate is then parsed with `sqlite3_prepare_v2` — parse only, never executes — and rejected if `sqlite3_stmt_readonly()` reports read/write or if `sqlite3_stmt_isexplain()` flags it. A data-modifying CTE can't even be expressed: a CTE body must be a `SELECT`, so `WITH d AS (DELETE ...)` is a parse-time syntax error, never reaching the readonly check at all. Statement types are further gated by the `text_to_sql_allowed_statements` config key.
3. **REVIEW** *(Optional)*: A second LLM call critiques the candidate against the original question.
4. **MECHANICAL CHECK**: preparing the statement **is** the mechanical check here — SQLite has no planner to consult without executing. The parse step still catches syntax errors and unknown-table shapes, without aborting your main transaction.
5. **RETURN or RETRY**: On success, the SQL is returned. On failure, the specific error (from the allowlist or the parse) is fed back into the next generation attempt, up to `text_to_sql_max_attempts`.

### The Execution Guardrail (Safe Agency)
While `fractal_text_to_sql` only returns text, its logic is the foundation for the `fractal_sql_agent`. Containing execution failures to the agent's own attempt is a core pillar of our **Safe Agency** promise: it ensures that late-stage constraint failures (e.g., foreign key violations) only roll back the agent's specific attempt, leaving your session intact and allowing the agent to self-correct.

---

## `fractal_schema_context()`

Builds the plain-text schema description used as the LLM's context. You can call this directly to audit exactly what the model sees. It takes no arguments in the SQLite integration (no `text[]` type): it walks `sqlite_master` (`type IN ('table','view')`, sqlite_* internals excluded, table-count capped).

```sql
SELECT fractal_schema_context();
-- Table: customers
--   Columns:
--     id INTEGER PK NOT NULL
--     name TEXT NOT NULL
-- Table: orders
--   Columns:
--     id INTEGER PK NOT NULL
--     customer_id INTEGER NOT NULL
--     total_cents INTEGER NOT NULL
--   Foreign keys:
--     orders: FOREIGN KEY (customer_id) REFERENCES customers(id)
```

**Sovereignty Note**: Auto-discovery pulls every table in the database — SQLite has no per-role grants to hide a table from discovery. If your schema contains sensitive metadata (e.g., a `payroll_secrets` table), use `fractal_sql_agent`'s `table_names` JSON argument to keep that metadata out of the prompt, and use the sqlite3 authorizer hook (`sqlite3_set_authorizer`) in your host application to enforce what the executed SQL may actually touch.

---

## Configuration & Security

### Config Keys
These are per-connection values set with `fractalsql_set(key, value)` (the easy_install wizard's `load_fractalsql.sql` snippet, applied per session via `sqlite3 -init load_fractalsql.sql mydb.sqlite` or `.read load_fractalsql.sql`, is the standard way to apply them):

| Config key | Default | Notes |
| --- | --- | --- |
| `text_to_sql_max_attempts` | `2` | Shared budget across all rejection types (range 1–10). |
| `text_to_sql_allowed_statements` | `'select'` | `'select_insert_update'` permits writes; see **Secure it** below. |
| `text_to_sql_use_review` | `off` | Enable for higher accuracy at the cost of latency. |

```sql
SELECT fractalsql_set('text_to_sql_use_review', 'on');
```

### Secure it: Authorization vs. Correctness
**Crucial**: This pipeline is a *correctness* aid, not an *authorization* mechanism. The allowlist and parse checks catch shape and schema problems, but SQLite has no engine-side role/grant model to replace.

To secure your Text-to-SQL implementation:
1. **Dedicated Connection**: Open the agent's connection against a database file (or `ATTACH` set) that only exposes the tables necessary for the use case — SQLite authorization happens at the host boundary, not inside the engine.
2. **Authorizer Hook**: Install a `sqlite3_set_authorizer` callback in your host application so the *executed* SQL is rejected unless its tables/actions are on the allowlist.
3. **Application-Side Filtering**: There is no RLS; enforce row-level visibility either with views that embed the tenant predicate, or by running the agent over a connection whose authorizer + database file layout already constrain it.

---

## Validation & Testing

FractalSQL includes a comprehensive test suite to ensure the pipeline's robustness:

- **Fuzz Testing**: `tests/test_text_to_sql_fuzz.py` forces malicious/malformed responses (stacked statements, DDL, prompt injections) to verify the allowlist.
- **Shadow Testing**: `tests/test_text_to_sql_shadow.py` runs complex questions against real models and diffs the results against ground-truth SQL.
- **Memory Safety**: `tests/test_text_to_sql_evil_nonterminating.py` ensures the C-bridge is length-bounded and immune to buffer over-reads.

(All three run against the SQLite extension via Python's `sqlite3` module — see `tests/_t2s_common.py` for the shared harness.)

---

## Known Limitations

- **Distinct-Value Sampling**: The current version does not sample enum-like columns (e.g., `'Completed'` vs `'completed'`) to help the LLM with value normalization.
- **Table Ranking**: For extremely large schemas, `fractal_search`-based table subset ranking is planned to replace the current linear auto-discovery.
- **Schema Caps**: `fractal_sql_agent`'s explicit `table_names` JSON array is capped at 512 entries to bound prompt overhead; `fractal_schema_context()` applies the same table-count cap during auto-discovery.
