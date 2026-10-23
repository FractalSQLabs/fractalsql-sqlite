// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
// fractalsql-sqlite-mcp's connection layer: sqlite3 directly, the
// extension loaded in-process via sqlite3_load_extension in a strict
// load-then-lock-down sequence, one dedicated connection per session
// (over stdio exactly one session, "stdio"), all execution under the
// connection's own mutex (no pipelining within a session).
#pragma once
#include <string>
#include <vector>
#include <variant>
#include <memory>
#include <map>
#include <mutex>
#include <optional>
#include <sqlite3.h>
#include "mcp_json.h"
#include "errors.h"
#include "logging.h"

namespace fsqlmcp
{
    // The plugin's own version, and the engine surface version it was
    // built and tested against (version numbers track the engine).
    static const char* const kMcpPluginName       = "fractalsql-sqlite-mcp";
    static const char* const kMcpPluginVersion    = "2.0.10";
    static const char* const kEngineVersionExpect = "2.0.10";

    using SqlValue = std::variant<std::nullptr_t, std::int64_t, double, std::string,
                                  std::vector<std::uint8_t>>;

    // Result-shape helpers specific to this engine's TEXT-JSON convention.
    inline std::optional<std::string> asText( const SqlValue& v )
    {
        return std::holds_alternative<std::string>( v )
            ? std::optional<std::string>( std::get<std::string>( v ) ) : std::nullopt;
    }

    inline std::optional<std::vector<std::uint8_t>> asBlob( const SqlValue& v )
    {
        return std::holds_alternative<std::vector<std::uint8_t>>( v )
            ? std::optional<std::vector<std::uint8_t>>( std::get<std::vector<std::uint8_t>>( v ) )
            : std::nullopt;
    }

    inline Json asScalarJson( const SqlValue& v )
    {
        return std::visit( []( auto&& x ) -> Json
        {
            using T = std::decay_t<decltype( x )>;
            if constexpr( std::is_same_v<T, std::nullptr_t> ) return nullptr;
            else if constexpr( std::is_same_v<T, std::int64_t> ) return x;
            else if constexpr( std::is_same_v<T, double> ) return x;
            else if constexpr( std::is_same_v<T, std::string> ) return x;
            else return nullptr;
        }, v );
    }

    // parse_json_text (lenient): NULL -> {"ok":true}; non-JSON text -> {"text":text}.
    inline Json parseJsonLenient( const SqlValue& v )
    {
        const auto t = asText( v );
        if( !t ) return Json{ { "ok", true } };
        try { return Json::parse( *t ); } catch( ... ) { return Json{ { "text", *t } }; }
    }

    // parse_json_text_strict: NULL or non-JSON text is a real engine-layer bug.
    inline Json parseJsonStrict( const SqlValue& v )
    {
        const auto t = asText( v );
        if( !t )
            throw ToolError( ErrorClass::ServerInternal, "expected a JSON document, engine returned NULL" );
        try { return Json::parse( *t ); }
        catch( ... )
        {
            throw ToolError( ErrorClass::ServerInternal,
                "engine returned non-JSON text where a JSON document was documented" );
        }
    }

    // One dedicated connection (sqlite3*) with its own execution mutex. All
    // calls are single scalar `SELECT fn(...)`; SQLite has no stored-procedure
    // OUT-var convention and no set-returning scalar function.
    class DbConnection
    {
    public:
        DbConnection() = default;
        DbConnection( const DbConnection& ) = delete;
        DbConnection& operator=( const DbConnection& ) = delete;
        ~DbConnection() { close(); }

        void connect( const std::string& dbPath, const std::string& extensionPath,
                      const std::string& bootstrapSql, const std::string& engineVersionExpected,
                      bool agentPartialReasoningFail = true )
        {
            openDatabase( dbPath );
            // Every engine call binds parameters. The only statements
            // executed unbound are the fixed PRAGMA and the bootstrap snippet
            // (an operator-supplied file/env, not caller input).
            exec( "PRAGMA busy_timeout=30000;" );
            loadExtensionLockedDown( extensionPath );
            runBootstrap( bootstrapSql );
            if( agentPartialReasoningFail ) applyAgentPartialReasoningFail();
            checkVersionSkew( engineVersionExpected );
        }

        void close() noexcept
        {
            std::lock_guard<std::mutex> lk( mu_ );
            if( db_ ) { sqlite3_close( db_ ); db_ = nullptr; }
        }

