<p align="center">
  <img src="../FractalSQLforSQLite.jpg" alt="FractalSQL for SQLite" width="720">
</p>

# FractalSQL MCP Plugin

**fractalsql-sqlite-mcp** is a Model Context Protocol server that opens
FractalSQL for SQLite to the broader AI agent ecosystem: Claude
Desktop, Cursor, Windsurf, Claude Code, LangChain, LlamaIndex, CrewAI,
the Vercel AI SDK, or any other client or framework that speaks MCP.
One clean tool per FractalSQL primitive: your agent calls
`fractal_search_telemetry` or `fractal_agent_data_analyst` and gets
back a finished, reasoned result, without ever writing a line of SQL.

**Why it exists.** FractalSQL's in-database agents are a *micro*-
orchestration tier: tight Retrieve → Reason → Act → Guard loops running
entirely inside the SQLite host process. The MCP server is the *macro*-
orchestration bridge one layer up: it lets an external agent call a
single FractalSQL primitive or recipe and get the result back over
MCP's JSON-RPC, translating between the two worlds at exactly one
boundary. Every tool name is the underlying SQL function name, every
argument list mirrors the function's documented one 1:1, and every
result comes back as real JSON (never a TEXT document that happens to
look like JSON), so an agent that has read [api-agency.md](api-agency.md)
can predict the tool surface without any translation layer.

> **SQLite shape, honestly carried.** There is no server process and no
> second extension here: loading `fractalsql.so` registers every agent
> and primitive in one step, every call is one scalar `SELECT fn(...)`,
> and every structured result is one TEXT-JSON document the MCP layer
> decodes for the client. The MCP server mirrors that exactly instead
> of inventing a set-returning shape SQLite doesn't have.

## Deployment topologies

The server itself only ever does two things: open one SQLite file
(`SQLITE_DB_PATH`) and speak JSON-RPC over stdio or HTTP. Everything
below is what you put on either side of it; none of it requires a code
change in this repo, and any storage posture combines with any
reasoning posture.

- **Local-first / air-gapped.** stdio transport, a local `.sqlite`
  file, and a local reasoning backend (Ollama, or any OpenAI-compatible
  server on localhost) for zero network egress end to end. This is the
  default posture in [Install & connect](#install--connect) below and
  the one the Docker demo runs. It's also the relevant shape for
  constrained edge hardware, not just workstations: the native C++17
  binary (see below) has no interpreter or `node_modules` tree to
  provision, so the footprint is the binary, the SQLite file, and
  whatever model runtime you pair it with.
- **Enterprise cloud reasoning.** Point the same server's reasoning
  config at a managed LLM account instead of a local model: AWS
  Bedrock (SigV4), Azure OpenAI, GCP Vertex AI, or an OpenAI-compatible
  serving layer (vLLM, Together AI, Fireworks AI). This is engine-level
  config, not MCP-specific: set it exactly as documented in
  [reasoning-setup.md](reasoning-setup.md), via
  `FRACTALSQL_BOOTSTRAP_SQL` or the `fractalsql_configure_reasoning`
  tool.
- **Distributed / replicated storage.** The server opens whatever file
  `SQLITE_DB_PATH` names, so file-layer replication that doesn't touch
  the SQLite format — **LiteFS**, **Litestream** — sits underneath it
  transparently: point the env var at the replica/mount path, make sure
  `fractalsql.so` is present on every node, and the server can't tell
  the difference. **Turso** is a different case: its hosted/remote mode
  speaks libSQL's own wire protocol, which this binary (built against
  vendored, vanilla `sqlite3.c`) doesn't. A Turso **embedded replica**
  file is ordinary SQLite on disk, so pointing `SQLITE_DB_PATH` at that
  local file works like any other local file; connecting this server
  directly to Turso's remote endpoint does not.
