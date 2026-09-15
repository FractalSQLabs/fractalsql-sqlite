<p align="center">
  <img src="../FractalSQLforSQLite.jpg" alt="FractalSQL for SQLite" width="720">
</p>

# Composition Guide: Build Your Own Agent

You have run the [industry starter kits](starter-kits.md) and read the
[sixteen agent recipes](api-agency.md#the-sixteen-recipes). Now the question
is: **how do I build a proprietary agent that isn't in the box?**

The good news: there is no framework to learn. Every FractalSQL primitive
(the search functions, the reasoning bridge, the six Universal Agents) is an
**ordinary SQL function**. A custom agent is just a routine in your host
language (or a view/plain SQL) that calls them in sequence, feeds one's output
into the next's input, and returns a shaped result. SQLite has no
server-side procedural language, so that composition lives in your
application code rather than in a stored function. The shipped agents and
the [Domain Agent blueprints](api-agency.md#reference-blueprints-domain-agents)
are exactly this: the same kind of composition, productized. You write the
same kind of routine, for your tables and your workflow.

---

## The six building blocks

These are the C-level **Universal Agents**, callable as soon as
`.load /usr/local/lib/sqlite3/fractalsql` runs — no separate install/activation step
(they need a reasoning plugin + an
OpenAI-compatible endpoint configured per connection; see
[reasoning-setup.md](reasoning-setup.md)). Full signatures and behaviour are
in [api-agency.md → Building blocks](api-agency.md#building-blocks-the-six-universal-agents);
here is the pick-list.

| Block | Role | Use it when… |
|---|---|---|
| `fractal_search_agent` | Embed → Scout-search → synthesize an answer over retrieved rows | You want a single reasoned answer grounded in a vector corpus |
| `fractal_rag_agent` | Single-turn RAG (embed → Scout → reason) | Same as above, focused one-shot; the lighter RAG pattern |
| `fractal_sql_agent` | NL → SQL with self-correction on parse-check/exec failure | You need structured answers from tables, not vector prose |
| `fractal_agent_plan_explore` | MCTS-style diverse strategy trajectories | You need *multiple* non-overlapping plans, not one answer |
| `fractal_agent_trajectory_predict` | Forecast state by matching a drift delta-vector in history | You need "where is this heading, based on past drift?" |
| `fractal_agent_detect_loop` | DFA-based infinite-loop / repetition detector | You need a safety monitor on an autonomous agent's state log |

Underneath these, the **Discovery primitives** (`fractal_search`,
`fractal_search_explore`, `fractal_search_trajectory`, `fractal_search_telemetry`,
`fractal_optimize_portfolio`, the `fractal_dimension_*` family) are also
ordinary functions you can chain directly when a Universal Agent is more than
you need.

---

## The composition principle

A composition is a pipeline with up to four stages:

1. **Retrieve**: find the relevant rows (Scout for diversity, or a trajectory
   search for "what changed"). Either call a Discovery primitive directly or
   let `fractal_search_agent` / `fractal_rag_agent` do embed→search for you.
2. **Reason**: `fractal_reason(query, context)` over the retrieved rows'
   *content* (not their raw vectors; the Universal Agents fetch the matched
   rows' non-vector columns by `rowid` and pass that compact JSON to the LLM).
3. **Act** (optional): `fractal_sql_agent` with `auto_execute` set when
   the agent must run a query, under a guardrailed connection (below).
4. **Guard** (optional): `fractal_agent_detect_loop` on the agent's state-hash
   log, and/or `fractal_agent_outlier_intercept`-style screening of a proposed
   action against known-bad states.

Stages 1–2 are the common case (most "answer my data" agents). Add 3 when the
agent must *do* something. Add 4 any time the agent is autonomous.

---

## Worked patterns

### Pattern A — "Answer my corpus" (single-turn RAG)

The simplest useful agent, and you usually don't even need to compose it:
call the block directly:

```sql
SELECT fractal_rag_agent(
    'What does our runbook say about a node that stops heartbeating?',
    'runbook_chunks', 'emb');
```

Compose it yourself only when you want to shape the output or pre-filter the
corpus with SQL the block doesn't expose yet. In the SQLite integration that
composition is plain SQL — wrap it in a small host-language function of your
own if you want it callable by name:

```sql
-- narrow the corpus with ordinary SQL first, then reason over it
SELECT fractal_reason(
    'What does our runbook say about a node that stops heartbeating?',
    (SELECT json_group_array(json_object('title', title, 'body', body))
       FROM (SELECT title, body FROM runbook_chunks
              WHERE team = 'sre' AND updated_at > datetime('now', '-90 days')
              ORDER BY updated_at DESC LIMIT 25)));
```

### Pattern B — Self-correcting read-only analyst

`fractal_sql_agent` generates SQL and (with `auto_execute` set) runs it,
retrying on prepare-check or execution failure. Compose it when the user's
question is about *tables*, not vector prose. **Always** behind the guardrails
in [Safe Agency](#safe-agency--guardrails):

```sql
-- per-connection config: restrict the statement classes the agent may emit
SELECT fractalsql_set('text_to_sql_allowed_statements', 'select');

SELECT json_extract(agent, '$.generated_sql')   AS generated_sql,
       json_extract(agent, '$.execution_status') AS execution_status,
       json_extract(agent, '$.result_json')      AS result_json
  FROM (SELECT fractal_sql_agent(
            'total spend per category last quarter',
            '["invoices"]', 2, 1) AS agent);
```

(There are no database-level roles in SQLite; the per-connection
`fractalsql_set` above plus the authorizer hook in Safe Agency is how you
pin this down per identity, instead of attaching the setting to a role.)

The `data_analyst` agent is the productized version of this:
NL→SQL inside its own composition, with the retry loop and a reasoned summary
of the result row.

### Pattern C — Multi-step agent with a safety barrier

This is the pattern the [DevOps starter kit](starter-kits.md#agentic-kits-model-on-composed-agents)
productizes: retrieve → act → guard. SQLite has no server-side procedural
language, so this whole skeleton lives in your host language, calling the
same four primitives in the same order — the wiring is the part to copy.

The four steps in the SQLite integration, over the real surface names
(as host-language pseudo-steps, since the orchestration lives in your code):

```sql
-- 1. RETRIEVE: Scout-search the incident corpus
SELECT fractal_search_explore(note_vec, '0.5,0.5,0.5')
  FROM incident_notes WHERE incident_id = 42;

-- 2. ACT (fallback): NL->SQL over the metrics tables
SELECT fractal_sql_agent('summarize last quarter metrics', '["metrics"]', 2, 1);

-- 3. REASON over the retrieved context
SELECT fractal_reason('...',
    (SELECT json_group_array(json_object('title', title, 'body', body))
       FROM incident_notes WHERE incident_id = 42));

-- 4. GUARD: check the state-hash log for a loop (hashes as JSON/CSV array TEXT)
SELECT fractal_agent_detect_loop('[101, 102, 101, 102, 101]');
```

> The skeleton is illustrative. Your state-hash scheme is yours
> to define (SQLite has no built-in hash function — hash in your host language
> and store the value). The wiring (retrieve, fall back to `fractal_sql_agent`, reason,
> then `fractal_agent_detect_loop` on the state log) is the part to copy. The
> shipped `route_task` + `outlier_intercept` +
> `detect_loop` composition in
> `demo/demo-vertical-agentic-ops-devops.sql` is the full, runnable form.

---

## Safe Agency & Guardrails

`fractal_sql_agent` (and any composition that calls it with
`auto_execute` set) generates and executes arbitrary SQL. Treat it the way
you'd treat any NL→SQL surface:

- **Run it under a least-privilege connection.** SQLite has no roles or grants
  inside the engine: open the agent's connection against a database file (or
  `ATTACH` set) that only exposes the tables you want it to reach, and install
  a `sqlite3_set_authorizer` hook in your host application to reject anything
  beyond that.
- **Restrict the allowed statements.** The `text_to_sql_allowed_statements`
  config key gates which statement classes the agent may emit; tighten it to
  the set your workload needs (e.g. `select` only for a read-only analyst):
  `SELECT fractalsql_set('text_to_sql_allowed_statements', 'select');`
- **Prefer `auto_execute` off for exploratory use.** Let the caller
  review `generated_sql` and run it themselves. The cognition agents (e.g.
  `data_analyst`) pass it on deliberately, *inside* their own composition with
  the connection and allowlist already locked down.

For autonomous agents (Pattern C), add the **safety barriers** the DevOps
blueprint uses: `fractal_agent_detect_loop` on the state-hash log to catch
infinite loops, and an `outlier_intercept`-style screen that checks a proposed
action's state vector against known-bad state clusters before the action runs.

---

## Notes

Two issues surfaced while building these composition patterns, and apply equally to any composition you write.

- **`id_col` must be an integer key.** The table-searching agents
  (`recall_hybrid`, `recommend_diverse`, `patient_deterioration_triage`,
  `schedule_workload`, `rebalance_sibling`, `detour_classify`,
  `track_anomaly`) resolve the C code's 0-indexed row position to your named
  id column via `row_number() OVER (ORDER BY rowid) - 1` (there is no
  separate physical-row-identifier pseudo-column here — `rowid` fills that
  role). A text label column
  won't do; pass the numeric PK. See
  [api-agency.md → A note on id resolution](api-agency.md#a-note-on-id-resolution).
- **Diversify is connection-global.** `recommend_diverse` calls
  `fractal_diversify_enable()` as a connection-wide side effect so re-searches avoid
  recently-rejected items. Reset it with `fractal_diversify_disable()` when
  you're done, or call `feedback_audit`, which runs the
  whole audit cycle and self-disables.

---

## Where next

- **Full signatures and per-agent behaviour** →
  [api-agency.md](api-agency.md) (the six Universal Agents block and the
  sixteen recipes).
- **Runnable compositions to copy** → the three agentic starter kits
  ([starter-kits.md](starter-kits.md#agentic-kits-model-on-composed-agents)):
  each one's blueprint sections are the wiring, immediately followed by a
  call to the shipped `fractal_agent_*` function doing the same composition.
- **Configure the reasoning endpoint** the Universal Agents call →
  [reasoning-setup.md](reasoning-setup.md).
- **Validate your composition** against the same demo path the shipped agents
  use → `demo/demo-agents.sql`, which exercises all sixteen installable
  agents' reference compositions end to end.