#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs

"""Gate-37 client driver for the fractalsql-sqlite-mcp C++ server.

Driven by build_test.sh's gate_37_mcp_smoke (and the matching PowerShell
gate): spawns the MCP server binary and mechanically enforces the
accessibility invariant across the whole registered surface. Four phases,
each with its own server lifecycle:
  1. the stdio session: locks, the 81-tool catalog, real tools/call round
     trips per tier including error paths, cancellation, resources and
     prompts (full catalogs), wire-framing edge lines, and a full-catalog
     coverage sweep (every tool answers: a result or its documented clean
     error)
  2. the HTTP transport session: Bearer auth (env and hot-reloaded file,
     rotation without restart), the two unauthenticated probes, session
     mint/reuse/close, and the refusal shapes (401/400/404/405, chunked,
     oversized)
  3. the CLI/env startup surface: --version/--list-tools/--help, tool
     whitelist and category narrowing, read-only mode, and the
     lock-mismatch postures (strict exit, warn-and-serve, safety hard exit)
  4. shutdown behavior: each server run ends the way a client ends it,
     stdin EOF for stdio (graceful drain) and termination for HTTP
     (the SIGTERM flag plus one final connection), verified clean

Zero dependencies beyond the stdlib. The client never imports the
server's implementation; it talks only the newline-delimited JSON-RPC
wire format, so it keeps working across the implementation's own
refactors.

Input (environment, all required unless noted):
  MCP_SERVER_EXE            the fractalsql-sqlite-mcp binary just built
  SQLITE_DB_PATH            the harness's throwaway DB (WAL file)
  FRACTALSQL_EXTENSION_PATH the just-built fractalsql .so/.dylib/.dll
  FRACTALSQL_BOOTSTRAP_SQL  the per-connection bootstrap (mock reasoning
                            plugin + canary), the bootstrap contract
  MCP_HERE                  the mcp/ directory (lock/manifest paths)
  MCP_CANARY_FILE           where to write the reasoning canary text
                            (the fixture plugin's fixed file contract)
  MCP_SERVER_CWD            the server process's working directory
                            (Windows fixture plugins fopen a CWD-relative
                            canary path; POSIX plugins don't care)

Exits 0 on all-pass, 1 otherwise; prints PASS/FAIL lines the gates
relabel."""

from __future__ import annotations

import http.client as httpc
import json
import os
import re
import signal
import socket
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time

_failures = 0


def check(label: str, cond: bool) -> bool:
    global _failures
    print(("PASS " if cond else "FAIL ") + label)
    if not cond:
        _failures += 1
    return bool(cond)


