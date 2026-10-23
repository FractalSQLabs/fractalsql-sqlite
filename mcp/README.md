<p align="center">
  <img src="../FractalSQLforSQLite.jpg" alt="FractalSQL MCP Server" width="720">
</p>

# FractalSQL MCP Server for SQLite

`fractalsql-sqlite-mcp` is an MCP (Model Context Protocol) server for
**FractalSQL for SQLite**: one clean tool per FractalSQL SQL function, so an
external agent (Claude Desktop, Cursor, Windsurf, Claude Code, LangChain,
LlamaIndex, CrewAI, ...) can call a primitive or one of the sixteen
installable agents without ever speaking SQL.

The full user documentation (quickstart, per-tier tool catalog, resources and
prompts, operational caveats, troubleshooting) lives in
**[docs/mcp-plugin.md](../docs/mcp-plugin.md)**. This README covers building,
running, and deploying the server.

## What's in this directory

    mcp/
      Makefile                    POSIX build (g++ or clang, make)
      scripts/windows/
        build.bat                 MSVC + vcpkg OpenSSL static build
        build-asan.bat            address-sanitized build
      .mcp-schema-lock            committed tool-surface integrity hash
      .mcp-safety-annotations-lock  committed safety-annotation hash
      manifest.json               distribution manifest
      src/                        C++17 sources
        main.cpp                  CLI flags, configuration from the environment
        jsonrpc_server.cpp        JSON-RPC dispatch, cancellation, shutdown
        db.h                      per-session connections, bootstrap, version guard
        tool_registry.cpp         tool table and the shared error taxonomy
        adapters/                 discovery | cognition | agency | analytics |
                                  enterprise | vectorizer | admin
        resources.cpp             the fractalsql:// read-only resources
        prompts.cpp               the eleven starter-kit prompts
        transport_stdio.cpp      default transport (newline-delimited JSON-RPC)
        transport_http.cpp        optional HTTP transport (Bearer token + probes)
        schema_lock.cpp           lock creation and startup verification
        vectors.cpp               vector-argument normalization
        rows.h                    row ceiling and truncation annotation
      vendor/json.hpp             nlohmann::json, vendored
      tests/mcp_smoke_client.py   smoke-test client for the build/test harness

The server binary embeds this repo's own SQLite amalgamation, so the shipped
image has no runtime SQLite dependency: install or copy the binary and point
it at a database file.

## Build and run

```bash
# Linux/macOS: g++ or clang >= 11, OpenSSL dev headers, make
make -C mcp                                   # -> mcp/fractalsql-sqlite-mcp

# Windows: VS 2022 + vcpkg's openssl:x64-windows-static (set VCPKG_ROOT),
# or let the script locate a sibling checkout
mcp\scripts\windows\build.bat                 # -> mcp\dist\windows-mcp\
```

Stdout carries the MCP wire (stdio transport); **all logging goes to stderr**
as structured JSON lines, so the wire protocol is never polluted.

```bash
SQLITE_DB_PATH=/data/app.sqlite \
FRACTALSQL_EXTENSION_PATH=/usr/local/lib/sqlite3/fractalsql.so \
  ./fractalsql-sqlite-mcp                     # stdio (default)

./fractalsql-sqlite-mcp --version             # release banner
./fractalsql-sqlite-mcp --list-tools          # the tool table
./fractalsql-sqlite-mcp --http 8765           # optional HTTP transport
./fractalsql-sqlite-mcp --https 8765 \
  --tls-cert cert.pem --tls-key key.pem       # HTTP transport, direct TLS
```

Configuration is environment-only (`SQLITE_DB_PATH`,
`FRACTALSQL_EXTENSION_PATH`, `FRACTALSQL_BOOTSTRAP_SQL`, `FSQL_MCP_*`) plus
the narrow flag set `--help` prints. The full environment table is in
[docs/mcp-plugin.md](../docs/mcp-plugin.md).

## Keep data access least-privilege

The MCP server inherits whatever its connection can touch and adds **no second
auth layer**. SQLite has no engine-side role model, so the boundary is how you
deploy:

- Open the server against a database file (or `ATTACH` set) that only exposes
  what the MCP client should see. A restricted-view pattern works well: put
  the LLM-facing columns in a view and point schema-aware prompts at it.
- Need a hard in-process hook? Build your own thin wrapper around the server
  process and install a `sqlite3_set_authorizer` there. The hook lives in
  your host process, not in the engine or the shipped server binary.
- Need per-tenant isolation? Run one MCP server instance per tenant-scoped
  database file. That is the boundary SQLite itself offers; the plugin does
  not invent an in-engine mechanism that does not exist.
- Run admin/config tools (`fractalsql_set_config`,
  `fractalsql_configure_reasoning`) against a separately-scoped server
  instance from ordinary tool traffic; the server soft-warns once when they
  share a connection.
- `auto_execute` defaults to false on the SQL-writing agents and requires an
  explicit client-set parameter to enable. `FSQL_MCP_READ_ONLY=true` is the
  deployment-wide stop switch: every `destructiveHint` tool is refused
  outright, before the call reaches the engine. It keys on
  `destructiveHint`, so it stops the seven destructive tools (ledger
  write/reset, `fractal_vectorizer_drop`, the two config tools) — not
  every write; the real no-write boundary is scoping the DB file.

## Regenerating the integrity locks

After any reviewed change to a tool's name, description, or schema, to safety
annotations, or to catalog membership, regenerate the committed checks and
commit them alongside your change:

```bash
fractalsql-sqlite-mcp --write-schema-lock
fractalsql-sqlite-mcp --write-safety-annotations-lock
fractalsql-sqlite-mcp --write-manifest
git add .mcp-schema-lock .mcp-safety-annotations-lock manifest.json
```

The server verifies both locks at startup. Set `FSQL_MCP_STRICT_SCHEMA_HASH=true`
to turn a stale lock into a hard startup failure for strict deployments.