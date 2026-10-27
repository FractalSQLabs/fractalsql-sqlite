// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#include "errors.h"
#include <cctype>
#include <cstddef>

namespace fsqlmcp
{
    namespace
    {
        // This used to be two std::regex_replace calls. std::regex matches
        // recursively (one stack frame per input character): on MSVC a long
        // message -- an engine error echoing a long identifier or SQL, say --
        // throws regex_error(error_complexity), which surfaced as a "server"
        // error out of the error path itself, and on libstdc++ the same input
        // can exhaust the stack. These are single linear passes with the same
        // matching rules, so no input length can fail.
        bool isSpace( char c ) { return std::isspace( static_cast<unsigned char>( c ) ) != 0; }
        bool isWord( char c )  { return std::isalnum( static_cast<unsigned char>( c ) ) != 0 || c == '_'; }

        char lower( char c ) { return static_cast<char>( std::tolower( static_cast<unsigned char>( c ) ) ); }

        // does s[0, end) end with `suffix`, ignoring case?
        bool endsWithNoCase( const std::string& s, std::size_t end, const char* suffix )
        {
            std::size_t n = 0;
            while( suffix[ n ] ) ++n;
            if( end < n ) return false;
            for( std::size_t i = 0; i < n; ++i )
                if( lower( s[ end - n + i ] ) != lower( suffix[ i ] ) ) return false;
            return true;
        }

        // scheme://user:PASSWORD@host -> scheme://user:***@host (username kept).
        // Rule: \w+ "://" [^:/\s@]+ ":" [^@\s]+ "@"; the password run is replaced.
        std::string maskUriCredentials( const std::string& s )
        {
            std::string out;
            out.reserve( s.size() );
            std::size_t i = 0;
            while( i < s.size() )
            {
                if( s.compare( i, 3, "://" ) == 0 && !out.empty() && isWord( out.back() ) )
                {
                    std::size_t j = i + 3;
                    const std::size_t userStart = j;
                    while( j < s.size() && s[ j ] != ':' && s[ j ] != '/' && s[ j ] != '@' && !isSpace( s[ j ] ) ) ++j;
                    if( j > userStart && j < s.size() && s[ j ] == ':' )
                    {
                        std::size_t k = j + 1;
                        const std::size_t pwStart = k;
                        while( k < s.size() && s[ k ] != '@' && !isSpace( s[ k ] ) ) ++k;
                        if( k > pwStart && k < s.size() && s[ k ] == '@' )
                        {
                            out.append( s, i, j + 1 - i );   // "://user:"
                            out += "***";
                            i = k;                            // the '@' is copied by the next iteration
                            continue;
                        }
                    }
                }
                out.push_back( s[ i++ ] );
            }
            return out;
        }

        // KEY=value / KEY = value for *PASSWORD / AUTH_TOKEN / *_KEY style keys
        // (case-insensitive): the \S+ value is replaced.
        std::string maskKeyValueCredentials( const std::string& s )
        {
            std::string out;
            out.reserve( s.size() );
            std::size_t i = 0;
            while( i < s.size() )
            {
                if( s[ i ] == '=' )
                {
                    // The key text lives in `out` (already copied), so test there.
                    std::size_t keyEnd = out.size();
                    while( keyEnd > 0 && isSpace( out[ keyEnd - 1 ] ) ) --keyEnd;
                    if( endsWithNoCase( out, keyEnd, "PASSWORD" ) || endsWithNoCase( out, keyEnd, "AUTH_TOKEN" )
                        || endsWithNoCase( out, keyEnd, "_KEY" ) )
                    {
                        std::size_t j = i + 1;
                        while( j < s.size() && isSpace( s[ j ] ) ) ++j;
                        std::size_t v = j;
                        while( v < s.size() && !isSpace( s[ v ] ) ) ++v;
                        if( v > j )
                        {
                            out.append( s, i, j - i );          // "=" and the spaces after it
                            out += "***";
                            i = v;
                            continue;
                        }
                    }
                }
                out.push_back( s[ i++ ] );
            }
            return out;
        }
    }

    std::string sanitizeSecrets( std::string_view text )
    {
        return maskKeyValueCredentials( maskUriCredentials( std::string( text ) ) );
    }
}
