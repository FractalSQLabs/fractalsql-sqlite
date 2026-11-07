#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
# conformance-version: 1
#
# MCP protocol conformance gate.
#
# The same file, byte for byte, in every FractalSQL engine repository that
# ships an MCP plugin. It drives a real server over its real transports and
# checks that the server behaves the way the protocol specifications say it
# must: both protocol eras, the authentication and framing rules, the tool
# catalog's shape, and the session-state handles.
#
# The caller profiles below model how real client stacks shape their
# requests. They are not copies of any SDK: the claim this gate makes is
# "the server behaves per spec under these request shapes", not "every SDK
# works".
#
# The gate needs a built server and a few environment variables; the
# repository's own gate function supplies them:
#
#   MCP_SERVER_EXE        the built server binary
#   MCP_SERVER_CWD        a scratch working directory
#   MCPC_TOKEN            the bearer token the HTTP transport is started with
#   MCPC_GATE             the gate number, used in the closing line
#   MCPC_READ_TOOL        a read-only tool to call           (default: fractalsql_get_version)
#   MCPC_READ_ARGS        its arguments, as JSON             (default: {})
#   MCPC_STATE_TOOL       a session-scoped tool to call      (default: fractal_diversify_enable)
#   MCPC_STATE_ARGS       its arguments, as JSON             (default: {})
#   MCPC_STATE_READER     a session-scoped state reader      (default: fractal_explain_result)
#   MCPC_DESTRUCTIVE_TOOL a tool the read-only switch refuses (default: the state tool)
#   MCPC_DESTRUCTIVE_ARGS its arguments, as JSON             (default: {})
#   MCPC_SAFE_KEY         a config key that is safe to write (default: http_model)
#   MCPC_UNSAFE_KEY       a config key that is not          (default: http_url)
#   MCPC_PASSTHROUGH_ENV  the environment variables a client config would pass
#   MCPC_LOCK_DIR         the directory holding the two lock files
#
# The engine's own variables (the database path, the extension path, the
# connection settings) are inherited from the environment the gate runs in.

import base64
import hashlib
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor

CONFORMANCE_VERSION = 1

EXE = os.environ.get("MCP_SERVER_EXE", "")
SERVER_CWD = os.environ.get("MCP_SERVER_CWD", "") or tempfile.gettempdir()
GATE = os.environ.get("MCPC_GATE", "00")
TOKEN = os.environ.get("MCPC_TOKEN", "conformance-token")
READ_TOOL = os.environ.get("MCPC_READ_TOOL", "fractalsql_get_version")
STATE_TOOL = os.environ.get("MCPC_STATE_TOOL", "fractal_diversify_enable")
STATE_READER = os.environ.get("MCPC_STATE_READER", "fractal_explain_result")
SAFE_KEY = os.environ.get("MCPC_SAFE_KEY", "http_model")
UNSAFE_KEY = os.environ.get("MCPC_UNSAFE_KEY", "http_url")
LOCK_DIR = os.environ.get("MCPC_LOCK_DIR", "") or os.path.dirname(os.path.abspath(EXE))
SCHEMA_LOCK = os.environ.get("FSQL_MCP_SCHEMA_LOCK") or os.path.join(
    LOCK_DIR, ".mcp-schema-lock")
SAFETY_LOCK = os.environ.get("FSQL_MCP_SAFETY_LOCK") or os.path.join(
    LOCK_DIR, ".mcp-safety-annotations-lock")


def _json_arg(name, default):
    raw = os.environ.get(name, "")
    if not raw.strip():
        return default
    try:
        return json.loads(raw)
    except ValueError:
        return default


READ_ARGS = _json_arg("MCPC_READ_ARGS", {})
STATE_ARGS = _json_arg("MCPC_STATE_ARGS", {})
DESTRUCTIVE_ARGS = _json_arg("MCPC_DESTRUCTIVE_ARGS", {})
DESTRUCTIVE_TOOL = os.environ.get("MCPC_DESTRUCTIVE_TOOL", "") or STATE_TOOL
PASSTHROUGH = [n.strip() for n in
               os.environ.get("MCPC_PASSTHROUGH_ENV", "").split(",") if n.strip()]

MODERN_VERSION = "2026-07-28"
LEGACY_VERSION = "2025-06-18"

# ---------------------------------------------------------------------------
# The caller profiles: how a client stack shapes its requests.
#
#   header_case   the case of the header names it sends
#   accept        which media types it accepts
#   framing       how it frames the request body
#   keepalive     whether it asks to keep the connection
#   origin        the Origin header it sends (None = no Origin header)
#   echo_session  whether it echoes the Mcp-Session-Id header
#   flow          which protocol flow it uses
#
# A DUAL client tries the modern flow first and falls back to the legacy one
# when the server answers with a 400 that is not a modern error (that is the
# fallback C04 describes). The legacy sequence is therefore run under the
# DUAL profiles too, as their fallback path.
#
# The chunked sender is the one profile that cannot be used for anything
# except the framing check: a body with no length is refused before the
# server looks at anything else, so the authentication and origin checks do
# not apply to it and are not run for it.
# ---------------------------------------------------------------------------
PROFILES = {
    "py-httpx": {
        "header_case": "lower", "accept": "both", "framing": "length",
        "keepalive": True, "origin": None, "echo_session": True, "flow": "dual",
    },
    "py-httpx-title": {
        "header_case": "title", "accept": "both", "framing": "length",
        "keepalive": True, "origin": None, "echo_session": True, "flow": "dual",
    },
    "node-undici": {
        "header_case": "lower", "accept": "both", "framing": "length",
        "keepalive": True, "origin": None, "echo_session": True, "flow": "dual",
    },
    "go-nethttp": {
        "header_case": "title", "accept": "both", "framing": "length",
        "keepalive": True, "origin": None, "echo_session": True, "flow": "dual",
    },
    "legacy-only": {
        "header_case": "title", "accept": "json", "framing": "length",
        "keepalive": False, "origin": None, "echo_session": True, "flow": "legacy",
    },
    "modern-only": {
        "header_case": "title", "accept": "both", "framing": "length",
        "keepalive": True, "origin": None, "echo_session": False, "flow": "modern",
    },
    "chunked-sender": {
        "header_case": "lower", "accept": "both", "framing": "chunked",
        "keepalive": False, "origin": None, "echo_session": False, "flow": "none",
    },
    "browser": {
        "header_case": "lower", "accept": "both", "framing": "length",
        "keepalive": True, "origin": "http://127.0.0.1:3000", "echo_session": True,
        "flow": "dual",
    },
}

# The profiles that can drive the legacy flow (the legacy-only profile and
# the DUAL profiles' fallback path) and those that can drive the modern one.
LEGACY_PROFILES = ["legacy-only", "py-httpx", "py-httpx-title", "node-undici",
                   "go-nethttp", "browser"]
MODERN_PROFILES = ["modern-only", "py-httpx", "py-httpx-title", "node-undici",
                   "go-nethttp", "browser"]
# Every profile that sends a body with a length, and so can be asked about
# authentication, the origin or the catalog.
LENGTH_PROFILES = [p for p in PROFILES if p != "chunked-sender"]

# The environment a desktop client config would pass: the engine's own
# variables and nothing else. No FractalSQL knob, no inherited state.
SCRUBBED_PASSTHROUGH = [
    "PATH", "HOME", "LANG", "LC_ALL", "TMPDIR", "TEMP", "TMP",
    "SYSTEMROOT", "WINDIR", "USERPROFILE", "APPDATA", "LOCALAPPDATA",
    "PATHEXT", "COMSPEC", "NUMBER_OF_PROCESSORS", "PROCESSOR_ARCHITECTURE",
]

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

_failures = []
_skips = []


def check(cid, desc, ok, detail=""):
    """One line per check: PASS or FAIL <id> <description>."""
    if ok:
        print("PASS %s %s" % (cid, desc))
    else:
        print("FAIL %s %s -- %s" % (cid, desc, detail))
        _failures.append(cid)
    return bool(ok)


def skip(cid, desc, why):
    print("SKIP %s %s -- %s" % (cid, desc, why))
    _skips.append(cid)


# ---------------------------------------------------------------------------
# A minimal HTTP client, written on raw sockets so the gate controls every
# byte of the request: the header casing, a repeated Content-Length, a
# chunked body.
# ---------------------------------------------------------------------------


