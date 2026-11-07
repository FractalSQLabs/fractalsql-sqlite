// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
// The Windows leg of the socket shim (transport_socket.h). Deliberately the
// ONLY Winsock-including TU in mcp/src.
#if defined( _WIN32 )
#include "transport_socket.h"
#define _WIN32_LEAN_AND_MEAN
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <winsock2.h>
#include <ws2tcpip.h>
#include <chrono>
#include <cstdint>
#include <string>

namespace fsqlmcp::net
{
    static SOCKET asSock( Socket s ) { return reinterpret_cast<SOCKET>( s ); }

    Socket invalidSocket() { return reinterpret_cast<void*>( INVALID_SOCKET ); }
    bool isInvalid( Socket s ) { return asSock( s ) == INVALID_SOCKET; }
    std::intptr_t rawHandle( Socket s ) { return static_cast<std::intptr_t>( asSock( s ) ); }

    void init()
    {
        WSADATA wsa;
        WSAStartup( MAKEWORD( 2, 2 ), &wsa );
    }
    void shutdownNet() { WSACleanup(); }

    Socket listenTcp( const std::string& host, int port, std::string& errOut )
    {
        SOCKET s = ::socket( AF_INET, SOCK_STREAM, 0 );
        if( s == INVALID_SOCKET )
        {
            errOut = "socket() failed: WSA error " + std::to_string( WSAGetLastError() );
            return invalidSocket();
        }
        sockaddr_in addr{};
        addr.sin_family = AF_INET;
        addr.sin_port = htons( static_cast<unsigned short>( port ) );
        if( InetPtonA( AF_INET, host.c_str(), &addr.sin_addr ) != 1 )
        {
            errOut = "unparsable listen host: " + host;
            ::closesocket( s );
            return invalidSocket();
        }
        if( ::bind( s, reinterpret_cast<sockaddr*>( &addr ), sizeof( addr ) ) == SOCKET_ERROR ||
            ::listen( s, SOMAXCONN ) == SOCKET_ERROR )
        {
            errOut = "bind/listen failed: WSA error " + std::to_string( WSAGetLastError() );
            ::closesocket( s );
            return invalidSocket();
        }
        return reinterpret_cast<void*>( s );
    }

    bool waitForConnection( Socket listenSock, int ms )
    {
        WSAPOLLFD p{ asSock( listenSock ), POLLRDNORM, 0 };
        return ::WSAPoll( &p, 1, ms ) > 0;
    }

    Socket accept( Socket listenSock )
    {
        SOCKET s = ::accept( asSock( listenSock ), nullptr, nullptr );
        if( s == INVALID_SOCKET ) return invalidSocket();
        // Bounded idle read so a silent client cannot pin a connection thread.
        DWORD timeoutMs = 65'000;
        ::setsockopt( s, SOL_SOCKET, SO_RCVTIMEO,
                      reinterpret_cast<const char*>( &timeoutMs ), sizeof( timeoutMs ) );
        return reinterpret_cast<void*>( s );
    }

    void stopListening( Socket listenSock ) { ::shutdown( asSock( listenSock ), SD_BOTH ); }
    int  recv( Socket s, char* buf, int len ) { return ::recv( asSock( s ), buf, len, 0 ); }
    int  send( Socket s, const char* buf, int len )
    {
        int sent = ::send( asSock( s ), buf, len, 0 );
        return sent == SOCKET_ERROR ? -1 : sent;
    }
    void close( Socket s ) { ::closesocket( asSock( s ) ); }
    void closeAfterReply( Socket s, int lingerMs )
    {
        // Half-close: the peer reads the reply and then sees EOF, so a client
        // that is still writing its request is not reset straight away.
        ::shutdown( asSock( s ), SD_SEND );
        // Read and discard whatever the peer sends until it stops or the
        // linger window ends. Data left unread in the receive buffer at
        // close time makes Windows reset the connection, and the reset
        // discards the reply that was just written: the client would see a
        // broken connection instead of the refusal it was owed.
        DWORD timeoutMs = 100;
        ::setsockopt( asSock( s ), SOL_SOCKET, SO_RCVTIMEO,
                      reinterpret_cast<const char*>( &timeoutMs ), sizeof( timeoutMs ) );
        char sink[ 4096 ];
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds( lingerMs );
        while( std::chrono::steady_clock::now() < deadline )
        {
            const int n = ::recv( asSock( s ), sink, static_cast<int>( sizeof( sink ) ), 0 );
            if( n == 0 ) break;   // the peer closed: nothing more can arrive
            if( n == SOCKET_ERROR )
            {
                const int e = WSAGetLastError();
                // A timeout means the peer has not written yet: keep waiting
                // for the rest of its request.
                if( e != WSAETIMEDOUT && e != WSAEWOULDBLOCK ) break;
            }
        }
        ::closesocket( asSock( s ) );
    }
}
#endif  // _WIN32