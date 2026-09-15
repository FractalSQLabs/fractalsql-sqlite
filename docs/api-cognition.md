<p align="center">
  <img src="../FractalSQLforSQLite.jpg" alt="FractalSQL for SQLite" width="720">
</p>

# Cognition API Reference

The Cognition tier provides the provider bridge that connects the SFS core to Large Language Models (LLMs) and embedding providers.

---

## `fractal_reason`
**LLM Dispatch**

Dispatches a natural language query and a context payload to the configured LLM reasoning plugin.

### Signature
```sql
fractal_reason(
    query   text,
    context text DEFAULT '{}'
) RETURNS text
```

### Arguments
| Argument | Type | Default | Description |
| --- | --- | --- | --- |
| `query` | `text` | (Required) | The question or instruction for the LLM. |
| `context` | `text` | `'{}'` | A JSON payload containing search results, schema, or other data. |

### Reasoning Effort
Hybrid-thinker models' internal reasoning trace is throttled via the `http_think` config key (`SELECT fractalsql_set('http_think', 'medium');`) and related keys -- see [Reasoning Setup: Reasoning Effort (THINK)](reasoning-setup.md#reasoning-effort-think).

---

## `fractal_embed`
**Semantic Vector Generation**

Generates a high-dimensional vector from text using the configured embedding model.

### Signature
```sql
fractal_embed(
    input text
) RETURNS BLOB   -- canonical fractal_vector (u16 dim LE + u16 reserved + f32[])
```

### Requirements
Requires `http_embed_url` and `http_embed_model` to be configured for this connection:

```sql
SELECT fractalsql_set('http_embed_url',   'http://127.0.0.1:11434/v1/embeddings');
SELECT fractalsql_set('http_embed_model', 'nomic-embed-text');
```

---

## `fractal_text_to_sql`
**Safe SQL Generation**

Turns a natural-language question into a single, parse-validated SQL statement.

### Signature
```sql
fractal_text_to_sql(
    question text
) RETURNS text
```

### Arguments
| Argument | Type | Default | Description |
| --- | --- | --- | --- |
| `question` | `text` | (Required) | The natural language question. |

*SQLite difference:* the optional `table_names` argument is not ported here — there is no `text[]` type. `fractal_text_to_sql(question)` always auto-discovers the schema via `sqlite_master`; use `fractal_sql_agent(question, table_names_json, ...)` (its `table_names` is a JSON array TEXT, e.g. `'["orders","customers"]'`) when you need explicit scoping.

### Safety Pipeline
1. **Keyword pre-check**: raw-text first-keyword screen rejects multi-statement / DDL / utility / `PRAGMA` / `ATTACH` candidates before any parse.
2. **Allowlist**: `sqlite3_prepare_v2` parse (never executes) plus `sqlite3_stmt_readonly()`; data-modifying CTEs are reported read/write on SQLite >= 3.35, and `EXPLAIN` is rejected outright via `sqlite3_stmt_isexplain`. Statement types further gated by the `text_to_sql_allowed_statements` config key.
3. **Parse-Check**: preparing the statement *is* the mechanical check here — SQLite has no planner to consult without executing.

---

## `fractal_schema_context`
**Schema Introspection**

Builds a plain-text description of the database schema for use as LLM context.

### Signature
```sql
fractal_schema_context() RETURNS text
```

### Arguments
None in the SQLite integration — the optional `table_names` and `query_hint` parameters are both dropped here, not just `table_names`; SQLite's `fractal_schema_context()` takes zero arguments. The function walks `sqlite_master` (`type IN ('table','view')`, sqlite_* internals excluded, capped) and describes every table; call it directly to audit exactly what the model sees.
