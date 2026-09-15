#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#
# build_test.sh — post-build validation gate runner for
# fractalsql-sqlite. Mirrors what CI runs, so local == CI.
#
# Builds (or accepts a prebuilt) extension and validates it against a
# THROWAWAY fixture database (a plain file under the temp root, opened
# in WAL mode and torn down on exit) — no server install, no root.
#
# 27 numbered gates; the structural rationale for each is documented
# per gate below.
#
# Gates:
#   01  build          make (or accept a prebuilt artifact)             ~5s
#   02  smoke          load + version + fractal_search convergence     ~5s
#   03  schema_context introspection (PK / NOT NULL / FK)              ~3s
#                      (re-aim: no COMMENT analog — SQLite tables have
#                       no comments; PK/FK/NOT NULL assertions kept)
#   04  text_to_sql    allowlist fuzz matrix + never-executes proof    ~8s
#                      (uses tests/mock_reasoning_plugin.c)
#   05  evil_overread  guard-page non-terminated response survives,    ~3s
#                      at GENERATE, REVIEW, and bare fractal_reason()
#                      (uses tests/evil_nonterminating_plugin.c;
#                      re-aim: a crash kills the sqlite3 PROCESS —
#                      detected by abnormal exit without a clean SQL
#                      error — instead of dropping a PG connection)
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
#                      path validation — stock SQLite cannot gate
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
#                      analog here — the BEGIN IMMEDIATE claim's
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
#                      embedding_array (highest priority — parses
#                      fractal_embed()'s raw response from whatever
#                      endpoint http_embed_url points at, genuinely
#                      externally-adversarial input),
#                      fsql_extract_best_point and
#                      fsql_extract_population (parse the vendored
#                      core's own result JSON — lower risk, included
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
#                      documented N/A — they belong to reasoning/
#                      feature-store TUs that are not ported)
#   23  agents         the registered C agents with a reasoning canary:
#                      search_agent/rag_agent (embed -> scout ->
#                      reason composition), sql_agent, plan_explore,
#                      trajectory_predict, detect_loop, telemetry,
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
#                      against the real primitives they compose
#   31  ledger_chain   fractalsql_ledger's append-only hash chain
#                      (src/fsql_ledger.c): a built chain verifies
#                      clean, a mutated row and a deleted middle row
#                      are both caught by fractal_ledger_verify(), the
#                      old snapshot-shape table migrates to the chain
#                      shape on first touch, kind=1/kind=2 chains stay
#                      independent, and fractal_audit_log now carries
#                      the same enterprise gate as the rest of the
#                      ledger surface (PG parity)
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
#                      other gates use — see the --tsan note below for
#                      why that approach doesn't reach Darwin at all.
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
#                           --asan/--ubsan, 6 under --tsan — set this
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
# (PG's GCOV_PREFIX dance exists because postgres backends run from a
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
# realpath(path) != path — a defense against symlink pivots (see its
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
# against the process's CURRENT DRIVE — so on Windows the harness pins
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
    echo "ERROR: cannot create $BTROOT — the fixture plugins hardcode" >&2
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
# so it's the right base — a bare POSIX "/..." literal or a hardcoded
# "C:/..." literal each work on only one of the two platforms.
BADPLUGIN="$BTROOTW/fractalsql_bt_nonexistent_plugin"

# wpath <posix-path> — Windows-mixed form (C:/...) when running under
# MSYS against native binaries; identity elsewhere.
wpath() {
  if [[ "$IS_MSYS" -eq 1 ]] && command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$1"
  else
    printf '%s' "$1"
  fi
}

DEFAULT_GATES=(01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20 22 23 24 25 26 27 28 29 30 31 32)
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
fail() { local msg="$1"; printf "  [${R}FAIL${Z}] %s\n" "$msg"; FAILED=1; return 0; }
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
MOCK=""; EVILNT=""; LYING=""; CRASH=""; RETRY=""; THINK=""; MOCKEMB=""; EVOLEMB=""
FAILED=0

# Fixed file contracts the fixture plugins hardcode (see each plugin's
# header comment). The plugins run inside the host process and do their
# own fopen()s, so the harness must write these through BTROOT (whose
# CRT-resolved location is $BTROOTW on Windows) — NOT through a path
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
    # loading (SQLITE_OMIT_LOAD_EXTENSION) — ".load" is not even a
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