        SqlValue callScalar( const std::string& sql, const std::vector<SqlValue>& binds )
        {
            std::lock_guard<std::mutex> lk( mu_ );   // one session, one connection, serialized
            ensureOpen();
            sqlite3_stmt* stmt = nullptr;
            if( sqlite3_prepare_v2( db_, sql.c_str(), -1, &stmt, nullptr ) != SQLITE_OK )
            {
                const std::string msg = sqlite3_errmsg( db_ );
                throw classifySqliteError( SQLITE_ERROR, msg );
            }
            for( std::size_t i = 0; i < binds.size(); ++i )
            {
                if( bindOne( stmt, static_cast<int>( i + 1 ), binds[ i ] ) != SQLITE_OK )
                {
                    const std::string msg = sqlite3_errmsg( db_ );
                    sqlite3_finalize( stmt );
                    throw ToolError( ErrorClass::ServerInternal, "engine parameter bind failed: " + sanitizeSecrets( msg ) );
                }
            }

            const int rc = sqlite3_step( stmt );
            if( rc != SQLITE_ROW && rc != SQLITE_DONE )
            {
                const std::string msg = sqlite3_errmsg( db_ );
                sqlite3_finalize( stmt );
                throw classifySqliteError( rc, msg );
            }
            SqlValue out = nullptr;
            if( rc == SQLITE_ROW )
                out = extractColumn( stmt, 0 );
            sqlite3_finalize( stmt );
            return out;
        }

        // SELECT * FROM <view/table> decoder for the resources layer.
        std::vector<std::vector<SqlValue>> queryAll( const std::string& sql,
                                                     const std::vector<SqlValue>& binds )
        {
            std::lock_guard<std::mutex> lk( mu_ );
            ensureOpen();
            sqlite3_stmt* stmt = nullptr;
            if( sqlite3_prepare_v2( db_, sql.c_str(), -1, &stmt, nullptr ) != SQLITE_OK )
            {
                const std::string msg = sqlite3_errmsg( db_ );
                throw classifySqliteError( SQLITE_ERROR, msg );
            }
            for( std::size_t i = 0; i < binds.size(); ++i )
                if( bindOne( stmt, static_cast<int>( i + 1 ), binds[ i ] ) != SQLITE_OK )
                {
                    const std::string msg = sqlite3_errmsg( db_ );
                    sqlite3_finalize( stmt );
                    throw ToolError( ErrorClass::ServerInternal, "engine parameter bind failed: " + sanitizeSecrets( msg ) );
                }
            std::vector<std::vector<SqlValue>> rows;
            for( ;; )
            {
                const int rc = sqlite3_step( stmt );
                if( rc == SQLITE_ROW )
                {
                    std::vector<SqlValue> row( static_cast<std::size_t>( sqlite3_column_count( stmt ) ) );
                    for( int c = 0; c < sqlite3_column_count( stmt ); ++c )
                        row[ static_cast<std::size_t>( c ) ] = extractColumn( stmt, c );
                    rows.push_back( std::move( row ) );
                }
                else if( rc == SQLITE_DONE ) break;
                else
                {
                    const std::string msg = sqlite3_errmsg( db_ );
                    sqlite3_finalize( stmt );
                    throw classifySqliteError( rc, msg );
                }
            }
            sqlite3_finalize( stmt );
            return rows;
        }

        std::vector<std::string> columnNames( const std::string& sql )
        {
            std::lock_guard<std::mutex> lk( mu_ );
            ensureOpen();
            sqlite3_stmt* stmt = nullptr;
            if( sqlite3_prepare_v2( db_, sql.c_str(), -1, &stmt, nullptr ) != SQLITE_OK )
            {
                const std::string msg = sqlite3_errmsg( db_ );
                throw classifySqliteError( SQLITE_ERROR, msg );
            }
            std::vector<std::string> names;
            for( int c = 0; c < sqlite3_column_count( stmt ); ++c )
                names.emplace_back( sqlite3_column_name( stmt, c ) );
            sqlite3_finalize( stmt );
            return names;
        }

        void interrupt() { if( db_ ) sqlite3_interrupt( db_ ); }   // the cancel mechanism on this engine
        bool probeAlive()
        { try { callScalar( "SELECT 1", {} ); return true; } catch( ... ) { return false; } }

