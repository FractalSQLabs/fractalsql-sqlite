// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#include "logging.h"
#include <openssl/evp.h>
#include <cstdio>
#include <chrono>
#include <algorithm>
#include <cctype>
#include <ctime>
#include <mutex>

namespace fsqlmcp::logging
{
    static Config g_cfg;
    static std::mutex g_stderrMu;

    void init( const Config& cfg ) { g_cfg = cfg; }

    bool debugVerbose() { return g_cfg.level == Level::Debug; }

    static std::string sha256_8( const std::string& s )
    {
        unsigned char digest[ EVP_MAX_MD_SIZE ];
        unsigned int  len = 0;
        EVP_MD_CTX* ctx = EVP_MD_CTX_new();
        EVP_DigestInit_ex( ctx, EVP_sha256(), nullptr );
        EVP_DigestUpdate( ctx, s.data(), s.size() );
        EVP_DigestFinal_ex( ctx, digest, &len );
        EVP_MD_CTX_free( ctx );
        static const char* const kHex = "0123456789abcdef";
        std::string out;
        for( unsigned int i = 0; i < 4 && i < len; ++i )
        {
            out.push_back( kHex[ digest[ i ] >> 4 ] );
            out.push_back( kHex[ digest[ i ] & 0xF ] );
        }
        return out;
    }

    static bool looksSecretKey( const std::string& key )
    {
        std::string lower = key;
        std::transform( lower.begin(), lower.end(), lower.begin(),
                        []( unsigned char c ) { return static_cast<char>( std::tolower( c ) ); } );
        for( const char* needle : { "token", "password", "key", "secret" } )
            if( lower.find( needle ) != std::string::npos )
                return true;
        return false;
    }

    Json redactAndCap( const Json& v, int depth )
    {
        if( v.is_object() )
        {
            if( depth >= 2 )
                return Json( "<object>" );
            Json out = Json::object();
            for( auto it = v.begin(); it != v.end(); ++it )
                out[ it.key() ] = looksSecretKey( it.key() ) ? Json( "***" )
                                                             : redactAndCap( it.value(), depth + 1 );
            return out;
        }
        if( v.is_array() )
        {
            const std::string dump = v.dump();
            return Json( "<array len=" + std::to_string( v.size() ) + " sha256_8=" + sha256_8( dump ) + ">" );
        }
        if( v.is_string() )
        {
            const std::string& s = v.get_ref<const std::string&>();
            if( s.size() > 256 )
                return Json( "<str len=" + std::to_string( s.size() ) + " sha256_8=" + sha256_8( s ) + ">" );
            return v;
        }
        return v;
    }

    static std::string nowIso()
    {
        const std::time_t t = std::time( nullptr );
        char buf[ 32 ] = {};
#if defined( _WIN32 )
        struct tm tmv;
        gmtime_s( &tmv, &t );
#else
        struct tm tmv;
        gmtime_r( &t, &tmv );
#endif
        std::strftime( buf, sizeof( buf ), "%Y-%m-%dT%H:%M:%SZ", &tmv );
        return buf;
    }

    static void emitLine( const Json& extra )
    {
        Json line{ { "ts", nowIso() } };
        for( auto it = extra.begin(); it != extra.end(); ++it )
            line[ it.key() ] = it.value();
        std::lock_guard<std::mutex> lk( g_stderrMu );
        std::fputs( line.dump().c_str(), stderr );
        std::fputc( '\n', stderr );
        std::fflush( stderr );
    }

    void toolCall( std::string_view toolName, const Json& argsRedactedCapped,
                   double latencyMs, const char* errorClassOrNull )
    {
        Json line{
            { "event", "tool_call" },
            { "tool", std::string( toolName ) },
            { "latency_ms", latencyMs }
        };
        if( errorClassOrNull )
            line[ "error_class" ] = errorClassOrNull;
        // 13.6: the verbose level is wired through to the actual call site.
        // Full redacted argument bodies appear at verbose/debug, and (same as
        // the Python reference) schema errors show args even at info level.
        if( g_cfg.level == Level::Debug ||
            ( errorClassOrNull && std::string_view( errorClassOrNull ) == "schema" ) )
            line[ "args" ] = argsRedactedCapped;
        emitLine( line );
    }

    void configChange( std::string_view key, std::string_view oldValueRedacted,
                       std::string_view newValueRedacted )
    {
        emitLine( Json{
            { "event", "config_change" }, { "key", std::string( key ) },
            { "old", std::string( oldValueRedacted ) }, { "new", std::string( newValueRedacted ) }
        } );
    }

    void exceptionDetail( std::string_view where, std::string_view sanitizedDetail )
    {
        emitLine( Json{ { "event", "exception" }, { "where", std::string( where ) },
                        { "detail", std::string( sanitizedDetail ) }, { "level", "error" } } );
    }

    void event( std::string_view name, const Json& fields )
    {
        Json line{ { "event", std::string( name ) } };
        if( fields.is_object() )
            for( auto it = fields.begin(); it != fields.end(); ++it )
                line[ it.key() ] = it.value();
        emitLine( line );
    }
}