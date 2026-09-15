<p align="center">
  <img src="../FractalSQLforSQLite.jpg" alt="FractalSQL for SQLite" width="720">
</p>

# Docker Demo: The Learning Path

Try FractalSQL without installing anything. `docker-compose.yml` at the repo
root builds a turnkey demo container — a long-lived `sqlite3` CLI
environment with the extension staged, reasoning pre-configured, and every
demo + benchmark inside it — alongside the `ollama` model service. There is
no database server to start (the extension is a file you `.load`, not a
service), so "the demo environment" is the container's `sqlite3` shell plus
the extension file it loads.

## 🛠️ Prerequisites

Docker and Docker Compose. The demo builds the extension from source inside
the container, so no local `sqlite3` client, compiler, or extension install
is required. (The `ollama` service is a real download, though: see step 2.)

---

## 🚀 Setup Guide

### 1. The turnkey default — `docker compose up -d`

One command, no flags, gives you the bare minimum:

- **Demo container** running: `sqlite3` + the fractalsql extension at
  `/usr/local/lib/sqlite3/fractalsql.so`, with the bundled reasoning
  plugin beside it, a **demo database** at `/work/fractalsql_demo.sqlite`
  (WAL mode, persisted on the `demo_data` volume), and reasoning
  **pre-configured per connection** — `docker/demo-entrypoint.sh` writes
  the bootstrap snippet (`demo_init.sql`, the same `.load` +
  `fractalsql_set()` lines the `easy_install.sh` wizard generates) from
  the compose `FRACTALSQL_*` env vars, pointing at the `ollama` service.
- **Every demo + the `bench/` head-to-head** inside the container
  (`/demo/`, `/bench/`). Demos are **demoable on demand**: they are not
  run at init, because reasoning is inert until a model is pulled and the
  demos are re-runnable.
- **Ollama** running with **no model pulled** (model download is opt-in,
  step 2).

```bash
docker compose up -d
```

Every exec command below runs with `/work` as the working directory, so
the snippet is just `-init demo_init.sql`:

**Quick test** (works with no model; base Sniper search needs no LLM):
```bash
docker compose exec demo sqlite3 fractalsql_demo.sqlite \
  -init demo_init.sql ".read /demo/demo.sql"
# demo.sql sections 0-2 run without a model; sections 3-4 (reasoning)
# get a clear model-not-found error from Ollama until step 2 pulls one.
```

Confirm the extension is alive and which edition it is:
```bash
docker compose exec demo sqlite3 fractalsql_demo.sqlite \
  -init demo_init.sql "SELECT fractalsql_edition(), fractalsql_version();"
# expect: Community|2.0.0
```

Run any demo (re-runnable; each recreates its own fixture tables):
```bash
docker compose exec demo sqlite3 fractalsql_demo.sqlite \
  -init demo_init.sql ".read /demo/<demo>.sql"
```

Or open an interactive `sqlite3` shell with reasoning pre-configured:
```bash
docker compose exec demo sqlite3 fractalsql_demo.sqlite -init demo_init.sql
```

### 2. Cognition — pull a model (opt-in)

Reasoning (`fractal_reason`, `fractal_embed`, `fractal_text_to_sql`) needs a
model. Ollama is already up from step 1; pull one with the `pull-model`
one-shot:

```bash
docker compose --profile pull-model run --rm pull-model
```

…or, equivalently, `docker compose exec ollama ollama pull gpt-oss:20b` (and
`nomic-embed-text`). This pulls ~13.8GB (gpt-oss:20b) + a few hundred MB
(nomic-embed-text). Nothing pulls a model for you — until you do, cognition
calls get a clear model-not-found error from Ollama, not a broken install.
CPU-only inference may take several minutes per query on modest hardware.
See [docs/reasoning-setup.md](reasoning-setup.md)'s hardware section. (Or
point the compose `FRACTALSQL_HTTP_*` env vars at a cloud endpoint instead
and recreate the demo container; see [Reasoning Setup](reasoning-setup.md).)