        const std::vector<std::string>& startupWarnings() const { return warnings_; }

    private:
        void ensureOpen()
        {
            if( !db_ )
                throw ToolError( ErrorClass::Connectivity,
                                 "database connection is not open (closed or never connected)" );
        }

        // connect()'s phases, broken out 1:1 (same order, same behavior,
        // same exceptions) so each stays small on its own.
        void openDatabase( const std::string& dbPath )
        {
            if( sqlite3_open( dbPath.c_str(), &db_ ) != SQLITE_OK )
            {
                const std::string msg = db_ ? sqlite3_errmsg( db_ ) : "cannot open database file";
                close();
                throw ToolError( ErrorClass::Connectivity, sanitizeSecrets( msg ) );
            }
        }

        // Load-then-lock-down: enable ON only for the one expected .load
        // call, then immediately OFF again. This prevents a later
        // fractal_text_to_sql-reachable path from loading a second extension.
        void loadExtensionLockedDown( const std::string& extensionPath )
        {
            sqlite3_enable_load_extension( db_, 1 );
            char* err = nullptr;
            if( sqlite3_load_extension( db_, extensionPath.c_str(), nullptr, &err ) != SQLITE_OK )
            {
                const std::string msg = err ? err : "failed to load extension";
                sqlite3_free( err );
                sqlite3_enable_load_extension( db_, 0 );
                close();
                throw ToolError( ErrorClass::Connectivity,
                                 sanitizeSecrets( "failed to load extension '" + extensionPath + "': " + msg ) );
            }
            sqlite3_enable_load_extension( db_, 0 );
        }

        void runBootstrap( const std::string& bootstrapSql )
        {
            for( const std::string& stmt : splitSqlStatements( bootstrapSql ) )
                exec( stmt );
        }

        // Partial-result honesty: opt the connection into the engine's
        // agent_partial_reasoning_fail mode so a reasoning-endpoint failure
        // inside an agent's one scalar call comes back as the computed data
        // half plus "reasoning_step_failed" instead of raising. Off by
        // default in the engine's own SQL surface; the plugin turns it on
        // for every session (FSQL_MCP_AGENT_PARTIAL=off keeps the engine's
        // raise behavior). Never fatal: an engine build without the key
        // just keeps raising, recorded as a startup warning (same posture
        // as the version-skew guard).
        void applyAgentPartialReasoningFail()
        {
            try
            {
                exec( "SELECT fractalsql_set('agent_partial_reasoning_fail','on')" );
            }
            catch( const std::exception& e )
            {
                warnings_.push_back( std::string(
                    "agent_partial_reasoning_fail not applied: " ) + e.what() );
                logging::event( "startup_warning", Json{ { "note", warnings_.back() } } );
            }
            catch( ... )
            {
                /* non-fatal, same as the version-skew guard */
            }
        }

        // Version-skew guard: warn, never hard-fail (the strict flag
        // governs the tool-surface hash, not this).
        void checkVersionSkew( const std::string& engineVersionExpected )
        {
            try
            {
                const SqlValue v = callScalar( "SELECT fractalsql_version()", {} );
                const auto t = asText( v );
                if( t && *t != engineVersionExpected )
                {
                    warnings_.push_back( "version skew: engine reports " + *t +
                                         ", plugin built against " + engineVersionExpected );
                    logging::event( "startup_warning", Json{
                        { "note", warnings_.back() },
                        { "action", "warn-not-fail: the SQL surface is stable across the compat matrix" } } );
                }
            }
            catch( ... ) { /* non-fatal: never thrown from connect() */ }
        }

        void exec( const std::string& stmt )
        {
            char* err = nullptr;
            if( sqlite3_exec( db_, stmt.c_str(), nullptr, nullptr, &err ) != SQLITE_OK )
            {
                const std::string msg = err ? err : "statement failed";
                sqlite3_free( err );
                throw ToolError( ErrorClass::Connectivity, sanitizeSecrets( msg ) );
            }
        }