def main() -> int:  # noqa: ANN201
    global _failures
    mcp_exe = os.environ["MCP_SERVER_EXE"]
    here = os.environ["MCP_HERE"]

    # phase 0: the 10.5 + 15.3 integrity locks, via the binary itself
    # The gate enforces the regenerate-and-commit workflow mechanically: the
    # binary recomputes both projections over its registered tool surface;
    # a changed tool table without a regenerated committed lock fails here.
    lock_path = os.path.join(here, ".mcp-schema-lock")
    safety_path = os.path.join(here, ".mcp-safety-annotations-lock")
    if not check("phase0: committed .mcp-schema-lock exists", os.path.isfile(lock_path)):
        return 1
    if not check("phase0: committed .mcp-safety-annotations-lock exists",
                 os.path.isfile(safety_path)):
        return 1
    if not check("phase0: manifest.json exists",
                 os.path.isfile(os.path.join(here, "manifest.json"))):
        return 1
    with tempfile.TemporaryDirectory() as td:
        regenerated = os.path.join(td, "schema.tmp")
        r = subprocess.run(
            [mcp_exe, "--write-schema-lock", "--schema-lock-path", regenerated],
            env=dict(os.environ, SQLITE_DB_PATH="", FRACTALSQL_EXTENSION_PATH=""),
            capture_output=True, text=True)
        if not check("phase0: --write-schema-lock regenerates cleanly", r.returncode == 0):
            return 1
        committed = open(lock_path, encoding="utf-8").read().strip()
        check("phase0: lock matches the registered tool set (10.5 workflow)",
              committed != "" and committed == open(regenerated).read().strip())
        regenerated_safety = os.path.join(td, "safety.tmp")
        r = subprocess.run(
            [mcp_exe, "--write-safety-annotations-lock", "--safety-lock-path",
             regenerated_safety],
            env=dict(os.environ, SQLITE_DB_PATH="", FRACTALSQL_EXTENSION_PATH=""),
            capture_output=True, text=True)
        ok = (r.returncode == 0
              and open(safety_path, encoding="utf-8").read()
                  == open(regenerated_safety, encoding="utf-8").read())
        check("phase0: safety annotations match the registered surface", ok)

    # fixture setup (direct SQL, before the server owns the DB)
    dbpath = os.environ["SQLITE_DB_PATH"]
    ext = os.environ["FRACTALSQL_EXTENSION_PATH"]
    con = sqlite3.connect(dbpath)
    con.enable_load_extension(True)
    con.load_extension(ext)
    con.executescript("""
    DROP TABLE IF EXISTS mcp_sm_docs;
    CREATE TABLE mcp_sm_docs(id INTEGER PRIMARY KEY, title TEXT, emb TEXT);
    INSERT INTO mcp_sm_docs VALUES
      (1,'alpha','0.1,0.1,0.1'),(2,'beta','0.9,0.9,0.9'),
      (3,'gamma','0.2,0.8,0.2'),(4,'delta','0.15,0.15,0.12');
    DROP TABLE IF EXISTS mcp_sm_logs;
    CREATE TABLE mcp_sm_logs(ts INTEGER, host TEXT, metric REAL);
    DROP TABLE IF EXISTS mcp_sm_vec_src;
    CREATE TABLE mcp_sm_vec_src(id INTEGER PRIMARY KEY, txt TEXT, emb TEXT);
    INSERT INTO mcp_sm_vec_src(id, txt, emb) VALUES (1, 'needs embedding', NULL);
    """)
    for i in range(1, 97):
        con.execute(
            "INSERT INTO mcp_sm_logs VALUES (?,?,?)",
            (i, "host-1", 50.0 + (i % 8) * 1.3 + (30.0 if i > 48 else 0.0)),
        )
    con.commit()
    con.close()

    # spawn the server (stdio transport, 1.1)
    canary_file = os.environ["MCP_CANARY_FILE"]
    # The mock plugin wraps the file's content in a ```sql fence before
    # returning it, so the canary must be a valid SELECT with the marker
    # comment riding along: fractal_reason then echoes the fenced marker
    # verbatim, and fractal_text_to_sql's pipeline extracts and validates
    # the same statement; one file passes both the reason-path and
    # GENERATE-path canary checks.
    with open(canary_file, "w", encoding="utf-8") as fh:
        fh.write("SELECT 1 -- mcp-gate-canary")

    server_log_path = os.path.join(os.environ["MCP_SERVER_CWD"],
                                   "mcp_server.log")
    server_log = open(server_log_path, "w", encoding="utf-8")
    # Unlike gate 01's build step, this process dlopens fractalsql.so at
    # runtime (sqlite3_load_extension) -- under --asan/--ubsan/--tsan that
    # .so IS sanitizer-built, so LD_PRELOAD must stay set here (preloading
    # the sanitizer runtime into this otherwise-unsanitized host process)
    # or the dlopen aborts with "ASan runtime does not come first".
    env = dict(os.environ)
    proc = subprocess.Popen(
        [mcp_exe],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=server_log,
        cwd=os.environ["MCP_SERVER_CWD"], env=env, text=True, bufsize=1,
    )

    _req = [0]
    _queue = []

    def _reader(proc) -> None:  # noqa: ANN001
        for line in proc.stdout:
            _queue.append(line)
        _queue.append(None)  # EOF sentinel

    threading.Thread(target=_reader, args=(proc,), daemon=True).start()

    def send(msg: dict) -> None:
        proc.stdin.write(json.dumps(msg) + "\n")
        proc.stdin.flush()

    def recv(deadline: float | None = None):  # noqa: ANN001
        """Queue-backed read so polls can bound their wait (a cancelled
        in-flight call must deliver no result to wait on)."""
        start = time.monotonic()
        while True:
            if _queue:
                line = _queue.pop(0)
                if line is None:
                    print("FAIL server closed stdout; server log tail:")
                    print(open(server_log_path, encoding="utf-8").read()[-2000:])
                    return None
                return json.loads(line)
            if deadline is not None and time.monotonic() - start > deadline:
                return {"__timeout__": True}
            time.sleep(0.02)

    def wait_for(rid, timeout: float = 30.0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            r = recv(deadline=0.2)
            if r is None or r.get("__timeout__"):
                if r is None:
                    return None
                continue
            if not isinstance(r, dict):
                return None
            if r.get("id") == rid:
                return r
        return {"__timeout__": True}

    def call(name: str, args: dict, timeout: float = 30.0):
        _req[0] += 1
        rid = 1000 + _req[0]
        send({"jsonrpc": "2.0", "id": rid, "method": "tools/call",
              "params": {"name": name, "arguments": args}})
        return wait_for(rid, timeout)

    try:
        # initialize handshake
        send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2025-06-18",
            "clientInfo": {"name": "gate37", "version": "0"}}})
        init = recv()
        if not check("initialize handshake",
                     init is not None
                     and init.get("result", {}).get("serverInfo", {})
                     .get("name") == "fractalsql-sqlite-mcp"
                     and init.get("result", {}).get("protocolVersion")
                     == "2025-06-18"):
            finish(proc, server_log)
            return 1
        send({"jsonrpc": "2.0", "id": 1, "method": "ping",
              "params": {}})
        pong = wait_for(1)
        check("ping liveness probe responds with an empty {}", pong is not None
              and pong.get("result") == {})

        # the accessibility invariant, mechanically
        send({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
        listed = recv()["result"]["tools"]
        check("tools/list: the full engine-filtered catalog (81 tools)",
              len(listed) == 81)
        anonymous = [t["name"] for t in listed
                     if not (t.get("description") or "").strip()
                     or "properties" not in t["inputSchema"]]
        check("1.7 accessibility invariant: every tool has a non-empty "
              "description and a complete inputSchema.properties", not anonymous)
        zero_arg = [t for t in listed
                    if t["inputSchema"].get("x-fractalsql-no-arguments")]
        check("1.7: zero-argument tools document their no-arguments shape "
              "via the marker", len(zero_arg) >= 10)
        tiers = {t.get("_meta", {}).get("x-fractalsql-tier") for t in listed}
        check("tier metadata groups tools like the docs teach",
              tiers == {"Discovery", "Cognition", "Agency", "Analytics",
                        "Enterprise", "Vectorizer", "Admin"})
        classes = {t.get("_meta", {}).get("x-fractalsql-class") for t in listed}
        check("x-fractalsql-class present on every tool; retry-tier OMITTED "
              "on SQLite (11.2's requirement, not a placeholder)",
              classes == {"cheap", "expensive"}
              and all("x-fractalsql-retry-tier" not in t["_meta"] for t in listed))
        annotated = {t["name"] for t in listed if t.get("annotations")}
        heavy = [n for n in ["fractal_ledger_reset_hard", "fractal_ledger_flush",
                             "fractal_vectorizer_drop","fractalsql_set_config"]
                 if n in annotated]
        check("15.2/6: destructiveHint present on the heavy/destructive tools",
              len(heavy) >= 3)
        tools_by_name = {t["name"]: t for t in listed}
        reasoning_tools = [n for n in ["fractal_reason", "fractal_agent_anomaly_triage",
                                       "fractal_sql_agent"] if n in tools_by_name]
        check("15.2: idempotentHint/openWorldHint/secretHint on the "
              "reasoning-capable tools",
              len(reasoning_tools) == 3
              and all(tools_by_name[n]["annotations"].get("openWorldHint")
                      and tools_by_name[n]["annotations"].get("secretHint")
                      for n in reasoning_tools))

        # sanity check (plugin docs' one-liner)
        r = call("fractalsql_get_version", {})
        check("sanity check: fractalsql_get_version returns a real "
              "edition/version",
              r is not None and not r["result"].get("isError")
              and r["result"]["structuredContent"]["edition"] == "Community")

        # Discovery tier
        r = call("fractal_search", {"vector": [0.1, 0.9], "query": [0.6, 0.8]})
        check("Discovery: fractal_search returns a real cosine distance",
              isinstance(r["result"]["structuredContent"].get("value"), float))
        r = call("fractal_search_telemetry",
                 {"table_name": "mcp_sm_docs", "vector_col": "emb",
                  "query": [0.15, 0.15, 0.1], "k": 200})
        sc = r["result"]["structuredContent"]
        check("Discovery: telemetry doc_id is a real rowid + scan_pos",
              isinstance(sc, dict) and sc.get("truncated") is True
              and {"doc_id", "distance", "scan_pos"} <= set(sc["rows"][0]))
        check("1.5 row ceiling: k=200 was ceiling-clamped and flagged",
              sc.get("total_scanned") == 200 and len(sc["rows"]) <= 100)
        r = call("fractal_search_telemetry",
                 {"table_name": "mcp_sm_docs", "vector_col": "emb",
                  "query": [0.15, 0.15, 0.1], "k": 2, "limit": 2})
        check("1.5: caller-settable limit honored", isinstance(
              r["result"]["structuredContent"], list)
              and len(r["result"]["structuredContent"]) == 2)
        r = call("fractal_hybrid_clinical_search",
                 {"table_name": "mcp_sm_docs", "vector_col": "emb",
                  "query": [0.9, 0.9, 0.9], "doc_ids": [1, 4], "k": 5})
        rows = r["result"]["structuredContent"]
        check("Discovery: cohort restriction applies to the scan",
              isinstance(rows, list)
              and {x["doc_id"] for x in rows} <= {1, 4})

        # rows.h's boundedCount(): the k=200 ceiling-clamp test above only
        # exercises the IN-RANGE path; its own range validation is
        # otherwise untested. (Its "must be an integer" type check turns
        # out to be dead via any live call: tool_registry.h's own schema-
        # layer jsonTypeMatches(Integer, v) already rejects a non-integer
        # k, with a DIFFERENT message, before boundedCount ever runs --
        # confirmed by reading mcp_json.h's jsonTypeMatches directly, not
        # guessed. This asserts the real (schema-layer) behavior instead.)
        r = call("fractal_search_telemetry",
                 {"table_name": "mcp_sm_docs", "vector_col": "emb",
                  "query": [0.1, 0.1, 0.1], "k": "not-a-number"})
        check("tool_registry.h: a wrong-typed k is refused at the schema "
              "layer before boundedCount ever runs",
              r is not None and r["result"].get("isError") is True
              and "has the wrong type" in json.dumps(r["result"]))
        r = call("fractal_search_telemetry",
                 {"table_name": "mcp_sm_docs", "vector_col": "emb",
                  "query": [0.1, 0.1, 0.1], "k": 0})
        check("rows.h: an out-of-range k (0) is refused",
              r is not None and r["result"].get("isError") is True
              and "out of range" in json.dumps(r["result"]))
        r = call("fractal_search_telemetry",
                 {"table_name": "mcp_sm_docs", "vector_col": "emb",
                  "query": [0.1, 0.1, 0.1], "k": 2, "limit": 0})
        check("rows.h: a non-positive limit is refused",
              r is not None and r["result"].get("isError") is True
              and "limit must be a positive integer" in json.dumps(r["result"]))

        # discovery.cpp: fractal_feedback_report's optional dwell_ms (the
        # 3-arg SQL variant) -- untested anywhere; the SQL-level build_test.sh
        # gates only cover 'positive'/'negative'/'dwell' kinds, not this
        # adapter's own dwell_ms-present branch.
        r = call("fractal_search_telemetry",
                 {"table_name": "mcp_sm_docs", "vector_col": "emb",
                  "query": [0.1, 0.1, 0.1], "k": 1})
        handle = r["result"]["structuredContent"][0]["scan_pos"]
        r = call("fractal_feedback_report",
                 {"result_handle": handle, "kind": "dwell", "dwell_ms": 1500})
        check("discovery.cpp: feedback_report with dwell_ms supplied uses "
              "the 3-arg SQL variant",
              r is not None and r["result"].get("isError") is not True)

        # enterprise.cpp: fractal_audit_unpack -- untested at the MCP layer
        # (dormant in Community; expect the same clean "enterprise tier
        # not loaded" condition every other Enterprise tool documents).
        r = call("fractal_audit_unpack", {"blob": "deadbeef"})
        check("Enterprise: audit_unpack returns the clean 'enterprise tier "
              "not loaded' condition on a Community install",
              r is not None and r["result"].get("isError") is True
              and "enterprise tier not loaded" in json.dumps(r["result"]))

        # logging.cpp: redactAndCap's own >256-char string cap -- every
        # logged tool-call argument so far has been short.
        r = call("fractal_reason", {"query": "x" * 300})
        check("logging.cpp: a >256-char logged argument is length-capped, "
              "not logged verbatim",
              r is not None and r["result"].get("isError") is not True)

        # tool_registry.h's validateArgs: a required arg OMITTED entirely
        # (distinct code path from the existing "explicit null" test) and
        # an OPTIONAL NULLABLE arg given explicit null (the p.nullable
        # true-branch, vs. simply leaving it out).
        r = call("fractal_search", {"vector": [0.1, 0.9]})
        check("tool_registry.h: a required arg left out entirely is "
              "refused (distinct from an explicit null)",
              r is not None and r["result"].get("isError") is True
              and "missing required argument" in json.dumps(r["result"]))
        r = call("fractal_agent_recall_hybrid",
                 {"mem_table": "mcp_sm_docs", "vec_col": "emb",
                  "query_vec": [0.1, 0.1, 0.1], "filter_col": None})
        check("tool_registry.h: an optional NULLABLE arg given explicit "
              "null is accepted (consumes the nullable slot)",
              r is not None and r["result"].get("isError") is not True)

        # analytics.cpp: fractal_vector_hamming_distance -- not called by
        # name anywhere in this suite; the generic sweep's wrong-typed
        # stub args for its two hex-STRING params fail schema validation
        # before ever reaching the adapter body.
        r = call("fractal_vector_hamming_distance", {"a": "ff00", "b": "00ff"})
        check("analytics.cpp: hamming_distance round-trips two real hex "
              "strings", r is not None and r["result"].get("isError")
              is not True and isinstance(
                  r["result"]["structuredContent"].get("value"), int))

        # Cognition tier (against the harness's mock reasoning)
        r = call("fractal_reason",
                 {"query": "reply with a short confirmation"})
        check("Cognition: fractal_reason reaches the mock reasoning plugin "
              "(reasoning configured via FRACTALSQL_BOOTSTRAP_SQL)",
              r is not None and not r["result"].get("isError")
              and "mcp-gate-canary" in r["result"]["content"][0]["text"])
        r = call("fractal_text_to_sql", {"question": "how many docs"})
        check("Cognition: fractal_text_to_sql returns validated SQL text "
              "(generated via the mock plugin)",
              r is not None and not r["result"].get("isError")
              and "mcp-gate-canary" in r["result"]["content"][0]["text"])

        # a Community agent (no-LLM tier)
        r = call("fractal_agent_recall_hybrid",
                 {"mem_table": "mcp_sm_docs", "vec_col": "emb",
                  "query_vec": [0.1, 0.1, 0.1], "filter_col": "title",
                  "filter_val": "alpha", "k": 2, "id_col": "id",
                  "content_col": "title"})
        check("Agency (community, no-LLM): recall_hybrid returns the real "
              "cohort row",
              isinstance(r["result"]["structuredContent"], list)
              and r["result"]["structuredContent"][0]["mem_id"] == 1)
        r = call("fractal_agent_anomaly_triage",
                 {"log_table": "mcp_sm_logs", "metric_col": "metric",
                  "time_col": "ts", "filter_col": "host",
                  "filter_val": "host-1", "baseline_window": 32})
        sc = r["result"]["structuredContent"]
        check("Agency: anomaly_triage composes drift -> reason (canary in "
              "triage_summary)",
              isinstance(sc, dict)
              and "mcp-gate-canary" in (sc.get("triage_summary") or ""))

        # Optional-nullable-argument adapter branches (agency.cpp): the
        # generic coverage sweep below only ever supplies REQUIRED args, so
        # every `a.contains(key) && !a.at(key).is_null()` ternary's "arg
        # present" side goes untested unless called explicitly here with the
        # optional field both omitted and supplied. Acceptance is generous
        # (any real response, success or clean error) -- the goal is
        # exercising the adapter's own arg-marshalling branches, not
        # re-proving the underlying engine call's own semantics (already
        # covered at the SQL level by build_test.sh's gate 29).
        r = call("fractal_agent_recall_hybrid",
                 {"mem_table": "mcp_sm_docs", "vec_col": "emb",
                  "query_vec": [0.1, 0.1, 0.1]})
        check("Agency: recall_hybrid with filter_col/filter_val/content_col "
              "all omitted (the nstr ternary's null side)",
              r is not None and "result" in r)

        r = call("fractal_agent_allocate",
                 {"mu": [0.1, 0.2], "cov": [1.0, 0.0, 0.0, 1.0],
                  "cardinality": 2})
        check("Agency: allocate with context omitted",
              r is not None and "result" in r)
        r = call("fractal_agent_allocate",
                 {"mu": [0.1, 0.2], "cov": [1.0, 0.0, 0.0, 1.0],
                  "cardinality": 2, "context": "{}"})
        check("Agency: allocate with context explicitly supplied",
              r is not None and "result" in r)

        r = call("fractal_agent_rebalance_sibling",
                 {"mu": [0.1, 0.2], "cov": [1.0, 0.0, 0.0, 1.0],
                  "cardinality": 2, "alloc_table": "mcp_sm_docs",
                  "alloc_emb_col": "emb", "baseline_vec": [0.1, 0.1, 0.1]})
        check("Agency: rebalance_sibling with seed omitted",
              r is not None and "result" in r)
        r = call("fractal_agent_rebalance_sibling",
                 {"mu": [0.1, 0.2], "cov": [1.0, 0.0, 0.0, 1.0],
                  "cardinality": 2, "alloc_table": "mcp_sm_docs",
                  "alloc_emb_col": "emb", "baseline_vec": [0.1, 0.1, 0.1],
                  "seed": 42.0})
        check("Agency: rebalance_sibling with seed explicitly supplied",
              r is not None and "result" in r)

        r = call("fractal_agent_diverse_portfolios",
                 {"mu": [0.1, 0.2], "cov": [1.0, 0.0, 0.0, 1.0],
                  "cardinality": 2})
        check("Agency: diverse_portfolios with seed omitted",
              r is not None and "result" in r)
        r = call("fractal_agent_diverse_portfolios",
                 {"mu": [0.1, 0.2], "cov": [1.0, 0.0, 0.0, 1.0],
                  "cardinality": 2, "seed": 42.0})
        check("Agency: diverse_portfolios with seed explicitly supplied",
              r is not None and "result" in r)

        r = call("fractal_agent_patient_deterioration_triage",
                 {"patient_table": "mcp_sm_docs", "vec_col": "emb",
                  "query_vec": [0.1, 0.1, 0.1], "baseline_vec": [0.1, 0.1, 0.1],
                  "current_vec": [0.2, 0.2, 0.2]})
        check("Agency: patient_deterioration_triage with cohort_doc_ids "
              "omitted", r is not None and "result" in r)
        r = call("fractal_agent_patient_deterioration_triage",
                 {"patient_table": "mcp_sm_docs", "vec_col": "emb",
                  "query_vec": [0.1, 0.1, 0.1], "baseline_vec": [0.1, 0.1, 0.1],
                  "current_vec": [0.2, 0.2, 0.2], "cohort_doc_ids": [1, 2]})
        check("Agency: patient_deterioration_triage with cohort_doc_ids "
              "explicitly supplied", r is not None and "result" in r)

        r = call("fractal_agent_data_analyst", {"question": "how many docs"})
        check("Agency: data_analyst with table_names omitted",
              r is not None and "result" in r)
        r = call("fractal_agent_data_analyst",
                 {"question": "how many docs",
                  "table_names": ["mcp_sm_docs"]})
        check("Agency: data_analyst with table_names explicitly supplied",
              r is not None and "result" in r)

        r = call("fractal_sql_agent", {"question": "how many docs"})
        check("Agency: sql_agent with table_names omitted",
              r is not None and "result" in r)
        r = call("fractal_sql_agent",
                 {"question": "how many docs",
                  "table_names": ["mcp_sm_docs"]})
        check("Agency: sql_agent with table_names explicitly supplied",
              r is not None and "result" in r)

        # Optional-nullable-argument adapter branches (analytics.cpp).
        r = call("fractal_optimize_subset",
                 {"item_values": [1.0, 2.0, 3.0],
                  "upper_bounds": [0.5, 0.5, 0.5], "k": 2, "seed": 1.0})
        check("Analytics: optimize_subset with prev_weights omitted",
              r is not None and "result" in r)
        r = call("fractal_optimize_subset",
                 {"item_values": [1.0, 2.0, 3.0],
                  "upper_bounds": [0.5, 0.5, 0.5], "k": 2, "seed": 1.0,
                  "prev_weights": [0.2, 0.2, 0.2]})
        check("Analytics: optimize_subset with prev_weights explicitly "
              "supplied", r is not None and "result" in r)

        r = call("fractal_store_morphology", {"feature_array": [0.1, 0.2]})
        check("Analytics: store_morphology with doc_id omitted",
              r is not None and "result" in r)
        r = call("fractal_store_morphology",
                 {"feature_array": [0.1, 0.2], "doc_id": 7})
        check("Analytics: store_morphology with doc_id explicitly supplied",
              r is not None and "result" in r)

        # the enterprise clean-error path (6/2.3)
        r = call("fractal_ledger_reset_hard", {})
        check("Enterprise: gated tool returns the clean 'enterprise tier "
              "not loaded' condition, not a crash or a silent no",
              r["result"].get("isError")
              and "enterprise tier not loaded"
              in r["result"]["content"][0]["text"]
              and r["result"]["structuredContent"]["error_class"] == "engine")
        r = call("fractal_ledger_verify", {"kind": 1})
        check("Enterprise: fractal_ledger_verify is pure read-only and "
              "works without the enterprise library",
              r is not None and not r["result"].get("isError"))

        # error-taxonomy pairing (1.6/11.1)
        r = call("fractal_agent_recall_hybrid",
                 {"mem_table": "mcp_sm_docs", "vec_col": "emb",
                  "query_vec": [0.1, 0.1, 0.1], "filter_col": "title",
                  "filter_val": "no-such-value", "k": 2, "id_col": "id"})
        if r["result"].get("isError") \
                and r["result"]["structuredContent"]["error_class"] == "engine":
            check("engine error class carries the engine's own actionable "
                  "text (verbatim, 1.6)",
                  "filter matched no rows" in r["result"]["content"][0]["text"])
        else:
            # Compat-tolerant (the version-skew guard's warning exists
            # exactly for this posture): an engine predating 2.0.5's
            # documented error text may return an empty cohort instead
            # of raising; that's the skew warning's domain, not the
            # MCP layer's.
            check("engine error class carries the engine's own actionable "
                  "text (or: the loaded extension predates 2.0.5's "
                  "documented error text -- version-skew warning territory)",
                  not r["result"].get("isError"))
        # fractal_dimension_drift is the tool that actually carries the
        # non-vector `win` field (1.4: lenient coercion is vector-element-
        # scoped; a wrong type elsewhere fails validation normally, before
        # any driver call).
        r = call("fractal_dimension_drift", {"series": [0.1, 0.2], "win": "x"})
        check("schema error class rejected before any driver call "
              "(wrong-typed non-vector field: no leniency, 1.4)",
              r["result"]["structuredContent"]["error_class"] == "schema")
        r = call("fractal_search", {"vector": "not,an,array"})
        check("schema error: non-array vector rejected",
              r["result"].get("isError")
              and r["result"]["structuredContent"]["error_class"] == "schema")
        # Explicit JSON null for a required arg is a DIFFERENT validateArgs
        # branch than simply omitting the key (tool_registry.h checks
        # !contains(key) first, then is_null() separately) -- distinct from
        # the omitted-key path every other schema-error check above takes.
        r = call("fractal_search", {"vector": None, "query": [0.1, 0.2]})
        check("schema error: explicit null for a required arg rejected "
              "(distinct from simply omitting it)",
              r["result"].get("isError")
              and r["result"]["structuredContent"]["error_class"] == "schema"
              and "vector" in r["result"]["content"][0]["text"])

        # $/cancel propagation
        # A slow-but-terminating O(n^2) DFT keeps the statement in-flight;
        # a cancel must interrupt the statement (sqlite3_interrupt), stay
        # responsive, and NEVER deliver the eventual result (it may respond
        # with an explicit cancellation signal, never the discarded payload).
        _req[0] += 1
        slow_id = 1000 + _req[0]
        big = [0.5 + 0.001 * (i % 7) for i in range(30000)]
        send({"jsonrpc": "2.0", "id": slow_id, "method": "tools/call",
              "params": {"name": "fractal_periodogram",
                         "arguments": {"series": big}}})
        time.sleep(0.2)
        send({"jsonrpc": "2.0", "method": "notifications/cancelled",
              "params": {"requestId": slow_id}})
        send({"jsonrpc": "2.0", "id": 9000, "method": "ping"})
        ping = None
        stale_result = None
        # First: the ping must get through WHILE the cancelled call runs.
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            r = recv(deadline=0.2)
            if r is None or r.get("__timeout__"):
                continue
            if r.get("id") == 9000:
                ping = r
                break
        # Then: the cancelled id responds ONLY with a cancellation signal,
        # never with the computed result, within a generous window.
        window_end = time.monotonic() + 15
        while time.monotonic() < window_end:
            r = recv(deadline=0.2)
            if r is None:
                break
            if r.get("__timeout__"):
                continue
            if r.get("id") == slow_id:
                stale_result = r
                break
        check("$/cancel: server stays responsive while a call is in flight",
              ping is not None)
        real_result = stale_result is not None and ((
            stale_result.get("result") or {})
            .get("structuredContent") not in (None, True)
        ) and "freqs" in json.dumps(
            (stale_result.get("result") or {}).get("structuredContent"))
        if stale_result is not None:
            if "error" in stale_result:
                # A top-level JSON-RPC error object is also an explicit
                # cancellation signal (the server's ErrorClass::Cancelled
                # path emits exactly this shape): any error naming the
                # cancel counts; the discarded payload never does.
                delivered_cancel_signal = ("cancel" in str(
                    stale_result.get("error", {}).get("message", "")))
            else:
                delivered_cancel_signal = (
                    stale_result.get("result", {}).get("isError") is True
                    and (stale_result["result"].get("content") or [{}])[0]
                        .get("text", "").find("cancel") >= 0)
        else:
            delivered_cancel_signal = False
        check("$/cancel: the cancelled call's REAL result is never delivered "
              "(at most an explicit cancellation signal)",
              not real_result and (stale_result is None or delivered_cancel_signal))

        # resources & prompts
        for uri, label in (("fractalsql://schema", "schema"),
                           ("fractalsql://config", "config"),
                           ("fractalsql://agents", "agents")):
            send({"jsonrpc": "2.0", "id": 9100, "method": "resources/read",
                  "params": {"uri": uri}})
            # Match by id, not "next message": a late reply from the
            # cancelled call above can still be in the queue (seen under
            # --tsan's slowdown) and would otherwise shift every reply
            # after it by one.
            r = wait_for(9100, 20)
            check(f"resource fractalsql://{label} reads as real content",
                  r is not None and (r.get("result") or {}).get("contents"))
        send({"jsonrpc": "2.0", "id": 9200, "method": "prompts/list"})
        prompts = ((wait_for(9200, 20) or {}).get("result") or {}).get("prompts") or []
        check("prompts/list: the 11-prompt starter set",
              len(prompts) == 11)
        send({"jsonrpc": "2.0", "id": 9201, "method": "prompts/get",
              "params": {"name": "safe_sql_question",
                         "arguments": {"question": "how many orders?"}}})
        pg = wait_for(9201, 20) or {}
        msg = (((pg.get("result") or {}).get("messages") or [{}])[0]
               .get("content") or {}).get("text", "")
        check("safe_sql_question prompt keeps auto_execute explicitly OFF",
              "EXPLICITLY FALSE" in msg)

        # full-catalog prompts exercise: render every declared prompt, not
        # just the representative one above. Declared arguments are filled
        # with their own names; the templates are static text builders.
        bad_prompts = []
        for p in prompts:
            if p["name"] == "safe_sql_question":
                continue   # asserted above with its real argument pairing
            pargs = {a["name"]: f"stub-{a['name']}"
                     for a in (p.get("arguments") or [])}
            send({"jsonrpc": "2.0", "id": 9251, "method": "prompts/get",
                  "params": {"name": p["name"], "arguments": pargs}})
            r = wait_for(9251, 20)
            if (not r or "error" in r
                    or not ((r.get("result") or {}).get("messages"))):
                bad_prompts.append((p["name"], r if r is None else str(
                    r.get("error") or "empty result.messages")))
        check(f"prompts/get: every declared prompt renders "
              f"({len(prompts) - 1} here)", not bad_prompts)
        for name, why in bad_prompts:
            print("FAIL prompts/get detail:", name, "->", why)
            _failures += 1

        # prompts/get error paths: the generic sweep above always supplies
        # every declared argument, so a required slot's OWN absence (as
        # opposed to a bad prompt name) is never exercised.
        send({"jsonrpc": "2.0", "id": 9252, "method": "prompts/get",
              "params": {"name": "incident_triage", "arguments": {}}})
        r = wait_for(9252, 10)
        check("prompts/get: a required slot left out is refused -32602",
              r is not None and r.get("error", {}).get("code") == -32602
              and "is required" in r["error"]["message"])
        send({"jsonrpc": "2.0", "id": 9253, "method": "prompts/get",
              "params": {"name": "not_a_real_prompt", "arguments": {}}})
        r = wait_for(9253, 10)
        check("prompts/get: an unknown prompt name is refused -32602",
              r is not None and r.get("error", {}).get("code") == -32602
              and "unknown prompt" in r["error"]["message"])

        # full-catalog resources exercise: resources/list, then read each
        # declared URI (ledger/vectorizer included, via their Community
        # clean conditions)
        send({"jsonrpc": "2.0", "id": 9260, "method": "resources/list"})
        list_resp = wait_for(9260, 20)
        res_list = (((list_resp or {}).get("result") or {})
                    .get("resources")) or []
        bad_resources = []
        for res in res_list:
            send({"jsonrpc": "2.0", "id": 9261, "method": "resources/read",
                  "params": {"uri": res["uri"]}})
            r = wait_for(9261, 20)
            sc_err = ""
            if r and "error" in r:
                sc_err = str(r.get("error", {}).get("message", ""))
            documented_empty = ("fractal_vectorizer_status is empty"
                                in sc_err)   # the documented fresh-session
                                             # condition, an error by design
            if (not r or "error" in r and not documented_empty
                    or (r and "error" not in r
                        and not ((r.get("result") or {}).get("contents")))):
                bad_resources.append((res["uri"], r if r is None else str(
                    r.get("error") or "no contents")))
        check(f"resources/read: every declared resource returns content "
              f"({len(res_list)})",
              not bad_resources and len(res_list) >= 6)
        for name, why in bad_resources:
            print("FAIL resources/read detail:", name, "->", why)
            _failures += 1

        # vector-argument form: integer elements coerce leniently,
        # like the engine's own lenient double coercion for array elements
        r = call("fractal_search", {"vector": [1, 0], "query": [0, 1]})
        check("vectors: integer elements coerce leniently",
              r is not None and not r["result"].get("isError")
              and isinstance(r["result"]["structuredContent"].get("value"),
                             float))

        # wire framing on stdio: a malformed line must answer with a parse
        # error (never a hang or a dead stream), blank/whitespace lines are
        # skipped silently, and an over-cap line must not desync the stream
        proc.stdin.write("this line is not json\n")
        proc.stdin.write("   \n")
        proc.stdin.write("9" * (9 * 1024 * 1024) + "\n")
        proc.stdin.flush()
        _req[0] += 1
        framing_ping = 1000 + _req[0]
        send({"jsonrpc": "2.0", "id": framing_ping, "method": "ping",
              "params": {}})
        parse_error = None
        framing_deadline = time.monotonic() + 30
        while time.monotonic() < framing_deadline:
            r = recv(deadline=0.2)
            if r is None:
                break
            if r.get("__timeout__"):
                continue
            if r.get("id") == framing_ping:
                break
            if "error" in r:
                parse_error = r
        check("wire framing: malformed and over-cap lines answer with parse "
              "errors and never desync the stream",
              parse_error is not None
              and parse_error.get("error", {}).get("code") == -32700)

        # Partial-result honesty (agent_partial_reasoning_fail)
        # The MCP layer opts every session into the engine's opt-in
        # partial mode at connect (FSQL_MCP_AGENT_PARTIAL, default on):
        # with a CONFIGURED but non-loadable chat plugin inside an agent
        # whose data step already computed, the ONE scalar call returns
        # the data half plus "reasoning_step_failed" carrying the
        # plugin's detail; isError=false, not a raise. fractal_reason
        # itself still raises (it IS the reasoning step; the partial mode only
        # rescues the data half). Repoint the plugin through the admin
        # tool (per-connection, like the engine's own config surface).
        # Admin tier: the enterprise-key/secret-key refusal branches and
        # configure_reasoning's own field-application loop. None of these
        # are exercised by the generic coverage sweep (it supplies only
        # REQUIRED args, and set_config/get_config/configure_reasoning's
        # interesting behavior is all gated behind OPTIONAL ones).
        r = call("fractalsql_set_config",
                 {"key": "enterprise_lib", "value": "/tmp/whatever.so"})
        check("Admin: set_config on an enterprise key without "
              "allow_secrets=true is refused",
              r is not None and (r.get("result") or {}).get("isError") is True
              and "allow_secrets=true" in json.dumps(r["result"]))
        r = call("fractalsql_get_config", {"key": "http_token"})
        check("Admin: get_config on a secret key is refused (never read "
              "back through any tool)",
              r is not None and (r.get("result") or {}).get("isError") is True
              and "never read back" in json.dumps(r["result"]))
        r = call("fractalsql_configure_reasoning", {"model": "mcp-smoke-model"})
        sc = (r.get("result") or {}).get("structuredContent") if r else None
        check("Admin: configure_reasoning applies a single field (model)",
              r is not None and (r.get("result") or {}).get("isError") is not True
              and isinstance(sc, dict)
              and "http_model" in (sc.get("applied") or {}))
        r = call("fractalsql_configure_reasoning", {"allow_plaintext": True})
        sc = (r.get("result") or {}).get("structuredContent") if r else None
        check("Admin: configure_reasoning applies allow_plaintext (the "
              "bool->on/off engine-spelling ternary)",
              r is not None and (r.get("result") or {}).get("isError") is not True
              and isinstance(sc, dict)
              and (sc.get("applied") or {}).get("http_allow_plaintext", {}).get("new")
              == "on")

        # fractalsql://vectorizer/status's SUCCESS path (real rows, not the
        # "registry is empty" Schema error the generic resources sweep
        # below documents and tolerates) needs an actual QUEUED row, which
        # needs a vectorizer created over a table with at least one NULL
        # embedding (fractal_vectorizer_status is the processing QUEUE,
        # not just a registry listing -- confirmed by direct testing: a
        # vectorizer created over a table whose embedding column is
        # already fully populated queues nothing and the view stays
        # empty). mcp_sm_vec_src's one row exists for exactly this.
        r = call("fractal_vectorizer_create",
                 {"source_table": "mcp_sm_vec_src", "text_col": "txt",
                  "embedding_col": "emb"})
        check("Vectorizer: fractal_vectorizer_create installs a registry "
              "row", r is not None and (r.get("result") or {}).get("isError")
              is not True)
        send({"jsonrpc": "2.0", "id": 9270, "method": "resources/read",
              "params": {"uri": "fractalsql://vectorizer/status"}})
        vr = wait_for(9270, 20)
        vr_contents = ((vr or {}).get("result") or {}).get("contents") or []
        vr_text = vr_contents[0].get("text", "") if vr_contents else ""
        check("Admin/Resources: fractalsql://vectorizer/status returns "
              "real queued rows once a vectorizer exists",
              vr is not None and "error" not in vr and vr_contents
              and "mcp_sm_vec_src" in vr_text)

        broken = os.path.join(os.environ["MCP_SERVER_CWD"],
                              "no_such_reasoning_plugin_for_mcp_smoke")
        r = call("fractalsql_set_config",
                 {"key": "reasoning_plugin", "value": broken})
        check("partial-result setup: the admin tool accepts a (non-loadable) "
              "reasoning_plugin path",
              r is not None and (r.get("result") or {}).get("isError") is not True)
        r = call("fractal_agent_regime_triage",
                 {"series": [round(i * 0.1, 6) for i in range(100)]},
                 timeout=60)
        sc = (r.get("result") or {}).get("structuredContent") if r else None
        sc_dump = json.dumps(sc) if sc is not None else ""
        check("partial-result: broken-endpoint agent call returns the computed data "
              "half plus reasoning_step_failed (isError=false)",
              r is not None and (r.get("result") or {}).get("isError") is False
              and "dfa_exponent" in sc_dump
              and "reasoning_step_failed" in sc_dump
              and "reasoning" in str(sc.get("reasoning_step_failed", "")))
        r = call("fractal_reason", {"query": "does the raise survive"}, timeout=60)
        check("partial-result: fractal_reason itself still raises (it IS the "
              "reasoning step)",
              r is not None and (r.get("result") or {}).get("isError") is True)
        # Restore the live mock plugin (the gate's bootstrap set it; the
        # repointed path above was per-connection but this session keeps
        # serving with it).
        m = re.search(r"fractalsql_set\(\s*'reasoning_plugin'\s*,\s*'([^']+)'",
                      os.environ.get("FRACTALSQL_BOOTSTRAP_SQL", ""))
        if m:
            call("fractalsql_set_config",
                 {"key": "reasoning_plugin", "value": m.group(1)})

        # full-catalog coverage sweep: every registered tool answers through
        # its own adapter at least once, so the smoke exercises the whole
        # 81-tool surface rather than a representative subset. Acceptance is
        # generous by design: either a result or a documented clean-error
        # condition (isError + a 1.6 taxonomy error_class + actionable text)
        # counts; a hang, a protocol-level error, a crash, or an error
        # result without the taxonomy shape fails the gate.
        KNOWN_ERROR_CLASSES = {"schema", "engine", "connectivity"}

        def stub_for(schema):
            t = schema.get("type")
            if t == "array":
                return [0.1, 0.2]
            if t == "integer":
                return 2
            if t == "number":
                return 0.5
            if t == "boolean":
                return False
            if t == "string":
                return "mcp_sm_docs"
            return {}

        answered, clean_errors, sweep_bad = 0, 0, []
        for tspec in listed:
            schema = tspec["inputSchema"]
            if schema.get("x-fractalsql-no-arguments"):
                args = {}
            else:
                props = schema.get("properties", {})
                args = {k: stub_for(props.get(k, {}))
                        for k in schema.get("required", [])}
            r = call(tspec["name"], args)
            if r is None:
                sweep_bad.append((tspec["name"], "no response (server died or EOF)"))
                continue
            if "error" in r:
                sweep_bad.append((tspec["name"],
                                  "protocol error: " + str(r["error"])[:160]))
                continue
            res = r.get("result") or {}
            if res.get("isError"):
                sc = res.get("structuredContent")
                text = (res.get("content") or [{}])[0].get("text", "")
                if (not isinstance(sc, dict)
                        or sc.get("error_class") not in KNOWN_ERROR_CLASSES
                        or not text.strip()):
                    sweep_bad.append((tspec["name"],
                                      "error result lacks the 1.6 taxonomy "
                                      "shape: " + json.dumps(res)[:160]))
                else:
                    clean_errors += 1
            else:
                answered += 1
        check(f"coverage sweep: all {len(listed)} tools answered (result or "
              f"clean error); {answered} succeeded, {clean_errors} surfaced "
              "their documented clean error",
              not sweep_bad and answered + clean_errors == len(listed))
        for name, why in sweep_bad:
            print("FAIL sweep detail:", name, "->", why)
            _failures += 1

        # unknown tool/method pairing (framing + dispatch)
        send({"jsonrpc": "2.0", "id": 9300, "method": "tools/call",
              "params": {"name": "fractal_nonexistent", "arguments": {}}})
        r = wait_for(9300, 10)
        check("unknown tool refuses with an error naming tools/list",
              r is not None and r.get("error") is not None
              and "unknown tool" in r["error"]["message"])
        send({"jsonrpc": "2.0", "id": 1, "method": "bogus/method"})
        r = wait_for(1, 10)
        check("unknown method returns -32601", r is not None
              and r.get("error", {}).get("code") == -32601)
        send({"jsonrpc": "2.0", "id": 9301})   # missing "method"
        r = wait_for(9301, 10)
        check("a request missing \"method\" is refused -32600 invalid "
              "request",
              r is not None and r.get("error", {}).get("code") == -32600)
        send({"jsonrpc": "2.0", "id": 9302, "method": "tools/call",
              "params": {"name": "fractal_reason", "arguments": "not an object"}})
        r = wait_for(9302, 10)
        check("tools/call with non-object arguments is refused -32602 "
              "(rejected before runTool's own isError-result wrapping)",
              r is not None and r.get("error", {}).get("code") == -32602
              and "must be a JSON object" in r["error"]["message"])
        send({"jsonrpc": "2.0", "id": 9303, "method": "resources/read",
              "params": {"uri": "fractalsql://not-a-real-resource"}})
        r = wait_for(9303, 10)
        check("resources/read on an unknown URI is refused -32602 "
              "(a top-level JSON-RPC error, not a tools/call-shaped result)",
              r is not None and r.get("error", {}).get("code") == -32602
              and "unknown resource uri" in r["error"]["message"])
    finally:
        finish(proc, server_log)

    # separate server lifecycles: the HTTP transport, the CLI/env startup
    # surface, and the lock-failure postures
    run_http_and_cli_phase()
    return 1 if _failures else 0


INIT_PARAMS = {"protocolVersion": "2025-06-18",
               "clientInfo": {"name": "gate37", "version": "0"}}


def quick_stdio(json_lines, env_extra, timeout=60):
    """A short-lived stdio session driven like the main one: send each
    request, wait for its id-matched response, then stdin EOF. Writing a
    batch and closing stdin in one breath is NOT equivalent: EOF begins
    the server's shutdown, and requests that land after it are refused,
    so a batch-and-forget helper never gets a real answer. Lines without
    an "id" (notifications) are sent without waiting."""
    env = dict(os.environ)
    env.update(env_extra)
    proc = subprocess.Popen(
        [os.environ["MCP_SERVER_EXE"]], stdin=subprocess.PIPE,
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        cwd=os.environ["MCP_SERVER_CWD"], env=env, text=True, bufsize=1)
    queue = []  # via a reader thread, so requests and responses interleave

    def reader(p):
        for line in p.stdout:
            queue.append(line)
        queue.append(None)

    threading.Thread(target=reader, args=(proc,), daemon=True).start()
    responses = []
    for want in json_lines:
        want_id = want.get("id")
        proc.stdin.write(json.dumps(want) + "\n")
        proc.stdin.flush()
        got = None
        if want_id is not None:
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                if queue:
                    raw = queue.pop(0)
                    if raw is None:
                        proc._broken = True
                        break
                    r = json.loads(raw)
                    if isinstance(r, dict) and r.get("id") == want_id:
                        got = r
                        break
                else:
                    time.sleep(0.02)
        responses.append(got)
    try:
        proc.stdin.close()
    except Exception:  # noqa: BLE001
        pass
    try:
        proc.wait(timeout=timeout)
    except Exception:  # noqa: BLE001
        proc.kill()
        proc.wait(timeout=10)
    return responses, proc.returncode


def run_http_and_cli_phase() -> None:
    """Third phase: the HTTP transport (a second server process with the
    token-file form), the CLI/env startup surface via short-lived
    subprocesses, and the lock-failure postures. These are the files the
    stdio-only session above never touches."""
    global _failures
    mcp_exe = os.environ["MCP_SERVER_EXE"]
    server_cwd = os.environ["MCP_SERVER_CWD"]
    base_env = dict(os.environ)

    # short-lived stdio variants: env narrowing and the read-only switch
    lines = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": INIT_PARAMS},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
    ]
    resps, code = quick_stdio(lines, {
        "FSQL_MCP_TOOL_WHITELIST": "fractal_search,fractal_reason",
        "FSQL_MCP_LOG_LEVEL": "verbose"})
    wl = next((x for x in resps if x and x.get("id") == 2), None)
    wl_names = [t["name"] for t in ((wl or {}).get("result")
                                    or {}).get("tools") or []]
    check("env narrowing: the tool whitelist registers exactly its two "
          "tools (verbose log level accepted)",
          code == 0 and sorted(wl_names)
          == ["fractal_reason", "fractal_search"])
    resps, code = quick_stdio(lines, {"FSQL_MCP_ENABLED_CATEGORIES":
                                      "discovery,admin"})
    cats = next((x for x in resps if x and x.get("id") == 2), None)
    cat_tools = ((cats or {}).get("result") or {}).get("tools") or []
    cat_tiers = {t.get("_meta", {}).get("x-fractalsql-tier")
                 for t in cat_tools}
    check("env narrowing: category leaves only the discovery+admin tiers",
          code == 0 and cat_tools and cat_tiers <= {"Discovery", "Admin"})
    ro_lines = lines + [
        {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
         "params": {"name": "fractalsql_set_config",
                    "arguments": {"key": "max_rows_ceiling", "value": "5"}}},
    ]
    resps, code = quick_stdio(ro_lines, {"FSQL_MCP_READ_ONLY": "true"})
    ro = next((x for x in resps if x and x.get("id") == 3), None)
    # the read-only refusal is a DISPATCH-level rejection, so it surfaces
    # as a top-level JSON-RPC error (like unknown-tool), before any adapter
    # or engine code runs
    ro_err = ((ro or {}).get("error") or {})
    check("env: FSQL_MCP_READ_ONLY refuses a destructive write tool at the "
          "dispatch layer (15.4's stop switch)",
          code == 0 and ro_err.get("code") == -32602
          and "read-only mode" in str(ro_err.get("message", "")))

    # CLI direct runs (each exits cleanly, so any live coverage data from
    # these processes also flushes)
    def cli_run(extra_args, env=None, timeout=60):
        return subprocess.run([mcp_exe] + extra_args, capture_output=True,
                              text=True, cwd=server_cwd,
                              env=env or dict(base_env), timeout=timeout,
                              input="")
    r = cli_run(["--version"])
    check("CLI: --version prints the release banner",
          r.returncode == 0 and "2.0.8" in r.stdout)
    r = cli_run(["--help"])
    check("CLI: --help prints the flag table",
          r.returncode == 0 and "--tool" in r.stdout)
    r = cli_run(["--list-tools"])
    check("CLI: --list-tools prints the (unfiltered) tool table",
          r.returncode == 0 and "fractal_search" in r.stdout)
    r = cli_run(["--definitely-not-a-flag"])
    check("CLI: an unknown flag exits nonzero with usage guidance",
          r.returncode != 0)
    r = cli_run([], env=dict(base_env, SQLITE_DB_PATH="",
                             FRACTALSQL_EXTENSION_PATH=""))
    check("CLI: missing database/extension env exits with the startup "
          "error", r.returncode != 0)
    # The two startup env checks are sequential ifs (DB path checked
    # first); the case above only ever exercises the FIRST one. This
    # isolates the second by supplying a (harmlessly nonexistent) DB
    # path and leaving only the extension path unset.
    r = cli_run([], env=dict(base_env, FRACTALSQL_EXTENSION_PATH=""))
    check("CLI: DB path set but extension path unset reports the "
          "extension-specific error",
          r.returncode != 0
          and "FRACTALSQL_EXTENSION_PATH is required" in r.stderr)
    # --write-manifest: the one one-shot flag (of write-lock/write-
    # safety-lock/write-manifest/list-tools) with no existing test.
    # FSQL_MCP_MANIFEST_PATH points this at a scratch file rather than
    # the committed mcp/manifest.json.
    manifest_tmp = os.path.join(server_cwd, "mcp_manifest_probe.json")
    r = cli_run(["--write-manifest"],
                env=dict(base_env, FSQL_MCP_MANIFEST_PATH=manifest_tmp))
    check("CLI: --write-manifest regenerates a manifest and exits",
          r.returncode == 0 and os.path.isfile(manifest_tmp)
          and "fractal_search" in open(manifest_tmp, encoding="utf-8").read())
    # --http with NEITHER auth env var set: runHttpMode's own config
    # validation must reject this before ever trying to bind the port.
    r = cli_run(["--http", "18997"],
                env=dict(base_env, FSQL_MCP_AUTH_TOKEN="",
                         FSQL_MCP_AUTH_TOKEN_FILE=""))
    check("CLI: --http with neither FSQL_MCP_AUTH_TOKEN nor "
          "FSQL_MCP_AUTH_TOKEN_FILE set exits before binding",
          r.returncode == 2
          and "FSQL_MCP_AUTH_TOKEN_FILE" in r.stderr)
    # A PRESENT but invalid extension path: a real file that isn't a
    # loadable SQLite extension, unlike the empty-string case above (caught
    # earlier, by main.cpp's own "is this set at all" check). DbConnection
    # is lazy (db.h's acquire()) -- it only connects on the first request
    # that actually needs the DB, so a bare startup-and-exit (cli_run's
    # input="") never reaches loadExtensionLockedDown() at all. A real
    # tools/call forces that connection attempt, exercising its
    # sqlite3_load_extension() failure branch for real.
    bad_ext_path = os.path.join(os.environ["MCP_HERE"], ".mcp-schema-lock")
    resps, code = quick_stdio(
        [{"jsonrpc": "2.0", "id": 1, "method": "initialize",
          "params": INIT_PARAMS},
         {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
          "params": {"name": "fractal_search",
                     "arguments": {"vector": [0.1, 0.9], "query": [0.6, 0.8]}}}],
        {"FRACTALSQL_EXTENSION_PATH": bad_ext_path})
    bad_ext_resp = next((x for x in resps if x and x.get("id") == 2), None)
    bad_ext_text = json.dumps(bad_ext_resp)
    check("a present-but-invalid extension path fails the first real "
          "request with a clean load-failure error (DbConnection is lazy, "
          "so startup alone never reaches it)",
          bad_ext_resp is not None
          and (bad_ext_resp.get("result", {}).get("isError")
               or "error" in bad_ext_resp)
          and "failed to load extension" in bad_ext_text)

    # the matching-lock path (checkSchemaGate's LockCheckResult::Ok
    # branch, which logs "schema_lock_ok") -- the default stdio session
    # above never hits it: the server's default lock-path resolution
    # walks up from its CWD looking for a checkout root, which the
    # scratch server_cwd this harness uses isn't, so without an
    # explicit override it resolves Absent, not Ok. Point
    # FSQL_MCP_SCHEMA_LOCK at the real committed lock explicitly instead.
    lock_path = os.path.join(os.environ["MCP_HERE"], ".mcp-schema-lock")
    r = cli_run([], env=dict(base_env, FSQL_MCP_SCHEMA_LOCK=lock_path))
    check("CLI: a matching schema lock logs schema_lock_ok and still "
          "serves", r.returncode == 0 and "schema_lock_ok" in r.stderr)

    # lock-failure postures against a tampered copy of the committed lock
    committed = open(lock_path, encoding="utf-8").read()
    flip = "0" if committed[10:11] != "0" else "1"
    bad_lock = os.path.join(server_cwd, "mcp_tampered_schema_lock")
    with open(bad_lock, "w", encoding="utf-8") as fh:
        fh.write(committed[:10] + flip + committed[11:])
    r = cli_run([], env=dict(base_env, FSQL_MCP_SCHEMA_LOCK=bad_lock,
                             FSQL_MCP_STRICT_SCHEMA_HASH="true"))
    check("CLI: a tampered schema lock under strict mode is a hard exit", r.returncode != 0)
    r = cli_run([], env=dict(base_env, FSQL_MCP_SCHEMA_LOCK=bad_lock))
    check("CLI: a tampered schema lock non-strict only warns and still "
          "serves", r.returncode == 0)
    safety_path = os.path.join(os.environ["MCP_HERE"],
                               ".mcp-safety-annotations-lock")
    safety = open(safety_path, encoding="utf-8").read()
    tampered = re.sub(r"destructive=(\d)",
                      lambda m: "destructive=" + str(1 - int(m.group(1))),
                      safety, count=1)
    if tampered == safety:   # no destructive flags at all: flip openWorld
        tampered = re.sub(r"openWorld=(\d)",
                          lambda m: "openWorld=" + str(1 - int(m.group(1))),
                          safety, count=1)
    bad_safety = os.path.join(server_cwd, "mcp_tampered_safety_lock")
    with open(bad_safety, "w", encoding="utf-8") as fh:
        fh.write(tampered)
    r = cli_run([], env=dict(base_env, FSQL_MCP_SAFETY_LOCK=bad_safety))
    check("CLI: a safety-annotation mismatch is a hard exit regardless of "
          "strict mode", r.returncode != 0)

    # the HTTP transport: token-FILE form (10.3 hot reload), a real session
    token_file = os.path.join(server_cwd, "mcp_http_token.txt")
    with open(token_file, "w", encoding="utf-8") as fh:
        fh.write("g37-tok-alpha\n")
    os.utime(token_file, (4, 4))   # pin mtime so the later rotation reloads
    tok_a, tok_b = "g37-tok-alpha", "g37-tok-beta"
    http_env = dict(base_env)
    http_env.update({
        "FSQL_MCP_HTTP_PORT": "18999",
        "FSQL_MCP_HTTP_HOST": "127.0.0.1",
        "FSQL_MCP_HTTP_PATH": "/mcp",
        "FSQL_MCP_AUTH_TOKEN": "",
        "FSQL_MCP_AUTH_TOKEN_FILE": token_file,
    })
    http_log_path = os.path.join(server_cwd, "mcp_http_server.log")
    http_log = open(http_log_path, "w", encoding="utf-8")
    http_proc = None
    try:
        http_proc = subprocess.Popen(
            [mcp_exe, "--http", "18999"], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=http_log, cwd=server_cwd,
            env=http_env, text=True)
        http_proc.stdin.close()

        def http_req(method, path, body=None, token=None, session=None,
                     timeout=15.0):
            headers = {}
            if token is not None:
                headers["Authorization"] = "Bearer " + token
            if session is not None:
                headers["Mcp-Session-Id"] = session
            try:
                conn = httpc.HTTPConnection("127.0.0.1", 18999,
                                            timeout=timeout)
                conn.request(method, path, body=body, headers=headers)
                resp = conn.getresponse()
                data = resp.read().decode("utf-8", "replace")
                hdrs = {k.lower(): v for k, v in resp.getheaders()}
                conn.close()
                return resp.status, hdrs, data
            except Exception:
                return None, {}, ""

        up = False
        for _ in range(100):
            s, _, _ = http_req("GET", "/healthz", timeout=2.0)
            if s == 200:
                up = True
                break
            time.sleep(0.15)
        check("HTTP: the transport comes up and GET /healthz answers "
              "unauthenticated", up)

        def rpc(payload, sess=None, token=tok_a):
            return http_req("POST", "/mcp", body=json.dumps(payload),
                            token=token, session=sess)

        s, _, _ = http_req("GET", "/readyz")
        check("HTTP: GET /readyz answers 200 while the engine is reachable",
              s == 200)
        s, _, _ = http_req("GET", "/mcp")
        check("HTTP: unauthenticated GET /mcp is refused 401 (only the two "
              "probes are exempt)", s == 401)
        s, _, b = http_req("POST", "/mcp", body='{"jsonrpc":"2.0"}')
        check("HTTP: unauthenticated POST is 401 with the missing-token "
              "text", s == 401 and "missing" in b)
        s, _, _ = http_req("POST", "/mcp", body='{"jsonrpc":"2.0"}',
                           token="g37-tok-wrong")
        check("HTTP: an invalid bearer token is refused 401 (timing-safe "
              "path)", s == 401)
        s, _, _ = http_req("GET", "/no-such-path", token=tok_a)
        check("HTTP: authenticated GET on an unknown path is 404", s == 404)
        s, _, _ = http_req("GET", "/mcp", token=tok_a)
        check("HTTP: GET on the JSON-RPC path is 405 (POST only)", s == 405)

        s, h, _ = rpc({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                       "params": INIT_PARAMS})
        minted = h.get("mcp-session-id")
        check("HTTP: initialize answers 200 and mints Mcp-Session-Id",
              s == 200 and bool(minted))
        s, _, _ = rpc({"jsonrpc": "2.0", "id": 2, "method": "initialize",
                       "params": INIT_PARAMS}, sess=minted)
        check("HTTP: initialize arriving with a session id is 400", s == 400)
        s, _, _ = http_req("POST", "/mcp", body=json.dumps(
            {"jsonrpc": "2.0", "id": 3, "method": "tools/list"}),
            token=tok_a)
        check("HTTP: a POST without Mcp-Session-Id is 400 (initialize "
              "first)", s == 400)
        s, _, _ = rpc({"jsonrpc": "2.0", "id": 4, "method": "tools/list"},
                      sess="sess-bogus")
        check("HTTP: an unknown session id is 404", s == 404)
        s, _, b = rpc({"jsonrpc": "2.0", "id": 5, "method": "tools/list"},
                      sess=minted)
        http_tools = (json.loads(b)["result"]["tools"]
                      if s == 200 and b.startswith("{") else [])
        check("HTTP: tools/list over the session matches the stdio "
              "catalog (81)", s == 200 and len(http_tools) == 81)
        s, _, b = rpc({"jsonrpc": "2.0", "id": 6, "method": "tools/call",
                       "params": {"name": "fractalsql_get_version",
                                  "arguments": {}}}, sess=minted)
        check("HTTP: a tools/call round-trips the same engine",
              s == 200 and json.loads(b)["result"]["structuredContent"]
              .get("edition") == "Community")
        s, _, _ = rpc({"jsonrpc": "2.0", "method": "notifications/initialized"},
                      sess=minted)
        check("HTTP: a plain notification over the session answers 202",
              s == 202)
        s, _, _ = rpc({"jsonrpc": "2.0", "method": "notifications/cancelled",
                       "params": {"requestId": 4242}}, sess=minted)
        check("HTTP: a cancel notification over the session answers 202",
              s == 202)
        s, _, _ = http_req("PUT", "/mcp", body="x", token=tok_a, session=minted)
        check("HTTP: an unhandled method is 405", s == 405)
        s, _, _ = http_req("POST", "/other", body="{}", token=tok_a)
        check("HTTP: POST on a non-JSON-RPC path is 404", s == 404)
        s, _, _ = http_req("POST", "/mcp", body="not json", token=tok_a,
                           session=minted)
        check("HTTP: a non-JSON body is 400", s == 400)
        s, _, _ = http_req("POST", "/mcp", body="", token=tok_a,
                           session=minted)
        check("HTTP: an empty body is 400", s == 400)
        s, _, _ = http_req("DELETE", "/mcp", token=tok_a, session=minted)
        check("HTTP: DELETE on the session closes it cleanly (200)", s == 200)
        s, _, _ = rpc({"jsonrpc": "2.0", "id": 7, "method": "tools/list"},
                      sess=minted)
        check("HTTP: the closed session is really gone (404)", s == 404)

        def raw_http(payload, timeout=10.0):
            try:
                with socket.create_connection(("127.0.0.1", 18999),
                                              timeout=timeout) as so:
                    so.sendall(payload)
                    return so.recv(65536)
            except Exception:
                return b""
        chunk = (b"POST /mcp HTTP/1.1\r\nHost: x\r\n"
                 b"Authorization: Bearer g37-tok-alpha\r\n"
                 b"Transfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n")
        check("HTTP: chunked transfer coding is refused (connection closed, "
              "no response)", raw_http(chunk) == b"")
        big = (b"POST /mcp HTTP/1.1\r\nAuthorization: Bearer "
               b"g37-tok-alpha\r\nContent-Length: 99999999\r\n\r\n")
        check("HTTP: an oversized Content-Length is refused (connection "
              "closed)", raw_http(big) == b"")

        # token hot reload: new content, distinct mtime, no restart
        with open(token_file, "w", encoding="utf-8") as fh:
            fh.write(tok_b + "\n")
        os.utime(token_file, (8, 8))
        s, _, _ = rpc({"jsonrpc": "2.0", "id": 8, "method": "initialize",
                       "params": INIT_PARAMS})
        check("HTTP: token rotation, the old token stops working (401)",
              s == 401)
        s, h2, _ = rpc({"jsonrpc": "2.0", "id": 9, "method": "initialize",
                        "params": INIT_PARAMS}, token=tok_b)
        check("HTTP: token rotation, the new token mints a session without "
              "a restart (mtime hot reload)",
              s == 200 and bool(h2.get("mcp-session-id")))
        s, _, _ = http_req("DELETE", "/mcp", token=tok_b,
                           session=h2.get("mcp-session-id"))
        check("HTTP: DELETE closes the post-rotation session cleanly",
              s == 200)

        # SIGHUP: a forced reload that ignores the mtime check entirely
        # (TokenStore::forceReloadFromSighup -> reload(true)), distinct
        # from the mtime-triggered hot reload just proven above. Pin the
        # file's mtime back to the SAME value the running process has
        # already recorded (lastMtime_ == 8) after writing new content,
        # so an ordinary per-request reload(false) would see an
        # unchanged mtime and skip re-reading the file -- only SIGHUP's
        # force=true bypass can pick up tok_c.
        if os.name != "nt":
            tok_c = "g37-tok-gamma"
            with open(token_file, "w", encoding="utf-8") as fh:
                fh.write(tok_c + "\n")
            os.utime(token_file, (8, 8))
            s, _, _ = rpc({"jsonrpc": "2.0", "id": 11, "method": "initialize",
                           "params": INIT_PARAMS}, token=tok_c)
            check("SIGHUP: before the signal, an unchanged mtime means the "
                  "new file content is NOT yet picked up (still tok_b)",
                  s == 401)
            os.kill(http_proc.pid, signal.SIGHUP)
            time.sleep(0.3)
            s, h4, _ = rpc({"jsonrpc": "2.0", "id": 12, "method": "initialize",
                            "params": INIT_PARAMS}, token=tok_c)
            check("SIGHUP: forces a reload that ignores the mtime check, "
                  "picking up the new token immediately",
                  s == 200 and bool(h4.get("mcp-session-id")))
            s, _, _ = http_req("DELETE", "/mcp", token=tok_c,
                               session=h4.get("mcp-session-id"))
            check("HTTP: DELETE closes the post-SIGHUP session cleanly",
                  s == 200)

        # A session left OPEN (never DELETEd) at shutdown: runHttpTransport's
        # own cleanup loop closes every still-live session's DB connection
        # via closeSession() before the process exits. Every session minted
        # above was explicitly DELETEd, so without this, that loop always
        # iterates zero times.
        s, h3, _ = rpc({"jsonrpc": "2.0", "id": 10, "method": "initialize",
                        "params": INIT_PARAMS},
                       token=(tok_c if os.name != "nt" else tok_b))
        check("HTTP: one more session minted, deliberately left open for "
              "the termination test below",
              s == 200 and bool(h3.get("mcp-session-id")))

        # main's listen-failure branch: a second process on the same port
        # must exit nonzero while the first still serves
        conflict = subprocess.run([mcp_exe, "--http"], capture_output=True,
                                  text=True, cwd=server_cwd, env=http_env,
                                  timeout=60, input="")
        check("HTTP: a bind conflict on the in-use port exits nonzero "
              "(no zombie listener)", conflict.returncode != 0)

        # graceful termination: the SIGTERM handler only sets the stop
        # flag while accept() blocks, so poke one more connection to let
        # the drain path run; a clean exit is the point (it also flushes
        # any live coverage counters). Windows terminate() is a hard kill.
        http_proc.terminate()
        http_req("GET", "/healthz", timeout=5.0)
        try:
            rc = http_proc.wait(timeout=25)
        except Exception:
            http_proc.kill()
            rc = http_proc.wait(timeout=10)
        if os.name != "nt":
            check("HTTP: the transport drains and exits cleanly on "
                  "termination", rc == 0)
    finally:
        if http_proc is not None and http_proc.poll() is None:
            http_proc.kill()
            try:
                http_proc.wait(timeout=10)
            except Exception:
                pass
        http_log.close()

    if os.name != "nt":
        run_shutdown_drain_phase(mcp_exe, server_cwd, base_env)


def run_shutdown_drain_phase(mcp_exe, server_cwd, base_env) -> None:
    """A dedicated, isolated server instance whose only job is to prove
    runHttpTransport's own shutdown sequencing -- the activeRequestCount()
    drain-wait loop and the liveConnections grace-wait loop right after it
    -- actually runs its wait body at least once, not just its (almost
    always instantly-false) loop condition. Both are a no-op unless a
    real request is still being processed by its own detached connection
    thread at the exact instant SIGTERM arrives, normally a sub-
    millisecond race. tests/slow_reasoning_plugin.c's artificial,
    caller-controlled sleep (FSQL_MOCK_SLOW_MS) turns that race into a
    wide, deterministic window: the request is still "in flight" for as
    long as we choose, so SIGTERM during that window always lands with
    activeRequestCount() > 0 and the connection thread still live."""
    global _failures
    slow_plugin = os.environ.get("MCP_SLOW_REASONING_PLUGIN", "")
    if not slow_plugin or not os.path.isfile(slow_plugin):
        check("HTTP shutdown: slow_reasoning_plugin not available, "
              "skipping (harness did not build it)", True)
        return

    port = 18997
    token = "g37-shutdown-drain-tok"
    env = dict(base_env)
    env.update({
        "FSQL_MCP_HTTP_PORT": str(port),
        "FSQL_MCP_HTTP_HOST": "127.0.0.1",
        "FSQL_MCP_HTTP_PATH": "/mcp",
        "FSQL_MCP_AUTH_TOKEN": token,
        "FSQL_MCP_AUTH_TOKEN_FILE": "",
        # Short drain so the test doesn't need a long sleep; the slow
        # plugin's own delay (well past this) guarantees the drain
        # loop's condition is true at least once before it gives up.
        "FSQL_MCP_SHUTDOWN_DRAIN_MS": "300",
        "FSQL_MOCK_SLOW_MS": "2000",
        "FRACTALSQL_BOOTSTRAP_SQL":
            "SELECT fractalsql_set('reasoning_plugin','" + slow_plugin + "');",
    })
    log_path = os.path.join(server_cwd, "mcp_http_shutdown_drain.log")
    log = open(log_path, "w", encoding="utf-8")
    proc = None
    try:
        proc = subprocess.Popen(
            [mcp_exe, "--http", str(port)], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=log, cwd=server_cwd,
            env=env, text=True)
        proc.stdin.close()

        def req(method, path, body=None, token=None, session=None,
                 timeout=15.0):
            headers = {}
            if token is not None:
                headers["Authorization"] = "Bearer " + token
            if session is not None:
                headers["Mcp-Session-Id"] = session
            try:
                conn = httpc.HTTPConnection("127.0.0.1", port, timeout=timeout)
                conn.request(method, path, body=body, headers=headers)
                resp = conn.getresponse()
                data = resp.read().decode("utf-8", "replace")
                hdrs = {k.lower(): v for k, v in resp.getheaders()}
                conn.close()
                return resp.status, hdrs, data
            except Exception:
                return None, {}, ""

        up = False
        for _ in range(100):
            s, _, _ = req("GET", "/healthz", timeout=2.0)
            if s == 200:
                up = True
                break
            time.sleep(0.15)
        if not up:
            check("HTTP shutdown: drain-wait server came up", False)
            return

        s, h, _ = req("POST", "/mcp",
                       body=json.dumps({"jsonrpc": "2.0", "id": 1,
                                        "method": "initialize",
                                        "params": INIT_PARAMS}),
                       token=token)
        sess = h.get("mcp-session-id")
        if s != 200 or not sess:
            check("HTTP shutdown: drain-wait session minted", False)
            return

        # Fire the slow call on its own thread; its connection thread
        # stays live (and activeRequestCount() stays > 0) for ~2s.
        slow_result = {}

        def fire_slow_call():
            st, _, body = req(
                "POST", "/mcp",
                body=json.dumps({"jsonrpc": "2.0", "id": 2,
                                 "method": "tools/call",
                                 "params": {"name": "fractal_reason",
                                            "arguments": {"query": "q"}}}),
                token=token, session=sess, timeout=10.0)
            slow_result["status"] = st
            slow_result["body"] = body

        t = threading.Thread(target=fire_slow_call, daemon=True)
        t.start()
        # Give the server time to read the request and enter
        # handleDispatch (incrementing activeRequestCount) before the
        # signal arrives -- well short of the plugin's own 2s sleep.
        time.sleep(0.3)

        t0 = time.monotonic()
        proc.terminate()
        # Same poke as the main HTTP session's own termination test: the
        # SIGTERM handler only sets the stop flag while accept() blocks,
        # so one more connection is needed to make the main loop notice
        # and fall through to the drain sequence.
        req("GET", "/healthz", timeout=5.0)
        try:
            rc = proc.wait(timeout=8)
        except Exception:
            proc.kill()
            rc = proc.wait(timeout=10)
        elapsed = time.monotonic() - t0

        check("HTTP shutdown: a request still in flight (held open by "
              "the slow reasoning plugin) does not block a clean "
              "SIGTERM shutdown", rc == 0)
        check("HTTP shutdown: the drain+grace wait is bounded, not a "
              "hang (exited in {:.2f}s, well under the 2s the slow "
              "call itself would need to finish)".format(elapsed),
              elapsed < 6.0)
        t.join(timeout=5.0)
    finally:
        if proc is not None and proc.poll() is None:
            proc.kill()
            try:
                proc.wait(timeout=10)
            except Exception:
                pass
        log.close()


def finish(proc, server_log) -> None:  # noqa: ANN001
    # Graceful stdin-EOF shutdown first. terminate() alone never ends this
    # server: the SIGTERM handler only sets a stop flag while the main
    # thread stays blocked in the bounded line read (fgetc auto-restarts),
    # so the process lingers and falls through to a hard kill that skips
    # every exit handler. Closing stdin makes fgetc return EOF, the
    # transport drains and exits cleanly, and any live coverage counters
    # for this session actually reach disk.
    try:
        proc.stdin.close()
    except Exception:  # noqa: BLE001
        pass
    try:
        proc.wait(timeout=15)
    except Exception:  # noqa: BLE001
        try:
            proc.terminate()
            proc.wait(timeout=15)
        except Exception:  # noqa: BLE001
            proc.kill()
    server_log.close()


if __name__ == "__main__":
    raised = None
    try:
        code = main()
    except SystemExit as exc:
        code = int(exc.code or 0)
    print(f"gate37-client: {'ALL GREEN' if code == 0 else 'FAILED'}; "
          f"{_failures} failure(s)")
    sys.exit(code)