**Quick test** (now that a model is present):
```bash
docker compose exec demo sqlite3 fractalsql_demo.sqlite \
  -init demo_init.sql ".read /demo/demo.sql"
# sections 3-4 now produce full reasoning output
```

Re-run any cognition demo now for full reasoning output: e.g. the
sixteen-agent validation:
```bash
docker compose exec demo sqlite3 fractalsql_demo.sqlite \
  -init demo_init.sql ".read /demo/demo-agents.sql"
```

### 3. Vectorizer automation

No extra containers: reuse the model from step 2. Enables automatic embedding
pipelines — see [vectorizer-setup.md](vectorizer-setup.md) for the
`fractal_vectorizer_create` / `fractal_vectorizer_process_queue` walkthrough.

```bash
docker compose exec demo sqlite3 fractalsql_demo.sqlite \
  -init demo_init.sql ".read /demo/demo-vectorizer.sql"
```

---

## 🎓 The Learning Path

Run the demos in this order to see the progression from a vector search tool to a
sovereign agentic database. (Cognition/Agency demos need a model from step 2;
Discovery demos do not.)

### Level 1: Geometric Discovery
*Focus: Using the fractal core and domain-specific geometry to find structure in noise.*
- **Goal**: Learn to use SFS for high-precision convergence and domain-specific metrics (vascular, cortical, nerve).
- **Demos**:
  ```bash
  # MedTech: Clinical Telemetry & Patient Monitoring
  docker compose exec demo sqlite3 fractalsql_demo.sqlite -init demo_init.sql ".read /demo/demo-vertical-medtech-clinical.sql"
  # Maritime: AIS & Radar Tracking
  docker compose exec demo sqlite3 fractalsql_demo.sqlite -init demo_init.sql ".read /demo/demo-vertical-maritime-defense.sql"
  # Fleet: Last-Mile Delivery
  docker compose exec demo sqlite3 fractalsql_demo.sqlite -init demo_init.sql ".read /demo/demo-vertical-fleet-logistics.sql"
  # Smart Cities: IoT Sensor Grids
  docker compose exec demo sqlite3 fractalsql_demo.sqlite -init demo_init.sql ".read /demo/demo-vertical-smart-cities-iot.sql"
  ```

### Level 2: Cognitive Synthesis
*Focus: Composing search with LLM reasoning to generate human-readable insights.*
- **Goal**: Learn to feed Scout Discovery results into `fractal_reason` and use `fractal_text_to_sql` for safe data exploration.
- **Demos**:
  ```bash
  # Recommendations: Advanced Discovery Engines
  docker compose exec demo sqlite3 fractalsql_demo.sqlite -init demo_init.sql ".read /demo/demo-vertical-recommendation-search.sql"
  # Sovereign: Edge & Autonomous Systems AI
  docker compose exec demo sqlite3 fractalsql_demo.sqlite -init demo_init.sql ".read /demo/demo-vertical-sovereign-edge-ai.sql"
  # BI: The Full Reasoning Loop (Question -> SQL -> Result -> Reason)
  docker compose exec demo sqlite3 fractalsql_demo.sqlite -init demo_init.sql ".read /demo/demo-business-intelligence.sql"
  ```

