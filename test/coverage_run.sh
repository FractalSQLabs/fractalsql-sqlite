#!/usr/bin/env bash
# test/coverage_run.sh -- line, function and branch coverage of the extension's own sources (src/*.c), measured with gcov on a
# COVERAGE=1 build of a COPY of the tree (dist/cov, so the repo's own objects and fractalsql.so are left alone) while the existing
# suites and the extra drivers drive it.
#
# Stages (STAGES="build gates edge oom unit report"; default all):
#   build    copy Makefile, src, include and deps to dist/cov and make COVERAGE=1 there (the previous counters are deleted)
#   gates    build_test.sh --gate N for the runtime gates, against the instrumented extension (FSQL_EXT)
#   edge     test/edge_inputs.py: every registered function x awkward arguments; configured, bare and misbehaving plugin
#   oom      test/oom_sweep.py: every allocation the extension makes while a demo kit runs is failed in turn
#   unit     the header-level / standalone probes (ed25519, the reply parsers) and the fuzz corpora replayed, built with --coverage
#   report   per-file table and totals (test/gcov_summary.py); exit status is the threshold verdict
#
# Counters accumulate across stages and processes. A process that dies on a signal writes none.
# Env: COV_MIN (floor for lines, functions and branches; default 80), COV_GATES (gate numbers), OOM_MAX_TRIALS (default 40),
# COV_FUZZ_MUTANTS (default 40).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT"
STAGES="${STAGES:-build gates edge mutate oom unit report}"
COVDIR="$ROOT/dist/cov"
GATES="${COV_GATES:-02 03 04 05 06 07 08 09 10 11 13 14 15 16 17 18 19 20 22 23 24 25 26 27 28 29 30 31 32 34 35 36 39 43}"
TMPROOT="${TMPDIR:-/tmp}"
has() { case " $STAGES " in *" $1 "*) return 0 ;; esac; return 1; }
say() { printf '\n== coverage: %s\n' "$*"; }

if has build; then
  say "build (make COVERAGE=1 in dist/cov)"
  rm -rf "$COVDIR"; mkdir -p "$COVDIR"
  cp -r Makefile src include deps "$COVDIR/" 2>/dev/null
  nice make -C "$COVDIR" COVERAGE=1 >"$TMPROOT/fsql_cov_build.log" 2>&1 || { tail -20 "$TMPROOT/fsql_cov_build.log"; exit 1; }
fi
has build && find "$COVDIR" -name "*.gcda" -delete 2>/dev/null   # the build leaves no counters of its own; a stale one makes libgcov refuse to merge
COVEXT="$COVDIR/fractalsql.so"
[ -f "$COVEXT" ] || { echo "no instrumented extension at $COVEXT (run the build stage)"; exit 1; }

if has gates; then
  say "gates: $GATES"
  for g in $GATES; do
    out="$(FSQL_EXT="$COVEXT" nice ./build_test.sh --gate "$g" 2>&1)"
    printf '%s\n' "$out" | grep -E 'ALL GREEN|FAILED' | sed "s/^/  gate $g: /"
    printf '%s\n' "$out" | grep -E '\[FAIL\]' | head -5
  done
fi

if has edge; then
  say "edge inputs (default environment)"
  FSQL_EXT="$COVEXT" nice python3 -I test/edge_inputs.py 2>&1 | tail -3
  for variant in "FSQL_AUDIT_REDACT=hash" "FSQL_AUDIT_REDACT=truncate" "FSQL_LEDGER_ANCHOR_LOG=stderr" "FSQL_LEDGER_ANCHOR_LOG=bogus"; do
    say "edge inputs ($variant)"
    env "$variant" FSQL_EXT="$COVEXT" EDGE_CONFIGS=configured,fail nice python3 -I test/edge_inputs.py 2>&1 | tail -2
  done
fi

if has edge; then
  say "refusals: enterprise library, reasoning plugin, configuration keys"
  for d in enterprise_errors plugin_gate config_matrix t2s_matrix vectorizer_matrix sql_agent_matrix; do FSQL_EXT="$COVEXT" nice python3 -I "test/$d.py" 2>&1 | tail -3; done
fi

if has mutate; then
  say "kit mutation (each kit statement with one literal argument swapped)"
  FSQL_EXT="$COVEXT" MUT_MAX="${MUT_MAX:-10}" nice python3 -I test/kit_mutation.py 2>&1 | grep -v "without a signature" | tail -3
