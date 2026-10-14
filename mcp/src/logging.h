// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#pragma once
#include <string>
#include <string_view>
#include "mcp_json.h"
#include "errors.h"

namespace fsqlmcp::logging
{
    enum class Level { Info = 5, Debug = 20 };

    struct Config
    {
        Level level = Level::Info;    // FSQL_MCP_LOG_LEVEL=normal|info|verbose|debug
    };

    void init( const Config& cfg );

    // One JSON-line to stderr per tool call. argsRedactedCapped is the already-
    // capped/redacted copy (redactAndCap); callers must not pass raw
    // caller-supplied arguments here.
    void toolCall( std::string_view toolName, const Json& argsRedactedCapped,
                   double latencyMs, const char* errorClassOrNull );

    // Admin-tool config changes: logs old+new value explicitly.
    void configChange( std::string_view key, std::string_view oldValueRedacted,
                       std::string_view newValueRedacted );

    void exceptionDetail( std::string_view where, std::string_view sanitizedDetail );

    // Startup/operational events (transport listening, lock checks, shutdown).
    void event( std::string_view name, const Json& fields = nullptr );

    bool debugVerbose();   // true when FSQL_MCP_LOG_LEVEL requests verbose bodies (13.6: wired through, not dead)

    // 11.3's capping/redaction rules: arrays -> "<array len=N sha256_8=XXXXXXXX>",
    // long strings -> "<str len=N sha256_8=XXXXXXXX>", any key containing
    // token/password/key/secret (case-insensitive) -> "***", recursing at
    // most 2 levels. Returns a NEW json value; never mutates the input.
    Json redactAndCap( const Json& args, int depth = 0 );
}