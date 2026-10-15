// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
// fractalsql-sqlite-mcp entrypoint: builds the full tool table up front and
// wires the stdio or HTTP transport.
#include <cstdlib>
#include <cstring>
#include <cctype>
#include <fstream>
#include <filesystem>
#include <iostream>
#include <algorithm>
#include <string>
#include <vector>

#include "jsonrpc_server.h"
#include "transport_stdio.h"
#include "transport_http.h"
#include "schema_lock.h"
#include "safety_lock.h"
#include "logging.h"
#include "db.h"
#include "resources.h"
#include "prompts.h"
#include "adapters/discovery.h"
#include "adapters/cognition.h"
#include "adapters/agency.h"
#include "adapters/analytics.h"
#include "adapters/enterprise.h"
#include "adapters/vectorizer.h"
#include "adapters/admin.h"

#if defined( _WIN32 )
#include <fcntl.h>
#include <io.h>
#endif

using namespace fsqlmcp;

static std::vector<ToolSpec> buildAllTools( Db& db )
{
    // NOTE: the rowCfg here must NOT be a local. Handlers
    // capture it by reference and are called long after this function
    // returns. sharedRowLimitConfig() is the process-wide object; main()
    // sets its ceiling from env BEFORE this builder runs.
    const RowLimitConfig& rowCfg = sharedRowLimitConfig();
    std::vector<ToolSpec> all;
    const std::vector<std::vector<ToolSpec>> tiers{
        buildDiscoveryTools( db, rowCfg ), buildCognitionTools( db ), buildAgencyTools( db ),
        buildAnalyticsTools( db, rowCfg ), buildEnterpriseTools( db ),
        buildVectorizerTools( db ), buildAdminTools( db )
    };
    for( const auto& v : tiers )
        all.insert( all.end(), v.begin(), v.end() );
    Resources::init( &db );

    // 81 tools total: 14+4+22+22+10+5+4. This is what the engine actually
    // registers, verified against the live extension, and main.cpp checks
    // the same total when it labels a filtered surface.

    // idempotentHint derivation, in ONE place: a genuinely read-only
    // tool is idempotent by definition, plus the documented diversify
    // enable/disable no-op pair.
    for( ToolSpec& t : all )
        if( t.readOnlyHint )
            t.idempotentHint = true;
    for( ToolSpec& t : all )
        if( t.name == "fractal_diversify_enable" || t.name == "fractal_diversify_disable" )
            t.idempotentHint = true;
    return all;
}

static std::string envOr( const char* name, const std::string& def )
{
    const char* v = std::getenv( name );
    return ( v && *v ) ? std::string( v ) : def;
}
static int envIntOr( const char* name, int def )
{
    const char* v = std::getenv( name );
    return ( v && *v ) ? std::atoi( v ) : def;
}
static bool envBool( const char* name, bool def )
{
    const char* v = std::getenv( name );
    if( !v || !*v ) return def;
    std::string s( v );
    std::transform( s.begin(), s.end(), s.begin(), []( unsigned char c ) { return std::tolower( c ); } );
    return s == "true" || s == "1" || s == "on" || s == "yes";
}

static std::vector<std::string> splitCsv( const std::string& raw )
{
    std::vector<std::string> out;
    std::size_t start = 0;
    while( start < raw.size() )
    {
        const std::size_t comma = raw.find( ',', start );
        const std::string part = raw.substr( start,
            comma == std::string::npos ? std::string::npos : comma - start );
        const std::size_t nb = part.find_first_not_of( " \t" );
        if( nb != std::string::npos )
            out.push_back( part.substr( nb, part.find_last_not_of( " \t" ) - nb + 1 ) );
        if( comma == std::string::npos ) break;
        start = comma + 1;
    }
    return out;
}