class Response(object):
    def __init__(self, status, headers, body):
        self.status = status
        self.headers = headers
        self.body = body

    def header(self, name):
        return self.headers.get(name.lower())

    def text(self):
        return self.body.decode("utf-8", "replace")

    def json(self):
        try:
            return json.loads(self.body.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            return None


def _parse_response(data):
    head, sep, body = data.partition(b"\r\n\r\n")
    if not sep:
        return Response(0, {}, data)
    lines = head.decode("latin-1").split("\r\n")
    try:
        status = int(lines[0].split()[1])
    except (IndexError, ValueError):
        status = 0
    headers = {}
    for line in lines[1:]:
        name, _, value = line.partition(":")
        headers[name.strip().lower()] = value.strip()
    return Response(status, headers, body)


def send_raw(port, payload, host="127.0.0.1", timeout=40.0):
    sock = socket.create_connection((host, port), timeout)
    try:
        sock.sendall(payload)
        chunks = []
        while True:
            block = sock.recv(65536)
            if not block:
                break
            chunks.append(block)
    finally:
        sock.close()
    return _parse_response(b"".join(chunks))


def cased(name, style):
    if style == "lower":
        return name.lower()
    return "-".join(part.capitalize() for part in name.split("-"))


def build_request(port, method, path, body=None, headers=None, style="lower",
                  accept="both", framing="length", keepalive=True, origin=None,
                  host="127.0.0.1", extra_lines=None):
    """Assembles one HTTP/1.1 request as bytes."""
    if body is None:
        body = b""
    elif isinstance(body, str):
        body = body.encode("utf-8")
    elif isinstance(body, (dict, list)):
        body = json.dumps(body).encode("utf-8")

    supplied = [n.lower() for n, _ in (headers or [])]
    lines = ["%s %s HTTP/1.1" % (method, path), "Host: %s:%d" % (host, port)]
    if accept == "both":
        lines.append("Accept: application/json, text/event-stream")
    elif accept == "json":
        lines.append("Accept: application/json")
    if origin is not None:
        lines.append("%s: %s" % (cased("Origin", style), origin))
    for name, value in (headers or []):
        lines.append("%s: %s" % (cased(name, style), value))
    if framing == "chunked":
        lines.append("Transfer-Encoding: chunked")
    elif "content-length" not in supplied:
        lines.append("Content-Length: %d" % len(body))
    lines.append("Connection: %s" % ("keep-alive" if keepalive else "close"))
    for line in (extra_lines or []):
        lines.append(line)
    head = ("\r\n".join(lines) + "\r\n\r\n").encode("latin-1")
    if framing == "chunked":
        out = head
        if body:
            out += ("%x\r\n" % len(body)).encode("latin-1")
            out += body + b"\r\n"
        out += b"0\r\n\r\n"
        return out
    return head + body


def request(port, method, path, body=None, headers=None, profile=None, **kwargs):
    """Sends one request shaped by the given profile."""
    prof = profile or PROFILES["py-httpx"]
    style = kwargs.pop("style", prof["header_case"])
    accept = kwargs.pop("accept", prof["accept"])
    framing = kwargs.pop("framing", prof["framing"])
    keepalive = kwargs.pop("keepalive", prof["keepalive"])
    origin = kwargs.pop("origin", prof["origin"])
    return send_raw(port, build_request(port, method, path, body, headers,
                                        style=style, accept=accept,
                                        framing=framing, keepalive=keepalive,
                                        origin=origin, **kwargs))


# ---------------------------------------------------------------------------
# JSON-RPC message builders
# ---------------------------------------------------------------------------


def rpc(method, params=None, req_id=1, notification=False):
    msg = {"jsonrpc": "2.0", "method": method}
    if params is not None:
        msg["params"] = params
    if not notification:
        msg["id"] = req_id
    return msg


def modern_body(method, params=None, req_id=1, notification=False,
                 version=MODERN_VERSION):
    """A modern era message: the revision travels in the body's _meta."""
    msg = rpc(method, params, req_id, notification)
    msg["_meta"] = {"io.modelcontextprotocol/protocolVersion": version}
    return msg


def modern_headers(method, name=None, version=MODERN_VERSION, encoded=False,
                   with_version=True):
    headers = []
    if with_version:
        headers.append(("MCP-Protocol-Version", version))
    headers.append(("Mcp-Method", method))
    if name is not None:
        value = name
        if encoded:
            raw = base64.urlsafe_b64encode(name.encode("utf-8")).decode("ascii")
            value = "=?base64?" + raw + "?="
        headers.append(("Mcp-Name", value))
    return headers


def name_for(method, params):
    """The name a modern request addresses, which the Mcp-Name header has to
    repeat."""
    if not isinstance(params, dict):
        return None
    if method in ("tools/call", "prompts/get"):
        return params.get("name")
    if method == "resources/read":
        return params.get("uri")
    return None


# ---------------------------------------------------------------------------
# Server processes
# ---------------------------------------------------------------------------

BASE_ENV = {}
SCRATCH = ""
WORKDIR = ""


class Server(object):
    """One server process, with its own log file."""

    def __init__(self, label, env_extra=None, args=None, cwd=None, env=None):
        self.label = label
        self.log_path = os.path.join(SCRATCH, "%s.log" % label)
        self.log = open(self.log_path, "ab")
        self.proc = subprocess.Popen(
            [EXE] + list(args or []),
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=self.log, env=env if env is not None else build_env(env_extra),
            cwd=cwd or WORKDIR)
        self.port = None

    def stop(self):
        try:
            self.proc.terminate()
            self.proc.wait(timeout=15)
        except Exception:
            try:
                self.proc.kill()
            except Exception:
                pass
        try:
            self.log.close()
        except Exception:
            pass

    def log_text(self):
        try:
            with open(self.log_path, "rb") as handle:
                return handle.read().decode("utf-8", "replace")
        except OSError:
            return ""


def build_env(extra=None, scrub=False):
    if scrub:
        # A desktop client config carries the engine's own variables and
        # nothing else: no FractalSQL knob, not even the lock paths or the
        # token. The engine variables arrive through the passthrough list.
        env = {}
        for name in SCRUBBED_PASSTHROUGH + PASSTHROUGH:
            if name in os.environ:
                env[name] = os.environ[name]
    else:
        env = dict(os.environ)
        env.update(BASE_ENV)
    if extra:
        for name, value in extra.items():
            if value is None:
                env.pop(name, None)
            else:
                env[name] = value
    return env


def free_port():
    sock = socket.socket()
    try:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]
    finally:
        sock.close()