fi

if has oom; then
  say "allocation-failure sweep"
  FSQL_EXT="$COVEXT" OOM_MAX_TRIALS="${OOM_MAX_TRIALS:-40}" nice python3 -I test/oom_sweep.py 2>&1 | tail -6
fi

if has unit; then
  say "unit probes and fuzz corpora (--coverage)"
  mkdir -p "$COVDIR/unit"
  cflags=(-std=c11 -O0 -g --coverage -fprofile-update=atomic -Wno-unused-function -I"$COVDIR/src" -I"$COVDIR/include")
  run_u() {   # run_u NAME args -- sources...
    local name="$1"; shift
    if env -u LD_PRELOAD cc "${cflags[@]}" "$@" -lm -o "$COVDIR/unit/$name" 2>"$TMPROOT/fsql_cov_unit.log"; then "$COVDIR/unit/$name" "${RUN_ARGS[@]}" 2>&1 | tail -1
    else echo "  FAIL $name did not build"; tail -3 "$TMPROOT/fsql_cov_unit.log"; fi
  }
  RUN_ARGS=(); run_u ed25519_probe tests/ed25519_probe.c
  RUN_ARGS=(); run_u redact_unit test/redact_unit.c
  # the ledger at the storage seam: the instrumented extension objects (all but the enterprise loader, which the test replaces) plus a fake core
  if env -u LD_PRELOAD cc "${cflags[@]}" -I"$ROOT/include" test/ledger_unit.c $(ls "$COVDIR"/src/*.o | grep -v '/fsql_enterprise\.o$') \
       "$ROOT/include/$(uname -s | tr A-Z a-z)-$(uname -m)/libfractalsql-community-sovereign-c.a" -lsqlite3 -lm -ldl -lpthread -o "$COVDIR/unit/ledger_unit" 2>"$TMPROOT/fsql_cov_unit.log"; then
    for m in "default" "cap FSQL_LEDGER_MAX_ROWS=3" "badcap FSQL_LEDGER_MAX_ROWS=abc" "nocap FSQL_LEDGER_MAX_ROWS=0" "anchor FSQL_LEDGER_ANCHOR_LOG=STDERR" \
             "anchor-syslog FSQL_LEDGER_ANCHOR_LOG=syslog" "anchor-bogus FSQL_LEDGER_ANCHOR_LOG=bogus"; do
      set -- $m; env ${2:+"$2"} "$COVDIR/unit/ledger_unit" "$1" 2>&1 | tail -3
    done
  else echo "  FAIL ledger_unit did not build"; tail -3 "$TMPROOT/fsql_cov_unit.log"; fi
  RUN_ARGS=(); run_u extract_parse_probe tests/extract_parse_probe.c "$COVDIR/src/fsql_parse.c"
  RUN_ARGS=(); run_u extract_population_probe tests/extract_population_probe.c "$COVDIR/src/fsql_parse.c"
  for t in parse_embedding_array extract_best_point extract_population; do
    RUN_ARGS=("tests/fuzz/corpus_$t" "${COV_FUZZ_MUTANTS:-40}"); run_u "fuzz_$t" test/fuzz_replay.c "tests/fuzz/fuzz_$t.c" "$COVDIR/src/fsql_parse.c"
  done
fi

if has report; then
  say "report"
  find "$COVDIR" -name '*.gcda' | grep -q . || { echo "  no .gcda produced"; exit 1; }
  summary="$(python3 -I "$HERE/gcov_summary.py" "$COVDIR" '(^|/)src/[^/]+\.(c|h)$')"
  printf '%s\n' "$summary" | grep -v '^TOTAL '
  read -r _ L_PCT F_PCT B_PCT <<<"$(printf '%s\n' "$summary" | grep '^TOTAL ')"
  MIN="${COV_MIN:-80}"; verdict=0
  for m in "lines:$L_PCT" "functions:$F_PCT" "branches:$B_PCT"; do
    if awk -v v="${m#*:}" -v t="$MIN" 'BEGIN { exit !(v + 0 >= t + 0) }'; then echo "  PASS ${m%%:*} ${m#*:}% (>= $MIN%)"
    else echo "  FAIL ${m%%:*} ${m#*:}% (< $MIN%)"; verdict=1; fi
  done
fi
exit "${verdict:-0}"
