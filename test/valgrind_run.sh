#!/usr/bin/env bash
# test/valgrind_run.sh -- build_test.sh --profile: valgrind memcheck over the extension and the MCP server's code
# (Linux only).
#
# What it adds to the sanitizer cells: uninitialised reads (MemorySanitizer cannot be used, the host is not
# instrumented) and leaks (the sanitizer runs set detect_leaks=0), on the unmodified release build.
#
# Targets:
#   units    tests/ed25519_probe, tests/extract_parse_probe, tests/extract_population_probe, and the three pure-C fuzz
#            corpora (parse_embedding_array, extract_best_point, extract_population) replayed with mutations; -O0 -g
#   engine   the sqlite3 shell loading the extension and running every demo/demo-vertical-*.sql kit (the mock reasoning
#            plugin answers), one valgrind process per kit
#   mcp      the MCP server's own code (mcp/src, C++): vectors_probe, db_probe (with the vendored sqlite3.c) and
#            concurrency_probe
#   server   the running MCP server (mcp/fractalsql-sqlite-mcp, built with make -C mcp if stale), started under valgrind by a
#            wrapper script and driven by mcp/tests/mcp_smoke_client.py (every tool, the HTTP transport, the CLI surface)
#
# Leaks counted as intentional (not failed): runHttpTransport's objects, which the code leaks on purpose because detached
# connection threads may outlive the drain (see the comment at the allocations in mcp/src/transport_http.cpp); and a process-wide
# SQLite mutex the extension allocates once and never frees (src/fsql_reasoning.c, g_reasoning_env_mu: freeing a mutex another
# thread may be entering is worse than one allocation at exit). The extension is unloaded before exit, so valgrind can no longer
# name its frames; the signature is the mutex allocation itself (pthreadMutexAlloc).
# (The mock reasoning plugin reads its canned reply from the fixed file /tmp/fractalsql_bt_sql.txt, as the gates do, so the
# server target writes that file.)
# Verdict (test/valgrind_check.py): FAIL on any memcheck error or definite/indirect leak whose stack has a frame in
# our code (the extension, a probe binary); the host's own reports (libsqlite3, libc) and possible leaks are counted,
# not failed. SKIP (exit 0) when not on Linux, or valgrind or sqlite3 is missing.
#
# Env: PROFILE_KEEP=1 keeps the logs directory; PROFILE_ONLY=units|engine|mcp|server runs one target; FSQL_EXT names the
# extension (default: ./fractalsql.so, built with make, run as a copy that keeps its symbol table); SQLITE3 names the shell.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT"
say() { printf '\n== profile: %s\n' "$*"; }
[ "$(uname -s)" = Linux ] || { echo "  SKIP profile: valgrind runs on Linux only"; exit 0; }
command -v valgrind >/dev/null 2>&1 || { echo "  SKIP profile: valgrind is not installed"; exit 0; }
SQLITE3="${SQLITE3:-$(command -v sqlite3 || true)}"
ONLY="${PROFILE_ONLY:-}"
W="$(mktemp -d "${TMPDIR:-/tmp}/fsql_profile_XXXXXX")"
trap '[ "${PROFILE_KEEP:-0}" = 1 ] || rm -rf "$W"' EXIT
FAILS=0
VG=(valgrind --tool=memcheck --leak-check=full --show-leak-kinds=definite,indirect,possible --track-origins=yes
    --num-callers=40 --fair-sched=yes --xml=yes)
cc_clean() { env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES "$@"; }

# The extension, built with make; plus a copy linked WITHOUT --strip-all from the same up-to-date objects (same code, same
# flags; only the symbol table is kept) so that a finding's stack names functions. FSQL_EXT overrides both.
build_ext() {   # sets EXT
  if [ -n "${FSQL_EXT:-}" ]; then EXT="$FSQL_EXT"; EXT="$(cd "$(dirname "$EXT")" && pwd)/$(basename "$EXT")"; return 0; fi
  nice make >"$W/make.log" 2>&1 || { echo "  FAIL the extension did not build (see $W/make.log)"; PROFILE_KEEP=1; exit 1; }
  EXT="$ROOT/fractalsql.so"
  mkdir -p "$W/sym"
  if cc_clean nice make TARGET="$W/sym/fractalsql.so" LDFLAGS="-shared -Wl,--gc-sections -Wl,--exclude-libs,ALL -lm -ldl -lpthread" >"$W/sym/make.log" 2>&1 \
     && [ -f "$W/sym/fractalsql.so" ]; then EXT="$W/sym/fractalsql.so"; fi
}

