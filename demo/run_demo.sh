#!/usr/bin/env bash
# demo/run_demo.sh
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#
# Runs every demo/*.sql content demo against the Docker demo
# container's own database, in one pass -- the "docker compose up -d;
# pull a model; run_demo.sh" button for a from-scratch look at
# everything in demo/, instead of running each file by hand.
#
# Usage (inside the demo container, matching docker-demo.md's own
# `docker compose exec demo <cmd>` invocation style):
#   docker compose exec demo /demo/run_demo.sh
#   docker compose exec demo /demo/run_demo.sh --quiet
#   docker compose exec demo /demo/run_demo.sh --only demo-vertical-fleet-logistics.sql
#   docker compose exec demo /demo/run_demo.sh --skip demo-agents.sql,enterprise-stress.sql
#   docker compose exec demo /demo/run_demo.sh --include-response-modes
#
# Scope: this is specifically the Docker demo image's workflow. It
# assumes /work/fractalsql_demo.sqlite + /work/demo_init.sql (written
# by docker/demo-entrypoint.sh from the compose FRACTALSQL_* env --
# see docs/docker-demo.md) and /demo/*.sql (COPYd by docker/Dockerfile's
# demo stage). A bare host install uses a different bootstrap snippet
# (easy_install.sh's load_fractalsql.sql) and has no /demo -- run
# demos there manually per each file's own header, or docs/docker-
# demo.md's non-Docker notes.
#
# Reasoning-dependent sections need a model pulled first (docs/docker-
# demo.md step 2); without one, those calls fail with a clean Ollama
# model-not-found error and this script counts that file as a
# non-zero-exit result, same as any other failure -- it does not
# special-case or hide that (same stance demo-workload.sh's own header
# takes).
#
# A non-zero exit from one file is a "go read its log" signal, not
# proof of a bug: sqlite3 exits non-zero on ANY runtime error during a
# session, including several files' OWN intentional demonstrations --
# a deliberate CHECK-constraint failure (demo-fractal-vector.sql), an
# unknown-metric rejection (demo-agents.sql), and the enterprise-tier-
# gated demos (demo-agents.sql's diverse_portfolios section,
# enterprise-qtl-audit.sql, enterprise-stress.sql) correctly showing
# the documented dormant path on a Community build with no
# enterprise_lib configured. Read the per-file log before assuming a
# bug.
#
# demo/response-modes.sql is SKIPPED BY DEFAULT: unlike every other
# file here, it is explicitly NOT meant to run in one `.read` pass --
# FSQL_REASONING_HTTP_RESPONSE_MODE is an env-var-only setting read
# once at plugin init, so switching modes needs a process restart with
# a new environment, not just a new SQL statement (see the file's own
# header). Running it through the main loop anyway would silently
# produce a misleading "malformed JSON" failure for the json-mode
# section, since neither code nor json mode would actually be engaged.
# Pass --include-response-modes to exercise it properly instead: each
# of its three modes then runs as a SEPARATE process with the matching
# env var set, mirroring what the file's header instructs a human to
# do by hand. That logic duplicates response-modes.sql's three SELECT
# statements inline below (same SQL, not `.read` against the file) --
# keep both in sync if that file's SQL changes.
#
# demo/demo-workload.sh is NOT part of this: that is a separate
# concurrent load/stress tool (p50/p95/p99 latency under sustained
# load), not a content demo -- see its own header.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DB="${FSQL_DEMO_DB:-/work/fractalsql_demo.sqlite}"
INIT="${FSQL_DEMO_INIT:-/work/demo_init.sql}"
SQLITE="${FSQL_SQLITE_BIN:-sqlite3}"
LOG_DIR="${FSQL_DEMO_RUN_LOG_DIR:-/tmp/fractalsql_demo_run}"
TIMEOUT_SECS="${FSQL_DEMO_RUN_TIMEOUT:-300}"

QUIET=0
ONLY=""
SKIP=""
INCLUDE_RESPONSE_MODES=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quiet)                  QUIET=1 ;;
    --only)                   ONLY="$2"; shift ;;
    --skip)                   SKIP="$2"; shift ;;
    --include-response-modes) INCLUDE_RESPONSE_MODES=1 ;;
    -h|--help)
      sed -n '2,56p' "$0"; exit 0 ;;
    *) echo "run_demo.sh: unknown arg: $1 (try --help)" >&2; exit 2 ;;
  esac
  shift