### Level 3: Autonomous Agency
*Focus: Building self-correcting, safe, and predictive agentic workflows.*
- **Goal**: Learn to use loop detection (DFA), trajectory prediction, self-correcting SQL agents, and the sixteen installable agents built on top of them — all register at `.load` time, no install step. See [api-agency.md](api-agency.md).
- **Demos**:
  ```bash
  # DevOps: Autonomous Incident Triage & Self-Healing
  docker compose exec demo sqlite3 fractalsql_demo.sqlite -init demo_init.sql ".read /demo/demo-vertical-agentic-ops-devops.sql"
  # Support: Stateful Session & Churn Drift
  docker compose exec demo sqlite3 fractalsql_demo.sqlite -init demo_init.sql ".read /demo/demo-vertical-agentic-customer-support.sql"
  # FinTech: MCTS Scenario Exploration & Safe Execution
  docker compose exec demo sqlite3 fractalsql_demo.sqlite -init demo_init.sql ".read /demo/demo-vertical-agentic-fintech-mcts.sql"
  # Cyber: Threat Detection & Triage
  docker compose exec demo sqlite3 fractalsql_demo.sqlite -init demo_init.sql ".read /demo/demo-vertical-cybersecurity-threat-detection.sql"
  # The sixteen agents (already in the loaded extension — no install step)
  docker compose exec demo sqlite3 fractalsql_demo.sqlite -init demo_init.sql ".read /demo/demo-agents.sql"
  ```

See [Agent Recipes](api-agency.md#which-agent-should-i-use) for what each agent
does and when to use it.

### Other demos in the image

`/demo/` also contains `demo.sql` (the base walkthrough), `response-modes.sql`,
`demo-text-to-sql.sql`, the `text-to-sql-spike-*.sql` series,
`demo-fractal-vector.sql`, `benchmark.sql`, `benchmark-api-reference.sql`,
and the enterprise-tier `enterprise-qtl-audit.sql` / `enterprise-stress.sql`.
Run any the same way. `demo/demo-workload.sh` (the sustained concurrent-load
tester) is also in the image at `/demo/` — it is a bash script, not SQL, so
run it with `docker compose exec demo /demo/demo-workload.sh --help`.

---

## 📊 Validation & Benchmarks

### Scout Discovery vs. naive top-K (in-database demo)
See how Scout Discovery captures more distinct clusters than standard top-K
search — `demo/benchmark.sql` runs both directly against a synthetic
cluster corpus:

```bash
docker compose exec demo sqlite3 fractalsql_demo.sqlite \
  -init demo_init.sql ".read /demo/benchmark.sql"
```

### Full API surface
`demo/benchmark-api-reference.sql` exercises the full function surface (Search,
Reason, Agents, Analytics) in one pass:
```bash
docker compose exec demo sqlite3 fractalsql_demo.sqlite \
  -init demo_init.sql ".read /demo/benchmark-api-reference.sql"
```

### Head-to-head benchmark (in-container)
`bench/` runs a real sqlite-vec-vs-Scout head-to-head at 100k-row scale
(sqlite-vec does exact brute-force KNN, not HNSW — see `bench/README.md`
for why). Its Python deps are pre-installed in `/bench/.venv`; the scripts
take `--ext`/`--db`, so in-container runs point `--ext` at the staged
extension and `--db` at a path on the persisted volume:

```bash
docker compose exec demo /bench/.venv/bin/python3 /bench/data_gen.py \
  --ext /usr/local/lib/sqlite3/fractalsql.so --db /work/fractalsql_bench.db
docker compose exec demo /bench/.venv/bin/python3 /bench/head_to_head.py \
  --ext /usr/local/lib/sqlite3/fractalsql.so --db /work/fractalsql_bench.db
docker compose exec demo /bench/.venv/bin/python3 /bench/vector_type_head_to_head.py \
  --ext /usr/local/lib/sqlite3/fractalsql.so --db /work/fractalsql_bench.db
```

…or run it from the host against your own built artifact with your own
Python env (`pip install -r bench/requirements.txt`, `make bench` /
`make bench-vector`). See `bench/README.md` for the output shape and
tuning knobs.

---

## 🧹 Cleanup

```bash
docker compose down -v                       # default services + volumes
docker compose --profile pull-model down -v  # also remove the pulled-model volume
```

The `-v` flag removes the named volumes (Sqlite data, the Ollama model cache). 
Drop it if you want to keep them for next time.