run_target() {   # label, ours-substring, cmd...   (stdin passes through)
  local label="$1" ours="$2"; shift 2
  local xml="$W/$label.xml" log="$W/$label.log"
  timeout 1500 nice "${VG[@]}" --xml-file="$xml" "$@" >"$log" 2>&1
  local rc=$?
  if [ ! -s "$xml" ]; then echo "  FAIL $label: valgrind produced no report (rc=$rc; see $log)"; FAILS=$((FAILS + 1)); PROFILE_KEEP=1; return; fi
  if python3 -I "$HERE/valgrind_check.py" verdict --ours "$ours" "$xml"; then echo "  PASS $label"
  else echo "  FAIL $label (logs in $W)"; FAILS=$((FAILS + 1)); PROFILE_KEEP=1; fi
}

if [ -z "$ONLY" ] || [ "$ONLY" = units ]; then
  say "units"
  mkdir -p "$W/u"
  build() { cc_clean cc -std=c11 -O0 -g -Wno-unused-function -Iinclude -Isrc "$@" -lm 2>"$W/u/cc.log" \
              || { echo "  FAIL a unit binary did not build"; tail -3 "$W/u/cc.log"; FAILS=$((FAILS + 1)); return 1; }; }
  build tests/ed25519_probe.c -o "$W/u/ed25519_probe" && run_target ed25519_probe "$W/u/" "$W/u/ed25519_probe"
  build tests/extract_parse_probe.c src/fsql_parse.c -o "$W/u/extract_parse_probe" \
    && run_target extract_parse_probe "$W/u/" "$W/u/extract_parse_probe"
  build tests/extract_population_probe.c src/fsql_parse.c -o "$W/u/extract_population_probe" \
    && run_target extract_population_probe "$W/u/" "$W/u/extract_population_probe"
  for t in parse_embedding_array extract_best_point extract_population; do
    build test/fuzz_replay.c "tests/fuzz/fuzz_$t.c" src/fsql_parse.c -o "$W/u/fuzz_$t" \
      && run_target "fuzz_$t" "$W/u/" "$W/u/fuzz_$t" "tests/fuzz/corpus_$t" 3
  done
fi

if [ -z "$ONLY" ] || [ "$ONLY" = engine ]; then
  say "engine (sqlite3 shell + the extension + the demo kits)"
  if [ -z "$SQLITE3" ]; then echo "  SKIP engine: no sqlite3 shell (set SQLITE3)"
  else
    build_ext
    [ -f "$EXT" ] || { echo "  FAIL no extension at $EXT"; exit 1; }
    mkdir -p "$W/k"
    if ! cc_clean cc -shared -fPIC -std=c99 -Iinclude tests/mock_reasoning_plugin.c -o "$W/mock_reasoning_plugin.so" 2>"$W/k/plugin.log"; then
      echo "  FAIL the mock reasoning plugin did not build"; tail -3 "$W/k/plugin.log"; exit 1
    fi
    export FSQL_REASONING_REQUIRE_SIGNATURE=0
    echo "  extension: $EXT; shell: $SQLITE3"
    n=0; xmls=()
    for kit in "$ROOT"/demo/demo-vertical-*.sql; do
      [ -f "$kit" ] || continue
      k="$(basename "$kit" .sql)"; n=$((n + 1)); xml="$W/kit_$k.xml"; xmls+=("$xml")
      ( cd "$W/k" && timeout 600 nice "${VG[@]}" --xml-file="$xml" "$SQLITE3" -batch -cmd ".load $EXT" \
          -cmd "SELECT fractal_config_set('reasoning_plugin','$W/mock_reasoning_plugin.so');" :memory: ".read $kit" >"$W/kit_$k.log" 2>&1 )
      [ -s "$xml" ] || { echo "  FAIL kit $k: valgrind produced no report (see $W/kit_$k.log)"; FAILS=$((FAILS + 1)); PROFILE_KEEP=1; }
    done
    echo "  $n kits"
    if python3 -I "$HERE/valgrind_check.py" verdict --ours "$EXT" "${xmls[@]}"; then echo "  PASS engine ($n kits)"
    else echo "  FAIL engine (logs in $W)"; FAILS=$((FAILS + 1)); PROFILE_KEEP=1; fi
  fi
