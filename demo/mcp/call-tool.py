#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs

"""One-shot MCP tool-call client: sends a raw JSON-RPC
`initialize` + `tools/call` sequence over stdio to a demo MCP server and
prints the tool result, so a user can see a real round trip without
installing Claude Desktop / Cursor first. (For the interactive
alternative: `npx @modelcontextprotocol/inspector` -- see
docs/docker-demo.md.)

Usage: python3 call-tool.py <server-cmd...> -- <tool-name> [json-args]
       (or: call-tool.sh <tool-name> ['{"...json..."}'] in the container)
"""

import json
import shutil
import subprocess
import sys


def main() -> int:  # noqa: ANN201
    argv = sys.argv[1:]
    if not argv or "--help" in argv or "-h" in argv:
        print(__doc__)
        return 0
    if "--" not in argv:
        print("usage: call-tool.py <server-cmd...> -- <tool-name> [json-args]",
              file=sys.stderr)
        return 2
    sep = argv.index("--")
    server_cmd, tool_name = argv[:sep], argv[sep + 1:]
    if not server_cmd or not tool_name:
        print("usage: call-tool.py <server-cmd...> -- <tool-name> [json-args]",
              file=sys.stderr)
        return 2
    args = json.loads(sys.argv[-1]) if len(tool_name) > 1 else {}
    tool_name = tool_name[0]

    # Command-injection guard: server_cmd[0] is raw CLI text about to be
    # executed, so require it to resolve to a real, executable file before
    # Popen (and hand Popen the resolved absolute path, unchanged behavior
    # with a guaranteed-resolvable argv[0]).
    server_exe = shutil.which(server_cmd[0])
    if server_exe is None:
        print(f"call-tool.py: server command not found or not executable: "
              f"{server_cmd[0]}", file=sys.stderr)
        return 2
    server_cmd = [server_exe] + server_cmd[1:]

    proc = subprocess.Popen(server_cmd, stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, text=True)

    def send(msg: dict) -> None:  # noqa: ANN001
        proc.stdin.write(json.dumps(msg) + "\n")
        proc.stdin.flush()

    def recv() -> dict:  # noqa: ANN001
        line = proc.stdout.readline()
        if not line:
            print("server closed without answering", file=sys.stderr)
            raise SystemExit(1)
        return json.loads(line)

    send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
          "params": {"protocolVersion": "2025-06-18",
                     "clientInfo": {"name": "call-tool", "version": "0"}}})
    init = recv()
    server = init.get("result", {}).get("serverInfo", {})
    print(f"# MCP session established: {server.get('name')} "
          f"{server.get('version', '')}".rstrip(), file=sys.stderr)
    send({"jsonrpc": "2.0", "method": "notifications/initialized"})
    send({"jsonrpc": "2.0", "id": 2, "method": "tools/call",
          "params": {"name": tool_name, "arguments": args}})
    while True:
        resp = recv()
        if resp.get("id") == 2:
            break
    proc.stdin.close()
    proc.wait(timeout=15)

    result = resp.get("result")
    if result is None:
        print(json.dumps(resp, indent=2))
        return 1
    if result.get("isError"):
        print("TOOL ERROR: " + result["content"][0]["text"], file=sys.stderr)
        return 1
    if "structuredContent" in result:
        print(json.dumps(result["structuredContent"], indent=2,
                         ensure_ascii=False))
    else:
        print(result["content"][0]["text"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())