<p align="center">
  <img src="../FractalSQLforSQLite.jpg" alt="FractalSQL for SQLite" width="720">
</p>

# Sovereign Reasoning Setup Guide

The **Cognition Tier** is the intelligence layer of FractalSQL. It provides a pluggable bridge that lets SQLite call Large Language Models (LLMs) and embedding providers directly from SQL.

By bringing reasoning directly into your SQLite process, FractalSQL lets you synthesize, analyze, and reason over your data without an external application-middleware hop. Sovereignty here is a deployment choice, not a guarantee baked into every provider: local models (Ollama/vLLM) keep data on your own infrastructure, while cloud providers (Bedrock, Azure OpenAI, Vertex) send it to that provider under your own account and compliance agreement.

---

## 🧠 The Cognition Model

At its core, the Cognition tier provides the `fractal_reason(query, context)` primitive. Unlike traditional RAG, which relies on external orchestrators, FractalSQL performs the synthesis inside the host process:

1. **Context Assembly**: You use ordinary SQL (subqueries, `json_group_array`/`json_object`, or the `fractal_search_explore` Scout aggregate) to gather the precise data needed.
2. **Sovereign Dispatch**: The extension dispatches the query and context to your configured LLM via a dedicated C-bridge.
3. **In-Place Synthesis**: The response is returned directly into your query result, allowing you to combine reasoning with standard SQL filters, joins, and aggregations in a single statement.

---

## 🛠️ Prerequisites

To activate the Cognition tier, you need a reasoning plugin and a configured endpoint.

### 1. The Reasoning Plugin
The reasoning plugin (`fractalsql-reasoning-http.so` on Linux and macOS — note the `.so` suffix even on macOS — or `.dll` on Windows) is installed alongside the extension. Installing the file does not activate the feature; you must point the connection at the plugin path with `fractalsql_set('reasoning_plugin', ...)`.

**Find the install directory**:
Common paths include:
- **Linux**: `/usr/local/lib/sqlite3/fractalsql-reasoning-http.so`
- **macOS**: `/usr/local/lib/sqlite3/fractalsql-reasoning-http.so` (same `.so` name as Linux)
- **Windows**: `C:\Program Files\FractalSQL\fractalsql-reasoning-http.dll`

### 2. Technical Requirements
- **Extension Version**: `fractalsql-sqlite` 2.0.0+ (`SELECT fractalsql_version();`).
- **Plugin Version**: `fractalsql-reasoning-http` v1.2.1+ (required for Response Modes and System Tags).
- **Host Dependencies**: `libcurl` 7.75.0+ (required for AWS SigV4 auth).
- **Endpoint**: An LLM provider (Ollama, AWS Bedrock, Azure OpenAI, GCP Vertex, or any OpenAI-compatible API).