# resolve_ext — locate the built extension when gate 01 did not run
# (single --gate invocations, fuzz-only runs). Sets EXT/EXTW or fails.
resolve_ext() {
  [[ -n "$EXT" ]] && return 0
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
# fractalsql_set() preamble — the SQLite analog of pg_set_guc().
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
    fail "runtime setup: no extension found — run gate 01 or set FSQL_EXT"; return 1
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
              mock_embed_plugin evil_embed_plugin; do
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
}

# Skip a gate whose fixture plugin did not compile (platform-limited
# plugin, e.g. evil_nonterminating's mmap/mprotect on a host without
# them) — the same probe-compile posture the PG runner takes.
have_plugin() { [[ -f "$(wpath "$1")" ]]; }

# py_run <name> [args...] — run an embedded python driver; each driver
# is written to $PDIR and receives the DB/extension paths via env.
py_run() {
  local name="$1"; shift
  FSQL_BT_DB="$DBW" FSQL_BT_EXT="$EXTW" "$PY" "$PDIRW/$name.py" "$@"
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
    || { fail "coverage: lcov capture failed — see $TMPROOT/fractalsql_bt_lcov.log"; return; }

  # Extract just our TUs: the capture also picks up the handful of
  # lines pulled in from sqlite3ext.h etc. -- those aren't our code and
  # nobody's asking about their coverage anyway. Multi-TU here (PG's
  # is a single src/fractalsql.c), hence the wildcard.
  lcov --extract "$TMPROOT/fractalsql_bt_coverage_raw.info" '*/src/*' \
       --output-file "$TMPROOT/fractalsql_bt_coverage.info" \
       --rc branch_coverage=1 >>"$TMPROOT/fractalsql_bt_lcov.log" 2>&1

  echo ""
  echo "=== coverage (src/*.c) ==="
  # Computed directly from the .info file's own LF/LH/FNF/FNH/BRF/BRH
  # totals rather than `lcov --list`'s table -- lcov 2.0-1's --list
  # renderer miscomputes its Rate% column against this intermediate
  # gcov-JSON-derived .info (seen in the PG runner: a nonsensical
  # 1170% function rate) even though the underlying LF:/LH:/etc.
  # totals, and genhtml's own report built from the same file, are
  # both correct.
  awk -F: '
    /^LF:/ { lf += $2 } /^LH:/ { lh += $2 }
    /^FNF:/ { fnf += $2 } /^FNH:/ { fnh += $2 }
    /^BRF:/ { brf += $2 } /^BRH:/ { brh += $2 }
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
            --rc branch_coverage=1 >"$TMPROOT/fractalsql_bt_genhtml.log" 2>&1 \
      && pass "coverage: report at coverage_html/index.html" \
      || fail "coverage: genhtml failed — see $TMPROOT/fractalsql_bt_genhtml.log"
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
    # driven by build_test.ps1 — this POSIX runner mirrors the gates on
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
    fail "01 build — see $TMPROOT/fractalsql_bt_build.log"
    # Surface the real diagnostics: linker errors often carry no
    # "error:" string — ld64 prints "ld: unknown option: ...",
    # "Undefined symbols for architecture arm64:", "ld: library not
    # found for ...", and MSVC prints "error LNK2001:" — so matching
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
  [[ "$ver" = "2.0.0" ]] \
    && pass "02 smoke: version=$ver" \
    || fail "02 smoke: version='$ver' (want 2.0.0)"
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
  # (not just the best_point extraction fractal_search uses) — assert
  # the best_point key survives. Signature here is
  # fractal_search_debug(query [, iterations, population_size,
  # diffusion_factor]) — a single query vector, run fresh.
  local dbg; dbg=$(sqlq "SELECT fractal_search_debug('0.6,0.8,0.0,0.0');")
  grep <<< "$dbg" -q "best_point" \
    && pass "02 smoke: fractal_search_debug has best_point" \
    || fail "02 smoke: fractal_search_debug='$dbg'"
}