fi

if [ -z "$ONLY" ] || [ "$ONLY" = mcp ]; then
  say "mcp (the MCP server's probes, C++)"
  CXX="$(command -v g++ || command -v c++ || command -v clang++ || true)"
  if [ -z "$CXX" ] || [ ! -f "$ROOT/mcp/tests/vectors_probe.cpp" ]; then echo "  SKIP mcp: no C++ compiler or no mcp/ tests"
  else
    mkdir -p "$W/mcp"
    M="$ROOT/mcp"; CXXF=(-std=c++17 -O1 -g -I"$M/vendor" -I"$M/src")
    bm() { cc_clean "$CXX" "${CXXF[@]}" "$@" 2>>"$W/mcp/cc.log" || { echo "  FAIL an MCP probe did not build (see $W/mcp/cc.log)"; FAILS=$((FAILS + 1)); PROFILE_KEEP=1; return 1; }; }
    bm "$M/tests/vectors_probe.cpp" "$M/src/vectors.cpp" "$M/src/errors.cpp" -o "$W/mcp/vectors_probe" \
      && run_target mcp_vectors_probe "$W/mcp/" "$W/mcp/vectors_probe"
    bm -pthread "$M/tests/concurrency_probe.cpp" -o "$W/mcp/concurrency_probe" \
      && run_target mcp_concurrency_probe "$W/mcp/" "$W/mcp/concurrency_probe"
    # db_probe links the vendored sqlite3.c (compiled as C) and OpenSSL
    if [ -f "$ROOT/deps/sqlite/sqlite3.c" ] && printf '#include <openssl/ssl.h>\nint main(){return 0;}\n' | cc_clean "$CXX" -x c++ -fsyntax-only - 2>/dev/null; then
      if cc_clean cc -std=c99 -O1 -g -fPIC -DSQLITE_ENABLE_LOAD_EXTENSION=1 -DSQLITE_THREADSAFE=1 -DSQLITE_ENABLE_COLUMN_METADATA=1 \
           -c "$ROOT/deps/sqlite/sqlite3.c" -o "$W/mcp/sqlite3.o" 2>>"$W/mcp/cc.log"; then
        bm -DFSQL_MCP_VERSION='"profile"' -I"$ROOT/deps/sqlite" "$M/tests/db_probe.cpp" "$M/src/errors.cpp" "$M/src/logging.cpp" \
           "$W/mcp/sqlite3.o" -o "$W/mcp/db_probe" -lssl -lcrypto -lpthread -ldl \
          && run_target mcp_db_probe "$W/mcp/" "$W/mcp/db_probe"
      else echo "  FAIL the vendored sqlite3.c did not build (see $W/mcp/cc.log)"; FAILS=$((FAILS + 1)); PROFILE_KEEP=1; fi
    else echo "  SKIP mcp_db_probe: OpenSSL headers or deps/sqlite/sqlite3.c not found"; fi
  fi
fi

