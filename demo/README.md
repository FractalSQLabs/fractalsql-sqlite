<p align="center">
  <img src="../FractalSQLforSQLite.jpg" alt="FractalSQL for SQLite" width="720">
</p>

# FractalSQL demo

`demo.sql` is a runnable, five-minute walkthrough of search and
reasoning in one script: Sniper Search, Scout Discovery, and LLM
reasoning — including Scout's output feeding straight into a reasoning
call, which is the pattern the rest of the docs point at but don't show
running end to end in one place. Text-to-SQL has its own walkthrough —
see [Text-to-SQL](#text-to-sql) below.

`response-modes.sql` is a companion script for `text` / `code` / `json`
response modes — see [Response modes](#response-modes) below for why
it's a separate file from `demo.sql`.

## Prerequisites

1. **The extension is built and loaded.** If you haven't done this
   yet, start with [../docs/getting-started.md](../docs/getting-started.md).
   SQLite extensions load per connection, not once per database —
   every script below assumes you pass the `.load` line first:

   ```sh
   sqlite3 mydb.sqlite -cmd ".load ./dist/amd64/fractalsql"
   ```

2. **Reasoning is configured.** Sections 0–2 of `demo.sql` only need the
   extension itself, but sections 3–4 call `fractal_reason()`, which
   needs a working LLM endpoint. Follow
   [../docs/reasoning-setup.md](../docs/reasoning-setup.md) first —
   Ollama, AWS Bedrock, Azure OpenAI, GCP Vertex, and any OpenAI-compatible
   endpoint are all documented there. Configuration is per-connection
   `fractalsql_set()` state (SQLite has no GUCs or config file to
   reload) — the standard way to apply it every run is the
   `load_fractalsql.sql` snippet the `easy_install` wizard writes,
   passed with `-init`. Confirm it works before running this demo:

   ```sql
   SELECT fractal_reason('reply with a short confirmation that this connection works');
   ```

   If that errors, `demo.sql` will hit the same error at section 3 — fix
   it there first rather than debugging through the demo script.

## Running it

```sh
sqlite3 mydb.sqlite -cmd ".load ./dist/amd64/fractalsql" \
  -init load_fractalsql.sql ".read demo/demo.sql"
```

(Omit `-init load_fractalsql.sql` if reasoning isn't configured yet —
sections 0–2 still run.) `.timer on` is set at the top, so you'll see
how long each step takes — worth watching, since the reasoning calls
(sections 3–4) are the slow part. A cloud endpoint typically responds
in a few seconds; a local Ollama model can take much longer on a cold
load (see "Slow or constrained hardware" in `reasoning-setup.md` if a
call times out).

The script is safe to re-run: `demo_alerts`, `demo_points`, and
`demo_embeddings` are dropped and recreated at the start of their
sections every time, so there's no stale-state cleanup to do between
runs.

## What each section shows

- **0 — Sanity check.** `fractalsql_edition()` / `fractalsql_version()`
  confirm the extension is actually loaded before anything else runs.
- **1 — Setup.** A small `demo_alerts` table with a deliberate story in
  it: a login-attempt count that escalates (3 → 3 → 17) and a latency
  spike in the last ~10 minutes. Nothing here calls the LLM yet.
- **2 — Sniper Search.** `fractal_search()` converges a stored column
  toward a query vector — the fast, precise mode. `fractal_search_debug`
  exposes the tunable form if you need it; the default form here is
  fixed at the SFS engine's own defaults.
- **3 — Reasoning over real data.** `fractal_reason()` gets a real
  `context` argument this time — the alerts from the last hour,
  serialized to JSON via `json_group_array(json_object(...))` — rather
  than an empty ping. Expect the model to notice the login-attempt
  escalation and the latency spike; exact wording varies by model and
  provider.
- **4 — Scout Discovery feeding reasoning.** `fractal_search_explore()`
  is an aggregate here — scan your own embedding column and it returns
  a diversity-spread population as one JSON document, which is handed
  to `fractal_reason()` as context in the same statement. This is the
  differentiator pattern: diversity-sampled context instead of a plain
  `WHERE` filter, in one pipeline.

## Response modes

`response-modes.sql` demonstrates `FSQL_REASONING_HTTP_RESPONSE_MODE`
(`text` / `code` / `json`) — see
[docs/reasoning-setup.md](../docs/reasoning-setup.md#response-modes)
for the full explanation.

It's a **separate file from `demo.sql`**, not another section in it,
because the response mode is env-var-only and read once when the
reasoning plugin initializes — changing it needs an OS-level
environment change plus a restart of the **host process** (the
`sqlite3` CLI or your application; SQLite has no separate server to
restart, but a new `sqlite3` session does not pick up the variable
unless its own environment changed). Run it as three manual passes
instead:

1. Run `demo.sql` first if you haven't — `response-modes.sql` reuses
   its `demo_alerts` table.
2. For each mode (`text` needs no setup — it's the default):
   1. Set `FSQL_REASONING_HTTP_RESPONSE_MODE` and restart the host
      process. See "Switching modes on an already-running install" in
      [docs/reasoning-setup.md](../docs/reasoning-setup.md#response-modes)
      for the exact commands on your platform (Windows/Linux/macOS
      differ here).
   2. Run only that section's query from `response-modes.sql`:

      ```sh
      sqlite3 mydb.sqlite -cmd ".load ./dist/amd64/fractalsql" \
        -init load_fractalsql.sql ".read demo/response-modes.sql"
      ```

      — copy just that one section into a one-statement file, or paste
      it directly into the `sqlite3` shell; not the whole file at once.

What to expect: `code` mode returns a bare SQL statement with no
prose wrapper (no "Here's a query that does that:" preamble, no
visible fence markers). `json` mode returns text wrapped in the
script's own `json()` call — SQLite's JSON parser raises on malformed
input, so a successful result is proof the plugin's own extraction and
validation actually worked, not just "looks like JSON."

## Enterprise Tier — QTL & CISO Audit

`enterprise-qtl-audit.sql` exercises the enterprise-tier **Quantized Ternary
Ledger** (append-only, tamper-evident Truth/Shadow record of search/feedback
events) and **CISO audit unpack** surface. Unlike every other demo here, it
runs in **two** states:

- **Dormant (default — the enterprise core is not shipped in this repo):**
  the nine functions (eight `fractal_ledger_*` functions plus
  `fractal_audit_unpack`) are present but inactive. The demo seeds real
  engagement events with the community `fractal_feedback_report()`
  primitive, then each enterprise call fails with a clean `fractalsql:
  enterprise tier not loaded` error. SQLite has no exception handling in
  plain SQL (no `DO`/PL/pgSQL equivalent), so unlike the PostgreSQL
  edition this can't be caught and summarized in one message — every
  call below the first prints its own copy of the same error, and the
  `sqlite3` shell (per its default `.bail off`) carries on. The community
  search engine above is unaffected either way, though the process does
  exit non-zero on a dormant run — read the output, not the exit code,
  to see which path ran.
- **Active:** with the enterprise core library staged in and
  `enterprise_lib` pointed at it (a fresh connection, no reload step),
  the demo flushes the seeded ledgers to the `fractalsql_ledger` table,
  decodes the persisted QTL blob back into a CISO event log, then
  exercises `load` / `compact` / `reset_soft` / `reset_hard` end to end.

```sh
sqlite3 mydb.sqlite -cmd ".load ./dist/amd64/fractalsql" \
  -cmd "SELECT fractalsql_set('enterprise_lib', '/path/to/libfractalsql-enterprise-sovereign-c.so');" \
  ".read demo/enterprise-qtl-audit.sql"
```

Omit the `fractalsql_set` line to see the dormant path. See
[docs/enterprise.md](../docs/enterprise.md) for the full mechanism,
the function table, and the append-only chain / signature-verification
details.

### Enterprise Tier — Stress & Tamper-Evidence

`enterprise-stress.sql` is the companion to the audit demo above: it
hammers the same enterprise ledger surface under load. It fills the
in-memory Truth/Shadow ledgers to their **capacity bound** (64 each,
`FSQL_TRUTH/SHADOW_DEFAULT_CAP` — 128 events total with disjoint doc_ids),
round-trips them through the QTL encode → `fractalsql_ledger` table →
decode path, churns 5 flush/load cycles at capacity, and probes
**tamper-evidence** in two layers: structurally (Phase C — truncating the
persisted QTL blob below its 24-byte header, rejected as
`FSQL_ELEDGER_INTEGRITY`) and cryptographically (Phase D — setting
`enterprise_ledger_key` to HMAC-SHA256-tag the payload and flipping a
middle byte the structural check cannot see, rejected by the MAC on
load), then walks the append-only chain in Phase E (`fractal_ledger_verify()`
catching a middle-row tamper that `load()`'s O(1) tip-only check cannot
see). Same dual-state shape as the audit demo — dormant on the community
build, active with a licensed enterprise core.

> **Scope note:** by default (`enterprise_ledger_key` unset) the QTL
> format carries no MAC, so the tamper-evidence in Phase C is
> **structural only** (truncation / count-length mismatch). A targeted
> payload byte-flip (e.g. changing a stored `doc_id`) is **not** detected
> by the structural check. **Phase D** sets `enterprise_ledger_key` (a
> plain `fractalsql_set()` string key, settable per connection) to add an
> **HMAC-SHA256 envelope**: every flush tags the persisted payload and
> every load verifies the tag before the core decodes, so that same
> byte-flip **is** detected. The MAC lives in the open extension at the
> storage seam — the enterprise core is unchanged and is never handed
> tampered bytes.
>
> **Concurrency / cross-session** coverage (parallel last-writer-wins
> flush, and load-in-a-fresh-connection) is exercised by `build_test`
> **gate 25** (`gate_25_enterprise_stress`), which drives a real
> enterprise core through Python's `sqlite3` stdlib — not something a
> single `.read` script can do without a scripting language's control
> flow. This demo's own invariant checks (e.g. "expect truth=64
> shadow=64") are informational, not enforced: SQLite has no
> `IF`/`RAISE EXCEPTION` in plain SQL to assert them, so on the active
> path you confirm them by eye against what's printed.

```sh
sqlite3 mydb.sqlite -cmd ".load ./dist/amd64/fractalsql" \
  -cmd "SELECT fractalsql_set('enterprise_lib', '/path/to/libfractalsql-enterprise-sovereign-c.so');" \
  ".read demo/enterprise-stress.sql"
```

## Text-to-SQL

`demo-text-to-sql.sql` walks through `fractal_text_to_sql()` against
a richer three-table schema with real foreign keys (`customers` ->
`orders` -> `order_items`) — single-table questions, a question
requiring a join, and a question requiring all three tables, plus
capturing and running a generated statement yourself via the CLI's
`.once`/`.read` spool trick (there's no `\gset` here). Unlike the PG
edition, `fractal_text_to_sql(question)` takes only the question — there
is no `text[]` scoping argument (SQLite has no array type); scoping the
LLM's view is `fractal_sql_agent`'s job instead
(`fractal_sql_agent(question, '["orders", "customers"]')`), and plain
`fractal_text_to_sql()` always auto-discovers the whole database — audit
that discovery with `fractal_schema_context()` (no arguments; walks
`sqlite_master`). Same prerequisites as `demo.sql` (extension loaded,
reasoning configured). Full pipeline explanation and the config-key
reference are in
[docs/text-to-sql-setup.md](../docs/text-to-sql-setup.md).

```sh
sqlite3 mydb.sqlite -cmd ".load ./dist/amd64/fractalsql" \
  -init load_fractalsql.sql ".read demo/demo-text-to-sql.sql"
```

`demo/text-to-sql-spike-*.sql` are earlier, throwaway hand-rolled
scripts from before this function existed (single-table, no FKs,
driving `fractal_reason()` directly to validate the approach) — kept
for history, not the recommended starting point.

## Industry vertical demos

Eleven runnable walkthroughs — eight **industry verticals** and three
**agentic verticals** — each with its own synthetic dataset and its own
subset of the function surface chosen for genuine domain fit, not forced
coverage. Every one ends with a `fractal_reason()` narrative call over
real computed results, same closing pattern as `demo.sql`. Same
prerequisites as `demo.sql` (extension loaded; the final reasoning
section in each needs [reasoning configured](../docs/reasoning-setup.md)
— every earlier section runs without it). All eleven are also wired
into the Docker demo — see [the Learning Path](../docs/docker-demo.md#the-learning-path).
Four (MedTech, Maritime, Fleet, Cybersecurity) store their vector
columns as the native **`fractal_vector`** BLOB type instead of
CSV-TEXT — see
[demo-fractal-vector.sql](demo-fractal-vector.sql) and
[docs/vectorizer-setup.md](../docs/vectorizer-setup.md#storage-csv-text-vs-the-fractal_vector-blob)
for the type itself. SQLite has no typmod, so unlike PG's
`fractal_vector(n)` column declaration, dimension enforcement here is a
`CHECK (fractal_vector_dims(col) = n)` constraint on the column instead.

```sh
sqlite3 mydb.sqlite -cmd ".load ./dist/amd64/fractalsql" \
  -init load_fractalsql.sql ".read demo/demo-vertical-quant-finance.sql"
```

- **[demo-vertical-quant-finance.sql](demo-vertical-quant-finance.sql)** —
  Quantitative Finance & Algorithmic Trading. A 25-asset factor-model
  portfolio (`fractal_optimize_portfolio` picks the best 8) and a
  300-point price series with a deliberate volatility regime change at
  t=150 (`fractal_dimension_dfa`/`fractal_dimension_drift`).
  `fractal_search_trajectory` finds which of 10 historical quarterly
  rebalances the new allocation most resembles.
- **[demo-vertical-medtech-clinical.sql](demo-vertical-medtech-clinical.sql)** —
  MedTech, Clinical Telemetry & Patient Monitoring. 40 synthetic
  patients, `vitals` stored as **`fractal_vector`** (dims=5, not
  CSV-TEXT) — a fixed five-field clinical vector where dimension-drift
  protection actually matters: `fractal_hybrid_clinical_search` over an
  age/condition cohort computed with ordinary SQL, `fractal_search_
  trajectory` for a patient's current vitals vs. their own admission
  baseline (the exact example in that function's own doc comment, using
  the `fractal_vector` overload directly), plus all four domain-
  geometry functions (`fractal_vascular_network`,
  `fractal_cortical_folding`, `fractal_nerve_plexus_metric`) on small,
  pre-extracted geometric fixtures — a vessel graph, a reference unit-
  cube mesh, a nerve fiber skeleton.
- **[demo-vertical-recommendation-search.sql](demo-vertical-recommendation-search.sql)** —
  Advanced Recommendation, Search & Discovery Engines. A 300-item, 6-genre
  catalog for diverse "you might also like" discovery
  (`fractal_search_explore`), table-backed top-k
  (`fractal_search_telemetry`), and the **full stateful-diversity
  loop**: enable Diversify, search, report negative feedback on the
  top result, re-search the same query, confirm it's now avoided — the
  real differentiator over plain top-K or MMR, neither of which is
  stateful across searches. Also covers `fractal_cross_modal_search`
  (content + behavior vectors, weighted).
- **[demo-vertical-sovereign-edge-ai.sql](demo-vertical-sovereign-edge-ai.sql)** —
  Sovereign, Edge & Autonomous Systems AI. FractalSQL's whole story fits
  this vertical natively — search, reasoning, and optimization all run
  as pure C inside the same process as SQLite itself, no external
  vector-DB service required. A 50-node edge-compute fleet: Sniper
  Search for an ideal node profile, Scout Discovery for diverse fleet
  profiles, `fractal_dimension_boxcount` over a facility deployment
  grid, and `fractal_optimize_portfolio` repurposed as a general
  on-device black-box resource allocator (picking 6-of-50 nodes for a
  distributed job under contention risk).
- **[demo-vertical-maritime-defense.sql](demo-vertical-maritime-defense.sql)** —
  Maritime, Aviation & Defense (AIS & Radar Tracking). 30 synthetic AIS
  vessel tracks (`baseline`/`current` stored as **`fractal_vector`**,
  dims=4 — a fixed track-state vector), one given a deliberate course
  deviation. `fractal_search_trajectory` on the current-vs-baseline
  track delta (a direct fit for "what changed" deviation detection, via
  the `fractal_vector` overload), nearest-track/diverse-track
  clustering across the fleet, and `fractal_dimension_dfa` on
  heading-change series to separate smooth transit from erratic
  maneuvering.
- **[demo-vertical-fleet-logistics.sql](demo-vertical-fleet-logistics.sql)** —
  Autonomous Fleet Management & Last-Mile Delivery. A 40-vehicle
  delivery fleet (`baseline`/`current` stored as **`fractal_vector`**,
  dims=4), one running a deliberate detour. Diverse route/zone
  clustering for depot coverage, a cohort-restricted search ("today's
  route-3 vehicles only" — the same cohort-then-search composition
  `fractal_hybrid_clinical_search` uses, built here with an ordinary
  filtered temp table instead of that clinically-named function),
  detour detection via `fractal_search_trajectory` (`fractal_vector`
  overload), and GPS-trace complexity via `fractal_dimension_boxcount`.
- **[demo-vertical-smart-cities-iot.sql](demo-vertical-smart-cities-iot.sql)** —
  Smart Cities & IoT Sensor Grids. A 400-sensor city grid
  (traffic/air-quality/noise): spatial coverage diagnostics
  (`fractal_dimension_boxcount`/`fractal_morphological_complexity`),
  an air-quality event detected via `fractal_dimension_dfa`/
  `fractal_dimension_drift` on a sensor series with a deliberate
  regime shift, and diverse representative-zone sampling via Scout
  Discovery.
- **[demo-vertical-cybersecurity-threat-detection.sql](demo-vertical-cybersecurity-threat-detection.sql)** —
  Cybersecurity & Threat Detection (network behavior analytics). A
  35-host fleet across three zones (`baseline`/`current` stored as
  **`fractal_vector`**, dims=4), one host showing a stealthy compromise
  pattern — outbound connections, destination ports, and DNS query
  volume all spike while failed-auth stays flat, not a brute-force
  signature. Diverse traffic-profile clustering for threat hunting
  (`fractal_search_explore`), a zone-restricted search ("DMZ hosts
  only" — the same cohort-then-search composition
  `fractal_hybrid_clinical_search` uses), compromise detection via
  `fractal_search_trajectory` (`fractal_vector` overload), and
  connection-rate regime-change detection via `fractal_dimension_dfa`/
  `fractal_dimension_drift` on a beaconing-onset series.

### Agentic verticals (Universal Agent composition)

The three agentic verticals exercise the six C-level **Universal Agents**
composed into **Domain Agents** — see
[docs/api-agency.md](../docs/api-agency.md) for the composition pattern.
Unlike the domain verticals above, every section here needs reasoning
configured (the agents call `fractal_reason`/`fractal_embed`), and each
is a clean, re-runnable regression test of a recently-fixed agent code
path — nothing commented out, no skip-wrappers (SQLite has no
PL/pgSQL, so there's no `DO`/`EXCEPTION` block to skip with; a call
without reasoning configured just errors with the clean "reasoning
plugin not configured" hint and the shell moves on).

- **[demo-vertical-agentic-ops-devops.sql](demo-vertical-agentic-ops-devops.sql)** —
  DevOps/SRE: Autonomous Incident Triage & Self-Healing. The
  embed-coupled agents on a vectorized `incident_logs` corpus:
  `fractal_search_agent` and `fractal_rag_agent` (retrieve-then-reason),
  both gated on the reasoning plugin — a clean hint without one, and the
  analytic sections still run either way — `fractal_agent_detect_loop`
  on a period-2 state-hash toggle (the short-period check flags it even
  though its DFA alpha is only ~0.04), `fractal_dimension_drift` over a
  non-degenerate latency series, plus `fractal_agent_route_task` and
  `fractal_agent_outlier_intercept` Domain Agent compositions.
- **[demo-vertical-agentic-fintech-mcts.sql](demo-vertical-agentic-fintech-mcts.sql)** —
  FinTech: Scenario Exploration & Safe Execution. `fractal_agent_plan_explore`
  embeds a seed state and Scout-searches a vectorized `trade_strategies`
  corpus (reasoning-plugin gated, like every cognition agent),
  `fractal_sql_agent` with `auto_execute => true` running the
  model-generated SQL in-process (a thrown execution error is captured
  into `execution_status='execution_failed'` rather than propagated to
  abort the call), and `fractal_optimize_portfolio` rebalancing.
- **[demo-vertical-agentic-customer-support.sql](demo-vertical-agentic-customer-support.sql)** —
  Customer Support: Stateful Session & Churn Drift.
  `fractal_agent_trajectory_predict` reads the baseline vector (by rowid)
  and the latest vector (max rowid) from a `state_vector` column, derives
  the dimension from the data, and computes a real delta — the column
  holds CSV/JSON vector text, since SQLite has no `float8[]` — plus
  `fractal_agent_recall_hybrid`, `fractal_agent_recommend_diverse`, and
  the `fractal_diversify_enable` stateful-diversity loop.

**A note on `fractal_dimension_boxcount`/`fractal_morphological_complexity`
fixture design**, visible across several of the scripts above: both
functions need enough *space-filling* points (a grid, a path, a real
geometric structure) for their internal box-counting estimator to find
>= 3 valid eps-octaves — its own documented validity filter. A sparse
or purely random scatter of points, even well past the 8-point
minimum, typically fails this and returns an error rather than a wrong
number. Every fixture above was chosen and verified against a live
instance with that requirement in mind.

## The sixteen agents

`demo-agents.sql` validates the sixteen installable agents. Unlike
PostgreSQL, where these ship in an optional `fractalsql_agents`
dependent extension, `src/fsql_domain_agents.c` registers all sixteen
as plain C SQL functions in this same extension DLL, next to the six
Universal Agents, the reasoning core, and the search core — no separate
install step. Load the extension once and all sixteen are already there
(see
[docs/api-agency.md](../docs/api-agency.md#which-agent-should-i-use)).
The demo exercises all sixteen end to end:

- **`fractal_agent_anomaly_triage`** — over a drifting latency series (real
  `fractal_dimension_drift` → real `fractal_reason`).
- **`fractal_agent_allocate`** — on a real `mu`/`cov` (real
  `fractal_optimize_portfolio` → real `fractal_reason`).
- **`fractal_agent_route_task`** — matches a task embedding to the nearest
  capability row (real `fractal_search_telemetry` → real `fractal_reason`).
- **`fractal_agent_outlier_intercept`** — screens a state vector against known
  bad states and compares the real nearest-distance to a threshold (real
  `fractal_search_telemetry` → real `fractal_reason`).
- **`fractal_agent_recall_hybrid`** — vector recall restricted by a metadata
  cohort (real `fractal_hybrid_clinical_search`); pure retrieval, no LLM step.
- **`fractal_agent_recommend_diverse`** — repulsion-diverse top-k over a catalog
  (real `fractal_diversify_enable` + real `fractal_search_telemetry`); pure
  retrieval, no LLM step.
- **`fractal_agent_data_analyst`** — a natural-language question over your
  tables (real `fractal_sql_agent` with `auto_execute => true` → real
  `fractal_reason`); the horizontal catch-all with no vertical preset.
- **`fractal_agent_patient_deterioration_triage`** — cohort-restricted
  nearest patient + baseline→current drift (real
  `fractal_hybrid_clinical_search` + real `fractal_search_trajectory` → real
  `fractal_reason`); the cohort is caller-built so `age>65 AND
  condition='sepsis'` composes in ordinary SQL.
- **`fractal_agent_feedback_audit`** — a self-contained diversify/repulsion
  audit cycle (real `fractal_detect_collapse` + real `fractal_explain_result`);
  pure analytics, **no LLM**, self-disables diversify.
- **`fractal_agent_schedule_workload`** — refines a task vector then finds
  the nearest node (real `fractal_search` + real `fractal_search_telemetry` →
  real `fractal_reason`).
- **`fractal_agent_rebalance_sibling`** — optimized book vs nearest
  historical allocation (real `fractal_optimize_portfolio` + real
  `fractal_search_trajectory` → real `fractal_reason`).
- **`fractal_agent_diverse_portfolios`** — enterprise tier; companion to
  `fractal_agent_allocate` returning several structurally distinct good
  portfolios instead of one (real `fractal_optimize_portfolio_multimodal` →
  real `fractal_reason`); dormant on the community build — the call errors
  with the clean "enterprise tier not loaded" hint and `demo-agents.sql`
  carries on to the next section.
- **`fractal_agent_detour_classify`** — route deviation + GPS-trace
  complexity (real `fractal_search_trajectory` + real
  `fractal_dimension_boxcount` → real `fractal_reason`).
- **`fractal_agent_track_anomaly`** — track deviation + heading DFA (real
  `fractal_search_trajectory` + real `fractal_dimension_dfa` → real
  `fractal_reason`).
- **`fractal_agent_network_coverage_alert`** — sensor-grid morphology +
  telemetry drift (real `fractal_morphological_complexity` + real
  `fractal_dimension_drift` → real `fractal_reason`); 20×20 grid (400 pts).
- **`fractal_agent_regime_triage`** — single-series regime change (real
  `fractal_dimension_dfa` + real `fractal_dimension_drift` → real
  `fractal_reason`).

Thirteen agents are cognition (end in `fractal_reason`); three are pure
retrieval/analytics with no endpoint needed (`recall_hybrid`,
`recommend_diverse`, `feedback_audit`). The script closes with
a `fractal_reason()` narrative over the computed results — same closing
pattern as every other demo.

**Prerequisites:** just the base extension and reasoning (same as
`demo.sql`) — there's no second extension to load:

```sh
sqlite3 mydb.sqlite -cmd ".load ./dist/amd64/fractalsql" \
  -init load_fractalsql.sql ".read demo/demo-agents.sql"
```

The script is safe to re-run: `agents_demo_logs` and the agent fixture
tables (`agents_demo_caps`, `agents_demo_badstates`, `agents_demo_mem`,
`agents_demo_catalog`, `agents_demo_data`, `agents_demo_patients`,
`agents_demo_fcatalog`/`agents_demo_fwarmup`, `agents_demo_nodes`,
`agents_demo_alloc`, `agents_demo_vehicles`, `agents_demo_tracks`) are
dropped and recreated at the top of their sections. The eight
non-agentic vertical demos (`demo-vertical-quant-finance.sql`,
`demo-vertical-medtech-clinical.sql`, `demo-vertical-recommendation-search.sql`,
`demo-vertical-sovereign-edge-ai.sql`, `demo-vertical-maritime-defense.sql`,
`demo-vertical-fleet-logistics.sql`, `demo-vertical-smart-cities-iot.sql`,
`demo-vertical-cybersecurity-threat-detection.sql`) are likewise now **presets** —
each rewired section keeps its raw-primitive call as a commented blueprint
above the shipped agent call that generalizes it (the 3 agentic vertical
reference blueprints — `demo-vertical-agentic-ops-devops.sql`,
`demo-vertical-agentic-fintech-mcts.sql`, `demo-vertical-agentic-customer-support.sql` —
stay untouched).
The agents are ordinary functions in the loaded extension, so there's
nothing separate to drop — dropping the demo tables (see
[Cleanup](#cleanup)) is all the teardown there is.

## Full API benchmark

`benchmark-api-reference.sql` is a `.timer on` pass exercising the
callable functions documented in `sql/fractalsql--1.0.sql`, grouped by
category, against small generated fixtures — a correctness-plus-latency
smoke pass over the whole API surface, distinct from
[`benchmark.sql`](benchmark.sql)'s narrower Sniper-Search/Scout-
Discovery/vectorizer-throughput comparison (which stays scoped to that,
see its own header comment). SQLite has no PL/pgSQL, so there is no
`bmk_safe_call()`-style wrapper function: reasoning-dependent calls
(`fractal_reason`, `fractal_text_to_sql`, `fractal_embed`, and the agent
family) are expected to fail here without a configured plugin, with the
clean "reasoning plugin not configured" hint — the `sqlite3` shell
continues past each error and prints its own `-- <name> skipped: <error>`
marker row instead of aborting the rest of the benchmark.

```sh
sqlite3 mydb.sqlite -cmd ".load ./dist/amd64/fractalsql" \
  -init load_fractalsql.sql ".read demo/benchmark-api-reference.sql"
```

## Cleanup

The demo tables are left in place after running so you can poke at the
results. SQLite's `DROP TABLE` takes exactly one table per statement
(no `DROP TABLE a, b;`), so drop them one at a time when you're done:

```sql
DROP TABLE demo_alerts; DROP TABLE demo_points; DROP TABLE demo_embeddings;
DROP TABLE order_items; DROP TABLE orders; DROP TABLE customers; DROP TABLE comments;             -- demo-text-to-sql.sql
DROP TABLE bi_customer_features; DROP TABLE bi_orders; DROP TABLE bi_customers; DROP TABLE bi_archetypes;  -- demo-business-intelligence.sql
DROP TABLE spike_candidates; DROP TABLE spike_negative_control;                                    -- text-to-sql-spike-*.sql
DROP TABLE bt_bench_clusters; DROP TABLE bt_bench_corpus; DROP TABLE bt_bench_docs;                 -- benchmark.sql
DROP TABLE vqf_assets; DROP TABLE vqf_loadings; DROP TABLE vqf_allocation_snapshots;                -- demo-vertical-quant-finance.sql
DROP TABLE vmc_patients;                                                                            -- demo-vertical-medtech-clinical.sql
DROP TABLE vrs_genres; DROP TABLE vrs_catalog; DROP TABLE vrs_modal_items;                          -- demo-vertical-recommendation-search.sql
DROP TABLE vse_nodes; DROP TABLE vse_throughput;                                                    -- demo-vertical-sovereign-edge-ai.sql
DROP TABLE vmd_vessels;                                                                             -- demo-vertical-maritime-defense.sql
DROP TABLE vfl_vehicles;                                                                            -- demo-vertical-fleet-logistics.sql
DROP TABLE vsc_sensors;                                                                             -- demo-vertical-smart-cities-iot.sql
DROP TABLE vcy_hosts;                                                                               -- demo-vertical-cybersecurity-threat-detection.sql
DROP TABLE incident_logs; DROP TABLE agent_capabilities; DROP TABLE known_bad_states;               -- demo-vertical-agentic-ops-devops.sql
DROP TABLE trade_strategies; DROP TABLE portfolios; DROP TABLE assets;
DROP TABLE restrictions; DROP TABLE historical_allocations;                                        -- demo-vertical-agentic-fintech-mcts.sql
DROP TABLE customer_sessions; DROP TABLE customer_playbook; DROP TABLE product_catalog;             -- demo-vertical-agentic-customer-support.sql
DROP TABLE bmk_corpus; DROP TABLE bmk_docs; DROP TABLE bmk_modal;                                   -- benchmark-api-reference.sql
DROP TABLE agents_demo_logs; DROP TABLE agents_demo_caps; DROP TABLE agents_demo_badstates;
DROP TABLE agents_demo_mem; DROP TABLE agents_demo_catalog; DROP TABLE agents_demo_data;
DROP TABLE agents_demo_patients; DROP TABLE agents_demo_fcatalog; DROP TABLE agents_demo_fwarmup;
DROP TABLE agents_demo_nodes; DROP TABLE agents_demo_alloc; DROP TABLE agents_demo_vehicles;
DROP TABLE agents_demo_tracks;                                                                      -- demo-agents.sql
```

`demo-vectorizer.sql` and `demo-fractal-vector.sql` each tear themselves
down at the top of every re-run and print their own one-line cleanup
recipe at the end (`fractal_vectorizer_drop()` + `DROP TABLE`, since
their vectorizer registry/queue are TEMP objects private to the
connection that created them) — see each file's own closing `.print`
block rather than duplicating that here.

## Troubleshooting

- **Section 0 fails** — the extension isn't built/loaded for this
  connection. See [../docs/getting-started.md](../docs/getting-started.md).
- **Section 3 or 4 fails** — reasoning isn't configured, or the endpoint
  is unreachable/misconfigured. See the Troubleshooting section in
  [../docs/reasoning-setup.md](../docs/reasoning-setup.md) — it covers
  the specific error strings you'll see ("reasoning plugin not
  configured", HTTP 401, timeout, non-2xx response) and what each one
  means.
- **The reasoning response reads oddly** (e.g. the model asks for data
  instead of describing it) — check that the `context` subquery in that
  section actually returned rows. An empty or NULL context still gets
  sent as `'{}'`, and the model's default system prompt explicitly
  expects "database search results" to analyze; with nothing there, it
  will say so rather than hallucinate an answer.
