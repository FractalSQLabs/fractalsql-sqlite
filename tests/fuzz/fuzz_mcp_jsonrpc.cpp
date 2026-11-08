// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
//
// libFuzzer entry point for the MCP server's JSON-RPC front door:
// JsonRpcServer::handleLine, the function both transports hand every
// client line to. The server is built once with two stub tools (one cheap,
// one expensive) so initialize, tools/list, tools/call argument validation,
// resources, prompts and cancellation are all reachable without a database.
//
// The input is one raw protocol line. Any reply, including an error
// response, is fine; a crash, hang or sanitizer report is the finding.
//
// Built and run by build_test.sh's MCP fuzz gate.
#include "jsonrpc_server.h"

#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <stdexcept>
#include <string>
#include <vector>

using namespace fsqlmcp;

static JsonRpcServer& server()
{
    static JsonRpcServer* s = []
    {
        // Keep stderr quiet: the server logs every call. FSQL_FUZZ_LAST turns
        // on debug logging so a handler exception shows its text.
        logging::init( { std::getenv( "FSQL_FUZZ_LAST" ) ? logging::Level::Debug : logging::Level::Info } );
        std::vector<ToolSpec> tools;
        ToolSpec cheap;
        cheap.name = "fuzz_cheap";
        cheap.category = "fuzz";
        cheap.toolClass = ToolClass::Cheap;
        cheap.params = {
            { "text", JsonType::String, true, nullptr, "a string" },
            { "n", JsonType::Integer, false, 3, "an integer" },
            { "v", JsonType::Array, false, nullptr, "an array" },
        };
        cheap.readOnlyHint = true;
        cheap.destructiveHint = false;
        cheap.description = "fuzz stub";
        cheap.handler = []( const Json& args, CallCtx& ) { return Json{ { "echo", args } }; };
        tools.push_back( cheap );
        ToolSpec costly = cheap;
        costly.name = "fuzz_expensive";
        costly.toolClass = ToolClass::Expensive;
        costly.destructiveHint = true;
        costly.readOnlyHint = false;
        tools.push_back( costly );
        return new JsonRpcServer( ServerConfig{}, std::move( tools ), ConcurrencyConfig{} );
    }();
    return *s;
}

// FSQL_FUZZ_SELFTEST=<path>: before the first input, run a fixed sequence of steps,
// logging each to <path> so a crash shows which step it was. The early steps
// isolate exception handling from the server; the later ones go through it.
static void line( const char* s ) { try { ( void ) server().handleLine( s, "selftest" ); } catch( const std::exception& ) {} }

