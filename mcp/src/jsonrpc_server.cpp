// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#include "jsonrpc_server.h"
#include "resources.h"
#include "prompts.h"
#include "policy.h"
#include <algorithm>
#include <unordered_set>

namespace fsqlmcp
{
    // Every revision this server speaks. The first three are the legacy era
    // (initialize handshake + Mcp-Session-Id); the last two are the modern
    // era (stateless requests, per-request _meta).
    static const std::unordered_set<std::string> kSupportedProtocolVersions{
        "2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25", "2026-07-28"
    };
    static const char* const kDefaultProtocolVersion = "2025-06-18";

    // The tools that take the model's auto_execute flag. The flag is
    // controlled by the same actor the control protects against, so the
    // operator's switch (FSQL_MCP_ALLOW_AUTO_EXECUTE) decides, not the model.
    static bool takesAutoExecute( std::string_view name )
    {
        return name == "fractal_sql_agent" || name == "fractal_agent_data_analyst";
    }

    JsonRpcServer::JsonRpcServer( ServerConfig cfg, std::vector<ToolSpec> tools, ConcurrencyConfig concCfg )
        : cfg_( std::move( cfg ) ), tools_( std::move( tools ) ), conc_( concCfg )
    {
        for( const ToolSpec& t : tools_ )
            byName_[ std::string( t.name ) ] = &t;
        logging::event( "server_built", Json{ { "n_tools", tools_.size() } } );
    }

    static Json makeError( const Json& id, int code, const std::string& message )
    {
        return Json{ { "jsonrpc", "2.0" }, { "id", id }, { "error", { { "code", code }, { "message", message } } } };
    }
    static Json makeResult( const Json& id, Json result )
    {
        return Json{ { "jsonrpc", "2.0" }, { "id", id }, { "result", std::move( result ) } };
    }

    std::optional<std::string> JsonRpcServer::handleLine( const std::string& line, const std::string& clientKey )
    {
        return handleLine( line, clientKey, CallOptions{} );
    }

    std::optional<std::string> JsonRpcServer::handleLine( const std::string& line, const std::string& clientKey,
                                                          const CallOptions& opts )
    {
        Json req;
        if( jsonNestsTooDeep( line ) )
            return makeError( nullptr, -32700, "parse error: nesting too deep" ).dump();
        try { req = Json::parse( line ); }
        catch( ... ) { return makeError( nullptr, -32700, "parse error" ).dump(); }   // framing gate: id:null

        if( !req.is_object() || !req.contains( "jsonrpc" ) || !req.contains( "method" ) )
            // value() throws type_error.306 on a non-object line (an array, string, number
            // or null), which escaped and aborted the whole process.
            return makeError( req.is_object() ? req.value( "id", Json( nullptr ) ) : Json( nullptr ), -32600, "invalid request" ).dump();

        // Nothing may escape handleLine: the stdio transport runs it on a worker thread
        // and an escaping exception there is std::terminate (the whole server dies).
        try { return dispatch( req, clientKey, opts ); }
        catch( const std::exception& e )
        {
            logging::exceptionDetail( "handleLine", sanitizeSecrets( e.what() ) );
            return makeError( nullptr, -32603, "internal server error" ).dump();
        }
    }

