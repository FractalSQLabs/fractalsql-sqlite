#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs

"""Gate-38 client driver for the fractalsql-sqlite-mcp direct-TLS mode
(--https). Driven by build_test.sh's gate_38_mcp_https (and the matching
PowerShell gate): the gate itself generates the throwaway self-signed
cert/key (via the openssl CLI) and skips the whole gate if openssl isn't
on PATH; this driver only ever sees the resulting PEM paths.

Deliberately narrow in scope: gate 37's own HTTP phase already exhausts
the plaintext HTTP transport's behavior (sessions, auth, framing,
refusal shapes, concurrency). This driver proves the THREE things that
are specific to --https and untested anywhere else:
  1. fail-fast misconfiguration: --https with no cert/key, and --https
     with a cert/key that doesn't load, both exit nonzero immediately,
     never falling back to plaintext or hanging.
  2. the listening port actually speaks TLS, not plaintext HTTP (a bare
     HTTP request against it gets no valid HTTP response).
  3. the full authenticated JSON-RPC round trip works over TLS, and the
     Bearer-token check still applies underneath it (TLS is additive,
     never a substitute for the token).

Input (environment, all required unless noted):
  MCP_SERVER_EXE            the fractalsql-sqlite-mcp binary just built
  MCP_SERVER_CWD            the server process's working directory
  SQLITE_DB_PATH            the harness's throwaway DB
  FRACTALSQL_EXTENSION_PATH the just-built fractalsql .so/.dylib/.dll
  MCP_HTTPS_PORT            a free localhost port, distinct from gate
                            37's own HTTP-phase port
  MCP_HTTPS_CERT            PEM cert path (the gate's throwaway self-signed one)
  MCP_HTTPS_KEY             PEM key path

Exits 0 on all-pass, 1 otherwise; prints PASS/FAIL lines the gates
relabel."""

from __future__ import annotations

import http.client
import json
import os
import socket
import ssl
import subprocess
import sys
import time

_failures = 0


def check(label: str, cond: bool) -> bool:
    global _failures
    print(("PASS " if cond else "FAIL ") + label)
    if not cond:
        _failures += 1
    return bool(cond)


def https_conn(port: int, timeout: float = 15.0) -> http.client.HTTPSConnection:
    # The throwaway cert is self-signed for 127.0.0.1; this driver only
    # ever talks to the server it just spawned, so disabling verification
    # is the correct choice here (there is no CA to verify against) and
    # not a stand-in for a real deployment's trust posture.
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return http.client.HTTPSConnection("127.0.0.1", port, timeout=timeout, context=ctx)


def https_req(port, method, path, body=None, token=None, session=None, timeout=15.0):
    headers = {}
    if token is not None:
        headers["Authorization"] = "Bearer " + token
    if session is not None:
        headers["Mcp-Session-Id"] = session
    try:
        conn = https_conn(port, timeout=timeout)
        conn.request(method, path, body=body, headers=headers)
        resp = conn.getresponse()
        data = resp.read().decode("utf-8", "replace")
        hdrs = {k.lower(): v for k, v in resp.getheaders()}
        conn.close()
        return resp.status, hdrs, data
    except Exception:
        return None, {}, ""


def plaintext_probe(port: int, timeout: float = 3.0) -> bool:
    """True if a bare HTTP request against the port gets back something
    that looks like an HTTP response -- i.e. the port is NOT TLS-only."""
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=timeout) as sock:
            sock.sendall(b"GET /healthz HTTP/1.1\r\nHost: x\r\n\r\n")
            data = sock.recv(256)
        return data.startswith(b"HTTP/1.")
    except Exception:
        return False


def cli_run(mcp_exe, cwd, extra_args, env, timeout=30):
    return subprocess.run([mcp_exe] + extra_args, capture_output=True, text=True,
                          cwd=cwd, env=env, timeout=timeout, input="")


