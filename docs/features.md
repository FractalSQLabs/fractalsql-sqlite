<p align="center">
  <img src="../FractalSQLforSQLite.jpg" alt="FractalSQL for SQLite" width="720">
</p>

# FractalSQL Feature Specification

FractalSQL is a tiered capability framework that runs discovery, reasoning, and agentic workflows inside your SQLite process: no external RAG middleware shuffling data between the database and the LLM. It provides a progression from basic vector discovery to autonomous agentic reasoning.

---

## 🏗️ Capability Tiering Model

FractalSQL ships in two editions, each unlocking more of the four capability tiers described below (Discovery → Cognition → Agency → Analytics). The editions are a *build/core* axis; the capability tiers are a *functional* axis. A single install belongs to one edition and exposes whichever capability tiers that edition includes.

| Tier | Focus | Key Capabilities | Build / Requirement |
| --- | --- | --- | --- |
| **Community (Sovereign)** | Discovery, Cognition, Agency | SFS Core, Sniper Search, Scout Discovery, In-DB Reasoning, Embeddings, the agents, vectorizer, ledger | One loadable extension statically linked against the `libfractalsql-community-sovereign-c.a` core — everything most installs need |
| **Community (Minimal)** | Discovery | SFS Core, Sniper Search | Same extension linked against the minimal core (`libfractalsql-community-minimal-c.a`); the sovereign-only translation units are compiled out, so sovereign-only names surface as clean "no such function" errors |

*SQLite difference:* the separately-gated Enterprise tier has the same shape here as elsewhere — the ledger/audit and multimodal-portfolio core symbols are absent from the community sovereign archive, so the enterprise core is resolved at call time from the `enterprise_lib` config key (see [Enterprise Tier](enterprise.md)). Everything in the table above needs only the community build.

---

## 🔍 Tier 1: Discovery

The foundation of FractalSQL is the **Stochastic Fractal Search (SFS)** engine, which treats vector search as a continuous optimization problem rather than an index lookup like standard HNSW or IVFFlat.

### Sniper Search (`fractal_search`)
Pure SFS convergence to the single best point minimizing cosine distance to a query over a unit box. It is a "precision" tool for finding the absolute global minimum. A per-row scalar: `fractal_search(vector_column, 'query-as-CSV')` in an `ORDER BY ... LIMIT k`.

### Scout Discovery (`fractal_search_explore`)
Scans a stored corpus and returns a diverse population of results: an SFS population search blended with **Maximal Marginal Relevance (MMR)** re-ranking, so the results cover the data's distinct basins of attraction instead of the "mode collapse" common in top-K search. An aggregate here — `SELECT fractal_search_explore(emb, 'query') FROM corpus` — folding the population into one JSON result (rather than returning one row per matched vector, as a set-returning function would).

### Table-Backed Telemetry (`fractal_search_telemetry`)
A deterministic primitive that returns the $K$ nearest real table rows to a query. This is the ground-truth layer used by all higher-order agentic functions.

---

## 🧠 Tier 2: Cognition

The Cognition tier adds a reasoning bridge to the SFS core, allowing it to call LLMs and embedding models via a pluggable C provider interface. This enables reasoning to happen *beside* the data.

### In-Database Reasoning (`fractal_reason`)
Dispatches a query and a context payload to a configured LLM provider. Because it runs inside the backend, you can feed it the results of a Scout search or a SQL query in one statement. 

**Provider-agnostic**: the same `fractal_reason()` call works against **AWS Bedrock (SigV4)**, **Azure OpenAI**, **GCP Vertex AI**, or **local Ollama**. Switch providers via config without changing a single line of SQL. Local providers keep data on your own infrastructure; cloud providers send it to that provider under your own account and agreement (BAA-covered where your compliance posture requires it).

### Semantic Embeddings (`fractal_embed`)
Generates vectors from text using a purpose-trained embedding model. This removes the need for an external embedding pipeline for many RAG use cases.

### Safe Text-to-SQL (`fractal_text_to_sql`)
Generates SQL from natural language. It uses a three-stage safety pipeline:
1. **Parse-Check**: Validates statement shape (e.g., no DDL) — a raw-text first-keyword screen plus `sqlite3_prepare_v2` (parse only, never executes).
2. **Allowlist**: Ensures the statement type is permitted (e.g., `SELECT` only) via `sqlite3_stmt_readonly()` — data-modifying CTEs report read/write on SQLite >= 3.35, and `EXPLAIN` is rejected outright via `sqlite3_stmt_isexplain`.
3. **Mechanical Check**: preparing the statement *is* the mechanical check — SQLite has no planner to consult without executing, so a separate planner-validation pass run inside a throwaway subtransaction has no counterpart here.

---

## 🤖 Tier 3: Agency