done

if [[ ! -f "$DB" || ! -f "$INIT" ]]; then
  echo "run_demo.sh: expected $DB and $INIT (the Docker demo container's" >&2
  echo "own database + bootstrap snippet). Run this inside the demo" >&2
  echo "container -- docker compose exec demo /demo/run_demo.sh -- not on" >&2
  echo "a bare host install (see this script's own header)." >&2
  exit 2
fi

mkdir -p "$LOG_DIR"

# response-modes.sql is handled separately below, never through the
# main loop (see this script's own header for why).
ALWAYS_SKIP="response-modes.sql"

IFS=',' read -r -a only_list  <<< "$ONLY"
IFS=',' read -r -a skip_list  <<< "$SKIP"

should_run() {
  local base="$1"
  [[ "$base" == "$ALWAYS_SKIP" ]] && return 1
  if [[ -n "$ONLY" ]]; then
    for o in "${only_list[@]}"; do [[ "$base" == "$o" ]] && return 0; done
    return 1
  fi
  for s in "${skip_list[@]}"; do [[ -n "$s" && "$base" == "$s" ]] && return 1; done
  return 0
}

pass=0
fail=0
declare -a failed_files=()

for sqlfile in "$HERE"/*.sql; do
  base="$(basename "$sqlfile")"
  should_run "$base" || continue
  [[ "$QUIET" -eq 1 ]] || echo "=== $base ==="
  log="$LOG_DIR/$base.log"
  if timeout "$TIMEOUT_SECS" "$SQLITE" "$DB" -init "$INIT" ".read $sqlfile" \
       > "$log" 2>&1
  then
    pass=$((pass + 1))
    [[ "$QUIET" -eq 1 ]] || echo "  ok ($log)"
  else
    fail=$((fail + 1))
    failed_files+=("$base")
    [[ "$QUIET" -eq 1 ]] || echo "  exit != 0 -- see $log (may be an intentional demonstration; read it before assuming a bug)"
  fi
done

if [[ "$INCLUDE_RESPONSE_MODES" -eq 1 ]]; then
  [[ "$QUIET" -eq 1 ]] || echo "=== response-modes.sql (text/code/json, each its own process + env) ==="
  for mode in text code json; do
    log="$LOG_DIR/response-modes.$mode.log"
    case "$mode" in
      text)
        sql="SELECT fractal_reason('summarize what happened in demo_alerts in one sentence', (SELECT json_group_array(json_object('service', service, 'message', message, 'severity', severity, 'created_at', created_at)) FROM (SELECT service, message, severity, created_at FROM demo_alerts)));"
        ;;
      code)
        sql="SELECT fractal_reason('write a SQLite query that selects all rows from demo_alerts where severity is critical');"
        ;;
      json)
        sql="SELECT json(fractal_reason('return a JSON object with keys critical_count, warning_count, and info_count summarizing the severities present', (SELECT json_group_array(json_object('severity', severity)) FROM (SELECT severity FROM demo_alerts)))) AS parsed_json;"
        ;;
    esac
    if FSQL_REASONING_HTTP_RESPONSE_MODE="$mode" timeout "$TIMEOUT_SECS" \
         "$SQLITE" "$DB" -init "$INIT" "$sql" > "$log" 2>&1
    then
      pass=$((pass + 1))
      [[ "$QUIET" -eq 1 ]] || echo "  $mode: ok ($log)"
    else
      fail=$((fail + 1))
      failed_files+=("response-modes.sql:$mode")
      [[ "$QUIET" -eq 1 ]] || echo "  $mode: exit != 0 -- see $log"
    fi
  done
elif [[ "$QUIET" -eq 1 ]]; then
  :
else
  echo "(skipped response-modes.sql -- needs demo_alerts from demo.sql plus a"
  echo " per-mode process restart; pass --include-response-modes to run it"
  echo " properly, or see the file's own header to run it by hand)"
fi

echo
echo "=== $pass ok, $fail non-zero exit, logs in $LOG_DIR ==="
if [[ "$fail" -gt 0 ]]; then
  echo "Non-zero-exit files (read the log before assuming a bug -- see this"
  echo "script's own header for the files known to error by design):"
  printf '  %s\n' "${failed_files[@]}"
fi

exit 0
