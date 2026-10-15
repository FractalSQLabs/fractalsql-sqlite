// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#include "transport_stdio.h"
#include <cstdio>
#include <thread>
#include <atomic>
#include <csignal>
#include <chrono>
#include <vector>
#include <mutex>
#include <string>

namespace fsqlmcp
{
    static std::atomic<bool> g_signalled{ false };
    static void onTermSignal( int ) { g_signalled.store( true ); }

    // Byte-safe bounded line reader: NEVER std::getline(std::cin,...), which
    // narrows int_type->char and can abort a sanitizer build on a single
    // 0x80-0xFF byte.
    static bool readLineBounded( std::string& out, std::size_t maxBytes )
    {
        out.clear();
        int c;
        while( ( c = std::fgetc( stdin ) ) != EOF )
        {
            if( c == '\n' ) return true;
            if( out.size() < maxBytes )
                out.push_back( static_cast<char>( static_cast<unsigned char>( c ) ) );
        }
        return !out.empty();
    }

    static void writeLine( const std::string& response )
    {
        std::fputs( response.c_str(), stdout );
        std::fputc( '\n', stdout );
        std::fflush( stdout );
    }

    int runStdioTransport( JsonRpcServer& server, const StdioConfig& cfg )
    {
        std::signal( SIGTERM, onTermSignal );
        std::signal( SIGINT,  onTermSignal );

        std::vector<std::thread> workers;
        std::mutex workersMu;

        constexpr std::size_t kLineMax = 8 * 1024 * 1024;
        std::string line;
        while( !g_signalled.load() && readLineBounded( line, kLineMax ) )
        {
            if( line.find_first_not_of( " \t\r\n\v\f" ) == std::string::npos )
                continue;
            if( server.isShuttingDown() )
                continue;    // new requests rejected inline; EOF/signal path below still drains

            const std::string lineCopy = line;
            std::lock_guard<std::mutex> lk( workersMu );
            try
            {
                workers.emplace_back( [ &server, lineCopy ]
                {
                    auto resp = server.handleLine( lineCopy, "stdio" );
                    if( resp )
                        writeLine( *resp );
                } );
            }
            catch( const std::exception& e )
            {
                // Thread spawn itself failed (resource exhaustion); still answer
                // this line synchronously rather than dropping a request silently.
                logging::exceptionDetail( "stdio_spawn", sanitizeSecrets( e.what() ) );
                if( !server.isShuttingDown() )
                {
                    auto resp = server.handleLine( lineCopy, "stdio" );
                    if( resp )
                        writeLine( *resp );
                }
            }
        }

        server.beginShutdown();
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds( cfg.shutdownDrainMs );
        while( server.activeRequestCount() > 0 && std::chrono::steady_clock::now() < deadline )
            std::this_thread::sleep_for( std::chrono::milliseconds( 20 ) );

        for( auto& t : workers ) if( t.joinable() ) t.join();
        logging::event( "shutdown_complete", Json{ { "transport", "stdio" } } );
        return 0;
    }
}