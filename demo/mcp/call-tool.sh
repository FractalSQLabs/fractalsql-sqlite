#!/bin/sh
# SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#
# The demo container's one-liner MCP tool call:
#
#   docker compose exec demo demo/mcp/call-tool.sh fractal_search \
#       '{"vector":[0.1,0.9],"query":[0.6,0.8]}'
#
# Runs the PRODUCTION MCP server binary (the same one mcp/ builds) with
# its tool table --tool-filtered to exactly the four pinned demo tools
# rather than a second, drifting demo implementation (the demo owns
# only this wrapper, not its own server).
# Wraps call-tool.py (the one-shot initialize + tools/call client) with
# the demo container's own configuration (the same
# /work/fractalsql_demo.sqlite + staged extension the SQL-level demos
# use; reasoning already pre-configured per connection via the
# entrypoint's demo_init.sql, which is passed as FRACTALSQL_BOOTSTRAP_SQL;
# its .load line is honored-but-skipped by the server, which loads the
# extension through the driver first). Deliberately reuses the demo
# compose project's own credentials/posture, so this is NOT a production
# posture.
set -eu

DEMO=/demo/mcp
DEMO_TOOLS=fractal_search,fractal_reason,fractal_agent_data_analyst,fractal_agent_diverse_portfolios

# Resolve the server binary: in-container path first (staged into
# /usr/local/bin by the Dockerfile), then the repo-checkout build (the
# Makefile's output), so the same wrapper works outside the container
# against a locally built mcp/fractalsql-sqlite-mcp.
SERVER=""
for CAND in \
    /usr/local/bin/fractalsql-sqlite-mcp \
    "$(dirname "$0")/../../mcp/fractalsql-sqlite-mcp" \
    "$(dirname "$0")/../../mcp/dist/windows-mcp/fractalsql-sqlite-mcp.exe"
do
    if [ -f "$CAND" ]; then
        SERVER="$CAND"
        break
    fi
done
if [ -z "$SERVER" ]; then
    echo "ERROR: no fractalsql-sqlite-mcp binary found." >&2
    echo "In the container it is staged by docker/Dockerfile; from a checkout build it with:" >&2
    echo "    make -C mcp                 (Linux/macOS)" >&2
    echo "    mcp\\scripts\\windows\\build.bat   (Windows)" >&2
    exit 1
fi

# Demo-process connection config (the env contract), same
# database + extension the demo image already stages.
if [ -z "${SQLITE_DB_PATH:-}" ]; then
    SQLITE_DB_PATH=/work/fractalsql_demo.sqlite
    export SQLITE_DB_PATH
fi
if [ -z "${FRACTALSQL_EXTENSION_PATH:-}" ]; then
    FRACTALSQL_EXTENSION_PATH=/usr/local/lib/sqlite3/fractalsql.so
    export FRACTALSQL_EXTENSION_PATH
fi
if [ -z "${FRACTALSQL_BOOTSTRAP_SQL:-}" ] && [ -f "${FSQL_DEMO_INIT:-/work/demo_init.sql}" ]; then
    # The entrypoint-generated bootstrap snippet (fractalsql_set() lines
    # pointing reasoning at the compose ollama service; the .load line is
    # honored-but-skipped). Pass the text itself, not the file path.
    FRACTALSQL_BOOTSTRAP_SQL="$(cat "${FSQL_DEMO_INIT:-/work/demo_init.sql}")"
    export FRACTALSQL_BOOTSTRAP_SQL
fi

if [ "$#" -lt 1 ]; then
    echo "usage: $0 <tool-name> ['{json args}']" >&2
    echo "demo tools: fractal_search, fractal_reason, fractal_agent_data_analyst," >&2
    echo "            fractal_agent_diverse_portfolios" >&2
    exit 2
fi
TOOL="$1"; shift
TOOL_ARGS="${1:-{\}}"

# Server argv = [binary, --tool, <four demo tools>]; the named tool and
# its JSON arguments travel only inside the JSON-RPC tools/call payload
# (call-tool.py splits the server command at the first '--').
exec python3 "$DEMO/call-tool.py" \
    "$SERVER" --tool "$DEMO_TOOLS" \
    -- "$TOOL" "$TOOL_ARGS"