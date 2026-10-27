// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
//
// sanitize_probe: differential test for fsqlmcp::sanitizeSecrets (src/errors.cpp).
//
// sanitizeSecrets used to be two std::regex_replace passes. std::regex matches
// recursively (one stack frame per input character): on MSVC a long message
// -- an engine error echoing a long identifier or SQL -- threw
// regex_error(error_complexity), surfacing as a "server" error out of the
// error path itself, and on libstdc++ the same input can exhaust the stack.
// The replacement is two linear passes with the same matching rules. This probe
// keeps the OLD regex implementation as the reference and checks, over a few
// hundred thousand generated strings, that the two agree byte for byte; then
// feeds the new one inputs far past where the regex falls over.
//
// Build (what mcp_robustness.py does):
//   c++ -std=c++17 -O1 -Isrc tests/sanitize_probe.cpp src/errors.cpp -o sanitize_probe
// Exit 0 = pass, 1 = fail. The regex reference is only ever fed SHORT inputs.

#include "errors.h"

#include <chrono>
#include <iostream>
#include <random>
#include <regex>
#include <string>

namespace reference
{
    // The pre-fix implementation, verbatim.
    std::string sanitize( std::string_view text )
    {
        std::string s( text );
        static const std::regex kUriCred( R"((\w+://[^:/\s@]+:)([^@\s]+)(@))" );
        s = std::regex_replace( s, kUriCred, "$1***$3" );
        static const std::regex kKvCred(
            R"(((?:[A-Z_]*PASSWORD|AUTH_TOKEN|[A-Z_]*_KEY)\s*=\s*)(\S+))",
            std::regex::icase );
        s = std::regex_replace( s, kKvCred, "$1***" );
        return s;
    }
}

int main()
{
    int failures = 0;

    // 1. differential over token soup that exercises every branch of both rules
    const char* toks[] = {
        "postgres", "mysql", "http", "://", "user", ":", "pw", "p@ss", "@", "host", " ", "=", "DB_PASSWORD",
        "AUTH_TOKEN", "api_key", "_KEY", "x", "password", "\t", "a", "/", "SECRET_KEY", " = ", "pass word",
        "PASSWORD=", "\n", "\xc3\xa9", "KEY", "TOKEN", "==", "=\t", "key=", "MARIADB_PASSWORD"
    };
    const int n = static_cast<int>( sizeof( toks ) / sizeof( *toks ) );
    std::mt19937 g( 20260426 );
    int diffs = 0;
    for( int i = 0; i < 300000; ++i )
    {
        std::string s;
        const int len = 1 + static_cast<int>( g() % 12 );
        for( int j = 0; j < len; ++j ) s += toks[ g() % n ];
        const std::string a = reference::sanitize( s );
        const std::string b = fsqlmcp::sanitizeSecrets( s );
        if( a != b && diffs++ < 5 )
            std::cout << "DIFF\n  in : [" << s << "]\n  old: [" << a << "]\n  new: [" << b << "]\n";
    }
    std::cout << "differential: " << diffs << " mismatch(es) over 300000 generated strings\n";
    if( diffs ) ++failures;

    // 2. known cases
    struct Case { const char* in; const char* want; };
    const Case cases[] = {
        { "connect postgres://alice:s3cret@db:5432/x failed", "connect postgres://alice:***@db:5432/x failed" },
        { "DB_PASSWORD=hunter2 next", "DB_PASSWORD=*** next" },
        { "my_key = abc123 and AUTH_TOKEN=zzz", "my_key = *** and AUTH_TOKEN=***" },
        { "no secrets here", "no secrets here" },
        { "http://host/path", "http://host/path" },
        { "", "" },
    };
    for( const Case& c : cases )
    {
        const std::string got = fsqlmcp::sanitizeSecrets( c.in );
        if( got != c.want )
        {
            ++failures;
            std::cout << "CASE FAIL in=[" << c.in << "] want=[" << c.want << "] got=[" << got << "]\n";
        }
    }

    // 3. inputs where std::regex throws or overflows the stack: must be instant and correct
    const auto t0 = std::chrono::steady_clock::now();
    const std::string big( 2000000, 'x' );
    if( fsqlmcp::sanitizeSecrets( big ) != big ) { ++failures; std::cout << "long run of x altered\n"; }
    const std::string pw = "DB_PASSWORD=" + std::string( 2000000, 'y' );
    if( fsqlmcp::sanitizeSecrets( pw ) != "DB_PASSWORD=***" ) { ++failures; std::cout << "long password not masked\n"; }
    std::string uri = "postgres://u:" + std::string( 2000000, 'p' ) + "@h";
    if( fsqlmcp::sanitizeSecrets( uri ) != "postgres://u:***@h" ) { ++failures; std::cout << "long uri password not masked\n"; }
    const std::string spaces( 2000000, ' ' );
    if( fsqlmcp::sanitizeSecrets( spaces ) != spaces ) { ++failures; std::cout << "long whitespace altered\n"; }
    const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>( std::chrono::steady_clock::now() - t0 ).count();
    std::cout << "large inputs (2,000,000 chars each) handled in " << ms << " ms\n";
    if( ms > 5000 ) { ++failures; std::cout << "too slow: not linear\n"; }

    std::cout << ( failures ? "sanitize_probe: FAILED\n" : "sanitize_probe: ok\n" );
    return failures ? 1 : 0;
}
