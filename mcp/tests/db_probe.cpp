// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
//
// Standalone unit test for mcp/src/db.h's DbConnection/classifySqliteError/
// splitSqlStatements. These are reachable through a live tools/call only
// indirectly and unreliably (a prepare/bind/step failure needs a
// deliberately-broken SQL string or schema state no adapter ever produces
// on its own; a version-skew warning needs the engine to report a
// DIFFERENT version than the plugin expects, which the real extension
// never does on its own), so this drives DbConnection's public API
// directly instead -- the same class the live server uses, just invoked
// with inputs a real tool call never constructs. Takes the already-built
// fractalsql.so's path as argv[1]; the extension-dependent checks (bind/
// step/version-skew/bootstrap) are skipped, not failed, if it's absent.
#include "db.h"

#include <cstdio>
#include <cstring>

using namespace fsqlmcp;

static int failed = 0;

static void check( const char* label, bool cond )
{
    std::printf( "%s %s\n", cond ? "OK:" : "FAIL:", label );
    if( !cond ) failed = 1;
}

static bool threwClass( const std::function<void()>& fn, ErrorClass want )
{
    try { fn(); }
    catch( const ToolError& e ) { return e.errorClass == want; }
    catch( ... ) { return false; }
    return false;
}

int main( int argc, char** argv )
{
    const std::string extPath = argc > 1 ? argv[ 1 ] : "";

    // splitSqlStatements: pure, static, no connection needed.
    {
        auto r = DbConnection::splitSqlStatements(
            "SELECT 1; -- a trailing comment\nSELECT 2;" );
        check( "splitSqlStatements: a -- comment is skipped, not split as SQL",
               r.size() == 2 && r[ 0 ] == "SELECT 1" && r[ 1 ].find( "SELECT 2" ) != std::string::npos );

        r = DbConnection::splitSqlStatements( ".load ./foo.so\nSELECT 1;" );
        check( "splitSqlStatements: a leading .load line is skipped, its "
               "statement kept",
               r.size() == 1 && r[ 0 ].find( "SELECT 1" ) != std::string::npos );

        r = DbConnection::splitSqlStatements( ".load ./foo.so\n.mode list\n" );
        check( "splitSqlStatements: dot-lines-only chunk (no trailing "
               "statement) contributes nothing", r.empty() );

        r = DbConnection::splitSqlStatements( ".load ./foo.so" );
        check( "splitSqlStatements: an unterminated dot line (no newline) "
               "contributes nothing", r.empty() );

        r = DbConnection::splitSqlStatements( "SELECT 'a;b' AS x;" );
        check( "splitSqlStatements: a semicolon inside a quoted string is "
               "not a statement break",
               r.size() == 1 && r[ 0 ].find( "a;b" ) != std::string::npos );
    }

    // ensureOpen: an unconnected DbConnection.
    {
        DbConnection conn;
        check( "callScalar on an unconnected DbConnection throws Connectivity",
               threwClass( [ &conn ] { conn.callScalar( "SELECT 1", {} ); },
                           ErrorClass::Connectivity ) );
    }

    // openDatabase failure: a path sqlite3_open cannot create/open.
    {
        DbConnection conn;
        check( "connect(): an unopenable DB path throws Connectivity",
               threwClass( [ &conn, &extPath ] {
                   conn.connect( "/nonexistent_dir_xyz_abc/db.sqlite", extPath, "", "2.0.8" );
               }, ErrorClass::Connectivity ) );
    }

    // loadExtensionLockedDown failure: a bad extension path (in-memory DB
    // opens fine either way, so this isolates the extension-load step).
    {
        DbConnection conn;
        check( "connect(): a nonexistent extension path throws Connectivity",
               threwClass( [ &conn ] {
                   conn.connect( ":memory:", "/nonexistent_xyz.so", "", "2.0.8" );
               }, ErrorClass::Connectivity ) );
    }

    if( extPath.empty() )
    {
        check( "(no fractalsql.so path given -- extension-dependent checks "
               "skipped, not failed)", true );
        return failed;
    }

    // runBootstrap/exec failure: malformed bootstrap SQL makes connect()
    // itself throw (unlike applyAgentPartialReasoningFail's own call,
    // runBootstrap's exec() is not wrapped in a try/catch).
    {
        DbConnection conn;
        check( "connect(): malformed bootstrap SQL propagates as a thrown "
               "ToolError",
               threwClass( [ &conn, &extPath ] {
                   conn.connect( ":memory:", extPath, "THIS IS NOT VALID SQL;", "2.0.8" );
               }, ErrorClass::Connectivity ) );
    }

    // checkVersionSkew: deliberately wrong expected version. connect()
    // must still succeed (warn, not fail) and record the warning.
    {
        DbConnection conn;
        bool threw = false;
        try { conn.connect( ":memory:", extPath, "", "9.9.9-does-not-exist" ); }
        catch( ... ) { threw = true; }
        bool warned = false;
        for( const auto& w : conn.startupWarnings() )
            if( w.find( "version skew" ) != std::string::npos ) warned = true;
        check( "connect(): a mismatched expected engine version warns, "
               "doesn't throw, and still serves",
               !threw && warned );
    }

    // prepare failure: malformed SQL via all three query paths.
    {
        DbConnection conn;
        conn.connect( ":memory:", extPath, "", "2.0.8" );
        check( "callScalar: malformed SQL throws an Engine-class error",
               threwClass( [ &conn ] { conn.callScalar( "SELEKT GARBAGE", {} ); },
                           ErrorClass::Engine ) );
        check( "queryAll: malformed SQL throws an Engine-class error",
               threwClass( [ &conn ] { conn.queryAll( "SELEKT GARBAGE", {} ); },
                           ErrorClass::Engine ) );
        check( "columnNames: malformed SQL throws an Engine-class error",
               threwClass( [ &conn ] { conn.columnNames( "SELEKT GARBAGE" ); },
                           ErrorClass::Engine ) );
    }

    // bind failure: a bind supplied for a statement with zero parameters
    // of its own (sqlite3_bind_* then reports SQLITE_RANGE).
    {
        DbConnection conn;
        conn.connect( ":memory:", extPath, "", "2.0.8" );
        check( "callScalar: a bind beyond the statement's own parameter "
               "count throws ServerInternal",
               threwClass( [ &conn ] {
                   conn.callScalar( "SELECT 1", { SqlValue( std::int64_t( 5 ) ) } );
               }, ErrorClass::ServerInternal ) );
        check( "queryAll: a bind beyond the statement's own parameter "
               "count throws ServerInternal",
               threwClass( [ &conn ] {
                   conn.queryAll( "SELECT 1", { SqlValue( std::int64_t( 5 ) ) } );
               }, ErrorClass::ServerInternal ) );
    }

    // step failure: a real UNIQUE constraint violation (not a prepare-time
    // error -- the statement is well-formed, the ROW it tries to write
    // isn't).
    {
        DbConnection conn;
        conn.connect( ":memory:", extPath, "", "2.0.8" );
        conn.callScalar( "CREATE TABLE _db_probe_uniq(x INTEGER UNIQUE)", {} );
        conn.callScalar( "INSERT INTO _db_probe_uniq VALUES(1)", {} );
        check( "callScalar: a step failure (UNIQUE violation) throws an "
               "Engine-class error",
               threwClass( [ &conn ] {
                   conn.callScalar( "INSERT INTO _db_probe_uniq VALUES(1)", {} );
               }, ErrorClass::Engine ) );
        check( "queryAll: a step failure (UNIQUE violation) throws an "
               "Engine-class error",
               threwClass( [ &conn ] {
                   conn.queryAll( "INSERT INTO _db_probe_uniq VALUES(1)", {} );
               }, ErrorClass::Engine ) );
    }

    // classifySqliteError: the two message-sniffed classifications,
    // tested directly (pure, static) rather than trying to engineer a
    // real interrupted/locked connection.
    {
        check( "classifySqliteError: an \"interrupted\" message classifies "
               "as Cancelled",
               DbConnection::classifySqliteError( 9 /*SQLITE_INTERRUPT*/,
                   "interrupted" ).errorClass == ErrorClass::Cancelled );
        check( "classifySqliteError: a \"database is locked\" message "
               "classifies as Connectivity",
               DbConnection::classifySqliteError( 5 /*SQLITE_BUSY*/,
                   "database is locked" ).errorClass == ErrorClass::Connectivity );
        check( "classifySqliteError: an ordinary engine error classifies "
               "as Engine",
               DbConnection::classifySqliteError( 1 /*SQLITE_ERROR*/,
                   "no such table: t" ).errorClass == ErrorClass::Engine );
    }

    return failed;
}