        static int bindOne( sqlite3_stmt* stmt, int idx, const SqlValue& v )
        {
            if( std::holds_alternative<std::nullptr_t>( v ) ) return sqlite3_bind_null( stmt, idx );
            if( std::holds_alternative<std::int64_t>( v ) )
                return sqlite3_bind_int64( stmt, idx, std::get<std::int64_t>( v ) );
            if( std::holds_alternative<double>( v ) )
                return sqlite3_bind_double( stmt, idx, std::get<double>( v ) );
            if( std::holds_alternative<std::string>( v ) )
            {
                const std::string& s = std::get<std::string>( v );
                return sqlite3_bind_text( stmt, idx, s.c_str(), static_cast<int>( s.size() ), SQLITE_TRANSIENT );
            }
            const auto& b = std::get<std::vector<std::uint8_t>>( v );
            return sqlite3_bind_blob( stmt, idx, b.data(), static_cast<int>( b.size() ), SQLITE_TRANSIENT );
        }

        static SqlValue extractColumn( sqlite3_stmt* stmt, int col )
        {
            switch( sqlite3_column_type( stmt, col ) )
            {
                case SQLITE_NULL:    return nullptr;
                case SQLITE_INTEGER: return static_cast<std::int64_t>( sqlite3_column_int64( stmt, col ) );
                case SQLITE_FLOAT:   return sqlite3_column_double( stmt, col );
                case SQLITE_TEXT:
                {
                    const char* p = reinterpret_cast<const char*>( sqlite3_column_text( stmt, col ) );
                    const int n = sqlite3_column_bytes( stmt, col );
                    return std::string( p, static_cast<std::size_t>( n < 0 ? 0 : n ) );
                }
                default:
                {
                    const auto* p = static_cast<const std::uint8_t*>( sqlite3_column_blob( stmt, col ) );
                    const int n = sqlite3_column_bytes( stmt, col );
                    return std::vector<std::uint8_t>( p, p + std::max( 0, n ) );
                }
            }
        }

    public:
        // Ported 4-state classification minus the Windows CPython decode-quirk
        // branch: that branch exists only because CPython's sqlite3
        // module surfaces sqlite3_errmsg in a lossy way; a C driver reads
        // clean text directly, so the garbled-message fallback state
        // deliberately does NOT exist here.
        static ToolError classifySqliteError( int rc, const std::string& msg )
        {
            if( msg.find( "interrupted" ) != std::string::npos )
                return ToolError( ErrorClass::Cancelled, "call was cancelled" );
            if( rc == SQLITE_CANTOPEN || rc == SQLITE_LOCKED ||
                msg.find( "unable to open" ) != std::string::npos || msg.find( "locked" ) != std::string::npos )
                return ToolError( ErrorClass::Connectivity, sanitizeSecrets( msg ) );
            return ToolError( ErrorClass::Engine, sanitizeSecrets( msg ) );
        }

        // Quote-aware, --comment-aware, leading-dot-command-skipping splitter,
        // ported from _split_sql_statements. Tolerates a copy-pasted
        // ".load ..." line surviving in the bootstrap snippet without erroring.
        static std::vector<std::string> splitSqlStatements( const std::string& sql )
        {
            std::vector<std::string> out;
            std::string cur;
            bool inSingle = false;
            bool inDouble = false;
            for( std::size_t i = 0; i < sql.size(); ++i )
            {
                const char c = sql[ i ];
                if( !inSingle && !inDouble && c == '-' && i + 1 < sql.size() && sql[ i + 1 ] == '-' )
                { while( i < sql.size() && sql[ i ] != '\n' ) ++i; continue; }
                if( !inDouble && c == '\'' ) inSingle = !inSingle;
                if( !inSingle && c == '"' ) inDouble = !inDouble;
                if( !inSingle && !inDouble && c == ';' ) { out.push_back( cur ); cur.clear(); continue; }
                cur.push_back( c );
            }
            if( !cur.empty() ) out.push_back( cur );
            std::vector<std::string> cleaned;
            for( std::string& s : out )
            {
                const std::size_t start = s.find_first_not_of( " \t\r\n" );
                if( start == std::string::npos ) continue;
                if( s[ start ] != '.' ) { cleaned.push_back( s.substr( start ) ); continue; }
                // Dot-command lines carry no ';', so they share a chunk with
                // whatever real statement follows; dropping the whole chunk
                // would silently lose that statement (a .load-headed
                // bootstrap snippet must still run its first fractalsql_set).
                // Walk only the leading dot LINES off the chunk instead.
                std::size_t p = start;
                while( p < s.size() && s[ p ] == '.' )
                {
                    const std::size_t nl = s.find( '\n', p );
                    if( nl == std::string::npos ) { p = std::string::npos; break; }
                    p = s.find_first_not_of( " \t\r\n", nl + 1 );
                }
                if( p == std::string::npos ) continue;      // dot-lines only
                if( s[ p ] == '.' ) continue;               // unterminated dot line
                cleaned.push_back( s.substr( p ) );
            }
            return cleaned;
        }