The Agency tier composes the Discovery and Cognition primitives into autonomous routines: 16 installable agents, each a productized recipe for a recurring pattern, built on 6 reusable Universal Agent primitives you can also call directly. *SQLite difference:* elsewhere these 16 ship as a second, optional install/activation step written in a server-side procedural language; here, SQLite has neither a server-side procedural language nor a second extension artifact, so they register as plain C SQL functions in this same `.so`, always present once it loads — no separate install step. See [`docs/api-agency.md`](api-agency.md) for the full argument reference, examples, and notes.

### Agents

| Agent | Recipe | Reasoning |
| --- | --- | --- |
| `fractal_agent_anomaly_triage` | drift exponent on one entity's series → reasoning triage | ✓ |
| `fractal_agent_regime_triage` | DFA + drift over one series → reasoning triage | ✓ |
| `fractal_agent_track_anomaly` | trajectory deviation + heading DFA → reasoning triage | ✓ |
| `fractal_agent_detour_classify` | trajectory deviation + box-counting → reasoning classify | ✓ |
| `fractal_agent_network_coverage_alert` | spatial morphology + telemetry drift → reasoning alert | ✓ |
| `fractal_agent_allocate` | SFS Sharpe optimizer → reasoning rationale | ✓ |
| `fractal_agent_rebalance_sibling` | optimizer + trajectory search → reasoning rationale | ✓ |
| `fractal_agent_diverse_portfolios` (enterprise) | multimodal optimizer → reasoning tradeoff summary | ✓ |
| `fractal_agent_route_task` | nearest-capability search + budget accounting → reasoning rationale | ✓ |
| `fractal_agent_schedule_workload` | `fractal_search_debug` refine + nearest node → reasoning rationale | ✓ |
| `fractal_agent_outlier_intercept` | distance-to-bad-state safety barrier → reasoning justification | ✓ |
| `fractal_agent_patient_deterioration_triage` | cohort search + trajectory drift → reasoning triage | ✓ |
| `fractal_agent_data_analyst` | NL → SQL → execute → reasoning analysis | ✓ |
| `fractal_agent_recall_hybrid` | cohort-restricted vector recall | — |
| `fractal_agent_recommend_diverse` | repulsion-diverse top-k | — |
| `fractal_agent_feedback_audit` | diversify loop + collapse detection | — |

### Universal Agents

The six building blocks the agents above compose. Call them directly to build your own recipe.

| Function | What it does |
| --- | --- |
| `fractal_search_agent` | Embed a query, Scout-search a table, and reason over the matched rows. |
| `fractal_rag_agent` | Focused single-turn RAG: embed, Scout-search, and reason over the result. |
| `fractal_sql_agent` | Self-correcting NL-to-SQL, retrying on parse/execution failure. |
| `fractal_agent_plan_explore` | MCTS-style exploration of multiple non-overlapping strategy trajectories. |
| `fractal_agent_trajectory_predict` | Forecasts future state from a delta against historical telemetry. |
| `fractal_agent_detect_loop` | Flags infinite/repetitive agent loops via a DFA scaling exponent. |

### Safe Agency & Guardrails

To prevent "hallucination-driven" database corruption, the Agent Tier implements two primary guardrails:

1. **The Execution Barrier**: Functions like `fractal_sql_agent` with `auto_execute` on run generated SQL inside a guarded execution. If a constraint is violated or an error occurs, the failure is contained to the agent's attempt, the error is fed back to the LLM for a retry, and the main session remains intact.
2. **The Deterministic Allowlist**: The `text_to_sql_allowed_statements` config key (`SELECT fractalsql_set('text_to_sql_allowed_statements', 'select');`) strictly limits the types of SQL the agent can generate (e.g., preventing `DROP TABLE` even if the LLM suggests it).

---

## 📐 Tier 4: Analytics

The final tier provides mathematical primitives for analyzing the "shape" of data and state, turning raw vectors into actionable structural insights.

### Fractal Dimension Analysis
- **DFA (`fractal_dimension_dfa`)**: Analyzes the scaling exponent of a time series to distinguish between noise, random walks, and structured signals.
- **Box-Counting (`fractal_dimension_boxcount`)**: Measures the Minkowski-Bouligand dimension of a point cloud to evaluate spatial complexity.
- **Drift (`fractal_dimension_drift`)**: Detects regime changes by comparing the DFA exponent of a recent window against a baseline.

### Domain-Specific Geometry
FractalSQL provides optimized routines for pre-extracted biological and technical geometry:
- **Vascular Networks**: Tortuosity and branch-density for vessel graphs.
- **Cortical Folding**: Gyrification Index for brain-surface meshes.
- **Nerve Plexus**: Density and dimension for fiber skeletons.
- **Morphological Complexity**: Combined box-counting and lacunarity for segmented masks.