- **Containerized / sidecar.** The binary's only runtime dependencies
  are libc, libssl, and libcrypto (see [Install & connect](#install--connect)):
  it drops into a Docker/Kubernetes sidecar next to whatever serves the
  database file, no interpreter or package manager in the image. The
  repo's own [docker-demo.md](docker-demo.md) is this shape.
- **Network-exposed HTTP transport.** Two ways to get TLS on the wire,
  pick one: put a reverse proxy/LB in front (the zero-config default --
  a sidecar fits the topology above) or run `--https` so this process
  terminates TLS itself (no proxy to deploy, at the cost of this binary
  now holding the cert/key). Either way the Bearer-token check is the
  same; see [Security](#security).

## Install & connect

The server is a **native C++17 binary** in the repo's [`mcp/`](../mcp/)
directory: the same toolchain every engine's own extension code builds
with, with no language runtime to ship or CVE-track (no `node_modules`,
no interpreter to patch). Its two dependencies are vendored in-repo: the
JSON parser (`mcp/vendor/json.hpp`) and the SQLite amalgamation it
embeds (`deps/sqlite/sqlite3.c`), plus the system OpenSSL libraries for
the integrity-lock hashing and the optional HTTP transport.

### 0. Build it

```bash
# Linux / macOS (g++ or clang >= 11, OpenSSL dev headers, make -C mcp)
make -C /path/to/fractalsql-sqlite/mcp        # -> mcp/fractalsql-sqlite-mcp
```

```powershell
# Windows (VS 2022 cl.exe + OpenSSL 3.x from vcpkg's x64-windows-static
# triplet, resolved via VCPKG_ROOT, same posture as the engine's own
# scripts\windows\build.bat)
mcp\scripts\windows\build.bat                 # -> mcp\dist\windows-mcp\fractalsql-sqlite-mcp.exe
```

Sanity check without a database: `fractalsql-sqlite-mcp --version` and
`--list-tools` print the release and the full tool table.

### 1. Environment

| Variable | Required | What it is |
| --- | --- | --- |
| `SQLITE_DB_PATH` | yes | The database file (or `:memory:`) the MCP server's connection opens. **This file is your access-control boundary**; see [Security](#security). |
| `FRACTALSQL_EXTENSION_PATH` | yes | The `fractalsql.so` / `.dylib` / `.dll` to load in-process. |
| `FRACTALSQL_BOOTSTRAP_SQL` | recommended | The per-connection `fractalsql_set(...)` snippet the server applies at session start: the same `load_fractalsql.sql` text [easy_install](getting-started.md) generates (`.load` lines in it are honored-but-skipped; the extension loads via the driver first). |
| `FSQL_MCP_HTTP_HOST` / `FSQL_MCP_HTTP_PORT` / `FSQL_MCP_HTTP_PATH` | no | HTTP transport bind address (default `127.0.0.1:8765`, path `/mcp`); transport is chosen by flag (`--http`/`--https`), not env. Default posture is TLS terminating **in front** (reverse proxy/LB); see [Security](#security). |
| `FSQL_MCP_AUTH_TOKEN` / `FSQL_MCP_AUTH_TOKEN_FILE` | http(s) only | Opaque Bearer token (or a mtime-hot-reloaded token file for rotation without downtime). Required for the HTTP/HTTPS transport, never used on stdio; TLS is never a substitute for it. |
| `FSQL_MCP_HTTPS` | no | `true` is equivalent to launching with `--https` (direct TLS, off by default); see [`--https`](#2-run-it) below. |
| `FSQL_MCP_TLS_CERT_FILE` / `FSQL_MCP_TLS_KEY_FILE` | https only | PEM certificate (chain OK) and unencrypted PEM private key for direct TLS; equivalent to `--tls-cert`/`--tls-key`. |
| `FSQL_MCP_MAX_ROWS_CEILING` | no | Hard server-enforced row ceiling (default 1000). |
| `FSQL_MCP_MAX_CONCURRENT_CHEAP` / `FSQL_MCP_MAX_CONCURRENT_EXPENSIVE` / `FSQL_MCP_MAX_CONCURRENT_EXPENSIVE_PER_CLIENT` | no | Concurrency caps (defaults 50 / 5 / 2); see [Concurrency](#concurrency). |
| `FSQL_MCP_MAX_QUEUE_WAIT_MS` | no | How long a request beyond a cap waits for a slot before a "server busy" error (default 900000). |
| `FSQL_MCP_SHUTDOWN_DRAIN_MS` | no | Graceful-shutdown drain window (default 5000). |
| `FSQL_MCP_STRICT_SCHEMA_HASH` | no | `true` turns a tool-surface schema-hash mismatch into a hard start failure. |
| `FSQL_MCP_READ_ONLY` | no | Deployment-wide kill switch: the server refuses every `destructiveHint` tool call with a clear error, before the call reaches the engine (default off). It keys on `destructiveHint`, not on `readOnlyHint` — the seven destructive tools (ledger write/reset, `fractal_vectorizer_drop`, the two config tools), not every write. |
| `FSQL_MCP_TOOL_WHITELIST` / `FSQL_MCP_ENABLED_CATEGORIES` | no | Runtime narrowing of the catalog: a comma-separated tool list or category list (`discovery,cognition,agency,analytics,enterprise,vectorizer,admin`). The demo container uses `FSQL_MCP_TOOL_WHITELIST`'s flag form, `--tool`. |
| `FSQL_MCP_LOG_LEVEL` | no | `info` (default), `verbose` (redacted argument bodies in the per-call log), or `debug`. |
| `FSQL_MCP_AGENT_PARTIAL` | no | `on` (default) opts every session into the engine's `agent_partial_reasoning_fail` mode: partial-result honesty. `off` keeps the engine's documented raise behavior for reasoning-endpoint failures inside agent calls. |

Reasoning/embedding provider config (chat URL, models, etc.) stays
where the engine's own docs put it: per-connection `fractalsql_set`
state, applied through `FRACTALSQL_BOOTSTRAP_SQL` or the
`fractalsql_configure_reasoning` tool. The MCP server never stores a
provider token or the enterprise ledger key itself.

### 2. Run it

```bash
export SQLITE_DB_PATH=/data/app.sqlite
export FRACTALSQL_EXTENSION_PATH=/usr/local/lib/sqlite3/fractalsql.so
export FRACTALSQL_BOOTSTRAP_SQL="SELECT fractalsql_set('http_url','http://127.0.0.1:11434/v1/chat/completions'); SELECT fractalsql_set('http_allow_plaintext','on'); SELECT fractalsql_set('http_model','gpt-oss:20b');"

# Linux/macOS: the Makefile build output; Windows: mcp\dist\windows-mcp\
/path/to/fractalsql-sqlite/mcp/fractalsql-sqlite-mcp
```

On Docker Desktop, `FRACTALSQL_BOOTSTRAP_SQL` can point at Docker Model
Runner instead of Ollama with no extra container:
`SELECT fractalsql_set('http_url','http://127.0.0.1:12434/engines/v1/chat/completions'); SELECT fractalsql_set('http_allow_plaintext','on'); SELECT fractalsql_set('http_model','ai/gpt-oss:20b'); -- or 'ai/gemma4:12b' or 'ai/phi4'`
(`docker model pull ai/gpt-oss:20b` first; see
[reasoning-setup.md](reasoning-setup.md#docker-model-runner-dmr)).

The default transport is stdio: one JSON-RPC 2.0 message per line,
stdout is the MCP wire and **all logging goes to stderr**. The optional
HTTP transport is `--http [port]` (plus `--host H` / `--path P`); pass
`--tool a,b,c` or `--category x,y` to narrow the catalog at launch.

For direct TLS instead of (or behind) a reverse proxy, `--https [port]
--tls-cert cert.pem --tls-key key.pem` (or the `FSQL_MCP_HTTPS` /
`FSQL_MCP_TLS_CERT_FILE` / `FSQL_MCP_TLS_KEY_FILE` env equivalents)
terminates TLS in this process using the OpenSSL it already links for
the schema-lock hashing. Off by default -- a bad or missing cert/key is
a hard startup failure (never a silent plaintext fallback), and the
Bearer-token check applies identically underneath either transport
mode; TLS authenticates the channel, not the caller. See [Deployment
topologies](#deployment-topologies) above for when direct TLS is the
right choice versus terminating in front.

### 3. Point your MCP client at it

Claude Desktop / Cursor `mcpServers` config (stdio launch, env passed
through):

```json
{
  "mcpServers": {
    "fractalsql": {
      "command": "/path/to/fractalsql-sqlite/mcp/fractalsql-sqlite-mcp",
      "env": {
        "SQLITE_DB_PATH": "/data/app.sqlite",
        "FRACTALSQL_EXTENSION_PATH": "/usr/local/lib/sqlite3/fractalsql.so",
        "FRACTALSQL_BOOTSTRAP_SQL": "SELECT fractalsql_set('http_url','http://127.0.0.1:11434/v1/chat/completions'); SELECT fractalsql_set('http_allow_plaintext','on'); SELECT fractalsql_set('http_model','gpt-oss:20b');"
      }
    }
  }
}
```

**Other clients and frameworks.** Windsurf and Claude Code consume the
identical `mcpServers`-shaped config above unmodified. Frameworks that
don't speak MCP's wire format natively go through their own MCP
client/adapter instead of anything bespoke here: LangChain
(`langchain-mcp-adapters`), LlamaIndex (`llama-index-tools-mcp`),
CrewAI (`MCPServerAdapter` in `crewai-tools`), and the Vercel AI SDK
(`experimental_createMCPClient`) each point their adapter at this same
binary/command the way they'd point at any other MCP server. Those
adapters are third-party and not maintained by this repo; what this
project guarantees is the standard MCP protocol surface above, not any
particular framework's wrapper around it.

### 4. The one-line sanity check

Call `fractalsql_get_version` from your client and expect a real
edition/version back (e.g. `Community|2.0.5`). On startup the server
also compares `fractalsql_version()` against the release its tool
surface was built against and **warns (never hard-fails)** on a
mismatch; the documented SQL surface is stable across the compat
matrix even when the patch version moves.

## Tool catalog

81 tools, grouped the same way the API docs group them. Optional
arguments carry their documented defaults in each tool's schema; vector
arguments are plain JSON arrays of numbers at the MCP boundary and are
converted to the engine's CSV/JSON TEXT convention for you. Tool names
are the SQL function names, unprefixed.

### Discovery (14)

| Tool | Purpose |
| --- | --- |
| `fractal_search` | Sniper-mode SFS convergence to the single best point (per-row scalar here; tuning knobs fixed; use `fractal_search_debug` for the tunable trace). |
| `fractal_search_debug` | Same convergence with a full trajectory trace (`best_point`/`best_fit` per generation, particle paths). |
| `fractal_search_explore` | Scout-mode DIVERSE population search (SFS + MMR): the anti-mode-collapse primitive, run with no model needed. |
| `fractal_search_telemetry` | Ground-truth K-nearest table rows by exact cosine distance; `doc_id` is the real `rowid` locator, `scan_pos` is the feedback handle. |
| `fractal_hybrid_clinical_search` | The same, cohort-restricted: pass an explicit JSON array of rowids to restrict the scan before ranking. |
| `fractal_search_trajectory` | Drift-vector search (current − baseline): "what changed," not "where am I." `doc_id` here is a 0-indexed scan position, NOT a row locator. |
| `fractal_cross_modal_search` | Weighted concatenation of two modality vectors before the search. |
| `fractal_diversify_enable` / `_disable` / `_set_params` | The stateful Diversify/Repulsion layer for this session (off by default; session-scoped). |
| `fractal_detect_collapse` | Current diversity quotient (D_q); null when nothing has searched yet. |
| `fractal_explain_result` | Session Diversify diagnostics `{dq, diversify_enabled, overhead_p99_us}`. |
| `fractal_feedback_report` / `fractal_isolate_background` | Report dwell/positive/negative engagement on a prior result by its `scan_pos` handle. |

### Cognition (4)

| Tool | Purpose |
| --- | --- |
| `fractal_reason` | Dispatches a query + JSON context to the configured LLM provider and returns the answer. Requires reasoning configured first. |
| `fractal_embed` | Embedding from text via the configured embed model, returned as a plain JSON array of numbers. |
| `fractal_text_to_sql` | NL question → ONE validated statement, **never auto-executed** (GENERATE → ALLOWLIST → [REVIEW] → parse-check pipeline). No `table_names` on SQLite: auto-discovers; use `fractal_sql_agent` for scoping. |
| `fractal_schema_context` | Plain-text schema description the LLM itself sees: zero arguments here; call it to audit before reasoning. |

### Agency: the sixteen installable agents (16)

Each agent is one JSON document back: the real computed numbers plus the LLM's read. The three no-LLM agents are marked.

| Agent | Recipe in one line |
| --- | --- |
| `fractal_agent_anomaly_triage` | Drift exponent on one entity's table-backed metric series → LLM triage |
| `fractal_agent_regime_triage` | DFA + drift over a single array-in series → LLM triage |
| `fractal_agent_track_anomaly` | Trajectory deviation + heading-series DFA → LLM triage |
| `fractal_agent_detour_classify` | Trajectory deviation + GPS-trace box-counting → LLM classify |
| `fractal_agent_network_coverage_alert` | Spatial morphology + telemetry drift → LLM alert |
| `fractal_agent_allocate` | SFS cardinality-constrained Sharpe optimizer → LLM rationale |
| `fractal_agent_rebalance_sibling` | Optimizer + nearest-historical-allocation trajectory search → LLM rationale |
| `fractal_agent_diverse_portfolios` | Multi-restart diverse candidates (`sharpe`/`pareto`) → one LLM tradeoff summary. **Enterprise tier.** |
| `fractal_agent_route_task` | Nearest-capability search + token-budget accounting → LLM rationale |
| `fractal_agent_schedule_workload` | `fractal_search` refinement + nearest-node lookup → LLM rationale |
| `fractal_agent_outlier_intercept` | Distance-to-known-bad-state barrier (`cosine`/`l2`) → LLM justification |
| `fractal_agent_patient_deterioration_triage` | Caller-built cohort search + baseline→current drift → LLM triage |
| `fractal_agent_data_analyst` | NL question → SQL → execute → LLM analysis (the horizontal catch-all) |
| `fractal_agent_recall_hybrid` | Cohort-restricted vector recall. **No LLM.** |
| `fractal_agent_recommend_diverse` | Repulsion-diverse top-k, avoiding recently-rejected items. **No LLM. Leaves Diversify ON.** |
| `fractal_agent_feedback_audit` | Self-contained Diversify health-check cycle. **No LLM. Self-disables.** |

**Partial-result honesty.** Every agent above that composes a data step
plus the final reasoning call (everything but the three **No LLM** rows,
`fractal_sql_agent`, `fractal_agent_plan_explore`, and
`fractal_agent_trajectory_predict`, whose engine implementations never
dispatch an LLM) opts this session into the engine's
`agent_partial_reasoning_fail` mode at connect: if the reasoning
endpoint fails **after** the data step, the tool returns the computed
data half plus `"reasoning_step_failed": "<the endpoint's error>"` with
`isError: false` instead of raising. Set `FSQL_MCP_AGENT_PARTIAL=off` to
keep the engine's documented raise behavior. The reasoning surface
itself (`fractal_reason`, `fractal_embed`, `fractal_text_to_sql`) is not
covered (there the reasoning call *is* the result), and an unconfigured
`reasoning_plugin` always raises, in both modes.

### Universal Agents (6)

| Agent | Returns |
| --- | --- |
| `fractal_search_agent` | `{answer, source_doc_ids, execution_time_ms}`: embed → Scout → reason over the matched rows' real content |
| `fractal_rag_agent` | `{answer}`: the lighter single-turn RAG sibling |
| `fractal_sql_agent` | `{generated_sql, execution_status, retry_count, result_json}`: `auto_execute` **defaults to false and is never defaulted to true** (see [Safety](#safety)) |
| `fractal_agent_plan_explore` | One JSON document of MCTS-style branches `{branch_id, plan_trajectory, confidence_score}` |
| `fractal_agent_trajectory_predict` | `{predicted_state_vector, projected_drift_delta, risk_threshold_exceeded}` |
| `fractal_agent_detect_loop` | `{agent_id, dfa_exponent, is_loop_detected[, cycle_len, at_index]}`: SimHash + Brent + DFA drift |

### Analytics (22)

Fractal dimensions (`fractal_dimension_dfa` / `_boxcount` / `_drift`),
time-series and topology (`fractal_change_point_detect`,
`fractal_periodogram`, `fractal_tda_persistence_diagram`),
fingerprinting (`fractal_state_fingerprint`, `fractal_cycle_detect`),
vector math (`fractal_vector_lp_distance`,
`fractal_vector_quantize_int8`, `fractal_vector_quantize_binary`,
`fractal_vector_hamming_distance`), domain geometry
(`fractal_vascular_network`, `fractal_cortical_folding`,
`fractal_nerve_plexus_metric`, `fractal_morphological_complexity`),
portfolio optimization (`fractal_optimize_portfolio`, the Enterprise
`_multimodal` / `_multimodal_pareto`, `fractal_optimize_subset`), and
the feature store (`fractal_store_morphology`,
`fractal_mine_topology_negatives`).

Each description carries the REAL, empirically-verified minimum input:
DFA's documented-16 is really ~24 points; box-counting's
documented-8 is really hundreds for a stable estimate; morphological
complexity wants ~256+ occupied points, carried over from the repo's
own test-suite findings so an agent doesn't rediscover them by trial.

### Enterprise / ledger (10): gated, clean error on Community

`fractal_ledger_flush`, `fractal_ledger_load`, `fractal_ledger_verify`,
`fractal_ledger_compact`, `fractal_ledger_reset_soft`,
`fractal_ledger_reset_hard`, `fractal_ledger_truth_count`,
`fractal_ledger_shadow_count`, `fractal_audit_unpack`,
`fractal_audit_log`. Every gated tool's description says so up front
("Enterprise tier: returns a clean 'enterprise tier not loaded' error
on a Community install"), so a client can tell "needs a license" from
"something broke." Exception: `fractal_ledger_verify` is a pure
read-only forensic query that works even with no enterprise library
loaded. The write-path tools (`_flush`, `_compact`, `_reset_soft`,
`_reset_hard`) carry MCP `destructiveHint` annotations: a client UI
that honors them will prompt a human first, which is intended behavior.

### Vectorizer (5)

`fractal_vectorizer_create` / `_pause` / `_resume` / `_drop` /
`_process_queue`: the pull-based embedding sync; you drive the queue
on your own schedule (no background worker in any engine, by design).
`fractal_vectorizer_status` is exposed as a Resource instead (below).
**Per-connection caveat:** the registry/queue are TEMP objects scoped to
the MCP server's dedicated session connection (see [Per-connection, not
global](#per-connection-not-global)).

### Admin (4)

| Tool | Purpose |
| --- | --- |
| `fractalsql_get_version` | `fractalsql_version()` + `fractalsql_edition()`: the one-line "is it alive" check. |
| `fractalsql_set_config` / `fractalsql_get_config` | Thin wrappers over the engine's own `fractalsql_set` / `fractalsql_get` per-connection surface. `destructiveHint`-flagged (a repointed `http_url` silently redirects every later reasoning call; old/new values of whatever changed are logged). Secrets are **never read back**. |
| `fractalsql_configure_reasoning` | One unified config tool shaped identically across the engine plugins (`provider_url`, `embed_url`, `model`, `embed_model`, `allow_plaintext`, `think_mode`), adapter-translated here into `fractalsql_set` calls: in effect immediately, nothing to reload. **Never touches the provider token or any enterprise key.** |

## Resources

| URI | What it holds |
| --- | --- |
| `fractalsql://schema` | `fractal_schema_context()`'s own live output: read it before composing a text-to-SQL call the way the install docs audit it. |
| `fractalsql://config` | The resolved non-secret session config. NEVER the reasoning token or ledger HMAC key; those are never read back through any resource or tool. |
| `fractalsql://ledger/{1\|2}` | `fractal_ledger_verify(kind)`'s JSON audit report: the CISO state a periodic refresh can pull like the schema. Clean "enterprise tier not loaded" condition on Community, same as the tool. |
| `fractalsql://vectorizer/status` | The `fractal_vectorizer_status` view's rows (TEMP objects, this session's connection only). |
| `fractalsql://agents` | The full "which agent should I use" decision table from api-agency.md as one pull. |

## Prompts

Eleven parameterized workflow templates, one per reference blueprint:
`incident_triage`, `portfolio_rebalance`, `patient_triage`,
`fleet_detour_check`, `track_anomaly_check`, `sensor_grid_health`,
`churn_recovery`, `ask_my_data` (the catch-all; auto-executing),
`safe_sql_question` (auto-execute explicitly OFF),
`diversity_audit`, `ciso_ledger_check`. Every generated message states
the tools it will call and in what order; the execution-capable ones
surface the least-privilege/accountability warnings inline.

## Operational notes

### Per-connection, not global

Every config knob is per-connection `fractalsql_set` state on the
server's ONE dedicated session connection, which is mostly transparent
because the server holds that connection for its lifetime. But a second
MCP client instance pointed at the same database file gets its own
bootstrap and inherits nothing, and the vectorizer registry/queue (TEMP
objects) live on this connection only. For per-tenant isolation on
SQLite (which has **no engine-side role/grant/RLS model at all**), run
one MCP server instance per tenant-scoped database file, or install a
`sqlite3_set_authorizer` hook in the server process yourself (see the
composition guide and reasoning-setup's Sovereign Guardrail section
for the pattern).

### `doc_id` semantics

`fractal_search_telemetry` / `fractal_hybrid_clinical_search` return
`doc_id` as the row's real `rowid` (stable under UPDATE; SQLite's
physical row locator), plus the 0-indexed `scan_pos`
alongside as the feedback handle. `fractal_search_trajectory` /
`fractal_cross_modal_search` `doc_id`s are 0-indexed scan positions,
never row locators. The table-searching agents resolve either shape
internally; raw telemetry calls return it exactly as the primitive does.

### Array-shaped results: the row ceiling

Every array-shaped tool result takes a caller-settable `limit`
(default 100) with a hard server-enforced ceiling (default 1000,
`FSQL_MCP_MAX_ROWS_CEILING`), never silently more. When the underlying
result was larger, the tool response carries `"truncated": true` and
`"total_scanned": N`, so the calling agent can re-call with search-level
filtering (a cohort restriction, a smaller k) instead of just a bigger
`limit`: a bigger limit alone doesn't fix an underlying query that was
always going to scan too much.

### Concurrency

Two global caps: 50 concurrent cheap-tier requests (Discovery,
Analytics, Vectorizer, Admin, Enterprise defaults and ledger reads) and
5 concurrent expensive-tier requests (Cognition, Agency, text-to-SQL;
anything dispatching a real LLM call, sized against the documented
300s+ cold-load window behind `FSQL_REASONING_HTTP_TIMEOUT_MS=330000`),
plus a smaller per-client cap (2 by default) on shared HTTP
deployments. A request beyond a cap queues or gets a clear "server
busy" error, never silently dropped. Cancellation (`$/cancel`) aborts
the in-flight statement and discards the cancelled call's eventual
result, never delivered after the fact. Graceful shutdown on SIGTERM/
SIGINT stops new requests immediately, drains in flight (5s default),
then closes the connection.

### Logging

The server writes structured JSON lines to stderr: every tool call with
size-capped, secret-redacted arguments, latency, and the error class:
**the only per-call audit trail on a Community install**. The
Enterprise ledger covers decision-agent writes, not MCP-layer tool
invocations, and is silent about them on Community; operators needing
compliance coverage must not assume otherwise. Connection strings and
credential fragments are scrubbed by a shared sanitizer before any
exception reaches a log line.

## Enterprise integration points

- **Identity / SSO.** Put an identity-aware reverse proxy (Okta, Entra
  ID, Auth0) in front of the HTTP(S) transport for SSO; it terminates
  alongside TLS in the default (non-`--https`) posture and sits in
  front of the Bearer-token check described in [Security](#security).
- **Gateways / proxies.** Docker's MCP Toolkit/Catalog, Cloudflare's
  Remote MCP hosting, and cloud-vendor agent gateways front this server
  the same way they front any stdio/HTTP(S) MCP endpoint, for policy,
  rate limiting, or observability across multiple MCP servers.
- **Secrets management.** `FSQL_MCP_AUTH_TOKEN_FILE` and
  `FSQL_MCP_TLS_KEY_FILE` are mtime/path-based so a secrets manager's
  sync agent (Vault Agent, the External Secrets Operator, AWS/Azure's
  secret-to-file sync) can rotate either file in place with no restart.
- **Observability / SIEM.** Pipe the structured stderr JSON log (see
  [Logging](#logging)) into Splunk, Elastic, Datadog, Sentinel, or any
  other log-aggregation pipeline; it's already size-capped and
  secret-redacted for that.
- **Registries / catalogs.** `mcp/manifest.json` (regenerate with
  `--write-manifest`) is the install-from-URL distribution manifest for
  listing this server in the official MCP Registry, Docker's MCP
  Catalog, or a similar catalog.
- **No-/low-code agent orchestrators.** Microsoft Copilot Studio / Azure
  AI Foundry Agent Service, Amazon Bedrock AgentCore, and Google's
  Vertex AI Agent Builder point at this server's stdio/HTTP(S) command
  the same way Claude Desktop or Cursor do (see [Other clients and
  frameworks](#3-point-your-mcp-client-at-it) above).

## Safety

- `fractal_sql_agent`'s `auto_execute` **defaults to false and is never
  defaulted to true by the MCP layer**: a client must pass it
  explicitly, and every relevant description names the consequence (the
  generated SQL runs under whatever the server's connection can touch).
- `fractal_agent_data_analyst` executes its internally-generated
  (read-only-allowlisted) SQL by recipe design; the least-privilege
  connection guidance applies to the server process's DB file.
- Enterprise write-path tools and destructive vectorizer operations
  carry `destructiveHint` annotations; reasoning-config changes are
  similarly flagged and always logged with old + new values.
- **"Reaches outside the database" is annotated per tool.** `openWorldHint`
  marks the tools whose call actually crosses the server boundary — a
  chat-LLM or embedding-provider dispatch (`fractal_reason`,
  `fractal_embed`, `fractal_text_to_sql`, the reasoning agents, and
  `fractal_agent_plan_explore`, which embeds the caller's state label
  through the configured embedding provider before exploring the strategy
  table). It is set PER TOOL, not per tier: the closed-world engines
  (`fractal_agent_recall_hybrid`, `fractal_agent_recommend_diverse`,
  `fractal_agent_feedback_audit`, `fractal_agent_trajectory_predict`,
  `fractal_agent_detect_loop`, `fractal_schema_context`) do NOT carry it,
  because they only read and compute inside this database. A client that
  gates "this may leave the world" should not have to ask a human about a
  local vector recall.
- One boundary the MCP layer cannot widen: which database file the
  server is opened against is fixed at process launch, an operator
  decision, never something an MCP client or LLM can change mid-session.
- **Deployment-wide read-only kill switch:** setting `FSQL_MCP_READ_ONLY=true`
  makes the server refuse every `destructiveHint` tool call with a clear
  in-band error, before the call reaches the engine: a fast lever for
  incident response and scheduled export/reporting windows that doesn't
  require re-permissioning the database file. It keys on
  `destructiveHint`, not on `readOnlyHint`, so it stops the seven
  destructive tools (the four ledger write/reset tools,
  `fractal_vectorizer_drop`, and the two config tools) — NOT every
  write: `fractal_store_morphology`, the four `fractal_vectorizer_*`
  lifecycle tools, and `fractal_audit_log` also write to the database,
  do not carry `destructiveHint`, and stay callable under the switch.
  (`fractal_audit_log` is enterprise-gated, so on Community it returns
  the clean "enterprise tier not loaded" error and writes nothing; on an
  enterprise install it appends audit rows — including the ones the
  agent engines emit.) For a genuine no-write posture, scope the DB file
  itself — on SQLite that file is the access-control boundary
  (see [Security](#security) below).
- **Data, never instructions:** tool results (LLM text and especially
  recalled/retrieved row content) are DATA. A row embedded from
  user-submitted text (a ticket, a review) can carry prompt-injection
  content; the highest-exposure tools (`fractal_rag_agent`,
  `fractal_agent_recall_hybrid`, `fractal_search_agent`) say so by name
  in their descriptions.

## Security

- **stdio** needs no auth: the client spawns the server as a trusted
  subprocess. **HTTP** transport is different: plaintext is never
  acceptable, even internally, so TLS is required either way -- the
  zero-config default is a reverse proxy/LB terminating it in front
  (`--http`), and `--https` (with `--tls-cert`/`--tls-key` or
  `FSQL_MCP_TLS_CERT_FILE`/`FSQL_MCP_TLS_KEY_FILE`) terminates it in
  this process directly when there's no proxy to put in front of it. A
  missing or unloadable cert/key under `--https` is a hard startup
  failure, never a silent plaintext fallback. Either way, every request
  must carry an opaque Bearer token (env or hot-reloadable file) --
  TLS and the token are independent controls, and neither substitutes
  for the other. Only `GET /healthz` and `GET /readyz` are exempt from
  the token; the JSON-RPC path never is.
- **Supply chain / rug-pull defense:** the tool surface is hash-locked.
  The committed `mcp/.mcp-schema-lock` holds the SHA-256 over the
  canonical (key-sorted, whitespace-free) JSON of every tool's name /
  description / schema; the server compares it at startup and warns on
  a mismatch (set `FSQL_MCP_STRICT_SCHEMA_HASH=true` to hard-fail). A
  second committed lock, `mcp/.mcp-safety-annotations-lock`, covers the
  tools' safety annotations (`readOnlyHint` / `destructiveHint` /
  `idempotentHint` / `openWorldHint`) the same way, so a client that
  trusts `readOnlyHint: true` is trusting a locked, reviewed table, not
  the current binary's word. When a tool's schema or annotations
  legitimately change, regenerate with
  `fractalsql-sqlite-mcp --write-schema-lock` and
  `--write-safety-annotations-lock` and commit the updated locks in the
  same PR; the same regenerate-and-commit shape as any other lockfile.
  `mcp/manifest.json` carries the install-from-URL-shaped distribution
  manifest the same regenerate flow regenerates (`--write-manifest`).
- **Injection safety:** every adapter uses the driver's own parameter
  binding for EVERY argument, never string concatenation. Ordinary
  tool calls don't pass through `fractal_text_to_sql`'s allowlist
  pipeline (that guards one tool, not the other eighty), so the binding
  layer is the injection boundary.
- **Least privilege:** the server inherits whatever its connection can
  touch. On SQLite that's architectural: scope the DB file, and prefer
  running admin tools (`fractalsql_set_config` et al.) against a
  separately-scoped server instance in production; the server soft-warns
  once when it detects the shared case.

## Troubleshooting

| What you see | What it means / what to do |
| --- | --- |
| `enterprise tier not loaded` | A gated tool on a Community install: a license/`enterprise_lib` question, not a bug. `fractal_ledger_verify` works regardless. |
| `version skew: this MCP plugin was built against ... but the database reports ...` (startup warning in the log) | The engine and the plugin disagree on release. The documented surface is stable across the compat matrix; align the versions if a tool misbehaves. |
| Connection-level failures at start | `SQLITE_DB_PATH` / `FRACTALSQL_EXTENSION_PATH` check first; the path in `reasoning_plugin` config keys must be absolute with no `..` segments (validated by the engine at set time). |
| `--https requires a TLS cert and key ...` / `failed to load TLS cert file ...` / `TLS certificate and private key do not match` | `--https` startup validation: pass `--tls-cert`/`--tls-key` (or set `FSQL_MCP_TLS_CERT_FILE`/`FSQL_MCP_TLS_KEY_FILE`) to a real, matching PEM pair. A hard exit here is correct behavior -- never a silent plaintext fallback. |
| `server busy: the expensive tier is over its cap ...` | Concurrency caps doing their job during a cold-loading local model; reduce parallel LLM-tier calls or raise the caps. |
| A result carries `reasoning_step_failed: ...` with `isError: false` | The agent's data half computed fine; the LLM endpoint failed and the session reports it instead of discarding the computation (partial-result honesty). Fix the reasoning endpoint/model config and re-call. Set `FSQL_MCP_AGENT_PARTIAL=off` to return to raising. |
| A prompt asks me to execute; I'd rather not | Use the `safe_sql_question` prompt (or `fractal_text_to_sql` directly): validation without execution. |
| Recalled content contains instructions addressed to the agent | That's prompt-injection-shaped row content: treat tool results as data, never instructions; see [Safety](#safety) / the reasoning-setup checklist. |

For the full walkthrough of every tool argument, see the API docs this
catalog mirrors: [api-discovery.md](api-discovery.md),
[api-cognition.md](api-cognition.md), [api-agency.md](api-agency.md),
[api-analytics.md](api-analytics.md), [vectorizer-setup.md](vectorizer-setup.md),
[enterprise.md](enterprise.md). The turnkey demo of the MCP round trip
without installing a client lives in
[docker-demo.md § Try the MCP server](docker-demo.md#4-try-the-mcp-server).