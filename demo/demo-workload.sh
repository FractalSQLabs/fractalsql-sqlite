#!/usr/bin/env bash
# demo/demo-workload.sh
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#
# A production-shaped mixed workload against a local SQLite deployment --
# concurrent simulated users, each issuing a realistic MIX of calls
# (mostly cheap search, occasionally expensive reasoning) sustained
# over real wall-clock time, with p50/p95/p99 latency per operation
# type at the end.
#
# This answers a different question than demo.sql/benchmark.sql do.
# Those prove the pipeline is CORRECT (right answer, one call at a
# time). This proves it HOLDS UP -- concurrent load, sustained
# duration, a realistic operation mix, not a single-shot demo. Neither
# one substitutes for the other.
#
# Baseline hardware assumption: a self-hosted, air-gapped deployment on
# modest 2016+-era hardware with an 8-16GB GPU running the reasoning
# model locally (not a cloud GPU) -- reasoning/text-to-sql latency
# numbers from this script are only meaningful in that context. Point
# --http-url at real hardware in that class to get a real baseline;
# the number this script cannot manufacture for you is "is my hardware
# in that class" -- that's on you to confirm separately.
#
# Usage:
#   ./demo/demo-workload.sh
#   ./demo/demo-workload.sh --duration 300 --concurrency 10
#   ./demo/demo-workload.sh --reasoning-plugin /usr/local/lib/sqlite3/fractalsql-reasoning-http.so
#   ./demo/demo-workload.sh --http-url http://127.0.0.1:11434/v1 --model gpt-oss:20b
#
# --reasoning-plugin / --http-url / --model: configure the reasoning
# plugin and/or endpoint for this run (per-connection fractalsql_set
# state, so the script applies the same SELECTs to every worker and
# scheduler invocation). Nothing on disk is edited -- these settings
# live only in each connection, so there is nothing to revert on exit
# (the PG-era docker-compose edit/recreate/revert dance is gone with
# the container). Without them, reason/text-to-sql/embed calls fail
# cleanly and get counted as failures in the summary, same as any
# other error under load would be -- this script does not hide that,
# it's a real signal about what's actually working right now.
#
# Env overrides:
#   WORKLOAD_DURATION      seconds per run (default 120)
#   WORKLOAD_CONCURRENCY   concurrent simulated users (default 5)
#   WORKLOAD_DB            throwaway SQLite file (default /tmp/fractalsql_demo_workload_<pid>.db)
#   FSQL_EXT               extension path (default dist/<os>/fractalsql
#                          built here, else /usr/local/lib/sqlite3/fractalsql)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"

DURATION="${WORKLOAD_DURATION:-120}"
CONCURRENCY="${WORKLOAD_CONCURRENCY:-5}"
DB="${WORKLOAD_DB:-/tmp/fractalsql_demo_workload_$$.db}"
OLLAMA_HOST=""
MODEL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --duration)        DURATION="$2"; shift ;;
    --concurrency)     CONCURRENCY="$2"; shift ;;
    --reasoning-plugin) REASONING_PLUGIN="$2"; shift ;;
    --http-url)        HTTP_URL="$2"; shift ;;
    --model)           MODEL="$2"; shift ;;
    -h|--help)
      sed -n '2,42p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

# --------------------------------------------------------------------
# Extension path: use the repo build if present (dist/<os>), else the
# make-install default. --extension overrides both.
# --------------------------------------------------------------------
EXT="${FSQL_EXT:-}"
if [[ -z "$EXT" ]]; then
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*) EXT=dist/windows/fractalsql.dll ;;
        Darwin*)              EXT=dist/darwin/fractalsql.dylib ;;
        *)                    EXT=dist/linux/fractalsql.so ;;
    esac
    [[ -f "$EXT" ]] || EXT=/usr/local/lib/sqlite3/fractalsql
fi
if [[ ! -e "$EXT" ]]; then
    echo "extension not found: $EXT (set FSQL_EXT or pass it via env)" >&2
    exit 1
fi

G="\033[32m"; Y="\033[33m"; Z="\033[0m"
log() { printf "%b\n" "$*"; }