static void selfTest()
{
    const char* path = std::getenv( "FSQL_FUZZ_SELFTEST" );
    if( !path ) return;
    std::FILE* f = std::fopen( path, "w" );
    if( !f ) return;
    static const char* callCheap = R"({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"fuzz_cheap","arguments":{"text":"x","n":2}}})";
    static const char* callNone  = R"({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"no_such_tool","arguments":{}}})";
    static const char* badMethod = R"({"jsonrpc":"2.0","id":3,"method":"no/such/method"})";
    static const char* cancel3   = R"({"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":3}})";
    static const char* callBadArgs = R"({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"fuzz_cheap","arguments":5}})";
    static const char* readBad     = R"({"jsonrpc":"2.0","id":3,"method":"resources/read","params":{"uri":"fractalsql://no/such"}})";
    static const char* promptBad   = R"({"jsonrpc":"2.0","id":3,"method":"prompts/get","params":{"name":"no_such_prompt"}})";
    const struct { const char* what; void ( *run )(); } steps[] = {
        { "throw and catch a std::runtime_error, short text",
          [] { try { throw std::runtime_error( "x" ); } catch( const std::exception& ) {} } },
        { "throw and catch a std::runtime_error, long text",
          [] { try { throw std::runtime_error( std::string( 150, 'z' ) ); } catch( const std::exception& ) {} } },
        { "build and destroy a ToolError, long text, no throw",
          [] { ToolError e( ErrorClass::Schema, std::string( 150, 'z' ) ); ( void ) e; } },
        { "throw a ToolError, short text, catch as std::exception",
          [] { try { throw ToolError( ErrorClass::Schema, "x" ); } catch( const std::exception& ) {} } },
        { "throw a ToolError, long text, catch as std::exception",
          [] { try { throw ToolError( ErrorClass::Schema, std::string( 150, 'z' ) ); } catch( const std::exception& ) {} } },
        { "throw a ToolError, long text, catch as ToolError",
          [] { try { throw ToolError( ErrorClass::Schema, std::string( 150, 'z' ) ); } catch( const ToolError& ) {} } },
        { "throw a struct holding a long std::string",
          [] { struct S { std::string s; }; try { throw S{ std::string( 150, 'z' ) }; } catch( const S& ) {} } },
        { "build and dump an error-shaped JSON",
          [] { Json id = 3; ( void ) Json{ { "jsonrpc", "2.0" }, { "id", id }, { "error", { { "code", -32602 }, { "message", "m" } } } }.dump(); } },
        { "server: unknown method (error reply, no throw)", [] { line( badMethod ); } },
        { "server: call fuzz_cheap, nothing cancelled",     [] { line( callCheap ); } },
        { "server: call unknown tool, nothing cancelled",   [] { line( callNone ); } },
        { "server: cancel request 3",                       [] { line( cancel3 ); } },
        { "server: call unknown tool after the cancel",     [] { line( callNone ); } },
        { "server: call fuzz_cheap after the cancel",       [] { line( callCheap ); } },
        { "server: call fuzz_cheap again",                  [] { line( callCheap ); } },
        { "throw a ToolError through live Json temporaries, local code",
          [] {
              try
              {
                  auto boom = []() -> Json { throw ToolError( ErrorClass::Schema, std::string( 150, 'z' ) ); };
                  ( void ) Json{ { "r", boom() }, { "p", Json::object() } }.dump();
              }
              catch( const ToolError& ) {}
          } },
        { "server: tools/call with non-object arguments",   [] { line( callBadArgs ); } },
        { "server: resources/read of an unknown uri",       [] { line( readBad ); } },
        { "server: prompts/get of an unknown prompt",       [] { line( promptBad ); } },
        { "catch ToolError, read errorClass",
          [] { try { throw ToolError( ErrorClass::Schema, std::string( 150, 'z' ) ); } catch( const ToolError& e ) { volatile int c = static_cast<int>( e.errorClass ); ( void ) c; } } },
        { "catch ToolError, read message.size()",
          [] { try { throw ToolError( ErrorClass::Schema, std::string( 150, 'z' ) ); } catch( const ToolError& e ) { volatile size_t n = e.message.size(); ( void ) n; } } },
        { "catch ToolError, read message[0]",
          [] { try { throw ToolError( ErrorClass::Schema, std::string( 150, 'z' ) ); } catch( const ToolError& e ) { volatile char c = e.message[ 0 ]; ( void ) c; } } },
        { "catch ToolError, copy message into a local",
          [] { try { throw ToolError( ErrorClass::Schema, std::string( 150, 'z' ) ); } catch( const ToolError& e ) { std::string m = e.message; ( void ) m; } } },
        { "catch ToolError, copy what() into a local",
          [] { try { throw ToolError( ErrorClass::Schema, std::string( 150, 'z' ) ); } catch( const ToolError& e ) { std::string m = e.what(); ( void ) m; } } },
        { "catch runtime_error, copy what() into a local",
          [] { try { throw std::runtime_error( std::string( 150, 'z' ) ); } catch( const std::runtime_error& e ) { std::string m = e.what(); ( void ) m; } } },
        { "return an int out of a catch block",
          [] { auto f = []() -> int { try { throw ToolError( ErrorClass::Schema, std::string( 150, 'z' ) ); } catch( const ToolError& ) { return 7; } }; ( void ) f(); } },
        { "return a fresh std::string out of a catch block",
          [] { auto f = []() -> std::string { try { throw ToolError( ErrorClass::Schema, std::string( 150, 'z' ) ); } catch( const ToolError& ) { return std::string( 150, 'y' ); } }; ( void ) f(); } },
        { "return a std::string copy of e.message out of a catch block",
          [] { auto f = []() -> std::string { try { throw ToolError( ErrorClass::Schema, std::string( 150, 'z' ) ); } catch( const ToolError& e ) { return e.message; } }; ( void ) f(); } },
        { "copy e.message to a local, return it after the catch",
          [] { auto f = []() -> std::string { std::string m; try { throw ToolError( ErrorClass::Schema, std::string( 150, 'z' ) ); } catch( const ToolError& e ) { m = e.message; } return m; }; ( void ) f(); } },
    };
    // FSQL_FUZZ_SELFTEST_ONLY=<n>: run just step n (1-based), so the caller can
    // run every step in its own process and see which ones crash.
    const char* only = std::getenv( "FSQL_FUZZ_SELFTEST_ONLY" );
    const int want = only ? std::atoi( only ) : 0;
    int n = 0;
    for( const auto& st : steps )
    {
        if( want && n + 1 != want ) { ++n; continue; }
        std::fprintf( f, "step %d begin: %s\n", ++n, st.what );
        std::fflush( f );
        st.run();
        std::fprintf( f, "step %d done\n", n );
        std::fflush( f );
    }
    std::fprintf( f, "selftest complete (%d steps)\n", n );
    std::fclose( f );
}

