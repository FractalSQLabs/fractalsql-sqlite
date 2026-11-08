// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
// The POSIX leg of the socket shim (transport_socket.h), Linux/macOS CI.
#if !defined( _WIN32 )
#include "transport_socket.h"
#include <sys/socket.h>
#include <poll.h>
#include <sys/time.h>   // struct timeval (SO_RCVTIMEO); glibc pulls this
                         // in transitively via sys/socket.h, musl doesn't
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <cerrno>
#include <chrono>
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
            ::listen( fd, SOMAXCONN ) < 0 )
        {
            errOut = "bind/listen failed: errno " + std::to_string( errno );
            ::close( fd );
            return invalidSocket();
        }
        return reinterpret_cast<void*>( static_cast<std::intptr_t>( fd ) );
    }

    bool waitForConnection( Socket listenSock, int ms )
    {
        pollfd p{ asFd( listenSock ), POLLIN, 0 };
        return ::poll( &p, 1, ms ) > 0;
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
    int  send( Socket s, const char* buf, int len )
    {
        // MSG_NOSIGNAL: a write to a peer that has gone returns an error here instead of raising SIGPIPE.
#ifdef MSG_NOSIGNAL
        return static_cast<int>( ::send( asFd( s ), buf, static_cast<std::size_t>( len ), MSG_NOSIGNAL ) );
#else
        return static_cast<int>( ::send( asFd( s ), buf, static_cast<std::size_t>( len ), 0 ) );   // macOS: SIGPIPE is ignored process-wide
#endif
    }
    void close( Socket s ) { ::close( asFd( s ) ); }
    void closeAfterReply( Socket s, int lingerMs )
    {
        // Half-close: the peer reads the reply and then sees EOF, so a client
        // that is still writing its request is not reset straight away.
        ::shutdown( asFd( s ), SHUT_WR );
        // Read and discard whatever the peer sends until it stops or the
        // linger window ends. Data left unread in the receive buffer at
        // close time makes the kernel reset the connection, and the reset
        // discards the reply that was just written: the client would see a
        // broken connection instead of the refusal it was owed.
        timeval tv{ 0, 100'000 };
        ::setsockopt( asFd( s ), SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof( tv ) );
        char sink[ 4096 ];
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds( lingerMs );
        while( std::chrono::steady_clock::now() < deadline )
        {
            const ssize_t n = ::recv( asFd( s ), sink, sizeof( sink ), 0 );
            if( n == 0 ) break;   // the peer closed: nothing more can arrive
            if( n < 0 )
            {
                // No data yet (or a signal landed mid-read): keep waiting for
                // the rest of the peer's request.
                if( errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR ) break;
            }
        }
        ::close( asFd( s ) );
    }
}
#endif  // !defined(_WIN32)