# --------------------------------------------------------------------
# Every invocation (worker op, scheduler tick, setup) opens its own
# connection: .load the extension, set a busy timeout for the
# concurrent writers, then turn .timer on so each statement prints a
# "Run Time: real ..." line the worker parses into its latency sample.
# Per-connection config (reasoning plugin / http endpoint) goes in
# front of the timer -- fractalsql_set state never crosses a
# connection, which is exactly why it's applied per invocation here.
# --------------------------------------------------------------------
CMD_BASE=(-cmd ".load $EXT" -cmd ".timeout 10000" -cmd ".timer on")
CMD_CONFIG=()
[[ -n "${REASONING_PLUGIN:-}" ]] && CMD_CONFIG+=(-cmd "SELECT fractalsql_set('reasoning_plugin','$REASONING_PLUGIN');")
[[ -n "${HTTP_URL:-}" ]]         && CMD_CONFIG+=(-cmd "SELECT fractalsql_set('http_url','$HTTP_URL');")
[[ -n "${MODEL:-}" ]]            && CMD_CONFIG+=(-cmd "SELECT fractalsql_set('http_model','$MODEL');")

# Fail fast if the extension isn't actually loadable, rather than let
# schema setup fail confusingly (or, worse, silently run the whole
# workload against a bare sqlite3 and report a wall of misleading
# "no such function" failures).
if ! sqlite3 -batch ":memory:" -cmd ".load $EXT" "SELECT fractalsql_edition();" >/dev/null 2>&1; then
    log "${Y}cannot load $EXT (sqlite3 with extension loading required) -- is it built/installed?${Z}"
    exit 1
fi

rm -f "$DB" "$DB-wal" "$DB-shm"

# --------------------------------------------------------------------
# Schema + seed data -- a small relational schema for text-to-sql, a
# document table for embed/vectorizer, and a vector corpus for
# Sniper/Scout. Realistic-shaped, not realistic content -- templated
# sentences/questions with real variety, not literal production text
# (that's not something this script can manufacture for you either).
# WAL mode so the concurrent workers don't serialize on readers.
# --------------------------------------------------------------------
log "Setting up workload schema (200 customers, ~1000 orders, 300 documents, 5000 vectors)..."

sqlite3 -batch "$DB" "${CMD_BASE[@]}" <<'SQL' >/dev/null
PRAGMA journal_mode = WAL;

CREATE TABLE wl_customers (id INTEGER PRIMARY KEY, name TEXT NOT NULL, status TEXT NOT NULL);
WITH RECURSIVE gs(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM gs WHERE n < 200)
INSERT INTO wl_customers (name, status)
SELECT 'customer_' || n,
       CASE WHEN (random() / 9223372036854775808.0 + 1) / 2 < 0.75 THEN 'active'
            ELSE 'churned' END
FROM gs;

CREATE TABLE wl_orders (id INTEGER PRIMARY KEY, customer_id INTEGER NOT NULL REFERENCES wl_customers(id),
                        total_cents INTEGER NOT NULL, status TEXT NOT NULL, placed_at TEXT NOT NULL);
WITH RECURSIVE gs(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM gs WHERE n < 1000)
INSERT INTO wl_orders (customer_id, total_cents, status, placed_at)
SELECT 1 + CAST((random() / 9223372036854775808.0 + 1) / 2 * 199 AS INTEGER),
       500 + CAST((random() / 9223372036854775808.0 + 1) / 2 * 20000 AS INTEGER),
       CASE WHEN (random() / 9223372036854775808.0 + 1) / 2 < 0.2 THEN 'pending'
            WHEN (random() / 9223372036854775808.0 + 1) / 2 < 0.8 THEN 'paid'
            ELSE 'refunded' END,
       datetime('now', printf('-%.1f days', (random() / 9223372036854775808.0 + 1) / 2 * 90))
FROM gs;