extern "C" int LLVMFuzzerTestOneInput( const uint8_t* data, size_t size )
{
    static const bool selfTested = ( selfTest(), true );
    ( void ) selfTested;
    // FSQL_FUZZ_LAST=<path>: keep the input being run, so a crash leaves it behind.
    if( const char* last = std::getenv( "FSQL_FUZZ_LAST" ) )
        if( std::FILE* f = std::fopen( last, "wb" ) )
        {
            std::fwrite( data, 1, size, f );
            std::fclose( f );
        }
    // FSQL_FUZZ_TRACE=<path>: append every input, hex, one per line, in run order.
    if( const char* trace = std::getenv( "FSQL_FUZZ_TRACE" ) )
    {
        static std::FILE* tf = std::fopen( trace, "ab" );
        if( tf )
        {
            for( size_t i = 0; i < size; ++i )
                std::fprintf( tf, "%02x", static_cast<unsigned>( data[ i ] ) );
            std::fputc( '\n', tf );
            std::fflush( tf );
        }
    }
    const std::string line( reinterpret_cast<const char*>( data ), size );
    try
    {
        ( void ) server().handleLine( line, "fuzz" );
    }
    catch( const std::exception& ) {}
    return 0;
}

// FSQL_FUZZ_STANDALONE: a driver with no libFuzzer, for Windows. libFuzzer's runtime breaks
// C++ exception objects in clang's Windows build (a caught std::runtime_error reads back a bad
// what()), so this target is built as a plain executable instead. It replays every input from the
// corpus directories and files given, then, for -max_total_time=N (or -runs=N), mutates corpus
// entries at random. Not coverage-guided; the Linux build keeps the real libFuzzer run. Other
// libFuzzer-style flags are accepted and ignored so the caller's command line is the same.
#ifdef FSQL_FUZZ_STANDALONE
#include <chrono>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <random>

namespace
{
    using Bytes = std::vector<uint8_t>;

    Bytes slurp( const std::filesystem::path& p )
    {
        std::ifstream f( p, std::ios::binary );
        return Bytes( std::istreambuf_iterator<char>( f ), std::istreambuf_iterator<char>() );
    }

