<p align="center">
  <img src="../FractalSQLforSQLite.jpg" alt="FractalSQL for SQLite" width="720">
</p>

# Sovereign Agency

FractalSQL is bundled with **sixteen installable agents**: autonomous,
self-correcting routines that compose the extension's Discovery, Analytics, and
Cognition primitives into end-to-end workflows. Each agent is a *recipe* for a
recurring agentic pattern: "drift on a metric series," "match a task to the best
capable sub-agent," "block an action near a known-bad state." You pick the recipe
that matches your problem, point it at your tables and columns, and get back real
computed results plus a human-readable read.

> **SQLite difference: registered C functions, not a second extension.** The
> server edition ships these sixteen as a server-side procedural language in a
> second, optional `fractalsql_agents` install/activation step. SQLite has no
> server-side procedural language and no second extension artifact, so
> `src/fsql_domain_agents.c` registers all sixteen as plain C SQL functions in
> this same `.so`, alongside the six Universal Agents — callable the moment
> `.load` runs, no install step.
> Every SQL example on this page is written in the server edition's dialect
> (`FROM fn(...)`, `ARRAY[...]::float8[]`, `timestamptz`) since it doubles as
> the reference for what each recipe composes; see the
> [porting note](#porting-these-examples-to-sqlite)
> right before the recipes for the mechanical translation to SQLite's calling
> convention.

This page is written for the **driver**, not the mechanic. For each agent you'll
find: what problem it solves, when to reach for it, the inputs it needs, how it
works inside, what it returns, a runnable example, and the non-obvious notes.
If you want to build a recipe that isn't in the box, see
[Composing your own](#composing-your-own) and the six Universal Agent building
blocks further down.

> **What's an "installable agent" vs. a "Universal Agent" vs. a "Domain Agent"?**
> The **installable agents** (below) are the productized recipes — sixteen
> C-registered SQL functions in the SQLite integration
> (`src/fsql_domain_agents.c`), a second, separately-installed
> `fractalsql_agents` extension in the server edition. The **Universal
> Agents** (lower down) are the six C-level building blocks the installable
> agents compose. The **Domain Agents** are the original reference blueprints
> in the server edition's `demo/demo-agentic-*.sql` scripts; the installable
> agents are their productized, parameterized form.

---

## Install

**SQLite difference:** no `fractalsql_agents` extension and no separate
install/activation step at all — load the base extension and all sixteen agents (plus
the six Universal Agents) are callable immediately:
```sql
.load /usr/local/lib/sqlite3/fractalsql
```

Thirteen are **cognition** agents that end in a `fractal_reason` step and need
reasoning configured (see [`reasoning-setup.md`](reasoning-setup.md)). Three are
**pure retrieval/analytics** with no LLM step (`recall_hybrid`,
`recommend_diverse`, `feedback_audit`) and need no endpoint. One
(`diverse_portfolios`) is enterprise tier; see its recipe below. Confirm
reasoning before running the cognition agents:

```sql
SELECT fractal_reason('reply with a short confirmation');
```

---

## Which agent should I use?

Pick by the problem shape, not by the function name.

| Your problem | Agent | Recipe in one line | LLM? |
| --- | --- | --- | --- |
| "Is this entity's metric series drifting into a new regime?" (table-backed, per-entity) | `anomaly_triage` | drift exponent on one entity's series → LLM triage | ✓ |
| "Is this single series in a regime change?" (array-in, no table) | `regime_triage` | DFA + drift over one series → LLM triage | ✓ |
| "Did this vessel/host track deviate from the fleet?" | `track_anomaly` | trajectory deviation + heading DFA → LLM triage | ✓ |
| "Did this vehicle detour, and how complex is its GPS trace?" | `detour_classify` | trajectory deviation + box-counting → LLM classify | ✓ |
| "Is my sensor grid's coverage degrading?" | `network_coverage_alert` | spatial morphology + telemetry drift → LLM alert | ✓ |
| "What's the best cardinality-constrained allocation?" | `allocate` | SFS Sharpe optimizer → LLM rationale | ✓ |
| "Rebalance, and compare to the nearest historical allocation?" | `rebalance_sibling` | optimizer + trajectory search → LLM rationale | ✓ |
| "Give me several distinct good portfolios, not just one?" (enterprise) | `diverse_portfolios` | multimodal optimizer → LLM tradeoff summary | ✓ |
| "Which sub-agent should handle this incoming task?" | `route_task` | nearest-capability search + budget accounting → LLM rationale | ✓ |
| "Which node should this workload land on (with vector refinement)?" | `schedule_workload` | `fractal_search` refine + nearest node → LLM rationale | ✓ |
| "Should I block this proposed action (is it near a known-bad state)?" | `outlier_intercept` | distance-to-bad-state safety barrier → LLM justification | ✓ |
| "Triage a patient against a cohort + baseline→current drift" | `patient_deterioration_triage` | cohort search + trajectory drift → LLM triage | ✓ |
| "Ask a natural-language question over my tables" | `data_analyst` | NL→SQL→execute → LLM analysis | ✓ |
| "Recall similar past memories, restricted by a metadata filter" | `recall_hybrid` | cohort-restricted vector recall | — |
| "Recommend diverse items, avoiding recently-rejected ones" | `recommend_diverse` | repulsion-diverse top-k | — |
| "Audit my recommender's diversity health" | `feedback_audit` | diversify loop + collapse detection | — |

> **A guarantee about the outputs.** Every output column is a **real primitive
> result, not a literal**. `threat_score` is the computed drift exponent;
> `allocation`/`sharpe` are the optimizer's own `{sharpe, weights}` jsonb and
> risk-adjusted return (no hardcoded `0.042`); `routed_to` is the real nearest
> capability name and `confidence` is `1/(1+distance)`; `intercepted` is a real
> distance-vs-threshold comparison; `mem_id`/`content` are the real recalled row;
> `item_id`/`score` are the real catalog id and `1 − cosine_distance`. The
> thirteen cognition agents' `triage_summary` / `rationale` / `analysis`
> columns are real `fractal_reason` output. Every agent raises a clean `ERROR`
> on bad input (empty target table, NULL series, filter matching no rows) with
> an agent-named message.

---

### Porting these examples to SQLite

Every example below is written in the server edition's dialect —
`FROM fractal_agent_x(...)` (a set-returning-function call),
`ARRAY[...]::float8[]` vector literals, and
`timestamptz`/`generate_series`/`now()` fixture DDL — since this page doubles
as the reference for what each recipe composes across both editions. The
mechanical translation to a SQLite session:

| Server edition (as written below) | SQLite |
| --- | --- |
| `SELECT col1, col2, ... FROM fractal_agent_x(args)` | `SELECT fractal_agent_x(args)` — one scalar call returning a single TEXT JSON document; pick fields with `json_extract(result, '$.col1')` |
| `ARRAY[0.1, 0.2, 0.3]::float8[]` | `'0.1,0.2,0.3'` (CSV text) or `'[0.1,0.2,0.3]'` (JSON text) — see [vectorizer-setup.md](vectorizer-setup.md) / [api-discovery.md](api-discovery.md) for the full vector-argument convention |
| `float8[]` column type | `TEXT` column holding a CSV/JSON vector, or a `fractal_vector` BLOB |
| `timestamptz`, `now()`, `generate_series(1, 96)` | an `INTEGER` ordering column (unix epoch or a plain sequence) and a `WITH RECURSIVE` CTE in place of `generate_series` |
| the [id-resolution](#a-note-on-id-resolution) `ctid`-`row_number()` mapping | identical, with `ORDER BY rowid` in place of `ORDER BY ctid` — `src/fsql_domain_agents.c`'s `da_resolve_id()` does this internally already; you only need it yourself when composing primitives by hand |

Every underlying primitive and every argument, default, and return field named
below is the same on both editions — only the fixture DDL and the call/result
shape differ.

---

## The sixteen recipes

### Anomaly triage — `fractal_agent_anomaly_triage`
**Triage drift on one entity's metric time series.**

Use it when you have a per-entity metric series in a table (latency, error rate,
vitals, sensor reading) and want to know whether that entity has drifted into a
new regime: Cybersecurity host triage, DevOps incident triage, MedTech patient
monitoring, Smart-Cities sensor regime change. For a single series you already
hold as an array (no per-row table), use [regime_triage](#regime-triage--fractal_agent_regime_triage)
instead.

**Inputs**

| Argument | Type | Default | What it is |
| --- | --- | --- | --- |
| `log_table` | `text` | — | your metric table |
| `metric_col` | `text` | — | the numeric metric column to read as the series |
| `time_col` | `text` | — | the timestamp column to order the series by |
| `filter_col` | `text` | — | the entity-id column to filter on (e.g. `host`) |
| `filter_val` | `text` | — | which entity (e.g. `'host-1'`) |
| `baseline_window` | `int` | `32` | recent-window size for the drift comparison |

**How it works.** (1) Reads the entity's metric series ordered by time into a
`float8[]` via dynamic SQL. (2) Runs `fractal_dimension_drift(series, baseline_window)`
for the regime-change drift exponent. (3) Calls `fractal_reason` to synthesize a
human-readable triage over the drift result.

**Returns** `(threat_score float8, anomaly_type text, triage_summary text)`:
`threat_score` is the real drift exponent; `anomaly_type` is the literal
`'vector_drift'` label; `triage_summary` is the LLM's read.

**Example**
```sql
CREATE TABLE agents_demo_logs (metric float8, ts timestamptz, host text);
INSERT INTO agents_demo_logs (metric, ts, host)
SELECT 50.0 + (gs % 8)::float8 * 1.3 + CASE WHEN gs > 48 THEN 30.0 ELSE 0.0 END,
       now() - (96 - gs) * interval '1 second', 'host-1'
FROM generate_series(1, 96) AS gs;

SELECT threat_score, anomaly_type, triage_summary
FROM fractal_agent_anomaly_triage(
    'agents_demo_logs', 'metric', 'ts', 'host', 'host-1', 32);
```

**Notes.** Raises `fractal_agent_anomaly_triage: no rows in …` if the filter
matches no rows. `baseline_window` must be large enough for DFA (16 is too small
and returns `rc=-1`; 32 is safe).

---

### Allocate — `fractal_agent_allocate`
**Cardinality-constrained portfolio allocation.**

Use it when you want the best allocation of a fixed number of assets from a
universe: Quant-Finance portfolios, Sovereign-Edge resource allocation, FinTech
rebalancing. You supply expected returns (`mu`) and risk (`cov`); the agent runs
the SFS Sharpe maximizer and reasons a rationale.

**Inputs**

| Argument | Type | Default | What it is |
| --- | --- | --- | --- |
| `mu` | `float8[]` | — | expected returns per asset |
| `cov` | `float8[]` | — | covariance matrix, **flattened 1-D row-major n×n** |
| `cardinality` | `int` | — | how many assets to hold |
| `context` | `text` | `NULL` | optional label passed to the reason call |

**How it works.** (1) `fractal_optimize_portfolio(mu, cov, cardinality)`: the
SFS cardinality-constrained Sharpe maximizer. (2) Extracts the real Sharpe from
the optimizer's own output. (3) `fractal_reason` explains the allocation.

**Returns** `(allocation jsonb, sharpe float8, rationale text)`: `allocation` is
the optimizer's `{sharpe, weights}` jsonb; `sharpe` is the real risk-adjusted
return; `rationale` is the LLM's explanation.

**Example**
```sql
-- 2 assets, hold 1; cov is the 2×2 identity flattened to 4 elements (row-major).
SELECT allocation, sharpe, rationale
FROM fractal_agent_allocate(
    ARRAY[0.05, 0.1]::float8[],
    ARRAY[1.0, 0.0, 0.0, 1.0]::float8[],
    1,
    '{"portfolio": "agents-demo"}'::text);
```

**Notes.** `cov` must be a **flattened 1-D row-major** matrix, not a 2-D array.
The primitive reads it via `float8_array_to_doubles` and rejects 2-D. A
mismatched `cov` length surfaces the primitive's clean `cov length` ERROR.

---

### Route task — `fractal_agent_route_task`
**Match an incoming task to the best capable sub-agent.**

Use it as a sub-agent dispatcher: DevOps task routing, Customer Support
intent routing, Cybersecurity analyst routing, Sovereign-Edge orchestration. You
pass the task as an embedding (the agent does not embed it for you); it finds the
nearest capability row and accounts a token budget.

**Inputs**

| Argument | Type | Default | What it is |
| --- | --- | --- | --- |
| `task_emb` | `float8[]` | — | the incoming task's embedding (same dim as the capability embeddings) |
| `cap_table` | `text` | — | your capability/sub-agent table |
| `cap_emb_col` | `text` | — | the embedding column in that table |
| `cap_id_col` | `text` | — | the column to return as the routed-to name |
| `budget` | `int` | — | the caller's token budget |
| `cost_per_route` | `int` | `150` | tokens one routing decision costs |

**How it works.** (1) `fractal_search_telemetry(cap_table, cap_emb_col, task_emb, 1)`
finds the nearest capability. (2) Resolves the 0-indexed scan position to the
named capability id via the [id-resolution mapping](#a-note-on-id-resolution). (3) Derives
`confidence = 1/(1+distance)`, accounts `remaining_budget = budget − cost_per_route`.
(4) `fractal_reason` writes a one-line routing rationale.

**Returns** `(routed_to text, confidence float8, remaining_budget int, rationale text)`.

**Example**
```sql
CREATE TABLE agents_demo_caps (capability_name text, emb float8[]);
INSERT INTO agents_demo_caps VALUES
    ('root-cause-analyzer', ARRAY[0.1, 0.2, 0.3]),
    ('capacity-autoscaler', ARRAY[0.9, 0.8, 0.7]),
    ('incident-pager',      ARRAY[0.3, 0.3, 0.9]);

SELECT routed_to, confidence, remaining_budget, rationale
FROM fractal_agent_route_task(
    ARRAY[0.11, 0.21, 0.31]::float8[],
    'agents_demo_caps', 'emb', 'capability_name', 1000);
```

**Notes.** Raises `no capability rows in …` if the capability table is empty
(the agent pre-checks so its message fires before the C primitive's
`no corpus rows to search`).

---

### Outlier intercept — `fractal_agent_outlier_intercept`
**Pre-commit safety barrier against known-bad states.**

Use it as a pre-commit screen on a proposed action's state vector: DevOps action
screening, Cybersecurity known-bad-state interception, MedTech out-of-range
vital interception, Sovereign-Edge anomalous command interception. It measures
the distance from the proposed state to the nearest known-bad state and intercepts
if that distance is within a threshold.

**Inputs**

| Argument | Type | Default | What it is |
| --- | --- | --- | --- |
| `state_vec` | `float8[]` | — | the proposed action's state vector |
| `history_table` | `text` | — | your known-bad-state table |
| `emb_col` | `text` | — | the embedding column in that table |
| `threshold` | `float8` | — | intercept if the nearest bad state is within this cosine distance |

**How it works.** (1) `fractal_search_telemetry(history_table, emb_col, state_vec, 1)`
for the distance to the nearest known-bad state. (2) `intercepted = distance < threshold`,
a real comparison of a real distance. (3) `fractal_reason` justifies the
decision in one sentence.

**Returns** `(intercepted boolean, reason text)`.

**Example**
```sql
CREATE TABLE agents_demo_badstates (emb float8[]);
INSERT INTO agents_demo_badstates VALUES
    (ARRAY[1.0, 0.0, 0.0]),
    (ARRAY[0.9, 0.1, 0.0]);

-- Near a bad state -> intercepted.
SELECT intercepted, reason
FROM fractal_agent_outlier_intercept(
    ARRAY[0.95, 0.05, 0.0]::float8[], 'agents_demo_badstates', 'emb', 0.5);

-- Orthogonal/far -> allowed.
SELECT intercepted, reason
FROM fractal_agent_outlier_intercept(
    ARRAY[0.0, 1.0, 0.0]::float8[], 'agents_demo_badstates', 'emb', 0.5);
```

**Notes.** Cosine distance **ignores magnitude**: `[0.1,0.1,0.1]` vs
`[0.9,0.9,0.9]` are parallel (distance 0, "near"), not far. To build a "far"
known-bad fixture, point a *different direction* (e.g. `[0,1,0]` vs `[1,0,0]` →
distance 1). Raises `no bad-state rows in …` if the history table is empty.

---

### Recall hybrid — `fractal_agent_recall_hybrid`
**Cohort-restricted vector recall (no LLM).**

Use it for memory recall restricted by a metadata filter: Customer Support memory
recall, MedTech cohort-restricted patient search, Smart-Cities zone-filtered
sensor recall. The "hybrid" is the cohort: a strict SQL filter applied *before*
the vector search so `k` is respected within the cohort.

**Inputs**

| Argument | Type | Default | What it is |
| --- | --- | --- | --- |
| `mem_table` | `text` | — | your memory/corpus table |
| `vec_col` | `text` | — | the embedding column |
| `query_vec` | `float8[]` | — | the query embedding |
| `filter_col` | `text` | `NULL` | metadata column to filter on (NULL = no filter, search all) |
| `filter_val` | `text` | `NULL` | the value to match |
| `k` | `int` | `5` | how many results |
| `id_col` | `text` | `'id'` | the column to return as the id (must be bigint-castable) |
| `content_col` | `text` | `NULL` | the text column to return (NULL = no content) |

**How it works.** (1) Builds a cohort of 0-indexed scan positions from the
optional filter via the [id-resolution mapping](#a-note-on-id-resolution). (2)
`fractal_hybrid_clinical_search` restricts the vector search to that cohort. (3)
Joins the returned `doc_id`s back to your named id and content columns.

**Returns** `(mem_id bigint, content text)`: the real recalled row's id and
content (not canned `generate_series` ids or `"recalled memory snippet N"`).

**Example**
```sql
CREATE TABLE agents_demo_mem (
    session_id bigint, customer_id text, state_vector float8[], content text);
INSERT INTO agents_demo_mem VALUES
    (1001, 'cust-a', ARRAY[0.2, 0.2, 0.2], 'resolved churn via loyalty upgrade'),
    (1002, 'cust-a', ARRAY[0.8, 0.8, 0.8], 'escalated billing dispute to agent'),
    (1003, 'cust-b', ARRAY[0.5, 0.5, 0.5], 'refunded a duplicate charge');

SELECT mem_id, content
FROM fractal_agent_recall_hybrid(
    'agents_demo_mem', 'state_vector', ARRAY[0.18, 0.22, 0.2]::float8[],
    'customer_id', 'cust-a', 2, 'session_id', 'content');
```

**Notes.** Raises `filter matched no rows in …` if the filter matches nothing.
`id_col` must be bigint-castable. This agent takes a single
`(filter_col, filter_val)`. For a multi-predicate cohort (e.g.
`age>65 AND condition='sepsis'`), build the cohort yourself and use [patient_deterioration_triage](#patient-deterioration-triage--fractal_agent_patient_deterioration_triage),
which accepts a caller-built `cohort_doc_ids`.

---

### Recommend diverse — `fractal_agent_recommend_diverse`
**Feedback-aware diverse top-k recommendations (no LLM).**

Use it when you want diverse candidates that avoid recently-rejected items:
Customer Support diverse recovery strategies, Recommendation "you might also
like," Smart-Cities diverse representative-zone sampling. It enables the
session-global Diversify/Repulsion layer, then runs a repulsion-diverse top-k.

**Inputs**

| Argument | Type | Default | What it is |
| --- | --- | --- | --- |
| `catalog_table` | `text` | — | your catalog table |
| `emb_col` | `text` | — | the embedding column |
| `query_vec` | `float8[]` | — | the query embedding |
| `k` | `int` | `10` | how many results |
| `id_col` | `text` | `'id'` | the column to return as the id (must be bigint-castable) |

**How it works.** (1) `fractal_diversify_enable()`: session-global repulsion, so
re-searches avoid recently-rejected items reported via
`fractal_feedback_report`. (2) `fractal_search_telemetry` for the top-k, which the
primitive applies repulsion to when diversify is enabled. (3) Resolves the
0-indexed `doc_id` to your named id via the [id-resolution mapping](#a-note-on-id-resolution).

**Returns** `(item_id bigint, score float8)`: `score = 1 − cosine_distance`,
real from the primitive (not canned `0.95 − i*0.01`).

**Example**
```sql
CREATE TABLE agents_demo_catalog (id bigint, emb float8[]);
INSERT INTO agents_demo_catalog VALUES
    (10, ARRAY[0.1, 0.0, 0.0]),
    (20, ARRAY[0.0, 1.0, 0.0]),
    (30, ARRAY[0.0, 0.0, 1.0]);

SELECT item_id, score
FROM fractal_agent_recommend_diverse(
    'agents_demo_catalog', 'emb', ARRAY[0.12, 0.01, 0.0]::float8[], 3, 'id');

-- Reset the session-global diversify flag when your session is done:
SELECT fractal_diversify_disable();
```

**Notes.** `fractal_diversify_enable()` is a **session-global side effect**:
this agent leaves it on; you are responsible for `fractal_diversify_disable()`
when done. (Contrast [feedback_audit](#feedback-audit--fractal_agent_feedback_audit), which
self-disables.) `id_col` must be bigint-castable.

---

### Data analyst — `fractal_agent_data_analyst`
**Natural-language analytics over any of your tables.**

The horizontal catch-all: the closest thing to a general-purpose agent in the
roster. Use it when no vertical agent fits and you just want to ask a
natural-language question over your tables and get a reasoned answer. It composes
`fractal_sql_agent` (NL→SQL→execute, with its own retry loop) then `fractal_reason`
to synthesize a read of the result. No vertical demo is wired to it.

**Inputs**

| Argument | Type | Default | What it is |
| --- | --- | --- | --- |
| `question` | `text` | — | the natural-language question |
| `table_names` | `text[]` | `NULL` | the tables the agent may query |
| `max_retries` | `int` | `2` | how many correction loops on EXPLAIN/execution failure |
| `context` | `text` | `'{}'` | optional label passed to the reason call |

**How it works.** (1) `fractal_sql_agent(question, table_names, max_retries, true)`:
NL→SQL→execute with `auto_execute=true` so `result_json` carries the real row
count (or a captured execution-failure reason); with `false`, `result_json` is
always NULL. (2) `fractal_reason` writes a one-paragraph analysis over the result.

**Returns** `(analysis text, generated_sql text, result_json jsonb)`:
`analysis` is the LLM's read; `generated_sql` and `result_json` are the SQL
agent's own real outputs (no canned constants).

**Example**
```sql
CREATE TABLE agents_demo_data (id int PRIMARY KEY, category text, amount float8);
INSERT INTO agents_demo_data VALUES
    (1, 'hardware', 1200.00),
    (2, 'software',  800.50),
    (3, 'hardware',  450.25);

SELECT analysis, generated_sql, result_json
FROM fractal_agent_data_analyst(
    'total amount spent per category in agents_demo_data',
    ARRAY['agents_demo_data'], 2);
```

**Notes.** No empty-table guard: there is no fixed table to pre-check;
`fractal_sql_agent` handles its own errors and reports empty/failed results via
`execution_status`. Guard the LLM-facing `fractal_sql_agent` step with a
restricted role (see [Safe Agency & Guardrails](#safe-agency--guardrails)).

---

### Patient deterioration triage — `fractal_agent_patient_deterioration_triage`
**Cohort-restricted patient triage with baseline→current drift.**

Use it for clinical deterioration triage, or any "nearest patient within a
cohort *plus* baseline→current drift" workflow. The `cohort_doc_ids` parameter
accepts a caller-built multi-predicate cohort (e.g. `age>65 AND condition='sepsis'`)
that [recall_hybrid](#recall-hybrid--fractal_agent_recall_hybrid)'s single
`(filter_col, filter_val)` cannot express.

**Inputs**

| Argument | Type | Default | What it is |
| --- | --- | --- | --- |
| `patient_table` | `text` | — | your patient/corpus table |
| `vec_col` | `text` | — | the embedding column |
| `query_vec` | `float8[]` | — | the patient to triage |
| `baseline_vec` | `float8[]` | — | the baseline state for the drift search |
| `current_vec` | `float8[]` | — | the current state for the drift search |
| `cohort_doc_ids` | `int8[]` | `NULL` | caller-built cohort (NULL = all rows) |
| `k` | `int` | `5` | how many cohort neighbors |
| `id_col` | `text` | `'id'` | the column to return as the id (must be bigint-castable) |

**How it works.** (1) Builds the cohort: from `cohort_doc_ids` if supplied, else
every row mapped to 0-indexed scan positions. (2)
`fractal_hybrid_clinical_search` for up to `k` nearest patients in the cohort,
ranked ascending by distance, each resolved to its named patient id via the
[id-resolution mapping](#a-note-on-id-resolution) in the same query. (3)
`fractal_search_trajectory` for the baseline→current drift — always a single
result; `k` does not apply here. (4) `fractal_reason` synthesizes the triage
over the single nearest cohort match and the drift, not over every entry in
`cohort_matches`.

**Returns** `(nearest_cohort_id bigint, cohort_distance float8, drift_distance float8, rationale text, cohort_matches jsonb)`.
`cohort_matches` is a ranked array of up to `k` `{"id":..,"distance":..}`
entries; `nearest_cohort_id`/`cohort_distance` are always `cohort_matches[0]`.

**Example**
```sql
CREATE TABLE agents_demo_patients (
    id int PRIMARY KEY, age int, condition text, vitals float8[]);
INSERT INTO agents_demo_patients VALUES
    (1, 72, 'sepsis',    ARRAY[0.90, -0.80, 0.70, 0.60]),
    (2, 64, 'sepsis',    ARRAY[0.10,  0.10, 0.10, 0.10]),
    (3, 78, 'pneumonia', ARRAY[0.20,  0.20, 0.20, 0.20]),
    (4, 81, 'sepsis',    ARRAY[0.85, -0.75, 0.65, 0.55]);

SELECT nearest_cohort_id, cohort_distance, drift_distance, rationale, cohort_matches
FROM fractal_agent_patient_deterioration_triage(
    'agents_demo_patients', 'vitals',
    ARRAY[0.9, -0.8, 0.7, 0.6]::float8[],
    ARRAY[0.1, 0.1, 0.1, 0.1]::float8[],
    ARRAY[0.95, -0.85, 0.75, 0.65]::float8[],
    (SELECT array_agg(doc_id ORDER BY doc_id) FROM
       (SELECT row_number() OVER (ORDER BY ctid) - 1 AS doc_id
          FROM agents_demo_patients
         WHERE age > 65 AND condition = 'sepsis') x),
    5, 'id');
```

**Notes.** Raises `no patient rows in …` if the table is empty, or `cohort
matched no rows in …` if the cohort is empty. `id_col` must be bigint-castable.
`k` controls only the cohort-search width; the drift search always compares a
single baseline point to a single current point, so it stays fixed at its
nearest point regardless of `k`.

---

### Feedback audit — `fractal_agent_feedback_audit`
**Recommender diversity audit (pure analytics, no LLM).**

Use it to audit a recommender's diversity health: a self-contained cycle that
enables session-global repulsion, warms the rolling diversity window with varied
queries, reports negative feedback on a target result, then reads back the
diversity quotient and session diagnostics. Unlike [recommend_diverse](#recommend-diverse--fractal_agent_recommend_diverse),
this agent **self-disables** diversify: it is a complete audit cycle that
leaves the session clean.

**Inputs**

| Argument | Type | Default | What it is |
| --- | --- | --- | --- |
| `catalog_table` | `text` | — | your catalog table |
| `emb_col` | `text` | — | the embedding column |
| `query_vec` | `float8[]` | — | the audit target's query embedding |
| `warmup_table` | `text` | — | a table of varied vectors to warm the window |
| `warmup_vec_col` | `text` | — | the vector column in the warmup table |
| `warmup_count` | `int` | `8` | how many warmup vectors to run |
| `k` | `int` | `3` | top-k for the warmup searches |

**How it works.** (1) `fractal_diversify_enable()` + `fractal_diversify_set_params`
with audit defaults. (2) Warms the `D_q` rolling window by running
`fractal_search_telemetry` over `warmup_count` varied vectors from the warmup
table (the window is empty until several searches have run; `detect_collapse`
returns NaN otherwise). (3) Captures the audit target's top `doc_id` and calls
`fractal_isolate_background(doc_id)`: the **doc_id is the handle**. (4) Reads back
`fractal_detect_collapse()` and `fractal_explain_result()`. (5) Self-disables
diversify.

**Returns** `(diversity_quotient float8, explanation jsonb)`: the real
`detect_collapse` reading (not NaN once the window is warm) and the real
`fractal_explain_result` diagnostics.

**Example**
```sql
CREATE TABLE agents_demo_fcatalog (id bigint PRIMARY KEY, emb float8[]);
INSERT INTO agents_demo_fcatalog
SELECT gs, ARRAY[random()*2-1, random()*2-1, random()*2-1]
FROM generate_series(1, 20) AS gs;
CREATE TABLE agents_demo_fwarmup (center float8[]);
INSERT INTO agents_demo_fwarmup
SELECT ARRAY[random()*2-1, random()*2-1, random()*2-1]
FROM generate_series(1, 8);

SELECT diversity_quotient, explanation
FROM fractal_agent_feedback_audit(
    'agents_demo_fcatalog', 'emb', ARRAY[0.5, 0.5, 0.5]::float8[],
    'agents_demo_fwarmup', 'center', 8, 3);
```

**Notes.** Raises `no catalog rows in …` if the catalog is empty. Needs a
warmup table with enough varied vectors to fill the window, or
`diversity_quotient` comes back NaN.

---

### Schedule workload — `fractal_agent_schedule_workload`
**Schedule a workload onto the best node (with vector refinement).**

Use it for Sovereign-Edge node scheduling, or any "refine a task vector, then
find the nearest capable node" workflow. Like [route_task](#route-task--fractal_agent_route_task)
but with a `fractal_search` refinement step that route_task lacks: the "sniper
search" in the abstract search space before the nearest-node lookup.

**Inputs**

| Argument | Type | Default | What it is |
| --- | --- | --- | --- |
| `task_vec` | `float8[]` | — | the workload's task vector |
| `node_table` | `text` | — | your node/capability table |
| `node_emb_col` | `text` | — | the embedding column in that table |
| `node_id_col` | `text` | — | the column to return as the node id |
| `iterations` | `int` | `30` | `fractal_search` refinement iterations |
| `population` | `int` | `50` | `fractal_search` population size |
| `k` | `int` | `5` | how many nearest nodes |
| `context` | `text` | `'{}'` | optional label passed to the reason call |

**How it works.** (1) `fractal_search(task_vec, iterations, population, 2)`:
refines the task vector (diffusion factor 2). (2)
`fractal_search_telemetry(node_table, node_emb_col, refined, 1)` for the nearest
node. (3) Resolves the scan position to the named node id via the
[id-resolution mapping](#a-note-on-id-resolution). (4) `fractal_reason` writes a one-line
placement rationale.

**Returns** `(assigned_node text, confidence float8, rationale text)`:
`confidence = 1/(1+distance)`.

**Example**
```sql
CREATE TABLE agents_demo_nodes (id int PRIMARY KEY, capability float8[]);
INSERT INTO agents_demo_nodes VALUES
    (1, ARRAY[0.9, 0.1, 0.0, 0.0, 0.0]),
    (2, ARRAY[0.0, 0.0, 0.9, 0.1, 0.0]),
    (3, ARRAY[0.1, 0.0, 0.0, 0.0, 0.9]);

SELECT assigned_node, confidence, rationale
FROM fractal_agent_schedule_workload(
    ARRAY[0.8, 0.1, 0.0, 0.0, 0.1]::float8[],
    'agents_demo_nodes', 'capability', 'id', 30, 50, 5);
```

**Notes.** Raises `no node rows in …` if the node table is empty.

---

### Rebalance sibling — `fractal_agent_rebalance_sibling`
**Rebalance a portfolio and compare to the nearest historical allocation.**

Use it for Quant-Finance rebalancing: run the SFS cardinality-constrained
optimizer, then find the nearest historical allocation pattern in a snapshots
table, then reason over both. Generalizes the fintech-MCTS reference blueprint.

**Inputs**

| Argument | Type | Default | What it is |
| --- | --- | --- | --- |
| `mu` | `float8[]` | — | expected returns per asset |
| `cov` | `float8[]` | — | covariance, **flattened 1-D row-major n×n** |
| `cardinality` | `int` | — | how many assets to hold |
| `alloc_table` | `text` | — | your historical-allocation-snapshots table |
| `alloc_emb_col` | `text` | — | the embedding column in that table |
| `baseline_vec` | `float8[]` | — | the baseline for the trajectory search |
| `seed` | `bigint` | `NULL` | optimizer RNG seed (NULL = nondeterministic) |
| `k` | `int` | `5` | how many nearest snapshots |
| `id_col` | `text` | `'id'` | the column to return as the allocation id (must be bigint-castable) |
| `context` | `text` | `'{}'` | optional label passed to the reason call |

**How it works.** (1) `fractal_optimize_portfolio(mu, cov, cardinality, seed)`.
(2) Extracts the weights as a `float8[]` vector. (3)
`fractal_search_trajectory(alloc_table, alloc_emb_col, baseline_vec, weights, 1)`
for the nearest historical allocation. (4) Resolves its `doc_id` to the named
allocation id via the [id-resolution mapping](#a-note-on-id-resolution). (5) `fractal_reason`
synthesizes the rebalance rationale.

**Returns** `(sharpe float8, weights jsonb, nearest_alloc_id bigint, nearest_distance float8, rationale text)`.

**Example**
```sql
CREATE TABLE agents_demo_alloc (id bigint PRIMARY KEY, alloc float8[]);
INSERT INTO agents_demo_alloc VALUES
    (1, ARRAY[0.25, 0.25, 0.25, 0.25]),
    (2, ARRAY[0.40, 0.30, 0.20, 0.10]),
    (3, ARRAY[0.10, 0.20, 0.30, 0.40]);

SELECT sharpe, weights, nearest_alloc_id, nearest_distance, rationale
FROM fractal_agent_rebalance_sibling(
    ARRAY[0.05, 0.10, 0.15, 0.20]::float8[],
    ARRAY[0.04, 0.0, 0.0, 0.0,
          0.0, 0.09, 0.0, 0.0,
          0.0, 0.0, 0.16, 0.0,
          0.0, 0.0, 0.0, 0.25]::float8[],
    4, 'agents_demo_alloc', 'alloc',
    ARRAY[0.25, 0.25, 0.25, 0.25]::float8[], NULL, 5, 'id');
```

**Notes.** `cov` is a **flattened 1-D row-major** matrix. `id_col` must be
bigint-castable: `nearest_alloc_id` is returned as `bigint`, so a text label
column won't do (pass the numeric PK). Raises `no allocation rows in …` if the
allocation table is empty.

---

### Diverse portfolios — `fractal_agent_diverse_portfolios`
**Enterprise tier.** Companion to `allocate`, above: instead of one
cardinality-constrained portfolio, return several structurally distinct good
ones.

Use it when a single "best" portfolio understates the real decision: a
portfolio manager usually wants to see a few genuinely different ways to hit a
similar risk-adjusted return, not one point estimate. Runs
`fractal_optimize_portfolio_multimodal` (multiple restarts, diverse-selected,
same entropy engine as the single-best optimizer, a licensed capability
gate, not a different algorithm) and reasons once over all the candidates'
tradeoffs.

**Inputs**

| Argument | Type | Default | What it is |
| --- | --- | --- | --- |
| `mu` | `float8[]` | — | expected returns per asset |
| `cov` | `float8[]` | — | covariance, **flattened 1-D row-major n×n** |
| `cardinality` | `int` | — | how many assets each candidate may hold |
| `n_restarts` | `int` | `8` | independent restarts (upper bound on candidates found) |
| `overlap_threshold` | `float8` | `0.15` | max shared-asset fraction between two returned candidates |
| `quality_frac` | `float8` | `0.90` | candidates must be within this fraction of the best Sharpe found |
| `seed` | `bigint` | `NULL` | optimizer RNG seed (NULL = nondeterministic) |
| `context` | `text` | `'{}'` | optional label passed to the reason call |
| `objective_mode` | `text` | `'sharpe'` | `'sharpe'` or `'pareto'`: selection strategy, see below |

**How it works.** `objective_mode = 'sharpe'` (default): (1)
`fractal_optimize_portfolio_multimodal(mu, cov, cardinality, n_restarts,
overlap_threshold, quality_frac, seed)` for up to `n_restarts` structurally
distinct candidates, sharpe-threshold + asset-overlap selected. (2) One
`fractal_reason` call summarizing the tradeoffs across all of them.
`objective_mode = 'pareto'` instead runs
`fractal_optimize_portfolio_multimodal_pareto(mu, cov, cardinality,
n_restarts, n_restarts, seed)`: the same `n_restarts` independent searches,
but scored by decomposed return/risk and reduced to a genuine non-dominated
Pareto front (NSGA-II crowding-distance truncation, not sharpe-threshold +
overlap selection); `overlap_threshold`/`quality_frac` are ignored in this
mode. Either mode calls `fractal_reason` once over all the candidates (not
one call per candidate); the prompt framing differs by mode (Sharpe-band
language vs. return/risk-dominance language).

**Returns** one row per candidate: `(candidate_id int, sharpe float8, weights
jsonb, rationale text)`. `rationale` repeats per row since it's a single
reasoning call covering every candidate. In `'sharpe'` mode `weights` is a
bare array, same as `allocate`. In `'pareto'` mode `weights` is instead
`{"weights": [...], "return": r, "risk": v}`: a richer object so per-row
return/risk are machine-queryable straight from the agent's output, without
a second call to `fractal_optimize_portfolio_multimodal_pareto` directly.

**Example**
```sql
SELECT candidate_id, sharpe, weights, rationale
FROM fractal_agent_diverse_portfolios(
    ARRAY[0.05, 0.10, 0.15, 0.20]::float8[],
    ARRAY[0.04, 0.0, 0.0, 0.0,
          0.0, 0.09, 0.0, 0.0,
          0.0, 0.0, 0.16, 0.0,
          0.0, 0.0, 0.0, 0.25]::float8[],
    2, 6);

-- Pareto-front mode: weights carries {weights, return, risk} per candidate.
SELECT candidate_id, weights->'return' AS return, weights->'risk' AS risk, rationale
FROM fractal_agent_diverse_portfolios(
    ARRAY[0.05, 0.10, 0.15, 0.20]::float8[],
    ARRAY[0.04, 0.0, 0.0, 0.0,
          0.0, 0.09, 0.0, 0.0,
          0.0, 0.0, 0.16, 0.0,
          0.0, 0.0, 0.0, 0.25]::float8[],
    2, 6, objective_mode := 'pareto');
```

**Notes.** `cov` is a **flattened 1-D row-major** matrix, same as
`allocate`/`rebalance_sibling`. Enterprise tier: errors with `enterprise
tier not loaded` until `fractalsql.enterprise_lib` is set; dormant on the
community image by default (see `demo/enterprise-qtl-audit.sql` for
activation). In `'sharpe'` mode, raises `no candidates found` if the
optimizer can't find any candidate within `quality_frac` of the best
Sharpe; in `'pareto'` mode, raises the same error if the non-dominated
front comes back empty (should not happen for `n_restarts >= 1`, but
guarded the same way as the sharpe path for consistency).

---

### Detour classify — `fractal_agent_detour_classify`
**Classify a vehicle detour: route deviation + GPS-trace complexity.**

Use it for Fleet-Logistics detour classification, or any trajectory-deviation +
GPS-trace-complexity workflow. It combines the route-deviation search across the
fleet with the fractal (box-counting) complexity of the vehicle's GPS trace.

**Inputs**

| Argument | Type | Default | What it is |
| --- | --- | --- | --- |
| `vehicle_table` | `text` | — | your fleet table |
| `emb_col` | `text` | — | the embedding column (searched for the deviation) |
| `baseline_vec` | `float8[]` | — | the vehicle's baseline route vector |
| `current_vec` | `float8[]` | — | the vehicle's current route vector |
| `gps_trace` | `float8[]` | — | the GPS trace as a flat interleaved array |
| `k` | `int` | `5` | how many nearest fleet peers |
| `id_col` | `text` | `'id'` | the column to return as the vehicle id (must be bigint-castable) |
| `boxcount_dim` | `int` | `2` | the box-counting embedding dimension |

**How it works.** (1) `fractal_search_trajectory(vehicle_table, emb_col, baseline_vec, current_vec, 1)`
for the route deviation vs. the fleet. (2) `fractal_dimension_boxcount(gps_trace, boxcount_dim)`
for the GPS trace complexity. (3) Resolves the nearest fleet peer's `doc_id` to
the named vehicle id via the [id-resolution mapping](#a-note-on-id-resolution). (4)
`fractal_reason` classifies the detour.

**Returns** `(nearest_fleet_id bigint, trajectory_distance float8, trace_complexity float8, rationale text)`.

**Example**
```sql
CREATE TABLE agents_demo_vehicles (
    id int PRIMARY KEY, baseline float8[], current float8[]);
INSERT INTO agents_demo_vehicles
SELECT gs, ARRAY[b1, b2, b3, b4], ARRAY[b1+0.05, b2+0.05, b3+0.05, b4+0.05]
FROM generate_series(1, 8) AS gs,
     LATERAL (SELECT random()*2-1 AS b1, random()*2-1 AS b2,
                     random()*2-1 AS b3, random()*2-1 AS b4) AS bl;
-- Give vehicle 1 a deliberate detour.
UPDATE agents_demo_vehicles
   SET current = ARRAY[(baseline::float8[])[1]-0.7, (baseline::float8[])[2]+0.6,
                       (baseline::float8[])[3]+0.5, (baseline::float8[])[4]-0.4]
 WHERE id = 1;

SELECT nearest_fleet_id, trajectory_distance, trace_complexity, rationale
FROM fractal_agent_detour_classify(
    'agents_demo_vehicles', 'current',
    (SELECT baseline::float8[] FROM agents_demo_vehicles WHERE id = 1),
    (SELECT current::float8[]  FROM agents_demo_vehicles WHERE id = 1),
    (SELECT array_agg(cum ORDER BY t, ord) FROM (
         SELECT t, ord, sum(step) OVER (PARTITION BY ord ORDER BY t) AS cum
           FROM generate_series(1, 100) AS t
          CROSS JOIN LATERAL (VALUES (1, (random()-0.5)*0.3),
                              (2, (random()-0.5)*0.3)) AS s(ord, step)
     ) c),
    5, 'id', 2);
```

**Notes.** Raises `no vehicle rows in …` if the vehicle table is empty.
`id_col` must be bigint-castable.

---

### Track anomaly — `fractal_agent_track_anomaly`
**Triage a track anomaly: trajectory deviation + heading-change DFA.**

Use it for Maritime track-deviation detection or Cybersecurity beaconing/C2
detection: any trajectory-drift + heading-change-DFA workflow. It combines the
track-deviation search across the fleet with the DFA long-range-correlation
exponent of the heading-change series.

**Inputs**

| Argument | Type | Default | What it is |
| --- | --- | --- | --- |
| `track_table` | `text` | — | your fleet/track table |
| `emb_col` | `text` | — | the embedding column (searched for the deviation) |
| `baseline_vec` | `float8[]` | — | the track's baseline vector |
| `current_vec` | `float8[]` | — | the track's current vector |
| `heading_series` | `float8[]` | — | the heading-change series |
| `k` | `int` | `5` | how many nearest fleet peers |
| `id_col` | `text` | `'id'` | the column to return as the track id (must be bigint-castable) |

**How it works.** (1) `fractal_search_trajectory(track_table, emb_col, baseline_vec, current_vec, 1)`
for the track deviation vs. the fleet. (2) `fractal_dimension_dfa(heading_series)`
for the heading-change exponent. (3) Resolves the nearest fleet peer's `doc_id`
to the named track id via the [id-resolution mapping](#a-note-on-id-resolution). (4)
`fractal_reason` triages the track.

**Returns** `(nearest_fleet_id bigint, trajectory_distance float8, dfa_exponent float8, rationale text)`.

**Example**
```sql
CREATE TABLE agents_demo_tracks (
    id int PRIMARY KEY, baseline float8[], current float8[]);
INSERT INTO agents_demo_tracks
SELECT gs, ARRAY[b1, b2, b3, b4], ARRAY[b1+0.04, b2+0.04, b3+0.04, b4+0.04]
FROM generate_series(1, 8) AS gs,
     LATERAL (SELECT random()*2-1 AS b1, random()*2-1 AS b2,
                     random()*2-1 AS b3, random()*2-1 AS b4) AS bl;
-- Give vessel 1 a deliberate track deviation.
UPDATE agents_demo_tracks
   SET current = ARRAY[(baseline::float8[])[1]+0.6, (baseline::float8[])[2]-0.5,
                       (baseline::float8[])[3]-0.9, (baseline::float8[])[4]+0.8]
 WHERE id = 1;

SELECT nearest_fleet_id, trajectory_distance, dfa_exponent, rationale
FROM fractal_agent_track_anomaly(
    'agents_demo_tracks', 'current',
    (SELECT baseline::float8[] FROM agents_demo_tracks WHERE id = 1),
    (SELECT current::float8[]  FROM agents_demo_tracks WHERE id = 1),
    (SELECT array_agg(cum ORDER BY t) FROM (
         SELECT t, sum(step) OVER (ORDER BY t) AS cum
           FROM (SELECT t,
                        (random()-0.5) * (CASE WHEN t BETWEEN 40 AND 60 THEN 0.35
                                               ELSE 0.03 END) AS step
                   FROM generate_series(1, 120) AS t) s
     ) c),
    5, 'id');
```

**Notes.** `dfa_exponent` may be `-1` (insufficient window), passed through;
the reason step notes it. Raises `no track rows in …` if the track table is
empty. `id_col` must be bigint-castable.

---

### Network coverage alert — `fractal_agent_network_coverage_alert`
**Smart-cities coverage alert: spatial morphology + telemetry drift.**

Use it for Smart-Cities sensor-grid coverage alerts, or any spatial-morphology +
telemetry-drift workflow. It combines the sensor grid's fractal morphology
(dimension + lacunarity) with the telemetry series' regime-change drift, then
reasons an alert.

**Inputs**

| Argument | Type | Default | What it is |
| --- | --- | --- | --- |
| `point_cloud` | `float8[]` | — | the sensor grid as a flat interleaved point array |
| `drift_series` | `float8[]` | — | the telemetry series |
| `boxcount_dim` | `int` | `2` | the morphology box-counting dimension |
| `drift_win` | `int` | `48` | the drift recent-window size |
| `drift_threshold` | `float8` | `0.5` | `drift_detected = \|drift\| > drift_threshold` |
| `context` | `text` | `'{}'` | optional label passed to the reason call |

**How it works.** (1) `fractal_morphological_complexity(point_cloud, boxcount_dim)`
→ `{dimension, lacunarity}`. (2) `fractal_dimension_drift(drift_series, drift_win)`
→ the drift field, a **signed numeric** (`recent_alpha − baseline_alpha`, not a
boolean). (3) `drift_detected = abs(drift) > drift_threshold`. (4) `fractal_reason`
issues the alert.

**Returns** `(morph_dimension float8, lacunarity float8, drift_detected boolean, rationale text)`.

**Example**
```sql
-- 20×20 sensor grid (400 points) + a 96-point step-up telemetry series.
SELECT morph_dimension, lacunarity, drift_detected, rationale
FROM fractal_agent_network_coverage_alert(
    (SELECT array_agg(v ORDER BY id, ord) FROM (
         SELECT r*20 + c AS id, ord, v
           FROM generate_series(0, 19) AS r
          CROSS JOIN generate_series(0, 19) AS c
          CROSS JOIN LATERAL unnest(ARRAY[r + (random()-0.5)*0.3,
                                          c + (random()-0.5)*0.3]) WITH ORDINALITY AS u(v, ord)
     ) g),
    (SELECT array_agg(v ORDER BY t) FROM (
         SELECT t, CASE WHEN t < 48 THEN 4.0 + 1.5*sin(t*0.31) + (random()-0.5)*0.8
                        ELSE 4.0 + 3.0*sin(t*1.4)  + (random()-0.5)*0.4 END AS v
           FROM generate_series(1, 96) AS t) s),
    2, 48, 0.5);
```

**Notes.** `point_cloud` needs **~≥256 points** for the morphology estimator to
succeed (a 20×20 grid = 400 points works; 100 or a scattered 60 fail with
`rc=-1`). `point_cloud` is a flat `n_points × dim` interleaved array. Raises
`point_cloud and drift_series are required` if either is NULL. The `drift` field
is a **signed numeric**, not a boolean: `drift_detected` is the boolean
comparison.

---

### Regime triage — `fractal_agent_regime_triage`
**Triage a regime change in a single series (array-in, no table).**

Use it for any single-series regime-change triage (Quant-Finance market regime,
Cybersecurity traffic regime, Smart-Cities sensor regime) when you already hold
the series as an array and don't have a per-row time/metric table (that's
[anomaly_triage](#anomaly-triage--fractal_agent_anomaly_triage)). It runs the DFA
long-range-correlation exponent and the regime-change drift, then reasons.

**Inputs**

| Argument | Type | Default | What it is |
| --- | --- | --- | --- |
| `series` | `float8[]` | — | the time series |
| `win` | `int` | `64` | the drift recent-window size |
| `drift_threshold` | `float8` | `0.5` | `drift_detected = \|drift\| > drift_threshold` |
| `context` | `text` | `'{}'` | optional label passed to the reason call |

**How it works.** (1) `fractal_dimension_dfa(series)` for the long-range
correlation exponent. (2) `fractal_dimension_drift(series, win)` for the
regime-change drift + recent/baseline alphas. (3) `drift_detected = abs(drift) >
drift_threshold`. (4) `fractal_reason` triages the regime change.

**Returns** `(dfa_exponent float8, drift_detected boolean, recent_alpha float8, baseline_alpha float8, rationale text)`.

**Example**
```sql
-- 96-point step-up series: baseline for the first 48 points, then a regime change.
SELECT dfa_exponent, drift_detected, recent_alpha, baseline_alpha, rationale
FROM fractal_agent_regime_triage(
    (SELECT array_agg(v ORDER BY t) FROM (
         SELECT t, CASE WHEN t < 48 THEN 4.0 + 1.5*sin(t*0.31) + (random()-0.5)*0.8
                        ELSE 4.0 + 3.0*sin(t*1.4)  + (random()-0.5)*0.4 END AS v
           FROM generate_series(1, 96) AS t) s),
    64, 0.5);
```

**Notes.** `dfa_exponent` may be `-1` (insufficient window), passed through.
Raises `series is required` if `series` is NULL. The `drift` field is a **signed
numeric** (`recent_alpha − baseline_alpha`), not a boolean; `drift_detected` is
the boolean comparison.

---

### A note on id resolution

`fractal_search_telemetry` and `fractal_hybrid_clinical_search` return `doc_id`
as a **0-indexed row position** in the C code's heap scan, not a primary key.
The table-searching agents (`recall_hybrid`, `recommend_diverse`,
`patient_deterioration_triage`, `schedule_workload`, `rebalance_sibling`,
`detour_classify`, `track_anomaly`) resolve that position to your named id column
(`id_col`) via `row_number() OVER (ORDER BY rowid) - 1` in the SQLite
integration (there is no separate physical-row-identifier pseudo-column to
fall back on here): the same robust mapping
the maritime/cybersecurity demos and the C source use internally for cohort
construction. `id_col` must be an integer key (e.g. `rebalance_sibling`
returns `nearest_alloc_id` as a number, so a text label column won't do; pass the
numeric PK).

`recommend_diverse` calls `fractal_diversify_enable()` as a session-global side
effect (so re-searches avoid recently-rejected items reported via
`fractal_feedback_report`); reset it with `fractal_diversify_disable()` when your
session is done. `feedback_audit` runs the whole audit cycle (enable → warmup →
isolate → read-back) **and self-disables** diversify, so it leaves the session
clean without caller cleanup.

---

## Building blocks: the six Universal Agents

The installable agents above are productized recipes. Underneath them are six **Universal
Agents**: C-level functions registered by the extension's own entrypoint the
moment it loads (see the registration table in `src/fsql_agents.c`) —
in the SQLite integration, callable as soon as `.load
/usr/local/lib/sqlite3/fractalsql` runs, with no separate install/activation
step and no separate agents extension. These are the building
blocks the server edition's procedural-language agents compose; you can also
call them directly or compose them into your own agents (see
[Composing your own](#composing-your-own)). They
require a reasoning plugin plus an OpenAI-compatible chat endpoint (and, for the
agents that embed a query, an embeddings endpoint) configured via
`fractalsql_set(...)` per connection. See [`reasoning-setup.md`](reasoning-setup.md). Signatures
mirror the C in `src/fsql_agents.c` exactly (argument order, types, defaults, and
`STRICT`ness — SQLite wrappers carry the same NULL-propagating behavior as the
server edition's own strict-argument declarations).

*Shape differences in the SQLite integration:* SQLite scalar functions cannot
return sets or composite rows, so the multi-value results below come back as a
single **TEXT JSON document** per call (pick fields with `json_extract(...)`);
`table_names` is a **JSON array TEXT** (there is no `text[]`); `detect_loop`'s
hash series is **JSON/CSV array TEXT** (no `int8[]`); and the id-resolution
mapping uses SQLite's `rowid` — SQLite has no separate physical-row-identifier
pseudo-column, so `rowid` fills that role directly.

### `fractal_search_agent`
**End-to-End Synthesis Agent**

Embeds a query, performs a diverse Scout search, and synthesizes the results into a reasoned answer.

`vector_col` must hold vectors (CSV-of-floats TEXT, bracketed-JSON TEXT, or the
canonical `fractal_vector` BLOB in the SQLite integration), and its element width must
match the configured embedding model's output dimension (768 for
`nomic-embed-text`, 1536 for `text-embedding-3-small`). Pointing the agent at a
non-vector column (e.g. an `INTEGER` state hash) raises a clean
error rather than crashing
the host process.

The reasoning step synthesizes its answer over the **retrieved rows'
content**, not the raw vectors. After the Scout search the agent maps each
top-k result position back to its physical row (by `rowid` in the SQLite
integration, captured during
the corpus scan) and fetches the matched rows' non-vector columns as a JSON
array. That compact, LLM-readable context is what `fractal_reason` consumes.
(The raw Scout result, by contrast, contains the top-k *embeddings*,
useless to an LLM and large enough, at `pop_size × dim` floats, to exceed a
local model's context window and fail the chat call.) `source_doc_ids` are the
0-based positions of the retrieved rows in the corpus scan.

```sql
fractal_search_agent(
    query       text,
    table_name  text,
    vector_col  text,
    pop_size    int  DEFAULT 50,
    iterations  int  DEFAULT 15
) RETURNS TEXT          -- one JSON document: {answer, source_doc_ids, execution_time_ms}
```
- `answer`: The synthesized text response from the LLM (`json_extract(res, '$.answer')`).
- `source_doc_ids`: The indices of the rows used as context.
- `execution_time_ms`: Total pipeline latency.

### `fractal_sql_agent`
**Self-Correcting SQL Agent**

Generates SQL from natural language and automatically retries upon prepare-check or execution failure (SQLite has no `EXPLAIN` gate — the parse/readonly check plays that role).

```sql
fractal_sql_agent(
    question      text,
    table_names   text  DEFAULT NULL,   -- JSON array of names, e.g. '["orders","customers"]'
    max_retries   int   DEFAULT 2,
    auto_execute  int   DEFAULT 0        -- truthy = execute the validated statement
) RETURNS TEXT          -- one JSON document: {generated_sql, execution_status, retry_count, result_json}
```
- `generated_sql`: The final validated SQL statement.
- `execution_status`: Status of the auto-execution (e.g., `"executed"`, `"failed"`).
- `retry_count`: Number of correction loops performed.
- `result_json`: JSON representation of the query results (if `auto_execute` was set).

### `fractal_agent_plan_explore`
**Strategy Trajectory Exploration**

Uses MCTS-style diversification to explore multiple non-overlapping strategy trajectories in a state space. Returns one row per explored branch.

```sql
fractal_agent_plan_explore(
    initial_state    text,
    strategy_table   text,
    vector_col       text,
    max_branches     int
) RETURNS TEXT          -- one JSON document of explored branches
```

`max_branches` is required (no default). `initial_state` is `text`: the
exploration seeds from the vector nearest to this state label, not from a
raw vector. The function is NULL-propagating (the server edition marks it
`STRICT`): a `NULL` argument returns `NULL` rather than executing.

Each returned branch carries its own `plan_trajectory`: the **matched
strategy's** embedding (the corpus row at that branch's result index), so the
branches are distinct rather than all echoing the query vector.
`confidence_score` is `1.0 − distance`. The branches come back as **one JSON
document** (SQLite scalar functions can't return sets — there's no
set-returning-function shape to fall back on here).
- `branch_id`: Unique identifier for the explored trajectory.
- `plan_trajectory`: The converged state vector for this branch.
- `confidence_score`: The fitness/relevance score of the trajectory.

### `fractal_agent_trajectory_predict`
**State Drift Forecasting**

Projects future state by searching for similar delta-vectors ($\Delta = V_{now} - V_{baseline}$) in historical telemetry.

```sql
fractal_agent_trajectory_predict(
    table_name      text,
    vector_col      text,
    baseline_id     int,
    forecast_steps  int
) RETURNS TEXT          -- one JSON document: {predicted_state_vector, projected_drift_delta, risk_threshold_exceeded}
```

All four arguments are required. The function resolves `table_name`'s
primary-key column from the schema (`sqlite_master` / `PRAGMA
table_info` in the SQLite integration), reads the **baseline** vector from the
row whose PK equals `baseline_id`, and the **current** vector from the latest
row (max PK). It derives `dim` from the data (not a hardcoded width) and
searches the corpus for the nearest state to $\Delta = V_{current} - V_{baseline}$.
`table_name` must therefore have a single-column primary key (an explicit
`PRIMARY KEY` or a rowid alias) and a non-NULL
`vector_col` of vector TEXT/BLOB on both the baseline and latest
rows. `forecast_steps` is reserved for a future extrapolation step.
- `predicted_state_vector`: The corpus row nearest to the drift delta (real, data-derived dim).
- `projected_drift_delta`: The distance to that nearest row.
- `risk_threshold_exceeded`: True if the drift exceeds 0.5.

### `fractal_agent_detect_loop`
**DFA-Based Safety Monitor**

Detects infinite agent loops or repetitive behavior by analyzing the scaling exponent of state hashes.

```sql
fractal_agent_detect_loop(
    log_arr text            -- JSON array or CSV of ordered state hashes
) RETURNS TEXT             -- one JSON document: {agent_id, dfa_exponent, is_loop_detected}
```

`log_arr` is a **JSON array or CSV TEXT** of ordered agent state hashes (the
SQLite analog of a native integer-array argument): typically `json_group_array(state_hash ORDER
BY event_ts)` from an agent event
log. A loop is flagged when **either** signal fires:

- the DFA scaling exponent $\alpha$ exceeds 0.9 (drift-to-chaos / random-walk-like
  cycling), **or**
- a tight discrete period $p \in [1, n/4]$ is found where
  `series[i] == series[i+p]` for all `i` (a clean toggle such as
  `12345 <-> 67890`, which the DFA scores as a low $\alpha \approx 0.1$ and
  would otherwise miss).
- `agent_id`: Identifier of the monitored agent (currently the constant `"monitor"`).
- `dfa_exponent`: The calculated $\alpha$ scaling exponent.
- `is_loop_detected`: True if either the DFA threshold or the short-period check fires.

### `fractal_rag_agent`
**Hybrid Retrieve-Reason Agent**

Embeds a query, Scout-searches a corpus, then reasons over the retrieved context to produce a single answer: a focused, single-turn RAG pattern.

Like `fractal_search_agent`, the reasoning step consumes the **retrieved rows'
content** (their non-vector columns, fetched by `rowid` in the SQLite
integration) rather than the raw
top-k vectors. See that function's note for why. The chat-dispatch return
code is checked: a reasoning-endpoint failure raises a clean error with the
plugin's detail, instead
of returning a NULL/garbage answer.

```sql
fractal_rag_agent(
    query        text,
    table_name   text,
    vector_col   text,
    meta_filter  text DEFAULT '{}'
) RETURNS TEXT          -- one JSON document: {answer}
```

`meta_filter` is reserved for a future metadata `WHERE` filter; it is
currently accepted but not yet applied to the search.
- `answer`: The synthesized text response from the LLM.

---

## Reference blueprints: Domain Agents

The three agentic-vertical demos (`demo/demo-vertical-agentic-ops-devops.sql`,
`-fintech-mcts.sql`, `-customer-support.sql`) hand-compose six **Domain
Agent** blueprints straight in SQL — the raw primitive calls, wired together —
then follow each one with a `.print --- the shipped agent: same composition,
one call ---` marker and a call to the installed `fractal_agent_*` function
that generalizes it, so you can see the hand-rolled composition and the
productized one side by side. Every demo is a clean, re-runnable regression
test: it drops and recreates its tables at the top, so run it again safely.

### DevOps / SRE — `demo/demo-vertical-agentic-ops-devops.sql`

| Domain Agent | Composes | Purpose |
| --- | --- | --- |
| `fractal_agent_route_task(task, cap_map, budget)` → `(routed_to, confidence, remaining_budget)` | `fractal_search_agent` (embed → Scout → reason) | Sub-agent dispatcher: matches an incoming task to the best capable sub-agent and returns a confidence plus a token-budget accounting. |
| `fractal_agent_outlier_intercept(state_vec, history_table, threshold)` → `(intercepted, reason)` | `fractal_search_telemetry` | Pre-commit safety barrier: screens a proposed action's state vector against known-bad state clusters and intercepts it when the nearest bad state is within `threshold`. |
| `fractal_agent_threat_triage(host_id, log_table, baseline_window)` → `(threat_score, anomaly_type, triage_summary)` | `fractal_dimension_drift` + `fractal_reason` | SOC incident triage: scores drift on the host's latency series, then reasons a human-readable triage summary over the drift result. |

### FinTech — `demo/demo-vertical-agentic-fintech-mcts.sql`

| Domain Agent | Composes | Purpose |
| --- | --- | --- |
| `fractal_agent_portfolio_rebalance(portfolio_id, target_cardinality)` → `(new_weights, drift_score, rationale)` | `fractal_optimize_portfolio` + `fractal_reason` | Cardinality-constrained rebalance: runs the SFS Sharpe optimizer for the target asset count, then reasons a rationale for the weight shift. |

### Customer Support — `demo/demo-vertical-agentic-customer-support.sql`

| Domain Agent | Composes | Purpose |
| --- | --- | --- |
| `fractal_agent_recall_hybrid(query, mem_table, alpha)` → `(mem_id, content)` | `fractal_search_trajectory` + SQL filter | Hybrid memory recall: fuses a strict metadata filter with a drift-vector (current-vs-baseline) state search. |
| `fractal_agent_recommend_diverse(customer_id, catalog_table, k)` → `(item_id, score)` | `fractal_diversify_enable` + Scout (`fractal_search_explore`) | Feedback-aware recommender: enables the stateful Diversify/Repulsion layer so re-searches avoid recently-rejected items, then Scout-searches for diverse candidates. |

### Getting started with the blueprints

1. **Prerequisites**: the extension loaded (`.load /usr/local/lib/sqlite3/fractalsql`)
   and reasoning configured; the agents call `fractal_reason` / `fractal_embed`,
   so follow [`reasoning-setup.md`](reasoning-setup.md) first. The two
   embed-coupled demos (DevOps, FinTech) also need an embeddings endpoint and a
   vectorized column. See [`vectorizer-setup.md`](vectorizer-setup.md).
2. **Run a demo** end to end:
   ```sh
   sqlite3 :memory: -cmd '.load /usr/local/lib/sqlite3/fractalsql' -init demo/demo-vertical-agentic-customer-support.sql
   ```
3. **Read the composition**: each blueprint's raw SQL sits above its
   `--- the shipped agent: same composition, one call ---` marker in the demo
   file. Copy that composition into your own schema and swap in your tables
   and columns, or call the installed `fractal_agent_*` function directly.

---

## Composing your own

The six Universal Agents above are the C-level building blocks; the sixteen
installable agents and the original Domain Agent blueprints show them composed
into vertical workflows. If your problem doesn't match one of the sixteen
recipes, compose your own: in the server edition that's a server-side
procedural language, in the
SQLite integration there is no server-side procedural language, so a custom
agent is ordinary application code — a query that calls one primitive, feeds
its output into the next's input, and shapes the result. The composition
principle (and every primitive) is identical across both editions.

For the full guide, see **[composition-guide.md](composition-guide.md)**: the
building-block pick-list, the four-stage pipeline (retrieve → reason → act →
guard), three worked patterns (single-turn RAG, self-correcting analyst,
multi-step agent with a safety barrier), the Safe Agency & Guardrails rules
for `fractal_sql_agent`, and a copy-paste skeleton.

---

## Validate

Gate 29 of `build_test.sh`/`build_test.ps1` smoke-tests three representative
installable agents (`anomaly_triage`, `recall_hybrid`, `regime_triage`) end to
end against a mock reasoning canary, covering the three composition shapes
(table-backed + LLM, pure retrieval with a cohort filter, array-in + LLM); the
existing gate 23 covers the six Universal Agents the same way. Run either with:

```sh
./build_test.sh --gate 29
./build_test.sh --gate 23
```

`demo/demo-agents.sql` exercises all sixteen installable agents end to end:
each section runs its raw-primitive blueprint, then a `.print --- the shipped
agent: same composition, one call ---` marker and a call to the installed
`fractal_agent_*` function, the same pattern as the
`demo-vertical-agentic-*.sql` blueprints above. Every example on this page is
drawn from that demo. Run it with:

```sh
sqlite3 :memory: -cmd '.load /usr/local/lib/sqlite3/fractalsql' -init demo/demo-agents.sql
```

See [the agents demo](../demo/README.md) and
[`getting-started.md`](getting-started.md) to get running first.