CREATE TABLE wl_documents (id INTEGER PRIMARY KEY, body TEXT NOT NULL, embedding TEXT);
WITH RECURSIVE gs(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM gs WHERE n < 300)
INSERT INTO wl_documents (body)
SELECT CASE (CAST((random() / 9223372036854775808.0 + 1) / 2 * 8 AS INTEGER))
           WHEN 0 THEN 'Quarterly infrastructure review: database latency remained within SLA across all regions.'
           WHEN 1 THEN 'Customer escalation notes: billing discrepancy resolved after reconciling the March invoice.'
           WHEN 2 THEN 'Release notes: the search API now supports diverse retrieval alongside nearest-neighbor lookup.'
           WHEN 3 THEN 'Incident postmortem: a connection pool exhaustion event was traced to a retry storm.'
           WHEN 4 THEN 'Onboarding guide: new team members should start with the architecture overview document.'
           WHEN 5 THEN 'Security review: rotated API credentials for all third-party integrations this cycle.'
           WHEN 6 THEN 'Product feedback summary: users requested clearer error messages on failed imports.'
           ELSE        'Capacity planning: projected storage growth suggests a review is needed within two quarters.'
       END || ' (doc ' || n || ')'
FROM gs;

-- 5000 vectors x 128 dims as CSV TEXT (SQLite has no float8[] typmod;
-- every analysis/search function here reads CSV TEXT transparently).
CREATE TABLE wl_vectors (id INTEGER PRIMARY KEY, emb TEXT NOT NULL);
CREATE TEMP TABLE long_vecs AS
WITH RECURSIVE gs(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM gs WHERE n < 640000)
SELECT (n - 1) / 128 + 1 AS vid, (n - 1) % 128 + 1 AS k,
       random() / 9223372036854775808.0 AS v FROM gs;
INSERT INTO wl_vectors (emb)
SELECT group_concat(printf('%.4f', v), ',') FROM long_vecs GROUP BY vid ORDER BY vid;
DROP TABLE long_vecs;
SQL

# --------------------------------------------------------------------
# Vectorizer backfill: SQLite's vectorizer state (registry, queue,
# enqueue trigger) is per-connection TEMP state, so the whole
# create -> backfill cycle runs in ONE invocation. Without a configured
# embed endpoint the queue drains into 'failed' rows (counted, not
# hidden) -- same signal as the reason/t2s ops below.
# --------------------------------------------------------------------
VZID=$(sqlite3 -batch "$DB" "${CMD_BASE[@]}" \
       "SELECT fractal_vectorizer_create('wl_documents', 'body', 'embedding');" 2>&1 | head -1)
log "Vectorizer created (id=$VZID), backfilling ${G}300${Z} documents before the run starts..."
sqlite3 -batch "$DB" "${CMD_BASE[@]}" \
    "SELECT fractal_vectorizer_process_queue(500);" >/dev/null 2>&1

# --------------------------------------------------------------------
# Worker: sustained, weighted-random mix of operations for DURATION
# seconds. Mix approximates a real search-heavy app: cheap DB-native
# search dominates (sniper/scout/embed/insert, 90%), expensive
# LLM-backed calls are occasional (reason/text-to-sql, 10%) -- matching
# how a real app actually calls an LLM sparingly, not on every request.
# --------------------------------------------------------------------
RESULTS_DIR="/tmp/fractalsql_demo_workload_$$"
rm -rf "$RESULTS_DIR"; mkdir -p "$RESULTS_DIR"

REASON_PROMPTS=(
    "summarize the current customer status distribution in one sentence"
    "what pattern, if any, is notable in recent order activity"
    "suggest one thing worth double-checking about billing data quality"
)
T2S_QUESTIONS=(
    "how many active customers are there?"
    "what is the total value of paid orders?"
    "which customers have refunded orders?"
    "how many orders were placed in the last 30 days?"
)
EMBED_TEXTS=(
    "a customer reported a billing discrepancy on their latest invoice"
    "quarterly infrastructure review shows stable database latency"
    "new release adds diverse retrieval to the search API"
)