// Tool-catalog narrowing: --tool/--category (and their env
// equivalents) filter the built table; filtered-out tools are simply absent
// from tools/list and resolve as unknown on tools/call. Category comparison
// is case-insensitive: the tool tables carry the capitalized tier names the
// docs teach ("Discovery", "Cognition", ...) while the env-var lists and
// the demo's --tool filter speak lowercase.
static std::vector<ToolSpec> filterTools( std::vector<ToolSpec> tools,
                                          const std::vector<std::string>& enabledCategories,
                                          const std::vector<std::string>& toolWhitelist )
{
    if( enabledCategories.empty() && toolWhitelist.empty() ) return tools;
    std::vector<ToolSpec> out;
    for( ToolSpec& t : tools )
    {
        std::string catLower( t.category );
        std::transform( catLower.begin(), catLower.end(), catLower.begin(),
                        []( unsigned char c ) { return std::tolower( c ); } );
        const bool categoryOk = enabledCategories.empty() ||
            std::find( enabledCategories.begin(), enabledCategories.end(), catLower )
                != enabledCategories.end();
        const bool nameOk = toolWhitelist.empty() ||
            std::find( toolWhitelist.begin(), toolWhitelist.end(), std::string( t.name ) )
                != toolWhitelist.end();
        if( categoryOk && nameOk ) out.push_back( std::move( t ) );
    }
    return out;
}

static void usage()
{
    std::cout <<
        "fractalsql-sqlite-mcp " << kMcpPluginVersion <<
        ", the FractalSQL for SQLite MCP plugin suite server\n"
        "\n"
        "Runs as an MCP server over stdio by default (one JSON-RPC 2.0 message per line).\n"
        "Connect env: SQLITE_DB_PATH, FRACTALSQL_EXTENSION_PATH, FRACTALSQL_BOOTSTRAP_SQL.\n"
        "\n"
        "Flags:\n"
        "  --version                        print the plugin version and exit\n"
        "  --write-schema-lock              regenerate .mcp-schema-lock and exit\n"
        "  --schema-lock-path PATH          override the lock file path\n"
        "  --write-safety-annotations-lock  regenerate .mcp-safety-annotations-lock and exit\n"
        "  --write-manifest                 regenerate manifest.json and exit\n"
        "  --list-tools                     print the filtered tool names, one per line, and exit\n"
        "  --tool a,b,c                     register only these tools (FSQL_MCP_TOOL_WHITELIST)\n"
        "  --category x,y                   register only these categories (FSQL_MCP_ENABLED_CATEGORIES):\n"
        "                                   discovery,cognition,agency,analytics,enterprise,vectorizer,admin\n"
        "  --http [PORT]                    run the HTTP transport (default 8765; needs an env auth token)\n"
        "  --https [PORT]                   run the HTTP transport with direct TLS (needs --tls-cert/\n"
        "                                   --tls-key or FSQL_MCP_TLS_CERT_FILE/FSQL_MCP_TLS_KEY_FILE;\n"
        "                                   default OFF -- TLS terminating in front via a reverse proxy\n"
        "                                   remains the documented zero-config posture)\n"
        "  --host H, --path P               HTTP/HTTPS transport host/path\n"
        "  --tls-cert PATH, --tls-key PATH  PEM certificate (chain OK) / unencrypted PEM private key\n"
        "                                   for --https (or FSQL_MCP_TLS_CERT_FILE/FSQL_MCP_TLS_KEY_FILE)\n"
        "\n"
        "Knobs (env): FSQL_MCP_AUTH_TOKEN, FSQL_MCP_AUTH_TOKEN_FILE, FSQL_MCP_MAX_ROWS_CEILING,\n"
        "FSQL_MCP_MAX_CONCURRENT_CHEAP/EXPENSIVE/EXPENSIVE_PER_CLIENT, FSQL_MCP_MAX_QUEUE_WAIT_MS,\n"
        "FSQL_MCP_SHUTDOWN_DRAIN_MS, FSQL_MCP_STRICT_SCHEMA_HASH, FSQL_MCP_READ_ONLY,\n"
        "FSQL_MCP_HTTPS, FSQL_MCP_TLS_CERT_FILE, FSQL_MCP_TLS_KEY_FILE,\n"
        "FSQL_MCP_LOG_LEVEL (normal|info|verbose|debug).\n"
        "Lock/manifest files default next to this binary's repo checkout; see mcp/README.md.\n";
}

