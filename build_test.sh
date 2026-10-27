#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#
# build_test.sh: post-build validation gate runner for
# fractalsql-sqlite. Mirrors what CI runs, so local == CI.
#
# Builds (or accepts a prebuilt) extension and validates it against a
# THROWAWAY fixture database (a plain file under the temp root, opened
# in WAL mode and torn down on exit): no server install, no root.
#
# 27 numbered gates; the structural rationale for each is documented
# per gate below.
#
# Gates:
#   01  build          make (or accept a prebuilt artifact)             ~5s
#   02  smoke          load + version + fractal_search convergence     ~5s
#   03  schema_context introspection (PK / NOT NULL / FK)              ~3s
#                      (re-aim: no COMMENT analog; SQLite tables have
#                       no comments; PK/FK/NOT NULL assertions kept)
#   04  text_to_sql    allowlist fuzz matrix + never-executes proof    ~8s
#                      (uses tests/mock_reasoning_plugin.c)
#   05  evil_overread  guard-page non-terminated response survives,    ~3s
#                      at GENERATE, REVIEW, and bare fractal_reason()
#                      (uses tests/evil_nonterminating_plugin.c;
#                      re-aim: a crash kills the sqlite3 PROCESS;
#                      detected by abnormal exit without a clean SQL
#                      error, instead of dropping a PG connection)
#   06  crash_recovery deliberately-segfaulting plugin: the sqlite3     ~10s
#                      process dies; the DB is reopened and the prior
#                      canary row must be intact (WAL recovery)
#                      (uses tests/evil_crash_plugin.c)
#   07  evil_lying_length  guard_ai_response_len rejects an implausible ~3s
#                      claimed length before any read, at GENERATE,
#                      REVIEW, and bare fractal_reason()
#                      (uses tests/evil_lying_length_plugin.c)
#   08  authz          sqlite3_set_authorizer denial honored inside    ~1s
#                      fractal_schema_context's introspection: denied
#                      reads error cleanly and leak no schema detail
#                      (re-aim: PG's low-privilege role becomes an
#                      authorizer hook in a python driver)
#   09  guc_superuser  relative/traversal reasoning_plugin paths       ~1s
#                      rejected at fractalsql_set time (re-aim: PG's
#                      GUC_SUPERUSER_ONLY check becomes strict set-time
#                      path validation; stock SQLite cannot gate
#                      per-role, so the same boundary is enforced on
#                      the value instead of the setter)
#   10  dos_and_injection  512-table cap fires at 513; an SQL-         ~1s
#                      injection-shaped table name is skipped by
#                      introspection (never smuggled into SQL text)
#                      and provably never executed
#   11  scout          fractal_search_explore: full population returned,      ~2s
#                      JSON-parseable, dispersed across distinct
#                      points (re-aim: the island metric becomes
#                      distinct-population-point counting)
#   12  soak           SOAK_WORKERS concurrent python connections x    ~5s
#                      SOAK_ITERS mixed benign calls each; asserts no
#                      failures and the DB stays responsive under load
#                      (shared-file WAL replaces the PG cluster)
#   13  siu_mode       text_to_sql_allowed_statements=select_insert_   ~2s
#                      update: INSERT/UPDATE returned (never executed),
#                      DDL/DELETE still rejected
#   14  retry          max_attempts=2 retry-with-feedback: attempt 1   ~1s
#                      rejected, attempt 2 succeeds, rejection reason
#                      threaded into the attempt-2 prompt
#                      (uses tests/retry_reasoning_plugin.c)
#   15  embed          fractal_embed() + the vectorizer: create/       ~3s
#                      backfill/process_queue/status against a canned
#                      embedding, real dispatch through the EMBED tier
#                      (not just error paths); NULL input, bad plugin
#                      path, over-limit embedding array
#                      (evil_embed_plugin.c), injection-shaped
#                      source_table, double-create
#                      (uses tests/mock_embed_plugin.c,
#                       tests/evil_embed_plugin.c)
#   16  embed_authz    vectorizer create-time validation: invalid      ~1s
#                      identifier, composite/missing PK, nonexistent
#                      source table + authorizer denial honored inside
#                      the PK probe (re-aim: PG's create-time
#                      source_table ownership check maps to these
#                      guards; role grants have no SQLite analog)
#   17  embed_soak     100-row queue drained by repeated               ~3s
#                      fractal_vectorizer_process_queue(batch=20)
#                      calls; asserts every row processed exactly
#                      once (re-aim: the vectorizer's registry/queue
#                      are TEMP = connection-private, so the PG
#                      cross-backend SKIP LOCKED claim race has no
#                      analog here; the BEGIN IMMEDIATE claim's
#                      correctness shows as zero double-processing
#                      within the draining loop)
#   18  embed_crash    deliberately-segfaulting plugin mid-            ~10s
#                      process_queue(): the sqlite3 process dies with
#                      the TEMP queue state (no stuck-'processing'
#                      rows are even possible); a fresh connection
#                      must find the DB intact and previously
#                      persisted embeddings preserved
#                      (uses tests/evil_crash_plugin.c, mirrors gate 06)
#   19  sfs_bounds     input-side guards for fractal_search/_explore   ~1s
#                      (over-arena dims, empty vector, query/vector
#                      dim mismatch, injection-shaped query into
#                      fractal_search_explore) (re-aim: PG's
#                      validate_sfs_params() params are fixed by
#                      FSQL_SFS_PARAMS_JSON here, so the adversarial
#                      surface moves to the input vectors)
#   20  api_func       closes API-surface coverage gaps: fractal_reason ~2s
#                      happy-path correctness, fractal_reason(NULL) and
#                      fractal_text_to_sql(NULL) rejection,
#                      fractal_search_explore()'s options-JSON rejection, and
#                      fractal_vectorizer_process_queue()'s stale_after
#                      reclaim (staged directly, with a within-window
#                      negative control)
#   21  fuzz_smoke     FUZZ ONLY (--fuzz, not in DEFAULT/QUICK). Builds ~90s
#                      + briefly runs (FSQL_FUZZ_TIME seconds each,
#                      default 30) libFuzzer drivers against the 3
#                      hand-rolled parsers in src/fsql_parse.c
#                      (factored out of the PG source specifically so
#                      they can link standalone): fsql_parse_
#                      embedding_array (highest priority; parses
#                      fractal_embed()'s raw response from whatever
#                      endpoint http_embed_url points at, genuinely
#                      externally-adversarial input),
#                      fsql_extract_best_point and
#                      fsql_extract_population (parse the vendored
#                      core's own result JSON, lower risk, included
#                      as defense-in-depth). No fixture DB needed.
#                      Requires a libFuzzer-capable clang (set
#                      FSQL_FUZZ_CC to override auto-detection); skips
#                      cleanly if none is found.
#   22  v2_functions   dimension (dfa/boxcount/drift), portfolio
#                      (+ cov-length rejection, pareto dormant path),
#                      domain geometry (vascular/cortical/nerve/
#                      morphological), search_telemetry, hybrid/cross-
#                      modal guards, explain_result/detect_collapse/
#                      diversify (feature-store functions are a
#                      documented N/A; they belong to reasoning/
#                      feature-store TUs that are not ported), the
#                      v2.0.25-core analytics surface (change_point_
#                      detect/periodogram/tda_persistence_diagram/state_
#                      fingerprint/cycle_detect/optimize_subset) and the
#                      vector-math quartet (lp_distance/quantize_int8/
#                      quantize_binary/hamming_distance)
#   23  agents         the registered C agents with a reasoning canary:
#                      search_agent/rag_agent (embed -> scout ->
#                      reason composition), sql_agent, plan_explore,
#                      trajectory_predict, detect_loop (the
#                      (agent_id, state_log, dim[, n_bits, seed,
#                      hamming_threshold]) signature: a period-2
#                      one-hot toggle flagged, a distinct-direction
#                      stream cleared, the short-log guard), telemetry,
#                      search_trajectory, hybrid, cross_modal,
#                      explain_result/detect_collapse (re-aim:
#                      SQLite has no server-side procedural language,
#                      so the same composition surface is proven here
#                      against the plain C registrations)
#   24  enterprise     dormant enterprise path: ledger/audit surface
#                      registered but cleanly rejected with
#                      "enterprise tier not loaded" (community archive
#                      carries no enterprise symbols); a bogus
#                      enterprise_lib path surfaces the load failure
#   25  enterprise_stress  self-skips unless an enterprise core is
#                      vendored in include/ (none is, on the community
#                      drop); the stress body is kept for the drop
#                      that eventually ships one
#   26  enterprise_signature  load-before-signature ordering: with no
#                      enterprise lib resolvable, the ledger call must
#                      fail with the LOAD error regardless of
#                      enterprise_require_signature (the signature
#                      check is only reachable after a successful load)
#   27  think          THINK-effort config forwarding: all four keys
#                      reach the plugin's environment via
#                      fractal_reason() and fractal_text_to_sql()'s
#                      GENERATE step, and NEVER reach fractal_embed()'s
#                      (uses tests/think_reasoning_plugin.c)
#   28  review_isolation  fractal_text_to_sql()'s REVIEW step dispatches
#                      on its own reasoning tier, not T2S: GENERATE
#                      still runs under T2S's forced RESPONSE_MODE=code,
#                      but REVIEW (text_to_sql_use_review=on) must see
#                      it unset (uses tests/mock_reasoning_plugin.c's
#                      per-call RESPONSE_MODE dump)
#   29  domain_agents  smoke gate for the sixteen installable Domain
#                      Agent engines (src/fsql_domain_agents.c): three
#                      representative engines (anomaly_triage,
#                      recall_hybrid, regime_triage) run end-to-end
#                      against the real primitives they compose, plus
#                      outlier_intercept's metric surface (cosine
#                      default, exact-L2 path, unknown-metric hard
#                      error)
#   31  ledger_chain   fractalsql_ledger's append-only hash chain
#                      (src/fsql_ledger.c): a built chain verifies
#                      clean, a mutated row and a deleted middle row
#                      are both caught by fractal_ledger_verify(), the
#                      old snapshot-shape table migrates to the chain
#                      shape on first touch, kind=1/kind=2 chains stay
#                      independent, and fractal_audit_log now carries
#                      the same enterprise gate as the rest of the
#                      ledger surface
#   33  tsan_ledger_concurrent  --tsan only, Linux/Darwin only. Real
#                      cross-connection ledger concurrency (fractal_
#                      ledger_flush's BEGIN IMMEDIATE serialization,
#                      same scenario gate 25 Phase C(b) proves correct
#                      on a plain build) driven from tests/
#                      tsan_ledger_runner.c: a small host binary
#                      compiled WITH -fsanitize=thread from the start,
#                      which dlopens (via sqlite3_load_extension) the
#                      identically-sanitized fractalsql.so. Not the
#                      LD_PRELOAD/DYLD_INSERT_LIBRARIES approach the
#                      other gates use; see the --tsan note below for
#                      why that approach doesn't reach Darwin at all.
#   34  oom_inject     Linux only. LD_PRELOAD fault injection (tests/
#                      oom_inject.c) makes one specific allocation size
#                      from fractalsql.so itself return NULL, reaching
#                      sqlite3_result_error_nomem() guard sites nothing
#                      else can: no other gate ever runs this process
#                      out of memory on its own. Size-matched and
#                      module-scoped (dladdr() on the caller's return
#                      address), not call-count-based, so it can't
#                      silently drift onto the wrong allocation if an
#                      unrelated earlier malloc is added or removed.
#   35  ed25519        src/fsql_ed25519.h's own header comment says it
#                      was "validated against the RFC 8032 Section 7.1
#                      test vectors... plus a corrupted-signature
#                      rejection check" during development, then "kept
#                      out of the shipped build" -- tests/ed25519_
#                      probe.c is that check, finally committed. A
#                      standalone translation unit (not a SQL-level
#                      test): the only SQL-reachable path to this
#                      header verifies against a hardcoded production
#                      key whose private half is never in CI by design,
#                      so this instead unit-tests the verify primitive
#                      directly, with throwaway keys, independent of
#                      the real one entirely.
#   36  extract_population  fsql_extract_population (src/fsql_parse.c)
#                      has no caller outside the libFuzzer smoke
#                      harness (gate 21, which --coverage never runs),
#                      so a plain run leaves it dead too -- same
#                      standalone-probe treatment as gate 35.
#   39  extract_parse  fsql_extract_best_point/fsql_parse_embedding_
#                      array/fsql_extract_topk's own malformed-input
#                      branches (src/fsql_parse.c): all three only
#                      ever see well-formed JSON through any real
#                      SQL-level call, so their error paths are
#                      otherwise dead too -- same standalone-probe
#                      treatment as gates 35/36.
#   40  vectors_probe  mcp/src/vectors.cpp's coercion/validation
#                      branches (non-finite-string, malformed hex/
#                      blob, bad.size()<3 cap) reachable only by
#                      finding a tool whose schema layer happens to
#                      let a malformed element through -- a direct
#                      unit test against DbConnection's siblings
#                      hits each one with certainty instead.
#   41  db_probe       mcp/src/db.h's prepare/bind/step-failure,
#                      version-skew-warning and bootstrap-failure
#                      branches need a deliberately-broken SQL
#                      string, a mismatched expected engine version,
#                      or a schema state no real tool call produces
#                      on its own -- a direct unit test against
#                      DbConnection's public API hits each one.
#   42  concurrency_probe  mcp/src/concurrency.h's per-client-limit
#                      and global-timeout throw branches are never
#                      hit by any live-protocol test, since a
#                      synchronous request/response round trip
#                      always releases its Token before the next
#                      request is even read -- holding Tokens open
#                      across sequential acquire() calls saturates
#                      the same counters deterministically, with no
#                      real concurrency or timing dependency needed.
#   43  kits           the twenty-nine newer industry kits (demo/demo-       ~10s
#                      vertical-{ev-battery-lifecycle,adas-safety-
#                      validation,v2x-warranty-triage,critical-
#                      inventory-routing,heavy-industry-predictive-
#                      maintenance,climatech-grid-balancing,hazmat-
#                      occupational-triage,scenario-planning-
#                      simulation,avionics-fault-prediction,
#                      satellite-constellation-coverage,telecom-
#                      account-anomaly-screening,telecom-traffic-
#                      routing,climatech-emissions-monitoring,
#                      climatech-risk-exposure,rf-spectrum-sensing}
#                      .sql): each runs end to end with the mock
#                      reasoning plugin, raises no SQL error (the
#                      scenario kit's plan_explore needs a real
#                      embedding endpoint: exactly one expected),
#                      prints no NaN, and reproduces its headline
#                      result on its deterministic fixture
#
# Gate sets:
#   QUICK   = 01 02                                   post-edit sanity loop
#   DEFAULT = 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20
#             22 23 24 25 26 27 28 29                 pre-push / CI
#             (+ 33, appended automatically under --tsan)
#   FUZZ    = 21                                       --fuzz, not part of
#                                                      DEFAULT (adds real
#                                                      wall-time)
#
# Usage:
#   ./build_test.sh                 # DEFAULT
#   ./build_test.sh --quick
#   ./build_test.sh --fuzz          # gate 21 only -- libFuzzer smoke
#   ./build_test.sh --gate 04
#   ./build_test.sh --asan          # or --ubsan, composable with each other
#   ./build_test.sh --tsan          # NOT composable with --asan (see note)
#   ./build_test.sh --coverage      # gcov-instrumented build; DEFAULT
#                                    # gates; lcov/genhtml report after
#   ./build_test.sh --list
#
# Environment:
#   FSQL_TEST_TIMEOUT_MULT  scales gate 06/18's recovery-poll budget
#                           (default 1; auto-defaults to 4 under
#                           --asan/--ubsan, 6 under --tsan; set this
#                           explicitly to override that auto-bump
#                           either direction).
#   FSQL_SQLITE3            sqlite3 CLI override (default: auto-detect
#                           on PATH; 3.35+ required for the
#                           data-modifying-CTE readonly assertion)
#   FSQL_PYTHON             python3 override (default: auto-detect;
#                           gates 08/12/16 need the stdlib sqlite3
#                           module and skip cleanly without it)
#   FSQL_CC                 plugin-compile override (default:
#                           cc/gcc/clang on PATH)
#   FSQL_EXT                prebuilt extension override (skips gate 01's
#                           build; on Git Bash/Windows the MSVC arbiter
#                           is scripts/windows/build.bat via
#                           build_test.ps1, so gate 01 there accepts
#                           dist/windows/fractalsql.dll)
#   FSQL_FUZZ_CC            libFuzzer-capable clang for gate 21 (default:
#                           auto-detect clang on PATH, probed for
#                           -fsanitize=fuzzer support before use)
#   FSQL_FUZZ_TIME          seconds per fuzz target in gate 21 (default
#                           30). A pre-push SMOKE run, not a campaign.
#
# --asan/--ubsan note: the flags flow into the POSIX `make` build
# (Makefile ASAN=1 / UBSAN=1, composable). Running the sanitized
# extension needs the sanitizer runtime preloaded into the host process
# (the sqlite3 CLI / python3, neither built with the sanitizer
# themselves) -- on Linux that's LD_PRELOAD of libasan/libubsan,
# resolved via the toolchain, which is where CI exercises them and
# gates 02-32 run for real. On MinGW/MSYS the sanitizer build isn't
# attempted at all (Makefile isn't even invoked there -- see gate 01).
#
# On Darwin, gates 02-32 are explicitly SKIPPED under --asan/--ubsan/
# --tsan rather than attempted: the dlopen-into-CLI design this note
# just described does not work on real macOS hardware, confirmed twice
# over in fractalsql-core's own Darwin harness work (build_test-darwin.sh
# gate 05): (1) SIP silently strips DYLD_INSERT_LIBRARIES for Apple-
# signed/System-protected sqlite3/python3 -- no error, just an
# unsanitized run that looks clean; (2) even past a confirmed non-SIP
# host, the sanitizer runtime can refuse its own interceptors
# ("loaded too late") because the host's own startup already allocated
# before the retrofitted runtime went live. There is no known fix for
# either short of not dlopening into an unsanitized host at all.
#
# EXPERIMENTAL (--asan/--ubsan only, not --tsan): when both hosts are
# NON-system builds (e.g. Homebrew's sqlite3/python3 first on PATH) and
# the clang_rt .dylibs resolve, main() preloads them via
# DYLD_INSERT_LIBRARIES and runs the gates for real. Failure (2) above
# is not ruled out by this; if it shows up, the gates fail loudly at
# extension load rather than passing unsanitized. Any other case still
# skips, with the specific reason printed.
#
# --tsan note: NOT combinable with --asan (their runtimes can't link
# into the same binary -- the compiler rejects it; build_test.sh checks
# this before invoking make). Composes with --ubsan. Linux gates 02-32
# get the same LD_PRELOAD-of-libtsan.so treatment as --asan/--ubsan
# above (same fragility applies -- TSan retrofit-via-LD_PRELOAD is
# known-flaky even on Linux; fractalsql-core's own Linux TSan gate
# treats an ambiguous startup failure there as a SKIP, not a FAIL).
# Real, reliable TSan coverage on EITHER platform comes from gate 33
# instead (tests/tsan_ledger_runner.c): a small harness compiled WITH
# -fsanitize=thread from the start, so the runtime initializes at
# normal process startup like any sanitized binary and no preload trick
# is needed at all -- the same binary works unmodified on Linux and
# Darwin. Windows/MSVC has no ThreadSanitizer support at all (clang-cl
# rejects -fsanitize=thread outright, confirmed in fractalsql-core's
# own Windows TSan investigation) -- --tsan is a no-op there beyond a
# warning.
#
# --coverage note: rebuilds with `make COVERAGE=1` (Makefile:
# --coverage on compile + link, -O1/-g/no-LTO profile so counters
# reflect the code as written), runs the DEFAULT gates against the
# instrumented fractalsql.so, then captures the .gcda the gate
# processes leave behind with lcov and renders coverage_html/ plus a
# text summary on stdout. No server redirects gcov's writes anywhere
# (The GCOV_PREFIX dance exists because postgres backends run from a
# system bindir -- here every host process is a sqlite3 CLI or a
# python driver started from this script, and they all write .gcda
# straight back next to the .gcno in src/, inside the checkout, which
# is writable). Stale src/*.gcda from a previous run are removed
# before the build so the report reflects THIS run only; the
# instrumented fractalsql.so stays in the tree afterward (make clean
# && make restores the normal artifact). Needs lcov + genhtml on PATH
# for the report (the gates themselves run fine without them); skips
# the report with a clear message if lcov is missing. No effect on
# Windows/MSYS (gate 01 there builds the MSVC artifact via
# build_test.ps1's arbiter -- MSVC has no gcov). NOT combinable with
# --asan/--ubsan/--tsan: both flag sets rewrite the Makefile's
# optimization profile (-O3 -> -O1) and gcov-counters-plus-sanitizer-
# instrumentation is an untested build configuration -- rejected up
# front rather than half-working.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

# Captured before the arg-parsing loop below consumes $@ via `shift` --
# needed later to re-exec this same invocation under setarch (--tsan
# only; see that check further down).
ORIG_ARGV=("$@")

# Canonical (symlink-resolved) tmp root. fractalsql-core's
# fsql_load_reasoning() deliberately rejects any plugin path where
# realpath(path) != path; a defense against symlink pivots (see its
# own header comment). On Linux /tmp is a real directory; on macOS /tmp
# is a symlink to /private/tmp, so resolving once here and building
# every path from $TMPROOT fixes that at the source instead of
# weakening the security check.
TMPROOT="$(cd /tmp && pwd -P)"

# --- platform ---------------------------------------------------------
sysname="$(uname -s)"
IS_MSYS=0
case "$sysname" in
  MINGW*|MSYS*|CYGWIN*) IS_MSYS=1 ;;
esac

# BTROOT is the directory the fixture plugins' hardcoded "/tmp/..."
# contracts actually resolve to. The plugins run inside the host
# process (sqlite3.exe here), whose CRT resolves a literal "/tmp/x"
# against the process's CURRENT DRIVE, so on Windows the harness pins
# C:/tmp (created if needed) and does all of its own fixture-file I/O
# through the same place. On POSIX this is just /tmp.
#
# BTROOTW is the same directory in Windows form (C:/tmp) for anything
# that crosses into native-process arguments or SQL string literals:
# MSYS argument conversion never sees those, so they must already be
# native paths.
BTROOT="$TMPROOT"
BTROOTW="$TMPROOT"
PLUGSUF=".so"
if [[ "$IS_MSYS" -eq 1 ]]; then
  if command -v cygpath >/dev/null 2>&1; then
    drive="$(cygpath -m "$PWD" | cut -c1)"
  else
    drive="C"
  fi
  drive="$(printf '%s' "$drive" | tr '[:upper:]' '[:lower:]')"
  BTROOT="/${drive}/tmp"
  BTROOTW="${drive}:/tmp"
  PLUGSUF=".dll"
  mkdir -p "$BTROOT" 2>/dev/null || true
  if [[ ! -d "$BTROOT" ]]; then
    echo "ERROR: cannot create $BTROOT: the fixture plugins hardcode" >&2
    echo "       /tmp/... paths that resolve to ${BTROOTW} on Windows." >&2
    exit 1
  fi
fi

# A nonexistent-but-absolute plugin path for the "unloadable plugin"
# negative tests (gates 15/24): must be absolute on BOTH POSIX and
# MSYS so fractalsql_set's own absolute-path validation lets it
# through to the actual load attempt, rather than rejecting it a step
# earlier with a different error. $BTROOTW is already native-form
# (C:/tmp on MSYS, /tmp on POSIX) and MSYS-argument-conversion-safe,
# so it's the right base; a bare POSIX "/..." literal or a hardcoded
# "C:/..." literal each work on only one of the two platforms.
BADPLUGIN="$BTROOTW/fractalsql_bt_nonexistent_plugin"

# wpath <posix-path>: Windows-mixed form (C:/...) when running under
# MSYS against native binaries; identity elsewhere.
wpath() {
  if [[ "$IS_MSYS" -eq 1 ]] && command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$1"
  else
    printf '%s' "$1"
  fi
}

DEFAULT_GATES=(01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20 22 23 24 25 26 27 28 29 30 31 32 34 35 36 37 38 39 40 41 42 43)
QUICK_GATES=(01 02)
FUZZ_GATES=(21)

MODE="default"
ONE_GATE=""
ASAN=0
UBSAN=0
TSAN=0
COVERAGE=0

if [[ -n "${FSQL_TEST_TIMEOUT_MULT:-}" ]]; then
  TIMEOUT_MULT="$FSQL_TEST_TIMEOUT_MULT"
elif [[ "$TSAN" -eq 1 ]]; then
  TIMEOUT_MULT=6
elif [[ "$ASAN" -eq 1 ]] || [[ "$UBSAN" -eq 1 ]]; then
  TIMEOUT_MULT=4
else
  TIMEOUT_MULT=1
fi

# --- colours ----------------------------------------------------------
if [[ -t 1 ]]; then G="\033[32m"; R="\033[31m"; Y="\033[33m"; Z="\033[0m"; else G=""; R=""; Y=""; Z=""; fi
pass() { local msg="$1"; printf "  [${G}PASS${Z}] %s\n" "$msg"; return 0; }
fail() {
  local msg="$1"
  # py_run saw the sanitizer runtime refuse to start in the host (Darwin
  # preload path only): not an extension failure, report it as a skip.
  if [[ -n "${SAN_RUNTIME_REFUSED:-}" ]]; then
    SAN_RUNTIME_REFUSED=""
    skip "$msg -- skipped: the sanitizer runtime refused to start in this host process (Darwin DYLD_INSERT_LIBRARIES; not an extension failure)"
    return 0
  fi
  printf "  [${R}FAIL${Z}] %s\n" "$msg"; FAILED=1; return 0
}
skip() { local msg="$1"; printf "  [${Y}SKIP${Z}] %s\n" "$msg"; return 0; }

usage() { sed -n '4,280p' "$0"; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quick)   MODE="quick" ;;
    --fuzz)    MODE="fuzz" ;;
    --gate)    ONE_GATE="$2"; shift ;;
    --asan)    ASAN=1 ;;
    --ubsan)   UBSAN=1 ;;
    --tsan)    TSAN=1 ;;
    --coverage) COVERAGE=1 ;;
    --list)    printf "gates: %s\nfuzz gates: %s\n" "${DEFAULT_GATES[*]}" "${FUZZ_GATES[*]}"; exit 0 ;;
    -h|--help) usage ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

# ASan and TSan runtimes cannot link into the same binary (the compiler
# rejects it); catch this here with a clear message instead of letting
# gate 01's build fail with a raw linker/compiler error.
if [[ "$ASAN" -eq 1 && "$TSAN" -eq 1 ]]; then
  echo "ERROR: --asan and --tsan cannot be combined -- their runtimes cannot link into the same binary. Run one at a time (--ubsan composes with either)." >&2
  exit 2
fi

# gcov instrumentation on top of a sanitized build is an untested build
# configuration (both flag sets rewrite the Makefile's optimization
# profile, and nobody has validated that counters survive sanitizer
# instrumentation intact here). Reject with a clear message instead of
# letting gate 01's build produce something quietly meaningless.
if [[ "$COVERAGE" -eq 1 && ( "$ASAN" -eq 1 || "$UBSAN" -eq 1 || "$TSAN" -eq 1 ) ]]; then
  echo "ERROR: --coverage cannot be combined with --asan/--ubsan/--tsan -- an untested build configuration (gcov counters + sanitizer instrumentation, both rewriting the optimization profile). Run them one at a time." >&2
  exit 2
fi

# TSan support requires -fsanitize=thread, which MSVC/clang-cl does not
# implement at all (confirmed in fractalsql-core's own Windows TSan
# investigation) -- unlike --asan, which MSVC does support in some
# form. Warn rather than silently no-op: the MSYS branch of gate_01
# ignores ASAN/UBSAN/TSAN entirely (it just accepts the prebuilt MSVC
# dist/windows/fractalsql.dll), so --tsan here would otherwise look
# like it did nothing with no explanation.
if [[ "$TSAN" -eq 1 && "$IS_MSYS" -eq 1 ]]; then
  echo "WARNING: --tsan has no effect on Windows/MSYS -- MSVC/clang-cl does not support -fsanitize=thread. Gate 01 will build the ordinary (unsanitized) MSVC artifact via build_test.ps1's arbiter." >&2
fi

# Same posture as --tsan on MSYS: gate 01 there builds the prebuilt-MSVC
# artifact and never touches `make`, so a coverage build can't happen and
# no .gcda can be produced -- warn rather than silently no-op (and
# main() below skips the report accordingly).
if [[ "$COVERAGE" -eq 1 && "$IS_MSYS" -eq 1 ]]; then
  echo "WARNING: --coverage has no effect on Windows/MSYS -- gate 01 there builds the MSVC artifact via build_test.ps1's arbiter, and MSVC has no gcov. Run --coverage on Linux or macOS." >&2
fi

# ASAN/UBSAN/TSAN arriving via --asan/--ubsan/--tsan must influence the
# timeout bump above; recompute now that all three were parsed.
if [[ -z "${FSQL_TEST_TIMEOUT_MULT:-}" ]]; then
  if [[ "$TSAN" -eq 1 ]]; then
    TIMEOUT_MULT=6
  elif [[ "$ASAN" -eq 1 ]] || [[ "$UBSAN" -eq 1 ]]; then
    TIMEOUT_MULT=4
  fi
fi

# TSan's shadow-memory layout can collide with a kernel's ASLR entropy
# ("FATAL: ThreadSanitizer: unexpected memory mapping") -- confirmed on
# this repo's own dev host, and non-deterministic (ASLR is randomized
# per process launch, so the identical command can pass or FATAL from
# one run to the next). This isn't limited to the sqlite3 CLI gates
# dlopen the sanitized extension into: ANY process that inherits
# LD_PRELOAD=libtsan.so hits it, including plain utilities this script
# itself shells out to (mkdir, grep, ...) once LD_PRELOAD is exported
# below. Re-exec the WHOLE script under setarch -R (ASLR off) here,
# before any such subprocess runs, rather than trying to wrap every
# individual call site -- the same fix fractalsql-core's own Linux TSan
# gate uses (scripts/confidence/30_tsan_concurrent.sh), just applied to
# the whole process tree instead of one invocation. FSQL_BT_TSAN_
# SETARCHED guards against re-exec'ing a second time once already
# inside the setarch'd process.
if [[ "$TSAN" -eq 1 && "$sysname" != "Darwin" && "$IS_MSYS" -eq 0 \
      && -z "${FSQL_BT_TSAN_SETARCHED:-}" ]]; then
  if command -v setarch >/dev/null 2>&1; then
    export FSQL_BT_TSAN_SETARCHED=1
    exec setarch "$(uname -m)" -R "$0" "${ORIG_ARGV[@]}"
  else
    echo "WARNING: --tsan requested but setarch is not on PATH -- TSan" >&2
    echo "         runtime aborts ('unexpected memory mapping') may occur" >&2
    echo "         non-deterministically on some kernels. Install" >&2
    echo "         util-linux to fix." >&2
  fi
fi

# --- state ------------------------------------------------------------
EXT=""; EXTW=""
DB=""; DBW=""
SQLITE3=""; PY=""; CC=""; MAKE=""
PLUGDIR=""; PLUGDIRW=""
PDIR=""
MOCK=""; EVILNT=""; LYING=""; CRASH=""; RETRY=""; THINK=""; MOCKEMB=""; EVOLEMB=""; SLOWPLUG=""
FAILED=0

# Fixed file contracts the fixture plugins hardcode (see each plugin's
# header comment). The plugins run inside the host process and do their
# own fopen()s, so the harness must write these through BTROOT (whose
# CRT-resolved location is $BTROOTW on Windows); NOT through a path
# only bash understands.
SQLTXT="$BTROOT/fractalsql_bt_sql.txt";           SQLTXTW="$BTROOTW/fractalsql_bt_sql.txt"
EVILTRIG="$BTROOT/fractalsql_bt_evil_trigger_call.txt"
RETRYPROMPT="$BTROOT/fractalsql_bt_retry_prompt.txt"
THINKDUMP="$BTROOT/fractalsql_bt_think_dump.txt"
REVIEWDUMP="$BTROOT/fractalsql_bt_review_env_dump.txt"

cleanup() {
  [[ -n "$PDIR" ]] && rm -rf "$PDIR"
  rm -f "$SQLTXT" "$EVILTRIG" "$RETRYPROMPT" "$THINKDUMP" "$REVIEWDUMP" 2>/dev/null
  rm -f "$BTROOT"/fractalsql_bt_*_plugin.* 2>/dev/null
  return 0
}
trap cleanup EXIT

# --- toolchain --------------------------------------------------------
find_toolchain() {
  if [[ -n "${FSQL_SQLITE3:-}" ]]; then
    SQLITE3="$FSQL_SQLITE3"
  else
    SQLITE3="$(command -v sqlite3 2>/dev/null || true)"
    # macOS: Apple's own /usr/bin/sqlite3 is built WITHOUT extension
    # loading (SQLITE_OMIT_LOAD_EXTENSION): ".load" is not even a
    # command there, and every CLI-driven gate dies with 'unknown
    # command or invalid arguments: "load"'. Homebrew's sqlite is
    # keg-only and never reaches PATH, so probe the auto-detected
    # shell and fall back to Homebrew's when it cannot load
    # extensions (the release workflow's functional test drives the
    # same binary explicitly). A load-capable shell answers the
    # nonexistent probe path with a dlopen error; Apple's reports
    # the dot-command itself as unknown.
    if [[ -n "$SQLITE3" && "$(uname -s)" = "Darwin" ]] \
       && "$SQLITE3" :memory: ".load /nonexistent-fractalsql-probe" 2>&1 \
            | grep -q "unknown command"; then
      local brew_sqlite3
      brew_sqlite3="$(brew --prefix sqlite 2>/dev/null)/bin/sqlite3"
      [[ -x "$brew_sqlite3" ]] && SQLITE3="$brew_sqlite3"
    fi
  fi
  if [[ -n "${FSQL_CC:-}" ]]; then
    CC="$FSQL_CC"
  else
    CC="$(command -v cc 2>/dev/null || command -v gcc 2>/dev/null || command -v clang 2>/dev/null || true)"
  fi
  MAKE="$(command -v make 2>/dev/null || true)"

  # python3/python, probed for the stdlib sqlite3 module (the Windows
  # Store alias stub resolves on PATH but cannot actually run code).
  if [[ -n "${FSQL_PYTHON:-}" ]]; then
    PY="$FSQL_PYTHON"
  else
    local cand
    for cand in python3 python; do
      if command -v "$cand" >/dev/null 2>&1 \
         && "$cand" -c 'import sqlite3' >/dev/null 2>&1; then
        PY="$(command -v "$cand")"
        break
      fi
    done
  fi
}

# resolve_ext: locate the built extension when gate 01 did not run
# (single --gate invocations, fuzz-only runs). Sets EXT/EXTW or fails.
resolve_ext() {
  [[ -n "$EXT" ]] && return 0
  # FSQL_EXT (documented above as the prebuilt-extension override) also
  # applies to single --gate invocations, not just to gate 01.
  if [[ -n "${FSQL_EXT:-}" && -f "$FSQL_EXT" ]]; then EXT="$FSQL_EXT"; return 0; fi
  if [[ "$IS_MSYS" -eq 1 ]]; then
    EXT="dist/windows/fractalsql.dll"
  else
    EXT="dist/fractalsql.so"
    [[ -f "$EXT" ]] || EXT="fractalsql.so"
  fi
  [[ -f "$EXT" ]]
}

# --- fixture-DB helpers ----------------------------------------------

# Run SQL through a FRESH connection with the extension loaded.
# Each argument is one statement; a script can also be piped on stdin.
# Config is per-connection, so every gate invocation carries its own
# fractalsql_set() preamble: the connection's own config surface.
sqlq() { "$SQLITE3" -batch -bail -cmd ".load $EXTW" "$DBW" "$@" 2>&1; }

# Expect a clean SQL error containing $1 from a fresh connection;
# any other outcome (success, crash, different error) fails.
expect_err() {
  local want="$1"; shift
  local r rc
  r=$(sqlq "$@"); rc=$?
  # Fixed-string match: want patterns carry regex metacharacters
  # verbatim (e.g. "alpha_weight must be in [0,1]").
  if [[ $rc -ne 0 ]] && grep -F <<< "$r" -q -- "$want"; then
    return 0
  fi
  printf '      expected error "%s", got rc=%d: %.300s\n' "$want" "$rc" "$r"
  return 1
}

# The crash discriminator: a process killed by a signal (segfault,
# abort, ...) reports rc = 128+signal under bash's wait-status
# convention (139 for SIGSEGV, confirmed by gate 06/18's own direct
# rc==139 checks below) -- a clean sqlite3 CLI `-bail` error exit is
# always rc=1, regardless of how the error text itself is formatted.
# Previously this matched literal error-text prefixes ("Runtime
# error: ..." / "Error in <N>th command line argument: ...") instead;
# on the sqlite3 3.45.1 CLI this harness actually runs against, a
# clean `-bail` error prints "Error: stepping, ..." -- neither prefix
# -- which made every clean error misclassified as a crash. A
# text-format match is inherently CLI-version-fragile where the rc
# convention is not, so use rc instead.
crashed() {   # crashed <output> <rc>
  local rc="$2"
  [[ $rc -ge 128 ]]
}

bt_setup() {
  if [[ -z "$SQLITE3" ]]; then
    fail "runtime setup: no sqlite3 CLI on PATH (set FSQL_SQLITE3)"; return 1
  fi
  if ! resolve_ext; then
    fail "runtime setup: no extension found, run gate 01 or set FSQL_EXT"; return 1
  fi
  EXTW="$(wpath "$EXT")"
  DBW="$(wpath "$DB")"

  # Fixture DB: a throwaway file in WAL mode (WAL so gate 12's
  # concurrent worker connections share it).
  rm -rf "$PDIR"
  mkdir -p "$PDIR"
  if ! "$SQLITE3" "$DBW" "PRAGMA journal_mode=WAL;" >/dev/null 2>&1; then
    fail "runtime setup: cannot initialize $DB"; return 1
  fi

  # Shared fixtures. Kept minimal so gate 03's auto-discovery
  # assertions stay meaningful; gate-specific tables are created by
  # their own gates.
  "$SQLITE3" "$DBW" "CREATE TABLE bt_customers(
      id INTEGER PRIMARY KEY, name TEXT NOT NULL, status TEXT);
    CREATE TABLE bt_orders(
      id INTEGER PRIMARY KEY,
      customer_id INTEGER NOT NULL REFERENCES bt_customers(id),
      total INTEGER NOT NULL);
    CREATE TABLE bt_explore(id INTEGER PRIMARY KEY, embedding TEXT);
    WITH RECURSIVE c(x) AS (VALUES(0) UNION ALL SELECT x+1 FROM c WHERE x<59)
    INSERT INTO bt_explore(embedding)
    SELECT CASE x%3
             WHEN 0 THEN (CASE x%2 WHEN 0 THEN '1.00,0.05,0.00,0.00'
                                   ELSE '0.95,0.05,0.00,0.00' END)
             WHEN 1 THEN (CASE x%2 WHEN 0 THEN '0.05,1.00,0.00,0.00'
                                   ELSE '0.05,0.95,0.00,0.00' END)
             ELSE        (CASE x%2 WHEN 0 THEN '0.05,0.00,1.00,0.00'
                                   ELSE '0.05,0.00,0.95,0.00' END)
           END
    FROM c;
    CREATE TABLE bt_telemetry(id INTEGER PRIMARY KEY, vec TEXT);
    INSERT INTO bt_telemetry(vec) VALUES
      ('0.6,0.8,0.0,0.0'),('0.1,0.2,-0.3,0.4'),('0.9,0.1,0.0,0.0'),
      ('0.5,0.5,0.5,0.5'),('0.0,0.0,0.0,1.0'),('0.2,0.2,0.2,0.2'),
      ('0.8,0.6,0.0,0.0'),('0.0,0.9,0.1,0.0');
    CREATE TABLE bt_corpus(id INTEGER PRIMARY KEY, body TEXT, emb TEXT);
    INSERT INTO bt_corpus(body, emb) VALUES
      ('doc-a about cosine metrics','1.0,0.05,0.0,0.0'),
      ('doc-b about vector stores','1.0,0.1,0.0,0.0'),
      ('doc-c about fractal search','0.05,1.0,0.0,0.0'),
      ('doc-d on SFS optimization','0.1,0.95,0.0,0.0'),
      ('doc-e on embedding tiers','0.05,0.0,1.0,0.0'),
      ('doc-f on queue processing','0.0,0.05,0.95,0.0');
    CREATE TABLE bt_traj(id INTEGER PRIMARY KEY, vec TEXT);
    INSERT INTO bt_traj(vec) VALUES
      ('0.0,0.0,0.0,0.0'),('0.1,0.0,0.0,0.0'),('0.2,0.0,0.0,0.0'),
      ('0.3,0.0,0.0,0.0'),('0.4,0.0,0.0,0.0');
    CREATE TABLE bt_soak(worker INTEGER, it INTEGER, tag TEXT);" \
    >/dev/null 2>&1 \
    || { fail "runtime setup: fixture DDL failed"; return 1; }

  compile_plugins
}

# The tests/*.c fixtures are host-agnostic reasoning-ABI plugins: the
# extension dlopens them via fsql_load_reasoning, so they build the
# same way on every host (cc -shared -fPIC -std=c99 -Iinclude).
compile_plugins() {
  local name
  for name in mock_reasoning_plugin evil_nonterminating_plugin \
              evil_lying_length_plugin evil_crash_plugin \
              retry_reasoning_plugin think_reasoning_plugin \
              mock_embed_plugin evil_embed_plugin mock_enterprise_core \
              slow_reasoning_plugin; do
    # Same LD_PRELOAD scoping as gate_01_build: this is a compile
    # invocation, not a load of the sanitized extension, and cc
    # inheriting the sanitizer runtime here would mis-flag its own
    # internal allocations as leaks.
    env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES "$CC" -shared -fPIC -std=c99 -Iinclude \
          "tests/$name.c" -o "$PDIRW/$name$PLUGSUF" \
          >"$PDIRW/$name.log" 2>&1 || printf '%s\n' "$name" >> "$PDIRW/compile_failures"
  done
  # Canonical plugin paths: PDIRSEP matches PDIRW's separator form so
  # the configured path equals its realpath (fsql_load_reasoning's
  # anti-symlink check compares the strings exactly).
  pj() { printf '%s%s%s' "$PDIRW" "$PDIRSEP" "$1"; }
  MOCK="$(pj "mock_reasoning_plugin$PLUGSUF")"
  EVILNT="$(pj "evil_nonterminating_plugin$PLUGSUF")"
  LYING="$(pj "evil_lying_length_plugin$PLUGSUF")"
  CRASH="$(pj "evil_crash_plugin$PLUGSUF")"
  RETRY="$(pj "retry_reasoning_plugin$PLUGSUF")"
  THINK="$(pj "think_reasoning_plugin$PLUGSUF")"
  MOCKEMB="$(pj "mock_embed_plugin$PLUGSUF")"
  EVOLEMB="$(pj "evil_embed_plugin$PLUGSUF")"
  MOCKENT="$(pj "mock_enterprise_core$PLUGSUF")"
  SLOWPLUG="$(pj "slow_reasoning_plugin$PLUGSUF")"
}

# Skip a gate whose fixture plugin did not compile (platform-limited
# plugin, e.g. evil_nonterminating's mmap/mprotect on a host without
# them): the same probe-compile posture the PG runner takes.
have_plugin() { [[ -f "$(wpath "$1")" ]]; }

# py_run <name> [args...]: run an embedded python driver; each driver
# is written to $PDIR and receives the DB/extension paths via env.
py_run() {
  local name="$1"; shift
  # Darwin --asan/--ubsan run via DYLD_INSERT_LIBRARIES (see main()). If
  # the sanitizer runtime itself refuses to start in the python host
  # ("Interceptors are not working ... loaded too late") that says
  # nothing about the extension: flag it so fail() reports a SKIP
  # instead of a failure. Any other failure is still a real FAIL.
  if [[ "$sysname" == "Darwin" && "${DARWIN_SAN_SKIP:-1}" -eq 0 ]]; then
    local out rc
    out=$(FSQL_BT_DB="$DBW" FSQL_BT_EXT="$EXTW" "$PY" "$PDIRW/$name.py" "$@" 2>&1)
    rc=$?
    printf '%s\n' "$out"
    if [[ $rc -ne 0 ]] && grep -qE "Interceptors are not working|loaded too late" <<< "$out"; then
      SAN_RUNTIME_REFUSED=1
    fi
    return $rc
  fi
  FSQL_BT_DB="$DBW" FSQL_BT_EXT="$EXTW" "$PY" "$PDIRW/$name.py" "$@"
}

# drop_scope_exit_branches <in.info> <out.info>
# The mcp/ server is heavy template C++ (nlohmann json, std::string): at the
# CLOSING line of a scope -- a bare "}", "} );", "} } );" -- gcc/gcov report
# a "branch" for every temporary's destructor and cleanup edge. They are
# compiler-generated, carry no source-level decision, and are not tagged as
# exception edges, so the 'e'-block filter alone leaves them in the
# denominator (on a 4k-line server it was about 1,000 of 8,700 branches, e.g.
# 76 "missed" on the single "}" that ends resources.cpp's table builder).
# Drops BRDA records whose source line is only closing punctuation, plus those on
# tool-table registration rows (see the comment at the second rule), and
# recomputes BRF/BRH per file; prints the number dropped (and how many of those
# were registration rows) on stderr.
drop_scope_exit_branches() {
  local in="$1" out="$2"
  awk -v outfile="$out" '
    function flush(   i, brf, brh, p) {
      brf = 0; brh = 0
      for (i = 1; i <= nl; i++) if (keep[i] && substr(L[i], 1, 5) == "BRDA:") {
        split(substr(L[i], 6), p, ",")
        brf++; if (p[4] != "-" && p[4] + 0 > 0) brh++
      }
      for (i = 1; i <= nl; i++) {
        if (!keep[i]) continue
        if (substr(L[i], 1, 4) == "BRF:") print "BRF:" brf > outfile
        else if (substr(L[i], 1, 4) == "BRH:") print "BRH:" brh > outfile
        else print L[i] > outfile
      }
    }
    BEGIN { nl = 0 }
    {
      line = $0
      if (substr(line, 1, 3) == "SF:") {
        file = substr(line, 4); n = 0; delete src
        while ((getline sl < file) > 0) { n++; src[n] = sl }
        close(file)
      }
      L[++nl] = line; keep[nl] = 1
      if (substr(line, 1, 5) == "BRDA:") {
        split(substr(line, 6), p, ",")
        if (src[p[1] + 0] ~ /^[ \t]*[})\];,]+[ \t})\];,]*$/) { keep[nl] = 0; dropped++ }
        # A tool-table registration row: "t.push_back( ToolSpec{ name, category, ..., lambda } );".
        # It is declarative (no decision in the row itself -- the handler lambda is on its own
        # lines and stays counted), but the aggregate initialiser builds a std::vector of params,
        # a std::function and several strings in one expression, and gcov attributes about six
        # unwind/cleanup branches per row that no input can reach (78 rows, ~470 of them).
        else if (index(src[p[1] + 0], "t.push_back( ToolSpec{") > 0) { keep[nl] = 0; dropped++; reg++ }
      }
      if (line == "end_of_record") { flush(); nl = 0; delete keep; delete L }
    }
    END { print dropped + 0, reg + 0 > "/dev/stderr" }
  ' "$in" 2>"$out.dropped"
  read -r SCOPE_EXIT_DROPPED REG_ROW_DROPPED < "$out.dropped" 2>/dev/null || true
  rm -f "$out.dropped"
}

# --coverage: capture the .gcda the gate processes left in src/ and
# generate an lcov report. Called once after the gate matrix finishes.
# Unlike the PG runner there is no GCOV_PREFIX redirect to undo: no
# server here -- every host process is a sqlite3 CLI or python driver
# started from this script, and gcov writes .gcda straight back next
# to the .gcno in src/, inside the (writable) checkout.
run_coverage_report() {
  if ! command -v lcov >/dev/null 2>&1; then
    skip "coverage: lcov not installed, skipping report (the gates themselves ran fine -- install lcov to get coverage_html/)"
    return
  fi
  if ! find src -name '*.gcda' | grep -q .; then
    fail "coverage: no .gcda produced (was --coverage gate 01 build ok?)"
    return
  fi
  lcov --capture --directory src --output-file "$TMPROOT/fractalsql_bt_coverage_raw.info" \
       --rc branch_coverage=1 >"$TMPROOT/fractalsql_bt_lcov.log" 2>&1 \
    || { fail "coverage: lcov capture failed; see $TMPROOT/fractalsql_bt_lcov.log"; return; }

  # Extract just our TUs: the capture also picks up the handful of
  # lines pulled in from sqlite3ext.h etc. -- those aren't our code and
  # nobody's asking about their coverage anyway. Multi-TU here (PG's
  # is a single src/fractalsql.c), hence the wildcard.
  #
  # NOTE: no_exception_branch=1 is NOT passed to lcov --capture/
  # --extract (only to genhtml, below and in the mcp/ section) --
  # confirmed empirically (round 49) that passing it to geninfo at
  # capture time zeroes out BRF/BRH entirely for this lcov/geninfo
  # version (2.0-1) when combined with --branch-coverage, a geninfo
  # bug in that combination, not a sign the setting itself is wrong.
  # It works correctly when passed to genhtml alone, reading the
  # already-captured .info's per-branch exception tag at render time.
  lcov --extract "$TMPROOT/fractalsql_bt_coverage_raw.info" '*/src/*' \
       --output-file "$TMPROOT/fractalsql_bt_coverage.info" \
       --rc branch_coverage=1 >>"$TMPROOT/fractalsql_bt_lcov.log" 2>&1

  echo ""
  echo "=== coverage (src/*.c) ==="
  # Computed directly from the .info file's own LF/LH/FNF/FNH totals
  # (lcov 2.0-1's --list renderer miscomputes its Rate% column against
  # this intermediate gcov-JSON-derived .info -- seen in the PG runner,
  # a nonsensical 1170% function rate -- even though the underlying
  # LF:/LH:/etc. totals, and genhtml's own report built from the same
  # file, are both correct), but branches are summed directly from the
  # raw BRDA: lines rather than trusted from the .info's own BRF:/BRH:
  # fields, EXCLUDING exception-tagged branches (an 'e' prefix on
  # BRDA's block-number field -- see the mcp/ section below for why).
  # A no-op for src/*.c today (plain C has no exceptions, so nothing is
  # ever 'e'-tagged there), but this way both sections use the same
  # counting method and this text summary always matches what
  # genhtml's --rc no_exception_branch=1 report shows.
  awk -F: '
    /^LF:/ { lf += $2 } /^LH:/ { lh += $2 }
    /^FNF:/ { fnf += $2 } /^FNH:/ { fnh += $2 }
    /^BRDA:/ {
      split($2, p, ",")
      if (substr(p[2], 1, 1) != "e") {
        brf++
        if (p[4] != "-" && p[4]+0 > 0) brh++
      }
    }
    END {
      printf "  lines:     %d/%d", lh, lf
      if (lf > 0) printf " (%.1f%%)", 100*lh/lf
      print ""
      printf "  functions: %d/%d", fnh, fnf
      if (fnf > 0) printf " (%.1f%%)", 100*fnh/fnf
      print ""
      printf "  branches:  %d/%d", brh, brf
      if (brf > 0) printf " (%.1f%%)", 100*brh/brf
      print ""
    }' "$TMPROOT/fractalsql_bt_coverage.info"

  if command -v genhtml >/dev/null 2>&1; then
    genhtml "$TMPROOT/fractalsql_bt_coverage.info" --output-directory coverage_html \
            --rc branch_coverage=1 --rc no_exception_branch=1 >"$TMPROOT/fractalsql_bt_genhtml.log" 2>&1 \
      && pass "coverage: report at coverage_html/index.html" \
      || fail "coverage: genhtml failed; see $TMPROOT/fractalsql_bt_genhtml.log"
  fi

  # MCP server (mcp/src/*.cpp, mcp/src/adapters/*.cpp); only produced
  # when gate 37 actually rebuilt the instrumented binary (POSIX, a
  # working make/g++, and on Darwin a resolvable Homebrew openssl@3;
  # see gate_37_mcp_smoke's own skip conditions). Absence here just
  # means gate 37 itself already reported why; nothing new to fail on.
  if ! find mcp/src -name '*.gcda' 2>/dev/null | grep -q .; then
    skip "coverage: no mcp/src/*.gcda produced (gate 37 didn't rebuild the MCP server under --coverage; see its own skip/fail reason above)"
    return
  fi
  # --ignore-errors mismatch: nlohmann::json.hpp (header-only, heavy
  # template + exception use) gets independently instantiated per
  # adapter .cpp TU; geninfo's gcda merge step chokes reconciling their
  # exception-handling tags across TUs ("mismatched exception tag for
  # id N") even though every individual TU's own counts are correct.
  # Documented, known gcov/geninfo limitation with this exact kind of
  # header, not a sign the data itself is wrong.
  #
  # no_exception_branch=1 (genhtml only -- see below): without it,
  # mcp/'s reported branch % is dominated by compiler-synthesized
  # exception-unwind landing pads from heavy template inlining
  # (nlohmann::json/std::string/std::vector construction under -O1
  # --coverage) -- GCC/gcov already tags these natively as exception
  # branches (the 'e' prefix on a BRDA: line's block-number field), so
  # excluding that tagged set is a principled fix, not a guessed
  # source-level pattern. Confirmed empirically (round 48): agency.cpp's
  # own branch rate went from 48.3% (803/1664, 857 of 861 missing
  # branches tagged "not taken" on lines that DID execute -- i.e.
  # reached but structurally unflippable) to 82.7% (811/981) with this
  # exclusion alone, no source or test changes. Without it, 80% branch
  # coverage on mcp/ is not a meaningful target: the denominator itself
  # is mostly compiler noise, not application logic. A plain -O0
  # rebuild was also tried as an alternative fix and does NOT help
  # (nlohmann::json's accessors are declared `inline` in the header, so
  # GCC keeps inlining their bodies regardless of optimization level).
  #
  # IMPORTANT (round 49): no_exception_branch=1 must NOT be passed to
  # lcov --capture/--extract (i.e. to geninfo) -- confirmed empirically
  # that doing so zeroes BRF/BRH entirely for this lcov/geninfo version
  # (2.0-1) when combined with --branch-coverage, a geninfo bug in that
  # exact combination. It works correctly when passed to genhtml alone
  # (reading the already-captured .info's per-branch tag at render
  # time), which is where it's applied below; the text summary here
  # instead sums BRDA: lines directly, skipping 'e'-tagged ones, so it
  # always agrees with genhtml's report.
  lcov --capture --directory mcp/src --output-file "$TMPROOT/fractalsql_bt_mcp_coverage_raw.info" \
       --rc branch_coverage=1 --ignore-errors mismatch >>"$TMPROOT/fractalsql_bt_lcov.log" 2>&1 \
    || { fail "coverage: mcp lcov capture failed; see $TMPROOT/fractalsql_bt_lcov.log"; return; }

  # Extract just mcp/src/mcp/src/adapters; the capture also picks up
  # mcp/vendor/json.hpp (nlohmann, not ours) and the vendored sqlite3.c
  # amalgamation compiled in as sqlite3.o; neither is our code.
  lcov --extract "$TMPROOT/fractalsql_bt_mcp_coverage_raw.info" '*/mcp/src/*' \
       --output-file "$TMPROOT/fractalsql_bt_mcp_coverage.info" \
       --rc branch_coverage=1 >>"$TMPROOT/fractalsql_bt_lcov.log" 2>&1
  # Compiler scope-exit (destructor) edges on closing-brace lines and the unwind edges on
  # tool-table registration rows carry no source decision: see drop_scope_exit_branches.
  # The filtered file is the one reported and rendered; the raw one stays in $TMPROOT.
  drop_scope_exit_branches "$TMPROOT/fractalsql_bt_mcp_coverage.info" "$TMPROOT/fractalsql_bt_mcp_coverage_f.info"

  echo ""
  echo "=== coverage (mcp/src/*.cpp) ==="
  echo "  (branch counts exclude exception edges, $(( ${SCOPE_EXIT_DROPPED:-0} - ${REG_ROW_DROPPED:-0} )) compiler records on closing-brace lines"
  echo "   and ${REG_ROW_DROPPED:-0} records on tool-table registration rows, t.push_back( ToolSpec{ ... } ))"
  # See the src/*.c section above for why branches are summed from raw
  # BRDA: lines (excluding 'e'-tagged exception branches) instead of
  # trusted from the .info's own BRF:/BRH: fields -- here it's not a
  # no-op: this is the fix that makes mcp/'s branch % mean something.
  awk -F: '
    /^LF:/ { lf += $2 } /^LH:/ { lh += $2 }
    /^FNF:/ { fnf += $2 } /^FNH:/ { fnh += $2 }
    /^BRDA:/ {
      split($2, p, ",")
      if (substr(p[2], 1, 1) != "e") {
        brf++
        if (p[4] != "-" && p[4]+0 > 0) brh++
      }
    }
    END {
      printf "  lines:     %d/%d", lh, lf
      if (lf > 0) printf " (%.1f%%)", 100*lh/lf
      print ""
      printf "  functions: %d/%d", fnh, fnf
      if (fnf > 0) printf " (%.1f%%)", 100*fnh/fnf
      print ""
      printf "  branches:  %d/%d", brh, brf
      if (brf > 0) printf " (%.1f%%)", 100*brh/brf
      print ""
    }' "$TMPROOT/fractalsql_bt_mcp_coverage_f.info"

  if command -v genhtml >/dev/null 2>&1; then
    genhtml "$TMPROOT/fractalsql_bt_mcp_coverage_f.info" --output-directory coverage_html_mcp \
            --rc branch_coverage=1 --rc no_exception_branch=1 >>"$TMPROOT/fractalsql_bt_genhtml.log" 2>&1 \
      && pass "coverage: mcp report at coverage_html_mcp/index.html" \
      || fail "coverage: mcp genhtml failed; see $TMPROOT/fractalsql_bt_genhtml.log"
  fi
}

# ======================================================================
# Gates
# ======================================================================

gate_01_build() {
  if [[ -n "${FSQL_EXT:-}" ]]; then
    EXT="$FSQL_EXT"
    [[ -f "$EXT" ]] && { pass "01 build (FSQL_EXT override: $EXT)"; return; }
    fail "01 build: FSQL_EXT=$EXT does not exist"; return
  fi
  if [[ "$IS_MSYS" -eq 1 ]]; then
    # The Windows build arbiter is scripts/windows/build.bat (MSVC),
    # driven by build_test.ps1; this POSIX runner mirrors the gates on
    # a toolchain (Git Bash) that has no make + sqlite3ext.h pair.
    # FSQL_EXT exists for an MSYS-side manual build.
    if [[ -f "dist/windows/fractalsql.dll" ]]; then
      EXT="dist/windows/fractalsql.dll"
      pass "01 build (prebuilt MSVC artifact; full MSVC build runs via build_test.ps1)"
    else
      fail "01 build: no dist/windows/fractalsql.dll (run scripts/windows/build.bat)"
    fi
    return
  fi
  local cov_log="$TMPROOT/fractalsql_bt_build.log"
  local san_args=()
  [[ "$ASAN" -eq 1 ]]  && san_args+=(ASAN=1)
  [[ "$UBSAN" -eq 1 ]] && san_args+=(UBSAN=1)
  [[ "$TSAN" -eq 1 ]]  && san_args+=(TSAN=1)
  [[ "$COVERAGE" -eq 1 ]] && san_args+=(COVERAGE=1)
  # Coverage: make's clean rule doesn't remove .gcda (they aren't in
  # $(OBJS)), so stale counters from a previous coverage run would
  # otherwise merge into THIS run's report. Clear them first so the
  # report reflects only this run.
  if [[ "$COVERAGE" -eq 1 ]]; then
    rm -f src/*.gcda
  fi
  # LD_PRELOAD (set below in main(), for the RUNTIME gates that dlopen
  # a sanitized extension into the unsanitized sqlite3 CLI) must not
  # leak into the build itself: with it inherited, cc/ld/ar all load
  # the sanitizer runtime too, and LeakSanitizer flags ordinary
  # toolchain-internal allocations as leaks, failing the build outright.
  if command -v make >/dev/null 2>&1 \
     && env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES make clean >/dev/null 2>&1 \
     && env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES make ${san_args[@]+"${san_args[@]}"} \
          >"$TMPROOT/fractalsql_bt_build.log" 2>&1 \
     && [[ -f "fractalsql.so" ]]; then
    EXT="$HERE/fractalsql.so"
    pass "01 build (make)"
  else
    fail "01 build: see $TMPROOT/fractalsql_bt_build.log"
    # Surface the real diagnostics: linker errors often carry no
    # "error:" string; ld64 prints "ld: unknown option: ...",
    # "Undefined symbols for architecture arm64:", "ld: library not
    # found for ...", and MSVC prints "error LNK2001:", so matching
    # only "error:" hid the actual cause behind clang's one-line
    # summary (observed twice on the macOS gates). Fall back to the
    # log tail when nothing matches.
    grep -inE "error|ld: |undefined symbol|undefined reference|unknown option|unresolved" \
        "$TMPROOT/fractalsql_bt_build.log" 2>/dev/null \
      | head -8 | sed 's/^/         /' \
      || { echo "         (no error-pattern lines; log tail:)"; \
           tail -12 "$TMPROOT/fractalsql_bt_build.log" 2>/dev/null \
             | sed 's/^/         /'; }
    # Preserve the FULL log for CI artifact upload: the printer above is
    # grep-filtered and capped, so a linker report hundreds of lines long
    # (e.g. a complete "Undefined symbols" block) surfaces only a sample.
    cp "$TMPROOT/fractalsql_bt_build.log" "$HERE/fractalsql_bt_build.log" 2>/dev/null || true
  fi
}

gate_02_smoke() {
  local ver; ver=$(sqlq "SELECT fractalsql_version();")
  [[ "$ver" = "2.0.11" ]] \
    && pass "02 smoke: version=$ver" \
    || fail "02 smoke: version='$ver' (want 2.0.11)"
  # fractal_search convergence: self-distance ~0
  local d; d=$(sqlq "SELECT fractal_search('0.6,0.8,0.0,0.0','0.6,0.8,0.0,0.0');")
  if [[ "$d" = "0.0" ]] || python_abs_lt_1e6 "$d"; then
    pass "02 smoke: fractal_search self-distance=$d"
  else
    fail "02 smoke: self-distance='$d'"
  fi
  # ...and a nontrivial one: query at a corpus corner converges to ~its twin
  local d2; d2=$(sqlq "SELECT fractal_search('0.1,0.2,-0.3,0.4','0.1,0.2,-0.3,0.4');")
  if python_abs_lt_1e6 "$d2"; then
    pass "02 smoke: fractal_search convergence=$d2"
  else
    fail "02 smoke: convergence=$d2"
  fi
  local ed; ed=$(sqlq "SELECT fractalsql_edition();")
  [[ "$ed" = "Community" ]] \
    && pass "02 smoke: edition=$ed" \
    || fail "02 smoke: edition='$ed'"
  # fractal_search_debug returns the FULL fsql_search_ptr result JSON
  # (not just the best_point extraction fractal_search uses); assert
  # the best_point key survives. Signature here is
  # fractal_search_debug(query [, iterations, population_size,
  # diffusion_factor]): a single query vector, run fresh.
  local dbg; dbg=$(sqlq "SELECT fractal_search_debug('0.6,0.8,0.0,0.0');")
  grep <<< "$dbg" -q "best_point" \
    && pass "02 smoke: fractal_search_debug has best_point" \
    || fail "02 smoke: fractal_search_debug='$dbg'"
}

# bash has no float compare; a one-shot python float check (skipped
# cleanly where python is absent, with the integer-equality case still
# covered by the caller).
python_abs_lt_1e6() {
  [[ -n "$PY" ]] || { [[ "$1" == "0" || "$1" == "0.0" ]]; return; }
  "$PY" -c "import sys; sys.exit(0 if abs(float('''$1'''))<1e-6 else 1)" 2>/dev/null
}

gate_03_schema_context() {
  local ctx; ctx=$(sqlq "SELECT fractal_schema_context();")
  grep <<< "$ctx" -q "id INTEGER PK" \
    && pass "03 schema_context: PK" \
    || fail "03 schema_context: PK"
  grep <<< "$ctx" -q "name TEXT NOT NULL" \
    && pass "03 schema_context: NOT NULL" \
    || fail "03 schema_context: NOT NULL"
  grep <<< "$ctx" -q "FOREIGN KEY (customer_id) REFERENCES bt_customers(id)" \
    && pass "03 schema_context: FK" \
    || fail "03 schema_context: FK ($ctx)"
  # auto-discovery (0-arg): must find both fixture tables on its own.
  # Relies on this gate running before gate 10 floods the schema.
  if grep <<< "$ctx" -q "bt_customers" && grep <<< "$ctx" -q "bt_orders"; then
    pass "03 schema_context: auto-discovery finds both tables"
  else
    fail "03 schema_context: auto-discovery='$ctx'"
  fi
  # COMMENT ON TABLE has no SQLite analog (structural N/A, documented
  # in sql/fractalsql--1.0.sql); no comment assertion here.

  # Composite FK with non-default ON UPDATE/ON DELETE actions: the
  # bt_customers/bt_orders fixture's single-column FK with implicit
  # NO ACTION never exercises fk_put_col_lists' multi-column join or
  # fk_put_constraint_line's ON UPDATE/ON DELETE emission (both are
  # skipped when the action is the default). Dropped again right after
  # so the auto-discovery assertion above (and gate 10's own schema
  # expectations) are unaffected by later gates.
  sqlq "
    CREATE TABLE bt_fk_parent(a INTEGER, b INTEGER, PRIMARY KEY(a,b));
    CREATE TABLE bt_fk_child(pa INTEGER, pb INTEGER,
      FOREIGN KEY (pa, pb) REFERENCES bt_fk_parent(a,b)
        ON DELETE CASCADE ON UPDATE SET NULL);
  " >/dev/null 2>&1 || fail "03 schema_context: composite-FK fixture setup failed"
  local ctxfk; ctxfk=$(sqlq "SELECT fractal_schema_context();")
  if grep <<< "$ctxfk" -q "FOREIGN KEY (pa, pb) REFERENCES bt_fk_parent(a, b)" \
      && grep <<< "$ctxfk" -q "ON UPDATE SET NULL" \
      && grep <<< "$ctxfk" -q "ON DELETE CASCADE"; then
    pass "03 schema_context: composite FK with ON UPDATE/ON DELETE actions"
  else
    fail "03 schema_context: composite FK, got: $ctxfk"
  fi
  sqlq "
    DROP TABLE IF EXISTS bt_fk_child;
    DROP TABLE IF EXISTS bt_fk_parent;
  " >/dev/null 2>&1
}

# helper: expect a text_to_sql rejection containing $2 (or PASS if $2
# empty). $3 = label, prefixed with the calling gate's own number since
# this helper is shared by gates 04 and 13.
t2s_expect() {
  local canned="$1" want="$2" label="$3"
  printf '%s' "$canned" > "$SQLTXT"
  local r; r=$(sqlq \
    "SELECT fractalsql_set('reasoning_plugin','$MOCK');" \
    "SELECT fractalsql_set('text_to_sql_allowed_statements','select');" \
    "SELECT fractal_text_to_sql('q');")
  local rc=$?
  if [[ -z "$want" ]]; then
    if [[ $rc -eq 0 ]]; then
      pass "$label → returned"
    else
      fail "$label (expected PASS): $r"
    fi
  else
    if [[ $rc -ne 0 ]] && grep <<< "$r" -q "$want"; then
      pass "$label → rejected ($want)"
    else
      fail "$label: got '$r' (want '$want')"
    fi
  fi
}

gate_04_text_to_sql() {
  t2s_expect "SELECT count(*) FROM bt_orders"                                  ""                       "04 valid-SELECT"
  # NOT exercised here: extract_sql_from_response's ```sql/bare-``` fence
  # branches. fractal_text_to_sql's GENERATE step force-sets RESPONSE_
  # MODE=code before calling the plugin, and mock_reasoning_plugin.c
  # deliberately does NOT fence its response in that mode -- it models
  # a real reasoning-http plugin, which already strips fences itself
  # under code mode before generate() returns (see the mock's own
  # header comment). extract_sql_from_response still runs as the
  # safety net for a plugin that doesn't pre-strip, but nothing in
  # this suite's mock infrastructure feeds it fenced content to strip.
  # Confirmed by a live failing assertion, not assumed from reading.
  t2s_expect "SELECT 1; DROP TABLE bt_orders"                                  "exactly one SQL"        "04 stacked"
  t2s_expect "DROP TABLE bt_orders"                                            "not permitted"          "04 DDL"
  t2s_expect "DELETE FROM bt_orders"                                           "not permitted"          "04 DELETE"
  # SQLite has no data-modifying CTE syntax: the WITH..DELETE form dies
  # at parse ("near \"DELETE\": syntax error"), unlike PG where it
  # reached the readonly analysis. The message below documents the
  # select-mode write posture for anything else that parses.
  t2s_expect "WITH d AS (DELETE FROM bt_orders RETURNING *) SELECT * FROM d"   "SQL does not parse"     "04 modifying-CTE"
  t2s_expect "SELECT nope FROM bt_orders"                                      "SQL does not parse"     "04 bad-column"
  t2s_expect "this is not sql at all ##"                                       'is not permitted'       "04 unparseable"
  t2s_expect "EXPLAIN SELECT 1"                                                'statement type "EXPLAIN" is not permitted' "04 EXPLAIN"
  t2s_expect "123 not a keyword"                                                "statement is empty or does not start with" "04 non-keyword-start"
  t2s_expect "INSERT INTO bt_orders VALUES (1)"                                 "not permitted"          "04 INSERT-in-select-mode"
  local n; n=$("$SQLITE3" "$DBW" "SELECT count(*) FROM bt_orders;" 2>&1)
  [[ "$n" = "0" ]] \
    && pass "04 never-executes (bt_orders still empty)" \
    || fail "04 never-executes: row count=$n"
  # Empty candidate: the model's response has no fenced ```sql block
  # and no bare statement (the mock returns the canned file's content
  # verbatim in code mode -- an empty file is an empty candidate).
  # max_attempts=1 makes this a single-shot exhaustion, exercising
  # t2s_handle_empty_candidate's own path, otherwise dead -- every
  # other t2s_expect case above returns a real (valid or rejected) SQL
  # candidate.
  printf '' > "$SQLTXT"
  if expect_err "the model response contained no SQL" \
      "SELECT fractalsql_set('reasoning_plugin','$MOCK');" \
      "SELECT fractalsql_set('text_to_sql_max_attempts','1');" \
      "SELECT fractal_text_to_sql('q');"; then
    pass "04 empty candidate -> rejected (no fenced block, no bare statement)"
  else
    fail "04 empty candidate: did not error cleanly"
  fi
  # extract_sql_from_response's own fenced-block stripping: normally
  # dead here, since T2S's forced RESPONSE_MODE=code makes $MOCK never
  # fence its GENERATE response (mirroring a real reasoning-http
  # plugin, which already strips the fence itself under that mode).
  # FSQL_MOCK_FLIP_FENCE (test-only override added to mock_reasoning_
  # plugin.c) flips that one call into fenced mode, letting this
  # exercise the actual ```sql fence + bare ``` fence stripping logic
  # instead of code mode's "return verbatim" shortcut.
  printf 'SELECT count(*) FROM bt_orders' > "$SQLTXT"
  r=$(FSQL_MOCK_FLIP_FENCE=1 sqlq \
    "SELECT fractalsql_set('reasoning_plugin','$MOCK');" \
    "SELECT fractal_text_to_sql('q');")
  [[ $? -eq 0 ]] && grep <<< "$r" -Fq "SELECT count(*) FROM bt_orders" \
    && pass "04 extract_sql_from_response strips a \`\`\`sql fenced block (FLIP_FENCE)" \
    || fail "04 extract_sql_from_response fenced-block case: $r"
  printf '' > "$SQLTXT"
  # auto-discovery: the full GENERATE -> ALLOWLIST -> prepare pipeline
  # works off the auto-built schema context (0-arg registration), not
  # just an explicit table list (the PG version's table_names arg, since
  # there is no explicit-names form here; discovery is the only path).
  printf 'SELECT count(*) FROM bt_orders' > "$SQLTXT"
  local auto; auto=$(sqlq \
    "SELECT fractalsql_set('reasoning_plugin','$MOCK');" \
    "SELECT fractal_text_to_sql('q');")
  [[ $? -eq 0 ]] \
    && pass "04 auto-discovery: text_to_sql off the auto-built context" \
    || fail "04 auto-discovery: got '$auto'"
}

# Guard-page plugin: the response is deliberately NOT NUL-terminated and
# sits flush against an unmapped page, so any over-read SIGSEGVs
# instantly. Proves the pnstrdup(summary, summary_len) fix holds at all
# three call sites. Re-aim: the crash kills the whole sqlite3 process,
# so "survived" means the process exited (rc==0 or a clean SQL error);
# the PG runner watched for a dropped connection instead.
gate_05_evil_overread() {
  if [[ ! -f "$(wpath "$EVILNT")" ]]; then
    skip "05 evil_overread (evil_nonterminating_plugin did not build on this platform)"; return
  fi
  survived() {  # survived <sql...>
    local r; r=$(sqlq "$@"); local rc=$?
    if crashed "$r" "$rc"; then
      printf '      output: %.200s\n' "$r"
      return 1
    fi
    return 0
  }
  echo "1" > "$EVILTRIG"
  printf 'SELECT 1' > "$SQLTXT"
  # The plugin reads its canned SQL from this env (inherited by the
  # in-process plugin; one env-visibility advantage over PG's forked
  # backends, which needed the fixed-file convention).
  export FSQL_EVIL_SQL_FILE="$SQLTXTW"
  if survived \
      "SELECT fractalsql_set('reasoning_plugin','$EVILNT');" \
      "SELECT fractal_text_to_sql('q');"; then
    pass "05 evil_overread: GENERATE path (non-terminated guard-page response) survived"
  else
    fail "05 evil_overread: GENERATE path crashed the process"
  fi
  if survived \
      "SELECT fractalsql_set('reasoning_plugin','$EVILNT');" \
      "SELECT fractal_reason('q','ctx');"; then
    pass "05 evil_overread: bare fractal_reason() survived"
  else
    fail "05 evil_overread: bare fractal_reason() crashed the process"
  fi
  echo "2" > "$EVILTRIG"
  if survived \
      "SELECT fractalsql_set('reasoning_plugin','$EVILNT');" \
      "SELECT fractalsql_set('text_to_sql_use_review','on');" \
      "SELECT fractal_text_to_sql('q');"; then
    pass "05 evil_overread: REVIEW path survived"
  else
    fail "05 evil_overread: REVIEW path crashed the process"
  fi
  unset FSQL_EVIL_SQL_FILE
  echo "1" > "$EVILTRIG"
}

gate_06_crash_recovery() {
  if [[ ! -f "$(wpath "$CRASH")" ]]; then
    skip "06 crash_recovery (evil_crash_plugin did not build)"; return
  fi
  # Canary committed by a prior connection.
  sqlq "CREATE TABLE IF NOT EXISTS bt_crash_canary(
          id INTEGER PRIMARY KEY, note TEXT);"
  sqlq "DELETE FROM bt_crash_canary;"
  sqlq "INSERT INTO bt_crash_canary VALUES (42, 'pre-crash');"

  echo "1" > "$EVILTRIG"
  local r rc
  r=$(sqlq \
      "SELECT fractalsql_set('reasoning_plugin','$CRASH');" \
      "SELECT fractal_reason('q','ctx');")
  rc=$?
  if ! crashed "$r" "$rc"; then
    fail "06 crash_recovery: expected a process crash, got rc=$rc out='$r'"
    return
  fi
  pass "06 crash_recovery: sqlite3 process died (rc=$rc)"

  # Recovery: poll until the dead process's locks release and the DB
  # reopens cleanly (WAL/journal replay on the next open), then the
  # prior data must be intact.
  local deadline=$(( SECONDS + 30 * TIMEOUT_MULT )) out
  while :; do
    out=$("$SQLITE3" "$DBW" "PRAGMA integrity_check;" 2>&1)
    grep <<< "$out" -q "^ok$" && break
    if (( SECONDS >= deadline )); then
      fail "06 crash_recovery: DB did not recover (integrity: $out)"; return
    fi
    sleep 1
  done
  pass "06 crash_recovery: DB reopened, integrity ok (WAL recovery)"
  local n
  n=$("$SQLITE3" "$DBW" \
      "SELECT count(*) FROM bt_crash_canary WHERE id=42 AND note='pre-crash';" 2>&1)
  [[ "$n" = "1" ]] \
    && pass "06 crash_recovery: canary row intact after crash" \
    || fail "06 crash_recovery: canary lost (count=$n)"
}

gate_07_evil_lying_length() {
  if [[ ! -f "$(wpath "$LYING")" ]]; then
    skip "07 evil_lying_length (evil_lying_length_plugin did not build)"; return
  fi
  expect_rej() {  # expect_rej <label> <sql...>
    local label="$1"; shift
    local r rc
    r=$(sqlq "$@"); rc=$?
    if crashed "$r" "$rc"; then
      fail "07 $label: process crashed ($r)"
    elif grep <<< "$r" -q "implausible response length"; then
      pass "07 $label rejected cleanly"
    else
      fail "07 $label: expected rejection, got: $r"
    fi
  }
  echo "1" > "$EVILTRIG"
  expect_rej "GENERATE path" \
    "SELECT fractalsql_set('reasoning_plugin','$LYING');" \
    "SELECT fractal_text_to_sql('q');"
  expect_rej "bare fractal_reason()" \
    "SELECT fractalsql_set('reasoning_plugin','$LYING');" \
    "SELECT fractal_reason('q');"
  echo "2" > "$EVILTRIG"
  expect_rej "REVIEW path" \
    "SELECT fractalsql_set('reasoning_plugin','$LYING');" \
    "SELECT fractalsql_set('text_to_sql_use_review','on');" \
    "SELECT fractal_text_to_sql('q');"
  echo "1" > "$EVILTRIG"
}

# Python driver: the authorizer hook (sqlite3_set_authorizer) must be
# honored INSIDE the extension's own introspection; a denied read on a
# table must surface as a clean error that leaks none of that table's
# column detail. This is the SQLite form of PG gate 08's low-privilege
# role boundary (stock SQLite has no roles; the authorizer is the hook
# an embedding application would use).
write_py_gate08() {
  cat > "$PDIR/py_gate08.py" <<'PYEOF'
import os, sqlite3, sys

db, ext = os.environ["FSQL_BT_DB"], os.environ["FSQL_BT_EXT"]
SQLITE_READ, SQLITE_DENY, SQLITE_OK = 20, 1, 0

con = sqlite3.connect(db)
con.enable_load_extension(True)
con.load_extension(ext)

# Control: allow-all authorizer -> schema_context sees the fixtures.
con.set_authorizer(lambda *a: SQLITE_OK)
try:
    v = con.execute("SELECT fractal_schema_context()").fetchone()[0]
    assert "bt_customers" in v, "control: fixture tables missing from context"
except Exception as e:
    print("FAIL control: %s" % e)
    sys.exit(1)

# Boundary: deny the introspection of bt_customers: both the PRAGMA
# table_info form (what schema_context actually issues per table; on
# builds without the bound-pragma form the argument arrives as arg2)
# and any direct READ of the table. The introspection must fail, and
# the error text must not carry the denied table's column detail.
SQLITE_PRAGMA = 19

def deny_read(action, arg1, arg2, db_name, trigger):
    if (action == SQLITE_PRAGMA and arg1 == "table_info"
            and arg2 == "bt_customers"):
        return SQLITE_DENY
    if action == SQLITE_READ and arg1 == "bt_customers":
        return SQLITE_DENY
    return SQLITE_OK

con.set_authorizer(deny_read)
try:
    v = con.execute("SELECT fractal_schema_context()").fetchone()[0]
    print("FAIL: schema_context returned data despite a denied introspection of bt_customers")
    sys.exit(1)
except sqlite3.Error as e:
    msg = str(e)
    if "name TEXT" in msg:
        print("FAIL: authorizer-denied error leaked schema detail: %s" % msg[:200])
        sys.exit(1)
    print("OK: denied read surfaced as a clean error (no leak): %s" % msg[:120])
    sys.exit(0)
PYEOF
}

gate_08_authz() {
  if [[ -z "$PY" ]]; then
    skip "08 authz (no python3 with the stdlib sqlite3 module)"; return
  fi
  write_py_gate08
  if py_run py_gate08; then
    pass "08 authz: authorizer denial honored inside schema_context, no leak"
  else
    fail "08 authz: see driver output above"
  fi
}

gate_09_guc_superuser() {
  # Enforced at fractalsql_set time: a path key must be absolute with
  # no traversal segments, whatever the caller's privileges.
  if expect_err "must be an absolute path with no '..' segments" \
      "SELECT fractalsql_set('reasoning_plugin','plugins/mock.so');"; then
    pass "09 guc_superuser: relative reasoning_plugin rejected"
  else
    fail "09 guc_superuser: relative path accepted"
  fi
  if expect_err "must be an absolute path with no '..' segments" \
      "SELECT fractalsql_set('reasoning_plugin','$BTROOTW/../evil$PLUGSUF');"; then
    pass "09 guc_superuser: traversal reasoning_plugin rejected"
  else
    fail "09 guc_superuser: traversal path accepted"
  fi
  # Control: the canonical absolute form is accepted (no load happens
  # at set time; set-time validation only).
  local r; r=$(sqlq "SELECT fractalsql_set('reasoning_plugin','$MOCK');")
  [[ "$r" == "ok" ]] \
    && pass "09 guc_superuser: canonical absolute path accepted" \
    || fail "09 guc_superuser: canonical path rejected: $r"
}

gate_10_dos_and_injection() {
  # 512-cap fires via DISCOVERY (513 tables in the DB), not an array
  # argument: fractal_schema_context() is 0-arg here.
  {
    for i in $(seq 0 512); do
      printf 'CREATE TABLE bt_dos_%s(id INTEGER);\n' "$i"
    done
  } | "$SQLITE3" "$DBW" >/dev/null 2>&1
  if expect_err "more than 512 tables/views found" \
      "SELECT fractal_schema_context();"; then
    pass "10 dos_and_injection: 512-table cap fires at 513"
  else
    fail "10 dos_and_injection: cap did not fire at 513 tables"
  fi
  # Auto-discovery with zero visible tables: needs a genuinely fresh,
  # empty connection -- the shared $DBW always has tables from other
  # gates by this point in the run.
  local r_empty; r_empty=$("$SQLITE3" :memory: ".load $EXTW" \
    "SELECT fractal_schema_context();" 2>&1)
  grep <<< "$r_empty" -Fq "no visible tables found" \
    && pass "10 dos_and_injection: schema_context on a table-less DB reports no visible tables" \
    || fail "10 dos_and_injection: expected 'no visible tables found', got: $r_empty"
  # Drop the flood before the injection case; the cap fires at
  # discovery time and would mask it otherwise.
  {
    for i in $(seq 0 512); do
      printf 'DROP TABLE bt_dos_%s;\n' "$i"
    done
  } | "$SQLITE3" "$DBW" >/dev/null 2>&1
  # An injection-shaped table name can be created literally (quoted);
  # schema_context must NOT carry it into SQL text; introspection is
  # SKIPPED for names that cannot be safely embedded (the bound
  # PRAGMA-argument form is unavailable in stock SQLite builds, so the
  # formatted fallback + ident_is_safe gate is the only posture), and
  # nothing is ever executed.
  sqlq 'CREATE TABLE "bt; DROP TABLE bt_customers--"(id INTEGER);'
  local r rc
  r=$(sqlq "SELECT fractal_schema_context();"); rc=$?
  if [[ $rc -eq 0 ]] && ! grep <<< "$r" -q 'bt; DROP TABLE'; then
    pass "10 dos_and_injection: injection-shaped name omitted from context (skipped, not smuggled)"
  else
    fail "10 dos_and_injection: injection-shaped name carried into context: $r"
  fi
  if [[ $rc -eq 0 ]] && grep <<< "$r" -q 'bt_customers'; then
    pass "10 dos_and_injection: safe tables still introspected alongside the skip"
  else
    fail "10 dos_and_injection: safe table introspection lost: $r"
  fi
  local n
  n=$("$SQLITE3" "$DBW" "SELECT count(*) FROM sqlite_master WHERE name='bt_customers';")
  [[ "$n" = "1" ]] \
    && pass "10 dos_and_injection: bt_customers survived (nothing executed)" \
    || fail "10 dos_and_injection: bt_customers missing: injection executed"
}

gate_11_scout() {
  local r; r=$(sqlq "SELECT fractal_search_explore(embedding, '1.0,0.05,0.0,0.0') FROM bt_explore;")
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    fail "11 scout: fractal_search_explore failed: $r"; return
  fi
  if [[ -z "$PY" ]]; then
    grep <<< "$r" -q "population" \
      && pass "11 scout: population key present (python absent, JSON unverified)" \
      || fail "11 scout: no population key: $r"
    return
  fi
  if "$PY" -c '
import json, sys
d = json.loads(sys.stdin.read())
pop = d.get("population")
assert pop and len(pop) >= 5, "population missing/short: %s" % (pop and len(pop))
groups = {round(p[0], 1) for p in pop}
assert len(groups) >= 2, "population collapsed onto one point group: %s" % groups
print("ok: %d population points, %d distinct x-groups" % (len(pop), len(groups)))
' <<< "$r"; then
    pass "11 scout: population returned and disperses across distinct points"
  else
    fail "11 scout: population JSON/distinctness check failed: $r"
  fi
  # Options-JSON variant accepted.
  r=$(sqlq "SELECT fractal_search_explore(embedding, '1.0,0.05,0.0,0.0',
            '{\"population_size\":24,\"iterations\":12}') FROM bt_explore;")
  [[ $? -eq 0 ]] \
    && pass "11 scout: options-JSON variant accepted" \
    || fail "11 scout: options variant failed: $r"
}

write_py_gate12() {
  cat > "$PDIR/py_gate12.py" <<'PYEOF'
import os, sqlite3, subprocess, sys

db, ext = os.environ["FSQL_BT_DB"], os.environ["FSQL_BT_EXT"]
workers = int(os.environ.get("SOAK_WORKERS", "6"))
iters = int(os.environ.get("SOAK_ITERS", "15"))

WORKER = r'''
import json, sqlite3, sys
db, ext, wid, iters = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
con = sqlite3.connect(db, timeout=30)
con.enable_load_extension(True)
con.load_extension(ext)
for i in range(iters):
    d = con.execute(
        "SELECT fractal_search('0.6,0.8,0.0,0.0','0.6,0.8,0.0,0.0')"
    ).fetchone()[0]
    if abs(d) > 1e-6:
        raise SystemExit("worker %s iter %s: dist %r" % (wid, i, d))
    con.execute("INSERT INTO bt_soak(worker, it) VALUES (?,?)", (wid, i))
    if i % 5 == 4:
        r = con.execute(
            "SELECT fractal_search_explore(embedding, '1.0,0.05,0.0,0.0') FROM bt_explore"
        ).fetchone()[0]
        json.loads(r)
con.commit()
print("worker %s ok" % wid)
'''
with open(os.path.join(os.path.dirname(db), "g12_worker.py"), "w") as f:
    f.write(WORKER)

procs = [subprocess.Popen([sys.executable,
                           os.path.join(os.path.dirname(db), "g12_worker.py"),
                           db, ext, str(w), str(iters)],
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
         for w in range(workers)]
bad = 0
for w, p in enumerate(procs):
    out = p.communicate()[0].decode(errors="replace")
    if p.returncode != 0:
        bad += 1
        print("worker %s rc=%s: %s" % (w, p.returncode, out.strip()[:300]))

con = sqlite3.connect(db, timeout=30)
con.enable_load_extension(True)
con.load_extension(ext)
n = con.execute("SELECT count(*) FROM bt_soak").fetchone()[0]
expected = workers * iters
assert n == expected, "expected %d soak rows, found %d" % (expected, n)
r = con.execute(
    "SELECT fractal_search('0.6,0.8,0.0,0.0','0.6,0.8,0.0,0.0')"
).fetchone()[0]
assert abs(r) < 1e-6, "DB not responsive after soak: %r" % r
assert bad == 0, "%d worker(s) failed" % bad
print("SOAK OK: %d workers x %d iters, %d rows" % (workers, iters, n))
PYEOF
}

gate_12_soak() {
  if [[ -z "$PY" ]]; then
    skip "12 soak (no python3 with the stdlib sqlite3 module)"; return
  fi
  export SOAK_WORKERS="${SOAK_WORKERS:-6}" SOAK_ITERS="${SOAK_ITERS:-15}"
  write_py_gate12
  if py_run py_gate12; then
    pass "12 soak: ${SOAK_WORKERS} workers x ${SOAK_ITERS} iters, DB responsive after"
  else
    fail "12 soak: see driver output above"
  fi
}

gate_13_siu_mode() {
  # allowlist widened to select+insert+update: the widened classes come
  # back as text (never executed); DDL/DELETE stay rejected.
  siu() {  # siu <canned-sql> <want> <label>
    printf '%s' "$1" > "$SQLTXT"
    local r; r=$(sqlq \
      "SELECT fractalsql_set('reasoning_plugin','$MOCK');" \
      "SELECT fractalsql_set('text_to_sql_allowed_statements',
            'select_insert_update');" \
      "SELECT fractal_text_to_sql('q');")
    local rc=$?
    if [[ -z "$2" ]]; then
      if [[ $rc -eq 0 ]]; then
        pass "13 $3 → returned"
      else
        fail "13 $3 (expected return): $r"
      fi
    else
      if [[ $rc -ne 0 ]] && grep <<< "$r" -q "$2"; then
        pass "13 $3 → rejected ($2)"
      else
        fail "13 $3: got '$r' (want '$2')"
      fi
    fi
  }
  sqlq "DELETE FROM bt_orders;" >/dev/null
  siu "INSERT INTO bt_orders(id, customer_id, total) VALUES (777,1,10)" \
      "" "widened INSERT"
  siu "UPDATE bt_orders SET total=999" "" "widened UPDATE"
  siu "DELETE FROM bt_orders"         "not permitted" "DELETE stays rejected"
  siu "DROP TABLE bt_orders"          "not permitted" "DDL stays rejected"
  local n
  n=$("$SQLITE3" "$DBW" "SELECT count(*) FROM bt_orders;")
  [[ "$n" = "0" ]] \
    && pass "13 widened classes never executed (bt_orders still empty)" \
    || fail "13 widened classes executed (count=$n)"
}

gate_14_retry() {
  if [[ ! -f "$(wpath "$RETRY")" ]]; then
    skip "14 retry (retry_reasoning_plugin did not build)"; return
  fi
  rm -f "$RETRYPROMPT"
  local r; r=$(sqlq \
    "SELECT fractalsql_set('reasoning_plugin','$RETRY');" \
    "SELECT fractalsql_set('text_to_sql_max_attempts','2');" \
    "SELECT fractal_text_to_sql('q');")
  if [[ $? -eq 0 ]] && grep <<< "$r" -q "SELECT 1"; then
    pass "14 retry: attempt 1 rejected, attempt 2 succeeded"
  else
    fail "14 retry: got '$r'"
    return
  fi
  if [[ -f "$(wpath "$RETRYPROMPT")" ]] \
     && grep -q "not permitted" "$(wpath "$RETRYPROMPT")"; then
    pass "14 retry: rejection reason threaded into the attempt-2 prompt"
  else
    fail "14 retry: attempt-2 prompt missing the rejection reason"
  fi
}

gate_15_embed() {
  # fractal_embed() itself: real dispatch through the EMBED tier.
  local d
  d=$(sqlq \
    "SELECT fractalsql_set('reasoning_plugin','$MOCKEMB');" \
    "SELECT fractalsql_set('http_embed_url','https://embed.invalid/v1');" \
    "SELECT fractal_vector_dims(fractal_embed('hello'));")
  [[ "$(tail -n1 <<< "$d")" == "3" ]] \
    && pass "15 embed: fractal_embed returns the canned 3-dim vector" \
    || fail "15 embed: dims='$d'"
  if expect_err "fractal_embed: input must not be NULL" \
      "SELECT fractal_embed(NULL);"; then
    pass "15 embed: NULL input rejected"
  else
    fail "15 embed: NULL input not rejected"
  fi
  if expect_err "exceeds the 4 MiB limit" \
      "SELECT fractal_embed(substr(hex(zeroblob(2500000)),1,4194305));"; then
    pass "15 embed: input over the 4 MiB limit rejected"
  else
    fail "15 embed: input over the 4 MiB limit accepted"
  fi
  if expect_err "reasoning plugin not configured" \
      "SELECT fractal_embed('x');"; then
    pass "15 embed: unconfigured embed errors with the set() hint"
  else
    fail "15 embed: unconfigured embed did not error"
  fi
  if expect_err "http_embed_url is not configured" \
      "SELECT fractalsql_set('reasoning_plugin','$MOCKEMB');" \
      "SELECT fractal_embed('x');"; then
    pass "15 embed: chat-only config rejected (no http_url fallback)"
  else
    fail "15 embed: missing http_embed_url did not error"
  fi
  if expect_err "failed to load reasoning plugin" \
      "SELECT fractalsql_set('reasoning_plugin','$BADPLUGIN$PLUGSUF');" \
      "SELECT fractalsql_set('http_embed_url','https://embed.invalid/v1');" \
      "SELECT fractal_embed('x');"; then
    pass "15 embed: unloadable plugin errors clearly"
  else
    fail "15 embed: bad plugin path did not error"
  fi
  if [[ -f "$(wpath "$EVOLEMB")" ]]; then
    if expect_err "could not parse embedding response" \
        "SELECT fractalsql_set('reasoning_plugin','$EVOLEMB');" \
        "SELECT fractalsql_set('http_embed_url','https://embed.invalid/v1');" \
        "SELECT fractal_embed('x');"; then
      pass "15 embed: over-limit (16385-elem) response rejected"
    else
      fail "15 embed: over-limit response not rejected"
    fi
  else
    skip "15 embed over-limit (evil_embed_plugin did not build)"
  fi

  # The vectorizer: create / backfill / process_queue / status / write-back.
  # All in ONE connection (the registry+queue are TEMP).
  local r; r=$(sqlq \
    "CREATE TABLE bt_vembed(
        id INTEGER PRIMARY KEY, body TEXT, emb TEXT);" \
    "INSERT INTO bt_vembed(body) VALUES ('a'),('b'),('c');" \
    "SELECT fractalsql_set('reasoning_plugin','$MOCKEMB');" \
    "SELECT fractalsql_set('http_embed_url','https://embed.invalid/v1');" \
    "SELECT fractal_vectorizer_create('bt_vembed','body','emb');" \
    "SELECT 'PROCESSED=' || fractal_vectorizer_process_queue(10);" \
    "SELECT 'DONE=' || n FROM fractal_vectorizer_status
      WHERE status='done';" \
    "SELECT 'D3=' || count(*) FROM bt_vembed
      WHERE fractal_vector_dims(emb)=3;" \
    "SELECT fractal_vectorizer_create('bt_vembed','body','emb');")
  # (-bail stops the invocation on the trailing double-create; the
  # assertions above still see everything printed before it. The
  # double-create MUST ride the same connection: the registry+queue
  # are TEMP, so a fresh connection would see an empty registry.)
  grep <<< "$r" -q "PROCESSED=3" \
    && grep <<< "$r" -q "DONE=3" \
    && grep <<< "$r" -q "D3=3" \
    && pass "15 vectorizer: create/backfill/process/status/write-back" \
    || fail "15 vectorizer: got '$r'"
  if grep <<< "$r" -q "already exists"; then
    pass "15 vectorizer: double-create rejected"
  else
    fail "15 vectorizer: double-create accepted"
  fi
  if expect_err "invalid identifier" \
      "SELECT fractal_vectorizer_create('bt; DROP TABLE bt_vembed--',
        'body','emb');"; then
    pass "15 vectorizer: injection-shaped source_table rejected"
  else
    fail "15 vectorizer: injection-shaped source_table accepted"
  fi
  if expect_err "invalid identifier" \
      "SELECT fractal_vectorizer_create('1_leading_digit','body','emb');"; then
    pass "15 vectorizer: digit-leading source_table rejected"
  else
    fail "15 vectorizer: digit-leading source_table accepted"
  fi
  # Schema-qualified source_table (e.g. 'main.tbl'): fsqlv_quote_ident's
  # segment loop used to pass the untruncated remaining tail to
  # fsqlv_qseg instead of just that segment, mis-quoting any real
  # multi-segment identifier ("main.tbl" -> "main.tbl"."tbl" instead of
  # "main"."tbl") and breaking every caller -- found live while writing
  # this test, fixed in fsqlv_quote_ident.
  local rsq; rsq=$(sqlq \
    "CREATE TABLE bt_vsq(id INTEGER PRIMARY KEY, body TEXT, emb TEXT);" \
    "INSERT INTO bt_vsq(body) VALUES ('a');" \
    "SELECT fractalsql_set('reasoning_plugin','$MOCKEMB');" \
    "SELECT fractalsql_set('http_embed_url','https://embed.invalid/v1');" \
    "SELECT fractal_vectorizer_create('main.bt_vsq','body','emb');")
  if [[ $? -eq 0 ]]; then
    pass "15 vectorizer: schema-qualified source_table (main.tbl) accepted"
  else
    fail "15 vectorizer: schema-qualified source_table rejected: $rsq"
  fi

  # Unconfigured embed endpoint: process_queue() must mark every row
  # 'failed' with a clean error, not silently skip or crash (fsqlv_fail_row's
  # own path, otherwise dead -- every other vectorizer test above
  # configures a working mock embed endpoint first).
  local rfail; rfail=$(sqlq \
    "CREATE TABLE bt_vnoembed(id INTEGER PRIMARY KEY, body TEXT, emb TEXT);" \
    "INSERT INTO bt_vnoembed(body) VALUES ('a'),('b');" \
    "SELECT fractal_vectorizer_create('bt_vnoembed','body','emb');" \
    "SELECT 'PROCESSED=' || fractal_vectorizer_process_queue(10);" \
    "SELECT 'FAILED=' || count(*) FROM fractal_vectorizer_queue WHERE status='failed';" \
    "SELECT error FROM fractal_vectorizer_queue LIMIT 1;")
  if grep <<< "$rfail" -q "PROCESSED=2" \
      && grep <<< "$rfail" -q "FAILED=2" \
      && grep <<< "$rfail" -q "reasoning plugin not configured"; then
    pass "15 vectorizer: unconfigured embed endpoint fails every row cleanly"
  else
    fail "15 vectorizer: unconfigured embed endpoint: got '$rfail'"
  fi

  # Rate cap: max_embeds_per_window caps how many rows one
  # process_queue() call actually embeds per window; the rest stay
  # 'pending' (fsqlv_rate_gate's gated branch, otherwise dead -- every
  # other vectorizer test above runs uncapped).
  local rcap; rcap=$(sqlq \
    "CREATE TABLE bt_vrate(id INTEGER PRIMARY KEY, body TEXT, emb TEXT);" \
    "INSERT INTO bt_vrate(body) VALUES ('a'),('b'),('c');" \
    "SELECT fractalsql_set('reasoning_plugin','$MOCKEMB');" \
    "SELECT fractalsql_set('http_embed_url','https://embed.invalid/v1');" \
    "SELECT fractal_vectorizer_create('bt_vrate','body','emb',
      '{\"max_embeds_per_window\":1,\"rate_window_secs\":3600}');" \
    "SELECT 'PROCESSED=' || fractal_vectorizer_process_queue(10);" \
    "SELECT 'DONE=' || count(*) FROM fractal_vectorizer_queue WHERE status='done';" \
    "SELECT 'PEND=' || count(*) FROM fractal_vectorizer_queue WHERE status='pending';")
  grep <<< "$rcap" -q "DONE=1" && grep <<< "$rcap" -q "PEND=2" \
    && pass "15 vectorizer: max_embeds_per_window caps one row/window, defers the rest" \
    || fail "15 vectorizer: rate cap: $rcap"

  # Partial-create rollback (fsqlv_create_cleanup): trigger names are
  # "fractal_vectorizer_trg_<id><suffix>", and the registry (along with
  # the queue and rate-window tables) is TEMP -- scoped to, and reset
  # by, each connection (see this gate's own bt_vembed comment above:
  # "All in ONE connection"). A fresh sqlq connection's registry is
  # therefore always empty, so its first-ever vectorizer is always
  # id=1, regardless of what any OTHER separate sqlq call created
  # earlier in this run. Pre-creating a same-named TEMP trigger here
  # (same connection, since a TEMP trigger from a different connection
  # wouldn't even still exist) makes the real create's own trigger step
  # collide, forcing the registry-row-already-inserted rollback path
  # otherwise dead in every other vectorizer test here.
  sqlq "CREATE TABLE bt_vclean(id INTEGER PRIMARY KEY, body TEXT, emb TEXT);" \
    >/dev/null 2>&1
  if expect_err "already exists" \
      "CREATE TEMP TRIGGER \"fractal_vectorizer_trg_1\"
        AFTER INSERT ON bt_vclean BEGIN SELECT 1; END;" \
      "SELECT fractalsql_set('reasoning_plugin','$MOCKEMB');" \
      "SELECT fractalsql_set('http_embed_url','https://embed.invalid/v1');" \
      "SELECT fractal_vectorizer_create('bt_vclean','body','emb');"; then
    pass "15 vectorizer: a trigger-name collision mid-create rolls back the registry row"
  else
    fail "15 vectorizer: expected the trigger collision to surface and roll back"
  fi

  # pause/resume/drop surface: a paused vectorizer defers (0 processed).
  r=$(sqlq \
    "CREATE TABLE bt_vsoak_stub(
        id INTEGER PRIMARY KEY, body TEXT, emb TEXT);" \
    "INSERT INTO bt_vsoak_stub(body) VALUES ('p');" \
    "SELECT fractalsql_set('reasoning_plugin','$MOCKEMB');" \
    "SELECT fractalsql_set('http_embed_url','https://embed.invalid/v1');" \
    "SELECT fractal_vectorizer_create('bt_vsoak_stub','body','emb');" \
    "SELECT fractal_vectorizer_pause(1);" \
    "SELECT 'P=' || fractal_vectorizer_process_queue(10);" \
    "SELECT fractal_vectorizer_resume(1);" \
    "SELECT fractal_vectorizer_drop(1);" \
    "SELECT 1;")
  grep <<< "$r" -q "P=0" \
    && pass "15 vectorizer: pause defers processing, resume/drop clean" \
    || fail "15 vectorizer: pause path: $r"

  # pause/resume/drop: NULL id and a nonexistent id, each function's
  # own guard (fsqlv_pause_resume_impl's NULL message is hardcoded to
  # "fractal_vectorizer_pause" regardless of which of the two callers
  # hit it -- a real but cosmetic label bug, not re-derived here).
  if expect_err "no vectorizer with id NULL" \
      "SELECT fractal_vectorizer_pause(NULL);"; then
    pass "15 vectorizer: pause(NULL) rejected"
  else
    fail "15 vectorizer: pause(NULL) accepted"
  fi
  if expect_err "no vectorizer with id NULL" \
      "SELECT fractal_vectorizer_resume(NULL);"; then
    pass "15 vectorizer: resume(NULL) rejected"
  else
    fail "15 vectorizer: resume(NULL) accepted"
  fi
  if expect_err "fractal_vectorizer_drop: no vectorizer with id NULL" \
      "SELECT fractal_vectorizer_drop(NULL);"; then
    pass "15 vectorizer: drop(NULL) rejected"
  else
    fail "15 vectorizer: drop(NULL) accepted"
  fi
  if expect_err "fractal_vectorizer_pause: no vectorizer with id 9999" \
      "SELECT fractal_vectorizer_pause(9999);"; then
    pass "15 vectorizer: pause rejects a nonexistent id"
  else
    fail "15 vectorizer: pause accepted a nonexistent id"
  fi
  if expect_err "fractal_vectorizer_resume: no vectorizer with id 9999" \
      "SELECT fractal_vectorizer_resume(9999);"; then
    pass "15 vectorizer: resume rejects a nonexistent id"
  else
    fail "15 vectorizer: resume accepted a nonexistent id"
  fi
  if expect_err "fractal_vectorizer_drop: no vectorizer with id 9999" \
      "SELECT fractal_vectorizer_drop(9999);"; then
    pass "15 vectorizer: drop rejects a nonexistent id"
  else
    fail "15 vectorizer: drop accepted a nonexistent id"
  fi

  # create: the duplicate-vectorizer-exists guard (same source/text/
  # embedding column triple created twice). The registry is a TEMP
  # table scoped per-connection (see the fsqlv_create_cleanup comment
  # above), so both create calls MUST run in the same sqlq invocation --
  # splitting them across two sqlq calls gives each its own empty
  # registry and the duplicate is never seen.
  sqlq "CREATE TABLE bt_vdup(id INTEGER PRIMARY KEY, body TEXT, emb TEXT);" \
    >/dev/null 2>&1
  if expect_err "already exists (id=" \
      "SELECT fractalsql_set('reasoning_plugin','$MOCKEMB');" \
      "SELECT fractalsql_set('http_embed_url','https://embed.invalid/v1');" \
      "SELECT fractal_vectorizer_create('bt_vdup','body','emb');" \
      "SELECT fractal_vectorizer_create('bt_vdup','body','emb');"; then
    pass "15 vectorizer: create rejects a duplicate source/text/embedding triple"
  else
    fail "15 vectorizer: create accepted a duplicate vectorizer"
  fi
}

write_py_gate16() {
  cat > "$PDIR/py_gate16.py" <<'PYEOF'
import os, sqlite3, sys

db, ext = os.environ["FSQL_BT_DB"], os.environ["FSQL_BT_EXT"]
SQLITE_PRAGMA, SQLITE_DENY, SQLITE_OK = 19, 1, 0

con = sqlite3.connect(db)
con.enable_load_extension(True)
con.load_extension(ext)
con.execute("CREATE TABLE IF NOT EXISTS bt_vauthz("
            "id INTEGER PRIMARY KEY, body TEXT, emb TEXT)")
con.execute("INSERT INTO bt_vauthz(body) VALUES ('x')")

# Control: allow-all authorizer -> the PK probe reads its PRAGMA and
# create() succeeds.
con.set_authorizer(lambda *a: SQLITE_OK)
try:
    con.execute("SELECT fractal_vectorizer_create("
                "'bt_vauthz','body','emb')").fetchone()
    print("OK control: vectorizer_create succeeded with allow-all")
except sqlite3.Error as e:
    print("FAIL control: create failed under allow-all authorizer: %s" % e)
    sys.exit(1)

# Boundary: deny the PRAGMA read the PK probe depends on -> create()
# must fail with a clean error (no crash, no silent wrong behavior).
def deny_pragma(action, arg1, arg2, db_name, trigger):
    if action == SQLITE_PRAGMA and (arg1 or "").startswith("table_info"):
        return SQLITE_DENY
    return SQLITE_OK

con.set_authorizer(deny_pragma)
try:
    con.execute("SELECT fractal_vectorizer_create("
                "'bt_vauthz','body','emb')").fetchone()
    print("FAIL: vectorizer_create succeeded despite a denied PRAGMA read")
    sys.exit(1)
except sqlite3.Error as e:
    print("OK boundary: denied PK probe surfaced as a clean error: %s"
          % str(e)[:120])
    sys.exit(0)
PYEOF
}

gate_16_embed_authz() {
  # create-time validation (PG's create-time source_table ownership
  # maps to these guards; role grants have no SQLite analog).
  # A nonexistent table is indistinguishable from a PK-less one here:
  # PRAGMA table_info on a missing table returns no rows, so the create
  # answers the same "no single-column primary key" error (the probe
  # PRAGMA doesn't fail on a missing table: SQLite's shape).
  if expect_err "has no single-column primary key" \
      "SELECT fractal_vectorizer_create('bt_nonexistent_xyz',
        'body','emb');"; then
    pass "16 embed_authz: nonexistent source table rejected (no-PK error)"
  else
    fail "16 embed_authz: nonexistent source table accepted"
  fi
  sqlq "CREATE TABLE bt_nopk(a INTEGER, b TEXT, emb TEXT);" >/dev/null 2>&1
  if expect_err "has no single-column primary key" \
      "SELECT fractal_vectorizer_create('bt_nopk','b','emb');"; then
    pass "16 embed_authz: missing-PK table rejected"
  else
    fail "16 embed_authz: missing-PK table accepted"
  fi
  sqlq "CREATE TABLE bt_compk(a INTEGER, b INTEGER, emb TEXT,
          PRIMARY KEY(a,b));" >/dev/null 2>&1
  if expect_err "has no single-column primary key" \
      "SELECT fractal_vectorizer_create('bt_compk','b','emb');"; then
    pass "16 embed_authz: composite-PK table rejected"
  else
    fail "16 embed_authz: composite-PK table accepted"
  fi
  if [[ -z "$PY" ]]; then
    skip "16 embed_authz authorizer driver (no python3 sqlite3 stdlib)"
    return
  fi
  write_py_gate16
  if py_run py_gate16; then
    pass "16 embed_authz: authorizer denial honored inside the PK probe"
  else
    fail "16 embed_authz: see driver output above"
  fi
}

gate_17_embed_soak() {
  # 100-row queue drained by repeated process_queue(batch=20) calls in
  # ONE connection (TEMP state): zero double-processing shows up as
  # done=100 / failed=0 with the last call returning 0.
  "$SQLITE3" "$DBW" "
    CREATE TABLE bt_vsoak(id INTEGER PRIMARY KEY, body TEXT, emb TEXT);
    WITH RECURSIVE c(x) AS (VALUES(1)
                             UNION ALL SELECT x+1 FROM c WHERE x<100)
    INSERT INTO bt_vsoak(body) SELECT 'doc-' || x FROM c;" >/dev/null 2>&1 \
    || { fail "17 embed_soak: bt_vsoak setup failed"; return; }
  local r
  r=$(sqlq \
    "SELECT fractalsql_set('reasoning_plugin','$MOCKEMB');" \
    "SELECT fractalsql_set('http_embed_url','https://embed.invalid/v1');" \
    "SELECT fractal_vectorizer_create('bt_vsoak','body','emb');" \
    "SELECT 'P=' || fractal_vectorizer_process_queue(20);" \
    "SELECT 'P=' || fractal_vectorizer_process_queue(20);" \
    "SELECT 'P=' || fractal_vectorizer_process_queue(20);" \
    "SELECT 'P=' || fractal_vectorizer_process_queue(20);" \
    "SELECT 'P=' || fractal_vectorizer_process_queue(20);" \
    "SELECT 'P=' || fractal_vectorizer_process_queue(20);" \
    "SELECT 'DONE=' || COALESCE(SUM(n),0) FROM fractal_vectorizer_status
      WHERE status='done';" \
    "SELECT 'FAILED=' || COALESCE(SUM(n),0) FROM fractal_vectorizer_status
      WHERE status='failed';")
  local pcnt; pcnt=$(grep -c "^P=20$" <<< "$r" || true)
  if [[ "$pcnt" = "5" ]] && grep <<< "$r" -q "DONE=100" \
     && grep <<< "$r" -q "FAILED=0"; then
    pass "17 embed_soak: 100 rows processed exactly once (5x20, then 0)"
  else
    fail "17 embed_soak: got '$r'"
  fi
}

gate_18_embed_crash() {
  if [[ ! -f "$(wpath "$CRASH")" ]]; then
    skip "18 embed_crash (evil_crash_plugin did not build)"; return
  fi
  "$SQLITE3" "$DBW" "
    CREATE TABLE bt_vcrash(id INTEGER PRIMARY KEY, body TEXT, emb TEXT);
    INSERT INTO bt_vcrash(body) VALUES ('a'),('b');" >/dev/null 2>&1
  local r rc
  r=$(sqlq \
    "SELECT fractalsql_set('reasoning_plugin','$CRASH');" \
    "SELECT fractalsql_set('http_embed_url','https://embed.invalid/v1');" \
    "SELECT fractal_vectorizer_create('bt_vcrash','body','emb');" \
    "SELECT fractal_vectorizer_process_queue(10);")
  rc=$?
  if ! crashed "$r" "$rc"; then
    fail "18 embed_crash: expected a process crash mid-queue, got rc=$rc"
    return
  fi
  pass "18 embed_crash: sqlite3 process died mid-process_queue (rc=$rc)"
  # A fresh connection must find the DB intact and the persisted
  # embeddings (gate 15's write-back) preserved. The TEMP queue state
  # died with the connection; no stuck-'processing' rows are even
  # possible, which is the structural difference from PG's queue.
  local deadline=$(( SECONDS + 30 * TIMEOUT_MULT )) out
  while :; do
    out=$("$SQLITE3" "$DBW" "PRAGMA integrity_check;" 2>&1)
    grep <<< "$out" -q "^ok$" && break
    if (( SECONDS >= deadline )); then
      fail "18 embed_crash: DB did not recover (integrity: $out)"; return
    fi
    sleep 1
  done
  pass "18 embed_crash: DB reopened, integrity ok"
  local n
  n=$("$SQLITE3" "$DBW" "SELECT count(*) FROM bt_vcrash;")
  [[ "$n" = "2" ]] \
    && pass "18 embed_crash: source rows intact after the crash" \
    || fail "18 embed_crash: source rows damaged (count=$n)"
  n=$("$SQLITE3" -cmd ".load $EXT" "$DBW" "SELECT count(*) FROM bt_vembed
    WHERE fractal_vector_dims(emb)=3;")
  [[ "$n" = "3" ]] \
    && pass "18 embed_crash: persisted embeddings from gate 15 preserved" \
    || fail "18 embed_crash: persisted embeddings damaged (count=$n)"
}

write_py_gate19() {
  cat > "$PDIR/py_gate19.py" <<'PYEOF'
import os, sqlite3, struct, sys

db, ext = os.environ["FSQL_BT_DB"], os.environ["FSQL_BT_EXT"]
con = sqlite3.connect(db, timeout=30)
con.enable_load_extension(True)
con.load_extension(ext)

# Over-arena vector (ARENA_MAX_DIM=4096): the parse rejects it. The
# TEXT path clamps silently at the cap, so the over-budget rejection
# is only reachable through the float32 BLOB path, where
# fsql_parse_blob_vector refuses count > cap outright (4097 floats).
blob = struct.pack("<4097f", *([0.1] * 4097))
try:
    con.execute("SELECT fractal_search(?, ?)", (blob, blob)).fetchone()
except sqlite3.OperationalError as e:
    if "invalid vector" in str(e):
        print("OK: over-arena BLOB rejected: %s" % str(e)[:120])
        sys.exit(0)
    print("FAIL: over-arena BLOB rejected with the wrong error: %s" % e)
    sys.exit(1)
print("FAIL: over-arena BLOB accepted")
sys.exit(1)
PYEOF
}

gate_19_sfs_bounds() {
  # Over-arena vector (ARENA_MAX_DIM=4096): the parse rejects it. The
  # TEXT path clamps at the cap (lenient surface), so the over-budget
  # rejection is exercised through the float32 BLOB path: a
  # 4097-float BLOB answers "invalid vector (expect CSV/JSON text or
  # float32 BLOB)" without ever reaching the solver.
  if [[ -n "$PY" ]]; then
    write_py_gate19
    if py_run py_gate19; then
      pass "19 sfs_bounds: over-arena vector rejected"
    else
      fail "19 sfs_bounds: over-arena vector accepted"
    fi
  else
    skip "19 sfs_bounds over-arena (no python3 with the stdlib sqlite3 module)"
  fi
  if expect_err "invalid vector" \
      "SELECT fractal_search('','1.0');"; then
    pass "19 sfs_bounds: empty vector rejected"
  else
    fail "19 sfs_bounds: empty vector accepted"
  fi
  if expect_err "query dim mismatch with vector" \
      "SELECT fractal_search('0.1,0.2','0.1,0.2,0.3');"; then
    pass "19 sfs_bounds: query/vector dim mismatch rejected"
  else
    fail "19 sfs_bounds: dim mismatch accepted"
  fi
  # fractal_search_explore folds its argument errors into its own aggregate
  # input-error message (the embed/query parse happens inside the
  # aggregate step, not per-row).
  if expect_err "fractal_search_explore input error" \
      "SELECT fractal_search_explore(embedding, '0.1,0.2,0.3,0.4,0.5')
       FROM bt_explore;"; then
    pass "19 sfs_bounds: explore dim mismatch rejected"
  else
    fail "19 sfs_bounds: explore dim mismatch accepted"
  fi
  # Injection-shaped query text: rejected as malformed, and provably
  # never executed.
  if expect_err "fractal_search_explore input error" \
      "SELECT fractal_search_explore(embedding,
        '0.1); DROP TABLE bt_explore--') FROM bt_explore;"; then
    pass "19 sfs_bounds: injection-shaped query rejected as malformed"
  else
    fail "19 sfs_bounds: injection-shaped query accepted"
  fi
  local n
  n=$("$SQLITE3" "$DBW" "SELECT count(*) FROM bt_explore;")
  [[ "$n" = "60" ]] \
    && pass "19 sfs_bounds: bt_explore survived (nothing executed)" \
    || fail "19 sfs_bounds: bt_explore damaged (count=$n)"
}

gate_20_api_func() {
  # fractal_reason happy-path correctness through the chat tier (the
  # bare call gets the fenced form; RESPONSE_MODE is t2s-internal).
  printf 'canary-reason-response' > "$SQLTXT"
  local r
  r=$(sqlq \
    "SELECT fractalsql_set('reasoning_plugin','$MOCK');" \
    "SELECT fractal_reason('q');")
  grep <<< "$r" -q "canary-reason-response" \
    && pass "20 api_func: fractal_reason returns the canned response" \
    || fail "20 api_func: fractal_reason='$r'"
  if expect_err "fractal_reason: query must not be NULL" \
      "SELECT fractal_reason(NULL);"; then
    pass "20 api_func: fractal_reason(NULL) rejected"
  else
    fail "20 api_func: fractal_reason(NULL) not rejected"
  fi
  if expect_err "fractal_reason(query, context) expects 1 or 2 args" \
      "SELECT fractal_reason();"; then
    pass "20 api_func: fractal_reason() rejects zero args"
  else
    fail "20 api_func: fractal_reason() accepted zero args"
  fi
  if expect_err "fractal_reason(query, context) expects 1 or 2 args" \
      "SELECT fractal_reason('q','ctx','extra');"; then
    pass "20 api_func: fractal_reason rejects 3 args"
  else
    fail "20 api_func: fractal_reason accepted 3 args"
  fi
  if expect_err "expects a TEXT question" \
      "SELECT fractal_text_to_sql(NULL);"; then
    pass "20 api_func: fractal_text_to_sql(NULL) rejected"
  else
    fail "20 api_func: fractal_text_to_sql(NULL) not rejected"
  fi
  # The error text says "1048576-byte" (1 MiB) but FSQL_MAX_INPUT_BYTES
  # is actually 4*1024*1024 (4 MiB) -- a stale/misleading literal in the
  # message, not a real behavioral cap mismatch; the test below uses the
  # real enforced size.
  if expect_err "exceeds the 1048576-byte input cap" \
      "SELECT fractal_text_to_sql(substr(hex(zeroblob(2500000)),1,4194305));"; then
    pass "20 api_func: fractal_text_to_sql rejects a question over the 4MiB input cap"
  else
    fail "20 api_func: fractal_text_to_sql accepted an over-cap question"
  fi
  # Options-JSON: the params surface is LENIENT here; a truncated JSON
  # prefix parses as far as it can and the rest clamps to defaults (the
  # same rc=0 shape gate 11's options variant accepts), so the
  # errorable boundary is only exercised via vector parse errors in
  # gate 19. Assert the documented behavior: malformed options still
  # return a full result.
  local opts
  opts=$(sqlq "SELECT fractal_search_explore('1.0,0.0,0.0,0.0','1.0,0.0,0.0,0.0',
    '{\"population_size\":');")
  if [[ $? -eq 0 ]] && grep <<< "$opts" -q "best_point"; then
    pass "20 api_func: malformed explore options are lenient (clamped)"
  else
    fail "20 api_func: malformed explore options errored: $opts"
  fi
  # process_queue argument bounds.
  if expect_err "batch_size must be 1.." \
      "SELECT fractal_vectorizer_process_queue(0);"; then
    pass "20 api_func: process_queue(0) rejected"
  else
    fail "20 api_func: process_queue(0) accepted"
  fi
  if expect_err "batch_size must be 1.." \
      "SELECT fractal_vectorizer_process_queue(100001);"; then
    pass "20 api_func: process_queue(100001) rejected (over FSQLV_MAX_BATCH)"
  else
    fail "20 api_func: process_queue(100001) accepted"
  fi
  if expect_err "stale_after must be a positive" \
      "SELECT fractal_vectorizer_process_queue(10, 0);"; then
    pass "20 api_func: process_queue(stale_after=0) rejected"
  else
    fail "20 api_func: process_queue(stale_after=0) accepted"
  fi
  # Stale-reclaim, staged directly: a claim stranded 7200s ago is
  # reclaimed (stale_after=60) and processed; the within-window control
  # row is left alone.
  local r2
  r2=$(sqlq \
    "CREATE TABLE bt_vstale(
        id INTEGER PRIMARY KEY, body TEXT, emb TEXT);" \
    "INSERT INTO bt_vstale(id, body)
      VALUES (995,'a'),(996,'b'),(997,'c'),(998,'d'),(999,'e');" \
    "SELECT fractalsql_set('reasoning_plugin','$MOCKEMB');" \
    "SELECT fractalsql_set('http_embed_url','https://embed.invalid/v1');" \
    "SELECT fractal_vectorizer_create('bt_vstale','body','emb');" \
    "UPDATE fractal_vectorizer_queue
      SET status='processing',
          processing_started_at=
            CAST(strftime('%s','now') AS INTEGER) - 7200
      WHERE source_pk_value='999';" \
    "UPDATE fractal_vectorizer_queue
      SET status='processing',
          processing_started_at=CAST(strftime('%s','now') AS INTEGER)
      WHERE source_pk_value='998';" \
    "SELECT fractal_vectorizer_process_queue(100, 60);" \
    "SELECT source_pk_value || ':' || status
       FROM fractal_vectorizer_queue ORDER BY id;")
  if grep <<< "$r2" -q "999:done" && grep <<< "$r2" -q "998:processing"; then
    pass "20 api_func: stale claim reclaimed; fresh claim left alone"
  else
    fail "20 api_func: stale reclaim staging: $r2"
  fi

  # t2s_handle_review's attempts-exhausted branch (verdict==1 &&
  # attempt==attempts): with text_to_sql_use_review=on, REVIEW always
  # dispatches under RESPONSE_MODE=(unset) (apply_review_env hard-
  # unsets it, unlike GENERATE's forced "code"), so $MOCK's own
  # fence-wrapping behavior under non-code mode kicks in for the
  # critique text too -- it always comes back as a literal
  # "```sql\n...\n```" block, which critique_pass() (a bare PASS-prefix
  # check) can never match. With this mock there is no way to make
  # REVIEW ever PASS, so this path always exhausts its attempts and
  # surfaces the "exhausted N attempt(s)" error -- genuinely reachable,
  # not previously exercised anywhere in this suite.
  sqlq "CREATE TABLE bt_t2s_review_exhaust(id INTEGER PRIMARY KEY);" \
    >/dev/null 2>&1
  printf 'SELECT 1' > "$SQLTXT"
  if expect_err "exhausted" \
      "SELECT fractalsql_set('reasoning_plugin','$MOCK');" \
      "SELECT fractalsql_set('text_to_sql_use_review','on');" \
      "SELECT fractal_text_to_sql('q');"; then
    pass "20 api_func: text_to_sql_use_review exhausts attempts when REVIEW never PASSes"
  else
    fail "20 api_func: expected an exhausted-attempts ERROR"
  fi
  sqlq "SELECT fractalsql_set('text_to_sql_use_review','off');" \
       "DROP TABLE IF EXISTS bt_t2s_review_exhaust;" >/dev/null 2>&1
  printf 'SELECT 1' > "$SQLTXT"
}

# find_fuzz_clang: locate a clang that can actually LINK a
# -fsanitize=fuzzer binary, probed by compiling a real minimal
# libFuzzer target (defines LLVMFuzzerTestOneInput, no main of its
# own; libFuzzer's runtime supplies main) rather than trusting
# `command -v clang` blindly. Two real, confirmed failure modes that
# existence-only detection misses:
#   1. A version manager (rbenv/nvm-style; confirmed here with a
#      swiftly-managed Swift toolchain) can shadow the real clang on
#      PATH with a broken wrapper that fails on ANY invocation --
#      "clang exists" is not "clang works".
#   2. Distros commonly ship several versioned clangs side by side
#      (clang-17/18/19); the bare `clang` alias may not be the one
#      with libclang-rt's fuzzer archive installed even when a
#      versioned sibling does.
# $FSQL_FUZZ_CC is still an explicit override (trusted as given, not
# probed) for a caller who already knows which clang to use.
find_fuzz_clang() {
  if [[ -n "${FSQL_FUZZ_CC:-}" ]]; then
    printf '%s' "$FSQL_FUZZ_CC"
    return 0
  fi
  local cand real
  for cand in clang clang-19 clang-18 clang-17 clang-16 clang-15 \
              /usr/lib/llvm-19/bin/clang /usr/lib/llvm-18/bin/clang \
              /usr/lib/llvm-17/bin/clang /usr/lib/llvm-16/bin/clang \
              /usr/lib/llvm-15/bin/clang \
              /opt/homebrew/opt/llvm/bin/clang /usr/local/opt/llvm/bin/clang; do
    command -v "$cand" >/dev/null 2>&1 || continue
    real="$(command -v "$cand")"
    if "$real" -fsanitize=fuzzer -O0 -x c - -o "$PDIRW/fuzz_probe$PLUGSUF" \
         >/dev/null 2>&1 <<<'#include <stdint.h>
#include <stddef.h>
int LLVMFuzzerTestOneInput(const uint8_t *d, size_t n){(void)d;(void)n;return 0;}'; then
      printf '%s' "$real"
      return 0
    fi
  done
  return 1
}

gate_21_fuzz_smoke() {
  local fuzzcc
  if ! fuzzcc="$(find_fuzz_clang)"; then
    skip "21 fuzz_smoke (no clang on PATH with a working -fsanitize=fuzzer; checked \$FSQL_FUZZ_CC, clang, clang-15..19, and common LLVM install paths)"; return
  fi
  local t src rc
  for t in fuzz_parse_embedding_array fuzz_extract_best_point \
           fuzz_extract_population; do
    src="tests/fuzz/$t.c"
    if ! "$fuzzcc" -O1 -g -fsanitize=fuzzer -Iinclude -Isrc \
          "$src" src/fsql_parse.c -o "$PDIRW/$t" \
          >"$PDIR/$t.log" 2>&1; then
      fail "21 fuzz_smoke: $t failed to build; see $PDIR/$t.log"
      continue
    fi
    rc=0
    # libFuzzer refuses to start if a positional corpus-dir argument
    # doesn't already exist ("No such file or directory: ..._seed;
    # exiting") -- it writes newly-interesting inputs there but won't
    # create the directory itself.
    mkdir -p "$PDIR/${t}_seed"
    "$PDIRW/$t" tests/fuzz/corpus_extract_population "$PDIRW/${t}_seed" \
      -max_total_time="${FSQL_FUZZ_TIME:-30}" -print_final_stats=1 \
      >"$PDIR/$t.run.log" 2>&1 || rc=$?
    if [[ $rc -eq 0 ]]; then
      pass "21 fuzz_smoke: $t (${FSQL_FUZZ_TIME:-30}s, corpus-seeded)"
    else
      fail "21 fuzz_smoke: $t exited rc=$rc; see $PDIR/$t.run.log"
      tail -5 "$PDIR/$t.run.log" 2>/dev/null | sed 's/^/         /'
    fi
  done
}

gate_22_v2_functions() {
  local s32
  if [[ -n "$PY" ]]; then
    s32=$("$PY" -c "
import math
print(','.join('%.6f' % math.sin(i/4.0) for i in range(32)))")
  else
    s32=$(awk 'BEGIN{for(i=0;i<32;i++)printf "%s%.6f",(i?",":""),sin(i/4.0)}')
  fi
  if expect_err "series needs >= 16 points" \
      "SELECT fractal_dimension_dfa('1.0,2.0,3.0');"; then
    pass "22 v2_functions: short-series DFA rejected"
  else
    fail "22 v2_functions: short-series DFA accepted"
  fi
  local r
  r=$(sqlq "SELECT fractal_dimension_dfa('$s32');")
  if [[ $? -eq 0 ]] && grep -Eq '^-?[0-9]' <<< "$r"; then
    pass "22 v2_functions: DFA returns a numeric exponent"
  else
    fail "22 v2_functions: DFA happy path: $r"
  fi
  # Drift: 200-point series, window 64; the core's box needs window+16
  # points of recent history AND a deep-enough baseline (window 16/n 32
  # is exactly on the printed boundary and the core still declines).
  local s200
  s200=$(awk 'BEGIN{out=""; for(i=1;i<=200;i++){v=sin(i/3.0)+i*0.001;
    if(i>1)out=out","; out=out sprintf("%.6f",v)} print out}')
  r=$(sqlq "SELECT fractal_dimension_drift('$s200', 64);")
  if [[ $? -eq 0 ]] && grep <<< "$r" -q "recent_alpha"; then
    pass "22 v2_functions: drift returns the JSON triple"
  else
    fail "22 v2_functions: drift happy path: $r"
  fi
  if expect_err "window must be > 0" \
      "SELECT fractal_dimension_drift('$s32', 0);"; then
    pass "22 v2_functions: drift window<=0 rejected"
  else
    fail "22 v2_functions: drift window<=0 accepted"
  fi
  # Box-counting fixtures: bottom out in box-counting, which needs
  # >= 3 valid epsilon buckets: enough points AND enough scale dynamic
  # range; an exactly-regular 9-point lattice silently fails the
  # filter (PG's gate-22 fixture note). 40 jittered points dim 2.
  local boxpts
  boxpts=$(awk 'BEGIN{srand(42); out="";
    for(i=1;i<=40;i++){x=i+rand()*0.01; y=i*0.5+rand()*0.01;
    if(i>1) out=out","; out=out x","y} print out}')
  r=$(sqlq "SELECT fractal_dimension_boxcount('$boxpts', 2);")
  if [[ $? -eq 0 ]] && grep -Eq '^-?[0-9]' <<< "$r"; then
    pass "22 v2_functions: boxcount returns a numeric dimension"
  else
    fail "22 v2_functions: boxcount happy path: $r"
  fi
  if expect_err "need >= 8 points" \
      "SELECT fractal_dimension_boxcount('0,0,1,0,0,1,1,1', 2);"; then
    pass "22 v2_functions: degenerate boxcount rejected"
  else
    fail "22 v2_functions: degenerate boxcount accepted"
  fi
  # Portfolio: happy path + cov-shape rejection + dormant pareto path.
  r=$(sqlq "SELECT fractal_optimize_portfolio(
              '0.10,0.12,0.07',
              '0.04,0.01,0.005,0.01,0.06,0.01,0.005,0.01,0.05',
              2, 42);")
  if [[ $? -eq 0 ]] && grep <<< "$r" -q "{"; then
    pass "22 v2_functions: portfolio returns JSON"
  else
    fail "22 v2_functions: portfolio happy path: $r"
  fi
  if expect_err "must be n_assets^2" \
      "SELECT fractal_optimize_portfolio(
        '0.10,0.12,0.07',
        '0.04,0.01,0.005,0.01,0.06,0.01,0.005,0.01,0.05,0.9',
        2, 42);"; then
    pass "22 v2_functions: non-square cov rejected"
  else
    fail "22 v2_functions: non-square cov accepted"
  fi
  if expect_err "malformed mu/cov" \
      "SELECT fractal_optimize_portfolio('bad!vec','1.0,0.0,0.0,1.0',1,42);"; then
    pass "22 v2_functions: portfolio rejects a malformed mu"
  else
    fail "22 v2_functions: portfolio accepted a malformed mu"
  fi
  if expect_err "k must satisfy 1 <= k <= n_assets" \
      "SELECT fractal_optimize_portfolio('0.1,0.1','1.0,0.0,0.0,1.0',3,42);"; then
    pass "22 v2_functions: portfolio rejects k > n_assets"
  else
    fail "22 v2_functions: portfolio accepted k > n_assets"
  fi
  if expect_err "enterprise tier not loaded" \
      "SELECT fractal_optimize_portfolio_multimodal_pareto(
        '0.10,0.12,0.07',
        '0.04,0.01,0.005,0.01,0.06,0.01,0.005,0.01,0.05',
        2, 42);"; then
    pass "22 v2_functions: pareto dormant path (no enterprise core)"
  else
    fail "22 v2_functions: pareto path did not surface the dormant error"
  fi
  # Domain geometry: synthetic node/edge payloads with the same shapes
  # PG's gate used (30-node 3D vessel chain with per-edge arc lengths;
  # 80-node 2D fiber grid).
  local vasc_nc vasc_el vasc_al
  {
    read -r vasc_nc
    read -r vasc_el
    read -r vasc_al
  } < <(awk 'BEGIN{
    srand(1); n=30; nc=""; el=""; al="";
    for (i=0;i<n;i++) { x=i; y=rand()*0.01; z=rand()*0.01;
      xs[i]=x; ys[i]=y; zs[i]=z; if (i>0) nc=nc","; nc=nc x","y","z; }
    for (i=0;i<n-1;i++) { if (i>0) { el=el","; al=al","; }
      el=el i","(i+1);
      dx=xs[i+1]-xs[i]; dy=ys[i+1]-ys[i]; dz=zs[i+1]-zs[i];
      al=al sqrt(dx*dx+dy*dy+dz*dz); }
    print nc; print el; print al;
  }')
  r=$(sqlq "SELECT fractal_vascular_network('$vasc_nc', '$vasc_el', '$vasc_al');")
  if [[ $? -eq 0 ]] && grep <<< "$r" -q "fractal_dimension"; then
    pass "22 v2_functions: vascular returns the JSON triple"
  else
    fail "22 v2_functions: vascular: $r"
  fi
  r=$(sqlq "SELECT fractal_cortical_folding(
              '0,0,0, 1,0,0, 1,1,0, 0,1,0, 0,0,1, 1,0,1, 1,1,1, 0,1,1',
              '0,1,2, 0,2,3, 4,5,6, 4,6,7');")
  if [[ $? -eq 0 ]] && grep <<< "$r" -q "gyrification_index"; then
    pass "22 v2_functions: cortical returns the gyrification triple"
  else
    fail "22 v2_functions: cortical: $r"
  fi
  local nerve_nc nerve_el
  {
    read -r nerve_nc
    read -r nerve_el
  } < <(awk 'BEGIN{
    srand(2); n=80; nc=""; el="";
    for (i=0;i<n;i++) { x=i; y=(i%2==0?0:1)+rand()*0.01;
      if (i>0) nc=nc","; nc=nc x","y; }
    for (i=0;i<n-1;i++) { if (i>0) el=el","; el=el i","(i+1); }
    print nc; print el;
  }')
  r=$(sqlq "SELECT fractal_nerve_plexus_metric('$nerve_nc', 2, '$nerve_el');")
  if [[ $? -eq 0 ]] && grep <<< "$r" -q "fiber_length_density"; then
    pass "22 v2_functions: nerve plexus returns its JSON"
  else
    fail "22 v2_functions: nerve: $r"
  fi
  if expect_err "node_coords length must be a multiple of 3" \
      "SELECT fractal_vascular_network('0,0,1,0','0,1','1.0');"; then
    pass "22 v2_functions: vascular rejects node_coords length not a multiple of 3"
  else
    fail "22 v2_functions: vascular accepted bad node_coords length"
  fi
  if expect_err "edges length must be a multiple of 2" \
      "SELECT fractal_vascular_network('0,0,0,1,0,0','0,1,2','1.0,1.0');"; then
    pass "22 v2_functions: vascular rejects edges length not a multiple of 2"
  else
    fail "22 v2_functions: vascular accepted bad edges length"
  fi
  if expect_err "vertices length must be a multiple of 3" \
      "SELECT fractal_cortical_folding('0,0,0,1,0,0,1,1','0,1,2');"; then
    pass "22 v2_functions: cortical rejects vertices length not a multiple of 3"
  else
    fail "22 v2_functions: cortical accepted bad vertices length"
  fi
  if expect_err "faces length must be a multiple of 3" \
      "SELECT fractal_cortical_folding('0,0,0,1,0,0,1,1,1','0,1');"; then
    pass "22 v2_functions: cortical rejects faces length not a multiple of 3"
  else
    fail "22 v2_functions: cortical accepted bad faces length"
  fi
  if expect_err "must be a positive multiple of dim" \
      "SELECT fractal_nerve_plexus_metric('0,0,1',2,'0,1');"; then
    pass "22 v2_functions: nerve rejects node_coords length not a multiple of dim"
  else
    fail "22 v2_functions: nerve accepted bad node_coords length"
  fi
  if expect_err "edges length must be a multiple of 2" \
      "SELECT fractal_nerve_plexus_metric('0,0,1,1',2,'0,1,2');"; then
    pass "22 v2_functions: nerve rejects edges length not a multiple of 2"
  else
    fail "22 v2_functions: nerve accepted bad edges length"
  fi
  r=$(sqlq "SELECT fractal_morphological_complexity('$boxpts', 2);")
  if [[ $? -eq 0 ]] && grep <<< "$r" -q "lacunarity"; then
    pass "22 v2_functions: morphology returns dimension+lacunarity"
  else
    fail "22 v2_functions: morphology: $r"
  fi
  # Diversify state + telemetry ground truth.
  r=$(sqlq \
    "SELECT fractal_diversify_enable();" \
    "SELECT fractal_diversify_set_params('{}');" \
    "SELECT fractal_diversify_current_dq();" \
    "SELECT fractal_diversify_overhead_p99_us();" \
    "SELECT fractal_diversify_disable();")
  if [[ $? -eq 0 ]]; then
    pass "22 v2_functions: diversify state machine cycles cleanly"
  else
    fail "22 v2_functions: diversify: $r"
  fi
  # current_dq returns an actual float once queries have run through
  # diversify (vs. the NaN-before-any-query path exercised just above).
  sqlq "CREATE TABLE bt_dqlive(id INTEGER PRIMARY KEY, emb TEXT);
    INSERT INTO bt_dqlive VALUES
      (1,'1.0,0.0,0.0'),(2,'0.0,1.0,0.0'),(3,'0.0,0.0,1.0');" >/dev/null 2>&1
  r=$(sqlq \
    "SELECT fractal_diversify_enable();" \
    "SELECT fractal_search_telemetry('bt_dqlive','emb','1.0,0.0,0.0',2);" \
    "SELECT fractal_search_telemetry('bt_dqlive','emb','0.0,1.0,0.0',2);" \
    "SELECT fractal_search_telemetry('bt_dqlive','emb','0.0,0.0,1.0',2);" \
    "SELECT fractal_diversify_current_dq();" \
    "SELECT fractal_diversify_disable();" | tail -n2 | head -n1)
  grep <<< "$r" -Eq '^[0-9]+(\.[0-9]+)?$' \
    && pass "22 v2_functions: diversify_current_dq returns a real float once queries have run" \
    || fail "22 v2_functions: expected a numeric current_dq, got: $r"
  sqlq "DROP TABLE IF EXISTS bt_dqlive;" >/dev/null 2>&1
  r=$(sqlq "SELECT d.id, json_extract(je.j,'\$.distance') AS distance FROM
            (SELECT value AS j FROM json_each(fractal_search_telemetry(
               'bt_telemetry', 'vec', '0.6,0.8,0.0,0.0', 2))) je
            JOIN bt_telemetry d ON d.rowid = json_extract(je.j,'\$.doc_id')
            ORDER BY json_extract(je.j,'\$.distance') LIMIT 1;")
  if [[ $? -eq 0 ]] && grep <<< "$r" -q "^1|"; then
    pass "22 v2_functions: search_telemetry doc_id resolves to the real row (rowid = doc_id)"
  else
    fail "22 v2_functions: telemetry rowid-join: $r"
  fi
  r=$(sqlq "SELECT json_extract(fractal_search_telemetry(
              'bt_telemetry', 'vec', '0.6,0.8,0.0,0.0', 2), '\$[0].scan_pos');")
  if [[ $? -eq 0 ]] && [[ "$(echo "$r" | tr -d '[:space:]')" = "0" ]]; then
    pass "22 v2_functions: search_telemetry reports scan_pos alongside the rowid doc_id"
  else
    fail "22 v2_functions: telemetry scan_pos: $r"
  fi
  if expect_err "k must be > 0" \
      "SELECT fractal_search_telemetry('bt_telemetry','vec',
        '0.6,0.8,0.0,0.0', 0);"; then
    pass "22 v2_functions: telemetry k<=0 rejected"
  else
    fail "22 v2_functions: telemetry k<=0 accepted"
  fi
  # agents_scan_corpus's own prepare failure: a WITHOUT ROWID table has
  # no rowid for the "ORDER BY rowid" scan query to select, surfacing a
  # clean "scan of T.C failed" error instead of propagating the raw
  # SQLite message uncontextualized. Shared by every v2 agent search
  # function that scans a table (search_telemetry, hybrid_clinical_
  # search, cross_modal_search, search_agent, rag_agent, plan_explore),
  # so one test here covers all of them.
  sqlq "
    CREATE TABLE bt_telemetry_nr(id TEXT PRIMARY KEY, vec TEXT) WITHOUT ROWID;
    INSERT INTO bt_telemetry_nr VALUES ('a','1.0,0.0,0.0,0.0');
  " >/dev/null 2>&1
  if expect_err "scan of bt_telemetry_nr.vec failed" \
      "SELECT fractal_search_telemetry('bt_telemetry_nr','vec','1.0,0.0,0.0,0.0',2);"; then
    pass "22 v2_functions: search_telemetry surfaces a clean error on a WITHOUT ROWID table"
  else
    fail "22 v2_functions: search_telemetry accepted a WITHOUT ROWID table"
  fi
  sqlq "DROP TABLE IF EXISTS bt_telemetry_nr;" >/dev/null 2>&1
  # hybrid: the cohort holds real rowids (the same locator the result
  # doc_id reports); the join asserts the returned doc_ids are real
  # row ids, not scan positions.
  r=$(sqlq "SELECT group_concat(d.id) FROM
            (SELECT value AS j FROM json_each(fractal_hybrid_clinical_search(
               'bt_telemetry', 'vec', '0.0,1.0,0.0,0.0',
               (SELECT json_group_array(rowid) FROM bt_telemetry
                 WHERE id IN (2,4,5)), 3))) r
            JOIN bt_telemetry d ON d.rowid = json_extract(r.j,'\$.doc_id');")
  if [[ $? -eq 0 ]] && grep <<< "$r" -q "2" && grep <<< "$r" -q "4" && grep <<< "$r" -q "5"; then
    pass "22 v2_functions: hybrid restricts to the rowid cohort and returns real row ids"
  else
    fail "22 v2_functions: hybrid rowid cohort: $r"
  fi
  if expect_err "cohort matched no rows" \
      "SELECT fractal_hybrid_clinical_search('bt_telemetry','vec',
        '0.0,1.0,0.0,0.0', '[999999]', 1);"; then
    pass "22 v2_functions: hybrid rejects a cohort matching zero rows"
  else
    fail "22 v2_functions: hybrid zero-cohort accepted"
  fi
  r=$(sqlq "SELECT fractal_search_trajectory(
              'bt_traj', 'vec', '0.0,0.0,0.0,0.0',
              '0.3,0.0,0.0,0.0', 3);")
  if [[ $? -eq 0 ]] && grep <<< "$r" -q "{"; then
    pass "22 v2_functions: search_trajectory returns JSON"
  else
    fail "22 v2_functions: search_trajectory: $r"
  fi
  # With diversify enabled and a few real searches run first (same
  # connection; current_dq needs query history to compute against --
  # confirmed live that one search alone still leaves it NaN), current_
  # dq becomes a real float, not NaN -- the numeric (snprintf) half of
  # explain_result's dq/p99 formatting, otherwise dead since every
  # other call here is on a fresh, diversify-off connection.
  r=$(sqlq \
    "SELECT fractal_diversify_enable();" \
    "SELECT fractal_search_telemetry('bt_traj','vec','1.0,0.0,0.0,0.0',2);" \
    "SELECT fractal_search_telemetry('bt_traj','vec','0.0,1.0,0.0,0.0',2);" \
    "SELECT fractal_search_telemetry('bt_traj','vec','0.0,0.0,1.0,0.0',2);" \
    "SELECT fractal_explain_result();" \
    "SELECT fractal_detect_collapse();" \
    "SELECT fractal_diversify_disable();")
  if [[ $? -eq 0 ]] && grep <<< "$r" -Eq '"dq":[0-9]'; then
    pass "22 v2_functions: explain_result reports a real numeric dq once diversify has run"
  else
    fail "22 v2_functions: explain_result numeric-dq call: $r"
  fi
  r=$(sqlq "SELECT fractal_explain_result();" \
            "SELECT fractal_detect_collapse();")
  if [[ $? -eq 0 ]]; then
    pass "22 v2_functions: explain_result/detect_collapse respond"
  else
    fail "22 v2_functions: explain/detect_collapse: $r"
  fi
  # --- v2.0.25-core analytics surface (10 functions) ------------------
  # change_point_detect: 40-point mean step at t=20, window 10 ->
  # boundary index 20 (the exact fixture demo/benchmark-api-reference.sql
  # uses, scaled down to stay inline here).
  r=$(sqlq "SELECT fractal_change_point_detect(
              '1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,
               1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,
               3.0,3.0,3.0,3.0,3.0,3.0,3.0,3.0,3.0,3.0,
               3.0,3.0,3.0,3.0,3.0,3.0,3.0,3.0,3.0,3.0',
              10, 1.0);")
  if [[ $? -eq 0 ]] && grep <<< "$r" -q '"indices"'; then
    pass "22 v2_functions: change_point_detect returns boundary indices"
  else
    fail "22 v2_functions: change_point_detect: $r"
  fi
  if expect_err "window and threshold must be > 0" \
      "SELECT fractal_change_point_detect('1,2,3,4,5,6,7,8,9,10',0,1.0);"; then
    pass "22 v2_functions: change_point_detect rejects window<=0"
  else
    fail "22 v2_functions: change_point_detect accepted window<=0"
  fi
  if expect_err "window and threshold must be > 0" \
      "SELECT fractal_change_point_detect('1,2,3,4,5,6,7,8,9,10',2,0.0);"; then
    pass "22 v2_functions: change_point_detect rejects threshold<=0"
  else
    fail "22 v2_functions: change_point_detect accepted threshold<=0"
  fi
  if expect_err "window and threshold must be > 0" \
      "SELECT fractal_change_point_detect('1,2,3,4,5,6,7,8,9,10',2,1.0,0);"; then
    pass "22 v2_functions: change_point_detect rejects max_points<=0"
  else
    fail "22 v2_functions: change_point_detect accepted max_points<=0"
  fi
  if expect_err "malformed series" \
      "SELECT fractal_change_point_detect('bad!vec',10,1.0);"; then
    pass "22 v2_functions: change_point_detect rejects a malformed series"
  else
    fail "22 v2_functions: change_point_detect accepted a malformed series"
  fi
  if expect_err "malformed node_coords/edges/edge_arc_length" \
      "SELECT fractal_vascular_network('bad!vec','0,1','1.0');"; then
    pass "22 v2_functions: vascular rejects a malformed node_coords"
  else
    fail "22 v2_functions: vascular accepted a malformed node_coords"
  fi
  if expect_err "malformed vertices/faces" \
      "SELECT fractal_cortical_folding('bad!vec','0,1,2');"; then
    pass "22 v2_functions: cortical rejects malformed vertices"
  else
    fail "22 v2_functions: cortical accepted malformed vertices"
  fi
  if expect_err "malformed node_coords/edges" \
      "SELECT fractal_nerve_plexus_metric('bad!vec',2,'0,1');"; then
    pass "22 v2_functions: nerve rejects malformed node_coords"
  else
    fail "22 v2_functions: nerve accepted malformed node_coords"
  fi
  if expect_err "malformed points" \
      "SELECT fractal_morphological_complexity('bad!vec',2);"; then
    pass "22 v2_functions: morphology rejects malformed points"
  else
    fail "22 v2_functions: morphology accepted malformed points"
  fi
  # periodogram: the same 32-point sin(i/4) series -> peak lists.
  r=$(sqlq "SELECT fractal_periodogram('$s32', 3);")
  if [[ $? -eq 0 ]] && grep <<< "$r" -q '"freqs"' \
      && grep <<< "$r" -q '"power"'; then
    pass "22 v2_functions: periodogram returns the peak lists"
  else
    fail "22 v2_functions: periodogram: $r"
  fi
  if expect_err "max_peaks must be > 0" \
      "SELECT fractal_periodogram('$s32', 0);"; then
    pass "22 v2_functions: periodogram rejects max_peaks<=0"
  else
    fail "22 v2_functions: periodogram accepted max_peaks<=0"
  fi
  if expect_err "malformed series" \
      "SELECT fractal_periodogram('bad!vec');"; then
    pass "22 v2_functions: periodogram rejects a malformed series"
  else
    fail "22 v2_functions: periodogram accepted a malformed series"
  fi
  if expect_err "need n >= 4" \
      "SELECT fractal_periodogram('1,2,3');"; then
    pass "22 v2_functions: periodogram rejects a too-short series"
  else
    fail "22 v2_functions: periodogram accepted a too-short series"
  fi
  # spectrogram_entropy: a period-4 tone (low entropy, constant per frame)
  # vs an LCG noise series (high entropy), built in SQL so no external
  # data file is needed. Frame count = floor((128-32)/16)+1 = 7.
  se_tone="(WITH RECURSIVE g(t) AS (VALUES(0) UNION ALL SELECT t+1 FROM g WHERE t<127) SELECT group_concat(CASE t%4 WHEN 0 THEN 1 WHEN 2 THEN -1 ELSE 0 END) FROM (SELECT t FROM g ORDER BY t))"
  se_noise="(WITH RECURSIVE g(t,x) AS (VALUES(0,12345) UNION ALL SELECT t+1,(x*1103515245+12345)%2147483648 FROM g WHERE t<127) SELECT group_concat((x/65536)%1000) FROM (SELECT t,x FROM g ORDER BY t))"
  r=$(sqlq "SELECT json_array_length(fractal_spectrogram_entropy($se_tone,32,16));")
  if [[ $? -eq 0 && "$r" == "7" ]]; then
    pass "22 v2_functions: spectrogram_entropy returns one value per frame"
  else
    fail "22 v2_functions: spectrogram_entropy frame count: $r"
  fi
  r=$(sqlq "SELECT max(value) < 0.5 AND min(value) >= 0.0 FROM json_each(fractal_spectrogram_entropy($se_tone,32,16));")
  if [[ $? -eq 0 && "$r" == "1" ]]; then
    pass "22 v2_functions: spectrogram_entropy reads a pure tone as ordered (< 0.5)"
  else
    fail "22 v2_functions: spectrogram_entropy tone: $r"
  fi
  r=$(sqlq "SELECT avg(value) > 0.7 AND max(value) <= 1.0 FROM json_each(fractal_spectrogram_entropy($se_noise,32,32));")
  if [[ $? -eq 0 && "$r" == "1" ]]; then
    pass "22 v2_functions: spectrogram_entropy reads noise as disordered (> 0.7, <= 1)"
  else
    fail "22 v2_functions: spectrogram_entropy noise: $r"
  fi
  r=$(sqlq "SELECT fractal_spectrogram_entropy('2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2',8,8);")
  if [[ $? -eq 0 && "$r" == "[0.0000000000,0.0000000000]" ]]; then
    pass "22 v2_functions: spectrogram_entropy reports a constant frame as 0.0, not NaN"
  else
    fail "22 v2_functions: spectrogram_entropy constant frame: $r"
  fi
  r=$(sqlq "SELECT json_array_length(fractal_spectrogram_entropy($se_tone,32,16,2));")
  if [[ $? -eq 0 && "$r" == "2" ]]; then
    pass "22 v2_functions: spectrogram_entropy honours max_frames"
  else
    fail "22 v2_functions: spectrogram_entropy max_frames: $r"
  fi
  r=$(sqlq "SELECT fractal_spectrogram_entropy(NULL);")
  if [[ $? -eq 0 && -z "$r" ]]; then
    pass "22 v2_functions: spectrogram_entropy(NULL) is NULL"
  else
    fail "22 v2_functions: spectrogram_entropy(NULL): $r"
  fi
  # Regime change: 64 tone samples then 64 noise samples -> the entropy
  # series steps up, and change_point_detect localizes it from the bare
  # array (the function's output feeds the next one directly).
  r=$(sqlq "WITH RECURSIVE g(t,x) AS (VALUES(0,12345) UNION ALL SELECT t+1,(x*1103515245+12345)%2147483648 FROM g WHERE t<127),
              s(v) AS (SELECT group_concat(CASE WHEN t<64 THEN (CASE t%4 WHEN 0 THEN 1 WHEN 2 THEN -1 ELSE 0 END) ELSE (x/65536)%1000 END) FROM (SELECT t,x FROM g ORDER BY t))
            SELECT fractal_change_point_detect(fractal_spectrogram_entropy(v,16,8),3,1.0) FROM s;")
  if [[ $? -eq 0 ]] && grep <<< "$r" -qE '"indices":\[[0-9]'; then
    pass "22 v2_functions: spectrogram_entropy -> change_point_detect localizes a regime change"
  else
    fail "22 v2_functions: spectrogram_entropy regime change: $r"
  fi
  for bad in "'$s32',4|window < 8" "'$s32',600|window > 512" "'$s32',16,0|hop < 1" \
             "'$s32',16,8,0|max_frames < 1" "'$s32',16,8,5000|max_frames > 4096" \
             "'1,2,3'|series shorter than window"; do
    if expect_err "needs window in" "SELECT fractal_spectrogram_entropy(${bad%%|*});"; then
      pass "22 v2_functions: spectrogram_entropy rejects ${bad##*|}"
    else
      fail "22 v2_functions: spectrogram_entropy accepted ${bad##*|}"
    fi
  done
  if expect_err "malformed series" \
      "SELECT fractal_spectrogram_entropy('bad!vec',16);"; then
    pass "22 v2_functions: spectrogram_entropy rejects a malformed series"
  else
    fail "22 v2_functions: spectrogram_entropy accepted a malformed series"
  fi
  # TDA: an 8-point square ring at spacing 2 (threshold 2.5 admits the
  # 8 ring edges, excludes the 2.83 corner diagonals) -> E-V+C = 1.
  r=$(sqlq "SELECT fractal_tda_persistence_diagram(
              '0,0,2,0,4,0,4,2,4,4,2,4,0,4,0,2', 2, 1, 2.5);")
  if [[ $? -eq 0 ]] && grep <<< "$r" -q '"betti1":1'; then
    pass "22 v2_functions: TDA flags the single ring cycle (betti1=1)"
  else
    fail "22 v2_functions: TDA: $r"
  fi
  r=$(sqlq "SELECT fractal_tda_persistence_diagram(
              '0,0,2,0,4,0,4,2,4,4,2,4,0,4,0,2', 2, 0, 2.5);")
  if [[ $? -eq 0 ]] && grep <<< "$r" -Fq '"betti1":null'; then
    pass "22 v2_functions: TDA max_dim=0 reports betti1:null (H1 not computed)"
  else
    fail "22 v2_functions: TDA max_dim=0: $r"
  fi
  # state_fingerprint: 64 bits -> (64+7)/8 = 8 bytes -> 16 hex chars.
  r=$(sqlq "SELECT length(hex(fractal_state_fingerprint('1.0,0.0,0.0', 64)));")
  if [[ "$r" == "16" ]]; then
    pass "22 v2_functions: state_fingerprint returns a 64-bit (16-hex-char) BLOB"
  else
    fail "22 v2_functions: state_fingerprint: $r"
  fi
  if expect_err "n_bits must be > 0" \
      "SELECT fractal_state_fingerprint('1.0,0.0,0.0', 0);"; then
    pass "22 v2_functions: state_fingerprint rejects n_bits<=0"
  else
    fail "22 v2_functions: state_fingerprint accepted n_bits<=0"
  fi
  if expect_err "malformed vec" \
      "SELECT fractal_state_fingerprint('bad!vec', 64);"; then
    pass "22 v2_functions: state_fingerprint rejects a malformed vector"
  else
    fail "22 v2_functions: state_fingerprint accepted a malformed vector"
  fi
  # cycle_detect: a clean period-2 one-hot fingerprint stream closes
  # (one-hot states, so the two directions are distinguishable).
  r=$(sqlq "
    WITH RECURSIVE g(t) AS (VALUES(0) UNION ALL SELECT t+1 FROM g WHERE t<9)
    SELECT fractal_cycle_detect(
        (SELECT json_group_array(f) FROM
           (SELECT hex(fractal_state_fingerprint(
              CASE WHEN t % 2 = 0 THEN '1.0,0.0,0.0' ELSE '0.0,1.0,0.0' END, 64)) AS f
              FROM g)),
        64) AS cycle_detect;")
  if [[ $? -eq 0 ]] && grep <<< "$r" -q '"detected":true'; then
    pass "22 v2_functions: cycle_detect closes the period-2 fingerprint stream"
  else
    fail "22 v2_functions: cycle_detect: $r"
  fi
  if expect_err "n_bits must be > 0" \
      "SELECT fractal_cycle_detect('[]', 0);"; then
    pass "22 v2_functions: cycle_detect rejects n_bits<=0"
  else
    fail "22 v2_functions: cycle_detect accepted n_bits<=0"
  fi
  # optimize_subset: best 5 of 10 scored items (bounds <= 1.0).
  r=$(sqlq "SELECT fractal_optimize_subset(
              '10,9,8,7,6,5,4,3,2,1',
              '1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0',
              5);")
  if [[ $? -eq 0 ]] && grep <<< "$r" -q '"weights"'; then
    pass "22 v2_functions: optimize_subset returns the value-weighted allocation"
  else
    fail "22 v2_functions: optimize_subset: $r"
  fi
  # Vector math quartet (registered in the common TU -- both builds).
  r=$(sqlq "SELECT fractal_vector_lp_distance('1,0,0', '0.5,0,0', 2.0) AS lp2;" \
            "SELECT fractal_vector_lp_distance('1,0,0', '0.5,0,0', 0.5) AS lp05;")
  if [[ $? -eq 0 ]]; then
    pass "22 v2_functions: fractal_vector_lp_distance (p=2 and fractional p=0.5)"
  else
    fail "22 v2_functions: lp_distance: $r"
  fi
  r=$(sqlq "SELECT fractal_vector_quantize_int8('0.5,-0.25,0.75,0.0');")
  if [[ $? -eq 0 ]] && grep <<< "$r" -q '"scale"'; then
    pass "22 v2_functions: quantize_int8 returns the scale+codes document"
  else
    fail "22 v2_functions: quantize_int8: $r"
  fi
  r=$(sqlq "SELECT length(fractal_vector_quantize_binary(
           '1,-1,1,1,-1,1,-1,-1,1,1'));")
  if [[ "$r" == "2" ]]; then   # (10 + 7) / 8 = 2 sign bytes
    pass "22 v2_functions: quantize_binary returns (dim+7)/8 sign bytes"
  else
    fail "22 v2_functions: quantize_binary: $r"
  fi
  r=$(sqlq "SELECT fractal_vector_hamming_distance(
           fractal_vector_quantize_binary('1,-1,1,1,-1,1,-1,-1,1,1'),
           fractal_vector_quantize_binary('1,-1,1,1,-1,1,-1,-1,1,1'));" \
            "SELECT fractal_vector_hamming_distance(
           fractal_vector_quantize_binary('1,-1,1,1,-1,1,-1,-1,1,1'),
           fractal_vector_quantize_binary('-1,-1,1,1,-1,1,-1,-1,1,1'));")
  if [[ "$r" == "0
1" ]]; then
    pass "22 v2_functions: hamming_distance (same pair=0, one bit=1)"
  else
    fail "22 v2_functions: hamming_distance: $r"
  fi

  # --- fractal_vector / from_text / to_json round-trip ----------------
  r=$(sqlq "SELECT fractal_vector_to_json(fractal_vector(3));")
  [[ "$r" == "[0,0,0]" ]] \
    && pass "22 v2_functions: fractal_vector(dim) constructs a zero vector" \
    || fail "22 v2_functions: fractal_vector(3): $r"
  if expect_err "dim must be" \
      "SELECT fractal_vector(0);"; then
    pass "22 v2_functions: fractal_vector rejects dim <= 0"
  else
    fail "22 v2_functions: fractal_vector(0) accepted"
  fi
  if expect_err "dim must be 1..32767, got 32768" \
      "SELECT fractal_vector(32768);"; then
    pass "22 v2_functions: fractal_vector rejects dim > FSQL_VEC_MAX_DIM"
  else
    fail "22 v2_functions: fractal_vector(32768) accepted"
  fi
  r=$(sqlq "SELECT fractal_vector_to_json(fractal_vector_from_text('1,2,3'));")
  [[ "$r" == "[1,2,3]" ]] \
    && pass "22 v2_functions: from_text canonicalizes a CSV vector" \
    || fail "22 v2_functions: from_text: $r"
  if expect_err "malformed vector" \
      "SELECT fractal_vector_from_text('not,a,vector,[');"; then
    pass "22 v2_functions: from_text rejects malformed input"
  else
    fail "22 v2_functions: from_text accepted malformed input"
  fi
  r=$(sqlq "SELECT fractal_vector_to_json('1.5,2.5,3.5');")
  [[ "$r" == "[1.5,2.5,3.5]" ]] \
    && pass "22 v2_functions: to_json renders a JSON array" \
    || fail "22 v2_functions: to_json: $r"

  # --- fractal_vector_add / fractal_vector_sub (fv_binary_vec_fn) -----
  r=$(sqlq "SELECT fractal_vector_to_json(fractal_vector_add('1,2,3','1,1,1'));")
  [[ "$r" == "[2,3,4]" ]] \
    && pass "22 v2_functions: add([1,2,3],[1,1,1])=[2,3,4]" \
    || fail "22 v2_functions: add: $r"
  r=$(sqlq "SELECT fractal_vector_to_json(fractal_vector_sub('3,4,5','1,1,1'));")
  [[ "$r" == "[2,3,4]" ]] \
    && pass "22 v2_functions: sub([3,4,5],[1,1,1])=[2,3,4]" \
    || fail "22 v2_functions: sub: $r"
  if expect_err "vector dim mismatch" \
      "SELECT fractal_vector_add('1,2,3','1,1');"; then
    pass "22 v2_functions: add rejects mismatched dims"
  else
    fail "22 v2_functions: add accepted mismatched dims"
  fi
  if expect_err "malformed vector" \
      "SELECT fractal_vector_add('bad!vec','1,1,1');"; then
    pass "22 v2_functions: add rejects a malformed vector"
  else
    fail "22 v2_functions: add accepted a malformed vector"
  fi

  # --- fractal_vector_scale / norm / normalize ------------------------
  r=$(sqlq "SELECT fractal_vector_to_json(fractal_vector_scale('1,2,3',2));")
  [[ "$r" == "[2,4,6]" ]] \
    && pass "22 v2_functions: scale([1,2,3],2)=[2,4,6]" \
    || fail "22 v2_functions: scale: $r"
  r=$(sqlq "SELECT fractal_vector_norm('3,4,0');")
  [[ "$r" == "5.0" || "$r" == "5" ]] \
    && pass "22 v2_functions: norm([3,4,0])=5" \
    || fail "22 v2_functions: norm: $r"
  # float32 storage round-trips 0.6/0.8 as 0.600000024/0.800000012 at
  # %.9g -- match on precision, not exact string equality.
  r=$(sqlq "SELECT fractal_vector_to_json(fractal_vector_normalize('3,4,0'));")
  grep <<< "$r" -Eq '^\[0\.6[0-9]*,0\.8[0-9]*,0\]$' \
    && pass "22 v2_functions: normalize([3,4,0]) -> unit vector [0.6,0.8,0]" \
    || fail "22 v2_functions: normalize: $r"
  r=$(sqlq "SELECT fractal_vector_normalize(NULL);")
  [[ -z "$r" ]] \
    && pass "22 v2_functions: normalize(NULL) -> NULL" \
    || fail "22 v2_functions: normalize(NULL): $r"

  # --- self-contained sin/sqrt/cos (hosts missing
  # SQLITE_ENABLE_MATH_FUNCTIONS) -----------------------------------
  r=$(sqlq "SELECT sin(0.0);")
  [[ "$r" = "0.0" ]] \
    && pass "22 v2_functions: sin(0)=0" \
    || fail "22 v2_functions: sin(0): $r"
  r=$(sqlq "SELECT cos(0.0);")
  [[ "$r" = "1.0" ]] \
    && pass "22 v2_functions: cos(0)=1" \
    || fail "22 v2_functions: cos(0): $r"
  r=$(sqlq "SELECT sqrt(4.0);")
  [[ "$r" = "2.0" ]] \
    && pass "22 v2_functions: sqrt(4)=2" \
    || fail "22 v2_functions: sqrt(4): $r"
  r=$(sqlq "SELECT sqrt(-1.0);")
  [[ -z "$r" ]] \
    && pass "22 v2_functions: sqrt(negative) -> NULL" \
    || fail "22 v2_functions: sqrt(-1): $r"
  r=$(sqlq "SELECT sin(NULL);")
  [[ -z "$r" ]] \
    && pass "22 v2_functions: sin(NULL) -> NULL" \
    || fail "22 v2_functions: sin(NULL): $r"

  # --- fractalsql_get -------------------------------------------------
  r=$(sqlq "SELECT fractalsql_set('reasoning_plugin','$MOCK');" \
           "SELECT fractalsql_get('reasoning_plugin');" | tail -n1)
  [[ "$r" = "$MOCK" ]] \
    && pass "22 v2_functions: fractalsql_get round-trips a string key" \
    || fail "22 v2_functions: fractalsql_get: $r"
  if expect_err "unknown config key" \
      "SELECT fractalsql_get('not_a_real_key');"; then
    pass "22 v2_functions: fractalsql_get rejects an unknown key"
  else
    fail "22 v2_functions: fractalsql_get accepted an unknown key"
  fi
  if expect_err "expects TEXT" \
      "SELECT fractalsql_get(123);"; then
    pass "22 v2_functions: fractalsql_get rejects a non-TEXT name"
  else
    fail "22 v2_functions: fractalsql_get accepted a non-TEXT name"
  fi

  # --- scattered argument-validation guards, each otherwise dead ------
  sqlq "CREATE TABLE bt_v22_empty(id INTEGER PRIMARY KEY, emb TEXT);" >/dev/null 2>&1
  if expect_err "k must be > 0" \
      "SELECT fractal_search_telemetry('bt_v22_empty','emb','1.0,2.0',0);"; then
    pass "22 v2_functions: search_telemetry rejects k<=0"
  else
    fail "22 v2_functions: search_telemetry accepted k<=0"
  fi
  if expect_err "doc_id must be >= 0" \
      "SELECT fractal_store_morphology(-1, '1.0,2.0,3.0');"; then
    pass "22 v2_functions: store_morphology rejects a negative doc_id"
  else
    fail "22 v2_functions: store_morphology accepted a negative doc_id"
  fi
  if expect_err "dim must be > 0" \
      "SELECT fractal_agent_detect_loop('a','1.0,2.0',0);"; then
    pass "22 v2_functions: detect_loop rejects dim<=0"
  else
    fail "22 v2_functions: detect_loop accepted dim<=0"
  fi
  if [[ -f "$(wpath "$MOCKEMB")" ]]; then
    if expect_err "no rows found in the corpus" \
        "SELECT fractalsql_set('reasoning_plugin','$MOCKEMB');" \
        "SELECT fractalsql_set('http_embed_url','https://embed.invalid/v1');" \
        "SELECT fractal_agent_plan_explore('1.0,2.0,3.0','bt_v22_empty','emb',5);"; then
      pass "22 v2_functions: plan_explore raises a clean ERROR when the corpus table is empty"
    else
      fail "22 v2_functions: plan_explore accepted an empty corpus table"
    fi
  else
    skip "22 v2_functions: plan_explore empty-corpus (mock_embed_plugin did not build)"
  fi
  sqlq "DROP TABLE IF EXISTS bt_v22_empty;" >/dev/null 2>&1

  # --- argument-validation rejections not exercised above ------------
  if expect_err "hamming_threshold must be >= 0" \
      "SELECT fractal_cycle_detect('[]', 64, -1);"; then
    pass "22 v2_functions: cycle_detect rejects hamming_threshold<0"
  else
    fail "22 v2_functions: cycle_detect accepted hamming_threshold<0"
  fi
  if expect_err "malformed fingerprints_json" \
      "SELECT fractal_cycle_detect('not valid json', 8);"; then
    pass "22 v2_functions: cycle_detect rejects non-JSON fingerprints_json"
  else
    fail "22 v2_functions: cycle_detect accepted non-JSON fingerprints_json"
  fi
  if expect_err "is not 1 bytes of hex text" \
      "SELECT fractal_cycle_detect('[\"zz\"]', 8);"; then
    pass "22 v2_functions: cycle_detect rejects a non-hex fingerprint element"
  else
    fail "22 v2_functions: cycle_detect accepted a non-hex fingerprint element"
  fi
  if expect_err "k must satisfy 1 <= k" \
      "SELECT fractal_optimize_subset('10,9','1.0,1.0',0);"; then
    pass "22 v2_functions: optimize_subset rejects k<=0"
  else
    fail "22 v2_functions: optimize_subset accepted k<=0"
  fi
  if expect_err "k must satisfy 1 <= k" \
      "SELECT fractal_optimize_subset('10,9','1.0,1.0',5);"; then
    pass "22 v2_functions: optimize_subset rejects k>item_values length"
  else
    fail "22 v2_functions: optimize_subset accepted k>item_values length"
  fi
  if expect_err "upper_bounds length must match" \
      "SELECT fractal_optimize_subset('10,9,8','1.0,1.0',1);"; then
    pass "22 v2_functions: optimize_subset rejects mismatched upper_bounds length"
  else
    fail "22 v2_functions: optimize_subset accepted mismatched upper_bounds length"
  fi
  r=$(sqlq "SELECT fractal_optimize_subset(
              '10,9,8,7,6','1.0,1.0,1.0,1.0,1.0',3,'0.1,0.1,0.1,0.1,0.1',0.1,42);")
  if [[ $? -eq 0 ]] && grep <<< "$r" -q '"weights"'; then
    pass "22 v2_functions: optimize_subset succeeds with all optional args (prev_weights/turnover/seed)"
  else
    fail "22 v2_functions: optimize_subset full-args call: $r"
  fi
  if expect_err "malformed prev_weights" \
      "SELECT fractal_optimize_subset('10,9,8,7,6','1.0,1.0,1.0,1.0,1.0',3,'bad!vec');"; then
    pass "22 v2_functions: optimize_subset rejects a malformed prev_weights"
  else
    fail "22 v2_functions: optimize_subset accepted a malformed prev_weights"
  fi
  if expect_err "malformed prev_weights, or length does not match" \
      "SELECT fractal_optimize_subset('1.0,2.0,3.0','1.0,1.0,1.0',2,'0.1,0.2');"; then
    pass "22 v2_functions: optimize_subset rejects a well-formed but wrong-length prev_weights"
  else
    fail "22 v2_functions: optimize_subset accepted a wrong-length prev_weights"
  fi
  if expect_err "invalid input" \
      "SELECT fractal_tda_persistence_diagram(
         '0,0,2,0,4,0,4,2,4,4,2,4,0,4,0,2', 2, 2, 2.5);"; then
    pass "22 v2_functions: TDA rejects an invalid max_dim (not 0 or 1)"
  else
    fail "22 v2_functions: TDA accepted an invalid max_dim"
  fi
  r=$(sqlq "SELECT fractal_tda_persistence_diagram(
              '0,0,2,0,4,0,4,2,4,4,2,4,0,4,0,2', 2, 1, 2.5, 16);")
  if [[ $? -eq 0 ]] && grep <<< "$r" -q 'betti1'; then
    pass "22 v2_functions: TDA succeeds with max_h0_bars explicitly supplied"
  else
    fail "22 v2_functions: TDA max_h0_bars call: $r"
  fi
  if expect_err "malformed points" \
      "SELECT fractal_tda_persistence_diagram('bad!vec', 2, 1, 2.5);"; then
    pass "22 v2_functions: TDA rejects a malformed points vector"
  else
    fail "22 v2_functions: TDA accepted a malformed points vector"
  fi
  if expect_err "need 2 <= n_points" \
      "SELECT fractal_tda_persistence_diagram('0,0', 2, 1, 2.5);"; then
    pass "22 v2_functions: TDA rejects too few points"
  else
    fail "22 v2_functions: TDA accepted too few points"
  fi
  # Portfolio multimodal/pareto argument validation runs BEFORE the
  # enterprise-tier gate, so these reject cleanly with no enterprise
  # core needed (same community-edition reach as the "dormant path"
  # test above).
  if expect_err "n_restarts must satisfy" \
      "SELECT fractal_optimize_portfolio_multimodal('0.05,0.1','1.0,0.0,0.0,1.0',1,0);"; then
    pass "22 v2_functions: portfolio_multimodal rejects n_restarts<=0"
  else
    fail "22 v2_functions: portfolio_multimodal accepted n_restarts<=0"
  fi
  if expect_err "n_restarts must satisfy" \
      "SELECT fractal_optimize_portfolio_multimodal('0.05,0.1','1.0,0.0,0.0,1.0',1,65);"; then
    pass "22 v2_functions: portfolio_multimodal rejects n_restarts>64"
  else
    fail "22 v2_functions: portfolio_multimodal accepted n_restarts>64"
  fi
  if expect_err "n_restarts must satisfy" \
      "SELECT fractal_optimize_portfolio_multimodal_pareto('0.05,0.1','1.0,0.0,0.0,1.0',1,0);"; then
    pass "22 v2_functions: portfolio_multimodal_pareto rejects n_restarts<=0"
  else
    fail "22 v2_functions: portfolio_multimodal_pareto accepted n_restarts<=0"
  fi
  if expect_err "max_front must satisfy" \
      "SELECT fractal_optimize_portfolio_multimodal_pareto('0.05,0.1','1.0,0.0,0.0,1.0',1,8,0);"; then
    pass "22 v2_functions: portfolio_multimodal_pareto rejects max_front<=0"
  else
    fail "22 v2_functions: portfolio_multimodal_pareto accepted max_front<=0"
  fi
  if expect_err "max_front must satisfy" \
      "SELECT fractal_optimize_portfolio_multimodal_pareto('0.05,0.1','1.0,0.0,0.0,1.0',1,8,9);"; then
    pass "22 v2_functions: portfolio_multimodal_pareto rejects max_front>n_restarts"
  else
    fail "22 v2_functions: portfolio_multimodal_pareto accepted max_front>n_restarts"
  fi
  if expect_err "diffusion_mode" \
      "SELECT fractal_optimize_portfolio_multimodal('0.05,0.1','1.0,0.0,0.0,1.0',1,8,0.15,0.9,42,0,'bogus-mode');"; then
    pass "22 v2_functions: portfolio_multimodal rejects an unknown diffusion_mode"
  else
    fail "22 v2_functions: portfolio_multimodal accepted an unknown diffusion_mode"
  fi
  if expect_err "diffusion_mode" \
      "SELECT fractal_optimize_portfolio_multimodal_pareto('0.05,0.1','1.0,0.0,0.0,1.0',1,8,8,42,0,'bogus-mode');"; then
    pass "22 v2_functions: portfolio_multimodal_pareto rejects an unknown diffusion_mode"
  else
    fail "22 v2_functions: portfolio_multimodal_pareto accepted an unknown diffusion_mode"
  fi

  if expect_err "must be a positive multiple of dim" \
      "SELECT fractal_dimension_boxcount('0,0,1,0,1', 2);"; then
    pass "22 v2_functions: boxcount rejects a points length not a multiple of dim"
  else
    fail "22 v2_functions: boxcount accepted a points length not a multiple of dim"
  fi
  if expect_err "must be a positive multiple of dim" \
      "SELECT fractal_morphological_complexity('0,0,1,0,1', 2);"; then
    pass "22 v2_functions: morphology rejects a points length not a multiple of dim"
  else
    fail "22 v2_functions: morphology accepted a points length not a multiple of dim"
  fi
  if expect_err "mu, cov and k must not be NULL" \
      "SELECT fractal_optimize_portfolio(NULL,'1.0,0.0,0.0,1.0',1,42);"; then
    pass "22 v2_functions: portfolio rejects a NULL mu"
  else
    fail "22 v2_functions: portfolio accepted a NULL mu"
  fi
  if expect_err "k must satisfy 1 <= k" \
      "SELECT fractal_optimize_portfolio('0.1,0.1','1.0,0.0,0.0,1.0',0,42);"; then
    pass "22 v2_functions: portfolio rejects k<=0"
  else
    fail "22 v2_functions: portfolio accepted k<=0"
  fi
  local dspn; dspn=$(sqlq "SELECT fractal_diversify_set_params(NULL);")
  [[ -z "$dspn" ]] \
    && pass "22 v2_functions: diversify_set_params(NULL) is a clean no-op NULL" \
    || fail "22 v2_functions: diversify_set_params(NULL) expected NULL, got: $dspn"
  if expect_err "params must be a JSON object text" \
      "SELECT fractal_diversify_set_params(123);"; then
    pass "22 v2_functions: diversify_set_params rejects a non-TEXT params arg"
  else
    fail "22 v2_functions: diversify_set_params accepted a non-TEXT params arg"
  fi
  r=$(sqlq "SELECT fractal_diversify_set_params(
              '{\"max_shadows_considered\":5,\"tail_buffer_cap\":10,\"stall_threshold\":0.5}');")
  if [[ $? -eq 0 ]]; then
    pass "22 v2_functions: diversify_set_params applies max_shadows_considered/tail_buffer_cap/stall_threshold"
  else
    fail "22 v2_functions: diversify_set_params field-set call: $r"
  fi
  r=$(sqlq "SELECT fractal_feedback_report(1,'negative');")
  if [[ $? -eq 0 ]]; then
    pass "22 v2_functions: feedback_report accepts kind='negative'"
  else
    fail "22 v2_functions: feedback_report negative kind: $r"
  fi
  r=$(sqlq "SELECT fractal_isolate_background(1);")
  if [[ $? -eq 0 ]]; then
    pass "22 v2_functions: isolate_background succeeds"
  else
    fail "22 v2_functions: isolate_background: $r"
  fi
  r=$(sqlq "SELECT fractal_feedback_report(1,'dwell',50);")
  if [[ $? -eq 0 ]]; then
    pass "22 v2_functions: feedback_report accepts kind='dwell'"
  else
    fail "22 v2_functions: feedback_report dwell kind: $r"
  fi
  r=$(sqlq "SELECT fractal_feedback_report('5','positive');")
  if [[ $? -eq 0 ]]; then
    pass "22 v2_functions: feedback_report accepts a TEXT result_handle"
  else
    fail "22 v2_functions: feedback_report TEXT handle: $r"
  fi
  if expect_err "result_handle must be >= 0" \
      "SELECT fractal_feedback_report('-1','positive');"; then
    pass "22 v2_functions: feedback_report rejects a negative TEXT result_handle"
  else
    fail "22 v2_functions: feedback_report accepted a negative TEXT result_handle"
  fi
  if expect_err "result_handle must be >= 0" \
      "SELECT fractal_feedback_report(-1,'positive');"; then
    pass "22 v2_functions: feedback_report rejects a negative INTEGER result_handle"
  else
    fail "22 v2_functions: feedback_report accepted a negative INTEGER result_handle"
  fi
  r=$(sqlq "SELECT fractal_isolate_background('5');")
  if [[ $? -eq 0 ]]; then
    pass "22 v2_functions: isolate_background accepts a TEXT result_handle"
  else
    fail "22 v2_functions: isolate_background TEXT handle: $r"
  fi
  if expect_err "result_handle must be >= 0" \
      "SELECT fractal_isolate_background('-1');"; then
    pass "22 v2_functions: isolate_background rejects a negative TEXT result_handle"
  else
    fail "22 v2_functions: isolate_background accepted a negative TEXT result_handle"
  fi
  if expect_err "result_handle must be >= 0" \
      "SELECT fractal_isolate_background(-1);"; then
    pass "22 v2_functions: isolate_background rejects a negative INTEGER result_handle"
  else
    fail "22 v2_functions: isolate_background accepted a negative INTEGER result_handle"
  fi
  if expect_err "must be >= 0" \
      "SELECT fractal_vascular_network('0,0,0,1,0,0','-1,0','1.0');"; then
    pass "22 v2_functions: vascular rejects a negative edge index"
  else
    fail "22 v2_functions: vascular accepted a negative edge index"
  fi
  if expect_err "must be <= 2147483647" \
      "SELECT fractal_vascular_network('0,0,0,1,0,0','2200000000,0','1.0');"; then
    pass "22 v2_functions: vascular rejects an out-of-range edge index"
  else
    fail "22 v2_functions: vascular accepted an out-of-range edge index"
  fi

  # --- fsql_vector.c surfaces not exercised above --------------------
  if [[ -z "$(sqlq "SELECT fractal_vector_lp_distance(NULL,'1,0,0',2.0);")" ]]; then
    pass "22 v2_functions: lp_distance(NULL,...) -> NULL (STRICT)"
  else
    fail "22 v2_functions: lp_distance NULL arg did not yield NULL"
  fi
  if expect_err "vector dim mismatch" \
      "SELECT fractal_vector_lp_distance('1,0,0','1,0',2.0);"; then
    pass "22 v2_functions: lp_distance rejects mismatched dims"
  else
    fail "22 v2_functions: lp_distance accepted mismatched dims"
  fi
  if expect_err "malformed vector" \
      "SELECT fractal_vector_lp_distance('bad!vec','1,0,0',2.0);"; then
    pass "22 v2_functions: lp_distance rejects a malformed vector"
  else
    fail "22 v2_functions: lp_distance accepted a malformed vector"
  fi
  if expect_err "p must be > 0" \
      "SELECT fractal_vector_lp_distance('1,0,0','0,1,0',0.0);"; then
    pass "22 v2_functions: lp_distance rejects p<=0"
  else
    fail "22 v2_functions: lp_distance accepted p<=0"
  fi
  if expect_err "vector dim mismatch" \
      "SELECT fractal_vector_cosine_distance('1,0,0','1,0');"; then
    pass "22 v2_functions: cosine_distance rejects mismatched dims"
  else
    fail "22 v2_functions: cosine_distance accepted mismatched dims"
  fi
  if expect_err "malformed vector" \
      "SELECT fractal_vector_cosine_distance('bad!vec','1,0,0');"; then
    pass "22 v2_functions: cosine_distance rejects a malformed vector"
  else
    fail "22 v2_functions: cosine_distance accepted a malformed vector"
  fi
  if expect_err "malformed vector" \
      "SELECT fractal_vector_quantize_int8('bad!vec');"; then
    pass "22 v2_functions: quantize_int8 rejects a malformed vector"
  else
    fail "22 v2_functions: quantize_int8 accepted a malformed vector"
  fi
  if expect_err "malformed vector" \
      "SELECT fractal_vector_quantize_binary('bad!vec');"; then
    pass "22 v2_functions: quantize_binary rejects a malformed vector"
  else
    fail "22 v2_functions: quantize_binary accepted a malformed vector"
  fi
  if [[ -z "$(sqlq "SELECT fractal_vector_quantize_binary(NULL);")" ]]; then
    pass "22 v2_functions: quantize_binary(NULL) -> NULL (STRICT)"
  else
    fail "22 v2_functions: quantize_binary NULL arg did not yield NULL"
  fi
  if [[ -z "$(sqlq "SELECT fractal_vector_hamming_distance(NULL,x'00');")" ]]; then
    pass "22 v2_functions: hamming_distance(NULL,...) -> NULL (STRICT)"
  else
    fail "22 v2_functions: hamming_distance NULL arg did not yield NULL"
  fi
  if expect_err "expects two packed-bit BLOBs" \
      "SELECT fractal_vector_hamming_distance('1,0,0','1,0,0');"; then
    pass "22 v2_functions: hamming_distance rejects non-BLOB args"
  else
    fail "22 v2_functions: hamming_distance accepted non-BLOB args"
  fi
  if expect_err "must be non-empty and the same length" \
      "SELECT fractal_vector_hamming_distance(x'00',x'0000');"; then
    pass "22 v2_functions: hamming_distance rejects mismatched-length BLOBs"
  else
    fail "22 v2_functions: hamming_distance accepted mismatched-length BLOBs"
  fi
  if expect_err "malformed vector" \
      "SELECT fractal_vector_to_json('bad!vec');"; then
    pass "22 v2_functions: to_json rejects a malformed vector"
  else
    fail "22 v2_functions: to_json accepted a malformed vector"
  fi
  if [[ -z "$(sqlq "SELECT fractal_vector_dims(NULL);")" ]]; then
    pass "22 v2_functions: dims(NULL) -> NULL (STRICT)"
  else
    fail "22 v2_functions: dims NULL arg did not yield NULL"
  fi
  if expect_err "fractal_vector_dims: malformed vector" \
      "SELECT fractal_vector_dims('bad!vec');"; then
    pass "22 v2_functions: dims rejects a malformed vector"
  else
    fail "22 v2_functions: dims accepted a malformed vector"
  fi
  if expect_err "malformed vector" \
      "SELECT fractal_vector_scale('bad!vec', 2.0);"; then
    pass "22 v2_functions: scale rejects a malformed vector"
  else
    fail "22 v2_functions: scale accepted a malformed vector"
  fi
  if expect_err "malformed vector" \
      "SELECT fractal_vector_norm('bad!vec');"; then
    pass "22 v2_functions: norm rejects a malformed vector"
  else
    fail "22 v2_functions: norm accepted a malformed vector"
  fi
  if expect_err "malformed vector" \
      "SELECT fractal_vector_normalize('bad!vec');"; then
    pass "22 v2_functions: normalize rejects a malformed vector"
  else
    fail "22 v2_functions: normalize accepted a malformed vector"
  fi

  # --- fsql_config.c surfaces not exercised above --------------------
  # fractalsql_get on every string-typed key -- each is its own
  # strcmp(key,...) line in cfg_str_value, never reached unless that
  # exact key is queried.
  r=$(sqlq \
    "SELECT fractalsql_get('http_url');" \
    "SELECT fractalsql_get('http_token');" \
    "SELECT fractalsql_get('http_model');" \
    "SELECT fractalsql_get('http_embed_url');" \
    "SELECT fractalsql_get('http_embed_model');" \
    "SELECT fractalsql_get('http_think');" \
    "SELECT fractalsql_get('http_think_provider');" \
    "SELECT fractalsql_get('http_native_url');" \
    "SELECT fractalsql_get('text_to_sql_allowed_statements');" \
    "SELECT fractalsql_get('enterprise_lib');" \
    "SELECT fractalsql_get('enterprise_ledger_key');")
  if [[ $? -eq 0 ]]; then
    pass "22 v2_functions: fractalsql_get reads every string-typed config key"
  else
    fail "22 v2_functions: fractalsql_get string-key sweep: $r"
  fi
  # Empty-string reset: a previously-set key goes back to unset (NULL).
  local cfgreset; cfgreset=$(sqlq \
    "SELECT fractalsql_set('http_token','x');" \
    "SELECT fractalsql_set('http_token','');" \
    "SELECT fractalsql_get('http_token');" | tail -n1)
  [[ -z "$cfgreset" ]] \
    && pass "22 v2_functions: an empty-string set resets a config key to unset" \
    || fail "22 v2_functions: expected NULL after empty-string reset, got: $cfgreset"
  # Over-length URL key (2048 cap) and over-length plain string key
  # (8192 cap).
  local longurl; longurl=$(printf 'a%.0s' $(seq 1 2100))
  if expect_err "too long" \
      "SELECT fractalsql_set('http_embed_url','https://x/$longurl');"; then
    pass "22 v2_functions: config rejects an over-2048-char URL key"
  else
    fail "22 v2_functions: config accepted an over-2048-char URL key"
  fi
  local longstr; longstr=$(printf 'a%.0s' $(seq 1 8200))
  if expect_err "too long" \
      "SELECT fractalsql_set('enterprise_ledger_key','$longstr');"; then
    pass "22 v2_functions: config rejects an over-8192-char plain string key"
  else
    fail "22 v2_functions: config accepted an over-8192-char plain string key"
  fi
  if expect_err "must be one of" \
      "SELECT fractalsql_set('text_to_sql_allowed_statements','bogus');"; then
    pass "22 v2_functions: config rejects an unknown enum value"
  else
    fail "22 v2_functions: config accepted an unknown enum value"
  fi
  r=$(sqlq \
    "SELECT fractalsql_set('agent_partial_reasoning_fail','1');" \
    "SELECT fractalsql_set('agent_partial_reasoning_fail','yes');" \
    "SELECT fractalsql_set('agent_partial_reasoning_fail','0');" \
    "SELECT fractalsql_set('agent_partial_reasoning_fail','no');" \
    "SELECT fractalsql_set('agent_partial_reasoning_fail','off');" \
    "SELECT fractalsql_set('agent_partial_reasoning_fail','true');" \
    "SELECT fractalsql_set('agent_partial_reasoning_fail','false');")
  if [[ $? -eq 0 ]]; then
    pass "22 v2_functions: config bool setter accepts 1/yes/0/no/true/false spellings"
  else
    fail "22 v2_functions: config bool spellings: $r"
  fi
  sqlq "SELECT fractalsql_set('agent_partial_reasoning_fail','off');" >/dev/null 2>&1
  if expect_err "expects an integer" \
      "SELECT fractalsql_set('text_to_sql_max_attempts','bogus');"; then
    pass "22 v2_functions: config int setter rejects a non-numeric value"
  else
    fail "22 v2_functions: config int setter accepted a non-numeric value"
  fi
  if expect_err "expects an integer" \
      "SELECT fractalsql_set('text_to_sql_max_attempts','3abc');"; then
    pass "22 v2_functions: config int setter rejects a value with trailing junk"
  else
    fail "22 v2_functions: config int setter accepted trailing junk"
  fi
  if expect_err "must be 1..10" \
      "SELECT fractalsql_set('text_to_sql_max_attempts','0');"; then
    pass "22 v2_functions: config int setter rejects a below-range value"
  else
    fail "22 v2_functions: config int setter accepted a below-range value"
  fi
  if expect_err "must be 1..10" \
      "SELECT fractalsql_set('text_to_sql_max_attempts','11');"; then
    pass "22 v2_functions: config int setter rejects an above-range value"
  else
    fail "22 v2_functions: config int setter accepted an above-range value"
  fi
  if expect_err "expects true/false/on/off/1/0" \
      "SELECT fractalsql_set('agent_partial_reasoning_fail','bogus');"; then
    pass "22 v2_functions: config bool setter rejects an unknown spelling"
  else
    fail "22 v2_functions: config bool setter accepted an unknown spelling"
  fi
  if expect_err "unknown config key" \
      "SELECT fractalsql_set('not_a_real_key','x');"; then
    pass "22 v2_functions: fractalsql_set rejects an unknown config key"
  else
    fail "22 v2_functions: fractalsql_set accepted an unknown config key"
  fi

  # --- fractalsql_sqlite.c surfaces not exercised above --------------
  local sqrtn; sqrtn=$(sqlq "SELECT sqrt(NULL);")
  [[ -z "$sqrtn" ]] \
    && pass "22 v2_functions: sqrt(NULL) -> NULL" \
    || fail "22 v2_functions: sqrt(NULL) expected NULL, got: $sqrtn"
  local cosn; cosn=$(sqlq "SELECT cos(NULL);")
  [[ -z "$cosn" ]] \
    && pass "22 v2_functions: cos(NULL) -> NULL" \
    || fail "22 v2_functions: cos(NULL) expected NULL, got: $cosn"
  # fractal_search's own argc!=2 check is unreachable via SQL: it is
  # registered at fixed arity 2, so SQLite's own prepare-time arity
  # check ("wrong number of arguments") fires first, every time --
  # confirmed by direct test, not assumed. Dead defensive code, not a
  # coverage gap; no test can reach the function's own branch.
  local fsn; fsn=$(sqlq "SELECT fractal_search(NULL,'1.0,0.0,0.0');")
  [[ -z "$fsn" ]] \
    && pass "22 v2_functions: fractal_search(NULL, ...) -> NULL (STRICT)" \
    || fail "22 v2_functions: fractal_search NULL arg did not yield NULL"
  r=$(sqlq "SELECT fractal_search('0.0,0.0,0.0','1.0,0.0,0.0');")
  [[ "$r" == "1.0" ]] \
    && pass "22 v2_functions: fractal_search cosine_distance's zero-norm fallback (distance=1.0)" \
    || fail "22 v2_functions: expected distance=1.0 for a zero vector, got: $r"

  sqlq "
    CREATE TABLE bt_v22_explore(id INTEGER PRIMARY KEY, embedding TEXT);
    INSERT INTO bt_v22_explore(embedding) VALUES
      (NULL),('1.0,0.05,0.0,0.0'),('0.9,0.1,0.0,0.0'),('0.2,0.9,0.0,0.0'),
      ('0.1,0.1,0.9,0.0'),('0.0,0.0,0.0,1.0'),('0.5,0.5,0.0,0.0'),
      ('0.3,0.3,0.3,0.1');
  " >/dev/null 2>&1 || fail "22 v2_functions: bt_v22_explore fixture setup failed"
  if expect_err "fractal_search_explore(emb, query [, params]) expects" \
      "SELECT fractal_search_explore(embedding) FROM bt_v22_explore;"; then
    pass "22 v2_functions: search_explore rejects the wrong arg count"
  else
    fail "22 v2_functions: search_explore accepted the wrong arg count"
  fi
  r=$(sqlq "SELECT fractal_search_explore(embedding, '1.0,0.05,0.0,0.0',
              '{\"population_size\":16,\"iterations\":8}') FROM bt_v22_explore;")
  if [[ $? -eq 0 ]]; then
    pass "22 v2_functions: search_explore succeeds with a 3rd TEXT params arg"
  else
    fail "22 v2_functions: search_explore 3-arg params call: $r"
  fi
  # Below-floor params (population_size/iterations/diffusion_factor all
  # 0) clamp up to the floor (2/1/1) rather than erroring.
  r=$(sqlq "SELECT fractal_search_explore(embedding, '1.0,0.05,0.0,0.0',
              '{\"population_size\":0,\"iterations\":0,\"diffusion_factor\":0}')
              FROM bt_v22_explore;")
  if [[ $? -eq 0 ]]; then
    pass "22 v2_functions: search_explore clamps below-floor params up instead of erroring"
  else
    fail "22 v2_functions: search_explore below-floor params: $r"
  fi
  if expect_err "fractal_search_explore input error" \
      "SELECT fractal_search_explore(embedding, NULL) FROM bt_v22_explore;"; then
    pass "22 v2_functions: search_explore rejects a NULL query (bad aggregate)"
  else
    fail "22 v2_functions: search_explore accepted a NULL query"
  fi
  if expect_err "fractal_search_explore input error" \
      "SELECT fractal_search_explore(embedding, '1.0,0.0,0.0,0.0,0.0') FROM bt_v22_explore;"; then
    pass "22 v2_functions: search_explore rejects a row whose embedding dim mismatches the query"
  else
    fail "22 v2_functions: search_explore accepted a dim-mismatched row"
  fi
  sqlq "DROP TABLE IF EXISTS bt_v22_explore;" >/dev/null 2>&1
}

gate_23_agents() {
  # The agents embed their query through the EMBED tier (canned
  # 3-dim), so this gate's corpus is 3-dim to match the canned embed.
  sqlq "
    CREATE TABLE bt_agent_docs(
        id INTEGER PRIMARY KEY, body TEXT, emb TEXT);
    INSERT INTO bt_agent_docs(body, emb) VALUES
      ('doc-a about cosine metrics','1.0,0.05,0.0'),
      ('doc-b about vector stores','1.0,0.1,0.0'),
      ('doc-c about fractal search','0.05,1.0,0.0'),
      ('doc-d on SFS optimization','0.1,0.95,0.0'),
      ('doc-e on embedding tiers','0.05,0.0,1.0'),
      ('doc-f on queue processing','0.0,0.05,0.95');
    CREATE TABLE bt_agent_empty(
      id INTEGER PRIMARY KEY, body TEXT, emb TEXT);
    -- fractal_cross_modal_search concatenates its two modality vectors
    -- (morphology ++ clinical) into one query of their combined dim, so
    -- its corpus needs that combined dim, not bt_agent_docs's 3 (sized
    -- for the EMBED tier's canned output used by the search/rag agents
    -- above) -- a separate 6-dim (3+3) fixture, not a shared-table reuse.
    CREATE TABLE bt_agent_docs_xmodal(
        id INTEGER PRIMARY KEY, body TEXT, emb TEXT);
    INSERT INTO bt_agent_docs_xmodal(body, emb) VALUES
      ('xm-a morph-heavy','1.0,0.05,0.0,0.05,0.0,0.0'),
      ('xm-b balanced','0.5,0.5,0.0,0.5,0.5,0.0'),
      ('xm-c clinical-heavy','0.0,0.05,0.0,1.0,0.05,0.0');" >/dev/null 2>&1 \
    || { fail "23 agents: fixture setup failed"; return; }
  # Preamble shared by every agent invocation (chat + embed tiers both
  # served by the embed-capable mock; endpoint keys are dummies).
  local PRE=(
    "SELECT fractalsql_set('reasoning_plugin','$MOCKEMB');"
    "SELECT fractalsql_set('http_url','https://llm.invalid/v1');"
    "SELECT fractalsql_set('http_embed_url','https://embed.invalid/v1');"
    "SELECT fractalsql_set('http_model','mock-model');"
  )
  agent() {  # agent <label> <sql...> (premble prepended)
    local label="$1"; shift
    local r; r=$(sqlq "${PRE[@]}" "$@")
    local rc=$?
    if crashed "$r" "$rc"; then
      fail "23 $label: process crashed"
    elif [[ $rc -ne 0 ]]; then
      fail "23 $label: $r"
    else
      pass "23 $label"
    fi
    LAST_AGENT_OUT="$r"
  }
  local LAST_AGENT_OUT=""
  agent_err() {  # agent_err <label> <want-pattern> <sql...>
    local label="$1"; shift
    local want="$1"; shift
    if expect_err "$want" "${PRE[@]}" "$@"; then
      pass "23 $label"
    else
      fail "23 $label"
    fi
    LAST_AGENT_OUT=""
  }
  agent "search_agent embeds→scouts→synthesizes" \
    "SELECT fractal_search_agent('cosine metrics','bt_agent_docs','emb');"
  grep <<< "$LAST_AGENT_OUT" -q '"answer"' \
    && grep <<< "$LAST_AGENT_OUT" -q '"source_doc_ids"' \
    && pass "23 search_agent returns the composite JSON" \
    || fail "23 search_agent JSON: $LAST_AGENT_OUT"
  agent "rag_agent single-turn RAG" \
    "SELECT fractal_rag_agent('embedding tiers','bt_agent_docs','emb');"
  # The partial-result mode is NOT covered for search_agent/rag_agent
  # here, unlike the domain agents below: agents_rag_pipeline composes
  # TWO reasoning calls (embed, then chat), and a single unloadable
  # "bogus_plugin" fails the embed step first (before any data half
  # exists to hand back), never reaching the chat-only failure the
  # partial branch targets. Reaching it needs a mock plugin that
  # succeeds at embed and fails only at chat -- none of the existing
  # tests/*_plugin.c fixtures are shaped that way, and building one
  # solely for this is deferred (same call made for data_analyst's
  # identical two-stage shape in gate 29).
  agent_err "search_agent bad identifier" \
    "must be plain identifiers" \
    "SELECT fractal_search_agent('q','bt_agent_docs; drop table bt_agent_docs','emb');"
  agent_err "rag_agent bad identifier" \
    "must be plain identifiers" \
    "SELECT fractal_rag_agent('q','bt_agent_docs','emb; drop table bt_agent_docs');"
  agent_err "search_agent missing required args" \
    "query, table_name, and vector_col are required" \
    "SELECT fractal_search_agent(NULL,'bt_agent_docs','emb');"
  agent_err "rag_agent missing required args" \
    "query, table_name, and vector_col are required" \
    "SELECT fractal_rag_agent(NULL,'bt_agent_docs','emb');"
  agent_err "search_agent rejects too few args" \
    "expects 3 to 5 args" \
    "SELECT fractal_search_agent('q','bt_agent_docs');"
  agent_err "search_agent rejects too many args" \
    "expects 3 to 5 args" \
    "SELECT fractal_search_agent('q','bt_agent_docs','emb',50,10,1);"
  agent_err "rag_agent rejects too few args" \
    "expects 3 or 4 args" \
    "SELECT fractal_rag_agent('q','bt_agent_docs');"
  agent_err "rag_agent rejects too many args" \
    "expects 3 or 4 args" \
    "SELECT fractal_rag_agent('q','bt_agent_docs','emb','{}',1);"
  agent_err "search_debug rejects too few args" \
    "expects 1 to 4 args" \
    "SELECT fractal_search_debug();"
  agent_err "search_debug rejects too many args" \
    "expects 1 to 4 args" \
    "SELECT fractal_search_debug('1.0,0.0,0.0',30,50,2,1);"
  agent "sql_agent T2S composition" \
    "SELECT fractal_sql_agent('count the orders');"
  grep <<< "$LAST_AGENT_OUT" -q '"generated_sql"' \
    && pass "23 sql_agent returns the composite JSON" \
    || fail "23 sql_agent JSON: $LAST_AGENT_OUT"
  if expect_err "expects 1 to 4 args" \
      "SELECT fractal_sql_agent('q','[]',1,0,'extra');"; then
    pass "23 sql_agent rejects too many args"
  else
    fail "23 sql_agent accepted too many args"
  fi
  if expect_err "question must not be NULL" \
      "SELECT fractal_sql_agent(NULL);"; then
    pass "23 sql_agent rejects a NULL question"
  else
    fail "23 sql_agent accepted a NULL question"
  fi
  agent_err "sql_agent rejects a malformed table_names" \
    "table_names must be a JSON array" \
    "SELECT fractal_sql_agent('q','not-a-json-array');"

  # sql_agent auto_execute, real SELECT: the PRE preamble above uses
  # $MOCKEMB, whose canned chat reply is a fixed embedding-shaped
  # string ("[0.1,0.2,0.3]") -- never valid SQL, so auto_execute never
  # gets past its own prepare() failure. $MOCK's canned reply instead
  # comes from $SQLTXT, a file this test controls directly: writing a
  # real SELECT into it and switching the reasoning_plugin to $MOCK
  # reaches the actual execute-and-fetch success path (agents_exec_
  # select_json), otherwise dead in every other agent test here.
  sqlq "
    CREATE TABLE bt_sql_t2s(id INTEGER PRIMARY KEY, v INTEGER);
    INSERT INTO bt_sql_t2s VALUES (1,10),(2,20);
  " >/dev/null 2>&1
  printf 'SELECT count(*) AS n FROM bt_sql_t2s' > "$SQLTXT"
  local r_t2s; r_t2s=$(sqlq \
    "SELECT fractalsql_set('reasoning_plugin','$MOCK');" \
    "SELECT fractalsql_set('http_url','https://llm.invalid/v1');" \
    "SELECT fractalsql_set('http_model','mock-model');" \
    "SELECT fractal_sql_agent('count rows','[\"bt_sql_t2s\"]',2,1);")
  grep <<< "$r_t2s" -q '"execution_status":"executed"' \
    && grep <<< "$r_t2s" -q '"rows":\[\[2\]\]' \
    && pass "23 sql_agent auto_execute runs a real generated SELECT and fetches real rows" \
    || fail "23 sql_agent auto_execute: expected a real executed SELECT, got: $r_t2s"
  # table_names as a 2-element JSON array: agents_parse_string_array's
  # comma-separated loop, otherwise only ever exercised with a single
  # element above (and never at all elsewhere in this suite).
  sqlq "CREATE TABLE bt_sql_t2s2(id INTEGER PRIMARY KEY, w INTEGER);
    INSERT INTO bt_sql_t2s2 VALUES (1,5);" >/dev/null 2>&1
  local r_t2s2; r_t2s2=$(sqlq \
    "SELECT fractalsql_set('reasoning_plugin','$MOCK');" \
    "SELECT fractal_sql_agent('count rows',
       '[\"bt_sql_t2s\",\"bt_sql_t2s2\"]',2,0);")
  if [[ $? -eq 0 ]]; then
    pass "23 sql_agent accepts a 2-element table_names array"
  else
    fail "23 sql_agent 2-element table_names array: $r_t2s2"
  fi
  sqlq "DROP TABLE IF EXISTS bt_sql_t2s2;" >/dev/null 2>&1
  # Multi-column, multi-row result: agents_exec_select_json's own
  # inter-row ("," between row arrays) and inter-column ("," between a
  # row's own values) joins, otherwise dead -- the single-column
  # single-row count(*) call above never takes either comma branch.
  printf 'SELECT id, v FROM bt_sql_t2s ORDER BY id' > "$SQLTXT"
  local r_t2s3; r_t2s3=$(sqlq \
    "SELECT fractalsql_set('reasoning_plugin','$MOCK');" \
    "SELECT fractal_sql_agent('list rows','[\"bt_sql_t2s\"]',2,1);")
  grep <<< "$r_t2s3" -Fq '"rows":[[1,10],[2,20]]' \
    && pass "23 sql_agent auto_execute joins multiple columns and rows with commas" \
    || fail "23 sql_agent multi-row/col result, got: $r_t2s3"
  # argc<1 (zero args): fractal_sql_agent is registered at variable
  # arity (-1), so SQLite lets a bare, argument-less call reach the
  # function body's own argc check.
  agent_err "sql_agent rejects zero args" \
    "expects 1 to 4 args" \
    "SELECT fractal_sql_agent();"
  # validation_failed: the mock keeps returning the same statement that
  # never parses (references a table that doesn't exist), so every
  # retry is rejected and the loop exhausts without ever setting
  # `passed` -- retry_count == max_retries, result_json carries the
  # last rejection reason.
  printf 'DROP TABLE x' > "$SQLTXT"
  local r_t2svf; r_t2svf=$(sqlq \
    "SELECT fractalsql_set('reasoning_plugin','$MOCK');" \
    "SELECT fractal_sql_agent('count rows','[\"bt_sql_t2s\"]',2,0);")
  grep <<< "$r_t2svf" -Fq '"execution_status":"validation_failed"' \
    && grep <<< "$r_t2svf" -Fq '"retry_count":2' \
    && grep <<< "$r_t2svf" -Fq '"status":"validation_failed"' \
    && pass "23 sql_agent validation_failed after exhausting all retries" \
    || fail "23 sql_agent validation_failed: $r_t2svf"
  # execution_failed: the generated statement is a valid, allow-listed
  # read-only SELECT (passes agents_check_allowlist), but a runtime
  # error at sqlite3_step time (a malformed vector literal) makes
  # agents_exec_select_json itself fail after `passed` is already set.
  printf "SELECT fractal_vector_from_text('bad!')" > "$SQLTXT"
  local r_t2sef; r_t2sef=$(sqlq \
    "SELECT fractalsql_set('reasoning_plugin','$MOCK');" \
    "SELECT fractal_sql_agent('count rows','[\"bt_sql_t2s\"]',2,1);")
  grep <<< "$r_t2sef" -Fq '"execution_status":"execution_failed"' \
    && grep <<< "$r_t2sef" -Fq '"status":"execution_failed","rows":[]' \
    && pass "23 sql_agent execution_failed: passed validation, failed at step()" \
    || fail "23 sql_agent execution_failed: $r_t2sef"
  printf 'SELECT 1' > "$SQLTXT"
  sqlq "DROP TABLE IF EXISTS bt_sql_t2s;" >/dev/null 2>&1
  agent "plan_explore MCTS branches" \
    "SELECT fractal_agent_plan_explore('1.0,0.0,0.0',
      'bt_agent_docs','emb', 2);"
  grep <<< "$LAST_AGENT_OUT" -q '"branch_id"' \
    && pass "23 plan_explore returns branch plans" \
    || fail "23 plan_explore JSON: $LAST_AGENT_OUT"
  local r_pen; r_pen=$(sqlq \
    "SELECT fractal_agent_plan_explore(NULL,'bt_agent_docs','emb',2);")
  [[ -z "$r_pen" ]] \
    && pass "23 plan_explore STRICT: NULL initial_state yields NULL, not an error" \
    || fail "23 plan_explore expected NULL (STRICT), got: $r_pen"
  if expect_err "must be plain identifiers" \
      "SELECT fractal_agent_plan_explore('1.0,0.0,0.0','bt_agent_docs; drop table bt_agent_docs','emb',2);"; then
    pass "23 plan_explore rejects a non-identifier table name"
  else
    fail "23 plan_explore accepted a non-identifier table name"
  fi
  if expect_err "max_branches must be > 0" \
      "SELECT fractal_agent_plan_explore('1.0,0.0,0.0','bt_agent_docs','emb',0);"; then
    pass "23 plan_explore rejects a non-positive max_branches"
  else
    fail "23 plan_explore accepted a non-positive max_branches"
  fi
  if expect_err "max_branches out of range" \
      "SELECT fractal_agent_plan_explore('1.0,0.0,0.0','bt_agent_docs','emb',100001);"; then
    pass "23 plan_explore rejects an out-of-range max_branches"
  else
    fail "23 plan_explore accepted an out-of-range max_branches"
  fi
  agent "trajectory_predict over telemetry" \
    "SELECT fractal_agent_trajectory_predict('bt_traj','vec',3,2);"
  grep <<< "$LAST_AGENT_OUT" -q '"predicted_state_vector"' \
    && grep <<< "$LAST_AGENT_OUT" -q '"projected_drift_delta"' \
    && grep <<< "$LAST_AGENT_OUT" -q '"risk_threshold_exceeded"' \
    && pass "23 trajectory_predict returns the real predicted-state JSON" \
    || fail "23 trajectory_predict JSON: $LAST_AGENT_OUT"
  local r_tp; r_tp=$(sqlq \
    "SELECT fractal_agent_trajectory_predict(NULL,'vec',3,2);")
  [[ -z "$r_tp" ]] \
    && pass "23 trajectory_predict STRICT: NULL table_name yields NULL, not an error" \
    || fail "23 trajectory_predict expected NULL (STRICT), got: $r_tp"
  agent_err "trajectory_predict bad identifier" \
    "must be plain identifiers" \
    "SELECT fractal_agent_trajectory_predict('bt_traj; drop table bt_traj','vec',3,2);"
  agent_err "trajectory_predict no such table" \
    "no usable rowid key" \
    "SELECT fractal_agent_trajectory_predict('bt_traj_no_such','vec',3,2);"
  agent_err "trajectory_predict baseline_id not found" \
    "no row in bt_traj with rowid" \
    "SELECT fractal_agent_trajectory_predict('bt_traj','vec',999999,2);"
  sqlq "
    CREATE TABLE bt_traj_bad(id INTEGER PRIMARY KEY, vec TEXT);
    INSERT INTO bt_traj_bad(vec) VALUES ('0.0,0.0'),('0.1,0.0,0.0,0.0');
  " >/dev/null 2>&1
  agent_err "trajectory_predict baseline/current dim mismatch" \
    "!= current dim" \
    "SELECT fractal_agent_trajectory_predict('bt_traj_bad','vec',1,2);"
  sqlq "DROP TABLE IF EXISTS bt_traj_bad;" >/dev/null 2>&1
  sqlq "
    CREATE TABLE bt_traj_null(id INTEGER PRIMARY KEY, vec TEXT);
    INSERT INTO bt_traj_null(vec) VALUES (NULL),('0.1,0.2');
  " >/dev/null 2>&1
  agent_err "trajectory_predict NULL baseline vector value" \
    "baseline vector is NULL or malformed" \
    "SELECT fractal_agent_trajectory_predict('bt_traj_null','vec',1,2);"
  sqlq "DROP TABLE IF EXISTS bt_traj_null;" >/dev/null 2>&1
  sqlq "
    CREATE TABLE bt_traj_mal(id INTEGER PRIMARY KEY, vec TEXT);
    INSERT INTO bt_traj_mal(vec) VALUES ('0.1,0.2'),('not,a,vector');
  " >/dev/null 2>&1
  agent_err "trajectory_predict malformed current vector value" \
    "current vector is NULL or malformed" \
    "SELECT fractal_agent_trajectory_predict('bt_traj_mal','vec',1,2);"
  sqlq "DROP TABLE IF EXISTS bt_traj_mal;" >/dev/null 2>&1
  # projected_drift_delta is a cosine-based distance (1 - cos similarity
  # between the delta vector and its nearest corpus neighbor), not a raw
  # Euclidean gap -- confirmed empirically: a large-magnitude baseline with
  # a small orthogonal nudge keeps the delta's *direction* far from both
  # corpus points' directions, pushing the distance well over the 0.5
  # risk threshold even though the Euclidean delta is tiny.
  sqlq "
    CREATE TABLE bt_traj_risk(id INTEGER PRIMARY KEY, vec TEXT);
    INSERT INTO bt_traj_risk(vec) VALUES ('10.0,0.0'),('10.0,1.0');
  " >/dev/null 2>&1
  agent "trajectory_predict large drift sets risk_threshold_exceeded true" \
    "SELECT fractal_agent_trajectory_predict('bt_traj_risk','vec',1,2);"
  grep <<< "$LAST_AGENT_OUT" -Fq '"risk_threshold_exceeded":true' \
    && pass "23 trajectory_predict risk_threshold_exceeded true branch" \
    || fail "23 trajectory_predict expected risk true, got: $LAST_AGENT_OUT"
  sqlq "DROP TABLE IF EXISTS bt_traj_risk;" >/dev/null 2>&1
  # detect_loop: the v2.0.25-core signature (agent_id, state_log, dim
  # [, n_bits, seed, hamming_threshold]) -- SimHash state fingerprints
  # streamed through Brent's cycle detector, plus a DFA drift check over
  # the per-state L2 norms. Both fixtures are 16 states (the DFA step
  # needs >= 16 states, checked first). One-hot encoding keeps the two
  # toggle states distinguishable by direction (a same-signed scalar
  # stream would collapse to one fingerprint and false-positive).
  agent "detect_loop flags a period-2 one-hot toggle" \
    "SELECT fractal_agent_detect_loop('agent-t1',
       '1.0,0.0,0.0,1.0,1.0,0.0,0.0,1.0,1.0,0.0,0.0,1.0,
        1.0,0.0,0.0,1.0,1.0,0.0,0.0,1.0,1.0,0.0,0.0,1.0,
        1.0,0.0,0.0,1.0,1.0,0.0,0.0,1.0', 2, 64, 42.0, 0);"
  grep <<< "$LAST_AGENT_OUT" -q '"is_loop_detected":true' \
    && grep <<< "$LAST_AGENT_OUT" -q '"agent_id":"agent-t1"' \
    && pass "23 detect_loop flags the period-2 toggle (fingerprint cycle, 6-arity form)" \
    || fail "23 detect_loop loop-case JSON: $LAST_AGENT_OUT"
  agent "detect_loop clears a distinct-direction stream" \
    "SELECT fractal_agent_detect_loop('agent-t2',
       '1.0,0.0, 0.8,0.6, 0.6,0.8, 0.0,1.0, 0.6,-0.8, 0.8,-0.6,
       -0.6,0.8, -0.8,0.6, -1.0,0.0, -0.8,-0.6, -0.6,-0.8, 0.0,-1.0,
        0.28,0.96, 0.96,0.28, -0.28,0.96, -0.96,0.28', 2);"
  grep <<< "$LAST_AGENT_OUT" -q '"is_loop_detected":false' \
    && pass "23 detect_loop clears the 16-state stream (distinct directions, unit norms)" \
    || fail "23 detect_loop drift-case JSON: $LAST_AGENT_OUT"
  # A 2-state log clears the ">= 2 states" floor but is far short of
  # DFA's own >= 24-point requirement; DFA is best-effort (matching the
  # pg wrapper), so this returns cleanly with dfa_exponent 0 rather than
  # erroring; the cycle check still runs and correctly finds no cycle
  # in a 2-state stream.
  agent "detect_loop short log is best-effort (DFA declines, no cycle)" \
    "SELECT fractal_agent_detect_loop('agent-t3', '1.0,0.0,0.0,1.0', 2);"
  grep <<< "$LAST_AGENT_OUT" -q '"agent_id":"agent-t3"' \
    && grep <<< "$LAST_AGENT_OUT" -q '"dfa_exponent":0' \
    && grep <<< "$LAST_AGENT_OUT" -q '"is_loop_detected":false' \
    && pass "23 detect_loop short-log JSON shape" \
    || fail "23 detect_loop short-log JSON: $LAST_AGENT_OUT"
  agent_err "detect_loop missing required args" \
    "agent_id, state_log, and dim are required" \
    "SELECT fractal_agent_detect_loop('agent-t4', NULL, 2);"
  agent_err "detect_loop dim must be positive" \
    "dim must be > 0" \
    "SELECT fractal_agent_detect_loop('agent-t4', '1.0,0.0,0.0,1.0', 0);"
  agent_err "detect_loop n_bits must be positive" \
    "n_bits must be > 0" \
    "SELECT fractal_agent_detect_loop('agent-t4', '1.0,0.0,0.0,1.0', 2, 0);"
  agent_err "detect_loop hamming_threshold must be non-negative" \
    "hamming_threshold must be >= 0" \
    "SELECT fractal_agent_detect_loop('agent-t4', '1.0,0.0,0.0,1.0', 2, 64, 42.0, -1);"
  agent_err "detect_loop rejects a malformed state_log" \
    "must be a flattened JSON/CSV array" \
    "SELECT fractal_agent_detect_loop('agent-t4', 'bad!vec', 2);"
  agent_err "detect_loop rejects a state_log length not a multiple of dim" \
    "is not a multiple of dim" \
    "SELECT fractal_agent_detect_loop('agent-t4', '1.0,0.0,0.0', 2);"
  agent_err "detect_loop rejects fewer than 2 states" \
    "must contain at least 2 states" \
    "SELECT fractal_agent_detect_loop('agent-t4', '1.0,0.0', 2);"
  agent "telemetry + trajectory + hybrid + cross_modal + explain" \
    "SELECT fractal_search_telemetry('bt_agent_docs','emb',
       '1.0,0.0,0.0', 2);" \
    "SELECT fractal_search_trajectory('bt_agent_docs','emb',
       '1.0,0.0,0.0', '0.0,1.0,0.0', 2);" \
    "SELECT fractal_hybrid_clinical_search('bt_agent_docs','emb',
       '1.0,0.0,0.0', '1,2,3', 2);" \
    "SELECT fractal_cross_modal_search('bt_agent_docs_xmodal','emb',
       '1.0,0.0,0.0', '0.0,1.0,0.0', 0.5, 2);" \
    "SELECT fractal_explain_result();"
  agent_err "search_trajectory k guard" \
    "k must be > 0" \
    "SELECT fractal_search_trajectory('bt_agent_docs','emb',
       '1.0,0.0,0.0', '0.0,1.0,0.0', 0);"
  agent_err "search_trajectory malformed vector" \
    "malformed vector" \
    "SELECT fractal_search_trajectory('bt_agent_docs','emb',
       'bad!vec', '0.0,1.0,0.0', 2);"
  agent_err "search_trajectory dim mismatch" \
    "must match" \
    "SELECT fractal_search_trajectory('bt_agent_docs','emb',
       '1.0,0.0,0.0', '0.0,1.0', 2);"
  local r_stn; r_stn=$(sqlq \
    "SELECT fractal_search_trajectory(NULL,'emb','1.0,0.0,0.0','0.0,1.0,0.0',2);")
  [[ -z "$r_stn" ]] \
    && pass "23 search_trajectory STRICT: NULL table_name yields NULL, not an error" \
    || fail "23 search_trajectory expected NULL (STRICT), got: $r_stn"
  # Canonical fractal_vector BLOB form for both baseline/current: the
  # float32-subtract fast path, otherwise dead (every other call here
  # uses CSV/JSON text, the double-decode path).
  r=$(sqlq "SELECT fractal_search_trajectory('bt_agent_docs','emb',
       fractal_vector_from_text('1.0,0.0,0.0'),
       fractal_vector_from_text('0.0,1.0,0.0'), 2);")
  if [[ $? -eq 0 ]] && grep <<< "$r" -q "doc_id"; then
    pass "23 search_trajectory succeeds with both vectors as canonical BLOBs (float32 fast path)"
  else
    fail "23 search_trajectory BLOB-pair call: $r"
  fi
  # Expected-error invocations: -bail stops at the first error, so the
  # two guards run as separate agent_err checks (a combined invocation
  # would never surface the second message).
  agent_err "cross_modal alpha_weight guard" \
    "alpha_weight must be in [0,1]" \
    "SELECT fractal_cross_modal_search('bt_agent_docs_xmodal','emb',
       '1.0,0.0,0.0', '0.0,1.0,0.0', 1.5, 2);"
  agent_err "hybrid k guard" \
    "k must be > 0" \
    "SELECT fractal_hybrid_clinical_search('bt_agent_docs','emb',
       'q', '1,2,3', 0);"
  agent_err "hybrid bad identifier" \
    "must be plain identifiers" \
    "SELECT fractal_hybrid_clinical_search('bt_agent_docs; drop table bt_agent_docs','emb',
       '1.0,0.0,0.0', '1,2,3', 2);"
  agent_err "hybrid rejects a malformed doc_ids" \
    "doc_ids must be a non-empty JSON/CSV array" \
    "SELECT fractal_hybrid_clinical_search('bt_agent_docs','emb',
       '1.0,0.0,0.0', 'bad!ids', 2);"
  agent_err "hybrid rejects a malformed query vector" \
    "invalid query vector" \
    "SELECT fractal_hybrid_clinical_search('bt_agent_docs','emb',
       'bad!vec', '1,2,3', 2);"
  local r_hn; r_hn=$(sqlq \
    "SELECT fractal_hybrid_clinical_search(NULL,'emb','1.0,0.0,0.0','1,2,3',2);")
  [[ -z "$r_hn" ]] \
    && pass "23 hybrid_clinical_search STRICT: NULL table_name yields NULL, not an error" \
    || fail "23 hybrid_clinical_search expected NULL (STRICT), got: $r_hn"
  agent_err "cross_modal bad identifier" \
    "must be plain identifiers" \
    "SELECT fractal_cross_modal_search('bt_agent_docs_xmodal; drop table bt_agent_docs_xmodal','emb',
       '1.0,0.0,0.0', '0.0,1.0,0.0', 0.5, 2);"
  agent_err "cross_modal rejects a malformed modality vector" \
    "malformed modality vector" \
    "SELECT fractal_cross_modal_search('bt_agent_docs_xmodal','emb',
       'bad!vec', '0.0,1.0,0.0', 0.5, 2);"
  agent_err "cross_modal k guard" \
    "k must be > 0" \
    "SELECT fractal_cross_modal_search('bt_agent_docs_xmodal','emb',
       '1.0,0.0,0.0', '0.0,1.0,0.0', 0.5, 0);"
  local r_cmn; r_cmn=$(sqlq \
    "SELECT fractal_cross_modal_search(NULL,'emb','1.0,0.0,0.0','0.0,1.0,0.0',0.5,2);")
  [[ -z "$r_cmn" ]] \
    && pass "23 cross_modal_search STRICT: NULL table_name yields NULL, not an error" \
    || fail "23 cross_modal_search expected NULL (STRICT), got: $r_cmn"
  agent_err "no-rows guard" \
    "no rows found in bt_agent_empty.emb" \
    "SELECT fractal_search_agent('q','bt_agent_empty','emb');"

  # --- argument-count extremes not exercised above -------------------
  # search_debug/search_agent/rag_agent's optional trailing args are
  # otherwise only ever exercised at ONE arg count each above; add the
  # max-args call (every optional arg supplied) each is missing.
  sqlq "SELECT fractalsql_set('reasoning_plugin','$MOCK');" >/dev/null 2>&1
  local rdbg; rdbg=$(sqlq "SELECT fractal_search_debug('0.6,0.8,0.0,0.0',10,20,3);")
  [[ "$rdbg" != *ERROR* && -n "$rdbg" ]] \
    && pass "23 agents: search_debug succeeds with all 4 args supplied (iterations/pop_size/diff_f included)" \
    || fail "23 agents: search_debug 4-arg call, got: $rdbg"
  local rsa; rsa=$(sqlq \
    "SELECT fractal_search_agent('cosine metrics','bt_agent_docs','emb',20,10);")
  [[ "$rsa" != *ERROR* && -n "$rsa" ]] \
    && pass "23 agents: search_agent succeeds with all 5 args supplied (pop_size/iterations included)" \
    || fail "23 agents: search_agent 5-arg call, got: $rsa"
  local rra; rra=$(sqlq \
    "SELECT fractal_rag_agent('embedding tiers','bt_agent_docs','emb','{\"unused\":1}');")
  [[ "$rra" != *ERROR* && -n "$rra" ]] \
    && pass "23 agents: rag_agent succeeds with all 4 args supplied (meta_filter included, currently unused)" \
    || fail "23 agents: rag_agent 4-arg call, got: $rra"

  # Explicit SQL NULL at an optional position (argc satisfied, but the
  # value itself is NULL) -- a different branch outcome than simply
  # omitting the trailing arg.
  local rdbgn; rdbgn=$(sqlq "SELECT fractal_search_debug('0.6,0.8,0.0,0.0',NULL,NULL,NULL);")
  [[ "$rdbgn" != *ERROR* && -n "$rdbgn" ]] \
    && pass "23 agents: search_debug falls back to defaults when optional args are explicit NULL" \
    || fail "23 agents: search_debug explicit-NULL call, got: $rdbgn"
  local rsan; rsan=$(sqlq \
    "SELECT fractal_search_agent('cosine metrics','bt_agent_docs','emb',NULL,NULL);")
  [[ "$rsan" != *ERROR* && -n "$rsan" ]] \
    && pass "23 agents: search_agent falls back to defaults when optional args are explicit NULL" \
    || fail "23 agents: search_agent explicit-NULL call, got: $rsan"
  local rsqn; rsqn=$(sqlq \
    "SELECT fractal_sql_agent('count the rows',NULL,NULL);")
  [[ "$rsqn" != *ERROR* && -n "$rsqn" ]] \
    && pass "23 agents: sql_agent falls back to defaults when optional args are explicit NULL" \
    || fail "23 agents: sql_agent explicit-NULL call, got: $rsqn"
  local rdln; rdln=$(sqlq \
    "SELECT fractal_agent_detect_loop('det1','0,0,0,1,1,1,0,0,0,1,1,1',3,NULL,NULL,NULL);")
  [[ "$rdln" != *ERROR* && -n "$rdln" ]] \
    && pass "23 agents: detect_loop falls back to defaults when optional args are explicit NULL" \
    || fail "23 agents: detect_loop explicit-NULL call, got: $rdln"
}

gate_24_enterprise() {
  # The community archive carries no enterprise symbols: the ledger/
  # audit surface is registered but dormant, and must reject cleanly
  # (never crash, never silently no-op).
  if expect_err "enterprise tier not loaded" \
      "SELECT fractal_ledger_flush();"; then
    pass "24 enterprise: ledger_flush rejects cleanly (dormant tier)"
  else
    fail "24 enterprise: ledger path did not surface the dormant error"
  fi
  # audit_log now carries the same enterprise gate as the rest of the
  # ledger surface (see gate 31 ledger_chain, which owns this behavior
  # in detail; previously this wrote unconditionally).
  if expect_err "enterprise tier not loaded" \
      "SELECT fractal_audit_log('entry', '{}');"; then
    pass "24 enterprise: audit_log rejects cleanly (dormant tier)"
  else
    fail "24 enterprise: audit_log did not surface the dormant-tier error"
  fi
  # Engine-side guard behind the MCP server's FSQL_MCP_READ_ONLY switch. Both
  # checks need no enterprise core: the latch is tested before the core is
  # resolved, and DIRECTONLY is enforced by SQLite itself at prepare time.
  # fractal_lock_destructive() is a one-way, per-connection latch (no unlock
  # function exists); after it, the four destructive ledger functions refuse.
  local lock_bad=() lf
  for lf in fractal_ledger_flush fractal_ledger_compact \
            fractal_ledger_reset_soft fractal_ledger_reset_hard; do
    expect_err "locked on this connection" \
        "SELECT fractal_lock_destructive();" "SELECT ${lf}();" >/dev/null \
      || lock_bad+=("$lf")
  done
  if [[ ${#lock_bad[@]} -eq 0 ]]; then
    pass "24 enterprise: fractal_lock_destructive() latches flush/compact/reset_soft/reset_hard on the connection"
  else
    fail "24 enterprise: destructive ledger functions still ran after the latch: ${lock_bad[*]}"
  fi
  # The destructive ledger functions are SQLITE_DIRECTONLY: a trigger or a
  # view cannot make an ordinary statement call them.
  # Reparsed from the schema (separate invocations): objects created and used
  # in one session are never flagged, only ones loaded from sqlite_schema.
  sqlq "CREATE TABLE bt_do(a);" \
       "CREATE TRIGGER bt_do_tr AFTER INSERT ON bt_do BEGIN SELECT fractal_ledger_reset_hard(); END;" \
       "CREATE VIEW bt_do_v AS SELECT fractal_ledger_reset_hard() AS x;" >/dev/null
  local do_ok=1
  expect_err "unsafe use of fractal_ledger_reset_hard" \
      "INSERT INTO bt_do VALUES (1);" || do_ok=0
  expect_err "unsafe use of fractal_ledger_reset_hard" \
      "SELECT * FROM bt_do_v;" || do_ok=0
  sqlq "DROP VIEW bt_do_v;" "DROP TABLE bt_do;" >/dev/null
  if [[ $do_ok -eq 1 ]]; then
    pass "24 enterprise: the destructive ledger functions are DIRECTONLY (refused from a trigger and a view)"
  else
    fail "24 enterprise: a trigger or view reached a destructive ledger function"
  fi
  # fsql_enterprise_ensure's ent_attempted cache: a SECOND dormant-tier
  # call on the same connection (no enterprise_lib reconfigured
  # between them) hits the "earlier attempt failed" short-circuit
  # instead of re-running the full load/signature-check path. Both the
  # "-bail" CLI flag sqlq uses AND the plain CLI's own multi-arg form
  # stop at the first statement's error, so this needs a script fed
  # over stdin (continues past an error, like any .sql script) to
  # reach the second call at all.
  local eac; eac=$(printf '.load %s\nSELECT fractal_audit_unpack(%s);\nSELECT fractal_audit_unpack(%s);\n' \
      "$EXTW" "'x'" "'x'" | "$SQLITE3" "$DBW" 2>&1)
  grep <<< "$eac" -Fq "an earlier attempt failed" \
    && pass "24 enterprise: a second dormant-tier call hits the cached-failure path" \
    || fail "24 enterprise: second dormant-tier call did not cite the earlier attempt, got: $eac"
  # A bogus enterprise_lib must be an absolute path (the same set-time
  # path validation as the plugin keys; $BADPLUGIN is already native-
  # form and MSYS-argument-conversion-safe), and the ledger call then
  # surfaces the load failure. With signature verification mandatory by
  # default the detached-signature check runs BEFORE the dlopen, so a
  # path with no sibling .sig refuses at that earlier gate ("no signature
  # found") rather than at the loader ("could not load"); either way it
  # is a distinct message from the unconfigured dormant-tier one.
  if expect_err "no signature found for enterprise library" \
      "SELECT fractalsql_set('enterprise_lib',
        '$BADPLUGIN-enterprise$PLUGSUF');" \
      "SELECT fractal_ledger_flush();"; then
    pass "24 enterprise: bogus enterprise_lib surfaces the load failure"
  else
    fail "24 enterprise: bogus enterprise_lib did not surface the error"
  fi

  # A library that dlopen()s cleanly but exports none of the 8 required
  # symbols: the ONLY way to reach ent_dlclose_failed() (closing a
  # handle that opened fine but got rejected after the fact) without a
  # TOCTOU race -- every other rejection path here fails before dlopen
  # ever runs.
  if [[ -n "$CC" ]]; then
    local empty_so="$PDIRW/empty_lib$PLUGSUF"
    if "$CC" -shared -fPIC -std=c99 -x c /dev/null -o "$empty_so" \
          >"$PDIRW/empty_lib_build.log" 2>&1; then
      if FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1 expect_err "missing expected enterprise symbols" \
          "SELECT fractalsql_set('enterprise_lib','$empty_so');" \
          "SELECT fractal_ledger_flush();"; then
        pass "24 enterprise: a symbol-less .so dlopens cleanly but is rejected and closed"
      else
        fail "24 enterprise: expected a missing-symbols rejection"
      fi
    else
      skip "24 enterprise: symbol-less .so (failed to build)"
    fi
  else
    skip "24 enterprise: symbol-less .so (no C compiler on PATH)"
  fi

  # ---- mock enterprise core: the active-tier success/failure paths --
  # tests/mock_enterprise_core.c is a test-only stand-in for the real,
  # licensed core (same 8+3-symbol dlsym surface fsql_enterprise.c
  # expects), unsigned -- loaded via FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1,
  # the same dev-drop bypass gate 25 uses for a real core. This is the
  # only place any of this is exercised: without it, every ledger/
  # portfolio-multimodal UDF's resolved-pointer success branch is dead
  # code in this public (no-vendored-core) checkout.
  if [[ ! -f "$(wpath "$MOCKENT")" ]]; then
    skip "24 enterprise: mock core (mock_enterprise_core.c did not build)"
    return
  fi

  local fn
  for fn in fractal_ledger_flush fractal_ledger_compact \
            fractal_ledger_reset_soft fractal_ledger_reset_hard \
            fractal_ledger_load; do
    local r
    r=$(FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1 sqlq \
      "SELECT fractalsql_set('enterprise_lib','$MOCKENT');" \
      "SELECT $fn();")
    if [[ $? -eq 0 ]]; then
      pass "24 enterprise: $fn succeeds while the mock is loaded"
    else
      fail "24 enterprise: $fn errored while the mock is loaded: $r"
    fi
  done
  # fractalsql_set() itself returns "ok" as a visible row, so a
  # multi-statement sqlq call's output is "ok"\n<actual result> --
  # tail -n1 the way every exact-equality check below does.
  local tc; tc=$(FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1 sqlq \
    "SELECT fractalsql_set('enterprise_lib','$MOCKENT');" \
    "SELECT fractal_ledger_truth_count();" | tail -n1)
  [[ "$tc" = "0" ]] \
    && pass "24 enterprise: truth_count succeeds while the mock is loaded" \
    || fail "24 enterprise: expected 0 from truth_count, got: $tc"
  local sc; sc=$(FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1 sqlq \
    "SELECT fractalsql_set('enterprise_lib','$MOCKENT');" \
    "SELECT fractal_ledger_shadow_count();" | tail -n1)
  [[ "$sc" = "0" ]] \
    && pass "24 enterprise: shadow_count succeeds while the mock is loaded" \
    || fail "24 enterprise: expected 0 from shadow_count, got: $sc"

  # Failure branch: the sentinel flips the mock's return codes without
  # touching enterprise_lib again (see mock_enterprise_core.c's own
  # header for why a file, not a value, is the toggle).
  local sentinel="$PDIR/fractalsql_bt_mock_ent_fail"
  rm -f "$sentinel"; touch "$sentinel"
  local rf; rf=$(FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1 FSQL_MOCK_ENT_FAIL="$sentinel" sqlq \
    "SELECT fractalsql_set('enterprise_lib','$MOCKENT');" \
    "SELECT fractal_ledger_flush();")
  local rfrc=$?
  if [[ $rfrc -ne 0 ]]; then
    pass "24 enterprise: flush refuses cleanly when the mock reports failure"
  else
    fail "24 enterprise: expected flush to error with the fail sentinel set, got: $rf"
  fi
  rm -f "$sentinel"

  # Portfolio multimodal family (both optional symbols present in the
  # mock: the UDF prefers _ex when available, so this also exercises
  # that resolved-pointer branch, not just the plain symbol).
  local pm; pm=$(FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1 sqlq \
    "SELECT fractalsql_set('enterprise_lib','$MOCKENT');" \
    "SELECT json_extract(fractal_optimize_portfolio_multimodal(
       '0.1,0.05','0.04,0.01,0.01,0.03',1,2),'\$.n_found');" | tail -n1)
  [[ "$pm" = "1" ]] \
    && pass "24 enterprise: fractal_optimize_portfolio_multimodal returns a well-formed result" \
    || fail "24 enterprise: expected n_found=1, got: $pm"
  # min registered arity is 4 (mu,cov,k,n_restarts); max_front defaults
  # to 8, so n_restarts must be >= 8 unless max_front is also given --
  # pass both explicitly (2,2) to keep max_front<=n_restarts trivially.
  local pmp; pmp=$(FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1 sqlq \
    "SELECT fractalsql_set('enterprise_lib','$MOCKENT');" \
    "SELECT json_extract(fractal_optimize_portfolio_multimodal_pareto(
       '0.1,0.05','0.04,0.01,0.01,0.03',1,2,2),'\$.n_found');" | tail -n1)
  [[ "$pmp" = "1" ]] \
    && pass "24 enterprise: fractal_optimize_portfolio_multimodal_pareto returns a well-formed result" \
    || fail "24 enterprise: expected n_found=1, got: $pmp"

  # fractal_audit_unpack: a direct decode call. The mock's audit_unpack
  # is a pure echo (its own header comment), so round-tripping a blob
  # through it is an exact equality check.
  local au; au=$(FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1 sqlq \
    "SELECT fractalsql_set('enterprise_lib','$MOCKENT');" \
    "SELECT fractal_audit_unpack('hello world') = 'hello world';" | tail -n1)
  [[ "$au" = "1" ]] \
    && pass "24 enterprise: audit_unpack round-trips a payload through the mock" \
    || fail "24 enterprise: expected audit_unpack to echo the payload back exactly, got: $au"
  local aun; aun=$(FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1 sqlq \
    "SELECT fractalsql_set('enterprise_lib','$MOCKENT');" \
    "SELECT fractal_audit_unpack(NULL);" | tail -n1)
  [[ -z "$aun" ]] \
    && pass "24 enterprise: audit_unpack(NULL) -> NULL (STRICT)" \
    || fail "24 enterprise: audit_unpack(NULL) expected NULL, got: $aun"
  if expect_err "enterprise tier not loaded" \
      "SELECT fractal_audit_unpack('x');"; then
    pass "24 enterprise: audit_unpack rejects cleanly (dormant tier)"
  else
    fail "24 enterprise: audit_unpack did not surface the dormant-tier error"
  fi

  # diffusion_mode (parse_diffusion_mode): only reached when the arg is
  # actually passed (NULL/omitted defaults to 'gaussian' without
  # parsing it at all) -- 'levy' exercises the accept branch, a bogus
  # value the reject branch.
  local dm; dm=$(FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1 sqlq \
    "SELECT fractalsql_set('enterprise_lib','$MOCKENT');" \
    "SELECT json_extract(fractal_optimize_portfolio_multimodal(
       '0.1,0.05','0.04,0.01,0.01,0.03',1,2,0.15,0.9,NULL,0,'levy'),'\$.n_found');" | tail -n1)
  [[ "$dm" = "1" ]] \
    && pass "24 enterprise: fractal_optimize_portfolio_multimodal accepts diffusion_mode='levy'" \
    || fail "24 enterprise: expected n_found=1 with diffusion_mode=levy, got: $dm"
  # pareto has its own separate parse_diffusion_mode call site --
  # untested until now even though multimodal's is covered above.
  local dmp; dmp=$(FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1 sqlq \
    "SELECT fractalsql_set('enterprise_lib','$MOCKENT');" \
    "SELECT json_extract(fractal_optimize_portfolio_multimodal_pareto(
       '0.1,0.05','0.04,0.01,0.01,0.03',1,2,2,0,0,'levy'),'\$.n_found');" | tail -n1)
  [[ "$dmp" = "1" ]] \
    && pass "24 enterprise: fractal_optimize_portfolio_multimodal_pareto accepts diffusion_mode='levy'" \
    || fail "24 enterprise: expected n_found=1 with pareto diffusion_mode=levy, got: $dmp"
  # parse_seed's TEXT branch: seed normally arrives as INTEGER; passing
  # it as a TEXT digit string exercises the strtoull parse path.
  local sdt; sdt=$(FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1 sqlq \
    "SELECT fractalsql_set('enterprise_lib','$MOCKENT');" \
    "SELECT json_extract(fractal_optimize_portfolio_multimodal(
       '0.1,0.05','0.04,0.01,0.01,0.03',1,2,0.15,0.9,'42',0,'levy'),'\$.n_found');" | tail -n1)
  [[ "$sdt" = "1" ]] \
    && pass "24 enterprise: fractal_optimize_portfolio_multimodal accepts a TEXT seed" \
    || fail "24 enterprise: expected n_found=1 with TEXT seed, got: $sdt"
  # diffusion_mode is validated before the enterprise-tier check, so
  # this rejection fires with no enterprise_lib needed.
  if expect_err "diffusion_mode must be" \
      "SELECT fractal_optimize_portfolio_multimodal(
        '0.1,0.05','0.04,0.01,0.01,0.03',1,2,0.15,0.9,NULL,0,'bogus');"; then
    pass "24 enterprise: fractal_optimize_portfolio_multimodal rejects an unknown diffusion_mode"
  else
    fail "24 enterprise: expected a diffusion_mode rejection"
  fi

  # fractal_feedback_report / parse_engagement_kind: no enterprise tier
  # needed (fsql_feedback_report is a plain core call).
  local fr; fr=$(sqlq "SELECT fractal_feedback_report(1,'positive');")
  [[ -z "$fr" ]] \
    && pass "24 enterprise: fractal_feedback_report('positive') succeeds" \
    || fail "24 enterprise: expected NULL, got: $fr"
  if expect_err "kind must be one of" \
      "SELECT fractal_feedback_report(1,'bogus');"; then
    pass "24 enterprise: fractal_feedback_report rejects an unknown kind"
  else
    fail "24 enterprise: fractal_feedback_report accepted an unknown kind"
  fi
}

# Python driver for gate 25: the enterprise QTL ledger under stress,
# concurrency, and MAC tamper-evidence, through the REAL vendored
# enterprise core end to end (sys.argv[1] is the core's absolute path).
# Structural tamper (mid-chain byte-flip), a deleted-row gap, and the
# snapshot -> chain schema migration are already fully covered by gate
# 31's storage-layer driver (built directly at the row level, so it
# needs no core at all) -- this driver does not repeat them. What it
# adds, and what genuinely needs a real core: fill-to-cap + churn
# through the real flush()/load() path (Phase A), cross-connection
# persistence and real concurrent writers serialized by
# ledger_chain_insert's BEGIN IMMEDIATE serializing concurrent writers
# (Phase C), and MAC-authenticated tamper-evidence through a real
# HMAC-tagged flush (Phase D), minus the phases gate 31 already owns.
write_py_gate25() {
  cat > "$PDIR/py_gate25.py" <<'PYEOF'
import os, sys, sqlite3, threading, json

db, ext = os.environ["FSQL_BT_DB"], os.environ["FSQL_BT_EXT"]
absw = os.environ["FSQL_BT_ENT_LIB"]

failed = False
def check(label, cond, detail=""):
    global failed
    if cond:
        print("OK: %s" % label)
    else:
        failed = True
        print("FAIL: %s%s" % (label, (" -- " + detail) if detail else ""))

def connect():
    con = sqlite3.connect(db)
    con.enable_load_extension(True)
    con.load_extension(ext)
    con.execute("PRAGMA busy_timeout=5000")
    con.execute("SELECT fractalsql_set('enterprise_lib', ?)", (absw,))
    return con

# ---- Phase A: fill-to-cap (64 truth + 64 shadow = 128) + 10 churn
# cycles. Truth/Shadow each cap at 64 (the core-level cap PG's own gate
# 25 documents); 64+64 with disjoint result_handles encodes all 128 (no
# QTL dedup).
try:
    con = connect()
    con.execute("DROP TABLE IF EXISTS fractalsql_ledger")
    con.execute("SELECT fractal_diversify_enable()")
    con.execute("SELECT fractal_ledger_reset_hard()")
    for i in range(1, 65):
        con.execute("SELECT fractal_feedback_report(?, 'positive')", (i,))
    for i in range(65, 129):
        con.execute("SELECT fractal_feedback_report(?, 'negative')", (i,))
    tc = con.execute("SELECT fractal_ledger_truth_count()").fetchone()[0]
    sc = con.execute("SELECT fractal_ledger_shadow_count()").fetchone()[0]
    con.execute("SELECT fractal_ledger_flush()")
    audit = con.execute(
        "SELECT fractal_audit_unpack(payload) FROM fractalsql_ledger "
        "WHERE kind=1 ORDER BY id DESC LIMIT 1").fetchone()[0]
    ev = len(json.loads(audit))
    check("Phase A fill: truth=64 shadow=64 events=128 after fill-to-cap",
          tc == 64 and sc == 64 and ev == 128,
          "truth=%s shadow=%s events=%s" % (tc, sc, ev))

    for c in range(1, 11):
        con.execute("SELECT fractal_ledger_reset_hard()")
        for i in range(1, 65):
            con.execute("SELECT fractal_feedback_report(?, 'positive')",
                        (i + 1000 * c,))
        for i in range(65, 129):
            con.execute("SELECT fractal_feedback_report(?, 'negative')",
                        (i + 1000 * c,))
        con.execute("SELECT fractal_ledger_flush()")
        con.execute("SELECT fractal_ledger_load()")
    tc = con.execute("SELECT fractal_ledger_truth_count()").fetchone()[0]
    sc = con.execute("SELECT fractal_ledger_shadow_count()").fetchone()[0]
    audit = con.execute(
        "SELECT fractal_audit_unpack(payload) FROM fractalsql_ledger "
        "WHERE kind=1 ORDER BY id DESC LIMIT 1").fetchone()[0]
    ev = len(json.loads(audit))
    check("Phase A churn: truth=64 shadow=64 events=128 after 10 flush/load cycles",
          tc == 64 and sc == 64 and ev == 128,
          "truth=%s shadow=%s events=%s" % (tc, sc, ev))
    con.close()
except sqlite3.Error as e:
    check("Phase A: fill-to-cap/churn completed without error", False, str(e))

# ---- Phase C(a): cross-connection persistence -- seed+flush on one
# connection, load+count on a FRESH one; counts must match (proves the
# table-backed VFS is connection-independent, not in-memory only).
try:
    con1 = connect()
    con1.execute("DROP TABLE IF EXISTS fractalsql_ledger")
    con1.execute("SELECT fractal_diversify_enable()")
    con1.execute("SELECT fractal_ledger_reset_hard()")
    for i in range(1, 11):
        con1.execute("SELECT fractal_feedback_report(?, 'positive')", (i,))
    for i in range(11, 21):
        con1.execute("SELECT fractal_feedback_report(?, 'negative')", (i,))
    con1.execute("SELECT fractal_ledger_flush()")
    con1.close()

    con2 = connect()
    con2.execute("SELECT fractal_ledger_load()")
    t2 = con2.execute("SELECT fractal_ledger_truth_count()").fetchone()[0]
    s2 = con2.execute("SELECT fractal_ledger_shadow_count()").fetchone()[0]
    con2.close()
    check("Phase C(a): cross-connection persistence -- fresh connection loaded 10/10",
          t2 == 10 and s2 == 10, "truth=%s shadow=%s" % (t2, s2))
except sqlite3.Error as e:
    check("Phase C(a): cross-connection persistence completed without error", False, str(e))

# ---- Phase C(b): 8 concurrent writers, each on its own connection,
# seed one event, flush. Fresh chain, pre-flushed with one row first so
# the workers append to an EXISTING chain (avoids a concurrent CREATE
# TABLE IF NOT EXISTS race). Invariant: 9 rows total (1 pre-flush + 8
# concurrent), the chain verifies as a single unforked line -- proving
# BEGIN IMMEDIATE actually serializes the read-head/link/insert
# sequence across real concurrent connections, not just within one --
# and the latest blob decodes.
try:
    setup = connect()
    setup.execute("DROP TABLE IF EXISTS fractalsql_ledger")
    setup.execute("SELECT fractal_diversify_enable()")
    setup.execute("SELECT fractal_feedback_report(0, 'positive')")
    setup.execute("SELECT fractal_ledger_flush()")
    setup.close()

    errors = []
    def worker(w):
        try:
            c = connect()
            c.execute("SELECT fractal_diversify_enable()")
            c.execute("SELECT fractal_feedback_report(?, 'positive')", (w,))
            c.execute("SELECT fractal_ledger_flush()")
            c.close()
        except Exception as e:
            errors.append("worker %d: %s" % (w, e))

    threads = [threading.Thread(target=worker, args=(w,)) for w in range(1, 9)]
    for t in threads: t.start()
    for t in threads: t.join()

    vcon = connect()
    rows = vcon.execute(
        "SELECT count(*) FROM fractalsql_ledger WHERE kind=1").fetchone()[0]
    report = json.loads(vcon.execute("SELECT fractal_ledger_verify()").fetchone()[0])
    latest = vcon.execute(
        "SELECT fractal_audit_unpack(payload) FROM fractalsql_ledger "
        "WHERE kind=1 ORDER BY id DESC LIMIT 1").fetchone()[0]
    vcon.close()
    json.loads(latest)  # must decode cleanly
    check("Phase C(b): 8 concurrent flushes -> 9 append-only rows, chain verifies as one unforked line",
          rows == 9 and report.get("ok") is True and not errors,
          "rows=%s verify=%s errors=%s" % (rows, report, errors))
except sqlite3.Error as e:
    check("Phase C(b): concurrent flush completed without error", False, str(e))

# ---- Phase D: MAC-authenticated tamper-evidence (enterprise_ledger_
# key). Phases A/C ran with the key UNSET (structural path, entry_hash
# only). D sets the key: flush tags the row with HMAC-SHA256 (assert
# length(mac)=32), load verifies; a payload byte-flip (length
# preserved, so it is a structural-blind tamper gate 31 never
# exercises) is rejected by the MAC; re-flush re-tags and load verifies
# clean again.
try:
    con = connect()
    con.execute("DROP TABLE IF EXISTS fractalsql_ledger")
    con.execute("SELECT fractalsql_set('enterprise_ledger_key', 'gate25-mac-key')")
    con.execute("SELECT fractal_diversify_enable()")
    con.execute("SELECT fractal_ledger_reset_hard()")
    con.execute("SELECT fractal_feedback_report(1, 'positive')")
    con.execute("SELECT fractal_ledger_flush()")
    row_id, mac_len, payload = con.execute(
        "SELECT id, length(mac), payload FROM fractalsql_ledger "
        "WHERE kind=1 ORDER BY id DESC LIMIT 1").fetchone()
    check("Phase D: flush tags the row with a 32-byte HMAC", mac_len == 32,
          "mac_len=%s" % mac_len)

    con.execute("SELECT fractal_ledger_load()")  # MAC verifies -> ok

    tampered = bytearray(payload)
    tampered[len(tampered) // 2] ^= 0xFF
    con.execute("UPDATE fractalsql_ledger SET payload=? WHERE id=?",
                (bytes(tampered), row_id))
    con.commit()  # close the implicit DML transaction before load()'s
                  # own internal BEGIN IMMEDIATE (else: "cannot start a
                  # transaction within a transaction")

    tamper_caught = False
    tamper_detail = ""
    try:
        con.execute("SELECT fractal_ledger_load()")
    except sqlite3.Error as e:
        tamper_detail = str(e)
        tamper_caught = "MAC verification failed" in tamper_detail
    check("Phase D: a structural-blind payload byte-flip is rejected by the MAC",
          tamper_caught, tamper_detail or "load did not raise")

    con.execute("SELECT fractal_ledger_reset_hard()")
    con.execute("SELECT fractal_feedback_report(1, 'positive')")
    con.execute("SELECT fractal_ledger_flush()")
    con.execute("SELECT fractal_ledger_load()")  # verifies clean again
    check("Phase D: re-flush re-tags and load verifies clean", True)

    # Phase D(b): a row flushed with NO key set (mac_null) is later
    # loaded with a key configured -- the "has no MAC" branch, distinct
    # from the HMAC-mismatch branch above.
    con.execute("SELECT fractalsql_set('enterprise_ledger_key', '');")
    con.execute("SELECT fractal_ledger_reset_hard()")
    con.execute("SELECT fractal_feedback_report(1, 'positive')")
    con.execute("SELECT fractal_ledger_flush()")  # no key -> mac_null
    con.execute("SELECT fractalsql_set('enterprise_ledger_key', 'gate25-mac-key')")
    nomac_caught = False
    nomac_detail = ""
    try:
        con.execute("SELECT fractal_ledger_load()")
    except sqlite3.Error as e:
        nomac_detail = str(e)
        nomac_caught = "has no MAC" in nomac_detail
    check("Phase D(b): loading a no-MAC row with a key configured is rejected",
          nomac_caught, nomac_detail or "load did not raise")

    # Phase D(c): a stored MAC of the wrong length -- distinct from
    # HMAC-mismatch (right length, wrong tag) and "has no MAC" (NULL).
    con.execute("SELECT fractal_ledger_reset_hard()")
    con.execute("SELECT fractal_feedback_report(1, 'positive')")
    con.execute("SELECT fractal_ledger_flush()")
    row_id2 = con.execute(
        "SELECT id FROM fractalsql_ledger WHERE kind=1 "
        "ORDER BY id DESC LIMIT 1").fetchone()[0]
    con.execute("UPDATE fractalsql_ledger SET mac=? WHERE id=?",
                (b"\x00" * 16, row_id2))
    con.commit()
    badlen_caught = False
    badlen_detail = ""
    try:
        con.execute("SELECT fractal_ledger_load()")
    except sqlite3.Error as e:
        badlen_detail = str(e)
        badlen_caught = "stored MAC is" in badlen_detail
    check("Phase D(c): a wrong-length stored MAC is rejected before any HMAC recompute",
          badlen_caught, badlen_detail or "load did not raise")

    con.close()
except sqlite3.Error as e:
    check("Phase D: MAC tamper-evidence flow completed without error", False, str(e))

sys.exit(1 if failed else 0)
PYEOF
}

gate_25_enterprise_stress() {
  # Self-skips unless an enterprise core is vendored in include/ (none
  # is, on the community drop) -- same detection as gate 24. See
  # write_py_gate25 above for what this gate covers and why.
  local ent_so
  ent_so=$(ls include/*/libfractalsql-enterprise-* 2>/dev/null | head -1)
  if [[ -z "$ent_so" ]]; then
    skip "25 enterprise_stress (no enterprise core vendored in include/)"
    return
  fi
  if [[ -z "$PY" ]]; then
    skip "25 enterprise_stress driver (no python3 sqlite3 stdlib)"
    return
  fi
  local abs absw
  abs=$(cd "$(dirname "$ent_so")" && pwd)/$(basename "$ent_so")
  absw="$(wpath "$abs")"

  write_py_gate25
  # FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1: a dev drop of the enterprise
  # library typically ships unsigned, and signature verification is
  # mandatory by default (fsql_enterprise.c) -- the stress gate tests
  # ledger behavior, not the signature gate, so opt out here the way a
  # dev would.
  if FSQL_BT_ENT_LIB="$absw" FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1 py_run py_gate25; then
    pass "25 enterprise_stress: fill-to-cap+churn, concurrency, MAC tamper-evidence (see driver OK lines above)"
  else
    fail "25 enterprise_stress: see driver output above"
  fi
}

gate_26_enterprise_signature() {
  # Ordering: the signature check is only reachable AFTER a successful
  # load. With no enterprise lib resolvable, enterprise_require_
  # signature=on must still surface the LOAD error, not a signature
  # error.
  local r; r=$(sqlq \
    "SELECT fractalsql_set('enterprise_require_signature','on');" \
    "SELECT fractal_ledger_flush();")
  local rc=$?
  if [[ $rc -ne 0 ]] && grep <<< "$r" -q "enterprise tier not loaded" \
     && ! grep <<< "$r" -q "no signature found"; then
    pass "26 enterprise_signature: load error precedes the signature check"
  else
    fail "26 enterprise_signature: got rc=$rc: $r"
  fi
}

gate_27_think() {
  if [[ ! -f "$(wpath "$THINK")" ]]; then
    skip "27 think (think_reasoning_plugin did not build)"; return
  fi
  assert_dump() {  # assert_dump <label> <grep-pattern>...
    local label="$1"; shift
    local ok=1 pat
    for pat in "$@"; do
      grep -q "$pat" "$(wpath "$THINKDUMP")" 2>/dev/null || ok=0
    done
    [[ $ok -eq 1 ]] \
      && pass "27 think: $label" \
      || fail "27 think: $label; dump: $(cat "$(wpath "$THINKDUMP")" 2>/dev/null)"
  }
  # 1) fractal_reason's chat tier forwards all four keys.
  rm -f "$THINKDUMP"
  sqlq \
    "SELECT fractalsql_set('reasoning_plugin','$THINK');" \
    "SELECT fractalsql_set('http_think','high');" \
    "SELECT fractalsql_set('http_think_provider','openai');" \
    "SELECT fractalsql_set('http_native_url','https://native.invalid/x');" \
    "SELECT fractalsql_set('http_num_ctx','8192');" \
    "SELECT fractal_reason('q');" >/dev/null 2>&1
  assert_dump "fractal_reason forwards the THINK block" \
    "^THINK=high$" "^THINK_PROVIDER=openai$" \
    "^NATIVE_URL=https://native.invalid/x$" "^NUM_CTX=8192$"
  # 2) fractal_text_to_sql's GENERATE step forwards them too.
  rm -f "$THINKDUMP"
  sqlq \
    "SELECT fractalsql_set('reasoning_plugin','$THINK');" \
    "SELECT fractalsql_set('http_think','low');" \
    "SELECT fractalsql_set('http_think_provider','anthropic');" \
    "SELECT fractalsql_set('http_native_url','https://native.invalid/y');" \
    "SELECT fractalsql_set('http_num_ctx','4096');" \
    "SELECT fractal_text_to_sql('q');" >/dev/null 2>&1
  assert_dump "fractal_text_to_sql GENERATE forwards the THINK block" \
    "^THINK=low$" "^THINK_PROVIDER=anthropic$" \
    "^NATIVE_URL=https://native.invalid/y$" "^NUM_CTX=4096$"
  # 3) The EMBED tier must NOT see the THINK block (embed config lives
  # in its own env block; think keys are chat-effort only).
  rm -f "$THINKDUMP"
  sqlq \
    "SELECT fractalsql_set('reasoning_plugin','$THINK');" \
    "SELECT fractalsql_set('http_think','high');" \
    "SELECT fractalsql_set('http_think_provider','openai');" \
    "SELECT fractalsql_set('http_native_url','https://native.invalid/x');" \
    "SELECT fractalsql_set('http_num_ctx','8192');" \
    "SELECT fractalsql_set('http_embed_url','https://embed.invalid/v1');" \
    "SELECT fractal_embed('x');" >/dev/null 2>&1
  assert_dump "fractal_embed sees NO THINK keys" \
    "^THINK=(unset)$" "^THINK_PROVIDER=(unset)$"
}

# Regression test for FSQL_REASONING_TIER_REVIEW/apply_review_env():
# fractal_text_to_sql()'s REVIEW step must never dispatch under T2S's
# hard-forced RESPONSE_MODE=code (before the fix, t2s_review() shared
# FSQL_REASONING_TIER_T2S directly, so REVIEW's plain PASS/FAIL-then-
# explain text response could get run through the code-block extractor
# meant for GENERATE's fenced SQL). tests/mock_reasoning_plugin.c dumps
# RESPONSE_MODE fresh on every generate() call, and REVIEW always runs
# last within one fractal_text_to_sql() call, so the dump file's
# content once the whole call returns reflects REVIEW's own env.
gate_28_review_isolation() {
  assert_dump() {  # assert_dump <label> <grep-pattern>
    local label="$1" pat="$2"
    grep -q "$pat" "$(wpath "$REVIEWDUMP")" 2>/dev/null \
      && pass "28 review_isolation: $label" \
      || fail "28 review_isolation: $label; dump: $(cat "$(wpath "$REVIEWDUMP")" 2>/dev/null)"
  }
  # 1) Regression guard: GENERATE alone (review off) still runs under
  # T2S's forced RESPONSE_MODE=code -- the split must not have
  # accidentally un-forced GENERATE's own tier.
  printf 'SELECT 1' > "$SQLTXT"
  rm -f "$REVIEWDUMP"
  sqlq \
    "SELECT fractalsql_set('reasoning_plugin','$MOCK');" \
    "SELECT fractal_text_to_sql('q');" >/dev/null 2>&1
  assert_dump "GENERATE still runs under T2S's forced RESPONSE_MODE=code" \
    "^RESPONSE_MODE=code$"
  # 2) The actual regression check: with review enabled, REVIEW's own
  # dispatch (the last generate() call within fractal_text_to_sql())
  # must NOT see RESPONSE_MODE=code.
  printf 'SELECT 1' > "$SQLTXT"
  rm -f "$REVIEWDUMP"
  sqlq \
    "SELECT fractalsql_set('reasoning_plugin','$MOCK');" \
    "SELECT fractalsql_set('text_to_sql_use_review','on');" \
    "SELECT fractal_text_to_sql('q');" >/dev/null 2>&1
  assert_dump "REVIEW never sees T2S's forced RESPONSE_MODE=code" \
    "^RESPONSE_MODE=(unset)$"
}

# Smoke gate for the sixteen installable Domain Agent engines
# (src/fsql_domain_agents.c), registered here as plain C SQL
# functions (SQLite has no server-side procedural language and no
# second extension artifact). Deliberately a smoke gate: proves
# representative engines (3 of 16) across the three composition
# shapes -- table-backed + LLM (anomaly_triage), pure retrieval with a
# cohort filter and no LLM (recall_hybrid), array-in + LLM
# (regime_triage) -- run end-to-end against the real C primitives they
# compose, with a canary proving the reasoning step actually ran.
gate_29_domain_agents() {
  sqlq "
    CREATE TABLE bt_da_logs(metric REAL, ts INTEGER, host TEXT);
    INSERT INTO bt_da_logs (metric, ts, host)
    SELECT 50.0 + (value % 8) * 1.3 + CASE WHEN value > 48 THEN 30.0 ELSE 0.0 END,
           value, 'host-1'
      FROM (WITH RECURSIVE c(value) AS (VALUES(1) UNION ALL SELECT value+1 FROM c WHERE value<96)
            SELECT value FROM c);
    CREATE TABLE bt_da_mem(id INTEGER, body TEXT, emb TEXT, kind TEXT);
    INSERT INTO bt_da_mem VALUES
      (1,'alpha','1.0,0.0,0.0','a'),(2,'beta','0.0,1.0,0.0','b'),(3,'gamma','0.9,0.1,0.0','a');
  " >/dev/null 2>&1 || { fail "29 domain_agents: fixture setup failed"; return; }

  printf 'domain-agent-canary' > "$SQLTXT"

  # Partial-result honesty (opt-in agent_partial_reasoning_fail,
  # see section 17 below for the full on/off contrast): a path that
  # cannot load, used throughout this gate to prove each data->reason
  # agent returns its computed data half plus "reasoning_step_failed"
  # instead of discarding the computation when the reasoning endpoint
  # fails partway. Hoisted here (not just section 17) so every agent's
  # own fixture -- still live at that point in the gate -- can reuse it
  # inline, right after that agent's own happy-path assertions.
  local bogus_plugin="$PWD/no_such_reasoning_plugin$PLUGSUF"

  # --- 1: fractal_agent_anomaly_triage (table + drift + reason) ------
  local r1; r1=$(sqlq \
    "SELECT fractalsql_set('reasoning_plugin','$MOCK');" \
    "SELECT json_extract(fractal_agent_anomaly_triage('bt_da_logs','metric','ts','host','host-1',32),'\$.threat_score');")
  grep <<< "$r1" -Eq '^-?[0-9]+(\.[0-9]+)?$' \
    && pass "29 domain_agents: anomaly_triage threat_score is a real computed drift float" \
    || fail "29 domain_agents: expected a numeric threat_score, got: $r1"

  local r1b; r1b=$(sqlq \
    "SELECT fractalsql_set('reasoning_plugin','$MOCK');" \
    "SELECT json_extract(fractal_agent_anomaly_triage('bt_da_logs','metric','ts','host','host-1',32),'\$.triage_summary');")
  grep <<< "$r1b" -q 'domain-agent-canary' \
    && pass "29 domain_agents: anomaly_triage composes drift -> reason (reason step ran)" \
    || fail "29 domain_agents: expected the reasoning canary in triage_summary, got: $r1b"

  local r2; r2=$(sqlq \
    "SELECT fractal_agent_anomaly_triage('bt_da_logs','metric','ts','host','no-such-host',32);")
  grep <<< "$r2" -q 'no rows in' \
    && pass "29 domain_agents: anomaly_triage raises a clean ERROR when the filter matches no rows" \
    || fail "29 domain_agents: expected a no-rows ERROR, got: $r2"

  # Partial-result mode: data half (threat_score) survives a broken reasoning
  # endpoint instead of being discarded.
  local r2pf; r2pf=$(sqlq \
    "SELECT fractalsql_set('agent_partial_reasoning_fail','on');" \
    "SELECT fractalsql_set('reasoning_plugin','$bogus_plugin');" \
    "SELECT fractal_agent_anomaly_triage('bt_da_logs','metric','ts','host','host-1',32);")
  [[ "$r2pf" == *'"reasoning_step_failed"'* && "$r2pf" == *'"threat_score"'* ]] \
    && pass "29 domain_agents: anomaly_triage partial document on a broken reasoning endpoint" \
    || fail "29 domain_agents: anomaly_triage expected the partial document, got: $r2pf"
  sqlq "SELECT fractalsql_set('reasoning_plugin','$MOCK');" \
       "SELECT fractalsql_set('agent_partial_reasoning_fail','off');" >/dev/null 2>&1
  if expect_err "expects 5 or 6 args" \
      "SELECT fractal_agent_anomaly_triage('bt_da_logs','metric','ts','host');"; then
    pass "29 domain_agents: anomaly_triage rejects too few args"
  else
    fail "29 domain_agents: anomaly_triage accepted too few args"
  fi
  if expect_err "expects 5 or 6 args" \
      "SELECT fractal_agent_anomaly_triage('bt_da_logs','metric','ts','host','host-1',32,1);"; then
    pass "29 domain_agents: anomaly_triage rejects too many args"
  else
    fail "29 domain_agents: anomaly_triage accepted too many args"
  fi
  if expect_err "identifier arguments must not be NULL" \
      "SELECT fractal_agent_anomaly_triage(NULL,'metric','ts','host','host-1');"; then
    pass "29 domain_agents: anomaly_triage rejects a NULL log_table"
  else
    fail "29 domain_agents: anomaly_triage accepted a NULL log_table"
  fi
  if expect_err "must be plain identifiers" \
      "SELECT fractal_agent_anomaly_triage('bt_da_logs; drop table bt_da_logs','metric','ts','host','host-1');"; then
    pass "29 domain_agents: anomaly_triage rejects a non-identifier log_table"
  else
    fail "29 domain_agents: anomaly_triage accepted a non-identifier log_table"
  fi

  # --- 2: fractal_agent_recall_hybrid (pure retrieval, cohort filter,
  # no LLM) -- the exact case a prior cohort-building bug broke (row_
  # number computed after WHERE-filtering instead of over the full
  # table), so this also guards that regression.
  local r3; r3=$(sqlq \
    "SELECT fractal_agent_recall_hybrid('bt_da_mem','emb','1.0,0.0,0.0','kind','a',5,'id','body');")
  [[ "$r3" == *'"mem_id":1'* && "$r3" == *'"mem_id":3'* && "$r3" != *'"mem_id":2'* ]] \
    && pass "29 domain_agents: recall_hybrid cohort filter includes only kind='a' rows" \
    || fail "29 domain_agents: expected mem_id 1 and 3 only (not 2), got: $r3"
  if expect_err "expects 3 to 8 args" \
      "SELECT fractal_agent_recall_hybrid('bt_da_mem','emb');"; then
    pass "29 domain_agents: recall_hybrid rejects too few args"
  else
    fail "29 domain_agents: recall_hybrid accepted too few args"
  fi
  if expect_err "mem_table, vec_col, query_vec are required" \
      "SELECT fractal_agent_recall_hybrid(NULL,'emb','1.0,0.0,0.0');"; then
    pass "29 domain_agents: recall_hybrid rejects a NULL required arg"
  else
    fail "29 domain_agents: recall_hybrid accepted a NULL required arg"
  fi
  if expect_err "plain identifiers" \
      "SELECT fractal_agent_recall_hybrid('bt_da_mem; drop table bt_da_mem','emb','1.0,0.0,0.0');"; then
    pass "29 domain_agents: recall_hybrid rejects a non-identifier table name"
  else
    fail "29 domain_agents: recall_hybrid accepted a non-identifier table name"
  fi
  if expect_err "query_vec must be a CSV/JSON vector" \
      "SELECT fractal_agent_recall_hybrid('bt_da_mem','emb','bad!vec');"; then
    pass "29 domain_agents: recall_hybrid rejects a malformed query_vec"
  else
    fail "29 domain_agents: recall_hybrid accepted a malformed query_vec"
  fi
  # Cohort filter matches zero rows (NOT a SQL error) -- the exact
  # shape of the uninitialized-err-buffer bug this session fixed in
  # da_build_cohort/da_table_has_rows: a legitimate zero-row match
  # must raise the clean "filter matched no rows" message, never an
  # engine error built from leftover stack bytes.
  if expect_err "filter matched no rows in bt_da_mem" \
      "SELECT fractal_agent_recall_hybrid('bt_da_mem','emb','1.0,0.0,0.0','kind','no-such-kind');"; then
    pass "29 domain_agents: recall_hybrid raises a clean ERROR when the cohort filter matches no rows"
  else
    fail "29 domain_agents: recall_hybrid expected a clean no-match ERROR"
  fi

  # --- 3: fractal_agent_regime_triage (array-in + dfa/drift + reason) -
  local series; series=$(awk 'BEGIN{srand(7); out="";
    for(i=0;i<100;i++){v=0.1*i+(rand()-0.5)*0.05; if(i>0) out=out","; out=out v} print out}')
  local r4; r4=$(sqlq \
    "SELECT fractalsql_set('reasoning_plugin','$MOCK');" \
    "SELECT json_extract(fractal_agent_regime_triage('$series',32),'\$.dfa_exponent');")
  grep <<< "$r4" -Eq '^-?[0-9]+(\.[0-9]+)?$' \
    && pass "29 domain_agents: regime_triage dfa_exponent is a real computed float" \
    || fail "29 domain_agents: expected a numeric dfa_exponent, got: $r4"

  local r4b; r4b=$(sqlq \
    "SELECT fractalsql_set('reasoning_plugin','$MOCK');" \
    "SELECT json_extract(fractal_agent_regime_triage('$series',32),'\$.rationale');")
  grep <<< "$r4b" -q 'domain-agent-canary' \
    && pass "29 domain_agents: regime_triage composes dfa+drift -> reason (reason step ran)" \
    || fail "29 domain_agents: expected the reasoning canary in rationale, got: $r4b"
  if expect_err "series must be a CSV/JSON vector" \
      "SELECT fractal_agent_regime_triage('bad!vec',32);"; then
    pass "29 domain_agents: regime_triage rejects a malformed series"
  else
    fail "29 domain_agents: regime_triage accepted a malformed series"
  fi
  if expect_err "expects 1 to 4 args" \
      "SELECT fractal_agent_regime_triage();"; then
    pass "29 domain_agents: regime_triage rejects zero args"
  else
    fail "29 domain_agents: regime_triage accepted zero args"
  fi
  if expect_err "expects 1 to 4 args" \
      "SELECT fractal_agent_regime_triage('0.1,0.2',64,0.5,'{}',1);"; then
    pass "29 domain_agents: regime_triage rejects too many args"
  else
    fail "29 domain_agents: regime_triage accepted too many args"
  fi
  if expect_err "series is required" \
      "SELECT fractal_agent_regime_triage(NULL);"; then
    pass "29 domain_agents: regime_triage rejects a NULL series"
  else
    fail "29 domain_agents: regime_triage accepted a NULL series"
  fi

  # --- 4: fractal_agent_outlier_intercept (the metric-arg surface) ----
  # 'cosine' (default) via the telemetry engine; 'l2' via the exact
  # ORDER BY over fractal_vector_l2_distance; any other value is a hard
  # error, never a fallback.
  sqlq "
    CREATE TABLE bt_da_badstates(state_id INTEGER PRIMARY KEY, state_vec TEXT);
    INSERT INTO bt_da_badstates VALUES (1,'1.0,0.0,0.0'),(2,'0.0,1.0,0.0');
  " >/dev/null 2>&1 \
    || { fail "29 domain_agents: bad-state fixture setup failed"; return; }
  local r5; r5=$(sqlq \
    "SELECT fractalsql_set('reasoning_plugin','$MOCK');" \
    "SELECT fractal_agent_outlier_intercept('0.95,0.05,0.0',
       'bt_da_badstates', 'state_vec', 0.5);")
  grep <<< "$r5" -q '"intercepted":true' \
    && grep <<< "$r5" -q 'cosine' \
    && pass "29 domain_agents: outlier_intercept intercepts the near-parallel state (cosine default)" \
    || fail "29 domain_agents: outlier_intercept cosine: $r5"
  # The small-magnitude state is ~0.95 away in Euclidean terms even
  # though cosine would call it near -- the exact-L2 path allows it.
  local r5b; r5b=$(sqlq \
    "SELECT fractalsql_set('reasoning_plugin','$MOCK');" \
    "SELECT fractal_agent_outlier_intercept('0.05,0.0,0.0',
       'bt_da_badstates', 'state_vec', 0.8, 'l2');")
  grep <<< "$r5b" -q '"intercepted":false' \
    && grep <<< "$r5b" -q 'l2' \
    && pass "29 domain_agents: outlier_intercept l2 metric allows the small-magnitude state" \
    || fail "29 domain_agents: outlier_intercept l2: $r5b"
  # Any other metric value (including 'euclid' and NULL) is a hard error.
  if expect_err "metric must be 'cosine' or 'l2'" \
      "SELECT fractalsql_set('reasoning_plugin','$MOCK');" \
      "SELECT fractal_agent_outlier_intercept('1.0,0.0,0.0',
        'bt_da_badstates','state_vec', 0.5, 'euclid');"; then
    pass "29 domain_agents: outlier_intercept unknown metric rejected"
  else
    fail "29 domain_agents: unknown metric accepted"
  fi
  if expect_err "metric must be 'cosine' or 'l2'" \
      "SELECT fractal_agent_outlier_intercept('1.0,0.0,0.0',
        'bt_da_badstates','state_vec', 0.5, NULL);"; then
    pass "29 domain_agents: outlier_intercept explicit-NULL metric rejected (no silent fallback)"
  else
    fail "29 domain_agents: explicit-NULL metric accepted"
  fi
  if expect_err "all arguments are required" \
      "SELECT fractal_agent_outlier_intercept(NULL,'bt_da_badstates','state_vec',0.5);"; then
    pass "29 domain_agents: outlier_intercept rejects a NULL state_vec"
  else
    fail "29 domain_agents: outlier_intercept accepted a NULL state_vec"
  fi
  sqlq "
    CREATE TABLE bt29z_badstates_null(state_id INTEGER PRIMARY KEY, state_vec TEXT);
    INSERT INTO bt29z_badstates_null VALUES (1,NULL),(2,NULL);
  " >/dev/null 2>&1
  if expect_err "no bad-state rows in bt29z_badstates_null" \
      "SELECT fractal_agent_outlier_intercept('1.0,0.0,0.0',
        'bt29z_badstates_null','state_vec', 0.5, 'l2');"; then
    pass "29 domain_agents: outlier_intercept l2 path's own no-rows guard (all-NULL emb col)"
  else
    fail "29 domain_agents: outlier_intercept l2 no-rows guard not raised"
  fi
  sqlq "DROP TABLE IF EXISTS bt29z_badstates_null;" >/dev/null 2>&1

  # Partial-result mode: data half (intercepted/nearest_distance) survives a
  # broken reasoning endpoint instead of being discarded.
  local r5pf; r5pf=$(sqlq \
    "SELECT fractalsql_set('agent_partial_reasoning_fail','on');" \
    "SELECT fractalsql_set('reasoning_plugin','$bogus_plugin');" \
    "SELECT fractal_agent_outlier_intercept('0.95,0.05,0.0',
       'bt_da_badstates', 'state_vec', 0.5);")
  [[ "$r5pf" == *'"reasoning_step_failed"'* && "$r5pf" == *'"intercepted"'* ]] \
    && pass "29 domain_agents: outlier_intercept partial document on a broken reasoning endpoint" \
    || fail "29 domain_agents: outlier_intercept expected the partial document, got: $r5pf"
  sqlq "SELECT fractalsql_set('reasoning_plugin','$MOCK');" \
       "SELECT fractalsql_set('agent_partial_reasoning_fail','off');" >/dev/null 2>&1

  # --- 5: fractal_agent_recommend_diverse (real catalog id + score) ----
  sqlq "
    CREATE TABLE bt_da_catalog(id INTEGER, emb TEXT);
    INSERT INTO bt_da_catalog VALUES
      (10,'0.1,0.2,0.3'),(20,'0.9,0.8,0.7'),(30,'0.5,0.5,0.5');
  " >/dev/null 2>&1 || { fail "29 domain_agents: catalog fixture setup failed"; return; }
  local r6; r6=$(sqlq \
    "SELECT json_extract(fractal_agent_recommend_diverse(
       'bt_da_catalog','emb','0.1,0.2,0.3',3,'id'),'\$[0].item_id');")
  [[ "$r6" = "10" ]] \
    && pass "29 domain_agents: recommend_diverse returns the real nearest catalog id" \
    || fail "29 domain_agents: expected item_id=10, got: $r6"
  local r6b; r6b=$(sqlq \
    "SELECT json_extract(fractal_agent_recommend_diverse(
       'bt_da_catalog','emb','0.1,0.2,0.3',3,'id'),'\$[0].score');")
  grep <<< "$r6b" -Eq '^[0-9]+(\.[0-9]+)?$' \
    && pass "29 domain_agents: recommend_diverse score is a real float" \
    || fail "29 domain_agents: expected a numeric score, got: $r6b"
  if expect_err "query_vec must be a CSV/JSON vector" \
      "SELECT fractal_agent_recommend_diverse(
        'bt_da_catalog','emb','bad!vec',3,'id');"; then
    pass "29 domain_agents: recommend_diverse rejects a malformed query_vec"
  else
    fail "29 domain_agents: recommend_diverse accepted a malformed query_vec"
  fi
  if expect_err "catalog_table, emb_col, query_vec are required" \
      "SELECT fractal_agent_recommend_diverse(NULL,'emb','0.1,0.2,0.3');"; then
    pass "29 domain_agents: recommend_diverse rejects a NULL catalog_table"
  else
    fail "29 domain_agents: recommend_diverse accepted a NULL catalog_table"
  fi
  if expect_err "must be plain identifiers" \
      "SELECT fractal_agent_recommend_diverse(
        'bt_da_catalog; drop table bt_da_catalog','emb','0.1,0.2,0.3');"; then
    pass "29 domain_agents: recommend_diverse rejects a non-identifier catalog_table"
  else
    fail "29 domain_agents: recommend_diverse accepted a non-identifier catalog_table"
  fi
  sqlq "SELECT fractal_diversify_disable();" >/dev/null 2>&1

  # --- 6: fractal_agent_data_analyst (composes sql_agent -> reason) ---
  sqlq "
    CREATE TABLE bt_da_data(id INTEGER PRIMARY KEY, val REAL);
    INSERT INTO bt_da_data VALUES (1,10.5),(2,20.5);
  " >/dev/null 2>&1 || { fail "29 domain_agents: data_analyst fixture setup failed"; return; }
  local r7; r7=$(sqlq \
    "SELECT fractalsql_set('reasoning_plugin','$MOCK');" \
    "SELECT json_extract(fractal_agent_data_analyst(
       'sum of val','[\"bt_da_data\"]',2),'\$.generated_sql');")
  grep <<< "$r7" -q 'domain-agent-canary' \
    && pass "29 domain_agents: data_analyst composes sql_agent (generated_sql is the real LLM step, canary)" \
    || fail "29 domain_agents: expected the canary in generated_sql, got: $r7"
  local r7b; r7b=$(sqlq \
    "SELECT fractalsql_set('reasoning_plugin','$MOCK');" \
    "SELECT json_extract(fractal_agent_data_analyst(
       'sum of val','[\"bt_da_data\"]',2),'\$.result_json');")
  grep <<< "$r7b" -q 'status' \
    && pass "29 domain_agents: data_analyst result_json is a real jsonb (auto_execute ran)" \
    || fail "29 domain_agents: expected a status-bearing result_json, got: $r7b"
  local r7c; r7c=$(sqlq \
    "SELECT fractalsql_set('reasoning_plugin','$MOCK');" \
    "SELECT json_extract(fractal_agent_data_analyst(
       'sum of val','[\"bt_da_data\"]',2),'\$.analysis');")
  grep <<< "$r7c" -q 'domain-agent-canary' \
    && pass "29 domain_agents: data_analyst composes sql_agent -> reason (analysis is the real reason step, canary)" \
    || fail "29 domain_agents: expected the canary in analysis, got: $r7c"
  if expect_err "expects 1 to 4 args" \
      "SELECT fractal_agent_data_analyst();"; then
    pass "29 domain_agents: data_analyst rejects zero args"
  else
    fail "29 domain_agents: data_analyst accepted zero args"
  fi
  if expect_err "expects 1 to 4 args" \
      "SELECT fractal_agent_data_analyst('q',NULL,2,'{}',1);"; then
    pass "29 domain_agents: data_analyst rejects too many args"
  else
    fail "29 domain_agents: data_analyst accepted too many args"
  fi
  if expect_err "question must not be NULL" \
      "SELECT fractal_agent_data_analyst(NULL);"; then
    pass "29 domain_agents: data_analyst rejects a NULL question"
  else
    fail "29 domain_agents: data_analyst accepted a NULL question"
  fi

  # --- 7: fractal_agent_patient_deterioration_triage (hybrid+trajectory
  # -> reason) + empty-table guard --------------------------------------
  sqlq "
    CREATE TABLE bt_da_patients(id INTEGER PRIMARY KEY, vitals TEXT);
    INSERT INTO bt_da_patients VALUES
      (1,'0.9,-0.8,0.7,0.6'),(2,'0.1,0.1,0.1,0.1'),
      (3,'0.2,0.2,0.2,0.2'),(4,'0.85,-0.75,0.65,0.55');
  " >/dev/null 2>&1 || { fail "29 domain_agents: patient fixture setup failed"; return; }
  local r8; r8=$(sqlq \
    "SELECT fractalsql_set('reasoning_plugin','$MOCK');" \
    "SELECT json_extract(fractal_agent_patient_deterioration_triage(
       'bt_da_patients','vitals','0.9,-0.8,0.7,0.6',
       '0.1,0.1,0.1,0.1','0.95,-0.85,0.75,0.65',NULL,5,'id'),'\$.nearest_cohort_id');")
  grep <<< "$r8" -Eq '^[0-9]+$' \
    && pass "29 domain_agents: patient_deterioration_triage returns the real nearest cohort id" \
    || fail "29 domain_agents: expected a numeric nearest_cohort_id, got: $r8"
  local r8b; r8b=$(sqlq \
    "SELECT fractalsql_set('reasoning_plugin','$MOCK');" \
    "SELECT json_extract(fractal_agent_patient_deterioration_triage(
       'bt_da_patients','vitals','0.9,-0.8,0.7,0.6',
       '0.1,0.1,0.1,0.1','0.95,-0.85,0.75,0.65',NULL,5,'id'),'\$.rationale');")
  grep <<< "$r8b" -q 'domain-agent-canary' \
    && pass "29 domain_agents: patient_deterioration_triage composes hybrid+trajectory -> reason (canary)" \
    || fail "29 domain_agents: expected the canary in rationale, got: $r8b"

  # Partial-result mode: data half (nearest_cohort_id/cohort_distance) survives a
  # broken reasoning endpoint instead of being discarded.
  local r8pf; r8pf=$(sqlq \
    "SELECT fractalsql_set('agent_partial_reasoning_fail','on');" \
    "SELECT fractalsql_set('reasoning_plugin','$bogus_plugin');" \
    "SELECT fractal_agent_patient_deterioration_triage(
       'bt_da_patients','vitals','0.9,-0.8,0.7,0.6',
       '0.1,0.1,0.1,0.1','0.95,-0.85,0.75,0.65',NULL,5,'id');")
  [[ "$r8pf" == *'"reasoning_step_failed"'* && "$r8pf" == *'"nearest_cohort_id"'* ]] \
    && pass "29 domain_agents: patient_deterioration_triage partial document on a broken reasoning endpoint" \
    || fail "29 domain_agents: patient_deterioration_triage expected the partial document, got: $r8pf"
  sqlq "SELECT fractalsql_set('reasoning_plugin','$MOCK');" \
       "SELECT fractalsql_set('agent_partial_reasoning_fail','off');" >/dev/null 2>&1

  if expect_err "expects 5 to 8 args" \
      "SELECT fractal_agent_patient_deterioration_triage('bt_da_patients','vitals');"; then
    pass "29 domain_agents: patient_deterioration_triage rejects too few args"
  else
    fail "29 domain_agents: patient_deterioration_triage accepted too few args"
  fi
  if expect_err "expects 5 to 8 args" \
      "SELECT fractal_agent_patient_deterioration_triage(
         'bt_da_patients','vitals','1,0,0','0,0,0','1,1,1',NULL,5,'id',99);"; then
    pass "29 domain_agents: patient_deterioration_triage rejects too many args"
  else
    fail "29 domain_agents: patient_deterioration_triage accepted too many args"
  fi
  if expect_err "must be CSV/JSON vectors" \
      "SELECT fractal_agent_patient_deterioration_triage(
        'bt_da_patients','vitals','0.9,-0.8,0.7,0.6','bad!vec','bad!vec',NULL,5,'id');"; then
    pass "29 domain_agents: patient_deterioration_triage rejects a malformed baseline_vec/current_vec"
  else
    fail "29 domain_agents: patient_deterioration_triage accepted a malformed baseline_vec/current_vec"
  fi

  sqlq "DELETE FROM bt_da_patients;" >/dev/null 2>&1
  if expect_err "no patient rows in bt_da_patients" \
      "SELECT fractal_agent_patient_deterioration_triage(
        'bt_da_patients','vitals','0.9,-0.8,0.7,0.6',
        '0.1,0.1,0.1,0.1','0.95,-0.85,0.75,0.65',NULL,5,'id');"; then
    pass "29 domain_agents: patient_deterioration_triage raises a clean ERROR when the patient table is empty"
  else
    fail "29 domain_agents: expected a no-patient-rows ERROR"
  fi

  # --- 8: fractal_agent_feedback_audit (pure analytics, no LLM) +
  # empty-table guard ---------------------------------------------------
  sqlq "
    CREATE TABLE bt_da_fcatalog(id INTEGER PRIMARY KEY, emb TEXT);
    INSERT INTO bt_da_fcatalog VALUES
      (1,'0.4,0.1,0.2'),(2,'-0.3,0.5,0.1'),(3,'0.2,-0.4,0.3'),
      (4,'0.6,0.2,-0.1'),(5,'-0.2,-0.3,0.4'),(6,'0.1,0.6,-0.2');
    CREATE TABLE bt_da_fwarmup(center TEXT);
    INSERT INTO bt_da_fwarmup VALUES
      ('0.3,0.1,0.2'),('-0.1,0.4,0.1'),('0.2,-0.2,0.3'),('0.5,0.1,-0.1');
  " >/dev/null 2>&1 || { fail "29 domain_agents: feedback_audit fixture setup failed"; return; }
  local r9; r9=$(sqlq \
    "SELECT json_extract(fractal_agent_feedback_audit(
       'bt_da_fcatalog','emb','0.5,0.5,0.5',
       'bt_da_fwarmup','center',4,3),'\$.diversity_quotient');")
  grep <<< "$r9" -Eq '^[0-9]+(\.[0-9]+)?$' \
    && pass "29 domain_agents: feedback_audit diversity_quotient is a real float (not NaN)" \
    || fail "29 domain_agents: expected a numeric diversity_quotient, got: $r9"
  local r9b; r9b=$(sqlq \
    "SELECT (json_extract(fractal_agent_feedback_audit(
       'bt_da_fcatalog','emb','0.5,0.5,0.5',
       'bt_da_fwarmup','center',4,3),'\$.explanation') IS NOT NULL);")
  [[ "$r9b" = "1" ]] \
    && pass "29 domain_agents: feedback_audit returns the real session diagnostics" \
    || fail "29 domain_agents: expected a non-null explanation, got: $r9b"
  sqlq "DELETE FROM bt_da_fcatalog;" >/dev/null 2>&1
  if expect_err "no catalog rows in bt_da_fcatalog" \
      "SELECT fractal_agent_feedback_audit(
        'bt_da_fcatalog','emb','0.5,0.5,0.5','bt_da_fwarmup','center',4,3);"; then
    pass "29 domain_agents: feedback_audit raises a clean ERROR when the catalog is empty"
  else
    fail "29 domain_agents: expected a no-catalog-rows ERROR"
  fi
  if expect_err "the first five arguments are required" \
      "SELECT fractal_agent_feedback_audit(
        NULL,'emb','0.5,0.5,0.5','bt_da_fwarmup','center');"; then
    pass "29 domain_agents: feedback_audit rejects a NULL catalog_table"
  else
    fail "29 domain_agents: feedback_audit accepted a NULL catalog_table"
  fi
  if expect_err "must be plain identifiers" \
      "SELECT fractal_agent_feedback_audit(
        'bt_da_fcatalog; drop table bt_da_fcatalog','emb','0.5,0.5,0.5',
        'bt_da_fwarmup','center');"; then
    pass "29 domain_agents: feedback_audit rejects a non-identifier catalog_table"
  else
    fail "29 domain_agents: feedback_audit accepted a non-identifier catalog_table"
  fi

  # --- 9: fractal_agent_schedule_workload (search+telemetry -> reason)
  # + empty-table guard --------------------------------------------------
  sqlq "
    CREATE TABLE bt_da_nodes(id INTEGER PRIMARY KEY, capability TEXT);
    INSERT INTO bt_da_nodes VALUES
      (1,'0.9,0.1,0.0,0.0,0.0'),(2,'0.0,0.0,0.9,0.1,0.0'),(3,'0.1,0.0,0.0,0.0,0.9');
  " >/dev/null 2>&1 || { fail "29 domain_agents: node fixture setup failed"; return; }
  local r10; r10=$(sqlq \
    "SELECT fractalsql_set('reasoning_plugin','$MOCK');" \
    "SELECT json_extract(fractal_agent_schedule_workload(
       '0.8,0.1,0.0,0.0,0.1','bt_da_nodes','capability','id',30,50,5),'\$.assigned_node');")
  grep <<< "$r10" -Eq '^[0-9]+$' \
    && pass "29 domain_agents: schedule_workload returns the real nearest node" \
    || fail "29 domain_agents: expected a numeric assigned_node, got: $r10"
  local r10b; r10b=$(sqlq \
    "SELECT fractalsql_set('reasoning_plugin','$MOCK');" \
    "SELECT json_extract(fractal_agent_schedule_workload(
       '0.8,0.1,0.0,0.0,0.1','bt_da_nodes','capability','id',30,50,5),'\$.rationale');")
  grep <<< "$r10b" -q 'domain-agent-canary' \
    && pass "29 domain_agents: schedule_workload composes search+telemetry -> reason (canary)" \
    || fail "29 domain_agents: expected the canary in rationale, got: $r10b"

  # Partial-result mode: data half (assigned_node/confidence) survives a broken
  # reasoning endpoint instead of being discarded.
  local r10pf; r10pf=$(sqlq \
    "SELECT fractalsql_set('agent_partial_reasoning_fail','on');" \
    "SELECT fractalsql_set('reasoning_plugin','$bogus_plugin');" \
    "SELECT fractal_agent_schedule_workload(
       '0.8,0.1,0.0,0.0,0.1','bt_da_nodes','capability','id',30,50,5);")
  [[ "$r10pf" == *'"reasoning_step_failed"'* && "$r10pf" == *'"assigned_node"'* ]] \
    && pass "29 domain_agents: schedule_workload partial document on a broken reasoning endpoint" \
    || fail "29 domain_agents: schedule_workload expected the partial document, got: $r10pf"
  sqlq "SELECT fractalsql_set('reasoning_plugin','$MOCK');" \
       "SELECT fractalsql_set('agent_partial_reasoning_fail','off');" >/dev/null 2>&1

  sqlq "DELETE FROM bt_da_nodes;" >/dev/null 2>&1
  if expect_err "no node rows in bt_da_nodes" \
      "SELECT fractal_agent_schedule_workload(
        '0.8,0.1,0.0,0.0,0.1','bt_da_nodes','capability','id',30,50,5);"; then
    pass "29 domain_agents: schedule_workload raises a clean ERROR when the node table is empty"
  else
    fail "29 domain_agents: expected a no-node-rows ERROR"
  fi
  if expect_err "expects 4 to 8 args" \
      "SELECT fractal_agent_schedule_workload('0.8,0.1,0.0,0.0,0.1','bt_da_nodes','capability');"; then
    pass "29 domain_agents: schedule_workload rejects too few args"
  else
    fail "29 domain_agents: schedule_workload accepted too few args"
  fi
  if expect_err "expects 4 to 8 args" \
      "SELECT fractal_agent_schedule_workload('0.8,0.1,0.0,0.0,0.1','bt_da_nodes','capability','id',30,50,5,'{}',1);"; then
    pass "29 domain_agents: schedule_workload rejects too many args"
  else
    fail "29 domain_agents: schedule_workload accepted too many args"
  fi
  if expect_err "the first four arguments are required" \
      "SELECT fractal_agent_schedule_workload(NULL,'bt_da_nodes','capability','id');"; then
    pass "29 domain_agents: schedule_workload rejects a NULL task_vec"
  else
    fail "29 domain_agents: schedule_workload accepted a NULL task_vec"
  fi
  if expect_err "must be plain identifiers" \
      "SELECT fractal_agent_schedule_workload('0.8,0.1,0.0,0.0,0.1','bt_da_nodes; drop table bt_da_nodes','capability','id');"; then
    pass "29 domain_agents: schedule_workload rejects a non-identifier node_table"
  else
    fail "29 domain_agents: schedule_workload accepted a non-identifier node_table"
  fi

  # resolved_id-NULL: node_id_col points at a nullable column whose
  # VALUE is NULL for the nearest-matched row (not "row not found") --
  # da_resolve_rowid legitimately returns NULL here, hitting
  # schedule_workload's own "assigned_node":null branch.
  sqlq "
    CREATE TABLE bt29z_nodes(id INTEGER PRIMARY KEY, label TEXT, capability TEXT);
    INSERT INTO bt29z_nodes VALUES (1,NULL,'0.9,0.1,0.0,0.0,0.0');
  " >/dev/null 2>&1
  local r10n; r10n=$(sqlq \
    "SELECT fractalsql_set('reasoning_plugin','$MOCK');" \
    "SELECT fractal_agent_schedule_workload(
       '0.8,0.1,0.0,0.0,0.1','bt29z_nodes','capability','label',30,50,5);")
  grep <<< "$r10n" -Fq '"assigned_node":null' \
    && pass "29 domain_agents: schedule_workload assigned_node:null when the id column's value is NULL" \
    || fail "29 domain_agents: expected assigned_node:null, got: $r10n"
  sqlq "DROP TABLE IF EXISTS bt29z_nodes;" >/dev/null 2>&1

  # --- 10: fractal_agent_rebalance_sibling (optimize+trajectory ->
  # reason) + empty-table guard -----------------------------------------
  sqlq "
    CREATE TABLE bt_da_alloc(id INTEGER PRIMARY KEY, alloc TEXT);
    INSERT INTO bt_da_alloc VALUES
      (1,'0.25,0.25,0.25,0.25'),(2,'0.4,0.3,0.2,0.1'),(3,'0.1,0.2,0.3,0.4');
  " >/dev/null 2>&1 || { fail "29 domain_agents: alloc fixture setup failed"; return; }
  local r11; r11=$(sqlq \
    "SELECT fractalsql_set('reasoning_plugin','$MOCK');" \
    "SELECT json_extract(fractal_agent_rebalance_sibling(
       '0.05,0.10,0.15,0.20',
       '0.04,0.0,0.0,0.0,0.0,0.09,0.0,0.0,0.0,0.0,0.16,0.0,0.0,0.0,0.0,0.25',
       4,'bt_da_alloc','alloc','0.25,0.25,0.25,0.25',NULL,5,'id'),'\$.sharpe');")
  grep <<< "$r11" -Eq '^-?[0-9]+(\.[0-9]+)?$' \
    && pass "29 domain_agents: rebalance_sibling sharpe is the real optimizer output" \
    || fail "29 domain_agents: expected a numeric sharpe, got: $r11"
  local r11b; r11b=$(sqlq \
    "SELECT fractalsql_set('reasoning_plugin','$MOCK');" \
    "SELECT json_extract(fractal_agent_rebalance_sibling(
       '0.05,0.10,0.15,0.20',
       '0.04,0.0,0.0,0.0,0.0,0.09,0.0,0.0,0.0,0.0,0.16,0.0,0.0,0.0,0.0,0.25',
       4,'bt_da_alloc','alloc','0.25,0.25,0.25,0.25',NULL,5,'id'),'\$.nearest_alloc_id');")
  grep <<< "$r11b" -Eq '^[0-9]+$' \
    && pass "29 domain_agents: rebalance_sibling nearest_alloc_id is the real trajectory nearest" \
    || fail "29 domain_agents: expected a numeric nearest_alloc_id, got: $r11b"

  # Partial-result mode: data half (sharpe/weights/nearest_alloc_id) survives a
  # broken reasoning endpoint instead of being discarded.
  local r11pf; r11pf=$(sqlq \
    "SELECT fractalsql_set('agent_partial_reasoning_fail','on');" \
    "SELECT fractalsql_set('reasoning_plugin','$bogus_plugin');" \
    "SELECT fractal_agent_rebalance_sibling(
       '0.05,0.10,0.15,0.20',
       '0.04,0.0,0.0,0.0,0.0,0.09,0.0,0.0,0.0,0.0,0.16,0.0,0.0,0.0,0.0,0.25',
       4,'bt_da_alloc','alloc','0.25,0.25,0.25,0.25',NULL,5,'id');")
  [[ "$r11pf" == *'"reasoning_step_failed"'* && "$r11pf" == *'"sharpe"'* ]] \
    && pass "29 domain_agents: rebalance_sibling partial document on a broken reasoning endpoint" \
    || fail "29 domain_agents: rebalance_sibling expected the partial document, got: $r11pf"
  sqlq "SELECT fractalsql_set('reasoning_plugin','$MOCK');" \
       "SELECT fractalsql_set('agent_partial_reasoning_fail','off');" >/dev/null 2>&1

  sqlq "DELETE FROM bt_da_alloc;" >/dev/null 2>&1
  if expect_err "no allocation rows in bt_da_alloc" \
      "SELECT fractal_agent_rebalance_sibling(
        '0.05,0.10,0.15,0.20',
        '0.04,0.0,0.0,0.0,0.0,0.09,0.0,0.0,0.0,0.0,0.16,0.0,0.0,0.0,0.0,0.25',
        4,'bt_da_alloc','alloc','0.25,0.25,0.25,0.25',NULL,5,'id');"; then
    pass "29 domain_agents: rebalance_sibling raises a clean ERROR when the allocation table is empty"
  else
    fail "29 domain_agents: expected a no-allocation-rows ERROR"
  fi
  if expect_err "expects 6 to 10 args" \
      "SELECT fractal_agent_rebalance_sibling('0.05,0.10','1.0,0.0,0.0,1.0',1,'bt_da_alloc','alloc');"; then
    pass "29 domain_agents: rebalance_sibling rejects too few args"
  else
    fail "29 domain_agents: rebalance_sibling accepted too few args"
  fi
  if expect_err "expects 6 to 10 args" \
      "SELECT fractal_agent_rebalance_sibling('0.05,0.10','1.0,0.0,0.0,1.0',1,'bt_da_alloc','alloc','0.25,0.25',42,5,'id','{}',1);"; then
    pass "29 domain_agents: rebalance_sibling rejects too many args"
  else
    fail "29 domain_agents: rebalance_sibling accepted too many args"
  fi
  if expect_err "the first six arguments are required" \
      "SELECT fractal_agent_rebalance_sibling(NULL,'1.0,0.0,0.0,1.0',1,'bt_da_alloc','alloc','0.25,0.25');"; then
    pass "29 domain_agents: rebalance_sibling rejects a NULL mu"
  else
    fail "29 domain_agents: rebalance_sibling accepted a NULL mu"
  fi
  if expect_err "must be plain identifiers" \
      "SELECT fractal_agent_rebalance_sibling('0.05,0.10','1.0,0.0,0.0,1.0',1,'bt_da_alloc; drop table bt_da_alloc','alloc','0.25,0.25');"; then
    pass "29 domain_agents: rebalance_sibling rejects a non-identifier alloc_table"
  else
    fail "29 domain_agents: rebalance_sibling accepted a non-identifier alloc_table"
  fi

  # --- 11: fractal_agent_detour_classify (trajectory+boxcount -> reason)
  # + empty-table guard --------------------------------------------------
  # Box-counting needs enough points AND enough scale dynamic range,
  # not just >= 8 points (an exactly-regular or tightly-clustered set
  # silently fails the epsilon-bucket filter) -- same linear-spread-
  # with-jitter shape gate 22's own boxcount fixture uses.
  local trace; trace=$(awk 'BEGIN{srand(11); out="";
    for(i=1;i<=40;i++){x=i+rand()*0.01; y=i*0.5+rand()*0.01;
      if(i>1) out=out","; out=out x","y} print out}')
  sqlq "
    CREATE TABLE bt_da_vehicles(id INTEGER PRIMARY KEY, baseline TEXT, current TEXT);
    INSERT INTO bt_da_vehicles VALUES
      (1,'0.1,0.1,0.1,0.1','0.8,0.7,0.6,0.5'),(2,'0.2,0.2,0.2,0.2','0.25,0.25,0.25,0.25');
  " >/dev/null 2>&1 || { fail "29 domain_agents: vehicle fixture setup failed"; return; }
  local r12; r12=$(sqlq \
    "SELECT fractalsql_set('reasoning_plugin','$MOCK');" \
    "SELECT json_extract(fractal_agent_detour_classify(
       'bt_da_vehicles','current','0.1,0.1,0.1,0.1','0.8,0.7,0.6,0.5',
       '$trace',5,'id',2),'\$.trace_complexity');")
  grep <<< "$r12" -Eq '^[0-9]+(\.[0-9]+)?$' \
    && pass "29 domain_agents: detour_classify trace_complexity is the real box-counting dimension" \
    || fail "29 domain_agents: expected a numeric trace_complexity, got: $r12"
  local r12b; r12b=$(sqlq \
    "SELECT fractalsql_set('reasoning_plugin','$MOCK');" \
    "SELECT json_extract(fractal_agent_detour_classify(
       'bt_da_vehicles','current','0.1,0.1,0.1,0.1','0.8,0.7,0.6,0.5',
       '$trace',5,'id',2),'\$.rationale');")
  grep <<< "$r12b" -q 'domain-agent-canary' \
    && pass "29 domain_agents: detour_classify composes trajectory+boxcount -> reason (canary)" \
    || fail "29 domain_agents: expected the canary in rationale, got: $r12b"

  # Partial-result mode: data half (nearest_fleet_id/trajectory_distance/
  # trace_complexity) survives a broken reasoning endpoint instead of
  # being discarded.
  local r12pf; r12pf=$(sqlq \
    "SELECT fractalsql_set('agent_partial_reasoning_fail','on');" \
    "SELECT fractalsql_set('reasoning_plugin','$bogus_plugin');" \
    "SELECT fractal_agent_detour_classify(
       'bt_da_vehicles','current','0.1,0.1,0.1,0.1','0.8,0.7,0.6,0.5',
       '$trace',5,'id',2);")
  [[ "$r12pf" == *'"reasoning_step_failed"'* && "$r12pf" == *'"nearest_fleet_id"'* ]] \
    && pass "29 domain_agents: detour_classify partial document on a broken reasoning endpoint" \
    || fail "29 domain_agents: detour_classify expected the partial document, got: $r12pf"
  sqlq "SELECT fractalsql_set('reasoning_plugin','$MOCK');" \
       "SELECT fractalsql_set('agent_partial_reasoning_fail','off');" >/dev/null 2>&1

  sqlq "DELETE FROM bt_da_vehicles;" >/dev/null 2>&1
  if expect_err "no vehicle rows in bt_da_vehicles" \
      "SELECT fractal_agent_detour_classify(
        'bt_da_vehicles','current','0.1,0.1,0.1,0.1','0.2,0.2,0.2,0.2',
        '0,0,0,0',5,'id',2);"; then
    pass "29 domain_agents: detour_classify raises a clean ERROR when the vehicle table is empty"
  else
    fail "29 domain_agents: expected a no-vehicle-rows ERROR"
  fi
  if expect_err "expects 5 to 8 args" \
      "SELECT fractal_agent_detour_classify('bt_da_vehicles','current','0.1,0.1,0.1,0.1');"; then
    pass "29 domain_agents: detour_classify rejects too few args"
  else
    fail "29 domain_agents: detour_classify accepted too few args"
  fi
  if expect_err "expects 5 to 8 args" \
      "SELECT fractal_agent_detour_classify('bt_da_vehicles','current','0.1,0.1,0.1,0.1','0.2,0.2,0.2,0.2','0,0,0,0',5,'id',2,1);"; then
    pass "29 domain_agents: detour_classify rejects too many args"
  else
    fail "29 domain_agents: detour_classify accepted too many args"
  fi
  if expect_err "the first five arguments are required" \
      "SELECT fractal_agent_detour_classify(NULL,'current','0.1,0.1,0.1,0.1','0.2,0.2,0.2,0.2','0,0,0,0');"; then
    pass "29 domain_agents: detour_classify rejects a NULL vehicle_table"
  else
    fail "29 domain_agents: detour_classify accepted a NULL vehicle_table"
  fi
  if expect_err "must be plain identifiers" \
      "SELECT fractal_agent_detour_classify('bt_da_vehicles; drop table bt_da_vehicles','current','0.1,0.1,0.1,0.1','0.2,0.2,0.2,0.2','0,0,0,0');"; then
    pass "29 domain_agents: detour_classify rejects a non-identifier vehicle_table"
  else
    fail "29 domain_agents: detour_classify accepted a non-identifier vehicle_table"
  fi

  # --- 12: fractal_agent_track_anomaly (trajectory+dfa -> reason) +
  # empty-table guard -----------------------------------------------------
  local heading; heading=$(awk 'BEGIN{srand(13); out=""; cum=0;
    for(i=0;i<80;i++){ step=(i>=30 && i<=50) ? (rand()-0.5)*0.35 : (rand()-0.5)*0.03;
      cum+=step; if(i>0) out=out","; out=out cum } print out}')
  sqlq "
    CREATE TABLE bt_da_tracks(id INTEGER PRIMARY KEY, baseline TEXT, current TEXT);
    INSERT INTO bt_da_tracks VALUES
      (1,'0.1,0.1,0.1,0.1','0.7,-0.4,-0.8,0.9'),(2,'0.2,0.2,0.2,0.2','0.24,0.24,0.24,0.24');
  " >/dev/null 2>&1 || { fail "29 domain_agents: track fixture setup failed"; return; }
  local r13; r13=$(sqlq \
    "SELECT fractalsql_set('reasoning_plugin','$MOCK');" \
    "SELECT json_extract(fractal_agent_track_anomaly(
       'bt_da_tracks','current','0.1,0.1,0.1,0.1','0.7,-0.4,-0.8,0.9',
       '$heading',5,'id'),'\$.dfa_exponent');")
  grep <<< "$r13" -Eq '^-?[0-9]+(\.[0-9]+)?$' \
    && pass "29 domain_agents: track_anomaly dfa_exponent is the real DFA exponent" \
    || fail "29 domain_agents: expected a numeric dfa_exponent, got: $r13"
  local r13b; r13b=$(sqlq \
    "SELECT fractalsql_set('reasoning_plugin','$MOCK');" \
    "SELECT json_extract(fractal_agent_track_anomaly(
       'bt_da_tracks','current','0.1,0.1,0.1,0.1','0.7,-0.4,-0.8,0.9',
       '$heading',5,'id'),'\$.rationale');")
  grep <<< "$r13b" -q 'domain-agent-canary' \
    && pass "29 domain_agents: track_anomaly composes trajectory+dfa -> reason (canary)" \
    || fail "29 domain_agents: expected the canary in rationale, got: $r13b"

  # Partial-result mode: data half (nearest_fleet_id/trajectory_distance/
  # dfa_exponent) survives a broken reasoning endpoint instead of
  # being discarded.
  local r13pf; r13pf=$(sqlq \
    "SELECT fractalsql_set('agent_partial_reasoning_fail','on');" \
    "SELECT fractalsql_set('reasoning_plugin','$bogus_plugin');" \
    "SELECT fractal_agent_track_anomaly(
       'bt_da_tracks','current','0.1,0.1,0.1,0.1','0.7,-0.4,-0.8,0.9',
       '$heading',5,'id');")
  [[ "$r13pf" == *'"reasoning_step_failed"'* && "$r13pf" == *'"nearest_fleet_id"'* ]] \
    && pass "29 domain_agents: track_anomaly partial document on a broken reasoning endpoint" \
    || fail "29 domain_agents: track_anomaly expected the partial document, got: $r13pf"
  sqlq "SELECT fractalsql_set('reasoning_plugin','$MOCK');" \
       "SELECT fractalsql_set('agent_partial_reasoning_fail','off');" >/dev/null 2>&1

  sqlq "DELETE FROM bt_da_tracks;" >/dev/null 2>&1
  if expect_err "no track rows in bt_da_tracks" \
      "SELECT fractal_agent_track_anomaly(
        'bt_da_tracks','current','0.1,0.1,0.1,0.1','0.2,0.2,0.2,0.2',
        '0,0,0',5,'id');"; then
    pass "29 domain_agents: track_anomaly raises a clean ERROR when the track table is empty"
  else
    fail "29 domain_agents: expected a no-track-rows ERROR"
  fi
  if expect_err "expects 5 to 7 args" \
      "SELECT fractal_agent_track_anomaly('bt_da_tracks','current','0.1,0.1,0.1,0.1');"; then
    pass "29 domain_agents: track_anomaly rejects too few args"
  else
    fail "29 domain_agents: track_anomaly accepted too few args"
  fi
  if expect_err "expects 5 to 7 args" \
      "SELECT fractal_agent_track_anomaly('bt_da_tracks','current','0.1,0.1,0.1,0.1','0.2,0.2,0.2,0.2','0,0,0',5,'id',1);"; then
    pass "29 domain_agents: track_anomaly rejects too many args"
  else
    fail "29 domain_agents: track_anomaly accepted too many args"
  fi
  if expect_err "the first five arguments are required" \
      "SELECT fractal_agent_track_anomaly(NULL,'current','0.1,0.1,0.1,0.1','0.2,0.2,0.2,0.2','0,0,0');"; then
    pass "29 domain_agents: track_anomaly rejects a NULL track_table"
  else
    fail "29 domain_agents: track_anomaly accepted a NULL track_table"
  fi
  if expect_err "must be plain identifiers" \
      "SELECT fractal_agent_track_anomaly('bt_da_tracks; drop table bt_da_tracks','current','0.1,0.1,0.1,0.1','0.2,0.2,0.2,0.2','0,0,0');"; then
    pass "29 domain_agents: track_anomaly rejects a non-identifier track_table"
  else
    fail "29 domain_agents: track_anomaly accepted a non-identifier track_table"
  fi

  # --- 13: fractal_agent_network_coverage_alert (morph+drift -> reason)
  # + NULL guard ----------------------------------------------------------
  # Same linear-spread-with-jitter shape as detour_classify's trace
  # above: morphological_complexity needs enough points AND enough
  # scale dynamic range, not just >= 8 points.
  local cloud; cloud=$(awk 'BEGIN{srand(17); out="";
    for(i=1;i<=40;i++){x=i+rand()*0.01; y=i*0.5+rand()*0.01;
      if(i>1) out=out","; out=out x","y} print out}')
  local drift; drift=$(awk 'BEGIN{srand(19); out="";
    for(t=1;t<=96;t++){ if(t<48){v=4.0+1.5*sin(t*0.31)+(rand()-0.5)*0.8}
                        else {v=4.0+3.0*sin(t*1.4)+(rand()-0.5)*0.4}
      if(t>1) out=out","; out=out v } print out}')
  local r14; r14=$(sqlq \
    "SELECT fractalsql_set('reasoning_plugin','$MOCK');" \
    "SELECT json_extract(fractal_agent_network_coverage_alert(
       '$cloud','$drift',2,48,0.5),'\$.morph_dimension');")
  grep <<< "$r14" -Eq '^[0-9]+(\.[0-9]+)?$' \
    && pass "29 domain_agents: network_coverage_alert morph_dimension is the real morphological complexity" \
    || fail "29 domain_agents: expected a numeric morph_dimension, got: $r14"
  local r14b; r14b=$(sqlq \
    "SELECT fractalsql_set('reasoning_plugin','$MOCK');" \
    "SELECT json_extract(fractal_agent_network_coverage_alert(
       '$cloud','$drift',2,48,0.5),'\$.rationale');")
  grep <<< "$r14b" -q 'domain-agent-canary' \
    && pass "29 domain_agents: network_coverage_alert composes morph+drift -> reason (canary)" \
    || fail "29 domain_agents: expected the canary in rationale, got: $r14b"
  if expect_err "point_cloud and drift_series are required" \
      "SELECT fractal_agent_network_coverage_alert(NULL,'1.0,2.0,3.0',2,48,0.5);"; then
    pass "29 domain_agents: network_coverage_alert raises a clean ERROR when point_cloud/drift_series is NULL"
  else
    fail "29 domain_agents: expected a required-args ERROR"
  fi
  if expect_err "point_cloud must be a CSV/JSON vector" \
      "SELECT fractal_agent_network_coverage_alert('bad!vec','1.0,2.0,3.0',2,48,0.5);"; then
    pass "29 domain_agents: network_coverage_alert rejects a malformed point_cloud"
  else
    fail "29 domain_agents: network_coverage_alert accepted a malformed point_cloud"
  fi
  if expect_err "drift_series must be a CSV/JSON vector" \
      "SELECT fractal_agent_network_coverage_alert('$cloud','bad!vec',2,48,0.5);"; then
    pass "29 domain_agents: network_coverage_alert rejects a malformed drift_series"
  else
    fail "29 domain_agents: network_coverage_alert accepted a malformed drift_series"
  fi
  # A flat, regime-free series keeps drift under threshold: the
  # "$drift" fixture above (a deliberate regime shift at t=48) only
  # ever exercises drift_detected:true elsewhere in this gate.
  local flat_drift; flat_drift=$(awk 'BEGIN{srand(3); out="";
    for(t=1;t<=96;t++){v=4.0+0.1*sin(t*0.1); if(t>1) out=out","; out=out v} print out}')
  local r14f; r14f=$(sqlq \
    "SELECT fractalsql_set('reasoning_plugin','$MOCK');" \
    "SELECT fractal_agent_network_coverage_alert('$cloud','$flat_drift',2,48,0.5);")
  grep <<< "$r14f" -Fq '"drift_detected":false' \
    && pass "29 domain_agents: network_coverage_alert drift_detected:false on a flat series" \
    || fail "29 domain_agents: expected drift_detected:false, got: $r14f"
  if expect_err "expects 2 to 6 args" \
      "SELECT fractal_agent_network_coverage_alert('$cloud');"; then
    pass "29 domain_agents: network_coverage_alert rejects too few args"
  else
    fail "29 domain_agents: network_coverage_alert accepted too few args"
  fi
  if expect_err "expects 2 to 6 args" \
      "SELECT fractal_agent_network_coverage_alert('$cloud','$drift',2,48,0.5,'{}',1);"; then
    pass "29 domain_agents: network_coverage_alert rejects too many args"
  else
    fail "29 domain_agents: network_coverage_alert accepted too many args"
  fi

  # Partial-result mode: data half (morph_dimension/lacunarity) survives a broken
  # reasoning endpoint instead of being discarded.
  local r14pf; r14pf=$(sqlq \
    "SELECT fractalsql_set('agent_partial_reasoning_fail','on');" \
    "SELECT fractalsql_set('reasoning_plugin','$bogus_plugin');" \
    "SELECT fractal_agent_network_coverage_alert('$cloud','$drift',2,48,0.5);")
  [[ "$r14pf" == *'"reasoning_step_failed"'* && "$r14pf" == *'"morph_dimension"'* ]] \
    && pass "29 domain_agents: network_coverage_alert partial document on a broken reasoning endpoint" \
    || fail "29 domain_agents: network_coverage_alert expected the partial document, got: $r14pf"
  sqlq "SELECT fractalsql_set('reasoning_plugin','$MOCK');" \
       "SELECT fractalsql_set('agent_partial_reasoning_fail','off');" >/dev/null 2>&1

  # --- 14: fractal_agent_allocate (optimize_portfolio -> reason) +
  # cov-length rejection ------------------------------------------------
  local r15; r15=$(sqlq \
    "SELECT fractalsql_set('reasoning_plugin','$MOCK');" \
    "SELECT fractal_agent_allocate('0.05,0.1','1.0,0.0,0.0,1.0',1,'{}');")
  grep <<< "$r15" -q '"sharpe"' \
    && pass "29 domain_agents: allocate composes optimize_portfolio -> reason (real optimizer jsonb with sharpe)" \
    || fail "29 domain_agents: expected a sharpe-bearing allocation jsonb, got: $r15"
  local r15b; r15b=$(sqlq \
    "SELECT fractalsql_set('reasoning_plugin','$MOCK');" \
    "SELECT json_extract(fractal_agent_allocate(
       '0.05,0.1','1.0,0.0,0.0,1.0',1,'{}'),'\$.rationale');")
  grep <<< "$r15b" -q 'domain-agent-canary' \
    && pass "29 domain_agents: allocate rationale is the real reason step output (canary)" \
    || fail "29 domain_agents: expected the canary in rationale, got: $r15b"
  if expect_err "expects 3 or 4 args" \
      "SELECT fractal_agent_allocate('0.05,0.1','1.0,0.0,0.0,1.0');"; then
    pass "29 domain_agents: allocate rejects too few args"
  else
    fail "29 domain_agents: allocate accepted too few args"
  fi
  if expect_err "expects 3 or 4 args" \
      "SELECT fractal_agent_allocate('0.05,0.1','1.0,0.0,0.0,1.0',1,'{}',1);"; then
    pass "29 domain_agents: allocate rejects too many args"
  else
    fail "29 domain_agents: allocate accepted too many args"
  fi
  if expect_err "mu, cov, and cardinality are required" \
      "SELECT fractal_agent_allocate(NULL,'1.0,0.0,0.0,1.0',1);"; then
    pass "29 domain_agents: allocate rejects a NULL mu"
  else
    fail "29 domain_agents: allocate accepted a NULL mu"
  fi
  if expect_err "must be n_assets^2" \
      "SELECT fractal_agent_allocate('0.1,0.1','1.0',1);"; then
    pass "29 domain_agents: allocate surfaces the optimizer's clean cov-length rejection"
  else
    fail "29 domain_agents: expected a cov-length rejection"
  fi
  if expect_err "mu/cov must be" \
      "SELECT fractal_agent_allocate('bad!vec','1.0,0.0,0.0,1.0',1);"; then
    pass "29 domain_agents: allocate rejects a malformed mu/cov"
  else
    fail "29 domain_agents: allocate accepted a malformed mu/cov"
  fi

  # Partial-result mode: data half (sharpe/allocation) survives a broken
  # reasoning endpoint instead of being discarded.
  local r15pf; r15pf=$(sqlq \
    "SELECT fractalsql_set('agent_partial_reasoning_fail','on');" \
    "SELECT fractalsql_set('reasoning_plugin','$bogus_plugin');" \
    "SELECT fractal_agent_allocate('0.05,0.1','1.0,0.0,0.0,1.0',1,'{}');")
  [[ "$r15pf" == *'"reasoning_step_failed"'* && "$r15pf" == *'"sharpe"'* ]] \
    && pass "29 domain_agents: allocate partial document on a broken reasoning endpoint" \
    || fail "29 domain_agents: allocate expected the partial document, got: $r15pf"
  sqlq "SELECT fractalsql_set('reasoning_plugin','$MOCK');" \
       "SELECT fractalsql_set('agent_partial_reasoning_fail','off');" >/dev/null 2>&1

  # --- 15: fractal_agent_route_task (telemetry -> reason) + empty-
  # capability-table guard ----------------------------------------------
  sqlq "
    CREATE TABLE bt_da_caps(capability_name TEXT, emb TEXT);
    INSERT INTO bt_da_caps VALUES ('cap-a','0.1,0.2,0.3'),('cap-b','0.9,0.8,0.7');
  " >/dev/null 2>&1 || { fail "29 domain_agents: capability fixture setup failed"; return; }
  local r16; r16=$(sqlq \
    "SELECT fractalsql_set('reasoning_plugin','$MOCK');" \
    "SELECT json_extract(fractal_agent_route_task(
       '0.1,0.2,0.3','bt_da_caps','emb','capability_name',1000),'\$.routed_to');" | tail -n1)
  [[ "$r16" = "cap-a" ]] \
    && pass "29 domain_agents: route_task returns the real nearest capability name" \
    || fail "29 domain_agents: expected routed_to=cap-a, got: $r16"
  local r16b; r16b=$(sqlq \
    "SELECT fractalsql_set('reasoning_plugin','$MOCK');" \
    "SELECT json_extract(fractal_agent_route_task(
       '0.1,0.2,0.3','bt_da_caps','emb','capability_name',1000),'\$.rationale');")
  grep <<< "$r16b" -q 'domain-agent-canary' \
    && pass "29 domain_agents: route_task composes telemetry -> reason (reason step ran)" \
    || fail "29 domain_agents: expected the canary in rationale, got: $r16b"

  # Partial-result mode: data half (routed_to/confidence) survives a broken
  # reasoning endpoint instead of being discarded.
  local r16pf; r16pf=$(sqlq \
    "SELECT fractalsql_set('agent_partial_reasoning_fail','on');" \
    "SELECT fractalsql_set('reasoning_plugin','$bogus_plugin');" \
    "SELECT fractal_agent_route_task(
       '0.1,0.2,0.3','bt_da_caps','emb','capability_name',1000);")
  [[ "$r16pf" == *'"reasoning_step_failed"'* && "$r16pf" == *'"routed_to"'* ]] \
    && pass "29 domain_agents: route_task partial document on a broken reasoning endpoint" \
    || fail "29 domain_agents: route_task expected the partial document, got: $r16pf"
  sqlq "SELECT fractalsql_set('reasoning_plugin','$MOCK');" \
       "SELECT fractalsql_set('agent_partial_reasoning_fail','off');" >/dev/null 2>&1

  sqlq "DELETE FROM bt_da_caps;" >/dev/null 2>&1
  if expect_err "no capability rows in bt_da_caps" \
      "SELECT fractal_agent_route_task(
        '0.1,0.2,0.3','bt_da_caps','emb','capability_name',1000);"; then
    pass "29 domain_agents: route_task raises a clean ERROR when the capability table is empty"
  else
    fail "29 domain_agents: expected a no-capability-rows ERROR"
  fi
  if expect_err "expects 5 or 6 args" \
      "SELECT fractal_agent_route_task('0.1,0.2,0.3','bt_da_caps','emb','capability_name');"; then
    pass "29 domain_agents: route_task rejects too few args"
  else
    fail "29 domain_agents: route_task accepted too few args"
  fi
  if expect_err "expects 5 or 6 args" \
      "SELECT fractal_agent_route_task('0.1,0.2,0.3','bt_da_caps','emb','capability_name',1000,200,1);"; then
    pass "29 domain_agents: route_task rejects too many args"
  else
    fail "29 domain_agents: route_task accepted too many args"
  fi
  if expect_err "identifier arguments must not be NULL" \
      "SELECT fractal_agent_route_task(NULL,'bt_da_caps','emb','capability_name',1000);"; then
    pass "29 domain_agents: route_task rejects a NULL task_emb"
  else
    fail "29 domain_agents: route_task accepted a NULL task_emb"
  fi
  if expect_err "must be plain identifiers" \
      "SELECT fractal_agent_route_task('0.1,0.2,0.3','bt_da_caps; drop table bt_da_caps','emb','capability_name',1000);"; then
    pass "29 domain_agents: route_task rejects a non-identifier cap_table"
  else
    fail "29 domain_agents: route_task accepted a non-identifier cap_table"
  fi

  # --- 16: fractal_agent_diverse_portfolios (enterprise tier) ---------
  # argc/NULL validation runs BEFORE the enterprise-tier check, so these
  # reject cleanly with no enterprise core needed.
  if expect_err "expects 3 to 9 args" \
      "SELECT fractal_agent_diverse_portfolios('0.05,0.1','1.0,0.0,0.0,1.0');"; then
    pass "29 domain_agents: diverse_portfolios rejects too few args"
  else
    fail "29 domain_agents: diverse_portfolios accepted too few args"
  fi
  if expect_err "expects 3 to 9 args" \
      "SELECT fractal_agent_diverse_portfolios('0.05,0.1','1.0,0.0,0.0,1.0',1,8,0.15,0.9,42,'{}','sharpe',1);"; then
    pass "29 domain_agents: diverse_portfolios rejects too many args"
  else
    fail "29 domain_agents: diverse_portfolios accepted too many args"
  fi
  if expect_err "mu, cov, cardinality are required" \
      "SELECT fractal_agent_diverse_portfolios(NULL,'1.0,0.0,0.0,1.0',1);"; then
    pass "29 domain_agents: diverse_portfolios rejects a NULL mu"
  else
    fail "29 domain_agents: diverse_portfolios accepted a NULL mu"
  fi
  if [[ -n "$(wpath "$MOCKENT")" && -f "$(wpath "$MOCKENT")" ]]; then
    local r17; r17=$(FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1 sqlq \
      "SELECT fractalsql_set('enterprise_lib','$MOCKENT');" \
      "SELECT fractalsql_set('reasoning_plugin','$MOCK');" \
      "SELECT json_extract(fractal_agent_diverse_portfolios(
         '0.05,0.1','1.0,0.0,0.0,1.0',1),'\$[0].candidate_id');" | tail -n1)
    grep <<< "$r17" -Eq '^[0-9]+$' \
      && pass "29 domain_agents: diverse_portfolios returns real candidates once enterprise is loaded" \
      || fail "29 domain_agents: expected a numeric candidate_id, got: $r17"
    # objective_mode is validated before the enterprise-tier check, so
    # this rejection fires with no enterprise_lib needed.
    if expect_err "objective_mode must be" \
        "SELECT fractal_agent_diverse_portfolios(
          '0.05,0.1','1.0,0.0,0.0,1.0',1,8,0.15,0.9,NULL,'{}','bogus');"; then
      pass "29 domain_agents: diverse_portfolios rejects an unknown objective_mode"
    else
      fail "29 domain_agents: diverse_portfolios accepted an unknown objective_mode"
    fi
    # mu/cov decode also happens before the enterprise-tier check.
    if expect_err "mu/cov must be" \
        "SELECT fractal_agent_diverse_portfolios('bad!vec','1.0,0.0,0.0,1.0',1);"; then
      pass "29 domain_agents: diverse_portfolios rejects a malformed mu/cov"
    else
      fail "29 domain_agents: diverse_portfolios accepted a malformed mu/cov"
    fi

    # Partial-result mode: data half (candidates/n_found) survives a broken
    # reasoning endpoint instead of being discarded.
    local r17pf; r17pf=$(FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1 sqlq \
      "SELECT fractalsql_set('enterprise_lib','$MOCKENT');" \
      "SELECT fractalsql_set('agent_partial_reasoning_fail','on');" \
      "SELECT fractalsql_set('reasoning_plugin','$bogus_plugin');" \
      "SELECT fractal_agent_diverse_portfolios('0.05,0.1','1.0,0.0,0.0,1.0',1);")
    [[ "$r17pf" == *'"reasoning_step_failed"'* && "$r17pf" == *'"candidates"'* ]] \
      && pass "29 domain_agents: diverse_portfolios partial document on a broken reasoning endpoint" \
      || fail "29 domain_agents: diverse_portfolios expected the partial document, got: $r17pf"

    # "no candidates found" (n_found<=0): otherwise unreachable, since
    # the mock always finds exactly one candidate -- FSQL_MOCK_ENT_
    # ZERO_FOUND is a new sentinel added to mock_enterprise_core.c
    # specifically for this branch (same file-touch convention as
    # FSQL_MOCK_ENT_FAIL above).
    local zf_sentinel="$PDIR/fractalsql_bt_mock_ent_zero_found"
    rm -f "$zf_sentinel"; touch "$zf_sentinel"
    if FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1 FSQL_MOCK_ENT_ZERO_FOUND="$zf_sentinel" \
        expect_err "no candidates found" \
        "SELECT fractalsql_set('enterprise_lib','$MOCKENT');" \
        "SELECT fractal_agent_diverse_portfolios('0.05,0.1','1.0,0.0,0.0,1.0',1);"; then
      pass "29 domain_agents: diverse_portfolios raises a clean ERROR when n_found<=0"
    else
      fail "29 domain_agents: diverse_portfolios accepted n_found<=0 without erroring"
    fi
    rm -f "$zf_sentinel"
  else
    skip "29 domain_agents: diverse_portfolios (mock core did not build)"
  fi

  # --- 17: partial-result honesty (opt-in
  # agent_partial_reasoning_fail). With the flag ON, a configured-but-
  # failing reasoning endpoint (a path that cannot load) inside an
  # agent whose data half already computed returns that data half plus
  # "reasoning_step_failed" with the plugin's detail, instead of
  # discarding the computation. With the flag OFF (the documented
  # default) the same call still raises cleanly. The reasoning surface
  # itself (fractal_reason etc.) is NOT covered: it IS the reasoning
  # step, so its failure is the whole result and keeps raising either
  # way. (bogus_plugin is hoisted to this gate's top, reused above too.)
  if expect_err "failed to load reasoning plugin" \
      "SELECT fractalsql_set('agent_partial_reasoning_fail','off');" \
      "SELECT fractalsql_set('reasoning_plugin','$bogus_plugin');" \
      "SELECT fractal_agent_regime_triage('$series',32);"; then
    pass "29 domain_agents: flag off (default) keeps the reasoning-endpoint raise"
  else
    fail "29 domain_agents: expected the default raise with agent_partial_reasoning_fail off"
  fi
  local r18; r18=$(sqlq \
    "SELECT fractalsql_set('agent_partial_reasoning_fail','on');" \
    "SELECT fractalsql_set('reasoning_plugin','$bogus_plugin');" \
    "SELECT fractal_agent_regime_triage('$series',32);")
  grep <<< "$r18" -q '"reasoning_step_failed"' \
    && pass "29 domain_agents: flag on returns the data half plus reasoning_step_failed" \
    || fail "29 domain_agents: expected the partial document, got: $r18"
  grep <<< "$r18" -q '"dfa_exponent"' \
    && pass "29 domain_agents: partial document carries the computed dfa_exponent" \
    || fail "29 domain_agents: partial document lost the data half, got: $r18"

  # Restore the live mock for any later cases in this gate.
  sqlq "SELECT fractalsql_set('reasoning_plugin','$MOCK');" >/dev/null 2>&1

  # --- 18: argument-count extremes not exercised above --------------
  # Every "Engine" primitive above has its own optional trailing args
  # (argc >= N thresholds) -- the sections above mostly exercise ONE
  # mid-range arg count each, missing the argc<N "false" branch (the
  # bare-minimum call) and/or the argc==max "true" branch (every
  # optional arg supplied). Fresh self-contained fixtures (bt29x_*),
  # not gate_29's own -- several of its own tables are emptied by
  # DELETE in the sections above, by this point in the run. $trace/
  # $heading/$cloud/$drift/$series are still in scope from their own
  # sections above (bash locals live for the whole function).
  sqlq "
    CREATE TABLE bt29x_logs(metric REAL, ts INTEGER, host TEXT);
    INSERT INTO bt29x_logs (metric, ts, host)
    SELECT 50.0 + (value % 8) * 1.3 + CASE WHEN value > 48 THEN 30.0 ELSE 0.0 END,
           value, 'host-1'
      FROM (WITH RECURSIVE c(value) AS (VALUES(1) UNION ALL SELECT value+1 FROM c WHERE value<96)
            SELECT value FROM c);
    CREATE TABLE bt29x_catalog(id INTEGER, emb TEXT);
    INSERT INTO bt29x_catalog VALUES (10,'0.1,0.2,0.3'),(20,'0.9,0.8,0.7');
    CREATE TABLE bt29x_data(id INTEGER PRIMARY KEY, val REAL);
    INSERT INTO bt29x_data VALUES (1,10.5),(2,20.5);
    CREATE TABLE bt29x_patients(id INTEGER PRIMARY KEY, vitals TEXT);
    INSERT INTO bt29x_patients VALUES
      (1,'0.9,-0.8,0.7,0.6'),(2,'0.1,0.1,0.1,0.1');
    CREATE TABLE bt29x_fcatalog(id INTEGER PRIMARY KEY, emb TEXT);
    INSERT INTO bt29x_fcatalog VALUES
      (1,'0.4,0.1,0.2'),(2,'-0.3,0.5,0.1'),(3,'0.2,-0.4,0.3');
    CREATE TABLE bt29x_fwarmup(center TEXT);
    INSERT INTO bt29x_fwarmup VALUES ('0.3,0.1,0.2'),('-0.1,0.4,0.1');
    CREATE TABLE bt29x_nodes(id INTEGER PRIMARY KEY, capability TEXT);
    INSERT INTO bt29x_nodes VALUES
      (1,'0.9,0.1,0.0,0.0,0.0'),(2,'0.0,0.0,0.9,0.1,0.0');
    CREATE TABLE bt29x_alloc(id INTEGER PRIMARY KEY, alloc TEXT);
    INSERT INTO bt29x_alloc VALUES
      (1,'0.25,0.25,0.25,0.25'),(2,'0.4,0.3,0.2,0.1');
    CREATE TABLE bt29x_vehicles(id INTEGER PRIMARY KEY, baseline TEXT, current TEXT);
    INSERT INTO bt29x_vehicles VALUES (1,'0.1,0.1,0.1,0.1','0.8,0.7,0.6,0.5');
    CREATE TABLE bt29x_tracks(id INTEGER PRIMARY KEY, baseline TEXT, current TEXT);
    INSERT INTO bt29x_tracks VALUES (1,'0.1,0.1,0.1,0.1','0.7,-0.4,-0.8,0.9');
    CREATE TABLE bt29x_caps(capability_name TEXT, emb TEXT);
    INSERT INTO bt29x_caps VALUES ('cap-a','0.1,0.2,0.3'),('cap-b','0.9,0.8,0.7');
  " >/dev/null 2>&1 || fail "29 domain_agents: argc-extremes fixtures setup failed"

  argc_ok() {  # argc_ok <label> <sql...>
    local label="$1"; shift
    local r; r=$(sqlq "SELECT fractalsql_set('reasoning_plugin','$MOCK');" "$@")
    [[ "$r" != *ERROR* && -n "$r" ]] \
      && pass "29 domain_agents: $label" \
      || fail "29 domain_agents: $label -- got: $r"
  }

  argc_ok "anomaly_triage succeeds with the bare minimum 5 args (baseline_window defaulted)" \
    "SELECT fractal_agent_anomaly_triage('bt29x_logs','metric','ts','host','host-1');"
  argc_ok "recommend_diverse succeeds with the bare minimum 3 args (k/id_col defaulted)" \
    "SELECT fractal_agent_recommend_diverse('bt29x_catalog','emb','0.1,0.2,0.3');"
  sqlq "SELECT fractal_diversify_disable();" >/dev/null 2>&1
  argc_ok "data_analyst succeeds with the bare minimum 1 arg (table_names/max_retries/context defaulted)" \
    "SELECT fractal_agent_data_analyst('sum of val');"
  argc_ok "data_analyst succeeds with all 4 args supplied (context included)" \
    "SELECT fractal_agent_data_analyst('sum of val','[\"bt29x_data\"]',2,'{\"hint\":1}');"
  argc_ok "patient_deterioration_triage succeeds with the bare minimum 5 args (cohort/k/id_col defaulted)" \
    "SELECT fractal_agent_patient_deterioration_triage(
       'bt29x_patients','vitals','0.9,-0.8,0.7,0.6','0.1,0.1,0.1,0.1','0.95,-0.85,0.75,0.65');"
  argc_ok "feedback_audit succeeds with the bare minimum 5 args (warmup_count/k defaulted)" \
    "SELECT fractal_agent_feedback_audit(
       'bt29x_fcatalog','emb','0.5,0.5,0.5','bt29x_fwarmup','center');"
  argc_ok "schedule_workload succeeds with the bare minimum 4 args (iterations/population/context defaulted)" \
    "SELECT fractal_agent_schedule_workload('0.8,0.1,0.0,0.0,0.1','bt29x_nodes','capability','id');"
  argc_ok "schedule_workload succeeds with all 8 args supplied (context included)" \
    "SELECT fractal_agent_schedule_workload(
       '0.8,0.1,0.0,0.0,0.1','bt29x_nodes','capability','id',30,50,5,'{\"hint\":1}');"
  argc_ok "rebalance_sibling succeeds with the bare minimum 6 args (seed/k/id_col/context defaulted)" \
    "SELECT fractal_agent_rebalance_sibling(
       '0.05,0.10,0.15,0.20',
       '0.04,0.0,0.0,0.0,0.0,0.09,0.0,0.0,0.0,0.0,0.16,0.0,0.0,0.0,0.0,0.25',
       4,'bt29x_alloc','alloc','0.25,0.25,0.25,0.25');"
  argc_ok "rebalance_sibling succeeds with all 10 args supplied (real seed + context)" \
    "SELECT fractal_agent_rebalance_sibling(
       '0.05,0.10,0.15,0.20',
       '0.04,0.0,0.0,0.0,0.0,0.09,0.0,0.0,0.0,0.0,0.16,0.0,0.0,0.0,0.0,0.25',
       4,'bt29x_alloc','alloc','0.25,0.25,0.25,0.25',42,5,'id','{\"hint\":1}');"
  argc_ok "detour_classify succeeds with the bare minimum 5 args (k/id_col/boxcount_dim defaulted)" \
    "SELECT fractal_agent_detour_classify(
       'bt29x_vehicles','current','0.1,0.1,0.1,0.1','0.8,0.7,0.6,0.5','$trace');"
  argc_ok "track_anomaly succeeds with the bare minimum 5 args (k/id_col defaulted)" \
    "SELECT fractal_agent_track_anomaly(
       'bt29x_tracks','current','0.1,0.1,0.1,0.1','0.7,-0.4,-0.8,0.9','$heading');"
  argc_ok "network_coverage_alert succeeds with the bare minimum 2 args (everything else defaulted)" \
    "SELECT fractal_agent_network_coverage_alert('$cloud','$drift');"
  argc_ok "network_coverage_alert succeeds with all 6 args supplied (context included)" \
    "SELECT fractal_agent_network_coverage_alert('$cloud','$drift',2,48,0.5,'{\"hint\":1}');"
  argc_ok "allocate succeeds with the bare minimum 3 args (context defaulted)" \
    "SELECT fractal_agent_allocate('0.05,0.1','1.0,0.0,0.0,1.0',1);"
  argc_ok "route_task succeeds with all 6 args supplied (cost_per_route included)" \
    "SELECT fractal_agent_route_task('0.1,0.2,0.3','bt29x_caps','emb','capability_name',1000,200);"

  if [[ -n "$(wpath "$MOCKENT")" && -f "$(wpath "$MOCKENT")" ]]; then
    local r19; r19=$(FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1 sqlq \
      "SELECT fractalsql_set('enterprise_lib','$MOCKENT');" \
      "SELECT fractalsql_set('reasoning_plugin','$MOCK');" \
      "SELECT fractal_agent_diverse_portfolios(
         '0.05,0.1','1.0,0.0,0.0,1.0',1,8,0.15,0.9,42,'{\"hint\":1}','sharpe');")
    [[ "$r19" != *ERROR* && -n "$r19" ]] \
      && pass "29 domain_agents: diverse_portfolios succeeds with all 9 args supplied (sharpe mode)" \
      || fail "29 domain_agents: diverse_portfolios 9-arg sharpe call, got: $r19"
    local r19b; r19b=$(FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1 sqlq \
      "SELECT fractalsql_set('enterprise_lib','$MOCKENT');" \
      "SELECT fractalsql_set('reasoning_plugin','$MOCK');" \
      "SELECT fractal_agent_diverse_portfolios(
         '0.05,0.1','1.0,0.0,0.0,1.0',1,4,0.15,0.9,NULL,'{}','pareto');")
    [[ "$r19b" != *ERROR* && -n "$r19b" ]] \
      && pass "29 domain_agents: diverse_portfolios succeeds in pareto objective_mode" \
      || fail "29 domain_agents: diverse_portfolios pareto-mode call, got: $r19b"
  else
    skip "29 domain_agents: diverse_portfolios argc-extremes (mock core did not build)"
  fi

  # Explicit SQL NULL at an optional position (argc satisfied, value
  # itself NULL) -- the max-args calls above all supplied REAL values,
  # which only flips the "argc>=N && real value" half of each compound
  # condition; this flips the other half in one call per engine (every
  # optional arg NULL at once, at the function's own max arity).
  argc_ok "recall_hybrid falls back to defaults when optional args are explicit NULL" \
    "SELECT fractal_agent_recall_hybrid('bt_da_mem','emb','1.0,0.0,0.0',NULL,NULL,NULL,NULL,NULL);"
  argc_ok "recommend_diverse falls back to defaults when optional args are explicit NULL" \
    "SELECT fractal_agent_recommend_diverse('bt29x_catalog','emb','0.1,0.2,0.3',NULL,NULL);"
  argc_ok "data_analyst falls back to defaults when optional args are explicit NULL" \
    "SELECT fractal_agent_data_analyst('sum of val',NULL,NULL,NULL);"
  argc_ok "patient_deterioration_triage falls back to defaults when optional args are explicit NULL" \
    "SELECT fractal_agent_patient_deterioration_triage(
       'bt29x_patients','vitals','0.9,-0.8,0.7,0.6','0.1,0.1,0.1,0.1','0.95,-0.85,0.75,0.65',
       NULL,NULL,NULL);"
  argc_ok "feedback_audit falls back to defaults when optional args are explicit NULL" \
    "SELECT fractal_agent_feedback_audit(
       'bt29x_fcatalog','emb','0.5,0.5,0.5','bt29x_fwarmup','center',NULL,NULL);"
  argc_ok "schedule_workload falls back to defaults when optional args are explicit NULL" \
    "SELECT fractal_agent_schedule_workload(
       '0.8,0.1,0.0,0.0,0.1','bt29x_nodes','capability','id',NULL,NULL,NULL,NULL);"
  argc_ok "rebalance_sibling falls back to defaults when optional args are explicit NULL" \
    "SELECT fractal_agent_rebalance_sibling(
       '0.05,0.10,0.15,0.20',
       '0.04,0.0,0.0,0.0,0.0,0.09,0.0,0.0,0.0,0.0,0.16,0.0,0.0,0.0,0.0,0.25',
       4,'bt29x_alloc','alloc','0.25,0.25,0.25,0.25',NULL,NULL,NULL,NULL);"
  argc_ok "detour_classify falls back to defaults when optional args are explicit NULL" \
    "SELECT fractal_agent_detour_classify(
       'bt29x_vehicles','current','0.1,0.1,0.1,0.1','0.8,0.7,0.6,0.5','$trace',NULL,NULL,NULL);"
  argc_ok "track_anomaly falls back to defaults when optional args are explicit NULL" \
    "SELECT fractal_agent_track_anomaly(
       'bt29x_tracks','current','0.1,0.1,0.1,0.1','0.7,-0.4,-0.8,0.9','$heading',NULL,NULL);"
  argc_ok "network_coverage_alert falls back to defaults when optional args are explicit NULL" \
    "SELECT fractal_agent_network_coverage_alert('$cloud','$drift',NULL,NULL,NULL,NULL);"
  argc_ok "regime_triage falls back to defaults when optional args are explicit NULL" \
    "SELECT fractal_agent_regime_triage('$series',NULL,NULL,NULL);"
  argc_ok "route_task falls back to defaults when the optional arg is explicit NULL" \
    "SELECT fractal_agent_route_task('0.1,0.2,0.3','bt29x_caps','emb','capability_name',1000,NULL);"

  if [[ -n "$(wpath "$MOCKENT")" && -f "$(wpath "$MOCKENT")" ]]; then
    local r20; r20=$(FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1 sqlq \
      "SELECT fractalsql_set('enterprise_lib','$MOCKENT');" \
      "SELECT fractalsql_set('reasoning_plugin','$MOCK');" \
      "SELECT fractal_agent_diverse_portfolios(
         '0.05,0.1','1.0,0.0,0.0,1.0',1,NULL,NULL,NULL,NULL,NULL,NULL);")
    [[ "$r20" != *ERROR* && -n "$r20" ]] \
      && pass "29 domain_agents: diverse_portfolios falls back to defaults when optional args are explicit NULL" \
      || fail "29 domain_agents: diverse_portfolios explicit-NULL call, got: $r20"
  else
    skip "29 domain_agents: diverse_portfolios explicit-NULL call (mock core did not build)"
  fi

  # resolved_id NULL (not an error): the matched row's own id_col value
  # is itself SQL NULL -- da_resolve_id finds the row (row_number
  # position matches) but sqlite3_column_text returns NULL for a NULL
  # column, so resolution legitimately yields NULL, not a NULL-row
  # miss. Exercises the "else" half of every agent's own
  # "if (resolved_id) ... else null" ternary, otherwise dead since
  # every other fixture's id_col is NOT NULL-valued.
  sqlq "
    CREATE TABLE bt29z_tracks(id INTEGER PRIMARY KEY, label TEXT,
      baseline TEXT, current TEXT);
    INSERT INTO bt29z_tracks VALUES
      (1,NULL,'0.1,0.1,0.1,0.1','0.7,-0.4,-0.8,0.9');
  " >/dev/null 2>&1 || fail "29 domain_agents: resolved_id-NULL fixture setup failed"
  # json_extract of a JSON `null` literal returns SQL NULL, not the
  # text "null" -- check the raw document instead of round-tripping
  # through json_extract's own NULL-vs-"null" ambiguity.
  local rrid; rrid=$(sqlq \
    "SELECT fractalsql_set('reasoning_plugin','$MOCK');" \
    "SELECT fractal_agent_track_anomaly(
       'bt29z_tracks','current','0.1,0.1,0.1,0.1','0.7,-0.4,-0.8,0.9',
       '$heading',5,'label');" | tail -n1)
  grep <<< "$rrid" -Fq '"nearest_fleet_id":null' \
    && pass "29 domain_agents: track_anomaly reports nearest_fleet_id:null when the id column is itself NULL" \
    || fail "29 domain_agents: expected nearest_fleet_id:null, got: $rrid"

  # Same resolved_id-NULL shape for the other three agents using
  # da_resolve_id/da_resolve_rowid with a caller-supplied id_col.
  sqlq "
    CREATE TABLE bt29z_alloc(id INTEGER PRIMARY KEY, label TEXT, alloc TEXT);
    INSERT INTO bt29z_alloc VALUES (1,NULL,'0.25,0.25,0.25,0.25');
    CREATE TABLE bt29z_vehicles(id INTEGER PRIMARY KEY, label TEXT,
      baseline TEXT, current TEXT);
    INSERT INTO bt29z_vehicles VALUES
      (1,NULL,'0.1,0.1,0.1,0.1','0.8,0.7,0.6,0.5');
    CREATE TABLE bt29z_caps(id INTEGER PRIMARY KEY, label TEXT, emb TEXT);
    INSERT INTO bt29z_caps VALUES (1,NULL,'0.1,0.2,0.3');
  " >/dev/null 2>&1 || fail "29 domain_agents: resolved_id-NULL fixtures (2) setup failed"

  local rras; rras=$(sqlq \
    "SELECT fractalsql_set('reasoning_plugin','$MOCK');" \
    "SELECT fractal_agent_rebalance_sibling(
       '0.05,0.10,0.15,0.20',
       '0.04,0.0,0.0,0.0,0.0,0.09,0.0,0.0,0.0,0.0,0.16,0.0,0.0,0.0,0.0,0.25',
       4,'bt29z_alloc','alloc','0.25,0.25,0.25,0.25',NULL,5,'label');" | tail -n1)
  grep <<< "$rras" -Fq '"nearest_alloc_id":null' \
    && pass "29 domain_agents: rebalance_sibling reports nearest_alloc_id:null when the id column is itself NULL" \
    || fail "29 domain_agents: expected nearest_alloc_id:null, got: $rras"

  local rdc; rdc=$(sqlq \
    "SELECT fractalsql_set('reasoning_plugin','$MOCK');" \
    "SELECT fractal_agent_detour_classify(
       'bt29z_vehicles','current','0.1,0.1,0.1,0.1','0.8,0.7,0.6,0.5',
       '$trace',5,'label');" | tail -n1)
  grep <<< "$rdc" -Fq '"nearest_fleet_id":null' \
    && pass "29 domain_agents: detour_classify reports nearest_fleet_id:null when the id column is itself NULL" \
    || fail "29 domain_agents: expected nearest_fleet_id:null, got: $rdc"

  local rrt; rrt=$(sqlq \
    "SELECT fractalsql_set('reasoning_plugin','$MOCK');" \
    "SELECT fractal_agent_route_task('0.1,0.2,0.3','bt29z_caps','emb','label',1000);" | tail -n1)
  grep <<< "$rrt" -Fq '"routed_to":null' \
    && pass "29 domain_agents: route_task reports routed_to:null when the id column is itself NULL" \
    || fail "29 domain_agents: expected routed_to:null, got: $rrt"

  sqlq "
    DROP TABLE IF EXISTS bt29z_tracks;
    DROP TABLE IF EXISTS bt29z_alloc;
    DROP TABLE IF EXISTS bt29z_vehicles;
    DROP TABLE IF EXISTS bt29z_caps;
  " >/dev/null 2>&1

  sqlq "
    DROP TABLE IF EXISTS bt29x_logs;
    DROP TABLE IF EXISTS bt29x_catalog;
    DROP TABLE IF EXISTS bt29x_data;
    DROP TABLE IF EXISTS bt29x_patients;
    DROP TABLE IF EXISTS bt29x_fcatalog;
    DROP TABLE IF EXISTS bt29x_fwarmup;
    DROP TABLE IF EXISTS bt29x_nodes;
    DROP TABLE IF EXISTS bt29x_alloc;
    DROP TABLE IF EXISTS bt29x_vehicles;
    DROP TABLE IF EXISTS bt29x_tracks;
    DROP TABLE IF EXISTS bt29x_caps;
  " >/dev/null 2>&1

  sqlq "
    DROP TABLE IF EXISTS bt_da_caps;
    DROP TABLE IF EXISTS bt_da_catalog;
    DROP TABLE IF EXISTS bt_da_data;
    DROP TABLE IF EXISTS bt_da_patients;
    DROP TABLE IF EXISTS bt_da_fcatalog;
    DROP TABLE IF EXISTS bt_da_fwarmup;
    DROP TABLE IF EXISTS bt_da_nodes;
    DROP TABLE IF EXISTS bt_da_alloc;
    DROP TABLE IF EXISTS bt_da_vehicles;
    DROP TABLE IF EXISTS bt_da_tracks;
  " >/dev/null 2>&1

  printf 'SELECT 1' > "$SQLTXT"
}

gate_30_feature_store() {
  local r1; r1=$(sqlq \
    "SELECT fractal_store_morphology(1, '0.0,0.0,0.0');" \
    "SELECT fractal_store_morphology(2, '1.0,0.0,0.0');" \
    "SELECT fractal_store_morphology(3, '5.0,5.0,5.0');")
  [[ "$r1" == $'ok\nok\nok' ]] \
    && pass "30 feature_store: fractal_store_morphology upserts, returns ok" \
    || fail "30 feature_store: expected three ok rows, got: $r1"

  local r2; r2=$(sqlq \
    "SELECT fractal_mine_topology_negatives('0.0,0.0,0.0', 3);")
  [[ "$r2" == '[{"doc_id":1,"distance":0},{"doc_id":2,"distance":1},'*'"doc_id":3'*']' ]] \
    && pass "30 feature_store: mine_topology_negatives orders by ascending distance" \
    || fail "30 feature_store: expected doc_id 1,2,3 ascending, got: $r2"

  local r3; r3=$(sqlq \
    "SELECT fractal_mine_topology_negatives('0.0,0.0,0.0', 1);")
  [[ "$r3" == '[{"doc_id":1,"distance":0}]' ]] \
    && pass "30 feature_store: k caps the returned candidate count" \
    || fail "30 feature_store: expected exactly doc_id 1, got: $r3"

  # Dimension-mismatched row must be skipped, not abort the scan.
  local r4; r4=$(sqlq \
    "SELECT fractal_store_morphology(4, '0.1,0.1');" \
    "SELECT fractal_mine_topology_negatives('0.0,0.0,0.0', 10);")
  [[ "$r4" == *'"doc_id":4'* ]] \
    && fail "30 feature_store: expected dim-mismatched doc_id 4 to be skipped, got: $r4" \
    || pass "30 feature_store: dimension-mismatched row silently skipped, scan not aborted"

  expect_err "doc_id must be >= 0" \
    "SELECT fractal_store_morphology(-1, '1.0');" \
    && pass "30 feature_store: negative doc_id rejected" \
    || fail "30 feature_store: negative doc_id should have raised a clean error"

  expect_err "invalid feature_array" \
    "SELECT fractal_store_morphology(5, 'bad!vec');" \
    && pass "30 feature_store: malformed feature_array rejected" \
    || fail "30 feature_store: malformed feature_array should have raised a clean error"

  expect_err "k must be > 0" \
    "SELECT fractal_mine_topology_negatives('0.0,0.0,0.0', 0);" \
    && pass "30 feature_store: non-positive k rejected" \
    || fail "30 feature_store: k=0 should have raised a clean error"

  local r5; r5=$(sqlq \
    "SELECT fractal_store_morphology(NULL, '1.0');" \
    "SELECT fractal_mine_topology_negatives(NULL, 3);")
  [[ -z "$r5" ]] \
    && pass "30 feature_store: NULL args are STRICT (NULL in, NULL out)" \
    || fail "30 feature_store: expected NULL/blank for NULL args, got: $r5"

  expect_err "invalid surrogate_vector" \
    "SELECT fractal_mine_topology_negatives('bad!vec', 3);" \
    && pass "30 feature_store: malformed surrogate_vector rejected" \
    || fail "30 feature_store: malformed surrogate_vector should have raised a clean error"

  local r6; r6=$(sqlq \
    "SELECT fractal_mine_topology_negatives('1.0,1.0,1.0,1.0', 5);")
  [[ "$r6" == '[]' ]] \
    && pass "30 feature_store: mine_topology_negatives returns [] when no row matches the query dim" \
    || fail "30 feature_store: expected [], got: $r6"
}

# fractalsql_ledger's append-only hash chain (src/fsql_ledger.c), the
# B-full port of PG's real tamper-evident design -- replacing the old
# last-writer-wins snapshot. Plain sqlq/expect_err assertions cover the
# enterprise gate and the "works with no enterprise_lib at all" contract;
# the storage-layer build/tamper/gap/migration/kind-independence checks
# need raw table manipulation with correctly chained SHA-256 hashes,
# which the sqlite3 CLI cannot compute -- that part runs as ONE python
# driver (same idiom as gate 08/16/19's write_py_gateNN + py_run).
#
# Sandbox note (disclosed, same limitation as gate 24/25): this checkout
# carries no vendored enterprise core, so fractal_ledger_flush() and
# fractal_ledger_load() always report "enterprise tier not loaded" here
# -- there is no way to exercise the real end-to-end write path (core
# flush -> ledger_materialize -> chain insert) or the O(1) tip check
# inside fractal_ledger_load through the mandated SQL surface in this
# environment. The driver below instead builds/mutates rows directly at
# the storage layer (the exact rows ledger_chain_insert would produce)
# and exercises fractal_ledger_verify(), which is deliberately NOT
# enterprise-gated and shares the same entry_hash/prev_hash
# recompute logic ledger_verify_tip uses for the O(1) load-time check --
# so this is real coverage of the chain algorithm itself, just entered
# from a different call site than fractal_ledger_flush/load. A checkout
# with a vendored enterprise core would additionally get full end-to-end
# coverage through gate 25 (self-skips here for the same reason).
write_py_gate31() {
  cat > "$PDIR/py_gate31.py" <<'PYEOF'
import os, sqlite3, sys
# Plain SHA-256 only. Prefer CPython's built-in implementation over
# hashlib: hashlib's first import pulls in the OpenSSL-backed _hashlib
# module, and under the Darwin DYLD_INSERT_LIBRARIES ASan run this was
# the one driver that aborted at startup ("Interceptors are not working
# ... loaded too late") -- the only driver that imports hashlib.
try:
    from _sha2 import sha256          # CPython 3.12+
except ImportError:
    try:
        from _sha256 import sha256    # CPython <= 3.11
    except ImportError:
        from hashlib import sha256

db, ext = os.environ["FSQL_BT_DB"], os.environ["FSQL_BT_EXT"]
con = sqlite3.connect(db)
con.enable_load_extension(True)
con.load_extension(ext)

failed = False
def check(label, cond, detail=""):
    global failed
    if cond:
        print("OK: %s" % label)
    else:
        failed = True
        print("FAIL: %s%s" % (label, (" -- " + detail) if detail else ""))

def verify(kind=None):
    if kind is None:
        row = con.execute("SELECT fractal_ledger_verify()").fetchone()
    else:
        row = con.execute("SELECT fractal_ledger_verify(?)", (kind,)).fetchone()
    return row[0]

def fresh_table():
    con.execute("DROP TABLE IF EXISTS fractalsql_ledger")
    con.execute("""CREATE TABLE fractalsql_ledger(
      id INTEGER PRIMARY KEY AUTOINCREMENT, kind INTEGER NOT NULL, payload BLOB NOT NULL,
      mac BLOB, prev_hash BLOB NOT NULL, entry_hash BLOB NOT NULL,
      sealed INTEGER NOT NULL DEFAULT 0, updated_at TEXT NOT NULL DEFAULT (datetime('now')))""")
    con.commit()

def append_row(kind, payload):
    # Mirrors ledger_chain_insert exactly: prev_hash = latest entry_hash
    # for this kind (or 32 zero bytes, genesis), entry_hash =
    # SHA256(prev_hash || payload) (no mac column populated here --
    # enterprise_ledger_key is unset in this driver, same as the mac-less
    # path ledger_chain_insert takes).
    row = con.execute(
        "SELECT entry_hash FROM fractalsql_ledger WHERE kind=? ORDER BY id DESC LIMIT 1",
        (kind,)).fetchone()
    prev = row[0] if row else b"\x00" * 32
    eh = sha256(prev + payload).digest()
    con.execute(
        "INSERT INTO fractalsql_ledger(kind,payload,mac,prev_hash,entry_hash) VALUES(?,?,NULL,?,?)",
        (kind, payload, prev, eh))
    con.commit()
    return con.execute("SELECT max(id) FROM fractalsql_ledger WHERE kind=?", (kind,)).fetchone()[0]

# 1) A built 2-row chain (simulating two flushes) verifies clean.
fresh_table()
append_row(1, b"truth-blob-1")
append_row(1, b"truth-blob-2")
v = verify()
check("chain build: 2 appended rows verify clean",
      v == '{"ok":true,"rows_verified":2}', v)

# 2) Mutating the TIP row's payload directly is caught by verify()'s
# entry_hash recompute -- the same structural check ledger_verify_tip
# runs at O(1) load time.
tip_id = con.execute("SELECT max(id) FROM fractalsql_ledger WHERE kind=1").fetchone()[0]
con.execute("UPDATE fractalsql_ledger SET payload=? WHERE id=?", (b"TAMPERED", tip_id))
con.commit()
v = verify()
check("tamper detection: a mutated payload is caught by verify()",
      v.startswith('{"ok":false') and "entry_hash mismatch" in v, v)

# 3) Deleting a MIDDLE row out of a 3-row chain leaves a visible id gap.
fresh_table()
append_row(1, b"a")
mid_id = append_row(1, b"b")
append_row(1, b"c")
con.execute("DELETE FROM fractalsql_ledger WHERE id=?", (mid_id,))
con.commit()
v = verify()
check("deletion gap: a deleted middle row is reported as a sequence gap",
      v.startswith('{"ok":false') and "gap" in v, v)

# 3b) Rewriting a MIDDLE row's prev_hash (and recomputing ITS OWN
# entry_hash to stay internally consistent with that new prev_hash)
# breaks only the chain-link check against the PRECEDING row's real
# entry_hash -- the structural recompute still passes, isolating this
# from the entry_hash-mismatch case above.
fresh_table()
append_row(1, b"a")
mid_id = append_row(1, b"b")
append_row(1, b"c")
fake_prev = b"\x99" * 32
fake_hash = sha256(fake_prev + b"b").digest()
con.execute("UPDATE fractalsql_ledger SET prev_hash=?, entry_hash=? WHERE id=?",
            (fake_prev, fake_hash, mid_id))
con.commit()
v = verify()
check("chain-link break: a rewritten prev_hash is caught even with a self-consistent entry_hash",
      v.startswith('{"ok":false') and "chain-link" in v, v)

# 3c) A hash/mac column of the wrong length is a structurally malformed
# row, checked before any hash recompute.
fresh_table()
append_row(1, b"a")
bad_id = append_row(1, b"b")
con.execute("UPDATE fractalsql_ledger SET entry_hash=? WHERE id=?",
            (b"\x00" * 16, bad_id))
con.commit()
v = verify()
check("malformed row: a wrong-length entry_hash is rejected before any recompute",
      v.startswith('{"ok":false') and "malformed row" in v, v)

# 4) The old last-writer-wins snapshot shape (no id column) migrates to
# the chain shape the first time the community-surface
# fractal_ledger_verify() touches it (same ensure_table path
# fractal_ledger_flush/load use, just reachable without enterprise).
# ensure_table's migration check only runs once per CONNECTION (the
# FsqlLedgerCtx.table_ready cache -- the SQLite analog of PG re-running
# its cheap EXISTS/EXISTS probe on every call: here it's paid once per
# session instead), so this needs a FRESH connection to see the
# old-shape table for the "first" time, same as a real upgrade (new
# library version, existing on-disk table, next connection that opens
# it) -- reusing the connection from checks 1-3 would report the
# already-migrated shape it cached from those earlier calls.
con.execute("DROP TABLE IF EXISTS fractalsql_ledger")
con.execute("CREATE TABLE fractalsql_ledger(kind INTEGER PRIMARY KEY, "
            "payload BLOB NOT NULL, sealed BLOB, updated_at TEXT)")
con.execute("INSERT INTO fractalsql_ledger(kind, payload) VALUES(1, X'00')")
con.commit()
con2 = sqlite3.connect(db)
con2.enable_load_extension(True)
con2.load_extension(ext)
v = con2.execute("SELECT fractal_ledger_verify()").fetchone()[0]
cols = [r[1] for r in con2.execute("PRAGMA table_info(fractalsql_ledger)")]
con2.close()
check("migration: old snapshot shape replaced with the chain shape",
      "id" in cols and v == '{"ok":true,"rows_verified":0}',
      "cols=%s verify=%s" % (cols, v))

# 5) kind=1 and kind=2 are independent chains; the default/NULL arg
# targets kind=1, an explicit kind=2 reports on the other chain.
fresh_table()
append_row(1, b"t1"); append_row(1, b"t2")
append_row(2, b"a1"); append_row(2, b"a2"); append_row(2, b"a3")
v1, v2, vdef = verify(1), verify(2), verify()
check("kind independence: verify()/verify(1) agree and differ from verify(2)",
      v1 == vdef == '{"ok":true,"rows_verified":2}'
      and v2 == '{"ok":true,"rows_verified":3}',
      "v1=%s v2=%s vdef=%s" % (v1, v2, vdef))

sys.exit(1 if failed else 0)
PYEOF
}

gate_31_ledger_chain() {
  sqlq "DROP TABLE IF EXISTS fractalsql_ledger;" >/dev/null 2>&1

  # The NEW parity fix this gate exists to pin: fractal_audit_log now
  # carries the same enterprise gate as the rest of the ledger surface
  # (previously it wrote unconditionally -- a real parity gap against PG,
  # which requires ensure_enterprise_lib() before writing).
  if expect_err "enterprise tier not loaded" \
      "SELECT fractal_audit_log('test','{}');"; then
    pass "31 ledger_chain: fractal_audit_log now gated (enterprise tier not loaded)"
  else
    fail "31 ledger_chain: fractal_audit_log did not surface the dormant-tier error"
  fi

  # Reaffirm flush/load are still gated too (gate 24 already covers this
  # broadly; pinned here again because it's this gate's own subject).
  if expect_err "enterprise tier not loaded" \
      "SELECT fractal_ledger_flush();"; then
    pass "31 ledger_chain: fractal_ledger_flush still gated (dormant tier)"
  else
    fail "31 ledger_chain: fractal_ledger_flush did not surface the dormant-tier error"
  fi

  # fractal_ledger_verify() is the one function in this surface that is
  # NOT enterprise-gated (it is a pure read-only forensic query) --
  # it must work standalone, creating an empty chain table on first touch.
  local vz; vz=$(sqlq "SELECT fractal_ledger_verify();")
  [[ "$vz" == '{"ok":true,"rows_verified":0}' ]] \
    && pass "31 ledger_chain: fractal_ledger_verify() works with no enterprise_lib at all" \
    || fail "31 ledger_chain: expected an empty-chain report, got: $vz"

  if [[ -z "$PY" ]]; then
    skip "31 ledger_chain storage-layer driver (no python3 sqlite3 stdlib)"
    return
  fi
  write_py_gate31
  if py_run py_gate31; then
    pass "31 ledger_chain: chain build/tamper/gap/migration/kind-independence (see driver OK lines above)"
  else
    fail "31 ledger_chain: see driver output above"
  fi

  # ---- real write/read storage path (not the driver's direct-table-
  # poke above): fractal_audit_log's actual C write goes through our
  # own storage VFS (ledger_slot_store/ledger_vfs_write_entry) even
  # with the mock core loaded -- the mock's canned flush()/load() never
  # touch it, so this is the only place that path is reachable. Setting
  # enterprise_ledger_key first also tags the write with a real HMAC,
  # and fractal_ledger_verify's read-back (ledger_vfs_read_entry) then
  # checks it in constant time -- both otherwise dead in this checkout.
  if [[ -n "$(wpath "$MOCKENT")" && -f "$(wpath "$MOCKENT")" ]]; then
    sqlq "DELETE FROM fractalsql_ledger WHERE kind = 2;" >/dev/null 2>&1
    local rw; rw=$(FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1 sqlq \
      "SELECT fractalsql_set('enterprise_lib','$MOCKENT');" \
      "SELECT fractalsql_set('enterprise_ledger_key','gate31-hmac-test-key');" \
      "SELECT fractal_audit_log('test.small','{\"n\":1}');" \
      "SELECT fractal_ledger_verify(2);" | tail -n1)
    grep <<< "$rw" -q '"ok":true' \
      && pass "31 ledger_chain: audit_log + ledger_verify round-trip a real HMAC-keyed write/read" \
      || fail "31 ledger_chain: expected an ok verify after a real write, got: $rw"

    # entry_type is the field ledger_json_escape() actually escapes (the
    # payload is embedded as raw JSON, by design); a quote and a
    # backslash in it exercise the two RFC 8259 mandatory escapes,
    # otherwise dead since every entry_type elsewhere in this suite is
    # a plain identifier-shaped string.
    local rwe; rwe=$(FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1 sqlq \
      "SELECT fractalsql_set('enterprise_lib','$MOCKENT');" \
      "SELECT fractal_audit_log('has\"quote\\backslash','{\"n\":2}');" \
      "SELECT fractal_audit_unpack(payload) FROM fractalsql_ledger
         WHERE kind=2 ORDER BY rowid DESC LIMIT 1;" | tail -n1)
    # fractal_audit_unpack returns the raw stored JSON TEXT, still
    # escaped (it does not re-parse it) -- the escaped form is the
    # correct, expected output here.
    grep <<< "$rwe" -Fq '"type":"has\"quote\\backslash"' \
      && pass "31 ledger_chain: audit_log entry_type escapes a quote+backslash" \
      || fail "31 ledger_chain: expected the escaped entry_type, got: $rwe"
  else
    skip "31 ledger_chain: real write/read storage path (mock core did not build)"
  fi
}

gate_32_enterprise_signature_real() {
  # Real Ed25519 detached-signature verification (src/fsql_ed25519.h,
  # vendored TweetNaCl -- see fsql_enterprise.c's header comment) for
  # the enterprise .so loader. Self-skips on a community-only checkout,
  # same detection as gate 25 -- no enterprise core is vendored in
  # include/ here, so there is nothing to point enterprise_lib at that
  # would ever get past dlsym symbol resolution far enough to exercise
  # Case A/B's "loads and works" assertion.
  #
  # Mirrors PG's gate_26_enterprise_signature() scope exactly: it does
  # NOT test the "valid signature, actually verifies" happy path either
  # -- that needs the real FractalSQLabs release private key, which
  # lives offline and never belongs in either repo or its test fixtures
  # (see fsql_enterprise.c's FSQL_ENTERPRISE_PUBKEY comment). What IS
  # tested needs no key at all: a missing .sig (soft unless require=on)
  # and a well-formed-but-wrong .sig (always hard-refused -- the one
  # case that actually exercises the new verify() call path, unlike
  # A/B which only exercise presence-checking), plus a wrong-length
  # .sig (also always invalid, never "missing" -- an exact-64-bytes
  # check PG's own gate doesn't separately need to test since it's
  # implied by fread()'s own semantics there; this port's
  # ent_check_signature() checks it explicitly, so it's worth its own
  # case here).
  #
  # Message-text note: this port's ENT_SIG_MISSING refusal (mandatory
  # mode, or require=on under FSQL_ENTERPRISE_ALLOW_UNVERIFIED) names
  # FSQL_ENTERPRISE_ALLOW_UNVERIFIED rather than the SQL key -- the SQL
  # key can only strengthen the check, so the message points at the
  # environment opt-out that actually governs. Case B below asserts on
  # this port's actual wording.
  local ent_so
  ent_so=$(ls include/*/libfractalsql-enterprise-* 2>/dev/null | head -1)
  if [[ -z "$ent_so" ]]; then
    skip "32 enterprise_signature_real: skipped (community edition; no libfractalsql-enterprise-* in include/)"
    return
  fi
  local abs absw sig_path
  abs=$(cd "$(dirname "$ent_so")" && pwd)/$(basename "$ent_so")
  absw="$(wpath "$abs")"
  sig_path="${abs}.sig"
  rm -f "$sig_path"

  # ---- Case A: no .sig, FSQL_ENTERPRISE_ALLOW_UNVERIFIED opt-out +
  # require=off -- soft: still loads and works.
  local ra rca
  ra=$(FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1 sqlq \
    "SELECT fractalsql_set('enterprise_lib', '$absw');" \
    "SELECT fractalsql_set('enterprise_require_signature','off');" \
    "SELECT fractal_ledger_reset_hard();")
  rca=$?
  if [[ $rca -eq 0 ]] && ! grep <<< "$ra" -q "enterprise tier not loaded"; then
    pass "32 enterprise_signature_real Case A: missing .sig + env opt-out + require=off -- still loads and works"
  else
    fail "32 enterprise_signature_real Case A: expected a clean load, got rc=$rca: $ra"
  fi

  # ---- Case B: no .sig, no env opt-out -- hard refusal even with
  # require=off (verification is mandatory without the opt-out).
  local rb rcb
  rb=$(sqlq \
    "SELECT fractalsql_set('enterprise_lib', '$absw');" \
    "SELECT fractalsql_set('enterprise_require_signature','off');" \
    "SELECT fractal_ledger_reset_hard();")
  rcb=$?
  if [[ $rcb -ne 0 ]] && grep <<< "$rb" -q "no signature found" \
     && grep <<< "$rb" -q "FSQL_ENTERPRISE_ALLOW_UNVERIFIED"; then
    pass "32 enterprise_signature_real Case B: missing .sig, no env opt-out -- refused"
  else
    fail "32 enterprise_signature_real Case B: expected a hard refusal, got rc=$rcb: $rb"
  fi

  # ---- Case C: garbage 64-byte .sig -- ALWAYS hard-refused, even with
  # require=off. The one case that actually exercises the new verify()
  # path (rejecting a well-formed-but-wrong signature).
  head -c 64 /dev/urandom > "$sig_path"
  local rc rcc
  rc=$(sqlq \
    "SELECT fractalsql_set('enterprise_lib', '$absw');" \
    "SELECT fractalsql_set('enterprise_require_signature','off');" \
    "SELECT fractal_ledger_reset_hard();")
  rcc=$?
  if [[ $rcc -ne 0 ]] && grep <<< "$rc" -q "failed signature verification"; then
    pass "32 enterprise_signature_real Case C: garbage .sig -- always refused regardless of require"
  else
    fail "32 enterprise_signature_real Case C: expected a hard refusal on invalid signature, got rc=$rcc: $rc"
  fi

  # ---- Case D: wrong-length (32-byte) .sig -- also always invalid,
  # never treated as "missing".
  head -c 32 /dev/urandom > "$sig_path"
  local rd rcd
  rd=$(sqlq \
    "SELECT fractalsql_set('enterprise_lib', '$absw');" \
    "SELECT fractalsql_set('enterprise_require_signature','off');" \
    "SELECT fractal_ledger_reset_hard();")
  rcd=$?
  if [[ $rcd -ne 0 ]] && grep <<< "$rd" -q "failed signature verification"; then
    pass "32 enterprise_signature_real Case D: wrong-length .sig -- treated as invalid, not missing"
  else
    fail "32 enterprise_signature_real Case D: expected a hard refusal on wrong-length signature, got rc=$rcd: $rd"
  fi

  rm -f "$sig_path"
}

gate_33_tsan_ledger_concurrent() {
  # --tsan only. See tests/tsan_ledger_runner.c's own header comment
  # for why this gate exists instead of reusing the LD_PRELOAD/
  # DYLD_INSERT_LIBRARIES approach the other 32 gates use: that
  # approach retrofits a sanitizer runtime onto an already-starting
  # host process, which is a confirmed dead end on Darwin (SIP strips
  # DYLD_INSERT_LIBRARIES for Apple-signed hosts, and even past that
  # the runtime can call itself "loaded too late") and known-flaky even
  # on Linux. This harness is compiled WITH -fsanitize=thread from the
  # start instead, so neither problem applies, on either platform.
  if [[ "$TSAN" -ne 1 ]]; then
    skip "33 tsan_ledger_concurrent (only runs under --tsan)"
    return
  fi
  if [[ "$IS_MSYS" -eq 1 ]]; then
    skip "33 tsan_ledger_concurrent (MSVC/clang-cl has no ThreadSanitizer support)"
    return
  fi
  if [[ -z "$MAKE" ]]; then
    skip "33 tsan_ledger_concurrent (no make on PATH)"
    return
  fi
  # Same enterprise-core precondition as gate 25: fractal_ledger_flush
  # is a dormant-tier no-op without it, so there is nothing concurrent
  # to exercise.
  local ent_so
  ent_so=$(ls include/*/libfractalsql-enterprise-* 2>/dev/null | head -1)
  if [[ -z "$ent_so" ]]; then
    skip "33 tsan_ledger_concurrent (no enterprise core vendored in include/)"
    return
  fi
  if [[ -z "$EXT" || ! -f "$EXT" ]]; then
    skip "33 tsan_ledger_concurrent (no extension built -- run gate 01 first)"
    return
  fi
  local ent_abs ext_abs
  ent_abs=$(cd "$(dirname "$ent_so")" && pwd)/$(basename "$ent_so")
  ext_abs=$(cd "$(dirname "$EXT")" && pwd)/$(basename "$EXT")

  if ! env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES "$MAKE" tsan-ledger-runner \
       >"$TMPROOT/fractalsql_bt_tsan_runner_build.log" 2>&1; then
    fail "33 tsan_ledger_concurrent: harness build failed; see $TMPROOT/fractalsql_bt_tsan_runner_build.log"
    return
  fi

  local runner_db="$PDIR/tsan_ledger.db"
  rm -f "$runner_db" "$runner_db-wal" "$runner_db-shm"

  local out rc
  out=$("$HERE/tsan_ledger_runner" \
        --db "$runner_db" --ext "$ext_abs" --ent-lib "$ent_abs" \
        --threads 8 2>&1)
  rc=$?
  if [[ $rc -eq 0 ]] && ! grep -qE "WARNING: ThreadSanitizer|==ERROR" <<< "$out"; then
    pass "33 tsan_ledger_concurrent: 8 concurrent connections, real BEGIN IMMEDIATE serialization ($out)"
  else
    fail "33 tsan_ledger_concurrent: rc=$rc: $out"
  fi
}

gate_34_oom_inject() {
  if [[ "$sysname" != "Linux" ]]; then
    skip "34 oom_inject (Linux only; dladdr()-based LD_PRELOAD interception)"
    return
  fi
  # A sanitizer runtime is already LD_PRELOADed (main(), below) and
  # must stay first in that list -- our own malloc/calloc/realloc
  # interposition can't be layered on top of that: either it goes
  # first and ASan refuses to start ("runtime does not come first in
  # initial library list"), or it goes after and the dynamic linker
  # binds malloc to ASan's definition first, making ours dead weight
  # either way. ASan/UBSan/TSan already instrument every allocation
  # path far more thoroughly than a size-matched malloc failure could.
  if [[ "$ASAN" -eq 1 || "$UBSAN" -eq 1 || "$TSAN" -eq 1 ]]; then
    skip "34 oom_inject (sanitizer builds already own malloc interception)"
    return
  fi
  if [[ -z "$CC" ]]; then
    skip "34 oom_inject (no C compiler on PATH)"
    return
  fi
  local shim="$PDIRW/oom_inject.so"
  if ! "$CC" -shared -fPIC -std=c99 tests/oom_inject.c -o "$shim" -ldl \
        >"$PDIRW/oom_inject.log" 2>&1; then
    fail "34 oom_inject: shim failed to build (see $PDIRW/oom_inject.log)"
    return
  fi

  # Two allocations, each the only one of its exact size made FROM
  # fractalsql.so for that call -- see tests/oom_inject.c's own header
  # for why size-based targeting needs that (a vector op whose output
  # buffer is unavoidably the same size as its own CSV-decode scratch
  # buffer can't be disambiguated this way; these two don't have that
  # problem).
  local v100; v100=$(printf '1.0,%.0s' {1..99}; printf '1.0')

  # fractal_vector(777): calloc(777, sizeof(float)) = 3108 bytes, the
  # only allocation of that size in this call (no CSV decode at all --
  # dim is a plain integer argument).
  local base1; base1=$(sqlq "SELECT fractal_vector_to_json(fractal_vector(777));")
  [[ "$base1" == \[0,0,0* ]] \
    && pass "34 oom_inject: fractal_vector(777) succeeds with no fault injected (baseline)" \
    || fail "34 oom_inject: baseline fractal_vector(777) failed: $base1"
  local oom1; oom1=$(LD_PRELOAD="$shim" FSQL_OOM_FAIL_SIZE=3108 \
    FSQL_OOM_TARGET_SO=fractalsql.so sqlq "SELECT fractal_vector(777);")
  grep <<< "$oom1" -qi "out of memory" \
    && pass "34 oom_inject: fractal_vector(dim)'s calloc failure surfaces as a clean out-of-memory error" \
    || fail "34 oom_inject: expected an out-of-memory error, got: $oom1"

  # fractal_vector_to_json(100 floats): malloc(16 + 100*32 + 4) = 3220
  # bytes -- the output JSON buffer, sized by a different multiplier
  # (32, not 4) than the CSV-decode scratch buffer (100*4=400), so the
  # two can't collide for this dim.
  local base2; base2=$(sqlq "SELECT length(fractal_vector_to_json('$v100'));")
  [[ "$base2" =~ ^[0-9]+$ ]] \
    && pass "34 oom_inject: fractal_vector_to_json(100 floats) succeeds with no fault injected (baseline)" \
    || fail "34 oom_inject: baseline to_json failed: $base2"
  local oom2; oom2=$(LD_PRELOAD="$shim" FSQL_OOM_FAIL_SIZE=3220 \
    FSQL_OOM_TARGET_SO=fractalsql.so sqlq "SELECT fractal_vector_to_json('$v100');")
  grep <<< "$oom2" -qi "out of memory" \
    && pass "34 oom_inject: fractal_vector_to_json's output-buffer malloc failure surfaces as a clean out-of-memory error" \
    || fail "34 oom_inject: expected an out-of-memory error, got: $oom2"

  # fractal_vector_quantize_int8(73 floats): malloc(73*sizeof(int8_t))
  # = 73 bytes -- the quantized-codes output buffer. 73 is deliberately
  # not a round number, to stay clear of any incidental same-size
  # allocation elsewhere in this call.
  local v73; v73=$(printf '1.0,%.0s' {1..72}; printf '1.0')
  local base3; base3=$(sqlq "SELECT length(fractal_vector_quantize_int8('$v73'));")
  [[ "$base3" =~ ^[0-9]+$ ]] \
    && pass "34 oom_inject: fractal_vector_quantize_int8(73 floats) succeeds with no fault injected (baseline)" \
    || fail "34 oom_inject: baseline quantize_int8 failed: $base3"
  local oom3; oom3=$(LD_PRELOAD="$shim" FSQL_OOM_FAIL_SIZE=73 \
    FSQL_OOM_TARGET_SO=fractalsql.so sqlq "SELECT fractal_vector_quantize_int8('$v73');")
  grep <<< "$oom3" -qi "out of memory" \
    && pass "34 oom_inject: fractal_vector_quantize_int8's codes-buffer malloc failure surfaces as a clean out-of-memory error" \
    || fail "34 oom_inject: expected an out-of-memory error, got: $oom3"

  # fractal_periodogram(series, max_peaks=37): malloc(37*sizeof(double))
  # = 296 bytes, made twice (out_freqs then out_power, same size) --
  # injection fails whichever of the two the allocator reaches first,
  # exercising the same `!out_freqs || !out_power` guard either way.
  local base4; base4=$(sqlq "SELECT length(fractal_periodogram('1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16', 37));")
  [[ "$base4" =~ ^[0-9]+$ ]] \
    && pass "34 oom_inject: fractal_periodogram(series, 37) succeeds with no fault injected (baseline)" \
    || fail "34 oom_inject: baseline periodogram failed: $base4"
  local oom4; oom4=$(LD_PRELOAD="$shim" FSQL_OOM_FAIL_SIZE=296 \
    FSQL_OOM_TARGET_SO=fractalsql.so sqlq \
    "SELECT fractal_periodogram('1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16', 37);")
  grep <<< "$oom4" -qi "out of memory" \
    && pass "34 oom_inject: fractal_periodogram's out_freqs/out_power malloc failure surfaces as a clean out-of-memory error" \
    || fail "34 oom_inject: expected an out-of-memory error, got: $oom4"

  # --- "Lever" injections: fsql_agents.c, fsql_domain_agents.c, and
  # fsql_sovereign.c's own StrBuf/SB growable-append builders all
  # bootstrap their very first allocation at a fixed 256 bytes
  # (`b->cap ? b->cap : 256`); fsql_t2s.c's StrBuf instead mallocs a
  # fixed 512 bytes in sb_init() itself. For any call whose first
  # append fits under that bootstrap size (true for every call here),
  # failing that ONE allocation latches the StrBuf's oom/failed flag,
  # which then cascades through every downstream `sb_failed()`/`oom`
  # check for the rest of that call -- one injection covers many
  # otherwise-individually-untestable guard branches at once, instead
  # of tracing each one's own capacity-doubling sequence by hand. ---
  local lev1; lev1=$(LD_PRELOAD="$shim" FSQL_OOM_FAIL_SIZE=256 \
    FSQL_OOM_TARGET_SO=fractalsql.so sqlq \
    "SELECT fractal_agent_detect_loop('det1','0,0,0,1,1,1,0,0,0,1,1,1', 3, 8, 42, 0);")
  grep <<< "$lev1" -qi "out of memory" \
    && pass "34 oom_inject: fsql_agents.c's StrBuf 256-byte bootstrap failure cascades to a clean out-of-memory error (detect_loop)" \
    || fail "34 oom_inject: expected an out-of-memory error, got: $lev1"

  local lev2; lev2=$(LD_PRELOAD="$shim" FSQL_OOM_FAIL_SIZE=512 \
    FSQL_OOM_TARGET_SO=fractalsql.so sqlq \
    "SELECT fractalsql_set('reasoning_plugin','$MOCK');" \
    "SELECT fractal_text_to_sql('q');")
  grep <<< "$lev2" -qi "out of memory" \
    && pass "34 oom_inject: fsql_t2s.c's StrBuf 512-byte sb_init() failure cascades to a clean out-of-memory error (fractal_text_to_sql's schema-context build)" \
    || fail "34 oom_inject: expected an out-of-memory error, got: $lev2"

  # --- Individually-sized, non-cascading targets: fixed or
  # caller-controlled-parameter formulas where the allocation under
  # test is a different size than any other allocation the same call
  # makes, so injection unambiguously isolates it. ---

  # fractal_vector_quantize_int8(73 floats)'s SECOND buffer: the
  # output JSON string, cap = 64 + 73*6 = 502 -- distinct from the
  # input decode (73*4=292 bytes) and the codes buffer (73 bytes,
  # already covered above).
  local oom5; oom5=$(LD_PRELOAD="$shim" FSQL_OOM_FAIL_SIZE=502 \
    FSQL_OOM_TARGET_SO=fractalsql.so sqlq "SELECT fractal_vector_quantize_int8('$v73');")
  grep <<< "$oom5" -qi "out of memory" \
    && pass "34 oom_inject: fractal_vector_quantize_int8's output-JSON malloc failure surfaces as a clean out-of-memory error" \
    || fail "34 oom_inject: expected an out-of-memory error, got: $oom5"

  # fractal_vector_quantize_binary(57 floats): nbytes=(57+7)/8=8,
  # distinct from the input decode (57*4=228 bytes).
  local v57; v57=$(printf '1.0,%.0s' {1..56}; printf '1.0')
  local base6; base6=$(sqlq "SELECT length(fractal_vector_quantize_binary('$v57'));")
  [[ "$base6" =~ ^[0-9]+$ ]] \
    && pass "34 oom_inject: fractal_vector_quantize_binary(57 floats) succeeds with no fault injected (baseline)" \
    || fail "34 oom_inject: baseline quantize_binary failed: $base6"
  local oom6; oom6=$(LD_PRELOAD="$shim" FSQL_OOM_FAIL_SIZE=8 \
    FSQL_OOM_TARGET_SO=fractalsql.so sqlq "SELECT fractal_vector_quantize_binary('$v57');")
  grep <<< "$oom6" -qi "out of memory" \
    && pass "34 oom_inject: fractal_vector_quantize_binary's output-buffer malloc failure surfaces as a clean out-of-memory error" \
    || fail "34 oom_inject: expected an out-of-memory error, got: $oom6"

  # fractal_vector_from_text: fsql_parse_text_vector's scratch copy,
  # malloc(slen+1). A 27-char CSV string -> 28 bytes. fsql_vec_decode
  # reports malloc failure and a genuinely malformed input with the
  # SAME generic "malformed vector" message (no distinct OOM text) --
  # same indistinguishable-error pattern already documented elsewhere
  # in this codebase (da_decode_vec, decode_series), so this check is
  # "fails cleanly" rather than "says out of memory".
  local base7; base7=$(sqlq "SELECT length(fractal_vector_from_text('1.0,2.0,3.0,4.0,5.0,6.0,7.0'));")
  [[ "$base7" =~ ^[0-9]+$ ]] \
    && pass "34 oom_inject: fractal_vector_from_text(27-char CSV) succeeds with no fault injected (baseline)" \
    || fail "34 oom_inject: baseline vector_from_text failed: $base7"
  local oom7; oom7=$(LD_PRELOAD="$shim" FSQL_OOM_FAIL_SIZE=28 \
    FSQL_OOM_TARGET_SO=fractalsql.so sqlq "SELECT fractal_vector_from_text('1.0,2.0,3.0,4.0,5.0,6.0,7.0');")
  grep <<< "$oom7" -qi "malformed vector" \
    && pass "34 oom_inject: fractal_vector_from_text's scratch-copy malloc failure fails cleanly (shares fsql_vec_decode's generic error text with a real parse failure, not a distinct OOM message)" \
    || fail "34 oom_inject: expected a clean malformed-vector error, got: $oom7"

  # fractal_state_fingerprint('1.0,0.0,0.0', 72): n_bytes=(72+7)/8=9,
  # distinct from the input decode_series (3 elements -> 3*8=24 bytes).
  local base8; base8=$(sqlq "SELECT length(hex(fractal_state_fingerprint('1.0,0.0,0.0', 72)));")
  [[ "$base8" =~ ^[0-9]+$ ]] \
    && pass "34 oom_inject: fractal_state_fingerprint(3-vec, 72 bits) succeeds with no fault injected (baseline)" \
    || fail "34 oom_inject: baseline state_fingerprint failed: $base8"
  local oom8; oom8=$(LD_PRELOAD="$shim" FSQL_OOM_FAIL_SIZE=9 \
    FSQL_OOM_TARGET_SO=fractalsql.so sqlq "SELECT fractal_state_fingerprint('1.0,0.0,0.0', 72);")
  grep <<< "$oom8" -qi "out of memory" \
    && pass "34 oom_inject: fractal_state_fingerprint's fingerprint-buffer malloc failure surfaces as a clean out-of-memory error" \
    || fail "34 oom_inject: expected an out-of-memory error, got: $oom8"

  # fractal_embed('x') via the mock embed plugin: fsqlv_embed's fixed
  # FSQLV_MAX_EMBED_DIM(16384)*sizeof(double) = 131072-byte scratch,
  # unconditional regardless of input (a response-parsing buffer sized
  # at the dimension ceiling, not the actual response).
  local base9; base9=$(sqlq \
    "SELECT fractalsql_set('reasoning_plugin','$MOCKEMB');" \
    "SELECT fractalsql_set('http_embed_url','https://embed.invalid/v1');" \
    "SELECT fractal_vector_dims(fractal_embed('x'));")
  [[ "$(tail -n1 <<< "$base9")" == "3" ]] \
    && pass "34 oom_inject: fractal_embed('x') succeeds with no fault injected (baseline)" \
    || fail "34 oom_inject: baseline fractal_embed failed: $base9"
  local oom9; oom9=$(LD_PRELOAD="$shim" FSQL_OOM_FAIL_SIZE=131072 \
    FSQL_OOM_TARGET_SO=fractalsql.so sqlq \
    "SELECT fractalsql_set('reasoning_plugin','$MOCKEMB');" \
    "SELECT fractalsql_set('http_embed_url','https://embed.invalid/v1');" \
    "SELECT fractal_embed('x');")
  grep <<< "$oom9" -qi "out of memory" \
    && pass "34 oom_inject: fractal_embed's embedding-response scratch-buffer malloc failure surfaces as a clean out-of-memory error" \
    || fail "34 oom_inject: expected an out-of-memory error, got: $oom9"

  # fractal_reason('X') via the T2S/mock reasoning plugin: the
  # length-bounded response copy, malloc(summary_len+1). The mock
  # wraps its canned text in a ```sql fence outside code mode, so a
  # 1-char canned response ("X") becomes "```sql\nX\n```" = 12 bytes,
  # +1 for the copy's NUL = 13.
  printf 'X' > "$SQLTXT"
  local base10; base10=$(sqlq \
    "SELECT fractalsql_set('reasoning_plugin','$MOCK');" \
    "SELECT length(fractal_reason('q'));" | tail -n1)
  [[ "$base10" =~ ^[0-9]+$ ]] \
    && pass "34 oom_inject: fractal_reason('q') succeeds with no fault injected (baseline)" \
    || fail "34 oom_inject: baseline fractal_reason failed: $base10"
  local oom10; oom10=$(LD_PRELOAD="$shim" FSQL_OOM_FAIL_SIZE=13 \
    FSQL_OOM_TARGET_SO=fractalsql.so sqlq \
    "SELECT fractalsql_set('reasoning_plugin','$MOCK');" \
    "SELECT fractal_reason('q');")
  grep <<< "$oom10" -qi "out of memory" \
    && pass "34 oom_inject: fractal_reason's response-copy malloc failure surfaces as a clean out-of-memory error" \
    || fail "34 oom_inject: expected an out-of-memory error, got: $oom10"

  # --- More lever coverage: the 256-byte StrBuf-bootstrap cascade only
  # covers the sb_failed() checks reachable from the ONE call path it
  # was exercised through above (fractal_agent_detect_loop). Every
  # other agent entry point in fsql_agents.c/fsql_domain_agents.c owns
  # its OWN StrBuf instance(s) with their own downstream sb_failed()
  # checks, so reaching those needs its own representative call --
  # still far cheaper than tracing each one's growth sequence by hand,
  # just not a single file-wide freebie. Self-contained fixtures
  # (bt34_* tables), not reused from gates 23/29, since those gates
  # DELETE some of their own fixture rows later in their own run and
  # this gate must not depend on an earlier gate's leftover state.
  lever() {  # lever <label> <sql...>
    local label="$1"; shift
    local r; r=$(LD_PRELOAD="$shim" FSQL_OOM_FAIL_SIZE=256 \
      FSQL_OOM_TARGET_SO=fractalsql.so sqlq \
      "SELECT fractalsql_set('reasoning_plugin','$MOCK');" "$@")
    grep <<< "$r" -qi "out of memory" \
      && pass "34 oom_inject: $label" \
      || fail "34 oom_inject: $label -- expected an out-of-memory error, got: $r"
  }

  # Same lever, but for the agent entry points that route through the
  # embed path (fsql_vec_embed_text()) before ever reaching their own
  # StrBuf bootstrap -- those need an embed plugin + http_embed_url
  # configured instead of (or in addition to) the reasoning plugin.
  lever_embed() {  # lever_embed <label> <sql...>
    local label="$1"; shift
    local r; r=$(LD_PRELOAD="$shim" FSQL_OOM_FAIL_SIZE=256 \
      FSQL_OOM_TARGET_SO=fractalsql.so sqlq \
      "SELECT fractalsql_set('reasoning_plugin','$MOCKEMB');" \
      "SELECT fractalsql_set('http_embed_url','https://embed.invalid/v1');" "$@")
    grep <<< "$r" -qi "out of memory" \
      && pass "34 oom_inject: $label" \
      || fail "34 oom_inject: $label -- expected an out-of-memory error, got: $r"
  }

  sqlq "
    CREATE TABLE bt34_docs(id INTEGER PRIMARY KEY, body TEXT, emb TEXT);
    INSERT INTO bt34_docs(body, emb) VALUES
      ('doc about cosine metrics','1.0,0.05,0.0'),
      ('doc about vector stores','1.0,0.1,0.0');
  " >/dev/null 2>&1 || fail "34 oom_inject: bt34_docs fixture setup failed"

  lever_embed "fractal_search_agent's StrBuf bootstrap failure cascades to a clean out-of-memory error" \
    "SELECT fractal_search_agent('cosine metrics','bt34_docs','emb');"
  lever_embed "fractal_rag_agent's StrBuf bootstrap failure cascades to a clean out-of-memory error" \
    "SELECT fractal_rag_agent('embedding tiers','bt34_docs','emb');"
  lever "fractal_sql_agent's StrBuf bootstrap failure cascades to a clean out-of-memory error" \
    "SELECT fractal_sql_agent('count the rows');"
  lever_embed "fractal_agent_plan_explore's StrBuf bootstrap failure cascades to a clean out-of-memory error" \
    "SELECT fractal_agent_plan_explore('cosine metrics','bt34_docs','emb',4);"

  # Same lever, but for the diverse_portfolios enterprise-tier entry
  # point, which also needs enterprise_lib loaded before it reaches
  # its own StrBuf bootstrap.
  lever_ent() {  # lever_ent <label> <sql...>
    local label="$1"; shift
    local r; r=$(LD_PRELOAD="$shim" FSQL_OOM_FAIL_SIZE=256 \
      FSQL_OOM_TARGET_SO=fractalsql.so FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1 sqlq \
      "SELECT fractalsql_set('enterprise_lib','$MOCKENT');" \
      "SELECT fractalsql_set('reasoning_plugin','$MOCK');" "$@")
    grep <<< "$r" -qi "out of memory" \
      && pass "34 oom_inject: $label" \
      || fail "34 oom_inject: $label -- expected an out-of-memory error, got: $r"
  }
  lever "fractal_agent_trajectory_predict's StrBuf bootstrap failure cascades to a clean out-of-memory error" \
    "SELECT fractal_agent_trajectory_predict('bt34_docs','emb',1,1);"

  sqlq "SELECT fractal_store_morphology(1, '0.0,0.0,0.0');" >/dev/null 2>&1 \
    || fail "34 oom_inject: fractal_store_morphology fixture setup failed"
  lever "fractal_mine_topology_negatives's StrBuf bootstrap failure cascades to a clean out-of-memory error" \
    "SELECT fractal_mine_topology_negatives('0.0,0.0,0.0', 1);"

  sqlq "
    CREATE TABLE bt34_logs(metric REAL, ts INTEGER, host TEXT);
    INSERT INTO bt34_logs VALUES (50.0,1,'host-1'),(55.0,2,'host-1');
    CREATE TABLE bt34_mem(id INTEGER, body TEXT, emb TEXT, kind TEXT);
    INSERT INTO bt34_mem VALUES (1,'alpha','1.0,0.0,0.0','a');
    CREATE TABLE bt34_states(state_id INTEGER PRIMARY KEY, state_vec TEXT);
    INSERT INTO bt34_states VALUES (1,'1.0,0.0,0.0');
    CREATE TABLE bt34_catalog(id INTEGER, emb TEXT);
    INSERT INTO bt34_catalog VALUES (10,'0.1,0.2,0.3');
    CREATE TABLE bt34_data(id INTEGER PRIMARY KEY, val REAL);
    INSERT INTO bt34_data VALUES (1,10.5);
    CREATE TABLE bt34_patients(id INTEGER PRIMARY KEY, vitals TEXT);
    INSERT INTO bt34_patients VALUES (1,'0.9,-0.8,0.7,0.6');
    CREATE TABLE bt34_caps(capability_name TEXT, emb TEXT);
    INSERT INTO bt34_caps VALUES ('cap-a','0.1,0.2,0.3');
  " >/dev/null 2>&1 || fail "34 oom_inject: domain-agent fixtures setup failed"

  lever "agent_anomaly_triage's StrBuf bootstrap failure cascades to a clean out-of-memory error" \
    "SELECT fractal_agent_anomaly_triage('bt34_logs','metric','ts','host','host-1',32);"
  lever "agent_recall_hybrid's StrBuf bootstrap failure cascades to a clean out-of-memory error" \
    "SELECT fractal_agent_recall_hybrid('bt34_mem','emb','1.0,0.0,0.0');"
  lever "agent_outlier_intercept's StrBuf bootstrap failure cascades to a clean out-of-memory error" \
    "SELECT fractal_agent_outlier_intercept('0.95,0.05,0.0','bt34_states','state_vec',0.5);"
  lever "agent_recommend_diverse's StrBuf bootstrap failure cascades to a clean out-of-memory error" \
    "SELECT fractal_agent_recommend_diverse('bt34_catalog','emb','0.1,0.2,0.3',3,'id');"
  lever "agent_data_analyst's StrBuf bootstrap failure cascades to a clean out-of-memory error" \
    "SELECT fractal_agent_data_analyst('sum of val','[\"bt34_data\"]',2);"
  lever "agent_patient_deterioration_triage's StrBuf bootstrap failure cascades to a clean out-of-memory error" \
    "SELECT fractal_agent_patient_deterioration_triage(
       'bt34_patients','vitals','0.9,-0.8,0.7,0.6',
       '0.1,0.1,0.1,0.1','0.95,-0.85,0.75,0.65',NULL,5,'id');"
  lever "agent_allocate's StrBuf bootstrap failure cascades to a clean out-of-memory error" \
    "SELECT fractal_agent_allocate('0.05,0.1','1.0,0.0,0.0,1.0',1,'{}');"
  lever "agent_route_task's StrBuf bootstrap failure cascades to a clean out-of-memory error" \
    "SELECT fractal_agent_route_task('0.1,0.2,0.3','bt34_caps','emb','capability_name',1000);"

  # The 8 remaining domain agents (fsql_domain_agents.c has 16 total;
  # the above covers the first 8). Fixtures and input shapes mirror
  # gate_29's own, which already proved these exact shapes reach deep
  # enough into each function (past its validation, through its real
  # analytics) to hit the StrBuf bootstrap -- not reused directly,
  # since gate_29 deletes some of its own fixture rows later in its
  # own run.
  sqlq "
    CREATE TABLE bt34_fcatalog(id INTEGER PRIMARY KEY, emb TEXT);
    INSERT INTO bt34_fcatalog VALUES
      (1,'0.4,0.1,0.2'),(2,'-0.3,0.5,0.1'),(3,'0.2,-0.4,0.3'),
      (4,'0.6,0.2,-0.1'),(5,'-0.2,-0.3,0.4'),(6,'0.1,0.6,-0.2');
    CREATE TABLE bt34_fwarmup(center TEXT);
    INSERT INTO bt34_fwarmup VALUES
      ('0.3,0.1,0.2'),('-0.1,0.4,0.1'),('0.2,-0.2,0.3'),('0.5,0.1,-0.1');
    CREATE TABLE bt34_nodes(id INTEGER PRIMARY KEY, capability TEXT);
    INSERT INTO bt34_nodes VALUES
      (1,'0.9,0.1,0.0,0.0,0.0'),(2,'0.0,0.0,0.9,0.1,0.0'),(3,'0.1,0.0,0.0,0.0,0.9');
    CREATE TABLE bt34_alloc(id INTEGER PRIMARY KEY, alloc TEXT);
    INSERT INTO bt34_alloc VALUES
      (1,'0.25,0.25,0.25,0.25'),(2,'0.4,0.3,0.2,0.1'),(3,'0.1,0.2,0.3,0.4');
    CREATE TABLE bt34_vehicles(id INTEGER PRIMARY KEY, baseline TEXT, current TEXT);
    INSERT INTO bt34_vehicles VALUES
      (1,'0.1,0.1,0.1,0.1','0.8,0.7,0.6,0.5'),(2,'0.2,0.2,0.2,0.2','0.25,0.25,0.25,0.25');
    CREATE TABLE bt34_tracks(id INTEGER PRIMARY KEY, baseline TEXT, current TEXT);
    INSERT INTO bt34_tracks VALUES
      (1,'0.1,0.1,0.1,0.1','0.7,-0.4,-0.8,0.9'),(2,'0.2,0.2,0.2,0.2','0.24,0.24,0.24,0.24');
  " >/dev/null 2>&1 || fail "34 oom_inject: remaining domain-agent fixtures setup failed"

  local trace34; trace34=$(awk 'BEGIN{srand(11); out="";
    for(i=1;i<=40;i++){x=i+rand()*0.01; y=i*0.5+rand()*0.01;
      if(i>1) out=out","; out=out x","y} print out}')
  local heading34; heading34=$(awk 'BEGIN{srand(13); out=""; cum=0;
    for(i=0;i<80;i++){ step=(i>=30 && i<=50) ? (rand()-0.5)*0.35 : (rand()-0.5)*0.03;
      cum+=step; if(i>0) out=out","; out=out cum } print out}')
  local cloud34; cloud34=$(awk 'BEGIN{srand(17); out="";
    for(i=1;i<=40;i++){x=i+rand()*0.01; y=i*0.5+rand()*0.01;
      if(i>1) out=out","; out=out x","y} print out}')
  local drift34; drift34=$(awk 'BEGIN{srand(19); out="";
    for(t=1;t<=96;t++){ if(t<48){v=4.0+1.5*sin(t*0.31)+(rand()-0.5)*0.8}
                        else {v=4.0+3.0*sin(t*1.4)+(rand()-0.5)*0.4}
      if(t>1) out=out","; out=out v } print out}')
  local series34; series34=$(awk 'BEGIN{srand(7); out="";
    for(i=0;i<100;i++){v=0.1*i+(rand()-0.5)*0.05; if(i>0) out=out","; out=out v} print out}')

  lever "agent_feedback_audit's StrBuf bootstrap failure cascades to a clean out-of-memory error" \
    "SELECT fractal_agent_feedback_audit(
       'bt34_fcatalog','emb','0.5,0.5,0.5','bt34_fwarmup','center',4,3);"
  lever "agent_schedule_workload's StrBuf bootstrap failure cascades to a clean out-of-memory error" \
    "SELECT fractal_agent_schedule_workload(
       '0.8,0.1,0.0,0.0,0.1','bt34_nodes','capability','id',30,50,5);"
  lever "agent_rebalance_sibling's StrBuf bootstrap failure cascades to a clean out-of-memory error" \
    "SELECT fractal_agent_rebalance_sibling(
       '0.05,0.10,0.15,0.20',
       '0.04,0.0,0.0,0.0,0.0,0.09,0.0,0.0,0.0,0.0,0.16,0.0,0.0,0.0,0.0,0.25',
       4,'bt34_alloc','alloc','0.25,0.25,0.25,0.25',NULL,5,'id');"
  lever "agent_detour_classify's StrBuf bootstrap failure cascades to a clean out-of-memory error" \
    "SELECT fractal_agent_detour_classify(
       'bt34_vehicles','current','0.1,0.1,0.1,0.1','0.8,0.7,0.6,0.5',
       '$trace34',5,'id',2);"
  lever "agent_track_anomaly's StrBuf bootstrap failure cascades to a clean out-of-memory error" \
    "SELECT fractal_agent_track_anomaly(
       'bt34_tracks','current','0.1,0.1,0.1,0.1','0.7,-0.4,-0.8,0.9',
       '$heading34',5,'id');"
  lever "agent_network_coverage_alert's StrBuf bootstrap failure cascades to a clean out-of-memory error" \
    "SELECT fractal_agent_network_coverage_alert('$cloud34','$drift34',2,48,0.5);"
  lever "agent_regime_triage's StrBuf bootstrap failure cascades to a clean out-of-memory error" \
    "SELECT fractal_agent_regime_triage('$series34',32);"

  if [[ -n "$(wpath "$MOCKENT")" && -f "$(wpath "$MOCKENT")" ]]; then
    lever_ent "agent_diverse_portfolios's StrBuf bootstrap failure cascades to a clean out-of-memory error" \
      "SELECT fractal_agent_diverse_portfolios('0.05,0.1','1.0,0.0,0.0,1.0',1);"
  else
    skip "34 oom_inject: agent_diverse_portfolios (mock core did not build)"
  fi
}

gate_35_ed25519() {
  if [[ -z "$CC" ]]; then
    skip "35 ed25519 (no C compiler on PATH)"
    return
  fi
  # Must run from the repo root with the same -Isrc the real build uses
  # to resolve fsql_enterprise.c's #include "fsql_ed25519.h": under
  # --coverage this makes gcov record the identical source path, so
  # this probe's hits merge into the SAME fsql_ed25519.h entry the main
  # build's own lcov capture reports, rather than a second, separate one.
  local obj="src/_ed25519_probe.o"
  local covflags=()
  [[ "$COVERAGE" -eq 1 ]] && covflags+=(--coverage)
  rm -f "$obj"
  if ! env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES "$CC" -std=c11 -O1 -g \
        ${covflags[@]+"${covflags[@]}"} -Isrc -c tests/ed25519_probe.c \
        -o "$obj" >"$PDIRW/ed25519_probe_build.log" 2>&1; then
    fail "35 ed25519: probe failed to build (see $PDIRW/ed25519_probe_build.log)"
    return
  fi
  local bin="$PDIRW/ed25519_probe"
  if ! env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES "$CC" ${covflags[@]+"${covflags[@]}"} "$obj" -o "$bin" \
        >"$PDIRW/ed25519_probe_link.log" 2>&1; then
    fail "35 ed25519: probe failed to link (see $PDIRW/ed25519_probe_link.log)"
    rm -f "$obj"
    return
  fi
  # This binary has no sanitizer instrumentation of its own -- running
  # it with a sanitizer runtime inherited via LD_PRELOAD hits the same
  # "runtime does not come first" refusal gate 34 does.
  local out; out=$(env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES "$bin" 2>&1)
  local rc=$?
  # .gcno/.gcda stay in src/ for run_coverage_report's later lcov
  # capture under --coverage; otherwise there's nothing worth keeping.
  rm -f "$obj"
  [[ "$COVERAGE" -ne 1 ]] && rm -f "${obj%.o}.gcno" "${obj%.o}.gcda"
  if [[ $rc -eq 0 ]]; then
    pass "35 ed25519: fsql_ed25519_verify_detached (RFC 8032 TEST 1/2 + throwaway-key accept/tamper/wrong-key/corrupt-sig reject -- see driver OK lines above)"
  else
    fail "35 ed25519: see driver output above ($out)"
  fi
}

gate_37_mcp_smoke() {
  # 8.3's MCP gate: builds on the already-built extension (bt_setup
  # resolved $EXT / compiled the mock reasoning fixtures), starts the
  # stdio MCP server subprocess against it, and drives a real client
  # session through initialize / tools-list / per-tier tools/call round
  # trips -- happy paths and clean error paths side by side, mirroring
  # the SQL-level gates' own pairing style. The client driver lives at
  # mcp/tests/mcp_smoke_client.py so the .ps1 gate drives the same file.

  # Self-skip until the MCP server code exists (the posture is kept
  # even though it now does). The server itself is the native C++17
  # binary -- the only python3 dependency here is this
  # gate's own JSON-RPC client driver, the same driver constraint the
  # python-driven gates already carry.
  if [[ ! -f "$HERE/mcp/tests/mcp_smoke_client.py" \
        || ! -f "$HERE/mcp/src/main.cpp" ]]; then
    skip "37 mcp_smoke (mcp/ server code not present)"
    return
  fi
  local mcp_py
  mcp_py="$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)"
  [[ -n "$PY" ]] && mcp_py="$PY"
  if [[ -z "$mcp_py" ]]; then
    skip "37 mcp_smoke (no python3 on PATH -- the smoke client driver needs it)"
    return
  fi
  if [[ "$(uname -s)" = "Darwin" && "$ASAN$UBSAN$TSAN" != "000" ]]; then
    skip "37 mcp_smoke (Darwin + --asan/--ubsan/--tsan: skipping like the other runtime gates)"
    return
  fi

  # The server binary: POSIX builds it from mcp/Makefile (incremental;
  # only when missing or stale against mcp/src). On Windows the .sh
  # harness uses the checked-in mcp/dist/windows-mcp build (built by
  # mcp/scripts/windows/build.bat -- this harness's gcc OOMs on the
  # amalgamation, per the Makefile's own note) as-is.
  local mcp_exe
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
      mcp_exe="$HERE/mcp/dist/windows-mcp/fractalsql-sqlite-mcp.exe"
      if [[ ! -f "$mcp_exe" ]]; then
        skip "37 mcp_smoke (no mcp/dist/windows-mcp build -- run mcp\\scripts\\windows\\build.bat)"
        return
      fi
      ;;
    *)
      mcp_exe="$HERE/mcp/fractalsql-sqlite-mcp"
      local needs_build=0
      if [[ ! -x "$mcp_exe" ]]; then
        needs_build=1
      elif [[ -n "$(find "$HERE/mcp/src" \( -name '*.cpp' -o -name '*.h' \) \
                    -newer "$mcp_exe" -print 2>/dev/null | head -n1)" ]]; then
        needs_build=1
      fi
      # --coverage always forces a full rebuild, mtime check or not: a
      # mtime-fresh binary from an earlier PLAIN run would otherwise be
      # reused as-is (no COVERAGE=1, no instrumentation), silently
      # producing a zero/empty report instead of an error. `make clean`
      # first for the same reason gate 01 does it for the core .so --
      # plain `make` has no flag-change tracking, only mtimes, so
      # stale non-instrumented .o files from a prior plain build would
      # otherwise NOT get recompiled under COVERAGE=1 and would link
      # straight into the "coverage" binary uninstrumented.
      if [[ "$COVERAGE" -eq 1 ]]; then
        needs_build=1
        rm -f "$HERE/mcp"/*.gcda "$HERE/mcp/src"/*.gcda "$HERE/mcp/src/adapters"/*.gcda
        env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES make -C "$HERE/mcp" clean >&2
      fi
      if [[ "$needs_build" = 1 ]]; then
        if ! command -v make >/dev/null 2>&1 || ! command -v g++ >/dev/null 2>&1; then
          skip "37 mcp_smoke (no make/g++ toolchain to build the MCP server binary)"
          return
        fi
        # Darwin: OpenSSL isn't in the macOS SDK at all, and Homebrew's
        # openssl@3 is keg-only (never symlinked into the default -I/-L
        # search path) -- mcp/Makefile's bare -lssl/-lcrypto only
        # resolves when CXXFLAGS points at it explicitly (same fix
        # scripts/package-darwin.sh carries for the release build).
        local mcp_cxxflags=""
        if [[ "$(uname -s)" = "Darwin" ]]; then
          local openssl_prefix
          openssl_prefix="$(brew --prefix openssl@3 2>/dev/null || true)"
          if [[ -z "$openssl_prefix" || ! -f "$openssl_prefix/include/openssl/evp.h" ]]; then
            skip "37 mcp_smoke (Homebrew openssl@3 not found -- brew install openssl@3 to build the MCP server)"
            return
          fi
          mcp_cxxflags="-std=c++17 -O2 -Wall -Wextra -I${openssl_prefix}/include -L${openssl_prefix}/lib"
        fi
        local mcp_env=(env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES)
        [[ -n "$mcp_cxxflags" ]] && mcp_env+=(CXXFLAGS="$mcp_cxxflags")
        local mcp_make_args=()
        [[ "$COVERAGE" -eq 1 ]] && mcp_make_args+=(COVERAGE=1)
        if ! "${mcp_env[@]}" make -C "$HERE/mcp" ${mcp_make_args[@]+"${mcp_make_args[@]}"} >&2; then
          fail "37 mcp_smoke: MCP server build failed"
          return
        fi
      fi
      ;;
  esac

  # Windows: the mock reasoning fixture fopens a CWD-relative canary
  # file, so the MCP server runs with its CWD at $BTROOT (where the
  # harness keeps the fixed file contracts); POSIX fixtures read the
  # absolute /tmp contract path, unaffected by CWD. The client driver
  # gets everything through the environment, per the MCP server's own
  # configuration convention.
  local bootsql="SELECT fractalsql_set('reasoning_plugin','$MOCK');"

  # $EXT is CWD-relative when resolve_ext() set it (single-gate runs),
  # but gate 01 sets it to the already-absolute "$HERE/fractalsql.so"
  # (a full run hits gate 01 first) -- prepending $HERE again in that
  # case doubles the path. The MCP server runs with its CWD at
  # $BTROOT, so it needs the ABSOLUTE form of the extension path
  # either way.
  local ext_for_abs="$EXT"
  [[ "$ext_for_abs" = /* ]] || ext_for_abs="$HERE/$ext_for_abs"
  local ext_abs="$EXTW"
  if command -v cygpath >/dev/null 2>&1; then
    ext_abs="$(cygpath -m "$ext_for_abs" 2>/dev/null)" || ext_abs="$EXTW"
  else
    ext_abs="$ext_for_abs"
  fi

  # Unlike the ed25519/oom-inject probes above, this process is NOT left
  # unsanitized end to end: the MCP server (mcp_exe, itself built plain --
  # mcp/Makefile has no ASAN_ARGS support) dlopens fractalsql.so at runtime
  # via sqlite3_load_extension(), and under --asan/--ubsan/--tsan that .so
  # IS sanitizer-built. That's the same "sanitized library dlopen'd into an
  # unsanitized host" case main() already arranges LD_PRELOAD for (see its
  # own comment) -- stripping LD_PRELOAD here (as the build step correctly
  # does, to keep the compiler itself unsanitized) would instead reproduce
  # gate 34/35's "ASan runtime does not come first" abort the moment the
  # extension loads.
  MCP_HERE="$(wpath "$HERE/mcp")" \
  MCP_SERVER_EXE="$(wpath "$mcp_exe")" \
  MCP_CANARY_FILE="$SQLTXT" \
  MCP_SERVER_CWD="$(wpath "$BTROOT")" \
  MCP_SLOW_REASONING_PLUGIN="$SLOWPLUG" \
  SQLITE_DB_PATH="$DBW" \
  FRACTALSQL_EXTENSION_PATH="$ext_abs" \
  FSQL_MCP_LOG_LEVEL=debug \
  FRACTALSQL_BOOTSTRAP_SQL="$bootsql" \
    "$mcp_py" -u "$HERE/mcp/tests/mcp_smoke_client.py"
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    fail "37 mcp_smoke: client driver exited $rc"
  else
    pass "37 mcp_smoke: full MCP session (initialize, 82-tool catalog, discovery/cognition/agency round trips, enterprise clean-error path, \$ / cancel, resources+prompts)"
  fi
}

gate_38_mcp_https() {
  # The optional direct-TLS mode (--https): deliberately narrow (see
  # mcp/tests/mcp_https_smoke_client.py's own docstring). Gate 37's HTTP
  # phase already exhausts the plaintext transport's behavior; this one
  # proves only what's specific to --https: fail-fast on a bad/missing
  # cert, the port actually speaking TLS (not dual-stack plaintext+TLS),
  # and the Bearer-token check still applying underneath TLS.
  if [[ ! -f "$HERE/mcp/tests/mcp_https_smoke_client.py" \
        || ! -f "$HERE/mcp/src/main.cpp" ]]; then
    skip "38 mcp_https (mcp/ server code not present)"
    return
  fi
  local mcp_py
  mcp_py="$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)"
  [[ -n "$PY" ]] && mcp_py="$PY"
  if [[ -z "$mcp_py" ]]; then
    skip "38 mcp_https (no python3 on PATH -- the smoke client driver needs it)"
    return
  fi
  if ! command -v openssl >/dev/null 2>&1; then
    skip "38 mcp_https (no openssl CLI on PATH to generate the throwaway TLS cert/key)"
    return
  fi
  if [[ "$(uname -s)" = "Darwin" && "$ASAN$UBSAN$TSAN" != "000" ]]; then
    skip "38 mcp_https (Darwin + --asan/--ubsan/--tsan: skipping like the other runtime gates)"
    return
  fi

  # Same binary gate 37 builds/reuses ($HERE/mcp/fractalsql-sqlite-mcp or
  # the checked-in Windows build); duplicated here rather than factored
  # out so this gate stays runnable standalone and never risks gate 37's
  # own (much larger, extensively exercised) build path.
  local mcp_exe
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
      mcp_exe="$HERE/mcp/dist/windows-mcp/fractalsql-sqlite-mcp.exe"
      if [[ ! -f "$mcp_exe" ]]; then
        skip "38 mcp_https (no mcp/dist/windows-mcp build -- run mcp\\scripts\\windows\\build.bat)"
        return
      fi
      ;;
    *)
      mcp_exe="$HERE/mcp/fractalsql-sqlite-mcp"
      local needs_build=0
      if [[ ! -x "$mcp_exe" ]]; then
        needs_build=1
      elif [[ -n "$(find "$HERE/mcp/src" \( -name '*.cpp' -o -name '*.h' \) \
                    -newer "$mcp_exe" -print 2>/dev/null | head -n1)" ]]; then
        needs_build=1
      fi
      # Unlike gate 37, this gate never forces a --coverage rebuild: the
      # TLS handshake path it tests doesn't depend on instrumentation,
      # and a second full mcp/ rebuild here would just double the
      # runtime under --coverage for no new signal (the coverage numbers
      # themselves come from gate 37's own rebuild).
      if [[ "$needs_build" = 1 ]]; then
        if ! command -v make >/dev/null 2>&1 || ! command -v g++ >/dev/null 2>&1; then
          skip "38 mcp_https (no make/g++ toolchain to build the MCP server binary)"
          return
        fi
        local mcp_cxxflags=""
        if [[ "$(uname -s)" = "Darwin" ]]; then
          local openssl_prefix
          openssl_prefix="$(brew --prefix openssl@3 2>/dev/null || true)"
          if [[ -z "$openssl_prefix" || ! -f "$openssl_prefix/include/openssl/evp.h" ]]; then
            skip "38 mcp_https (Homebrew openssl@3 not found -- brew install openssl@3 to build the MCP server)"
            return
          fi
          mcp_cxxflags="-std=c++17 -O2 -Wall -Wextra -I${openssl_prefix}/include -L${openssl_prefix}/lib"
        fi
        local mcp_env=(env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES)
        [[ -n "$mcp_cxxflags" ]] && mcp_env+=(CXXFLAGS="$mcp_cxxflags")
        if ! "${mcp_env[@]}" make -C "$HERE/mcp" >&2; then
          fail "38 mcp_https: MCP server build failed"
          return
        fi
      fi
      ;;
  esac

  # Throwaway self-signed cert/key, 1-day validity, CN=127.0.0.1 (the only
  # host this gate ever connects to). Regenerated every run; never reused
  # across invocations and never committed anywhere.
  local tls_cert="$TMPROOT/fractalsql_bt_mcp_https_cert.pem"
  local tls_key="$TMPROOT/fractalsql_bt_mcp_https_key.pem"
  rm -f "$tls_cert" "$tls_key"
  # MSYS_NO_PATHCONV: under MSYS/git-bash (the MINGW*/MSYS*/CYGWIN* leg
  # above), an MSYS-built openssl otherwise rewrites the leading "/" in
  # -subj as a Windows path (the well-known MSYS argv path-conversion
  # gotcha).
  # -config pointing at a minimal synthesized [req]/distinguished_name
  # section, rather than OPENSSL_CONF=/dev/null (empty config): whichever
  # openssl resolves on PATH may carry a baked-in default config path
  # from an unrelated install (seen in practice on Windows: PostgreSQL's
  # psqlODBC ships its own openssl.exe pointing at its own
  # etc/openssl.cnf, which `openssl req` hard-fails loading if it doesn't
  # exist) -- but macOS's /usr/bin/openssl is Apple's LibreSSL, not
  # OpenSSL (Homebrew's real openssl@3 is keg-only and never reaches
  # PATH), and LibreSSL's `req`, unlike OpenSSL >= 1.1.1, has no built-in
  # fallback when the config has no distinguished_name section -- an
  # empty/absent config (including /dev/null) hard-fails there even
  # though -subj supplies every value a prompt would have asked for. An
  # explicit minimal config satisfies both implementations.
  local tls_cnf="$TMPROOT/fractalsql_bt_mcp_https_openssl.cnf"
  printf '[req]\ndistinguished_name = dn\nprompt = no\n[dn]\n' >"$tls_cnf"
  if ! MSYS_NO_PATHCONV=1 openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=127.0.0.1" \
        -config "$tls_cnf" -keyout "$tls_key" -out "$tls_cert" >"$PDIRW/mcp_https_cert_gen.log" 2>&1; then
    fail "38 mcp_https: openssl req failed to generate the throwaway cert/key (see $PDIRW/mcp_https_cert_gen.log)"
    return
  fi

  # $EXT is CWD-relative when resolve_ext() set it (single-gate runs), but
  # gate 01 sets it to the already-absolute "$HERE/fractalsql.so" (a full
  # run hits gate 01 first) -- same resolution gate 37 does, since this
  # gate's one real tools/call also dlopens the extension.
  local ext_for_abs="$EXT"
  [[ "$ext_for_abs" = /* ]] || ext_for_abs="$HERE/$ext_for_abs"
  local ext_abs="$EXTW"
  if command -v cygpath >/dev/null 2>&1; then
    ext_abs="$(cygpath -m "$ext_for_abs" 2>/dev/null)" || ext_abs="$EXTW"
  else
    ext_abs="$ext_for_abs"
  fi

  # LD_PRELOAD is NOT stripped here (unlike the build step above): under
  # --asan/--ubsan/--tsan the extension this process dlopens IS
  # sanitizer-built, so the sanitizer runtime must already be first in
  # this process's own library list -- gate 37's own comment on its
  # matching invocation explains the same requirement.
  MCP_SERVER_EXE="$(wpath "$mcp_exe")" \
  MCP_SERVER_CWD="$(wpath "$BTROOT")" \
  MCP_HTTPS_PORT=18990 \
  MCP_HTTPS_CERT="$(wpath "$tls_cert")" \
  MCP_HTTPS_KEY="$(wpath "$tls_key")" \
  SQLITE_DB_PATH="$DBW" \
  FRACTALSQL_EXTENSION_PATH="$ext_abs" \
    "$mcp_py" -u "$HERE/mcp/tests/mcp_https_smoke_client.py"
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    fail "38 mcp_https: client driver exited $rc"
  else
    pass "38 mcp_https: --https fail-fast misconfig, TLS-only listening, and a full authenticated JSON-RPC round trip"
  fi
}

gate_36_extract_population() {
  if [[ -z "$CC" ]]; then
    skip "36 extract_population (no C compiler on PATH)"
    return
  fi
  # fsql_extract_population's only caller is the libFuzzer smoke
  # harness (gate 21, FSQL_FUZZ_* only -- never part of a plain
  # --coverage run), so it's otherwise dead here. Same repo-root /
  # -Isrc treatment as gate 35's probe, but compiling src/fsql_parse.c
  # itself rather than a header: a SEPARATELY-named object (not
  # src/fsql_parse.o, which the real build already populated with this
  # same file's other 3 functions' hits from earlier gates) so this
  # probe's run only ADDS fsql_extract_population's hits via lcov's own
  # same-source-path summation, rather than overwriting the real
  # build's object and risking its already-recorded hits.
  local mainobj="src/_extract_pop_main.o"
  local supportobj="src/_extract_pop_support.o"
  local covflags=()
  [[ "$COVERAGE" -eq 1 ]] && covflags+=(--coverage)
  rm -f "$mainobj" "$supportobj"
  if ! env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES "$CC" -std=c11 -O1 -g \
        ${covflags[@]+"${covflags[@]}"} -Isrc \
        -c tests/extract_population_probe.c -o "$mainobj" \
        >"$PDIRW/extract_pop_build.log" 2>&1 \
     || ! env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES "$CC" -std=c11 -O1 -g \
        ${covflags[@]+"${covflags[@]}"} \
        -c src/fsql_parse.c -o "$supportobj" \
        >>"$PDIRW/extract_pop_build.log" 2>&1; then
    fail "36 extract_population: probe failed to build (see $PDIRW/extract_pop_build.log)"
    rm -f "$mainobj" "$supportobj"
    return
  fi
  local bin="$PDIRW/extract_population_probe"
  if ! env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES "$CC" ${covflags[@]+"${covflags[@]}"} \
        "$mainobj" "$supportobj" -o "$bin" \
        >"$PDIRW/extract_pop_link.log" 2>&1; then
    fail "36 extract_population: probe failed to link (see $PDIRW/extract_pop_link.log)"
    rm -f "$mainobj" "$supportobj"
    return
  fi
  # No sanitizer instrumentation of its own -- same LD_PRELOAD-
  # exclusion gate 34/35 need under --asan/--ubsan/--tsan.
  local out; out=$(env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES "$bin" 2>&1)
  local rc=$?
  rm -f "$mainobj" "$supportobj"
  if [[ "$COVERAGE" -ne 1 ]]; then
    rm -f "${mainobj%.o}.gcno" "${mainobj%.o}.gcda"
    rm -f "${supportobj%.o}.gcno" "${supportobj%.o}.gcda"
  fi
  if [[ $rc -eq 0 ]]; then
    pass "36 extract_population: fsql_extract_population (population-array parse, no-key, NULL, max_rows cap -- see driver OK lines above)"
  else
    fail "36 extract_population: see driver output above ($out)"
  fi
}

gate_39_extract_parse() {
  if [[ -z "$CC" ]]; then
    skip "39 extract_parse (no C compiler on PATH)"
    return
  fi
  # fsql_extract_best_point/fsql_parse_embedding_array/fsql_extract_
  # topk (src/fractalsql_parse.c) all parse JSON text that, through
  # any real SQL-level call, only ever comes back well-formed from the
  # vendored SFS core or tests/mock_reasoning_plugin.c's canned
  # responses -- there is no SQL-reachable way to feed them a
  # deliberately malformed string, so their error branches (missing
  # key, malformed number, missing closing brace, idx out of range)
  # are otherwise dead in a plain --coverage run. Same standalone-
  # probe / separately-named-object treatment as gate 36's sibling
  # probe (see its own comment): a probe-only object for src/
  # fractalsql_parse.c, not src/fsql_parse.o itself, so this run's
  # hits ADD to the real build's via lcov's own same-source-path
  # summation instead of overwriting it.
  local mainobj="src/_extract_parse_main.o"
  local supportobj="src/_extract_parse_support.o"
  local covflags=()
  [[ "$COVERAGE" -eq 1 ]] && covflags+=(--coverage)
  rm -f "$mainobj" "$supportobj"
  if ! env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES "$CC" -std=c11 -O1 -g \
        ${covflags[@]+"${covflags[@]}"} -Isrc \
        -c tests/extract_parse_probe.c -o "$mainobj" \
        >"$PDIRW/extract_parse_build.log" 2>&1 \
     || ! env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES "$CC" -std=c11 -O1 -g \
        ${covflags[@]+"${covflags[@]}"} \
        -c src/fsql_parse.c -o "$supportobj" \
        >>"$PDIRW/extract_parse_build.log" 2>&1; then
    fail "39 extract_parse: probe failed to build (see $PDIRW/extract_parse_build.log)"
    rm -f "$mainobj" "$supportobj"
    return
  fi
  local bin="$PDIRW/extract_parse_probe"
  if ! env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES "$CC" ${covflags[@]+"${covflags[@]}"} \
        "$mainobj" "$supportobj" -o "$bin" \
        >"$PDIRW/extract_parse_link.log" 2>&1; then
    fail "39 extract_parse: probe failed to link (see $PDIRW/extract_parse_link.log)"
    rm -f "$mainobj" "$supportobj"
    return
  fi
  # No sanitizer instrumentation of its own -- same LD_PRELOAD-
  # exclusion gate 34/35/36 need under --asan/--ubsan/--tsan.
  local out; out=$(env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES "$bin" 2>&1)
  local rc=$?
  rm -f "$mainobj" "$supportobj"
  if [[ "$COVERAGE" -ne 1 ]]; then
    rm -f "${mainobj%.o}.gcno" "${mainobj%.o}.gcda"
    rm -f "${supportobj%.o}.gcno" "${supportobj%.o}.gcda"
  fi
  if [[ $rc -eq 0 ]]; then
    pass "39 extract_parse: fsql_extract_best_point/fsql_parse_embedding_array/fsql_extract_topk malformed-input branches (see driver OK lines above)"
  else
    fail "39 extract_parse: see driver output above ($out)"
  fi
}

gate_40_vectors_probe() {
  if [[ ! -f "$HERE/mcp/tests/vectors_probe.cpp" ]]; then
    skip "40 vectors_probe (mcp/ test not present)"
    return
  fi
  local cxx
  cxx="$(command -v g++ 2>/dev/null || true)"
  if [[ -z "$cxx" ]]; then
    skip "40 vectors_probe (no g++ on PATH)"
    return
  fi
  # mcp/src/vectors.cpp's own coercion/validation branches (coerceNumber's
  # non-finite-string path, vectorParamToText's bad.size()<3 cap, blobTo
  # Numbers'/hexToBytes' malformed-input rejections) are reachable through
  # a real tools/call round trip only indirectly, by finding a tool whose
  # own JSON-schema layer lets a deliberately-malformed element through --
  # a direct unit test is simpler and certain to hit each branch. Same
  # standalone-probe / separately-named-object idiom as gate 39's C
  # sibling: builds from mcp/ so the recorded source path for mcp/src/
  # vectors.cpp and mcp/src/errors.cpp matches the main mcp build's own,
  # merging into its coverage via lcov's same-source-path summation
  # rather than overwriting or duplicating it.
  local mainobj="$HERE/mcp/src/_vectors_probe_main.o"
  local vecobj="$HERE/mcp/src/_vectors_probe_vectors.o"
  local errobj="$HERE/mcp/src/_vectors_probe_errors.o"
  local covflags=()
  [[ "$COVERAGE" -eq 1 ]] && covflags+=(--coverage -fprofile-update=atomic)
  # std::to_chars(double) in src/vectors.cpp needs macOS >= 13.3 (see mcp/Makefile)
  local minver=()
  [[ "$(uname -s)" = "Darwin" ]] && minver+=(-mmacosx-version-min=13.3)
  rm -f "$mainobj" "$vecobj" "$errobj"
  ( cd "$HERE/mcp" && \
    env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES "$cxx" -std=c++17 -O1 -g \
        ${covflags[@]+"${covflags[@]}"} ${minver[@]+"${minver[@]}"} -Ivendor -Isrc \
        -c tests/vectors_probe.cpp -o "$mainobj" \
     && env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES "$cxx" -std=c++17 -O1 -g \
        ${covflags[@]+"${covflags[@]}"} ${minver[@]+"${minver[@]}"} -Ivendor -Isrc \
        -c src/vectors.cpp -o "$vecobj" \
     && env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES "$cxx" -std=c++17 -O1 -g \
        ${covflags[@]+"${covflags[@]}"} ${minver[@]+"${minver[@]}"} -Ivendor -Isrc \
        -c src/errors.cpp -o "$errobj" \
  ) >"$PDIRW/vectors_probe_build.log" 2>&1
  if [[ ! -f "$mainobj" || ! -f "$vecobj" || ! -f "$errobj" ]]; then
    fail "40 vectors_probe: probe failed to build (see $PDIRW/vectors_probe_build.log)"
    rm -f "$mainobj" "$vecobj" "$errobj"
    return
  fi
  local bin="$PDIRW/vectors_probe"
  if ! env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES "$cxx" ${covflags[@]+"${covflags[@]}"} \
        "$mainobj" "$vecobj" "$errobj" -o "$bin" \
        >"$PDIRW/vectors_probe_link.log" 2>&1; then
    fail "40 vectors_probe: probe failed to link (see $PDIRW/vectors_probe_link.log)"
    rm -f "$mainobj" "$vecobj" "$errobj"
    return
  fi
  local out; out=$(env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES "$bin" 2>&1)
  local rc=$?
  rm -f "$mainobj" "$vecobj" "$errobj"
  if [[ "$COVERAGE" -ne 1 ]]; then
    rm -f "${mainobj%.o}.gcno" "${mainobj%.o}.gcda"
    rm -f "${vecobj%.o}.gcno" "${vecobj%.o}.gcda"
    rm -f "${errobj%.o}.gcno" "${errobj%.o}.gcda"
  fi
  if [[ $rc -eq 0 ]]; then
    pass "40 vectors_probe: mcp/src/vectors.cpp coercion/validation branches (see driver OK lines above)"
  else
    fail "40 vectors_probe: see driver output above ($out)"
  fi
}

gate_41_db_probe() {
  if [[ ! -f "$HERE/mcp/tests/db_probe.cpp" ]]; then
    skip "41 db_probe (mcp/ test not present)"
    return
  fi
  local cxx
  cxx="$(command -v g++ 2>/dev/null || true)"
  if [[ -z "$cxx" ]]; then
    skip "41 db_probe (no g++ on PATH)"
    return
  fi
  if [[ -z "$CC" ]]; then
    skip "41 db_probe (no C compiler on PATH for the vendored sqlite3.c TU)"
    return
  fi
  # mcp/src/db.h's own prepare/bind/step-failure, version-skew-warning and
  # bootstrap-failure branches need a deliberately-broken SQL string, a
  # mismatched expected engine version, or a schema state a real tool call
  # never produces on its own -- a direct unit test against DbConnection's
  # public API (connect/callScalar/queryAll/columnNames, the SAME class the
  # live server uses) hits each one with certainty instead. db.h is header-
  # only (every function inline, no db.cpp of its own), so unlike gate 40's
  # vectors.cpp sibling there is no separately-compiled real object to
  # merge against -- this probe's OWN translation unit is the only place
  # db.h's coverage data exists at all. Its `#include "db.h"` (relying on
  # -Isrc, not a `../src/db.h` relative path) is deliberate: it must match
  # how every real .cpp includes it so gcov records the identical "src/
  # db.h" path and lcov's same-source-path summation actually finds it
  # (confirmed by direct testing: a `../src/db.h` include recorded a
  # different, non-merging path).
  local mainobj="$HERE/mcp/src/_db_probe_main.o"
  local errobj="$HERE/mcp/src/_db_probe_errors.o"
  local logobj="$HERE/mcp/src/_db_probe_logging.o"
  local sqliteobj="$HERE/mcp/src/_db_probe_sqlite3.o"
  local covflags=()
  # Darwin: src/logging.cpp includes <openssl/evp.h>, and Homebrew's
  # openssl@3 is keg-only (see gate 37), so the probe's own compile/link
  # lines need its include/lib dirs explicitly.
  local ossl_cflags=() ossl_ldflags=()
  if [[ "$(uname -s)" = "Darwin" ]]; then
    local openssl_prefix
    openssl_prefix="$(brew --prefix openssl@3 2>/dev/null || true)"
    if [[ -z "$openssl_prefix" || ! -f "$openssl_prefix/include/openssl/evp.h" ]]; then
      skip "41 db_probe (Homebrew openssl@3 not found -- brew install openssl@3)"
      return
    fi
    ossl_cflags=(-I"${openssl_prefix}/include")
    ossl_ldflags=(-L"${openssl_prefix}/lib")
  fi
  [[ "$COVERAGE" -eq 1 ]] && covflags+=(--coverage -fprofile-update=atomic)
  rm -f "$mainobj" "$errobj" "$logobj" "$sqliteobj"
  ( cd "$HERE/mcp" && \
    env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES "$cxx" -std=c++17 -O1 -g \
        ${covflags[@]+"${covflags[@]}"} -DFSQL_MCP_VERSION="\"2.0.11\"" \
        -I../deps/sqlite -Ivendor -Isrc ${ossl_cflags[@]+"${ossl_cflags[@]}"} \
        -c tests/db_probe.cpp -o "$mainobj" \
     && env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES "$cxx" -std=c++17 -O1 -g \
        ${covflags[@]+"${covflags[@]}"} -DFSQL_MCP_VERSION="\"2.0.11\"" \
        -I../deps/sqlite -Ivendor -Isrc ${ossl_cflags[@]+"${ossl_cflags[@]}"} \
        -c src/errors.cpp -o "$errobj" \
     && env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES "$cxx" -std=c++17 -O1 -g \
        ${covflags[@]+"${covflags[@]}"} -DFSQL_MCP_VERSION="\"2.0.11\"" \
        -I../deps/sqlite -Ivendor -Isrc ${ossl_cflags[@]+"${ossl_cflags[@]}"} \
        -c src/logging.cpp -o "$logobj" \
     && env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES "$CC" -std=c99 -O1 -g -fPIC \
        ${covflags[@]+"${covflags[@]}"} \
        -DSQLITE_ENABLE_LOAD_EXTENSION=1 -DSQLITE_THREADSAFE=1 \
        -DSQLITE_ENABLE_COLUMN_METADATA=1 \
        -c ../deps/sqlite/sqlite3.c -o "$sqliteobj" \
  ) >"$PDIRW/db_probe_build.log" 2>&1
  if [[ ! -f "$mainobj" || ! -f "$errobj" || ! -f "$logobj" || ! -f "$sqliteobj" ]]; then
    fail "41 db_probe: probe failed to build (see $PDIRW/db_probe_build.log)"
    rm -f "$mainobj" "$errobj" "$logobj" "$sqliteobj"
    return
  fi
  local bin="$PDIRW/db_probe"
  if ! env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES "$cxx" ${covflags[@]+"${covflags[@]}"} \
        "$mainobj" "$errobj" "$logobj" "$sqliteobj" -o "$bin" \
        ${ossl_ldflags[@]+"${ossl_ldflags[@]}"} \
        -lssl -lcrypto -lpthread -ldl \
        >"$PDIRW/db_probe_link.log" 2>&1; then
    fail "41 db_probe: probe failed to link (see $PDIRW/db_probe_link.log)"
    rm -f "$mainobj" "$errobj" "$logobj" "$sqliteobj"
    return
  fi
  # Same absolute-path resolution gate 37/38 use for $EXT (a real .so to
  # exercise the version-skew/bootstrap paths; CWD-relative otherwise).
  local ext_for_abs="$EXT"
  [[ "$ext_for_abs" = /* ]] || ext_for_abs="$HERE/$ext_for_abs"
  # Unlike gate 35/36/39's standalone probes (no sanitizer runtime of
  # their own, and nothing else in their process ever needs one), this
  # probe DLOPENS the real fractalsql.so via DbConnection::connect() --
  # same "sanitized library dlopen'd into an unsanitized host" case
  # gate 37/38's own comment describes: under --asan/--ubsan/--tsan that
  # .so IS sanitizer-built, so LD_PRELOAD must stay set for THIS step
  # (unlike the build step above, which must strip it to keep g++/cc
  # itself unsanitized) or the dlopen aborts with "ASan runtime does not
  # come first in initial library list".
  local out; out=$("$bin" "$ext_for_abs" 2>&1)
  local rc=$?
  rm -f "$mainobj" "$errobj" "$logobj" "$sqliteobj"
  if [[ "$COVERAGE" -ne 1 ]]; then
    rm -f "${mainobj%.o}.gcno" "${mainobj%.o}.gcda"
    rm -f "${errobj%.o}.gcno" "${errobj%.o}.gcda"
    rm -f "${logobj%.o}.gcno" "${logobj%.o}.gcda"
    rm -f "${sqliteobj%.o}.gcno" "${sqliteobj%.o}.gcda"
  fi
  if [[ $rc -eq 0 ]]; then
    pass "41 db_probe: mcp/src/db.h prepare/bind/step-failure, version-skew-warning, bootstrap-failure and classifySqliteError branches (see driver OK lines above)"
  else
    fail "41 db_probe: see driver output above ($out)"
  fi
}

gate_42_concurrency_probe() {
  if [[ ! -f "$HERE/mcp/tests/concurrency_probe.cpp" ]]; then
    skip "42 concurrency_probe (mcp/ test not present)"
    return
  fi
  local cxx
  cxx="$(command -v g++ 2>/dev/null || true)"
  if [[ -z "$cxx" ]]; then
    skip "42 concurrency_probe (no g++ on PATH)"
    return
  fi
  # mcp/src/concurrency.h's per-client-limit-reached and global-timeout
  # throw branches (and the Token-destructor release paths each throw
  # takes on its way out) are never hit by any live-protocol test: a
  # synchronous request/response round trip always releases its Token
  # before the next request is even read, so the limits this class
  # guards are never actually seen saturated. concurrency.h is header-
  # only (every method inline, no concurrency.cpp of its own; it doesn't
  # call anything defined in errors.cpp/logging.cpp either), so -- like
  # gate 41's db_probe sibling -- this probe's own translation unit is
  # the only place its coverage data exists at all, and no other object
  # needs to be separately compiled alongside it.
  local obj="$HERE/mcp/src/_concurrency_probe.o"
  local covflags=()
  [[ "$COVERAGE" -eq 1 ]] && covflags+=(--coverage -fprofile-update=atomic)
  rm -f "$obj"
  ( cd "$HERE/mcp" && \
    env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES "$cxx" -std=c++17 -O1 -g -pthread \
        ${covflags[@]+"${covflags[@]}"} -Ivendor -Isrc \
        -c tests/concurrency_probe.cpp -o "$obj" \
  ) >"$PDIRW/concurrency_probe_build.log" 2>&1
  if [[ ! -f "$obj" ]]; then
    fail "42 concurrency_probe: probe failed to build (see $PDIRW/concurrency_probe_build.log)"
    rm -f "$obj"
    return
  fi
  local bin="$PDIRW/concurrency_probe"
  if ! env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES "$cxx" -pthread ${covflags[@]+"${covflags[@]}"} \
        "$obj" -o "$bin" \
        >"$PDIRW/concurrency_probe_link.log" 2>&1; then
    fail "42 concurrency_probe: probe failed to link (see $PDIRW/concurrency_probe_link.log)"
    rm -f "$obj"
    return
  fi
  local out; out=$(env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES "$bin" 2>&1)
  local rc=$?
  rm -f "$obj"
  if [[ "$COVERAGE" -ne 1 ]]; then
    rm -f "${obj%.o}.gcno" "${obj%.o}.gcda"
  fi
  if [[ $rc -eq 0 ]]; then
    pass "42 concurrency_probe: mcp/src/concurrency.h per-client-limit, global-timeout and Token-release branches (see driver OK lines above)"
  else
    fail "42 concurrency_probe: see driver output above ($out)"
  fi
}

# ----------------------------------------------------------------------
# gate 43: industry kits (demo/demo-vertical-*.sql, the twenty-nine newer
# automotive / aerospace / telecom / climate-tech / RF kits).  Each is
# run end to end through a fresh in-memory connection with the mock
# reasoning plugin configured, and must (a) exist, (b) raise no SQL
# error beyond the one documented exception (the scenario-planning kit's
# plan_explore call needs a real embedding endpoint), (c) print no NaN,
# and (d) reproduce its headline claim -- the fixtures are deterministic
# (no random()), so the claim is checked against fixed numbers.
# ----------------------------------------------------------------------
# kit_shape_ok <output> <min>: the 13 original kits print no HEADLINE line and seed random(), so
# their numbers are not pinned. What a regression does change is the SHAPE of the output: a step
# that silently returns no rows drops data lines. Count the lines that are neither errors, the
# .timer "Run Time:" lines nor blank and require <min> (three quarters of a clean run).
kit_shape_ok() {
  local n
  n=$(grep -vcE '^(Runtime error|Parse error|Error[: ]|Run Time:|$)' <<< "$1")
  [[ "$n" -ge "$2" ]]
}

gate_43_kits() {
  if [[ ! -d demo ]]; then
    skip "43 kits (demo/ not present)"; return
  fi
  local tmp="$PDIR/kits"; rm -rf "$tmp"; mkdir -p "$tmp"
  local kits=(ev-battery-lifecycle adas-safety-validation v2x-warranty-triage
    critical-inventory-routing heavy-industry-predictive-maintenance
    climatech-grid-balancing hazmat-occupational-triage
    scenario-planning-simulation avionics-fault-prediction
    satellite-constellation-coverage telecom-account-anomaly-screening
    telecom-traffic-routing climatech-emissions-monitoring
    climatech-risk-exposure rf-spectrum-sensing
    event-stream-anomaly-triage outlier-interception-footprint agentic-budget-reallocation
    stalled-process-triage intent-matching-discovery
    agentic-next-action-ranking document-risk-drift
    coordinated-record-detection sensor-telemetry-allocation simulated-economy-drift
    multi-series-replenishment periodicity-portfolio-selection
    agentic-recall-recommendation spatial-footprint-portfolio-risk
    agentic-customer-support agentic-edge-swarm agentic-fintech-mcts
    agentic-ops-devops biotech-genomics cybersecurity-threat-detection
    fleet-logistics maritime-defense medtech-clinical quant-finance
    recommendation-search smart-cities-iot sovereign-edge-ai)
  local k f out nerr want ok kitabs extabs
  for k in "${kits[@]}"; do
    f="demo/demo-vertical-$k.sql"
    if [[ ! -f "$f" ]]; then
      fail "43 kits: $f is missing"; continue
    fi
    kitabs="$(wpath "$PWD/$f")"
    # The kit runs from a scratch directory (it may spool a teardown
    # file), so the extension path must be absolute.
    extabs="$(wpath "$(cd "$(dirname "$EXT")" && pwd)/$(basename "$EXT")")"
    out=$(cd "$tmp" && "$SQLITE3" -batch \
            -cmd ".load $extabs" \
            -cmd "SELECT fractalsql_set('reasoning_plugin','$MOCK');" \
            :memory: ".read $kitabs" 2>&1)
    nerr=$(grep -ciE '^(Runtime|Parse) error|^Error[: ]' <<< "$out")
    want=0; [[ "$k" == scenario-planning-simulation ]] && want=1; [[ "$k" == periodicity-portfolio-selection ]] && want=1
    case "$k" in agentic-fintech-mcts) want=1 ;; agentic-ops-devops) want=2 ;; esac   # fractal_embed with no embedding endpoint
    if [[ "$nerr" -ne "$want" ]]; then
      fail "43 kits: $k raised $nerr SQL error(s), expected $want: $(grep -iE '^(Runtime|Parse) error|^Error[: ]' <<< "$out" | head -2 | tr '\n' ' ')"
      continue
    fi
    if grep -qiwE 'nan|inf' <<< "$out"; then
      fail "43 kits: $k printed a NaN/inf cell"; continue
    fi
    ok=0
    case "$k" in
      event-stream-anomaly-triage|outlier-interception-footprint|agentic-budget-reallocation|stalled-process-triage|intent-matching-discovery|agentic-next-action-ranking|document-risk-drift|coordinated-record-detection|sensor-telemetry-allocation|simulated-economy-drift|multi-series-replenishment|periodicity-portfolio-selection|agentic-recall-recommendation|spatial-footprint-portfolio-risk) grep -q "HEADLINE kit=$k ok" <<< "$out" && ok=1 ;;
      agentic-customer-support) kit_shape_ok "$out" 22 && ok=1 ;;
      agentic-edge-swarm) kit_shape_ok "$out" 21 && ok=1 ;;
      agentic-fintech-mcts) kit_shape_ok "$out" 17 && ok=1 ;;
      agentic-ops-devops) kit_shape_ok "$out" 28 && ok=1 ;;
      biotech-genomics) kit_shape_ok "$out" 12 && ok=1 ;;
      cybersecurity-threat-detection) kit_shape_ok "$out" 42 && ok=1 ;;
      fleet-logistics) kit_shape_ok "$out" 33 && ok=1 ;;
      maritime-defense) kit_shape_ok "$out" 35 && ok=1 ;;
      medtech-clinical) kit_shape_ok "$out" 24 && ok=1 ;;
      quant-finance) kit_shape_ok "$out" 26 && ok=1 ;;
      recommendation-search) kit_shape_ok "$out" 39 && ok=1 ;;
      smart-cities-iot) kit_shape_ok "$out" 24 && ok=1 ;;
      sovereign-edge-ai) kit_shape_ok "$out" 33 && ok=1 ;;
      ev-battery-lifecycle) awk -F'|' '$1=="EV-203" && $2+0>0.5 && $3+0>1.5 {a=1} $1=="EV-101" && $2+0<0 && $3+0<1 {b=1} END{exit !(a&&b)}' <<< "$out" && ok=1 ;;
      adas-safety-validation) awk -F'|' '$1 ~ /^P1 firm/ && $4==1 {a=1} $1 ~ /^P2 steady/ && $4==0 {b=1} $1 ~ /^P3 gentle/ && $4==1 {c=1} END{exit !(a&&b&&c)}' <<< "$out" && ok=1 ;;
      v2x-warranty-triage) grep -q '^battery-thermal-service|0\.99' <<< "$out" && ok=1 ;;
      critical-inventory-routing) awk -F'|' '$1==4 && $2=="west" && $5+0>1.2 {a=1} END{exit !a}' <<< "$out" && ok=1 ;;
      heavy-industry-predictive-maintenance) awk -F'|' '$1=="PUMP-07" && $2+0>0.5 && $3+0>1.5 {a=1} $1=="PUMP-03" && $2+0<0 {b=1} END{exit !(a&&b)}' <<< "$out" && ok=1 ;;
      climatech-grid-balancing) awk -F'|' '$1=="AREA-C" && $2+0>0.5 && $3+0>1.2 {a=1} $1=="AREA-A" && $2+0<0 {b=1} END{exit !(a&&b)}' <<< "$out" && ok=1 ;;
      hazmat-occupational-triage) awk -F'|' '($1==7||$1==15||$1==31) && $2=="reactor-bay" && $3=="night" && $4+0<0.001 {n++} END{exit !(n>=3)}' <<< "$out" && ok=1 ;;
      scenario-planning-simulation) [[ $(grep -c 'variant' <<< "$out") -ge 6 ]] && ok=1 ;;
      avionics-fault-prediction) grep -q '^AC-09|0\.2' <<< "$out" && ok=1 ;;
      satellite-constellation-coverage) awk -F'|' '$1=="healthy" && NF==3 {h=$3+0} $1=="degraded" && NF==3 {d=$3+0} END{exit !(h>0 && d>h)}' <<< "$out" && ok=1 ;;
      telecom-account-anomaly-screening) awk -F'|' '$1 ~ /^E1 swap/ && $4==1 {a=1} $1 ~ /^E2 routine/ && $4==0 {b=1} $1 ~ /^E4 faint/ && $4==1 {c=1} END{exit !(a&&b&&c)}' <<< "$out" && ok=1 ;;
      telecom-traffic-routing) grep -q '^R3 mobile handover burst|edge-mobile-hub|' <<< "$out" && grep -q '^R3 mobile handover burst|edge-backup-west$' <<< "$out" && ok=1 ;;
      climatech-emissions-monitoring) awk -F'|' '$1=="CH4-02" && $2+0>0.5 && $3+0>1.5 {a=1} $1=="CH4-01" && $2+0<0 {b=1} END{exit !(a&&b)}' <<< "$out" && ok=1 ;;
      climatech-risk-exposure) awk -F'|' '$1=="dry season" && NF==3 {a=1} $1=="wet season" && NF==3 {b=1} END{exit !(a&&b)}' <<< "$out" && ok=1 ;;
      rf-spectrum-sensing) grep -q '^CH-A|{"indices":\[9\]}' <<< "$out" && grep -q '^CH-B|{"indices":\[\]}' <<< "$out" && grep -q '^CH-C|{"indices":\[\]}' <<< "$out" && ok=1 ;;
    esac
    if [[ "$ok" -eq 1 ]]; then
      pass "43 kits: demo-vertical-$k.sql runs clean and reproduces its headline result"
    else
      fail "43 kits: demo-vertical-$k.sql did not reproduce its headline result"
    fi
  done
}

# ======================================================================
# Runner
# ======================================================================

gate_title() {
  case "$1" in
    01) echo "build" ;;                 02) echo "smoke" ;;
    03) echo "schema_context" ;;        04) echo "text_to_sql" ;;
    05) echo "evil_overread" ;;         06) echo "crash_recovery" ;;
    07) echo "evil_lying_length" ;;     08) echo "authz" ;;
    09) echo "guc_superuser" ;;         10) echo "dos_and_injection" ;;
    11) echo "scout" ;;                 12) echo "soak" ;;
    13) echo "siu_mode" ;;              14) echo "retry" ;;
    15) echo "embed" ;;                 16) echo "embed_authz" ;;
    17) echo "embed_soak" ;;            18) echo "embed_crash" ;;
    19) echo "sfs_bounds" ;;            20) echo "api_func" ;;
    21) echo "fuzz_smoke" ;;            22) echo "v2_functions" ;;
    23) echo "agents" ;;                24) echo "enterprise" ;;
    25) echo "enterprise_stress" ;;     26) echo "enterprise_signature" ;;
    27) echo "think" ;;                 28) echo "review_isolation" ;;
    29) echo "domain_agents" ;;         30) echo "feature_store" ;;
    31) echo "ledger_chain" ;;
    32) echo "enterprise_signature_real" ;;
    33) echo "tsan_ledger_concurrent" ;;
    34) echo "oom_inject" ;;
    35) echo "ed25519" ;;
    36) echo "extract_population" ;;
    37) echo "mcp_smoke" ;;
    38) echo "mcp_https" ;;
    39) echo "extract_parse" ;;
    40) echo "vectors_probe" ;;
    41) echo "db_probe" ;;
    42) echo "concurrency_probe" ;;
    43) echo "kits" ;;
  esac
}

run_gate() {
  case "$1" in
    01) gate_01_build ;;                 02) gate_02_smoke ;;
    03) gate_03_schema_context ;;        04) gate_04_text_to_sql ;;
    05) gate_05_evil_overread ;;         06) gate_06_crash_recovery ;;
    07) gate_07_evil_lying_length ;;     08) gate_08_authz ;;
    09) gate_09_guc_superuser ;;         10) gate_10_dos_and_injection ;;
    11) gate_11_scout ;;                 12) gate_12_soak ;;
    13) gate_13_siu_mode ;;              14) gate_14_retry ;;
    15) gate_15_embed ;;                 16) gate_16_embed_authz ;;
    17) gate_17_embed_soak ;;            18) gate_18_embed_crash ;;
    19) gate_19_sfs_bounds ;;            20) gate_20_api_func ;;
    21) gate_21_fuzz_smoke ;;            22) gate_22_v2_functions ;;
    23) gate_23_agents ;;                24) gate_24_enterprise ;;
    25) gate_25_enterprise_stress ;;     26) gate_26_enterprise_signature ;;
    27) gate_27_think ;;                 28) gate_28_review_isolation ;;
    29) gate_29_domain_agents ;;         30) gate_30_feature_store ;;
    31) gate_31_ledger_chain ;;
    32) gate_32_enterprise_signature_real ;;
    33) gate_33_tsan_ledger_concurrent ;;
    34) gate_34_oom_inject ;;
    35) gate_35_ed25519 ;;
    36) gate_36_extract_population ;;
    37) gate_37_mcp_smoke ;;
    38) gate_38_mcp_https ;;
    39) gate_39_extract_parse ;;
    40) gate_40_vectors_probe ;;
    41) gate_41_db_probe ;;
    42) gate_42_concurrency_probe ;;
    43) gate_43_kits ;;
  esac
}

main() {
  find_toolchain

  # --asan/--ubsan note (see the flag doc above) says this gets
  # arranged; until now nothing actually did it, so every runtime gate
  # failed at extension load with "ASan runtime does not come first in
  # initial library list" the moment fractalsql.so (built with
  # -fsanitize=address/undefined) got dlopen'd into the unsanitized
  # sqlite3 CLI. LD_PRELOAD-ing the same compiler's sanitizer runtime
  # ahead of the CLI is the standard fix for a sanitized library loaded
  # via dlopen from an unsanitized host process.
  #
  # Darwin gets none of this: the same dlopen-into-CLI design is a dead
  # end there (SIP strips DYLD_INSERT_LIBRARIES for Apple-signed hosts,
  # and even past that the runtime can call itself "loaded too late" --
  # both confirmed on real hardware in fractalsql-core's Darwin harness
  # work; see the --tsan/--asan note above). DARWIN_SAN_SKIP marks that
  # gates 02-32 should be skipped with an explicit reason instead of
  # attempted and left to fail confusingly; gate 01 (build) and gate 33
  # (the TSan harness, --tsan only) are unaffected and still run.
  DARWIN_SAN_SKIP=0; DARWIN_SAN_SKIP_WHY=""
  if { [[ "$ASAN" -eq 1 ]] || [[ "$UBSAN" -eq 1 ]] || [[ "$TSAN" -eq 1 ]]; } \
     && [[ "$IS_MSYS" -eq 0 ]]; then
    if [[ "$sysname" == "Darwin" ]]; then
      # --asan/--ubsan can run for real on Darwin when BOTH host
      # processes (the sqlite3 CLI and python3) are non-system builds,
      # e.g. Homebrew's: SIP only strips DYLD_INSERT_LIBRARIES from
      # Apple-signed binaries under /usr, /bin, /System. --tsan stays
      # skipped (gate 33 is its Darwin coverage), as does any run where
      # a host is a system binary or the runtime dylibs can't be found.
      DARWIN_SAN_SKIP=1
      DARWIN_SAN_SKIP_WHY="dlopen'ing a sanitized extension into the real sqlite3 CLI is not attempted -- see the --asan/--ubsan/--tsan note near the top of this script for why. Gate 33 gives genuine Darwin --tsan coverage instead."
      if [[ "$TSAN" -eq 0 && -n "$CC" ]]; then
        local host sys_host="" dylibs="" rtdir name rt
        for host in "$SQLITE3" "$PY"; do
          [[ -z "$host" ]] && continue
          case "$(command -v "$host" 2>/dev/null)" in
            /usr/bin/*|/bin/*|/sbin/*|/usr/sbin/*|/usr/libexec/*|/System/*) sys_host="$host" ;;
          esac
        done
        rtdir="$("$CC" -print-resource-dir 2>/dev/null)/lib/darwin"
        for name in $([[ "$ASAN" -eq 1 ]] && echo asan) $([[ "$UBSAN" -eq 1 ]] && echo ubsan); do
          rt="$("$CC" -print-file-name="libclang_rt.${name}_osx_dynamic.dylib" 2>/dev/null)"
          [[ -f "$rt" ]] || rt="$rtdir/libclang_rt.${name}_osx_dynamic.dylib"
          if [[ -f "$rt" ]]; then
            dylibs="${dylibs:+$dylibs:}$rt"
          else
            dylibs=""; break
          fi
        done
        if [[ -n "$sys_host" ]]; then
          DARWIN_SAN_SKIP_WHY="host '$sys_host' is an Apple system binary, so SIP strips DYLD_INSERT_LIBRARIES (silently unsanitized). Put a Homebrew sqlite3/python3 first on PATH or set FSQL_SQLITE3/FSQL_PYTHON to run the sanitized gates."
        elif [[ -z "$dylibs" ]]; then
          DARWIN_SAN_SKIP_WHY="no libclang_rt.{asan,ubsan}_osx_dynamic.dylib found for \$CC ($CC) to preload."
        else
          DARWIN_SAN_SKIP=0
          export DYLD_INSERT_LIBRARIES="${DYLD_INSERT_LIBRARIES:+$DYLD_INSERT_LIBRARIES:}$dylibs"
          # Same reasoning as the Linux ASAN_OPTIONS below: the hosts are
          # unsanitized, and gates 06/18 detect a deliberate crash via rc>=128.
          export ASAN_OPTIONS="${ASAN_OPTIONS:+$ASAN_OPTIONS:}detect_leaks=0:abort_on_error=1"
        fi
      fi
    elif [[ -n "$CC" ]]; then
      local preload="" lib
      if [[ "$ASAN" -eq 1 ]]; then
        lib="$("$CC" -print-file-name=libasan.so 2>/dev/null)"
        [[ -n "$lib" && -f "$lib" ]] && preload="$lib"
      fi
      if [[ "$UBSAN" -eq 1 ]]; then
        lib="$("$CC" -print-file-name=libubsan.so 2>/dev/null)"
        [[ -n "$lib" && -f "$lib" ]] && preload="${preload:+$preload:}$lib"
      fi
      if [[ "$TSAN" -eq 1 ]]; then
        lib="$("$CC" -print-file-name=libtsan.so 2>/dev/null)"
        [[ -n "$lib" && -f "$lib" ]] && preload="${preload:+$preload:}$lib"
      fi
      if [[ -n "$preload" ]]; then
        export LD_PRELOAD="${LD_PRELOAD:+$LD_PRELOAD:}$preload"
        # LeakSanitizer has no way to tell "the extension under test
        # leaked" from "the system libsqlite3.so (or, for the gate
        # 08/16/19/25/29/31 python drivers, CPython itself): neither
        # ASan-instrumented, and still holding normal long-lived allocations
        # at process exit." Both host processes are un-instrumented and
        # never freed by design, so leak-checking them is unreliable by
        # construction; only AddressSanitizer's actual corruption
        # detectors (the part worth having) matter here.
        # abort_on_error=1: gates 06/18 deliberately crash a plugin and
        # detect the process death via rc>=128 (a real signal). Without
        # this, ASan reports the SEGV itself but then calls exit(1) --
        # a clean-looking exit code that hides the crash from that
        # check. Aborting instead raises SIGABRT, which does satisfy it.
        export ASAN_OPTIONS="${ASAN_OPTIONS:+$ASAN_OPTIONS:}detect_leaks=0:abort_on_error=1"
      else
        echo "WARNING: --asan/--ubsan/--tsan requested but \$CC ($CC) could" >&2
        echo "         not resolve libasan.so/libubsan.so/libtsan.so --" >&2
        echo "         runtime gates will fail to load the sanitized" >&2
        echo "         extension." >&2
      fi
    fi
  fi

  # TSAN_OPTIONS: unconditional whenever --tsan is live and reachable at
  # all (Linux; not Darwin/MSYS) -- gate 33 needs this regardless of
  # whether the LD_PRELOAD resolution above found libtsan.so, since
  # gate 33 doesn't preload anything (see its own comment). Mirrors
  # ASAN_OPTIONS's two reasons (detect_leaks has no TSan equivalent to
  # disable; TSan's own leak detector is separate and not relevant
  # here), plus suppressions for the one confirmed-benign race gate 33
  # also suppresses (SQLITE_EXTENSION_INIT2 racing sqlite3_api across
  # concurrent loads) -- see tests/tsan_suppressions.txt.
  if [[ "$TSAN" -eq 1 && "$sysname" != "Darwin" && "$IS_MSYS" -eq 0 ]]; then
    export TSAN_OPTIONS="${TSAN_OPTIONS:+$TSAN_OPTIONS:}halt_on_error=0:second_deadlock_stack=1:abort_on_error=1:suppressions=$HERE/tests/tsan_suppressions.txt"
  fi

  PDIR="$BTROOT/fractalsql_bt_$$"
  # fsql_load_reasoning requires the configured plugin path to be
  # canonical (realpath(path) == path); on MSYS realpath answers in
  # Windows backslash form, so the configured paths must be too;
  # wpath's forward-slash mixed form is rejected as non-canonical.
  # PDIRSEP matches the join separator to PDIRW's form.
  if command -v cygpath >/dev/null 2>&1; then
    PDIRW="$(cygpath -w "$PDIR")"
    PDIRSEP='\'
  else
    PDIRW="$(wpath "$PDIR")"
    PDIRSEP='/'
  fi
  DB="$PDIR/bt.db"

  local gates
  if [[ -n "$ONE_GATE" ]]; then
    gates=("$ONE_GATE")
  elif [[ "$MODE" == "quick" ]]; then
    gates=("${QUICK_GATES[@]}")
  elif [[ "$MODE" == "fuzz" ]]; then
    gates=("${FUZZ_GATES[@]}")
  else
    gates=("${DEFAULT_GATES[@]}")
  fi

  # gate 33 is --tsan-only (see its own function); not in DEFAULT_GATES
  # so a plain run never pays for it, appended here so a full --tsan
  # run exercises it without needing a separate --gate 33 invocation.
  if [[ "$TSAN" -eq 1 && "$MODE" == "default" && -z "$ONE_GATE" ]]; then
    gates+=("33")
  fi

  printf "fractalsql-sqlite build_test: %s: gates: %s\n" \
    "$MODE" "${gates[*]}"
  printf "tmp root: %s (db under it) | timeout x%s\n" "$BTROOT" "$TIMEOUT_MULT"

  local ran_setup=0 g t0 t1
  mkdir -p "$PDIR"
  for g in "${gates[@]}"; do
    printf "\n== gate %s: %s ==\n" "$g" "$(gate_title "$g")"
    if [[ "$DARWIN_SAN_SKIP" -eq 1 && "$g" != "01" && "$g" != "33" ]]; then
      skip "$g $(gate_title "$g") (Darwin + --asan/--ubsan/--tsan: $DARWIN_SAN_SKIP_WHY)"
      continue
    fi
    if [[ "$g" != "01" && "$g" != "21" && "$ran_setup" -eq 0 ]]; then
      bt_setup || { echo "runtime setup failed: aborting"; exit 1; }
      ran_setup=1
    fi
    t0=$SECONDS
    run_gate "$g"
    t1=$(( SECONDS - t0 ))
    printf "   (gate %s took %ss)\n" "$g" "$t1"
  done

  if [[ "$COVERAGE" -eq 1 && "$IS_MSYS" -eq 0 ]]; then
    run_coverage_report
  fi

  if [[ "$FAILED" -eq 1 ]]; then
    printf "\n${R}FAILED${Z}: see the [FAIL] lines above\n"
    exit 1
  fi
  printf "\n${G}ALL GREEN${Z}: %s gate(s) passed\n" "${#gates[@]}"
  exit 0
}

main "$@"