# bash has no float compare — a one-shot python float check (skipped
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
  # in sql/fractalsql--1.0.sql) — no comment assertion here.
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
  local n; n=$("$SQLITE3" "$DBW" "SELECT count(*) FROM bt_orders;" 2>&1)
  [[ "$n" = "0" ]] \
    && pass "04 never-executes (bt_orders still empty)" \
    || fail "04 never-executes: row count=$n"
  # auto-discovery: the full GENERATE -> ALLOWLIST -> prepare pipeline
  # works off the auto-built schema context (0-arg registration), not
  # just an explicit table list (the PG version's table_names arg —
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
# so "survived" means the process exited (rc==0 or a clean SQL error) —
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
  # in-process plugin — one env-visibility advantage over PG's forked
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
      fail "07 $label — process crashed — $r"
    elif grep <<< "$r" -q "implausible response length"; then
      pass "07 $label rejected cleanly"
    else
      fail "07 $label — expected rejection, got: $r"
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
# honored INSIDE the extension's own introspection — a denied read on a
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

# Boundary: deny the introspection of bt_customers — both the PRAGMA
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
  # Re-aim of PG's non-superuser GUC rejection: the same boundary is
  # enforced at fractalsql_set time — a path key must be absolute with
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
  # at set time — set-time validation only).
  local r; r=$(sqlq "SELECT fractalsql_set('reasoning_plugin','$MOCK');")
  [[ "$r" == "ok" ]] \
    && pass "09 guc_superuser: canonical absolute path accepted" \
    || fail "09 guc_superuser: canonical path rejected: $r"
}

gate_10_dos_and_injection() {
  # 512-cap fires via DISCOVERY (513 tables in the DB), not an array
  # argument — fractal_schema_context() is 0-arg here.
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
  # Drop the flood before the injection case — the cap fires at
  # discovery time and would mask it otherwise.
  {
    for i in $(seq 0 512); do
      printf 'DROP TABLE bt_dos_%s;\n' "$i"
    done
  } | "$SQLITE3" "$DBW" >/dev/null 2>&1
  # An injection-shaped table name can be created literally (quoted);
  # schema_context must NOT carry it into SQL text — introspection is
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
    || fail "10 dos_and_injection: bt_customers missing — injection executed"
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
  # fractal_embed() itself — real dispatch through the EMBED tier.
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
  # double-create MUST ride the same connection — the registry+queue
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
  # maps to these guards — role grants have no SQLite analog).
  # A nonexistent table is indistinguishable from a PK-less one here:
  # PRAGMA table_info on a missing table returns no rows, so the create
  # answers the same "no single-column primary key" error (the probe
  # PRAGMA doesn't fail on a missing table — SQLite's shape).
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
  # died with the connection — no stuck-'processing' rows are even
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
  # rejection is exercised through the float32 BLOB path — a
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
  # bare call gets the fenced form — RESPONSE_MODE is t2s-internal).
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
  if expect_err "expects a TEXT question" \
      "SELECT fractal_text_to_sql(NULL);"; then
    pass "20 api_func: fractal_text_to_sql(NULL) rejected"
  else
    fail "20 api_func: fractal_text_to_sql(NULL) not rejected"
  fi
  # Options-JSON: the params surface is LENIENT here — a truncated JSON
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
}