def wait_for_port(port, proc, timeout=40.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if proc.poll() is not None:
            return False
        try:
            sock = socket.create_connection(("127.0.0.1", port), 0.5)
            sock.close()
            return True
        except OSError:
            time.sleep(0.05)
    return False


def start_http(label, env_extra=None, args=None, cwd=None, env=None):
    """Starts an HTTP server on a free port and waits for it to listen."""
    port = free_port()
    srv = Server(label, env_extra, args=["--http", str(port)] + list(args or []),
                 cwd=cwd, env=env)
    srv.port = port
    if not wait_for_port(port, srv.proc):
        srv.stop()
        raise RuntimeError("the %s server did not start listening:\n%s"
                           % (label, srv.log_text()))
    return srv


def run_to_exit(label, env_extra=None, args=None, cwd=None, env=None, timeout=60.0):
    """Runs a server that is expected to refuse to start, and returns its code."""
    srv = Server(label, env_extra, args=args, cwd=cwd, env=env)
    try:
        code = srv.proc.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        srv.stop()
        return None
    finally:
        try:
            srv.log.close()
        except Exception:
            pass
    return code


# ---------------------------------------------------------------------------
# A conversation with one HTTP server
# ---------------------------------------------------------------------------


class Client(object):
    def __init__(self, port, profile=None, token=None):
        self.port = port
        self.profile = profile or PROFILES["py-httpx"]
        # None means "the configured token"; the empty string means "no
        # credential at all", which is what the unauthenticated probes need.
        self.token = TOKEN if token is None else token
        self.session_id = None

    def headers(self, extra=None):
        headers = []
        if self.token:
            headers.append(("Authorization", "Bearer %s" % self.token))
        if self.session_id and self.profile["echo_session"]:
            headers.append(("Mcp-Session-Id", self.session_id))
        headers.extend(extra or [])
        return headers

    def post(self, body, extra_headers=None, profile=None, **kwargs):
        return request(self.port, "POST", "/mcp", body,
                       headers=self.headers(extra_headers),
                       profile=profile or self.profile, **kwargs)

    def legacy(self, method, params=None, req_id=1, notification=False,
               extra_headers=None, **kwargs):
        return self.post(rpc(method, params, req_id, notification),
                         extra_headers, **kwargs)

    def modern(self, method, params=None, req_id=1, notification=False,
               name=None, version=MODERN_VERSION, body_version=None,
               method_header=None, encoded=False, with_version=True,
               extra_headers=None, **kwargs):
        """A modern era request.

        name            the Mcp-Name header; None derives it from the params,
                        "" sends no Mcp-Name header at all.
        version         the revision in the header.
        body_version    the revision in the body's _meta (defaults to the
                        header's).
        method_header   the Mcp-Method header (defaults to the body's method).
        """
        if name is None:
            name = name_for(method, params)
        headers = modern_headers(method_header or method,
                                 None if name == "" else name,
                                 version, encoded, with_version)
        headers.extend(extra_headers or [])
        return self.post(modern_body(method, params, req_id, notification,
                                      body_version or version),
                         headers, **kwargs)

    def initialize(self, version=LEGACY_VERSION):
        resp = self.post(rpc("initialize",
                              {"protocolVersion": version,
                               "clientInfo": {"name": "conformance", "version": "1"},
                               "capabilities": {}}))
        sid = resp.header("mcp-session-id")
        if sid:
            self.session_id = sid
        return resp


def result_of(resp):
    body = resp.json() or {}
    result = body.get("result")
    return result if isinstance(result, dict) else {}


def flow_call(client, method, params=None):
    """A call shaped the way the client's profile talks: the modern era for a
    modern profile, the legacy era for every other one."""
    if (client.profile or {}).get("flow") == "modern":
        return client.modern(method, params)
    return client.legacy(method, params)


def flow_client(port, profile, token=None):
    """A client that is ready to make calls: a legacy profile has to
    initialize first and keep the session it was given."""
    client = Client(port, profile, token=token)
    if (client.profile or {}).get("flow") != "modern":
        client.initialize()
    return client


def error_of(resp):
    body = resp.json() or {}
    err = body.get("error")
    return err if isinstance(err, dict) else {}


def tool_payload(resp):
    """The structured payload of a tools/call result, or None."""
    result = result_of(resp)
    if isinstance(result.get("structuredContent"), dict):
        return result["structuredContent"]
    content = result.get("content") or []
    for item in content:
        if item.get("type") == "text":
            try:
                return json.loads(item.get("text", ""))
            except ValueError:
                return None
    return None


def tool_error_text(resp):
    """The message of a refused call, or the empty string."""
    result = result_of(resp)
    if result.get("isError"):
        structured = result.get("structuredContent") or {}
        if isinstance(structured, dict) and structured.get("message"):
            return str(structured["message"])
        content = result.get("content") or []
        for item in content:
            if item.get("type") == "text":
                return str(item.get("text", ""))
    err = error_of(resp)
    if err:
        return str(err.get("message", ""))
    return ""


# ---------------------------------------------------------------------------
# Scratch space
# ---------------------------------------------------------------------------


def make_scratch():
    global SCRATCH, WORKDIR
    SCRATCH = tempfile.mkdtemp(prefix="mcp-conf-")
    WORKDIR = os.path.join(SCRATCH, "work")
    os.makedirs(WORKDIR)


def report_servers(servers, tail_lines=60):
    """Prints, for each server, whether it is still running and the end of its log."""
    for srv in servers:
        code = srv.proc.poll()
        state = "still running" if code is None else "EXITED with code %s" % code
        text = srv.log_text().strip()
        print("server-log: %s server %s (port %s)" % (srv.label, state, srv.port))
        if text:
            for line in text.splitlines()[-tail_lines:]:
                print("server-log:   %s" % line)


def cleanup():
    if SCRATCH and os.path.isdir(SCRATCH):
        shutil.rmtree(SCRATCH, ignore_errors=True)


# ---------------------------------------------------------------------------
# Running one check under several profiles
# ---------------------------------------------------------------------------


class Sweep(object):
    """The result of one check, run under several profiles.

    A check passes only when it holds under every profile it applies to, and
    the line it prints names the profile that broke it.
    """

    def __init__(self, cid, desc):
        self.cid = cid
        self.desc = desc
        self.outcomes = []

    def add(self, profile, ok, detail=""):
        self.outcomes.append((profile, bool(ok), detail))

    def report(self):
        bad = [(p, d) for (p, ok, d) in self.outcomes if not ok]
        if bad:
            profile, detail = bad[0]
            return check(self.cid, self.desc, False,
                         "profile %s: %s" % (profile, detail))
        return check(self.cid, self.desc, True)


def sweep(profiles, probe, workers=8):
    """Runs one probe per profile, in parallel, and returns {profile: result}.

    The probes are independent requests, so they overlap; that keeps the
    gate inside its runtime budget even where a refusal costs the server a
    backoff delay.
    """
    if not profiles:
        return {}
    with ThreadPoolExecutor(max_workers=min(workers, len(profiles))) as pool:
        futures = [(p, pool.submit(probe, p)) for p in profiles]
        return dict((p, f.result()) for (p, f) in futures)


# ---------------------------------------------------------------------------
# T: the legacy era's transport rules
# ---------------------------------------------------------------------------


def legacy_probe(port, pname):
    """Runs the legacy era's checks for one profile; returns {id: (ok, detail)}."""
    out = {}
    prof = PROFILES[pname]
    client = Client(port, prof)

    resp = client.initialize()
    result = result_of(resp)
    ok = (resp.status == 200
          and isinstance(result.get("protocolVersion"), str)
          and result["protocolVersion"] != ""
          and isinstance(result.get("capabilities"), dict)
          and isinstance(result.get("serverInfo"), dict)
          and result["serverInfo"].get("name") != ""
          and resp.header("mcp-session-id") is not None)
    out["T01"] = (ok, "status=%s body=%s" % (resp.status, resp.text()[:200]))

    resp = client.legacy("notifications/initialized", notification=True)
    out["T02"] = (resp.status == 202 and resp.body.strip() == b"",
                  "status=%s body=%s" % (resp.status, resp.text()[:120]))

    anon = Client(port, prof)
    resp = anon.legacy("tools/list")
    out["T03"] = (resp.status == 400, "status=%s" % resp.status)

    resp = client.legacy("tools/list",
                         extra_headers=[("Mcp-Session-Id", "no-such-session")])
    out["T04"] = (resp.status == 404, "status=%s" % resp.status)

    first = request(port, "DELETE", "/mcp",
                    headers=[("Authorization", "Bearer %s" % TOKEN),
                             ("Mcp-Session-Id", client.session_id or "")],
                    profile=prof).status
    second = request(port, "DELETE", "/mcp",
                     headers=[("Authorization", "Bearer %s" % TOKEN),
                              ("Mcp-Session-Id", client.session_id or "")],
                     profile=prof).status
    out["T05"] = (first == 200 and second == 404,
                  "first=%s second=%s" % (first, second))
    client.session_id = None

    resp = request(port, "GET", "/mcp",
                   headers=[("Authorization", "Bearer %s" % TOKEN)], profile=prof)
    out["T06"] = (resp.status == 405, "status=%s" % resp.status)

    resp = client.post("this is not a JSON-RPC message")
    err = error_of(resp)
    out["T07"] = (resp.status == 400 and err.get("code") == -32700,
                  "status=%s code=%s" % (resp.status, err.get("code")))

    client = Client(port, prof)
    client.initialize()
    resp = client.legacy("ping")
    ok = resp.status == 200 and "result" in (resp.json() or {})
    out["T08"] = (ok, "status=%s body=%s" % (resp.status, resp.text()[:160]))
    # A legacy tool call, so the operator's log records the legacy era.
    resp = client.legacy("tools/call",
                         {"name": READ_TOOL, "arguments": dict(READ_ARGS)})
    out["T08"] = (out["T08"][0] and resp.status == 200,
                  "ping=%s tool-call=%s" % (out["T08"][1], resp.status))
    return out


def check_r_group(dual):
    """R: a client that vanishes, or that is refused before its body is read, must neither take the server down
    nor lose the reply it is owed."""
    import struct
    client = Client(dual.port)
    ping = build_request(dual.port, "POST", "/mcp", json.dumps(rpc("ping")),
                         headers=client.headers([("Content-Type", "application/json")]), keepalive=False)

    # R01: the peer resets the connection while the server is still deciding its reply. A wrong token makes the
    # server stall the answer (the failed-auth backoff), so the write lands on a dead socket: that raises SIGPIPE
    # unless the server ignores it, and SIGPIPE ends the process without a word.
    wrong = build_request(dual.port, "POST", "/mcp", json.dumps(rpc("ping")),
                          headers=[("Authorization", "Bearer not-the-token"),
                                   ("Content-Type", "application/json")], keepalive=False)
    for _ in range(8):
        try:
            sock = socket.create_connection(("127.0.0.1", dual.port), 10)
            sock.sendall(wrong)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
            sock.close()
        except OSError:
            pass
    time.sleep(2.5)                      # past the longest backoff of the eight
    code = dual.proc.poll()
    status = None
    if code is None:
        try:
            status = Client(dual.port).initialize().status
        except OSError as exc:
            status = "no answer (%s)" % exc
    check("R01", "clients that reset the connection mid-exchange do not take the server down",
          code is None and status == 200,
          "server %s" % ("exited with code %s" % code if code is not None else "answered %s" % status))

    # R02: a request refused before its body is read (here: chunked, 411) leaves unread data on the socket. Closing
    # it then makes the kernel reset the connection, and the reset throws away the reply that was just written.
    body = b"x" * 262144
    chunked = (build_request(dual.port, "POST", "/mcp", None, headers=client.headers([("Content-Type", "application/json")]), framing="chunked",
                             keepalive=False)
               + (b"%x\r\n" % len(body)) + body + b"\r\n0\r\n\r\n")
    bad = []
    for i in range(20):
        try:
            r = send_raw(dual.port, chunked)
            if r.status != 411:
                bad.append("#%d status %s" % (i, r.status))
        except OSError as exc:
            bad.append("#%d %s" % (i, exc))
    check("R02", "a request refused before its body is read still receives its reply (no reset)",
          not bad, "; ".join(bad[:3]))


def check_t_group(dual):
    descs = {
        "T01": "initialize answers 200 with protocolVersion, capabilities, "
               "serverInfo and an Mcp-Session-Id header (MCP 2025-06-18 "
               "initialize)",
        "T02": "notifications/initialized is acknowledged with 202 and no body "
               "(MCP 2025-06-18 initialized)",
        "T03": "a request that is not initialize and carries no session id is "
               "refused with 400 (MCP 2025-06-18 session header)",
        "T04": "an unknown session id is refused with 404 (MCP 2025-06-18 "
               "session header)",
        "T05": "DELETE with a valid session answers 200 and the same session is "
               "then unknown (MCP 2025-06-18 session termination)",
        "T06": "GET on the MCP path is refused with 405 (MCP 2025-06-18 "
               "transport)",
        "T07": "a body that is not JSON-RPC is a parse error with HTTP 400 "
               "(JSON-RPC 2.0 parse error -32700)",
        "T08": "ping answers in the legacy era (MCP 2025-06-18 ping)",
    }
    sweeps = dict((cid, Sweep(cid, desc)) for cid, desc in descs.items())
    results = sweep(LEGACY_PROFILES, lambda p: legacy_probe(dual.port, p))
    for pname, outcome in results.items():
        for cid, (ok, detail) in outcome.items():
            sweeps[cid].add(pname, ok, detail)
    # The echoed revision: initialize answers with the revision it was asked
    # for when that revision is one the server speaks.
    echo = Client(dual.port, PROFILES["legacy-only"])
    resp = echo.initialize("2024-11-05")
    echoed = result_of(resp).get("protocolVersion")
    for sweep_obj in sweeps.values():
        for idx, (pname, ok, detail) in enumerate(sweep_obj.outcomes):
            if sweep_obj.cid == "T01":
                sweep_obj.outcomes[idx] = (pname, ok and echoed == "2024-11-05",
                                           detail if echoed == "2024-11-05"
                                           else "echoed revision %r" % (echoed,))
    for cid in sorted(sweeps):
        sweeps[cid].report()


# ---------------------------------------------------------------------------
# M: the modern era's transport rules
# ---------------------------------------------------------------------------


def modern_probe(port, pname):
    """Runs the modern era's checks for one profile; returns {id: (ok, detail)}."""
    out = {}
    prof = PROFILES[pname]
    client = Client(port, prof)

    resp = client.modern("server/discover")
    result = result_of(resp)
    versions = result.get("protocolVersions") or []
    ok = (resp.status == 200 and MODERN_VERSION in versions
          and isinstance(result.get("capabilities"), dict)
          and isinstance(result.get("serverInfo"), dict))
    out["M01"] = (ok, "status=%s versions=%s" % (resp.status, versions))

    first = result_of(client.modern("tools/list"))
    second = result_of(client.modern("tools/list"))
    names_a = [t.get("name") for t in (first.get("tools") or [])]
    names_b = [t.get("name") for t in (second.get("tools") or [])]
    ok = (first.get("resultType") == "complete"
          and "ttlMs" in first and "cacheScope" in first
          and names_a == names_b and len(names_a) > 0)
    out["M02"] = (ok, "resultType=%s ttlMs=%s cacheScope=%s same-order=%s" % (
        first.get("resultType"), first.get("ttlMs"), first.get("cacheScope"),
        names_a == names_b))

    resp = client.modern("tools/list", with_version=False)
    err = error_of(resp)
    out["M03"] = (resp.status == 400 and err.get("code") == -32020,
                  "status=%s code=%s" % (resp.status, err.get("code")))

    resp = client.modern("tools/list", version=MODERN_VERSION,
                          body_version="2025-11-25")
    err = error_of(resp)
    out["M04"] = (resp.status == 400 and err.get("code") == -32020,
                  "status=%s code=%s" % (resp.status, err.get("code")))

    resp = client.modern("ping", method_header="tools/list")
    err = error_of(resp)
    out["M05"] = (resp.status == 400 and err.get("code") == -32020,
                  "status=%s code=%s" % (resp.status, err.get("code")))

    plain = client.modern("tools/call",
                          {"name": READ_TOOL, "arguments": dict(READ_ARGS)},
                          name="a-different-tool")
    encoded = client.modern("tools/call",
                            {"name": READ_TOOL, "arguments": dict(READ_ARGS)},
                            name="a-different-tool", encoded=True)
    matched = client.modern("tools/call",
                            {"name": READ_TOOL, "arguments": dict(READ_ARGS)},
                            name=READ_TOOL, encoded=True)
    plain_ok = plain.status == 400 and error_of(plain).get("code") == -32020
    encoded_ok = encoded.status == 400 and error_of(encoded).get("code") == -32020
    matched_ok = matched.status == 200
    out["M06"] = (plain_ok and encoded_ok and matched_ok,
                  "plain=%s encoded=%s matching=%s" % (
                      plain_ok, encoded_ok, matched_ok))

    resp = client.modern("tools/list", version="2020-01-01")
    err = error_of(resp)
    data = err.get("data") or {}
    out["M07"] = (resp.status == 400 and err.get("code") == -32022
                  and MODERN_VERSION in (data.get("supported") or []),
                  "status=%s code=%s data=%s" % (resp.status, err.get("code"),
                                                data))

    resp = client.modern("no/such/method")
    err = error_of(resp)
    out["M08"] = (resp.status == 404 and err.get("code") == -32601,
                  "status=%s code=%s" % (resp.status, err.get("code")))

    minted = client.modern("tools/list").header("mcp-session-id")
    resp = client.modern("tools/list",
                         extra_headers=[("Mcp-Session-Id", "not-a-session")])
    out["M09"] = (minted is None and resp.status == 200,
                  "minted=%s with-a-supplied-session=%s" % (minted, resp.status))

    get_status = request(port, "GET", "/mcp",
                         headers=[("Authorization", "Bearer %s" % TOKEN),
                                  ("MCP-Protocol-Version", MODERN_VERSION)],
                         profile=prof).status
    delete_status = request(port, "DELETE", "/mcp",
                            headers=[("Authorization", "Bearer %s" % TOKEN),
                                     ("MCP-Protocol-Version", MODERN_VERSION)],
                            profile=prof).status
    out["M10"] = (get_status == 405 and delete_status == 405,
                  "GET=%s DELETE=%s" % (get_status, delete_status))

    resp = client.modern("notifications/initialized", notification=True)
    out["M11"] = (resp.status == 202, "status=%s" % resp.status)

    resp = client.modern("tools/call",
                          {"name": READ_TOOL, "arguments": dict(READ_ARGS)})
    result = result_of(resp)
    out["M12"] = (resp.status == 200 and result.get("resultType") == "complete",
                  "status=%s resultType=%s" % (resp.status,
                                               result.get("resultType")))

    resp = client.modern("resources/read",
                          {"uri": "fractalsql://no-such-resource"})
    err = error_of(resp)
    out["M13"] = (err.get("code") == -32602,
                  "status=%s code=%s" % (resp.status, err.get("code")))
    return out


def check_m_group(dual):
    descs = {
        "M01": "server/discover answers with the supported revisions including "
               "2026-07-28, the capabilities and the server identity (MCP "
               "2026-07-28 server/discover)",
        "M02": "tools/list says what kind of result it is, how long it may be "
               "cached and in which scope, and two calls list the tools in the "
               "same order (MCP 2026-07-28 result metadata)",
        "M03": "a modern request without the MCP-Protocol-Version header is "
               "refused with 400 and -32020 (MCP 2026-07-28 HeaderMismatch)",
        "M04": "a modern request whose header and body disagree about the "
               "revision is refused with 400 and -32020 (MCP 2026-07-28 "
               "HeaderMismatch)",
        "M05": "a modern request whose Mcp-Method header disagrees with the "
               "body is refused with 400 and -32020 (MCP 2026-07-28 "
               "HeaderMismatch)",
        "M06": "a modern request whose Mcp-Name header disagrees with the name "
               "in the body is refused with 400 and -32020, in plain and in the "
               "base64 form (MCP 2026-07-28 HeaderMismatch)",
        "M07": "an unsupported protocol revision is refused with 400 and -32022 "
               "and the revisions the server does speak (MCP 2026-07-28 "
               "UnsupportedProtocolVersionError)",
        "M08": "an unknown method is refused with 404 and -32601 (JSON-RPC 2.0 "
               "method not found)",
        "M09": "a modern request mints no Mcp-Session-Id and a supplied one is "
               "ignored (MCP 2026-07-28 stateless transport)",
        "M10": "GET and DELETE are refused with 405 on a modern request (MCP "
               "2026-07-28 stateless transport)",
        "M11": "a notification POST is acknowledged with 202 (MCP 2026-07-28 "
               "notifications)",
        "M12": "a tools/call result carries resultType \"complete\" (MCP "
               "2026-07-28 result metadata)",
        "M13": "a resource that does not exist is refused with -32602 (JSON-RPC "
               "2.0 invalid params)",
    }
    sweeps = dict((cid, Sweep(cid, desc)) for cid, desc in descs.items())
    results = sweep(MODERN_PROFILES, lambda p: modern_probe(dual.port, p))
    for pname, outcome in results.items():
        for cid, (ok, detail) in outcome.items():
            sweeps[cid].add(pname, ok, detail)
    for cid in sorted(sweeps):
        sweeps[cid].report()


# ---------------------------------------------------------------------------
# C: the compatibility matrix
# ---------------------------------------------------------------------------


def check_c_group(dual):
    modern = Client(dual.port, PROFILES["modern-only"])
    resp = modern.modern("tools/list")
    check("C01", "a modern client works against a dual-era server (MCP "
                 "2026-07-28 against a dual-era server)",
          resp.status == 200 and "tools" in result_of(resp),
          "status=%s" % resp.status)

    resp = modern.modern("tools/list")
    check("C02", "a dual-era client stays in the modern era once a modern "
                 "request has worked (MCP 2026-07-28 era negotiation)",
          resp.status == 200 and result_of(resp).get("resultType") == "complete",
          "status=%s" % resp.status)

    legacy = Client(dual.port, PROFILES["legacy-only"])
    legacy.initialize()
    resp = legacy.legacy("tools/list")
    check("C03", "a legacy client works against a dual-era server (MCP "
                 "2025-06-18 against a dual-era server)",
          resp.status == 200 and "tools" in result_of(resp),
          "status=%s" % resp.status)

    resp = Client(dual.port, PROFILES["legacy-only"]).legacy("tools/list")
    err = resp.json() or {}
    code = error_of(resp).get("code")
    modern_body_shape = isinstance(err.get("error"), dict)
    check("C04", "a legacy-style request with no session and no modern "
                 "metadata is refused with a 400 that is not a modern error "
                 "body, so a dual-era client falls back correctly (MCP "
                 "2026-07-28 era negotiation)",
          resp.status == 400 and not modern_body_shape
          and code not in (-32020, -32022),
          "status=%s code=%s body=%s" % (resp.status, code, resp.text()[:160]))


# ---------------------------------------------------------------------------
# E: the era switch
# ---------------------------------------------------------------------------


def check_e_group(modern_only, dual):
    client = Client(modern_only.port, PROFILES["modern-only"])
    resp = client.post(rpc("initialize", {"protocolVersion": LEGACY_VERSION}))
    body = resp.text()
    names_versions = ("2025-11-25" in body and MODERN_VERSION in body)
    modern_ok = client.modern("tools/list").status == 200
    get_status = request(modern_only.port, "GET", "/mcp",
                         headers=[("Authorization", "Bearer %s" % TOKEN)]).status
    delete_status = request(modern_only.port, "DELETE", "/mcp",
                            headers=[("Authorization", "Bearer %s" % TOKEN)]).status
    check("E01", "a server that speaks the modern era only refuses the legacy "
                 "handshake and names the revisions it speaks, answers a "
                 "modern request, and refuses GET and DELETE with 405 "
                 "(FSQL_MCP_PROTOCOL_ERA=modern)",
          resp.status == 400 and names_versions and modern_ok
          and get_status == 405 and delete_status == 405,
          "status=%s names-the-versions=%s modern=%s GET=%s DELETE=%s" % (
              resp.status, names_versions, modern_ok, get_status,
              delete_status))

    legacy_ok = Client(dual.port, PROFILES["legacy-only"]).initialize().status == 200
    modern_ok = Client(dual.port, PROFILES["modern-only"]).modern("tools/list").status == 200
    check("E02", "a server that speaks both eras serves both on one endpoint "
                 "(FSQL_MCP_PROTOCOL_ERA=dual, the default)",
          legacy_ok and modern_ok,
          "legacy=%s modern=%s" % (legacy_ok, modern_ok))

    eras = set()
    for line in dual.log_text().splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if event.get("event") == "tool_call" and event.get("era"):
            eras.add(event["era"])
    check("E03", "the per-call log line carries the protocol era the call "
                 "arrived in (operator log)",
          "legacy" in eras and "modern" in eras,
          "eras in the log: %s" % (sorted(eras) or "none"))


# ---------------------------------------------------------------------------
# A: authentication
# ---------------------------------------------------------------------------


def auth_probe(port, pname, tokens):
    """Runs the credential checks for one profile; returns {id: (ok, detail)}."""
    out = {}
    prof = PROFILES[pname]

    resp = Client(port, prof, token="").post(rpc("initialize", {}))
    challenge = resp.header("www-authenticate") or ""
    out["A01"] = (resp.status == 401 and "Bearer" in challenge,
                  "status=%s challenge=%r" % (resp.status, challenge))

    resp = Client(port, prof, token="not-the-token").post(rpc("initialize", {}))
    out["A02"] = (resp.status == 401, "status=%s" % resp.status)

    resp = request(port, "POST", "/mcp?access_token=%s" % TOKEN,
                   body=json.dumps(rpc("initialize", {})).encode("utf-8"),
                   headers=[("Content-Type", "application/json")], profile=prof)
    out["A03"] = (resp.status == 401, "status=%s" % resp.status)

    health = request(port, "GET", "/healthz", profile=prof)
    ready = request(port, "GET", "/readyz", profile=prof)
    out["A04"] = (health.status == 200 and ready.status in (200, 503),
                  "health=%s ready=%s" % (health.status, ready.status))

    resp = Client(port, prof, token=tokens["expired"]).post(rpc("initialize", {}))
    challenge = resp.header("www-authenticate") or ""
    expired_status = resp.status
    resp = Client(port, prof, token=tokens["valid"]).post(rpc("initialize", {}))
    out["A07"] = (expired_status == 401 and "invalid_token" in challenge
                  and resp.status == 200,
                  "expired=%s challenge=%r unexpired=%s" % (
                      expired_status, challenge, resp.status))
    return out


def check_a_group(dual, tokens):
    descs = {
        "A01": "a request without a token is refused with 401 and a bearer "
               "challenge (RFC 6750 section 3)",
        "A02": "a request with the wrong token is refused with 401 (RFC 6750 "
               "section 3)",
        "A03": "a token carried only in the query string is not a credential "
               "and is refused with 401 (RFC 6750 section 2)",
        "A04": "the health and readiness probes answer without a token (MCP "
               "2026-07-28 health)",
        "A07": "an expired credential is refused with 401 and "
               "error=\"invalid_token\" while an unexpired one works (RFC 6750 "
               "section 3.1)",
    }
    sweeps = dict((cid, Sweep(cid, desc)) for cid, desc in descs.items())
    results = sweep(LENGTH_PROFILES, lambda p: auth_probe(dual.port, p, tokens))
    for pname, outcome in results.items():
        for cid, (ok, detail) in outcome.items():
            sweeps[cid].add(pname, ok, detail)
    for cid in sorted(sweeps):
        sweeps[cid].report()

    slowest = 0.0
    failures = 0
    for _ in range(8):
        started = time.time()
        resp = Client(dual.port, PROFILES["legacy-only"],
                      token="not-the-token").post(rpc("initialize", {}))
        slowest = max(slowest, time.time() - started)
        if resp.status == 401:
            failures += 1
    resp = Client(dual.port, PROFILES["legacy-only"]).post(rpc("initialize", {}))
    check("A05", "repeated failures neither lock out a valid token nor make a "
                 "refusal take longer than about two and a half seconds (RFC "
                 "6750 section 3)",
          failures == 8 and resp.status == 200 and slowest < 2.5,
          "failures=%s slowest=%.2fs valid-token=%s" % (
              failures, slowest, resp.status))

    owner = Client(dual.port, PROFILES["legacy-only"])
    owner.initialize()
    session = owner.session_id
    resp = owner.modern("tools/call",
                        {"name": STATE_TOOL, "arguments": dict(STATE_ARGS)})
    context = result_of(resp).get("context_id")
    other = Client(dual.port, PROFILES["legacy-only"], token=tokens["second"])
    resp = other.legacy("tools/list", extra_headers=[("Mcp-Session-Id", session)])
    session_status = resp.status
    arguments = dict(STATE_ARGS)
    if context:
        arguments["context_id"] = context
    resp = other.modern("tools/call",
                        {"name": STATE_TOOL, "arguments": arguments})
    context_status = resp.status
    check("A06", "a second credential cannot use the first one's session or "
                 "its context handle (MCP 2025-06-18 session ownership)",
          session_status == 404 and context_status == 404,
          "session=%s context=%s" % (session_status, context_status))

    limited = Client(dual.port, PROFILES["legacy-only"], token=tokens["limited"])
    resp = limited.post(rpc("initialize", {}))
    limited.session_id = resp.header("mcp-session-id")
    resp = limited.legacy("tools/list")
    listed = [t.get("name") for t in (result_of(resp).get("tools") or [])]
    resp = limited.legacy("tools/call",
                           {"name": STATE_READER, "arguments": {}})
    message = tool_error_text(resp)
    check("A08", "a credential restricted by the policy file sees only its own "
                 "tools and cannot call a tool outside the list (MCP 2026-07-28 "
                 "per-client credentials)",
          listed == [READ_TOOL] and "allowlist" in message,
          "listed=%s message=%s" % (listed, message[:160]))


# ---------------------------------------------------------------------------
# S: security and framing
# ---------------------------------------------------------------------------


def security_probe(dual_port, origins_port, pname):
    """Runs the origin and framing checks for one profile."""
    out = {}
    prof = PROFILES[pname]
    # The origin check and the length-framing refusals are about the request
    # as a whole, not about how a client frames it, so they are asked with a
    # length-framed body whichever profile is running. The chunked refusal
    # below is the one check that is about the framing itself.
    length = dict(prof, framing="length")

    no_origin = Client(dual_port, prof).post(
        rpc("initialize", {}), profile=dict(length, origin=None))
    foreign = Client(dual_port, prof).post(
        rpc("initialize", {}), profile=dict(length, origin="http://attacker.example.com"))
    allowlisted = Client(origins_port, prof).post(
        rpc("initialize", {}), profile=dict(length, origin="http://allowed.example.com"))
    out["S01"] = (foreign.status == 403 and no_origin.status == 200
                  and allowlisted.status == 200,
                  "foreign=%s no-origin=%s allowlisted=%s" % (
                      foreign.status, no_origin.status, allowlisted.status))

    chunked = request(dual_port, "POST", "/mcp",
                      body=json.dumps(rpc("initialize", {})).encode("utf-8"),
                      headers=[("Authorization", "Bearer %s" % TOKEN)],
                      framing="chunked", profile=prof)
    oversize = request(dual_port, "POST", "/mcp", body=b"",
                        headers=[("Authorization", "Bearer %s" % TOKEN),
                                 ("Content-Length", "99999999")], profile=length)
    doubled = request(dual_port, "POST", "/mcp",
                      body=json.dumps(rpc("initialize", {})).encode("utf-8"),
                      headers=[("Authorization", "Bearer %s" % TOKEN),
                               ("Content-Length", "10")],
                      extra_lines=["Content-Length: 10"], profile=length)
    out["S02"] = (chunked.status == 411 and oversize.status == 413
                  and doubled.status == 400,
                  "chunked=%s oversize=%s doubled=%s" % (
                      chunked.status, oversize.status, doubled.status))
    return out


def check_s_group(dual, origins):
    descs = {
        "S01": "a foreign browser origin is refused with 403, a request "
               "without an origin is allowed and an allowlisted origin is "
               "allowed (MCP 2026-07-28 origin check)",
        "S02": "a chunked body is refused with 411, an over-limit body with 413 "
               "and an ambiguous framing with 400 (RFC 9112 sections 6.1 and "
               "6.3)",
    }
    sweeps = dict((cid, Sweep(cid, desc)) for cid, desc in descs.items())
    results = sweep(PROFILES.keys(),
                     lambda p: security_probe(dual.port, origins.port, p))
    for pname, outcome in results.items():
        for cid, (ok, detail) in outcome.items():
            sweeps[cid].add(pname, ok, detail)
    for cid in sorted(sweeps):
        sweeps[cid].report()

    code = run_to_exit("s03-refused", args=["--http", str(free_port()),
                                             "--host", "0.0.0.0"])
    accepted = Server("s03-allowed",
                      env_extra={"FSQL_MCP_ALLOW_PLAINTEXT_NONLOOPBACK": "true"},
                      args=["--http", str(free_port()), "--host", "0.0.0.0"])
    time.sleep(1.5)
    stayed = accepted.proc.poll() is None
    accepted.stop()
    check("S03", "a non-loopback plaintext bind exits non-zero unless the "
                 "operator accepts the risk "
                 "(FSQL_MCP_ALLOW_PLAINTEXT_NONLOOPBACK)",
          code not in (None, 0) and stayed,
          "refused-exit=%s the-opt-out-started=%s" % (code, stayed))

    missing_schema = run_to_exit(
        "s04-no-schema",
        env_extra={"FSQL_MCP_SCHEMA_LOCK": os.path.join(SCRATCH, "no-such-lock")})
    missing_safety = run_to_exit(
        "s04-no-safety",
        env_extra={"FSQL_MCP_SAFETY_LOCK": os.path.join(SCRATCH, "no-such-lock")})
    installed = installed_layout_starts()
    check("S04", "a server started without lock files exits non-zero, and "
                 "one with the locks beside the executable starts from any "
                 "working directory (tool-surface drift check)",
          missing_schema not in (None, 0) and missing_safety not in (None, 0)
          and installed,
          "missing-schema=%s missing-safety=%s installed-layout=%s" % (
              missing_schema, missing_safety, installed))

    stale = os.path.join(SCRATCH, "stale-schema.lock")
    with open(stale, "w") as handle:
        handle.write("0" * 64 + "\n")
    code = run_to_exit("s05-stale-lock", env_extra={"FSQL_MCP_SCHEMA_LOCK": stale})
    check("S05", "a schema lock that does not match the tool surface exits "
                 "non-zero by default (FSQL_MCP_STRICT_SCHEMA_HASH)",
          code not in (None, 0), "exit=%s" % code)


def installed_layout_starts():
    """Copies the server and its two lock files into an install directory and
    starts the copy from an unrelated working directory."""
    install = os.path.join(SCRATCH, "install")
    os.makedirs(install, exist_ok=True)
    source_dir = os.path.dirname(os.path.abspath(EXE))
    target = os.path.join(install, os.path.basename(EXE))
    try:
        shutil.copy2(EXE, target)
        for name in os.listdir(source_dir):
            if name.lower().endswith(".dll"):
                shutil.copy2(os.path.join(source_dir, name),
                             os.path.join(install, name))
        for name in (".mcp-schema-lock", ".mcp-safety-annotations-lock"):
            source = os.path.join(LOCK_DIR, name)
            if os.path.exists(source):
                shutil.copy2(source, os.path.join(install, name))
    except (OSError, IOError):
        return False
    elsewhere = os.path.join(SCRATCH, "elsewhere")
    os.makedirs(elsewhere, exist_ok=True)
    env = build_env({"FSQL_MCP_SCHEMA_LOCK": None, "FSQL_MCP_SAFETY_LOCK": None})
    port = free_port()
    proc = subprocess.Popen([target, "--http", str(port)], stdin=subprocess.DEVNULL,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                            env=env, cwd=elsewhere)
    try:
        started = wait_for_port(port, proc, timeout=25.0)
    finally:
        try:
            proc.terminate()
            proc.wait(timeout=15)
        except Exception:
            try:
                proc.kill()
            except Exception:
                pass
    return started


# ---------------------------------------------------------------------------
# K: the schema, the tools and the operator switches
# ---------------------------------------------------------------------------


def sample_element(items_type):
    if items_type == "string":
        return "conformance"
    if items_type == "integer":
        return 1
    if items_type == "array":
        return [1.0]
    return 1.0


def wrong_element(items_type):
    if items_type == "string":
        return 7
    if items_type in ("number", "integer"):
        return "not-a-number"
    if items_type == "array":
        return 7
    return "not-a-number"


def sample_for(prop):
    kind = prop.get("type")
    if kind == "array":
        return [sample_element((prop.get("items") or {}).get("type"))]
    if kind == "string":
        return "conformance"
    if kind == "integer":
        return 1
    if kind == "number":
        return 1.0
    if kind == "boolean":
        return True
    if kind == "object":
        return {}
    return None


def sample_args(schema, target_name, wrong=False):
    """Fills a tool's required arguments, with the target parameter holding
    either a correctly typed element or a wrongly typed one."""
    props = schema.get("properties") or {}
    args = {}
    for pname in schema.get("required") or []:
        if pname == target_name:
            continue
        args[pname] = sample_for(props.get(pname) or {})
    items = (props.get(target_name) or {}).get("items") or {}
    args[target_name] = [wrong_element(items.get("type"))] if wrong \
        else [sample_element(items.get("type"))]
    return args


def array_params(catalog):
    """Every array parameter in the catalog, with the element type it
    advertises."""
    found = []
    for tool in catalog:
        props = (tool.get("inputSchema") or {}).get("properties") or {}
        for pname in sorted(props):
            prop = props[pname]
            if isinstance(prop, dict) and prop.get("type") == "array":
                items = prop.get("items")
                found.append((tool.get("name"), pname,
                              items.get("type") if isinstance(items, dict) else None))
    return found


def pick_array_probe(catalog):
    """The tool and parameter the element-kind check is exercised on.

    A read-only tool is preferred, so the probe cannot change anything, and
    an element kind other than "number" is preferred, because that proves
    the check is per parameter rather than one blanket rule.
    """
    fallback = None
    for tool in sorted(catalog, key=lambda t: t.get("name") or ""):
        annotations = tool.get("annotations") or {}
        read_only = bool(annotations.get("readOnlyHint"))
        props = (tool.get("inputSchema") or {}).get("properties") or {}
        for pname in sorted(props):
            prop = props[pname]
            if not isinstance(prop, dict) or prop.get("type") != "array":
                continue
            items = (prop.get("items") or {}).get("type")
            candidate = (tool["name"], pname, items)
            if not read_only:
                if fallback is None:
                    fallback = candidate
                continue
            if items not in ("number", None):
                return candidate
            if fallback is None:
                fallback = candidate
    return fallback


def catalog_problems(catalog):
    problems = []
    for tool in catalog:
        name = tool.get("name")
        if not isinstance(name, str) or not name:
            problems.append("a tool without a name")
            continue
        if not isinstance(tool.get("description"), str) or not tool.get("description"):
            problems.append("%s: no description" % name)
        schema = tool.get("inputSchema")
        if not isinstance(schema, dict) or schema.get("type") != "object":
            problems.append("%s: inputSchema is not an object schema" % name)
        annotations = tool.get("annotations") or {}
        for hint in ("readOnlyHint", "destructiveHint", "idempotentHint",
                     "openWorldHint"):
            if not isinstance(annotations.get(hint), bool):
                problems.append("%s: %s is not a boolean" % (name, hint))
    return problems


# The configuration-write check applies to a server that publishes a
# configuration-writing tool. An engine that publishes none has no
# configuration for the write switch to govern, so the check has nothing to
# enforce there and is skipped rather than failed.
CONFIG_WRITE_TOOL = "fractalsql_set_config"


def publishes_config_tool(port):
    """Whether the server at `port` publishes the configuration-write tool."""
    client = flow_client(port, PROFILES["py-httpx"])
    catalog = result_of(flow_call(client, "tools/list")).get("tools") or []
    return any(t.get("name") == CONFIG_WRITE_TOOL for t in catalog)


def k_probe(dual, readonly, autoexec, cfg_off, cfg_all, pname, with_config):
    """Runs the catalog and operator-switch checks for one profile.

    `with_config` says whether the server publishes a configuration-writing
    tool; when it does not, the configuration-write check is not run.
    """
    out = {}
    prof = PROFILES[pname]

    client = flow_client(dual.port, prof)
    catalog = result_of(flow_call(client, "tools/list")).get("tools") or []

    problems = catalog_problems(catalog)
    out["K01"] = (not problems, "; ".join(problems[:5]))

    arrays = array_params(catalog)
    bad_shape = [(t, p, i) for (t, p, i) in arrays if i is None]
    probe = pick_array_probe(catalog)
    probe_ok = True
    probe_detail = "the catalog has no array parameter to probe"
    if probe is not None:
        tool_name, pname_param, items_type = probe
        schema = {}
        for tool in catalog:
            if tool.get("name") == tool_name:
                schema = tool.get("inputSchema") or {}
        good = sample_args(schema, pname_param, wrong=False)
        bad = sample_args(schema, pname_param, wrong=True)
        resp = flow_call(client, "tools/call", {"name": tool_name, "arguments": good})
        good_text = tool_error_text(resp)
        resp = flow_call(client, "tools/call", {"name": tool_name, "arguments": bad})
        bad_text = tool_error_text(resp)
        probe_ok = ("elements must be" not in good_text
                    and "elements must be" in bad_text and pname_param in bad_text)
        probe_detail = ("tool=%s parameter=%s elements=%s good=%r bad=%r" % (
            tool_name, pname_param, items_type, good_text[:100], bad_text[:100]))
    out["K02"] = (not bad_shape and probe_ok,
                  "shape problems=%s; %s" % (bad_shape[:5], probe_detail))

    # The two eras are always compared against each other: the legacy half
    # keeps the session a legacy client was given, the modern half asks in
    # the modern way whatever profile is running.
    legacy_client = Client(dual.port, dict(prof, flow="legacy", echo_session=True))
    legacy_client.initialize()
    legacy_tools = result_of(legacy_client.legacy("tools/list")).get("tools")
    modern_tools = result_of(
        Client(dual.port, prof).modern("tools/list")).get("tools")
    out["K04"] = (legacy_tools == modern_tools,
                  "legacy=%s tools, modern=%s tools" % (
                      len(legacy_tools or []), len(modern_tools or [])))

    ro = flow_client(readonly.port, prof)
    resp = flow_call(ro, "tools/call",
                     {"name": DESTRUCTIVE_TOOL, "arguments": dict(DESTRUCTIVE_ARGS)})
    refused = tool_error_text(resp)
    resp = flow_call(ro, "tools/call",
                     {"name": READ_TOOL, "arguments": dict(READ_ARGS)})
    read_ok = resp.status == 200 and not tool_error_text(resp)
    out["K03"] = ("read-only mode" in refused and read_ok,
                  "refusal=%r read=%s" % (refused[:160], resp.status))

    default_client = flow_client(dual.port, prof)
    resp = flow_call(default_client, "tools/call",
                     {"name": "fractal_agent_data_analyst",
                      "arguments": {"question": "conformance probe",
                                    "auto_execute": True}})
    default_text = tool_error_text(resp)
    enabled_client = flow_client(autoexec.port, prof)
    resp = flow_call(enabled_client, "tools/call",
                     {"name": "fractal_agent_data_analyst",
                      "arguments": {"question": "conformance probe",
                                    "auto_execute": True}})
    enabled_text = tool_error_text(resp)
    out["K05"] = ("auto_execute is refused" in default_text
                  and "auto_execute is refused" not in enabled_text,
                  "default=%r enabled=%r" % (default_text[:120], enabled_text[:120]))

    if not with_config:
        return out

    resp = flow_call(default_client, "tools/call",
                     {"name": "fractalsql_set_config",
                      "arguments": {"key": UNSAFE_KEY,
                                    "value": "http://127.0.0.1:9/v1"}})
    unsafe_refused = tool_error_text(resp)
    resp = flow_call(default_client, "tools/call",
                     {"name": "fractalsql_set_config",
                      "arguments": {"key": SAFE_KEY,
                                    "value": "probe-model"}})
    safe_allowed = not tool_error_text(resp)
    resp = flow_call(default_client, "tools/call",
                     {"name": "fractalsql_configure_reasoning",
                      "arguments": {"provider_url": "http://127.0.0.1:9/v1"}})
    configure_refused = tool_error_text(resp)

    off_client = flow_client(cfg_off.port, prof)
    resp = flow_call(off_client, "tools/call",
                     {"name": "fractalsql_set_config",
                      "arguments": {"key": SAFE_KEY, "value": "probe-model"}})
    off_refused = tool_error_text(resp)
    resp = flow_call(off_client, "tools/call",
                     {"name": "fractalsql_get_config",
                      "arguments": {"key": SAFE_KEY}})
    get_answers = not tool_error_text(resp)
    resp = flow_call(off_client, "tools/call",
                     {"name": "fractalsql_get_config",
                      "arguments": {"key": "http_token"}})
    secret_text = tool_error_text(resp)
    secret_hidden = ("***" in secret_text or "secret" in secret_text.lower())

    all_client = flow_client(cfg_all.port, prof)
    resp = flow_call(all_client, "tools/call",
                     {"name": "fractalsql_set_config",
                      "arguments": {"key": UNSAFE_KEY,
                                    "value": "http://127.0.0.1:9/v1"}})
    all_unsafe = not tool_error_text(resp)
    resp = flow_call(all_client, "tools/call",
                     {"name": "fractalsql_configure_reasoning",
                      "arguments": {"model": "probe-model"}})
    all_model = not tool_error_text(resp)
    out["K06"] = (bool(unsafe_refused) and safe_allowed and bool(configure_refused)
                  and bool(off_refused) and get_answers and secret_hidden
                  and all_unsafe and all_model,
                  "safe: url-refused=%s model-accepted=%s configure-url-refused=%s; "
                  "off: refused=%s get=%s secret-redacted=%s; all: url=%s model=%s" % (
                      bool(unsafe_refused), safe_allowed, bool(configure_refused),
                      bool(off_refused), get_answers, secret_hidden,
                      all_unsafe, all_model))
    return out


def check_k_group(dual, readonly, autoexec, cfg_off, cfg_all):
    descs = {
        "K01": "every tool has a name, a description, an object input schema "
               "and the four annotation hints as booleans (MCP 2025-06-18 "
               "tools/list)",
        "K02": "every array parameter advertises the element type the server "
               "accepts, and the server enforces what it advertises (MCP "
               "2025-06-18 tools/list input schema)",
        "K03": "read-only mode refuses the destructive tool and leaves the "
               "read-only tools working (FSQL_MCP_READ_ONLY)",
        "K04": "tools/list is identical across a legacy and a modern request "
               "apart from the era's result fields (MCP 2026-07-28 against a "
               "dual-era server)",
        "K05": "with FSQL_MCP_ALLOW_AUTO_EXECUTE off a call with "
               "auto_execute=true is refused, and with it on the call is "
               "accepted (FSQL_MCP_ALLOW_AUTO_EXECUTE)",
        "K06": "FSQL_MCP_CONFIG_WRITES decides which configuration a model may "
               "change: at its default the endpoint URL is refused and the "
               "model name is accepted, off refuses both while get_config "
               "still answers with the secrets redacted, and all accepts both "
               "(FSQL_MCP_CONFIG_WRITES)",
    }
    # A server that publishes no configuration-writing tool has nothing for
    # the write switch to govern, so the check is skipped with its reason
    # rather than failed against a surface that does not exist.
    with_config = publishes_config_tool(dual.port)
    if not with_config:
        skip("K06", descs["K06"],
             "this server publishes no configuration-writing tool, so there is "
             "no configuration for the write switch to govern")
        del descs["K06"]
    sweeps = dict((cid, Sweep(cid, desc)) for cid, desc in descs.items())
    results = sweep(LENGTH_PROFILES,
                     lambda p: k_probe(dual, readonly, autoexec, cfg_off, cfg_all,
                                       p, with_config))
    for pname, outcome in results.items():
        for cid, (ok, detail) in outcome.items():
            sweeps[cid].add(pname, ok, detail)
    for cid in sorted(sweeps):
        sweeps[cid].report()


# ---------------------------------------------------------------------------
# H: the session-state handles
# ---------------------------------------------------------------------------


def check_h_group(dual, readonly, tokens):
    client = Client(dual.port, PROFILES["modern-only"])
    resp = client.modern("tools/call",
                          {"name": STATE_TOOL, "arguments": dict(STATE_ARGS)})
    context = result_of(resp).get("context_id")
    is_handle = (isinstance(context, str) and len(context) == 32
                 and all(c in "0123456789abcdef" for c in context))
    check("H01", "the state tool returns a context_id in the modern era (MCP "
                 "2026-07-28 context handle)",
          is_handle, "context_id=%r" % (context,))

    first = Client(dual.port, PROFILES["modern-only"])
    resp = first.modern("tools/call", {"name": STATE_READER, "arguments": {}})
    handle_a = result_of(resp).get("context_id")
    resp = first.modern("tools/call",
                        {"name": STATE_TOOL,
                         "arguments": dict(STATE_ARGS, context_id=handle_a)})
    enabled = tool_error_text(resp) == ""
    resp = first.modern("tools/call",
                        {"name": STATE_READER,
                         "arguments": {"context_id": handle_a}})
    after = tool_payload(resp) or {}
    resp = first.modern("tools/call", {"name": STATE_READER, "arguments": {}})
    handle_b = result_of(resp).get("context_id")
    other = tool_payload(resp) or {}
    check("H02", "two contexts do not share their Diversify state (MCP "
                 "2026-07-28 context handle)",
          bool(handle_a) and bool(handle_b) and handle_a != handle_b and enabled
          and after.get("diversify_enabled") is True
          and other.get("diversify_enabled") is not True,
          "handle_a=%s handle_b=%s enabled=%s after=%s other=%s" % (
              handle_a, handle_b, enabled, after.get("diversify_enabled"),
              other.get("diversify_enabled")))

    owner = Client(dual.port, PROFILES["modern-only"])
    resp = owner.modern("tools/call",
                        {"name": STATE_TOOL, "arguments": dict(STATE_ARGS)})
    handle = result_of(resp).get("context_id")
    other = Client(dual.port, PROFILES["modern-only"], token=tokens["second"])
    resp = other.modern("tools/call",
                        {"name": STATE_TOOL,
                         "arguments": dict(STATE_ARGS, context_id=handle)})
    check("H03", "another credential cannot use a context handle it does not "
                 "own (MCP 2026-07-28 context handle)",
          resp.status == 404, "status=%s" % resp.status)

    client = Client(readonly.port, PROFILES["modern-only"])
    resp = client.modern("tools/call",
                          {"name": DESTRUCTIVE_TOOL,
                           "arguments": dict(DESTRUCTIVE_ARGS)})
    refused = tool_error_text(resp)
    resp = client.modern("tools/call",
                          {"name": READ_TOOL, "arguments": dict(READ_ARGS)})
    read_ok = resp.status == 200 and not tool_error_text(resp)
    check("H04", "a fresh context's connection is latched read-only when the "
                 "read-only switch is on (FSQL_MCP_READ_ONLY)",
          "read-only mode" in refused and read_ok,
          "refusal=%r read=%s" % (refused[:160], resp.status))


# ---------------------------------------------------------------------------
# The stdio-desktop profile
# ---------------------------------------------------------------------------


def check_stdio_profile():
    """A desktop client spawns the server itself: a scrubbed environment, an
    arbitrary working directory, newline-framed JSON-RPC and a last line with
    no trailing newline."""
    workdir = os.path.join(SCRATCH, "desktop")
    os.makedirs(workdir, exist_ok=True)
    env = build_env(scrub=True)
    proc = subprocess.Popen([EXE], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, env=env, cwd=workdir)
    try:
        lines = [
            json.dumps(rpc("initialize",
                           {"protocolVersion": LEGACY_VERSION,
                            "clientInfo": {"name": "desktop", "version": "1"},
                            "capabilities": {}}, 1)),
            json.dumps(rpc("tools/list", {}, 2)),
        ]
        payload = "\n".join(lines)      # the last line carries no newline
        out, _ = proc.communicate(payload.encode("utf-8"), timeout=90)
    except Exception:
        proc.kill()
        raise
    replies = []
    for line in out.decode("utf-8", "replace").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            replies.append(json.loads(line))
        except ValueError:
            pass
    initialize = None
    tools = None
    for reply in replies:
        if reply.get("id") == 1:
            initialize = reply
        elif reply.get("id") == 2:
            tools = reply
    ok = (initialize is not None and "result" in initialize
          and tools is not None and "tools" in (tools.get("result") or {}))
    check("P01", "a desktop client can drive the server over stdio from any "
                 "working directory with a scrubbed environment and a final "
                 "line that carries no newline (MCP 2025-06-18 stdio "
                 "transport)",
          ok, "replies=%s" % [sorted(r.keys()) for r in replies])


# ---------------------------------------------------------------------------
# The credential files the gate writes for itself
# ---------------------------------------------------------------------------


def sha256_hex(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def write_policy_file(tokens):
    entries = []
    for name, value, tools, expires in tokens:
        entry = {"name": name, "sha256": sha256_hex(value), "tools": tools}
        if expires:
            entry["expires"] = expires
        entries.append(entry)
    path = os.path.join(SCRATCH, "tokens.json")
    with open(path, "w") as handle:
        json.dump({"tokens": entries}, handle, indent=2)
    return path


# ---------------------------------------------------------------------------
# The gate
# ---------------------------------------------------------------------------


def main():
    global BASE_ENV
    if not EXE or not os.path.isfile(EXE):
        print("FAIL GATE the server binary was not found (MCP_SERVER_EXE)")
        print("gate%s-conformance: FAILED; 1 failure(s)" % GATE)
        return 1

    print("conformance-version: %d" % CONFORMANCE_VERSION)
    make_scratch()

    tokens = {
        "second": "conformance-second-token",
        "expired": "conformance-expired-token",
        "valid": "conformance-policy-token",
        "limited": "conformance-limited-token",
    }
    policy = write_policy_file([
        ("second", tokens["second"], "*", None),
        ("expired", tokens["expired"], "*", "2020-01-01"),
        ("valid", tokens["valid"], "*", None),
        ("limited", tokens["limited"], [READ_TOOL], None),
    ])

    BASE_ENV = {"FSQL_MCP_AUTH_TOKEN": TOKEN,
                "FSQL_MCP_TOKEN_POLICY_FILE": policy,
                "FSQL_MCP_LOG_LEVEL": "info",
                "FSQL_MCP_SCHEMA_LOCK": SCHEMA_LOCK,
                "FSQL_MCP_SAFETY_LOCK": SAFETY_LOCK}

    servers = []
    try:
        dual = start_http("dual")
        servers.append(dual)
        modern_only = start_http("modern-only",
                                 env_extra={"FSQL_MCP_PROTOCOL_ERA": "modern"})
        servers.append(modern_only)
        readonly = start_http("read-only",
                              env_extra={"FSQL_MCP_READ_ONLY": "true"})
        servers.append(readonly)
        autoexec = start_http("auto-execute",
                              env_extra={"FSQL_MCP_ALLOW_AUTO_EXECUTE": "true"})
        servers.append(autoexec)
        cfg_off = start_http("config-off",
                             env_extra={"FSQL_MCP_CONFIG_WRITES": "off"})
        servers.append(cfg_off)
        cfg_all = start_http("config-all",
                             env_extra={"FSQL_MCP_CONFIG_WRITES": "all"})
        servers.append(cfg_all)
        origins = start_http("origins",
                             env_extra={"FSQL_MCP_ALLOWED_ORIGINS":
                                        "http://allowed.example.com"})
        servers.append(origins)

        only = set(x for x in os.environ.get("MCPC_ONLY", "").split(",") if x)

        def run_group(name, fn, *args):
            if not only or name in only:
                fn(*args)

        run_group("R", check_r_group, dual)
        run_group("T", check_t_group, dual)
        if only:
            return 1 if _failures else 0
        check_m_group(dual)
        check_c_group(dual)
        check_e_group(modern_only, dual)
        check_a_group(dual, tokens)
        check_s_group(dual, origins)
        check_k_group(dual, readonly, autoexec, cfg_off, cfg_all)
        check_h_group(dual, readonly, tokens)
        check_stdio_profile()
    finally:
        # A server that died (a sanitizer abort, a crash) shows up to the driver only as a reset connection; its own
        # stderr says why, and the scratch directory holding it is about to be deleted. Print it first.
        if _failures or sys.exc_info()[0] is not None:
            report_servers(servers)
        for srv in servers:
            srv.stop()
        if not os.environ.get("MCPC_KEEP_SCRATCH"):
            cleanup()

    if _failures:
        print("gate%s-conformance: FAILED; %d failure(s)" % (GATE,
                                                             len(_failures)))
        return 1
    if _skips:
        print("gate%s-conformance: ALL GREEN; 0 failure(s); %d skipped check(s)"
              % (GATE, len(_skips)))
    else:
        print("gate%s-conformance: ALL GREEN; 0 failure(s)" % GATE)
    return 0


if __name__ == "__main__":
    sys.exit(main())
