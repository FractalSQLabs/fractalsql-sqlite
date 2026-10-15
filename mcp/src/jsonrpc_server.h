// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#pragma once
#include <optional>
#include <string>
#include <functional>
#include <unordered_map>
#include <unordered_set>
#include <mutex>
#include "mcp_json.h"
#include "tool_registry.h"
#include "concurrency.h"
#include "rows.h"
#include <atomic>
#include "logging.h"

namespace fsqlmcp
{
    struct ServerConfig
    {
        std::string serverName    = "fractalsql-mcp";
        std::string serverVersion = "0.0.0";
        RowLimitConfig rowLimits;
        // 15.4's deployment-wide kill switch (FSQL_MCP_READ_ONLY): refuse every
        // destructive call before it reaches the adapter layer.
        bool readOnlyMode = false;
    };

    // Transport-agnostic dispatch core, called identically from
    // transport_stdio.cpp (per-line) and transport_http.cpp (per-POST-body).
    class JsonRpcServer
    {
    public:
        JsonRpcServer( ServerConfig cfg, std::vector<ToolSpec> tools, ConcurrencyConfig concCfg );

        // Returns std::nullopt for a notification or a cancelled-and-discarded call.
        std::optional<std::string> handleLine( const std::string& line, const std::string& clientKey );

        // notifications/cancelled side effect: flags the id AND interrupts the
        // session's engine statement (sqlite3_interrupt here; pg_cancel_backend /
        // KILL QUERY in the other engines' db layers).
        void cancel( const std::string& requestId );
        void beginShutdown();
        bool isShuttingDown() const { return shuttingDown_; }
        std::size_t activeRequestCount() { return active_.load(); }

        const std::vector<ToolSpec>& tools() const { return tools_; }

        // Wired by each engine's main(): interrupts the in-flight statement on
        // the connection owning the given client/session key (13.4.3's cancel
        // path: sqlite3_interrupt here; pg_cancel_backend / KILL QUERY
        // elsewhere). Receives the client key because only the dispatch layer
        // maps a request id to its session.
        std::function<void( const std::string& clientKey )> interruptHook;

    private:
        std::optional<std::string> dispatch( const Json& req, const std::string& clientKey );
        Json handleInitialize( const Json& params );
        Json handleToolsList();
        Json handleToolsCall( const Json& params, const std::string& clientKey, const std::string& requestId );
        Json handleResourcesList();
        Json handleResourcesRead( const Json& params );
        Json handlePromptsList();
        Json handlePromptsGet( const Json& params );

        ServerConfig cfg_;
        std::vector<ToolSpec> tools_;
        std::unordered_map<std::string, const ToolSpec*> byName_;
        ConcurrencyManager conc_;
        std::mutex inflightMu_;
        std::unordered_map<std::string, std::string> inflightSessions_; // request id -> client key
        std::unordered_set<std::string> cancelledIds_;
        bool shuttingDown_ = false;
        std::atomic<std::size_t> active_{ 0 };
    };
}