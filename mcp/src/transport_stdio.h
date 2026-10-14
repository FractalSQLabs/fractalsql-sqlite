// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#pragma once
#include "jsonrpc_server.h"

namespace fsqlmcp
{
    struct StdioConfig { int shutdownDrainMs = 5000; };    // FSQL_MCP_SHUTDOWN_DRAIN_MS

    // Blocks until EOF or a termination signal; drains in-flight requests up
    // to shutdownDrainMs before returning. Returns the process exit code.
    int runStdioTransport( JsonRpcServer& server, const StdioConfig& cfg );
}