worker() {
    local wid="$1" end_at op out lat
    end_at=$(( $(date +%s) + DURATION ))
    : > "$RESULTS_DIR/worker_$wid.log"
    while [[ "$(date +%s)" -lt "$end_at" ]]; do
        local r=$(( RANDOM % 100 ))
        if   [[ "$r" -lt 40 ]]; then op=sniper
        elif [[ "$r" -lt 55 ]]; then op=scout
        elif [[ "$r" -lt 70 ]]; then op=embed
        elif [[ "$r" -lt 80 ]]; then op=insert
        elif [[ "$r" -lt 90 ]]; then op=t2s
        else                       op=reason
        fi

        case "$op" in
            sniper)
                # Abstract-space Sniper: one SFS convergence per call
                # (PG's abstract fractal_search(query, 30, 30, 2) form).
                out=$(sqlite3 -batch "$DB" "${CMD_BASE[@]}" \
                    ${CMD_CONFIG[@]+"${CMD_CONFIG[@]}"} \
                    "SELECT fractal_search_debug('0.3,0.6,0.9,0.2,0.0', 30, 30, 2);" 2>&1) ;;
            scout)
                # Scout over the corpus: the aggregate fractal_search_explore
                # runs once per distinct query per scan (memoized), the
                # population is the diverse representative set.
                out=$(sqlite3 -batch "$DB" "${CMD_BASE[@]}" \
                    ${CMD_CONFIG[@]+"${CMD_CONFIG[@]}"} \
                    "WITH RECURSIVE d(k, s) AS (
                         SELECT 1, printf('%.4f', random() / 9223372036854775808.0)
                         UNION ALL SELECT k + 1, s || printf(',%.4f', random() / 9223372036854775808.0)
                         FROM d WHERE k < 128),
                     e AS (SELECT fractal_search_explore(emb, (SELECT s FROM d WHERE k = 128),
                              '{\"population_size\": 20, \"iterations\": 8, \"walk\": 0}') AS res
                            FROM wl_vectors)
                     SELECT DISTINCT value FROM e, json_each(e.res, '\$.population') LIMIT 20;" 2>&1) ;;
            embed)
                local txt="${EMBED_TEXTS[$((RANDOM % ${#EMBED_TEXTS[@]}))]}"
                out=$(sqlite3 -batch "$DB" "${CMD_BASE[@]}" \
                    ${CMD_CONFIG[@]+"${CMD_CONFIG[@]}"} \
                    "SELECT fractal_embed('$txt');" 2>&1) ;;
            insert)
                out=$(sqlite3 -batch "$DB" "${CMD_BASE[@]}" \
                    ${CMD_CONFIG[@]+"${CMD_CONFIG[@]}"} \
                    "INSERT INTO wl_documents (body)
                     VALUES ('workload-generated note from worker $wid at ' || datetime('now'));" 2>&1) ;;
            t2s)
                local q="${T2S_QUESTIONS[$((RANDOM % ${#T2S_QUESTIONS[@]}))]}"
                out=$(sqlite3 -batch "$DB" "${CMD_BASE[@]}" \
                    ${CMD_CONFIG[@]+"${CMD_CONFIG[@]}"} \
                    "SELECT fractal_text_to_sql('$q');" 2>&1) ;;
            reason)
                local p="${REASON_PROMPTS[$((RANDOM % ${#REASON_PROMPTS[@]}))]}"
                out=$(sqlite3 -batch "$DB" "${CMD_BASE[@]}" \
                    ${CMD_CONFIG[@]+"${CMD_CONFIG[@]}"} \
                    "SELECT fractal_reason('$p');" 2>&1) ;;
            *) ;;   # unreachable: op is set to one of the above by the if/elif chain above
        esac

        # .timer prints a Run Time line even when the statement itself
        # errored -- it measures execution wall-clock regardless of
        # outcome, it is not a success signal. Check for ERROR first, or
        # a fast dispatch failure (e.g. no chat model configured on the
        # target endpoint) silently counts as a fast "success" here,
        # which it did on a real run before this fix.
        lat=$(printf '%s' "$out" | grep -oE '^Run Time: real [0-9.]+' | grep -oE '[0-9.]+$' | head -1 | awk '{printf "%.1f", $1 * 1000}')
        if printf '%s' "$out" | grep -qE '^(Error|Parse error|Runtime error)'; then
            echo "$op fail 0" >> "$RESULTS_DIR/worker_$wid.log"
        elif [[ -n "$lat" ]]; then
            echo "$op ok $lat" >> "$RESULTS_DIR/worker_$wid.log"
        else
            echo "$op fail 0" >> "$RESULTS_DIR/worker_$wid.log"
        fi
    done
}