    std::optional<std::string> JsonRpcServer::dispatch( const Json& req, const std::string& clientKey,
                                                        const CallOptions& opts )
    {
        const bool isNotification = !req.contains( "id" );
        // value() does not type-check a key it finds: a non-string "method" threw
        // type_error.302 out of here and aborted the server. A non-string method is
        // just an unknown method (-32601).
        const std::string method = ( req.contains( "method" ) && req[ "method" ].is_string() )
            ? req[ "method" ].get<std::string>() : std::string();

        if( method == "notifications/cancelled" || method == "$/cancel" )
        {
            if( req.contains( "params" ) && req[ "params" ].is_object() &&
                req[ "params" ].contains( "requestId" ) )
                cancel( req[ "params" ][ "requestId" ].dump() );
            return std::nullopt;             // never reply to a notification
        }
        if( isNotification )
            return std::nullopt;             // e.g. notifications/initialized

        const Json& id = req[ "id" ];
        if( shuttingDown_ )
            return makeError( id, -32000,
                "server shutting down (a new request was refused after the shutdown signal; retry after restart)" ).dump();

        const bool modern = ( opts.era == ProtocolEra::Modern );

        try
        {
            Json result;
            bool listResult = false;
            if( method == "initialize" )
            {
                if( cfg_.modernOnly )
                    return makeError( id, -32000,
                        "this server speaks the modern protocol era only (FSQL_MCP_PROTOCOL_ERA=modern); "
                        "the initialize handshake is part of the legacy era and is refused. "
                        "Supported versions: 2025-11-25, 2026-07-28" ).dump();
                result = handleInitialize( req.value( "params", Json::object() ) );
            }
            else if( method == "server/discover" ) result = handleServerDiscover();
            else if( method == "ping" )           result = Json::object();
            else if( method == "tools/list" )     { result = handleToolsList( opts ); listResult = true; }
            else if( method == "tools/call" )     result = handleToolsCall( req.value( "params", Json::object() ), clientKey, id.dump(), opts );
            else if( method == "resources/list" ) { result = handleResourcesList(); listResult = true; }
            else if( method == "resources/read" ) { result = handleResourcesRead( req.value( "params", Json::object() ) ); listResult = true; }
            else if( method == "resources/templates/list" ) { result = Json{ { "resourceTemplates", Json::array() } }; listResult = true; }
            else if( method == "prompts/list" )   { result = handlePromptsList(); listResult = true; }
            else if( method == "prompts/get" )    result = handlePromptsGet( req.value( "params", Json::object() ) );
            else return makeError( id, -32601, "method not found: " + method ).dump();

            if( modern )
            {
                // The modern era's result envelope: every result says what kind
                // of result it is, and a list result says how long it may be
                // cached and in which scope.
                result[ "resultType" ] = "complete";
                if( listResult )
                {
                    result[ "ttlMs" ] = 0;              // this catalog is not cacheable
                    result[ "cacheScope" ] = "session"; // ...and it is scoped to the caller's session
                }
            }
            return makeResult( id, std::move( result ) ).dump();
        }
        catch( const ToolError& e )
        {
            // tools/call's own error-shaped result (isError:true) is built inside
            // handleToolsCall; a ToolError escaping here means some OTHER handler
            // (resources/read's bad-kind, etc.) hit the same typed-error path.
            // Schema-class => -32602 per JSON-RPC convention (the Python
            // reference's own mapping); everything else -32000.
            const int code = ( e.errorClass == ErrorClass::Schema ) ? -32602 : -32000;
            return makeError( id, code, e.message ).dump();
        }
        catch( const std::exception& e )
        {
            logging::exceptionDetail( "dispatch", sanitizeSecrets( e.what() ) );
            return makeError( id, -32000, "internal server error" ).dump();
        }
    }

    Json JsonRpcServer::handleInitialize( const Json& params )
    {
        std::string proto = kDefaultProtocolVersion;
        if( params.contains( "protocolVersion" ) && params[ "protocolVersion" ].is_string() )
        {
            const std::string requested = params[ "protocolVersion" ].get<std::string>();
            if( kSupportedProtocolVersions.count( requested ) )
                proto = requested;      // echo back if recognized; else fall back silently
        }
        return Json{
            { "protocolVersion", proto },
            { "serverInfo", { { "name", cfg_.serverName }, { "version", cfg_.serverVersion } } },
            { "capabilities", { { "tools", Json::object() },
                                { "resources", Json::object() },
                                { "prompts", Json::object() },
                                { "logging", Json::object() } } }
        };
    }

    // The modern era's discovery RPC: which revisions this server speaks, what
    // it can do and who it is. A modern client reads the supported versions
    // from here instead of guessing.
    Json JsonRpcServer::handleServerDiscover()
    {
        Json versions = Json::array();
        for( const std::string& v : { "2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25", "2026-07-28" } )
            versions.push_back( v );
        return Json{
            { "protocolVersions", versions },
            { "serverInfo", { { "name", cfg_.serverName }, { "version", cfg_.serverVersion } } },
            { "capabilities", { { "tools", Json::object() },
                                { "resources", Json::object() },
                                { "prompts", Json::object() },
                                { "logging", Json::object() } } }
        };
    }