> **Shortcut**: for a local Ollama or a plain OpenAI-compatible endpoint,
> `scripts/easy_install.sh` (Linux/macOS) and
> `scripts/windows/easy_install.ps1` (Windows) do Steps 1–2 below for you
> interactively, loading the extension and writing the `fractalsql_set` lines
> into a `load_fractalsql.sql` snippet in one pass.
> See **[docs/getting-started.md §5](getting-started.md#5-install-without-docker)**.
> The manual walkthrough below still applies for Bedrock/Azure/Vertex
> (the wizard only offers the two common defaults) and for anyone who
> wants to see exactly what gets configured.

---

## 🚀 Setup Sequence

**A note on configuration first.** SQLite has no GUCs and no server config file: every setting below is **per-connection** state applied with `SELECT fractalsql_set('<key>', '<value>');` and read back with `fractalsql_get('<key>')`. The standard way to apply it is the `load_fractalsql.sql` snippet the easy_install wizard generates — pass it to every session with `sqlite3 -init load_fractalsql.sql mydb.sqlite`, or `.read load_fractalsql.sql` from inside a session. Configuration takes effect immediately on the connection that runs it; there is nothing to reload.

## Step 1: Activate the Plugin
Add the following to your per-session bootstrap (`load_fractalsql.sql`, or right after your `.load` line):

```sql
-- Plugin path must be absolute (traversal-hygiene validated at set time)
SELECT fractalsql_set('reasoning_plugin',
                      '/usr/local/lib/sqlite3/fractalsql-reasoning-http.so');
```
The plugin attaches lazily upon the first reasoning call on the connection; changing `reasoning_plugin` detaches the previously-attached plugin and the next call re-attaches from the new path. On Windows the path is `C:\Program Files\FractalSQL\fractalsql-reasoning-http.dll`.

## Step 2: Universal LLM Connectivity
One of the core strengths of this design is **zero provider lock-in**: the provider bridge abstracts each provider's API, so your SQL calls to `fractal_reason()` remain identical whether you're using a local model for privacy or a cloud provider for scale.

Pick your provider and add the corresponding block to your configuration. Only one block should be active at a time.

## Ollama (Local or Private Network)
The gold standard for fully air-gapped, sovereign deployments. Traffic stays inside your network perimeter.

```sql
-- Local Ollama
SELECT fractalsql_set('http_url',             'http://127.0.0.1:11434/v1/chat/completions');
SELECT fractalsql_set('http_allow_plaintext', 'on');
SELECT fractalsql_set('http_model',           'gpt-oss:20b');
```
*Note: Run `ollama pull gpt-oss:20b` or `ollama pull gemma4:12b` or `ollama pull phi4:14b` before connecting.*

## OpenAI-Compatible (OpenAI, Together AI, Fireworks, vLLM)
```sql
SELECT fractalsql_set('http_url',   'https://api.openai.com/v1/chat/completions');
SELECT fractalsql_set('http_token', 'sk-...');
SELECT fractalsql_set('http_model', 'gpt-4o-mini');
```

## AWS Bedrock
Bedrock uses AWS SigV4 signing. The URL must point to the **OpenAI-compatible** surface.

```sql
SELECT fractalsql_set('http_url',   'https://bedrock-runtime.us-east-1.amazonaws.com/openai/v1/chat/completions');
SELECT fractalsql_set('http_model', 'amazon.nova-lite-v1:0');
```
**Critical**: Auth type and region are set via the reasoning plugin's own
lower-level environment variables, not `fractalsql_set` config keys:
```sh
export FSQL_REASONING_HTTP_AUTH_TYPE=aws-sigv4
export FSQL_REASONING_HTTP_AWS_REGION=us-east-1
```

## Azure OpenAI
Azure requires a separate deployment for the chat model.

```sql
SELECT fractalsql_set('http_url',   'https://<resource>.openai.azure.com/openai/deployments/<deployment>/chat/completions?api-version=2024-02-01');
SELECT fractalsql_set('http_token', '<azure-api-key>');
SELECT fractalsql_set('http_model', 'gpt-4o');
```

## Google Vertex AI
Vertex AI exposes an OpenAI-compatible endpoint on the `openai/v1` path of your
project's region endpoint. Auth is a Google **service-account OAuth access
token** (a short-lived bearer), supplied via `http_token` exactly like an API
key. No SigV4-style signing is needed.

```sql
SELECT fractalsql_set('http_url',   'https://{LOCATION}-aiplatform.googleapis.com/v1/projects/{PROJECT}/locations/{LOCATION}/endpoints/openapi/chat/completions');
SELECT fractalsql_set('http_token', '<gcp-oauth-access-token>');
SELECT fractalsql_set('http_model', 'google/gemini-2.5-flash');
```

**Generating the token**: the `http_token` must be a valid Google OAuth access
token for a service account with the Vertex AI User role. The canonical way is
a service-account JSON key plus the gcloud CLI:

```sh
gcloud auth activate-service-account --key-file=sa-key.json
gcloud auth print-access-token    # paste the output into http_token
```

The token is short-lived (~1 hour). For a long-running install, refresh it on a
schedule (e.g. a sidecar that re-runs `print-access-token` and rewrites the
`fractalsql_set('http_token', '...')` line in your `load_fractalsql.sql`
snippet, so fresh sessions pick it up). The `http_token` value is read on
every reasoning call on the connection, so rotating it is a plain
`fractalsql_set` away — it takes effect immediately, no reload, no reconnect.

---

## ⚖️ Hardware & Performance (Local Reasoning)

For users deploying Ollama locally, hardware affects "cold-load" latency.

| Resource | Recommendation | Notes |
| --- | --- | --- |
| **GPU VRAM** | 8GB $\rightarrow$ 16GB | 8GB runs Phi-4/Gemma4 (Q4); 16GB runs GPT-OSS 20B. |
| **System RAM** | 16GB+ | Covers model, OS, and the SQLite host process's overhead. |
| **CPU** | AVX2 Support | Essential for acceptable CPU-side inference (Post-2016). |

### Handling Constrained Hardware
Local models can take up to 300s to cold-load into memory. To prevent `curl` from aborting the request, raise the timeout and low-speed windows in the **host process environment** — whichever process loads the extension (the `sqlite3` CLI, your application), since the plugin runs in-process:

```sh
export FSQL_REASONING_HTTP_TIMEOUT_MS=330000
export FSQL_REASONING_HTTP_LOW_SPEED_SECS=300
```
*Note: These are plugin environment variables, not config keys — set them before launching the host process.*

---

## 🛠️ Advanced Configuration

Every advanced knob at a glance -- details for each are in the sections below:

| Variable | Notes |
| --- | --- |
| `FSQL_REASONING_HTTP_RESPONSE_MODE` | `text` (default) / `code` / `json` -- see [Response Modes](#response-modes) |
| `http_think` | Reasoning effort for hybrid-thinker models -- see [Reasoning Effort](#reasoning-effort) |
| `http_think_provider` | Request shape THINK uses -- see [Reasoning Effort](#reasoning-effort) |
| `http_native_url` | Override URL for the ollama/anthropic native shape |
| `http_num_ctx` | Ollama-native context-window cap |
| `FSQL_REASONING_HTTP_AUTH_TYPE` | `bearer` (default) / `api-key` / `aws-sigv4` -- see [AWS Bedrock](#aws-bedrock) |
| `FSQL_REASONING_HTTP_AWS_REGION` | AWS region for `aws-sigv4` |
| `FSQL_REASONING_HTTP_TIMEOUT_MS` | Total request timeout -- see [Handling Constrained Hardware](#handling-constrained-hardware) |
| `FSQL_REASONING_HTTP_LOW_SPEED_SECS` | Slow-response abort window |
| `FSQL_REASONING_HTTP_SYSTEM_PROMPT` | Replaces the baseline anti-injection system prompt -- see [Security & Governance](#-security--governance) |

`http_think` / `http_think_provider` / `http_native_url` / `http_num_ctx` are
`fractalsql_set` config keys (per-connection, no restart needed); everything
else in the table is a process environment variable read once at plugin init.

### Response Modes
Shape how the plugin post-processes the LLM response via environment variables:
- `text` (default): Raw content.
- `code`: Forces a single fenced code block and extracts it.
- `json`: Forces a fenced JSON block and validates structural integrity.

Applies to `fractal_reason`

Not a config key: set `FSQL_REASONING_HTTP_RESPONSE_MODE` in the host
process's environment and restart the host process (the `sqlite3` CLI or
your application) -- reloading anything else is not sufficient.

### Reasoning Effort
Hybrid-thinker models (Granite 4.2, OpenAI o-series, Claude extended thinking, DeepSeek-R1, QwQ) emit an internal reasoning trace before their final answer -- left uncontrolled, that trace dominates latency and, on memory-constrained GPUs, VRAM. Two config keys throttle it:

| Config key (`fractalsql_set`) | Values | Notes |
| --- | --- | --- |
| `http_think` | unset (default) / `none` / `off` / any other string (`low`, `medium`, `high`, `minimal`, `xhigh`, `max`, ...) | Unset (or `none`) sends no thinking-control field, so the model's own default applies. `off` explicitly disables thinking on the wire -- not the same thing, since a hybrid-thinker model's own default is often ON. Any other value is forwarded to the provider verbatim, not checked against a fixed list -- provider effort scales keep adding tiers, so this plugin doesn't hardcode any one vendor's current names. Applies to `fractal_reason()` and `fractal_text_to_sql()`'s GENERATE step only -- never `fractal_embed()`. |
| `http_think_provider` | unset (defaults to `openai`) / `openai` / `ollama` / `anthropic` / `vllm` / `grok` | Selects the request SHAPE, not a vendor -- `openai` also covers Azure OpenAI, AWS Bedrock, and Google Vertex AI's OpenAI-compatible surfaces, since this is independent of how `http_url` is authenticated. `grok` is for xAI's Grok models on Bedrock's OpenAI-compatible surface, which take a nested `reasoning.effort` field instead of `openai`'s top-level one. Ollama and Anthropic speak a native request shape instead, since their OpenAI-compatible endpoints don't honor thinking control. Ignored entirely when `http_think` is unset. |
| `http_native_url` | unset (default) / URL | Only consulted for the ollama/anthropic native shape. Leave unset to target `http_url` verbatim. |
| `http_num_ctx` | `0` (default, unset) / positive integer (max 1048576) | Ollama-native context window cap (`options.num_ctx`) -- a measured fix for hybrid-thinker VRAM blowup on memory-constrained GPUs. Only applies when `http_think_provider=ollama`. |

```sql
-- Local Ollama, medium reasoning effort, capped context window
SELECT fractalsql_set('http_think', 'medium');
SELECT fractalsql_set('http_think_provider', 'ollama');
SELECT fractalsql_set('http_num_ctx', '16384');
```

The plugin never surfaces the reasoning trace itself -- `fractal_reason()`/`fractal_text_to_sql()` still return the final answer only, regardless of `http_think_provider`'s shape.

### Target-System Hints
Set `FSQL_REASONING_HTTP_SYSTEM_TAG=sqlite` in the host process environment to hint to the model that it should use syntax appropriate for your specific engine.

---

## 🔒 Security & Governance

### The Sovereign Guardrail: Dedicated Roles
SQLite has no role model, grants, or RLS inside the engine. The equivalents are
architectural: scope the database file (or `ATTACH` set) the reasoning
connection opens to what you want the LLM to be able to see, and install a
`sqlite3_set_authorizer` callback in your host application to bound what
executed SQL may touch. Config path keys must be absolute with no traversal
segments, enforced by strict validation at set time.

Never expose more of the database to a reasoning connection than the LLM needs. A restricted-view pattern works well: put the LLM-facing columns in a view and point `fractal_schema_context()`-driven prompts at it, rather than at the base tables.

### Row-Level Security (RLS)
Enforce row-level visibility with views that embed the tenant predicate (or a tenant-scoped database file / authorizer hook), so the context subquery only returns rows the connecting user is permitted to see. This prevents "cross-tenant" data leakage to the LLM.

### Prompt Injection (OWASP LLM01)
The plugin prepends a baseline anti-injection instruction to every system message as a best-effort mitigation. No system-prompt instruction can fully prevent prompt injection from untrusted context, since the model still can't reliably distinguish instructions from data. Treat it as raising the bar, not closing the door. The real defense is architectural: RLS and column-level grants restricting what the context subquery can see (above), and treating every LLM response as untrusted output, never executed as SQL (see the checklist below). To replace the baseline instruction, set `FSQL_REASONING_HTTP_SYSTEM_PROMPT`.

---

## 📋 Production Checklist

- [ ] **Plugin Path**: the `reasoning_plugin` config value is absolute, has no `..` segments, and is readable by the host process.
- [ ] **Session Bootstrap**: the `load_fractalsql.sql` snippet (`.load` + `fractalsql_set` lines) is passed to every session (`sqlite3 -init load_fractalsql.sql mydb.sqlite`), and is protected like a credential (it contains `http_token` in plain text).
- [ ] **Access Model**: the reasoning connection's database file / authorizer hook bounds what executed SQL may touch (no engine-side roles in SQLite).
- [ ] **Isolation**: tenant-sensitive rows are only reachable through tenant-scoped views or a scoped database file.
- [ ] **Egress Review**: Cloud endpoints' DPA/BAA have been reviewed for the specific data classification.
- [ ] **Environment**: `FSQL_REASONING_HTTP_AUTH_TYPE` is correctly exported to the host process environment (not just the SQL config).
- [ ] **Output Safety**: LLM responses are treated as untrusted display text and never executed as SQL.