static std::string findRepoLockPath( const char* fname )
{
    // Walk up from the CWD to the checkout root (here: a directory
    // containing .git or Makefile) and prefer its mcp/ directory, so the
    // committed locks/manifest are found wherever the binary is launched
    // from.
    namespace fs = std::filesystem;
    std::error_code ec;
    fs::path dir = fs::current_path( ec );
    int depth = 0;
    while( depth++ < 8 )
    {
        if( fs::exists( dir / ".git", ec ) || fs::exists( dir / "Makefile", ec ) || depth == 8 )
        {
            fs::path p = dir / "mcp" / fname;
            if( fs::exists( dir / "mcp", ec ) )
                return p.string();
            return ( dir / fname ).string();
        }
        fs::path parent = dir.parent_path();
        if( parent == dir ) break;
        dir = parent;
    }
    return std::string( fname );
}

int main( int argc, char** argv )
{
#if defined( _WIN32 )
    // The stdio transport carries UTF-8 JSON; Windows text mode would corrupt
    // high bytes (a 0x0A byte inside a JSON payload is impossible, but raw
    // CRLF translation of 0x0A-on-write corrupts framing).
    _setmode( _fileno( stdin ), _O_BINARY );
    _setmode( _fileno( stdout ), _O_BINARY );
#endif

    bool writeLock = false, writeSafetyLock = false, writeManifest = false, listTools = false;
    bool httpMode = false;
    bool httpsMode = false;
    int httpPort = envIntOr( "FSQL_MCP_HTTP_PORT", 8765 );
    std::string httpHost = envOr( "FSQL_MCP_HTTP_HOST", "127.0.0.1" );
    std::string httpPath = envOr( "FSQL_MCP_HTTP_PATH", "/mcp" );
    std::string tlsCertFile = envOr( "FSQL_MCP_TLS_CERT_FILE", "" );
    std::string tlsKeyFile  = envOr( "FSQL_MCP_TLS_KEY_FILE", "" );
    std::string lockPath = envOr( "FSQL_MCP_SCHEMA_LOCK", "" );
    std::string safetyLockPath = envOr( "FSQL_MCP_SAFETY_LOCK", "" );
    std::vector<std::string> toolWhitelist, enabledCategories;

    for( int i = 1; i < argc; ++i )
    {
        const std::string arg( argv[ i ] );
        auto next = [&]( const char* flagName ) -> std::string {
            if( i + 1 >= argc )
            {
                std::cerr << "missing value for " << flagName << "\n";
                std::exit( 2 );
            }
            return std::string( argv[ ++i ] );
        };
        if( arg == "--write-schema-lock" ) writeLock = true;
        else if( arg == "--write-safety-annotations-lock" ) writeSafetyLock = true;
        else if( arg == "--write-manifest" ) writeManifest = true;
        else if( arg == "--list-tools" ) listTools = true;
        else if( arg == "--schema-lock-path" ) lockPath = next( "--schema-lock-path" );
        else if( arg == "--safety-lock-path" ) safetyLockPath = next( "--safety-lock-path" );
        else if( arg == "--tool" ) toolWhitelist = splitCsv( next( "--tool" ) );
        else if( arg == "--category" ) enabledCategories = splitCsv( next( "--category" ) );
        else if( arg == "--http" || arg == "--http-transport" )
        { httpMode = true; if( i + 1 < argc && argv[ i + 1 ][ 0 ] != '-' ) httpPort = std::atoi( argv[ ++i ] ); }
        else if( arg == "--https" )
        { httpMode = true; httpsMode = true; if( i + 1 < argc && argv[ i + 1 ][ 0 ] != '-' ) httpPort = std::atoi( argv[ ++i ] ); }
        else if( arg == "--host" ) httpHost = next( "--host" );
        else if( arg == "--path" ) httpPath = next( "--path" );
        else if( arg == "--tls-cert" ) tlsCertFile = next( "--tls-cert" );
        else if( arg == "--tls-key" ) tlsKeyFile = next( "--tls-key" );
        else if( arg == "--help" || arg == "-h" ) { usage(); return 0; }
        else if( arg == "--version" )
        {
            std::cout << kMcpPluginVersion << "\n";
            return 0;
        }
        else
        {
            std::cerr << "unknown argument '" << arg << "' (try --help)\n";
            return 2;
        }
    }

    // The --write-* / --list-tools paths build the tool table WITHOUT touching
    // the database (handlers only run through serving).
    Db db;
    db.configure( Db::ConnectConfig{
        envOr( "SQLITE_DB_PATH", "" ),
        envOr( "FRACTALSQL_EXTENSION_PATH", "" ),
        envOr( "FRACTALSQL_BOOTSTRAP_SQL", "" ),
        // FSQL_MCP_AGENT_PARTIAL: 'on' (default) opts each
        // session into the engine's partial-result honesty mode. A
        // reasoning-endpoint failure inside an agent's scalar call
        // returns the computed data half plus "reasoning_step_failed"
        // instead of raising. Anything else (e.g. 'off') keeps the
        // engine's documented raise behavior.
        []( const std::string& v ) { return v.empty() || v == "on" || v == "true" || v == "1"; }(
            envOr( "FSQL_MCP_AGENT_PARTIAL", "on" ) ),
    } );

    const bool serving = !writeLock && !writeSafetyLock && !writeManifest && !listTools;
    db.selectSession( "stdio" );   // default; the HTTP transport re-selects per session

    if( serving )
    {
        if( envOr( "SQLITE_DB_PATH", "" ).empty() )
        {
            std::cerr << "SQLITE_DB_PATH is required (a database file path or ':memory:')\n";
            return 2;
        }
        if( envOr( "FRACTALSQL_EXTENSION_PATH", "" ).empty() )
        {
            std::cerr << "FRACTALSQL_EXTENSION_PATH is required (the fractalsql .so/.dylib/.dll to load)\n";
            return 2;
        }
    }

    sharedRowLimitConfig().maxRowsCeiling =
        envIntOr( "FSQL_MCP_MAX_ROWS_CEILING", 1000 );   // set BEFORE the handlers capture it

    std::vector<ToolSpec> tools = buildAllTools( db );
    // 15.1: env vars feed the same filters the flags set (flags win).
    if( toolWhitelist.empty() ) toolWhitelist = splitCsv( envOr( "FSQL_MCP_TOOL_WHITELIST", "" ) );
    if( enabledCategories.empty() ) enabledCategories = splitCsv( envOr( "FSQL_MCP_ENABLED_CATEGORIES", "" ) );
    tools = filterTools( std::move( tools ), enabledCategories, toolWhitelist );

    if( lockPath.empty() ) lockPath = findRepoLockPath( ".mcp-schema-lock" );
    if( safetyLockPath.empty() ) safetyLockPath = findRepoLockPath( ".mcp-safety-annotations-lock" );

    const std::string hash = computeSchemaHash( tools );
    if( writeLock ) { writeSchemaLock( lockPath, hash ); std::cout << hash << "\n"; return 0; }

    if( writeSafetyLock )
    {
        writeSafetyAnnotations( safetyLockPath, renderSafetyAnnotations( tools ) );
        std::cout << safetyLockPath << " written\n";
        return 0;
    }

    if( writeManifest )
    {
        Json tools_json = Json::array();
        for( const ToolSpec& t : tools )
            tools_json.push_back( Json{ { "name", std::string( t.name ) },
                                        { "description", std::string( t.description ) } } );
        Json manifest{
            { "name", kMcpPluginName }, { "version", kMcpPluginVersion },
            { "server", { { "type", "binary" }, { "entry_point", kMcpPluginName } } },
            { "tools", tools_json }
        };
        // 15.5: manifests default into mcp/ like the lock files.
        const std::string manifestPath = envOr( "FSQL_MCP_MANIFEST_PATH", findRepoLockPath( "manifest.json" ) );
        std::ofstream( manifestPath ) << manifest.dump( 2 ) << "\n";
        std::cout << manifestPath << " written (" << tools.size() << " tools)\n";
        return 0;
    }

    if( listTools )
    {
        for( const ToolSpec& t : tools )
            std::cout << t.name << "\n";
        return 0;
    }

    // 15.3: safety-annotation check is a HARD mismatch (exit 3), regardless of
    // FSQL_MCP_STRICT_SCHEMA_HASH.
    {
        std::string diffOut;
        if( !checkSafetyAnnotations( safetyLockPath, renderSafetyAnnotations( tools ), &diffOut ) )
        {
            std::cerr << "safety-annotation regression: the registered safety hints differ from "
                      << safetyLockPath << "\n--- lock file contents ---\n" << diffOut;
            return 3;
        }
    }

    // 10.5: schema-lock check, warn by default, hard-fail (exit 2) when strict.
    {
        std::string expected;
        const LockCheckResult lockResult = checkSchemaLock( lockPath, hash, &expected );
        std::string filtered = ( tools.size() == 81 ) ? std::string() : " (filtered surface)";
        if( lockResult == LockCheckResult::Warn )
        {
            std::cerr << "schema hash mismatch: expected " << expected << " got " << hash << " ("
                      << tools.size() << " tools" << filtered << "); regenerate via "
                      "fractalsql-sqlite-mcp --write-schema-lock\n";
            if( envBool( "FSQL_MCP_STRICT_SCHEMA_HASH", false ) ) return 2;
        }
        else if( lockResult == LockCheckResult::Ok )
            logging::event( "schema_lock_ok", Json{ { "hash", hash } } );
    }

    logging::init( { envOr( "FSQL_MCP_LOG_LEVEL", "info" ) == "verbose" ||
                             envOr( "FSQL_MCP_LOG_LEVEL", "info" ) == "debug"
                         ? logging::Level::Debug : logging::Level::Info } );

    ConcurrencyConfig concCfg;
    concCfg.cheapLimit         = envIntOr( "FSQL_MCP_MAX_CONCURRENT_CHEAP", 50 );
    concCfg.expensiveLimit     = envIntOr( "FSQL_MCP_MAX_CONCURRENT_EXPENSIVE", 5 );
    concCfg.expensivePerClient = envIntOr( "FSQL_MCP_MAX_CONCURRENT_EXPENSIVE_PER_CLIENT", 2 );
    concCfg.maxQueueWaitMs     = envIntOr( "FSQL_MCP_MAX_QUEUE_WAIT_MS", 900'000 );

    ServerConfig serverCfg;
    serverCfg.serverName    = kMcpPluginName;
    serverCfg.serverVersion = kMcpPluginVersion;
    serverCfg.rowLimits = sharedRowLimitConfig();   // the same object the handlers captured
    serverCfg.readOnlyMode  = envBool( "FSQL_MCP_READ_ONLY", false );   // 15.4

    JsonRpcServer server( serverCfg, std::move( tools ), concCfg );
    server.interruptHook = [ &db ]( const std::string& clientKey ) { db.interrupt( clientKey ); };

    if( httpMode )
    {
        HttpConfig httpCfg;
        httpCfg.host = httpHost;
        httpCfg.port = httpPort;
        httpCfg.path = httpPath;
        httpCfg.authToken     = envOr( "FSQL_MCP_AUTH_TOKEN", "" );
        httpCfg.authTokenFile = envOr( "FSQL_MCP_AUTH_TOKEN_FILE", "" );
        httpCfg.shutdownDrainMs = envIntOr( "FSQL_MCP_SHUTDOWN_DRAIN_MS", 5000 );
        httpCfg.tlsEnabled  = httpsMode || envBool( "FSQL_MCP_HTTPS", false );
        httpCfg.tlsCertFile = tlsCertFile;
        httpCfg.tlsKeyFile  = tlsKeyFile;
        if( httpCfg.authToken.empty() && httpCfg.authTokenFile.empty() )
        {
            std::cerr << "the HTTP transport requires FSQL_MCP_AUTH_TOKEN or "
                         "FSQL_MCP_AUTH_TOKEN_FILE\n";
            return 2;
        }
        if( httpCfg.tlsEnabled && ( httpCfg.tlsCertFile.empty() || httpCfg.tlsKeyFile.empty() ) )
        {
            std::cerr << "--https requires a TLS cert and key: pass --tls-cert/--tls-key or set "
                         "FSQL_MCP_TLS_CERT_FILE/FSQL_MCP_TLS_KEY_FILE\n";
            return 2;
        }
        return runHttpTransport( server, httpCfg, [ &db ] { return db.probeAlive(); },
                                 [ &db ]( const std::string& key ) { db.closeSession( key ); } );
    }

    StdioConfig stdioCfg;
    stdioCfg.shutdownDrainMs = envIntOr( "FSQL_MCP_SHUTDOWN_DRAIN_MS", 5000 );
    return runStdioTransport( server, stdioCfg );
}