# find_fuzz_clang — locate a clang that can actually LINK a
# -fsanitize=fuzzer binary, probed by compiling a real minimal
# libFuzzer target (defines LLVMFuzzerTestOneInput, no main of its
# own — libFuzzer's runtime supplies main) rather than trusting
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
    skip "21 fuzz_smoke (no clang on PATH with a working -fsanitize=fuzzer — checked \$FSQL_FUZZ_CC, clang, clang-15..19, and common LLVM install paths)"; return
  fi
  local t src rc
  for t in fuzz_parse_embedding_array fuzz_extract_best_point \
           fuzz_extract_population; do
    src="tests/fuzz/$t.c"
    if ! "$fuzzcc" -O1 -g -fsanitize=fuzzer -Iinclude -Isrc \
          "$src" src/fsql_parse.c -o "$PDIRW/$t" \
          >"$PDIR/$t.log" 2>&1; then
      fail "21 fuzz_smoke: $t failed to build — see $PDIR/$t.log"
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
      fail "21 fuzz_smoke: $t exited rc=$rc — see $PDIR/$t.run.log"
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
  # Drift: 200-point series, window 64 — the core's box needs window+16
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
  # >= 3 valid epsilon buckets — enough points AND enough scale dynamic
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
  r=$(sqlq "SELECT fractal_search_telemetry(
              'bt_telemetry', 'vec', '0.6,0.8,0.0,0.0', 2);")
  if [[ $? -eq 0 ]] && grep <<< "$r" -q "id"; then
    pass "22 v2_functions: search_telemetry returns ground-truth rows"
  else
    fail "22 v2_functions: telemetry: $r"
  fi
  if expect_err "k must be > 0" \
      "SELECT fractal_search_telemetry('bt_telemetry','vec',
        '0.6,0.8,0.0,0.0', 0);"; then
    pass "22 v2_functions: telemetry k<=0 rejected"
  else
    fail "22 v2_functions: telemetry k<=0 accepted"
  fi
  r=$(sqlq "SELECT fractal_search_trajectory(
              'bt_traj', 'vec', '0.0,0.0,0.0,0.0',
              '0.3,0.0,0.0,0.0', 3);")
  if [[ $? -eq 0 ]] && grep <<< "$r" -q "{"; then
    pass "22 v2_functions: search_trajectory returns JSON"
  else
    fail "22 v2_functions: search_trajectory: $r"
  fi
  r=$(sqlq "SELECT fractal_explain_result();" \
            "SELECT fractal_detect_collapse();")
  if [[ $? -eq 0 ]]; then
    pass "22 v2_functions: explain_result/detect_collapse respond"
  else
    fail "22 v2_functions: explain/detect_collapse: $r"
  fi
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
      fail "23 $label — process crashed"
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
  agent "sql_agent T2S composition" \
    "SELECT fractal_sql_agent('count the orders');"
  grep <<< "$LAST_AGENT_OUT" -q '"generated_sql"' \
    && pass "23 sql_agent returns the composite JSON" \
    || fail "23 sql_agent JSON: $LAST_AGENT_OUT"
  agent "plan_explore MCTS branches" \
    "SELECT fractal_agent_plan_explore('1.0,0.0,0.0',
      'bt_agent_docs','emb', 2);"
  grep <<< "$LAST_AGENT_OUT" -q '"branch_id"' \
    && pass "23 plan_explore returns branch plans" \
    || fail "23 plan_explore JSON: $LAST_AGENT_OUT"
  agent "trajectory_predict over telemetry" \
    "SELECT fractal_agent_trajectory_predict('bt_traj','vec',3,2);"
  agent "detect_loop monitors a series" \
    "SELECT fractal_agent_detect_loop(
       '0.0,0.1,0.2,0.3,0.4,0.5,0.6,0.7,0.8,0.9,0.0,0.1,
        0.2,0.3,0.4,0.5,0.6,0.7,0.8,0.9,0.0,0.1,0.2,0.3');"
  grep -Eq '"is_loop_detected":(true|false)' <<< "$LAST_AGENT_OUT" \
    && pass "23 detect_loop returns the verdict" \
    || fail "23 detect_loop JSON: $LAST_AGENT_OUT"
  agent "telemetry + trajectory + hybrid + cross_modal + explain" \
    "SELECT fractal_search_telemetry('bt_agent_docs','emb',
       '1.0,0.0,0.0', 2);" \
    "SELECT fractal_hybrid_clinical_search('bt_agent_docs','emb',
       '1.0,0.0,0.0', '1,2,3', 2);" \
    "SELECT fractal_cross_modal_search('bt_agent_docs_xmodal','emb',
       '1.0,0.0,0.0', '0.0,1.0,0.0', 0.5, 2);" \
    "SELECT fractal_explain_result();"
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
  agent_err "no-rows guard" \
    "no rows found in bt_agent_empty.emb" \
    "SELECT fractal_search_agent('q','bt_agent_empty','emb');"
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
  # ledger surface (PG parity fix — see gate 31 ledger_chain, which owns
  # this behavior in detail; previously this wrote unconditionally, a
  # real parity gap against PG's own ensure_enterprise_lib() check).
  if expect_err "enterprise tier not loaded" \
      "SELECT fractal_audit_log('entry', '{}');"; then
    pass "24 enterprise: audit_log rejects cleanly (dormant tier)"
  else
    fail "24 enterprise: audit_log did not surface the dormant-tier error"
  fi
  # A bogus enterprise_lib must be an absolute path (the same set-time
  # path validation as the plugin keys — $BADPLUGIN is already native-
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
      || fail "27 think: $label — dump: $(cat "$(wpath "$THINKDUMP")" 2>/dev/null)"
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
      || fail "28 review_isolation: $label — dump: $(cat "$(wpath "$REVIEWDUMP")" 2>/dev/null)"
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

  # --- 2: fractal_agent_recall_hybrid (pure retrieval, cohort filter,
  # no LLM) -- the exact case a prior cohort-building bug broke (row_
  # number computed after WHERE-filtering instead of over the full
  # table), so this also guards that regression.
  local r3; r3=$(sqlq \
    "SELECT fractal_agent_recall_hybrid('bt_da_mem','emb','1.0,0.0,0.0','kind','a',5,'id','body');")
  [[ "$r3" == *'"mem_id":1'* && "$r3" == *'"mem_id":3'* && "$r3" != *'"mem_id":2'* ]] \
    && pass "29 domain_agents: recall_hybrid cohort filter includes only kind='a' rows" \
    || fail "29 domain_agents: expected mem_id 1 and 3 only (not 2), got: $r3"

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
# enterprise-gated (PG parity) and shares the same entry_hash/prev_hash
# recompute logic ledger_verify_tip uses for the O(1) load-time check --
# so this is real coverage of the chain algorithm itself, just entered
# from a different call site than fractal_ledger_flush/load. A checkout
# with a vendored enterprise core would additionally get full end-to-end
# coverage through gate 25 (self-skips here for the same reason).
write_py_gate31() {
  cat > "$PDIR/py_gate31.py" <<'PYEOF'
import os, sqlite3, sys, hashlib

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
    eh = hashlib.sha256(prev + payload).digest()
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
  # NOT enterprise-gated (PG parity: a pure read-only forensic query) --
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
    fail "33 tsan_ledger_concurrent: harness build failed — see $TMPROOT/fractalsql_bt_tsan_runner_build.log"
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
    fail "33 tsan_ledger_concurrent: rc=$rc — $out"
  fi
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
  DARWIN_SAN_SKIP=0
  if { [[ "$ASAN" -eq 1 ]] || [[ "$UBSAN" -eq 1 ]] || [[ "$TSAN" -eq 1 ]]; } \
     && [[ "$IS_MSYS" -eq 0 ]]; then
    if [[ "$sysname" == "Darwin" ]]; then
      DARWIN_SAN_SKIP=1
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
        # 08/16/19/25/29/31 python drivers, CPython itself) — neither
        # ASan-instrumented — still holds normal long-lived allocations
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
  # Windows backslash form, so the configured paths must be too —
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

  # gate 33 is --tsan-only (see its own function) — not in DEFAULT_GATES
  # so a plain run never pays for it, appended here so a full --tsan
  # run exercises it without needing a separate --gate 33 invocation.
  if [[ "$TSAN" -eq 1 && "$MODE" == "default" && -z "$ONE_GATE" ]]; then
    gates+=("33")
  fi

  printf "fractalsql-sqlite build_test — %s — gates: %s\n" \
    "$MODE" "${gates[*]}"
  printf "tmp root: %s (db under it) | timeout x%s\n" "$BTROOT" "$TIMEOUT_MULT"

  local ran_setup=0 g t0 t1
  mkdir -p "$PDIR"
  for g in "${gates[@]}"; do
    printf "\n== gate %s: %s ==\n" "$g" "$(gate_title "$g")"
    if [[ "$DARWIN_SAN_SKIP" -eq 1 && "$g" != "01" && "$g" != "33" ]]; then
      skip "$g $(gate_title "$g") (Darwin + --asan/--ubsan/--tsan: dlopen'ing a sanitized extension into the real sqlite3 CLI is not attempted -- see the --asan/--ubsan/--tsan note near the top of this script for why. Gate 33 gives genuine Darwin --tsan coverage instead.)"
      continue
    fi
    if [[ "$g" != "01" && "$g" != "21" && "$ran_setup" -eq 0 ]]; then
      bt_setup || { echo "runtime setup failed — aborting"; exit 1; }
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
    printf "\n${R}FAILED${Z} — see the [FAIL] lines above\n"
    exit 1
  fi
  printf "\n${G}ALL GREEN${Z} — %s gate(s) passed\n" "${#gates[@]}"
  exit 0
}

main "$@"