    void run( const Bytes& d )
    {
        static const uint8_t none = 0;
        LLVMFuzzerTestOneInput( d.empty() ? &none : d.data(), d.size() );
    }

    void mutate( Bytes& d, const std::vector<Bytes>& corpus, std::mt19937_64& rng )
    {
        auto r = [ & ]( size_t n ) { return n ? static_cast<size_t>( rng() % n ) : size_t( 0 ); };
        static const char* const tokens[] = { "0", "-1", "2147483647", "9223372036854775807", "null",
                                              "[]", "{}", "\"\"", "1e999", "true" };
        for( size_t rounds = 1 + r( 4 ); rounds; --rounds )
        {
            switch( r( 7 ) )
            {
                case 0: if( !d.empty() ) d[ r( d.size() ) ] ^= static_cast<uint8_t>( 1u << r( 8 ) ); break;
                case 1: if( !d.empty() ) d[ r( d.size() ) ] = static_cast<uint8_t>( rng() ); break;
                case 2: d.insert( d.begin() + r( d.size() + 1 ), static_cast<uint8_t>( rng() ) ); break;
                case 3: if( !d.empty() ) d.erase( d.begin() + r( d.size() ) ); break;
                case 4:
                    if( !corpus.empty() )
                    {
                        const Bytes& o = corpus[ r( corpus.size() ) ];
                        if( !o.empty() )
                        {
                            const size_t from = r( o.size() ), n = 1 + r( o.size() - from );
                            d.insert( d.begin() + r( d.size() + 1 ), o.begin() + from, o.begin() + from + n );
                        }
                    }
                    break;
                case 5:
                {
                    const char* t = tokens[ r( 10 ) ];
                    d.insert( d.begin() + r( d.size() + 1 ), t, t + std::strlen( t ) );
                    break;
                }
                default: if( d.size() > 1 ) std::swap( d[ r( d.size() ) ], d[ r( d.size() ) ] ); break;
            }
        }
        if( d.size() > 4096 ) d.resize( 4096 );
    }
}

int main( int argc, char** argv )
{
    namespace fs = std::filesystem;
    double maxTime = 0;
    long runs = -1;
    std::vector<Bytes> corpus;
    for( int i = 1; i < argc; ++i )
    {
        const std::string a = argv[ i ];
        if( a.rfind( "-max_total_time=", 0 ) == 0 ) { maxTime = std::atof( a.c_str() + 16 ); continue; }
        if( a.rfind( "-runs=", 0 ) == 0 )           { runs = std::atol( a.c_str() + 6 ); continue; }
        if( !a.empty() && a[ 0 ] == '-' ) continue;
        std::error_code ec;
        if( fs::is_directory( a, ec ) )
        {
            for( const auto& e : fs::directory_iterator( a, ec ) )
                if( e.is_regular_file() ) corpus.push_back( slurp( e.path() ) );
        }
        else if( fs::is_regular_file( a, ec ) )
            corpus.push_back( slurp( a ) );
    }

    run( Bytes() );                                  // first call also runs the FSQL_FUZZ_SELFTEST steps
    if( runs == 0 ) return 0;
    for( const Bytes& d : corpus ) run( d );
    unsigned long executed = corpus.size() + 1;

    if( maxTime > 0 || runs > 0 )
    {
        const auto seed = std::random_device{}();
        std::fprintf( stderr, "standalone mutator: seed %u, %zu corpus inputs\n", seed, corpus.size() );
        std::mt19937_64 rng( seed );
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::duration<double>( maxTime );
        for( long n = 0; ( runs < 0 || n < runs ) && ( maxTime <= 0 || std::chrono::steady_clock::now() < deadline ); ++n )
        {
            Bytes d = corpus.empty() ? Bytes() : corpus[ rng() % corpus.size() ];
            mutate( d, corpus, rng );
            run( d );
            ++executed;
        }
    }
    std::fprintf( stderr, "standalone mutator: %lu inputs run, no crash\n", executed );
    return 0;
}
#endif