    Json JsonRpcServer::handleToolsList( const CallOptions& opts )
    {
        // A deterministic order (by name) in BOTH eras: the spec asks for it,
        // and a client that compares two listings must see the same order
        // whichever era it asked in.
        std::vector<const ToolSpec*> sorted;
        sorted.reserve( tools_.size() );
        for( const ToolSpec& t : tools_ ) sorted.push_back( &t );
        std::sort( sorted.begin(), sorted.end(),
                   []( const ToolSpec* a, const ToolSpec* b ) { return a->name < b->name; } );

        Json arr = Json::array();
        for( const ToolSpec* tp : sorted )
        {
            const ToolSpec& t = *tp;
            // A per-client credential may be limited to a subset of the
            // catalog; the tools it may not call are not even listed.
            if( opts.toolAllow && opts.toolAllow->count( std::string( t.name ) ) == 0 ) continue;
            Json entry{
                { "name", std::string( t.name ) },
                { "description", std::string( t.description ) },
                { "inputSchema", buildInputSchema( t ) },
                // 1.7's discovery grouping + 11.2's class, as the documented
                // non-standard-but-declared _meta extension. x-fractalsql-retry-tier
                // is omitted entirely on SQLite (no daemon, no tiering; 11.2).
                { "_meta", { { "x-fractalsql-tier", std::string( t.category ) },
                             { "x-fractalsql-class", std::string( toolClassName( t.toolClass ) ) } } }
            };
            if( t.retryTier )
                entry[ "_meta" ][ "x-fractalsql-retry-tier" ] = std::string( *t.retryTier );   // retry-tier editions only
            entry[ "annotations" ] = toolAnnotations( t );
            arr.push_back( entry );
        }
        return Json{ { "tools", arr } };
    }

