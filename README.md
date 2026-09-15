<p align="center">
  <img src="FractalSQLforSQLite.jpg" alt="FractalSQL for SQLite" width="720">
</p>

# FractalSQL: Sovereign Data Intelligence
### Sovereign, Agentic SQLite

**Vector Search. In-Database Reasoning. Production-Safe Agency. All beside your data.**

FractalSQL transforms SQLite from a passive data store into an active agentic
database. FractalSQL adds what traditional RAG (Retrieval-Augmented Generation)
stops short of: reasoning over what it retrieves, and when you enable it
acting on the result, whether that's running a generated query or executing a
decision an agent computed, all inside the same database process.

By bringing reasoning and agency directly into the SQLite backend, FractalSQL
enables **Sovereign Data Intelligence**: the ability to reason, plan, and act upon
your data with the deployment topology under your control. Run fully on-prem or in
your own containers with Ollama/vLLM for zero data egress, or point at your
organization's cloud AI accounts (Bedrock, Azure OpenAI, Vertex), where your compliance
posture requires it for managed-model scale. You control the trade, not the product.

| Traditional RAG Stack | The Sovereign Way (FractalSQL) |
| --- | --- |
| **Mode Collapse**: top-K search returns near-duplicates, starving the LLM of diverse context. | **Scout Discovery**: MMR-style diverse semantic search that discovers the data's real structure. |
| **Fragmented Logic**: app pulls rows, calls LLM, handles retries, and glues answers in middleware. | **In-Database Reasoning**: reasoning and embedding happen inside the SQLite host process itself. |
| **Passive Retrieval**: you ask a question, the DB returns rows, and you hope the LLM is correct. | **Autonomous Agency**: self-correcting SQL, loop detection, and trajectory forecasting. |

## From zero to your first agent

FractalSQL's docs follow a single linear path. Each step answers one question
and hands off to the next. You don't need to read everything; follow the path.

1. **What is this and why do I care?**: you are here. Sovereign Data Intelligence, in one page.
2. **How do I get the extension running in 60 seconds?** → [Getting Started](docs/getting-started.md) (`.load` the extension, then your first Scout search).
3. **How do I apply this to my industry?** → [Starter Kits](docs/starter-kits.md): runnable, industry-specific SQL scripts (SOC, FinTech, MedTech, Fleet, Smart-Cities, …).
4. **How does a specific agent work and what are its inputs?** → [Agent Recipes](docs/api-agency.md): the built-in agents, each as a recipe.
5. **How do I build a proprietary agent that isn't in the box?** → [Composition Guide](docs/composition-guide.md): the design patterns behind the recipes.

> New here? Step 2 is a one-command demo. Step 3 drops you into a vertical that
> looks like your problem. Step 4 is the reference you'll keep coming back to.

---

## 🎯 Who are you?

Depending on your role, you'll want to start in different places:

- **AI Engineer**: You want to improve RAG quality and reasoning.
  → Start with **[docs/features.md](docs/features.md)** and **[docs/reasoning-setup.md](docs/reasoning-setup.md)**.