    private:
        sqlite3* db_ = nullptr;
        std::mutex mu_;
        std::vector<std::string> warnings_;
    };

    // Session -> dedicated connection registry. Over stdio there is exactly
    // one session ("stdio"); the HTTP transport gets one connection per
    // Mcp-Session-Id and never hands a connection to a second client while
    // the first's session lives.
    // Handler tables capture the single Db&; Db routes each call to the
    // session bound to the dispatching thread (the transports select it).
    class Db
    {
    public:
        struct ConnectConfig
        {
            std::string dbPath;          // SQLITE_DB_PATH (or ':memory:')
            std::string extensionPath;   // FRACTALSQL_EXTENSION_PATH
            std::string bootstrapSql;    // FRACTALSQL_BOOTSTRAP_SQL (easy_install.sh's snippet)
            bool        agentPartialReasoningFail = true;   // FSQL_MCP_AGENT_PARTIAL
        };

        void configure( ConnectConfig cfg ) { cfg_ = std::move( cfg ); }

        ~Db() { closeAll(); }

        static void selectSession( const std::string& key ) { t_sessionKey() = key; }

        void closeSession( const std::string& key )
        {
            std::lock_guard<std::mutex> lk( regMu_ );
            connections_.erase( key );
        }
        void closeAll()
        {
            std::lock_guard<std::mutex> lk( regMu_ );
            connections_.clear();
        }

        bool probeAlive( const std::string& key )
        {
            return withConnection( key, []( DbConnection& c ) { return c.probeAlive(); } );
        }
        void interrupt( const std::string& key )
        {
            std::lock_guard<std::mutex> lk( regMu_ );
            auto it = connections_.find( key );
            if( it != connections_.end() )
                it->second->interrupt();
        }

        std::vector<std::string> sessionKeys()
        {
            std::lock_guard<std::mutex> lk( regMu_ );
            std::vector<std::string> out;
            for( const auto& kv : connections_ ) out.push_back( kv.first );
            return out;
        }

        // The single entry the adapter tables capture. Routes to the current
        // session's dedicated connection (selected by the transport just
        // before dispatch); each call takes a shared_ptr copy under the
        // registry lock so a concurrent closeSession can never destroy a
        // connection still in use.
        SqlValue callScalar( const std::string& sql, const std::vector<SqlValue>& binds )
        { return acquire( t_sessionKey() )->callScalar( sql, binds ); }

        std::vector<std::vector<SqlValue>> queryAll( const std::string& sql,
                                                     const std::vector<SqlValue>& binds )
        { return acquire( t_sessionKey() )->queryAll( sql, binds ); }

        std::vector<std::string> columnNames( const std::string& sql )
        { return acquire( t_sessionKey() )->columnNames( sql ); }

        std::vector<std::string> startupWarnings()
        { return acquire( t_sessionKey() )->startupWarnings(); }

        bool probeAlive() { return acquire( t_sessionKey() )->probeAlive(); }

    private:
        template<typename F>
        auto withConnection( const std::string& key, F f )
        -> decltype( f( *static_cast<DbConnection*>( nullptr ) ) )
        {
            std::shared_ptr<DbConnection> c = acquire( key );
            return f( *c );
        }

        static std::string& t_sessionKey()
        {
            thread_local std::string key = "stdio";
            return key;
        }

        std::shared_ptr<DbConnection> acquire( const std::string& key )
        {
            std::lock_guard<std::mutex> lk( regMu_ );
            auto it = connections_.find( key );
            if( it == connections_.end() )
            {
                auto c = std::make_shared<DbConnection>();
                c->connect( cfg_.dbPath, cfg_.extensionPath, cfg_.bootstrapSql,
                            kEngineVersionExpect, cfg_.agentPartialReasoningFail );
                connections_[ key ] = c;
                for( const std::string& w : c->startupWarnings() )
                    logging::event( "session_startup_warning", Json{ { "session", key }, { "note", w } } );
                return c;
            }
            return it->second;
        }

        ConnectConfig cfg_;
        std::mutex regMu_;
        std::map<std::string, std::shared_ptr<DbConnection>> connections_;
    };
}