### Portfolio Optimization
`fractal_optimize_portfolio` uses the SFS engine to solve cardinality-constrained Sharpe-ratio maximization. It finds the best $K$ assets in a large universe without the exponential cost of a brute-force search.

---

## 📈 Benchmarks & Scaling

### sqlite-vec vs. Scout Discovery
In a benchmark of 100k vectors across 50 Gaussian clusters, measured directly against current Scout (see `bench/README.md` for the full methodology and how to reproduce it):
- **sqlite-vec** (`vec0`, exact brute-force KNN, top-50 — not an approximate index like HNSW; see `bench/README.md` for why) typically discovered **1 cluster**, averaging ~381ms per query at this scale.
- **Scout** (pop=50) typically discovered **6-9 clusters** (measured average 6.2), averaging ~2017ms per query, roughly **5x slower** than sqlite-vec at this scale.

That tradeoff is the whole point of Scout Mode, not a hidden cost: it's $O(N \times d)$ (linear scan) by design, and it's the only way here to guarantee your LLM receives a genuinely diverse set of perspectives rather than a single collapsed cluster. It is not a drop-in replacement for sqlite-vec's exact top-k. Use it where diversity matters more than latency (e.g. curated sub-corpora, not full-corpus top-k at scale).

### Storage: TEXT vs the `fractal_vector` BLOB
Storing vectors as the canonical `fractal_vector` BLOB (u16 dim LE + u16 reserved + float32 payload) gives close to a **~2x** speedup over CSV-TEXT vectors for small embeddings: the BLOB path runs the float32 math directly off the payload, while TEXT rows pay a string parse per row. The realized gap depends on how wide and how numerous your vectors are; measure on your own data before treating either number as a promise (see `bench/README.md`'s `fractal_vector vs float8[]` section — the benchmark harness itself has not yet been adapted to this integration and still targets the other database directly).

---

## 📚 API Reference

(Detailed argument tables, defaults, and ranges are available in the **[Detailed API Reference](api-discovery.md)**.)

**Discovery**
- `fractal_search(vector, query)`: Sniper Mode convergence. $\rightarrow$ **[api-discovery.md](api-discovery.md)**
- `fractal_search_explore(emb, query, params?)`: Scout Mode diverse exploration (aggregate). $\rightarrow$ **[api-discovery.md](api-discovery.md)**
- `fractal_search_telemetry(table, col, query, k)`: Ground-truth row retrieval. $\rightarrow$ **[api-discovery.md](api-discovery.md)**

**Cognition**
- `fractal_reason(query, context)`: LLM dispatch. $\rightarrow$ **[api-cognition.md](api-cognition.md)**
- `fractal_embed(input)`: Semantic vector generation. $\rightarrow$ **[api-cognition.md](api-cognition.md)**
- `fractal_text_to_sql(question)`: Safe SQL generation. $\rightarrow$ **[api-cognition.md](api-cognition.md)**

**Agency**
- `fractal_agent_data_analyst(...)`: NL question over tables + reasoned summary. $\rightarrow$ **[api-agency.md](api-agency.md)**
- `fractal_agent_route_task(...)`: Sub-agent dispatch. $\rightarrow$ **[api-agency.md](api-agency.md)**
- `fractal_agent_regime_triage(...)` / `_anomaly_triage(...)`: Drift/regime detection. $\rightarrow$ **[api-agency.md](api-agency.md)**
- `fractal_agent_recommend_diverse(...)` / `_recall_hybrid(...)`: Diverse/cohort-restricted retrieval. $\rightarrow$ **[api-agency.md](api-agency.md)**
- 10 more, full list $\rightarrow$ **[api-agency.md](api-agency.md#which-agent-should-i-use)**

**Analytics**
- `fractal_dimension_dfa(series)`: DFA scaling exponent. $\rightarrow$ **[api-analytics.md](api-analytics.md)**
- `fractal_dimension_boxcount(points, dim)`: Box-counting dimension. $\rightarrow$ **[api-analytics.md](api-analytics.md)**
- `fractal_dimension_drift(series, win)`: Regime change detection. $\rightarrow$ **[api-analytics.md](api-analytics.md)**
- `fractal_optimize_portfolio(...)`: Cardinality-constrained optimization. $\rightarrow$ **[api-analytics.md](api-analytics.md)**
- `fractal_vascular_network(...)`: Vessel tortuosity/density. $\rightarrow$ **[api-analytics.md](api-analytics.md)**
- `fractal_cortical_folding(...)`: Gyrification Index. $\rightarrow$ **[api-analytics.md](api-analytics.md)**
- `fractal_nerve_plexus_metric(...)`: Fiber plexus density. $\rightarrow$ **[api-analytics.md](api-analytics.md)**
- `fractal_morphological_complexity(...)`: Mask complexity. $\rightarrow$ **[api-analytics.md](api-analytics.md)**