# The running server under valgrind: the smoke client starts every server process through a wrapper that runs it under
# memcheck (one XML log per process). Frames in the server binary or in the extension it loads count as ours.
if [ -z "$ONLY" ] || [ "$ONLY" = server ]; then
  say "server (the running MCP server under valgrind, driven by mcp/tests/mcp_smoke_client.py)"
  if [ ! -f "$ROOT/mcp/tests/mcp_smoke_client.py" ] || [ -z "$SQLITE3" ]; then echo "  SKIP server: no mcp/ smoke client or no sqlite3 shell"
  else
    build_ext
    if ! cc_clean nice make -C "$ROOT/mcp" >"$W/smake.log" 2>&1; then
      echo "  FAIL the MCP server did not build (see $W/smake.log)"; tail -5 "$W/smake.log"; FAILS=$((FAILS + 1)); PROFILE_KEEP=1
    elif ! cc_clean cc -shared -fPIC -std=c99 -Iinclude tests/mock_reasoning_plugin.c -o "$W/mock_reasoning_plugin.so" 2>"$W/plugin.log" \
         || ! cc_clean cc -shared -fPIC -std=c99 -Iinclude tests/slow_reasoning_plugin.c -o "$W/slow_reasoning_plugin.so" 2>>"$W/plugin.log"; then
      echo "  FAIL a reasoning fixture plugin did not build"; tail -3 "$W/plugin.log"; FAILS=$((FAILS + 1)); PROFILE_KEEP=1
    else
      mkdir -p "$W/srv/slogs"
      {
        echo '#!/bin/sh'
        echo "exec nice valgrind --tool=memcheck --leak-check=full --show-leak-kinds=definite,indirect,possible --track-origins=yes \\"
        echo "  --num-callers=40 --fair-sched=yes --xml=yes --xml-file='$W/srv/slogs/server.%p.xml' '$ROOT/mcp/fractalsql-sqlite-mcp' \"\$@\""
      } > "$W/srv/srv-valgrind.sh"
      chmod +x "$W/srv/srv-valgrind.sh"
      export FSQL_REASONING_REQUIRE_SIGNATURE=0
      out="$(env MCP_HERE="$ROOT/mcp" MCP_SERVER_EXE="$W/srv/srv-valgrind.sh" MCP_CANARY_FILE=/tmp/fractalsql_bt_sql.txt MCP_SERVER_CWD="$W/srv" \
             MCP_SLOW_REASONING_PLUGIN="$W/slow_reasoning_plugin.so" SQLITE_DB_PATH="$W/srv/bt.db" FRACTALSQL_EXTENSION_PATH="$EXT" \
             FSQL_MCP_LOG_LEVEL=debug FRACTALSQL_BOOTSTRAP_SQL="SELECT fractal_config_set('reasoning_plugin','$W/mock_reasoning_plugin.so');" \
             timeout 3000 python3 -u "$ROOT/mcp/tests/mcp_smoke_client.py" 2>&1)"
      rc=$?
      printf '%s\n' "$out" > "$W/srv/smoke.log"
      echo "  smoke client: $(grep -c '^ *PASS' <<< "$out") checks passed, $(grep -c '^ *FAIL' <<< "$out") failed (exit $rc)"
      if [ "$rc" -ne 0 ]; then
        echo "  (the checks run under valgrind's slowdown: a failure here may be a client timeout, see $W/srv/smoke.log)"
        grep -E '^ *FAIL|Traceback|Error' <<< "$out" | head -5
        FAILS=$((FAILS + 1)); PROFILE_KEEP=1
      fi
      # shellcheck disable=SC2206
      logs=("$W"/srv/slogs/server.*.xml)
      if [ -e "${logs[0]}" ]; then
        if python3 -I "$HERE/valgrind_check.py" verdict --ours "$ROOT/mcp/fractalsql-sqlite-mcp" --ours "$EXT" --host-fn sqlite3 --host-fn pthreadMutexAlloc \
             --intentional-leak runHttpTransport --intentional-leak pthreadMutexAlloc "${logs[@]}"; then echo "  PASS server (${#logs[@]} server process(es))"
        else echo "  FAIL server (logs in $W)"; FAILS=$((FAILS + 1)); PROFILE_KEEP=1; fi
      else echo "  FAIL server: no valgrind logs were written"; FAILS=$((FAILS + 1)); PROFILE_KEEP=1; fi
    fi
  fi
fi

echo
if [ "$FAILS" -eq 0 ]; then echo "profile: all targets clean"; else echo "profile: $FAILS target(s) failed"; fi
[ "${PROFILE_KEEP:-0}" = 1 ] && echo "  logs kept in $W"
exit "$FAILS"