    Json JsonRpcServer::handleToolsCall( const Json& params, const std::string& clientKey, const std::string& requestId,
                                         const CallOptions& opts )
    {
        const std::string name = params.value( "name", "" );
        auto it = byName_.find( name );
        if( it == byName_.end() )
            throw ToolError( ErrorClass::Schema, "unknown tool '" + name + "'; tools/list has the full catalog "
                              "(tool names are the underlying FractalSQL SQL function names, unprefixed)" );
        const ToolSpec& spec = *it->second;

        // 15.4: deployment-wide read-only switch, checked before the
        // concurrency-slot acquire so a refused call never touches the
        // adapter layer nor counts against any cap.
        if( cfg_.readOnlyMode && spec.destructiveHint )
            throw ToolError( ErrorClass::Schema,
                "server is running in read-only mode (FSQL_MCP_READ_ONLY=true); '" + name +
                "' is destructive and was refused before reaching the engine" );

        // A per-client credential restricted to a subset of the catalog may
        // not call outside it, even by guessing the name.
        if( opts.toolAllow && opts.toolAllow->count( name ) == 0 )
            throw ToolError( ErrorClass::Schema,
                "tool '" + name + "' is not in this client's tool allowlist; the credential that made "
                "this request may only call: " + [ &opts ] {
                    std::string s;
                    for( const std::string& n : *opts.toolAllow ) { if( !s.empty() ) s += ", "; s += n; }
                    return s;
                }() );

        Json args = params.value( "arguments", Json::object() );
        if( !args.is_object() )
            throw ToolError( ErrorClass::Schema, "tool arguments must be a JSON object" );

        // The context handle is the transport's, not the engine's: it selects
        // which connection the call runs on and never reaches the adapter.
        args.erase( "context_id" );

        // The model's auto_execute flag only counts when the operator turned
        // it on: the parameter is set by the same actor the control protects
        // against, so a flag is not a control.
        if( takesAutoExecute( spec.name ) && args.contains( "auto_execute" ) &&
            args[ "auto_execute" ].is_boolean() && args[ "auto_execute" ].get<bool>() &&
            !autoExecuteAllowed() )
            throw ToolError( ErrorClass::Schema,
                "auto_execute is refused: this server runs with FSQL_MCP_ALLOW_AUTO_EXECUTE unset, so a "
                "generated statement is never executed without an operator turning that switch on "
                "(FSQL_MCP_ALLOW_AUTO_EXECUTE=true). Generate the SQL and run it yourself instead." );

        // Register as in-flight BEFORE the concurrency acquire, so a $/cancel
        // landing either side of it still finds the session to interrupt (1.1).
        { std::lock_guard<std::mutex> lk( inflightMu_ ); inflightSessions_[ requestId ] = clientKey; }
        ++active_;
        struct ActiveGuard { std::atomic<std::size_t>& a; ~ActiveGuard() { --a; } } activeGuard{ active_ };

        // Drops the in-flight entry on any exit (a no-op once the success path erased it).
        struct SessionGuard
        {
            JsonRpcServer& s; const std::string& id;
            ~SessionGuard() { std::lock_guard<std::mutex> lk( s.inflightMu_ ); s.inflightSessions_.erase( id ); }
        } sessionGuard{ *this, requestId };

        {
            ConcurrencyManager::Token token = conc_.acquire( spec.toolClass, clientKey );

            CallCtx ctx; ctx.clientKey = clientKey;
            // Which protocol era this call arrived in: the operator's log
            // says so on every call, so a client that silently falls back
            // from the modern era to the legacy one is visible.
            ctx.era = ( opts.era == ProtocolEra::Modern ) ? "modern" : "legacy";
            { std::lock_guard<std::mutex> lk( inflightMu_ ); ctx.cancelled = cancelledIds_.count( requestId ) != 0; }

            Json result;
            bool isError = false;
            Json errorPayload;
            try
            {
                result = runTool( spec, args, ctx );
            }
            catch( const ToolError& e )
            {
                isError = true;
                errorPayload = e.clientPayload();
                // 1.6: the original engine message in the text content, verbatim;
                // 11.1: the class in a structured field the client can branch on
                // (ServerInternal is genericized by clientPayload already).
                result = Json{ { "message", e.errorClass == ErrorClass::ServerInternal
                                                ? errorPayload[ "message" ].get<std::string>()
                                                : e.message } };
            }

            bool cancelledAfter = false;
            { std::lock_guard<std::mutex> lk( inflightMu_ );
              cancelledAfter = cancelledIds_.count( requestId ) != 0;
              inflightSessions_.erase( requestId );
              cancelledIds_.erase( requestId ); }
            if( cancelledAfter )
                throw ToolError( ErrorClass::Cancelled, "call was cancelled; result discarded" );   // 1.1: never deliver a late result

            if( isError )
            {
                Json out{ { "content", Json::array( { Json{ { "type", "text" }, { "text", result[ "message" ] } } } ) },
                          { "isError", true }, { "structuredContent", errorPayload } };
                if( !opts.contextId.empty() ) out[ "context_id" ] = opts.contextId;
                return out;
            }
            Json out{ { "content", Json::array( { Json{ { "type", "text" }, { "text", result.dump() } } } ) },
                      { "isError", false }, { "structuredContent", result } };
            // The context handle the caller may pass back to keep using the
            // same engine state.
            if( !opts.contextId.empty() ) out[ "context_id" ] = opts.contextId;
            return out;
        }
    }

    Json JsonRpcServer::handleResourcesList() { return Resources::list(); }
    Json JsonRpcServer::handleResourcesRead( const Json& params ) { return Resources::read( params.value( "uri", "" ) ); }
    Json JsonRpcServer::handlePromptsList()   { return Prompts::list(); }
    Json JsonRpcServer::handlePromptsGet( const Json& params )
    {
        return Prompts::get( params.value( "name", "" ), params.value( "arguments", Json::object() ) );
    }

    void JsonRpcServer::cancel( const std::string& requestId )
    {
        std::string clientKey;
        {
            std::lock_guard<std::mutex> lk( inflightMu_ );
            cancelledIds_.insert( requestId );
            auto it = inflightSessions_.find( requestId );
            if( it != inflightSessions_.end() ) clientKey = it->second;
        }
        if( interruptHook && !clientKey.empty() )
            interruptHook( clientKey );   // adapter-layer interrupt (engine-specific)
        logging::event( "cancel_propagated", Json{ { "request", requestId } } );
    }

    void JsonRpcServer::beginShutdown()
    {
        shuttingDown_ = true;
        logging::event( "shutdown_begin" );
    }
}