def main() -> int:
    mcp_exe = os.environ["MCP_SERVER_EXE"]
    cwd = os.environ["MCP_SERVER_CWD"]
    port = int(os.environ["MCP_HTTPS_PORT"])
    cert = os.environ["MCP_HTTPS_CERT"]
    key = os.environ["MCP_HTTPS_KEY"]
    base_env = dict(os.environ)
    token = "g38-https-tok"

    common_env = dict(base_env, FSQL_MCP_AUTH_TOKEN=token, FSQL_MCP_HTTP_PORT=str(port),
                      FSQL_MCP_HTTP_HOST="127.0.0.1", FSQL_MCP_HTTP_PATH="/mcp")

    # 1a. fail-fast: --https with no cert/key configured at all.
    r = cli_run(mcp_exe, cwd, ["--https", str(port)], dict(common_env))
    check("--https with no cert/key configured exits nonzero immediately "
          "(never silently serves plaintext)",
          r.returncode != 0 and ("cert" in r.stderr.lower() or "key" in r.stderr.lower()))

    # 1b. fail-fast: --https with a cert file that doesn't exist/load.
    r = cli_run(mcp_exe, cwd, ["--https", str(port), "--tls-cert",
                              os.path.join(cwd, "mcp_https_no_such_cert.pem"),
                              "--tls-key", key], dict(common_env))
    check("--https with an unloadable cert file exits nonzero (TLS init "
          "failure, not a hang or a crash)", r.returncode != 0)

    # 2+3. the real server: TLS-only listening, auth still enforced, and a
    # full authenticated JSON-RPC round trip over the direct-TLS transport.
    log_path = os.path.join(cwd, "mcp_https_server.log")
    log = open(log_path, "w", encoding="utf-8")
    proc = None
    try:
        proc = subprocess.Popen(
            [mcp_exe, "--https", str(port), "--tls-cert", cert, "--tls-key", key],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log,
            cwd=cwd, env=common_env, text=True)
        proc.stdin.close()

        up = False
        for _ in range(100):
            s, _, _ = https_req(port, "GET", "/healthz", timeout=2.0)
            if s == 200:
                up = True
                break
            time.sleep(0.15)
        if not check("--https: the transport comes up and GET /healthz "
                     "answers over TLS unauthenticated", up):
            print("---- server log tail ----")
            log.flush()
            print(open(log_path, encoding="utf-8").read()[-2000:])
            return 1

        check("--https: a bare plaintext HTTP request against the port "
              "gets no valid HTTP response (TLS-only, not dual-stack)",
              not plaintext_probe(port))

        s, _, b = https_req(port, "POST", "/mcp", body='{"jsonrpc":"2.0"}')
        check("--https: TLS does not bypass the Bearer-token check "
              "(unauthenticated POST still 401)", s == 401 and "missing" in b)

        init_params = {"protocolVersion": "2025-06-18",
                       "clientInfo": {"name": "gate38", "version": "0"}}
        s, h, _ = https_req(port, "POST", "/mcp", token=token, body=json.dumps(
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": init_params}))
        minted = h.get("mcp-session-id")
        check("--https: initialize over TLS answers 200 and mints a session",
              s == 200 and bool(minted))

        s, _, b = https_req(port, "POST", "/mcp", token=token, session=minted,
                            body=json.dumps({"jsonrpc": "2.0", "id": 2,
                                            "method": "tools/call",
                                            "params": {"name": "fractalsql_get_version",
                                                       "arguments": {}}}))
        edition = None
        if s == 200 and b.startswith("{"):
            try:
                edition = (json.loads(b).get("result") or {}) \
                    .get("structuredContent", {}).get("edition")
            except Exception:
                edition = None
        check("--https: a full authenticated tools/call round-trips the "
              "same engine over TLS", s == 200 and edition == "Community")

        s, _, _ = https_req(port, "DELETE", "/mcp", token=token, session=minted)
        check("--https: DELETE closes the TLS session cleanly (200)", s == 200)

        proc.terminate()
        https_req(port, "GET", "/healthz", timeout=5.0)
        try:
            rc = proc.wait(timeout=25)
        except Exception:
            proc.kill()
            rc = proc.wait(timeout=10)
        if os.name != "nt":
            check("--https: the transport drains and exits cleanly on "
                  "termination", rc == 0)
    finally:
        if proc is not None and proc.poll() is None:
            proc.kill()
            try:
                proc.wait(timeout=10)
            except Exception:
                pass
        log.close()

    return 1 if _failures else 0


if __name__ == "__main__":
    try:
        code = main()
    except SystemExit as exc:
        code = int(exc.code or 0)
    print(f"gate38-client: {'ALL GREEN' if code == 0 else 'FAILED'}; "
          f"{_failures} failure(s)")
    sys.exit(code)
