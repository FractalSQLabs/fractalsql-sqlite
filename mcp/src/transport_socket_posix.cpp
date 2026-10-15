// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
// The POSIX leg of the socket shim (transport_socket.h), Linux/macOS CI.
#if !defined( _WIN32 )
#include "transport_socket.h"
#include <sys/socket.h>
#include <sys/time.h>   // struct timeval (SO_RCVTIMEO); glibc pulls this
                         // in transitively via sys/socket.h, musl doesn't
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <cerrno>
#include <cstdint>   // std::intptr_t, not pulled in transitively here
#include <cstring>
#include <string>

namespace fsqlmcp::net
{
    static int asFd( Socket s ) { return static_cast<int>( reinterpret_cast<std::intptr_t>( s ) ); }

    Socket invalidSocket() { return reinterpret_cast<void*>( static_cast<std::intptr_t>( -1 ) ); }
    bool isInvalid( Socket s ) { return asFd( s ) < 0; }
    std::intptr_t rawHandle( Socket s ) { return reinterpret_cast<std::intptr_t>( s ); }

    void init() {}
    void shutdownNet() {}

    Socket listenTcp( const std::string& host, int port, std::string& errOut )
    {
        const int fd = ::socket( AF_INET, SOCK_STREAM, 0 );
        if( fd < 0 )
        {
            errOut = "socket() failed: errno " + std::to_string( errno );
            return invalidSocket();
        }
        int one = 1;
        ::setsockopt( fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof( one ) );
        sockaddr_in addr{};
        addr.sin_family = AF_INET;
        addr.sin_port = htons( static_cast<unsigned short>( port ) );
        if( ::inet_pton( AF_INET, host.c_str(), &addr.sin_addr ) != 1 )
        {
            errOut = "unparsable listen host: " + host;
            ::close( fd );
            return invalidSocket();
        }
        if( ::bind( fd, reinterpret_cast<sockaddr*>( &addr ), sizeof( addr ) ) < 0 ||
            ::listen( fd, 16 ) < 0 )
        {
            errOut = "bind/listen failed: errno " + std::to_string( errno );
            ::close( fd );
            return invalidSocket();
        }
        return reinterpret_cast<void*>( static_cast<std::intptr_t>( fd ) );
    }

    Socket accept( Socket listenSock )
    {
        const int fd = ::accept( asFd( listenSock ), nullptr, nullptr );
        if( fd < 0 ) return invalidSocket();
        // Bounded idle read so a silent client cannot pin a connection thread.
        struct timeval tv{ 65, 0 };
        ::setsockopt( fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof( tv ) );
        return reinterpret_cast<void*>( static_cast<std::intptr_t>( fd ) );
    }

    void stopListening( Socket listenSock ) { ::shutdown( asFd( listenSock ), SHUT_RDWR ); }
    int  recv( Socket s, char* buf, int len ) { return ::recv( asFd( s ), buf, len, 0 ); }
    int  send( Socket s, const char* buf, int len ) { return ::send( asFd( s ), buf, len, 0 ); }
    void close( Socket s ) { ::close( asFd( s ) ); }
}
#endif  // !defined(_WIN32)