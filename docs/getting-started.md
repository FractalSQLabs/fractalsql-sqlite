<p align="center">
  <img src="../FractalSQLforSQLite.jpg" alt="FractalSQL for SQLite" width="720">
</p>

# Getting Started: From Zero to Your First Agent

This guide takes you from a fresh checkout to a running agentic database in
about five minutes: no server install, no compiler, no model download
required to start. By the end you will have:

- a `sqlite3` session with the `fractalsql` extension loaded,
- a diverse vector search that runs with **no model** connected,
- a live reasoning call against a real LLM, and
- the built-in agents demoable on demand: the six C-level Universal Agents
  (search, SQL, RAG, plan-explore, trajectory-predict, loop-detect) plus the
  sixteen installable agents built on them, all registered at `.load` time —
  see [api-agency.md](api-agency.md).

The fastest path is the setup wizard. If you are putting this into a real
application instead, jump to
[Install without Docker](#5-install-without-docker) and come back to the
"first search" / "first agent" sections.

> **The 5-minute path:** [1. Running in 60 seconds](#1-running-in-60-seconds-docker)
> → [2. Your first search](#2-your-first-search-no-model-needed)
> → [3. Turn on reasoning](#3-turn-on-reasoning) → [4. Your first agent](#4-your-first-agent)
> → [where next](#where-next).

---

## 1. Running in 60 seconds (Docker)

From the repo root:

```bash
docker build -f docker/Dockerfile --target export \
  --output type=local,dest=./dist/amd64 .
```

That builds the extension binary (`fractalsql.so`) — there is no server to
start and nothing to enable by init: an SQLite extension is a file you
`.load`. Point a `sqlite3` shell at it and verify FractalSQL is alive:

```bash
sqlite3 :memory: \
  -cmd ".load ./dist/amd64/fractalsql" \
  "SELECT fractalsql_edition(), fractalsql_version();"
```

You should see:

```
Community|2.0.0
```

> **No `sqlite3` on your host?** Any SQLite host that permits
> `sqlite3_load_extension` works the same way (Python's `sqlite3` module with
> `conn.enable_load_extension(True)`, better-sqlite3, ...). The turnkey
> compose demo environment (a database server + Ollama containers with the demo SQL
> preloaded) is the other edition's flow — not applicable to this
> integration; there is no server here.

---

## 2. Your first search (no model needed)

FractalSQL's core is a **Stochastic Fractal Search** optimizer. It comes in
two flavours that solve different problems:

- **Sniper** (`fractal_search`): converge to the single best point in a
  continuous space.
- **Scout** (`fractal_search_explore`): discover the *diverse* structure of
  your own data, finding distinct "islands" instead of collapsing to one
  nearest neighbour.

Scout is what makes FractalSQL different from a plain vector DB, and it runs
with **no model connected**. Try it on a tiny toy corpus (vectors are
CSV-of-floats TEXT here, not a native array column type):

```sql
-- sqlite3 mydb.sqlite  (then:)
.load /usr/local/lib/sqlite3/fractalsql

CREATE TABLE demo_vecs (id INTEGER PRIMARY KEY, emb TEXT);
INSERT INTO demo_vecs VALUES
  (1, '0.1,0.1,0.1'),
  (2, '0.9,0.9,0.9'),
  (3, '0.2,0.8,0.2');

-- Scout: discover the distinct basins in the data (not just the closest row)
SELECT fractal_search_explore(
    emb,
    '0.5,0.5,0.5',
    '{"population_size": 20, "iterations": 10, "walk": 0}')
FROM demo_vecs;
```

You'll get back a spread of vectors drawn from the distinct clusters in your
table (a JSON document holding the final SFS population): the opposite of a
`top-K` query that would return three rows all from the same neighbourhood.
Re-running it is safe and gives similar diverse coverage.

→ For the sqlite-vec-vs-Scout benchmark that makes the difference concrete, see
**[docs/docker-demo.md](docker-demo.md)** (the benchmark section) or run
`make bench` directly (see `bench/README.md`).

---

## 3. Turn on reasoning

Search finds data; **reasoning** turns it into insight. Reasoning is opt-in.
It calls an LLM through a high-performance HTTP bridge, so you point it at a
provider (Ollama locally, or AWS Bedrock / Azure OpenAI / GCP Vertex in the
cloud). Configuration is per-connection — there are no global config keys — so the standard
way is the `load_fractalsql.sql` snippet (below) passed to every session:

```sql
SELECT fractalsql_set('reasoning_plugin',
                      '/usr/local/lib/sqlite3/fractalsql-reasoning-http.so');
SELECT fractalsql_set('http_url',             'http://127.0.0.1:11434/v1/chat/completions');
SELECT fractalsql_set('http_allow_plaintext', 'on');
SELECT fractalsql_set('http_model',           'gpt-oss:20b');

SELECT fractal_reason('Reply with exactly: FSQL_LIVE_OK') AS reply;
```

```
FSQL_LIVE_OK
```

The embedder works the same way (it powers the vectorizer and any
RAG-style agent):

```sql
SELECT fractalsql_set('http_embed_url',   'http://127.0.0.1:11434/v1/embeddings');
SELECT fractalsql_set('http_embed_model', 'nomic-embed-text');

SELECT fractal_vector_dims(fractal_embed('hello world')) AS embed_dim;
--  768
```

→ To point at a cloud endpoint instead of local Ollama, see
**[docs/reasoning-setup.md](reasoning-setup.md)** (provider config keys,
the slow-hardware timeout notes).

---

## 4. Your first agent

The **Agent Tier** composes Discovery + Cognition into self-correcting
routines. The C-level **Universal Agents** are registered the moment the
extension loads — try the single-turn RAG agent end to end:

```sql
SELECT fractal_rag_agent(
    'What do the notes say about a node that stops heartbeating?',
    'runbook_chunks', 'emb');
```

For the full walk of every primitive (search → reason, text-to-SQL,
verticals), the demo scripts ship in `demo/` of the repository, already
adapted to this integration's real syntax and function surface (`.load`,
`fractalsql_set`, CSV/JSON-TEXT or `fractal_vector` BLOB vectors — not
carried over unmodified from the original port) — run them directly, e.g. `sqlite3 -cmd ".load
./dist/amd64/fractalsql" ":memory:" ".read demo/demo-agents.sql"`.

Prefer a specific industry? The vertical walkthroughs are catalogued one
per industry, e.g. cybersecurity threat detection — see
**[docs/starter-kits.md](starter-kits.md)**.

→ To pick the right agent for your problem, see the decision table in
**[docs/api-agency.md](api-agency.md#which-agent-should-i-use)**.

---

## 5. Install without Docker

### Option A: one command

Run the setup wizard for your platform. It detects an existing install,
offers to install the matching package if it's not there yet, and walks you
through picking a reasoning provider (local Ollama, an OpenAI-compatible
endpoint, or search only). No config-file editing required — it writes a
`load_fractalsql.sql` bootstrap snippet instead.

```bash
# Linux / macOS
curl -fsSL https://github.com/FractalSQLabs/fractalsql-sqlite/releases/latest/download/easy_install.sh | bash
# or, from a clone:
./scripts/easy_install.sh
```

```powershell
# Windows
pwsh -File .\scripts\windows\easy_install.ps1
```

Already installed the package yourself? Run the same script and it detects
that, skipping straight to the wizard. It's also safe to re-run any time
you want to switch providers or models: it just rewrites the
`load_fractalsql.sql` snippet. Every prompt has a matching flag
(`--provider`, `--url`, `--model`, `--yes`, `--dry-run`, ...) for
non-interactive or CI use. Run with `--help` for the full list. The script
never phones home: no telemetry, no usage reporting, all of it stays local
to your box.

Pass the snippet to every session — configuration is per-connection, so the
snippet (a `.load` line plus the `fractalsql_set` calls) is the standard way
to apply it:

```bash
sqlite3 -init /usr/local/lib/sqlite3/load_fractalsql.sql mydb.sqlite
```

### Option B: manual / air-gapped

For anything that can't run a cloned script directly, such as a compliance
environment, an air-gapped box, or just wanting to see every step, the
package matching your CPU architecture is on
[GitHub Releases](https://github.com/FractalSQLabs/fractalsql-sqlite/releases).

```bash
# Debian / Ubuntu
sudo apt install ./sqlite3-fractalsql-amd64.deb

# RHEL / Rocky / Fedora / SUSE
sudo dnf install ./fractalsql-sqlite-*.rpm   # or: sudo zypper install ./fractalsql-sqlite-*.rpm
```

```powershell
# Windows: run the matching .msi (e.g. FractalSQL-SQLite-2.0.0-x64.msi)
# It installs to C:\Program Files\FractalSQL\fractalsql.dll.
```

There is no separate install/activation step — loading *is* installing. Point any
session at the file:

```sql
-- Linux / macOS (SQLite strips the .so/.dylib suffix automatically):
.load /usr/local/lib/sqlite3/fractalsql
-- or, in SQL: SELECT load_extension('/usr/local/lib/sqlite3/fractalsql');
-- Windows:
.load C:\Program Files\FractalSQL\fractalsql.dll
```

On **macOS** there is no `.deb`/`.rpm` equivalent, so releases ship a
per-arch tarball:

```bash
tar xzf fractalsql-sqlite-2.0.0-darwin-arm64.tar.gz
sudo mkdir -p /usr/local/lib/sqlite3
sudo install -m0755 fractalsql.dylib /usr/local/lib/sqlite3/
sudo install -m0755 fractalsql-reasoning-http.so /usr/local/lib/sqlite3/
# then, per session: .load /usr/local/lib/sqlite3/fractalsql
```

Reasoning provider configuration (the `fractalsql_set` lines `easy_install`
writes for you in Option A) is documented step by step in
**[docs/reasoning-setup.md](reasoning-setup.md)**.

→ Package paths, version matrices, and the reasoning-plugin config keys are in
**[docs/features.md](features.md)** and
**[docs/reasoning-setup.md](reasoning-setup.md)**.

---

## Where next

The documentation is a linear path. You just finished this guide, step 2 of
the path in the [README](../README.md#from-zero-to-your-first-agent).

| Step | Question | Go to |
|------|----------|-------|
| 3 | *"How do I apply this to **my** industry?"* | **[docs/starter-kits.md](starter-kits.md)** |
| 4 | *"How does a specific agent work, and what are its inputs?"* | **[docs/api-agency.md](api-agency.md)** |
| 5 | *"How do I build a proprietary agent that isn't in the box?"* | **[docs/composition-guide.md](composition-guide.md)** |

If you want the extension-build walkthrough (profiles, libc variants), see
the "Build profiles" note in **[docs/docker-demo.md](docker-demo.md)**.