- **DBA / Security Architect**: You care about stability, safety, and access control.
  → See the **[Safety & Governance guide](docs/text-to-sql-setup.md#secure-it-authorization-vs-correctness)**.
- **Product Developer**: You want to build agentic features quickly.
  → Run the **[Docker Demo](docs/docker-demo.md)**, then pick a **[Starter Kit](docs/starter-kits.md)**.

---

## 🧩 What's in the box

Four tiers of SQL-callable primitives, composable into agents with plain SQL
and application code — no server-side language required.

- **Discovery**: diverse, mode-collapse-free retrieval: `fractal_search` (Sniper), `fractal_search_explore` (Scout).
- **Cognition**: in-process LLM integration: `fractal_reason` (Bedrock, Azure OpenAI, Vertex, Ollama), `fractal_embed`, `fractal_text_to_sql`.
- **Agency**: self-correcting routines: the search/sql agents, plan/trajectory/loop-detection helpers — see the [Agent Recipes](docs/api-agency.md).
- **Analytics**: fractal/dimension primitives: `fractal_dimension_dfa`, `fractal_dimension_boxcount`, `fractal_optimize_portfolio`, and more.

Plus SQLite-native plumbing: `fractal_vector` as a canonical BLOB type,
`fractalsql_set()`/`fractalsql_get()` per-connection configuration, the background
`fractal_vectorizer` embedding pipeline, and the tamper-evident
`fractal_ledger_*` audit surface. The full function-surface reference with
runnable examples lives in [sql/fractalsql--1.0.sql](sql/fractalsql--1.0.sql).

Reasoning is opt-in and provider-pluggable: the `fractalsql-reasoning-http`
plugin speaks the OpenAI chat-completions wire format, so any OpenAI-compatible
endpoint works. Without a plugin configured, Discovery and Analytics are fully
functional and Cognition/Agency return clean precondition errors.

---

## 🚀 Get it running

The fastest path is one command: Docker if you just want to try it, or the
setup wizard if you have a real sqlite3 CLI install already. See
**[Getting Started](docs/getting-started.md)** for the full walkthrough.

```bash
docker compose up -d   # or: docker build -t fractalsql-sqlite .
                       # then .load the extension and run your first Scout search
```

```bash
# Or, on a real install (Linux/macOS):
curl -fsSL https://github.com/FractalSQLabs/fractalsql-sqlite/releases/latest/download/easy_install.sh | bash
# Windows: scripts/windows/easy_install.ps1
```

Native installers: `.deb` / `.rpm` for Linux amd64/arm64 (glibc and musl
channels), a Windows `.msi` (x64), and a self-contained tarball
for macOS (arm64/x86_64). `easy_install.sh` (Linux/macOS) and
`easy_install.ps1` (Windows) wrap all of these behind one interactive
wizard; no telemetry, everything stays local.

Because configuration is per-connection (`fractalsql_set` — SQLite has no
GUCs to persist), the wizard writes a `load_fractalsql.sql` bootstrap
snippet you pass to every session: `sqlite3 -init load_fractalsql.sql mydb.sqlite`.

---

## 🏛️ Enterprise Tier

Everything above is Community edition and fully functional on its own.
Discovery, Cognition, and Agency don't depend on anything in this section. For regulated
environments that need to **prove, not just
tamper-evident, HMAC-sealed decision record: see
**[Enterprise Tier](docs/enterprise.md)** for the full mechanism, including
what the ledger can and can't prove.

---

## 📊 Compatibility & License

| SQLite | Linux | Windows | macOS |
| --- | :---: | :---: | :---: |
| 3.25+ | ✓ | ✓ | ✓ |

Any SQLite host that permits `sqlite3_load_extension` — the `sqlite3` CLI,
Python's `sqlite3` module (`conn.enable_load_extension`), better-sqlite3,
libSQL/Turso-compatible hosts, mobile SQLite bridges. Verified on AWS
Graviton, Apple Silicon, Ampere Altra, and Raspberry Pi.

**License**: Apache-2.0. See `LICENSE`. Third-party components are under
their own permissive licenses (BSD-2-Clause, MIT, and others) --
see `THIRD-PARTY-NOTICES.md`.

For enterprise editions, licensing, and support, contact
**enterprise@fractalsqlabs.com**.

---

## 📚 Documentation

*Follow the path above; the links below are the same steps, expanded.*

- **[Getting Started](docs/getting-started.md)**: 60-second Docker / native install.
- **[Starter Kits](docs/starter-kits.md)**: industry-specific runnable SQL scripts.
- **[Agent Recipes](docs/api-agency.md)**: the sixteen installable agents, each as a recipe.
- **[Composition Guide](docs/composition-guide.md)**: build your own agent.
- **[Features](docs/features.md)**: the full Capability Map and API reference.
- **[Reasoning Setup](docs/reasoning-setup.md)**: LLM provider configuration (Ollama, OpenAI, Bedrock, Azure, Vertex).
- **[Text-to-SQL Setup](docs/text-to-sql-setup.md)**: pipeline details and the security model.
- **[Vectorizer Setup](docs/vectorizer-setup.md)**: automatic embedding pipelines.
- **[Docker Demo](docs/docker-demo.md)**: a one-command end-to-end demo.
- **[Agent Blueprint Gallery](demo/README.md)**: the vertical demos and reference agents.
- **[Enterprise Tier](docs/enterprise.md)**: the tamper-evident decision ledger (CISO/audit).