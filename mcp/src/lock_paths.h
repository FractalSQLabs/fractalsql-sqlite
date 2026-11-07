// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
// lock_paths.h -- where the schema / safety-annotation lock files are looked for, and
// whether their absence is fatal.
//
// The default lock paths used to be relative to the process CWD, so a server started
// from any other directory silently ran with NO lock check. A relative path that does
// not exist in the CWD now falls back to the directory holding the executable. Every package
// installs the two lock files beside the binary (and Windows installers and archives do the same),
// so that directory is the one place an installed server looks. A missing lock is reported
// (and refused unless FSQL_MCP_ALLOW_MISSING_LOCKS=true) instead of being silently treated
// as a pass.
#pragma once
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <string>
#if defined( _WIN32 )
// windows.h defines function-like min()/max() macros unless NOMINMAX is set; they rewrite
// std::min/std::max into "std::(...)" and fail to compile (C2589).
#  ifndef NOMINMAX
#    define NOMINMAX
#  endif
#  include <windows.h>
#else
#  include <unistd.h>
#  include <limits.h>
#  include <stdlib.h>
#  if defined( __APPLE__ )
#    include <mach-o/dyld.h>
#  endif
#endif

namespace fsqlmcp
{
    // The absolute path of the running executable, or empty when the platform cannot tell.
    // Linux exposes it as /proc/self/exe; macOS has no /proc and uses _NSGetExecutablePath.
    inline std::string selfExecutablePath()
    {
#if defined( _WIN32 )
        char buf[ 4096 ];
        const DWORD n = GetModuleFileNameA( nullptr, buf, sizeof buf );
        return std::string( buf, n ? n : 0 );
#elif defined( __APPLE__ )
        char raw[ PATH_MAX ];
        uint32_t size = sizeof raw;
        if( _NSGetExecutablePath( raw, &size ) != 0 ) return std::string();
        char real[ PATH_MAX ];
        return realpath( raw, real ) ? std::string( real ) : std::string( raw );
#else
        char buf[ PATH_MAX ];
        const ssize_t n = readlink( "/proc/self/exe", buf, sizeof buf - 1 );
        return std::string( buf, n > 0 ? static_cast<std::size_t>( n ) : 0 );
#endif
    }

    inline std::string selfDirectory()
    {
        const std::string p = selfExecutablePath();
#if defined( _WIN32 )
        const std::size_t cut = p.find_last_of( "\\/" );
#else
        const std::size_t cut = p.find_last_of( '/' );
#endif
        return cut == std::string::npos ? std::string() : p.substr( 0, cut );
    }

    inline bool lockFileExists( const std::string& path )
    {
        std::ifstream in( path );
        return static_cast<bool>( in );
    }

    // Resolve a lock path: an existing path is used as is; a relative one that does not
    // exist in the CWD is tried next to the executable (by basename) before giving up.
    inline std::string resolveLockPath( const std::string& path )
    {
        if( lockFileExists( path ) ) return path;
        const bool relative = !path.empty() && path[ 0 ] != '/' && path.find( ':' ) == std::string::npos;
        if( relative )
        {
            const std::size_t slash = path.find_last_of( "/\\" );
            const std::string base = slash == std::string::npos ? path : path.substr( slash + 1 );
            const std::string dir  = selfDirectory();
            if( !dir.empty() && lockFileExists( dir + "/" + base ) ) return dir + "/" + base;
        }
        return path;
    }

    // For a DEFAULTED lock path that does not exist: try beside the executable. An explicit path (flag or env)
    // is never passed through here, so it is never replaced.
    inline std::string withInstalledFallback( const std::string& path )
    {
        if( lockFileExists( path ) ) return path;
        const std::size_t slash = path.find_last_of( "/\\" );
        const std::string base = slash == std::string::npos ? path : path.substr( slash + 1 );
        const std::string dir  = selfDirectory();
        if( !dir.empty() && lockFileExists( dir + "/" + base ) ) return dir + "/" + base;
        return path;
    }

    // Fail closed: a missing lock file refuses to start unless the operator opts out with
    // FSQL_MCP_ALLOW_MISSING_LOCKS=true (or an explicit FSQL_MCP_REQUIRE_LOCKS=false).
    inline bool lockEnvTruthy( const char* name, bool& isSet )
    {
        const char* v = std::getenv( name );
        isSet = ( v && *v );
        if( !isSet ) return false;
        std::string s( v );
        for( char& c : s ) c = static_cast<char>( ::tolower( static_cast<unsigned char>( c ) ) );
        return s == "true" || s == "1" || s == "on" || s == "yes";
    }

    inline bool requireLocks()
    {
        bool allowSet = false, reqSet = false;
        if( lockEnvTruthy( "FSQL_MCP_ALLOW_MISSING_LOCKS", allowSet ) ) return false;
        const bool req = lockEnvTruthy( "FSQL_MCP_REQUIRE_LOCKS", reqSet );
        if( reqSet && !req ) return false;      // explicit REQUIRE_LOCKS=false is an opt-out
        return true;
    }
}