# Scheduler: drains the vectorizer queue on a fixed cadence, same as a
# real deployment's cron job would -- not inline with user requests.
# Each tick is one whole connection: SQLite's vectorizer state is
# per-connection TEMP state (registry, queue, trigger), so the tick
# re-creates the vectorizer, ingests a couple of documents (which the
# tick's own enqueue trigger catches), and drains. See
# ../docs/vectorizer-setup.md for the real scheduling options this
# stands in for.
scheduler() {
    local end_at=$(( $(date +%s) + DURATION ))
    while [[ "$(date +%s)" -lt "$end_at" ]]; do
        sleep 5
        sqlite3 -batch "$DB" "${CMD_BASE[@]}" ${CMD_CONFIG[@]+"${CMD_CONFIG[@]}"} \
            "SELECT fractal_vectorizer_create('wl_documents', 'body', 'embedding');
             INSERT INTO wl_documents (body)
             VALUES ('scheduler-ingested note at ' || datetime('now'));
             SELECT fractal_vectorizer_process_queue(50);" >/dev/null 2>&1
    done
}

log "\nRunning ${G}${CONCURRENCY}${Z} concurrent workers for ${G}${DURATION}s${Z}..."
log "Mix: 40% sniper / 15% scout / 15% embed / 10% insert / 10% text-to-sql / 10% reason\n"

pids=()
for w in $(seq 1 "$CONCURRENCY"); do
    worker "$w" &
    pids+=("$!")
done
scheduler &
pids+=("$!")
for p in "${pids[@]}"; do wait "$p"; done

# --------------------------------------------------------------------
# Aggregate: per-operation count, failures, and p50/p95/p99 latency
# (ms) across all workers. Percentile = sorted[ceil(p * n) - 1],
# nearest-rank method -- simple, standard, no external dependency.
# --------------------------------------------------------------------
percentile() {
    # args: sorted-values-file percentile(0-100)
    local file="$1" p="$2" n idx
    n=$(wc -l < "$file")
    [[ "$n" -eq 0 ]] && { echo "-"; return; }
    idx=$(( (p * n + 99) / 100 ))
    [[ "$idx" -lt 1 ]] && idx=1
    [[ "$idx" -gt "$n" ]] && idx="$n"
    sed -n "${idx}p" "$file"
}

log "================================================================"
log "Results (${CONCURRENCY} workers x ${DURATION}s)"
log "================================================================"
printf "%-8s %8s %8s %10s %10s %10s\n" "op" "calls" "failed" "p50 ms" "p95 ms" "p99 ms"

cat "$RESULTS_DIR"/worker_*.log > "$RESULTS_DIR/all.log" 2>/dev/null || : > "$RESULTS_DIR/all.log"
total_calls=0
total_failed=0
for op in sniper scout embed insert t2s reason; do
    n=$(awk -v o="$op" '$1==o' "$RESULTS_DIR/all.log" | wc -l)
    [[ "$n" -eq 0 ]] && continue
    nfail=$(awk -v o="$op" '$1==o && $2=="fail"' "$RESULTS_DIR/all.log" | wc -l)
    awk -v o="$op" '$1==o && $2=="ok" {print $3}' "$RESULTS_DIR/all.log" | sort -n > "$RESULTS_DIR/$op.sorted"
    p50=$(percentile "$RESULTS_DIR/$op.sorted" 50)
    p95=$(percentile "$RESULTS_DIR/$op.sorted" 95)
    p99=$(percentile "$RESULTS_DIR/$op.sorted" 99)
    printf "%-8s %8s %8s %10s %10s %10s\n" "$op" "$n" "$nfail" "$p50" "$p95" "$p99"
    total_calls=$((total_calls + n))
    total_failed=$((total_failed + nfail))
done

log ""
log "Total: $total_calls calls, $total_failed failed, $(( total_calls / DURATION )) calls/sec aggregate throughput"
if [[ "$total_failed" -eq 0 ]]; then
    log "${G}No failures under this load.${Z}"
else
    log "${Y}$total_failed calls failed -- if reasoning wasn't configured, that's expected"
    log "for reason/text-to-sql/embed; anything else is a real problem worth digging into.${Z}"
fi
log "================================================================"

rm -rf "$RESULTS_DIR"
log "Workload DB left in place at $DB for inspection; remove it (plus -wal/-shm) when done."