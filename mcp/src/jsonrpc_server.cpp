// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#include "jsonrpc_server.h"
#include "resources.h"
#include "prompts.h"
#include <unordered_set>

namespace fsqlmcp
{
    static const std::unordered_set<std::string> kSupportedProtocolVersions{
        "2024-11-05", "2025-03-26", "2025-06-18"
    };
    static const char* const kDefaultProtocolVersion = "2025-06-18";

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
        Json req;
        try { req = Json::parse( line ); }
        catch( ... ) { return makeError( nullptr, -32700, "parse error" ).dump(); }   // framing gate: id:null

        if( !req.is_object() || !req.contains( "jsonrpc" ) || !req.contains( "method" ) )
            return makeError( req.value( "id", Json( nullptr ) ), -32600, "invalid request" ).dump();

        return dispatch( req, clientKey );
    }

    std::optional<std::string> JsonRpcServer::dispatch( const Json& req, const std::string& clientKey )
    {
        const bool isNotification = !req.contains( "id" );
        const std::string method = req.value( "method", "" );

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

        try
        {
            if( method == "initialize" )     return makeResult( id, handleInitialize( req.value( "params", Json::object() ) ) ).dump();
            if( method == "ping" )           return makeResult( id, Json::object() ).dump();
            if( method == "tools/list" )     return makeResult( id, handleToolsList() ).dump();
            if( method == "tools/call" )     return makeResult( id, handleToolsCall( req.value( "params", Json::object() ), clientKey, id.dump() ) ).dump();
            if( method == "resources/list" ) return makeResult( id, handleResourcesList() ).dump();
            if( method == "resources/read" ) return makeResult( id, handleResourcesRead( req.value( "params", Json::object() ) ) ).dump();
            if( method == "resources/templates/list" ) return makeResult( id, Json{ { "resourceTemplates", Json::array() } } ).dump();
            if( method == "prompts/list" )   return makeResult( id, handlePromptsList() ).dump();
            if( method == "prompts/get" )    return makeResult( id, handlePromptsGet( req.value( "params", Json::object() ) ) ).dump();
            return makeError( id, -32601, "method not found: " + method ).dump();
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

    Json JsonRpcServer::handleToolsList()
    {
        Json arr = Json::array();
        for( const ToolSpec& t : tools_ )
        {
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
            Json annotations;
            if( t.destructiveHint ) annotations[ "destructiveHint" ] = true;
            if( t.readOnlyHint )    annotations[ "readOnlyHint" ]    = true;
            if( t.idempotentHint )  annotations[ "idempotentHint" ]  = true;   // 15.2
            if( t.openWorldHint )   annotations[ "openWorldHint" ]   = true;   // 15.2
            if( t.secretHint )      annotations[ "secretHint" ]      = true;   // 15.2
            if( !annotations.empty() ) entry[ "annotations" ] = annotations;
            arr.push_back( entry );
        }
        return Json{ { "tools", arr } };
    }

    Json JsonRpcServer::handleToolsCall( const Json& params, const std::string& clientKey, const std::string& requestId )
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

        const Json args = params.value( "arguments", Json::object() );
        if( !args.is_object() )
            throw ToolError( ErrorClass::Schema, "tool arguments must be a JSON object" );

        // Register as in-flight BEFORE the concurrency acquire, so a $/cancel
        // landing either side of it still finds the session to interrupt (1.1).
        { std::lock_guard<std::mutex> lk( inflightMu_ ); inflightSessions_[ requestId ] = clientKey; }
        ++active_;
        struct ActiveGuard { std::atomic<std::size_t>& a; ~ActiveGuard() { --a; } } activeGuard{ active_ };

        try
        {
            ConcurrencyManager::Token token = conc_.acquire( spec.toolClass, clientKey );

            CallCtx ctx; ctx.clientKey = clientKey;
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
                return Json{ { "content", Json::array( { Json{ { "type", "text" }, { "text", result[ "message" ] } } } ) },
                             { "isError", true }, { "structuredContent", errorPayload } };
            return Json{ { "content", Json::array( { Json{ { "type", "text" }, { "text", result.dump() } } } ) },
                         { "isError", false }, { "structuredContent", result } };
        }
        catch( ... )
        {
            std::lock_guard<std::mutex> lk( inflightMu_ );
            inflightSessions_.erase( requestId );
            throw;
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