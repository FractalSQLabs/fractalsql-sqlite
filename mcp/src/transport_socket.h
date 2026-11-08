// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#pragma once
// Platform socket shim for the optional HTTP transport (10.3/13.5): the only
// file in mcp/src that touches Winsock2/POSIX sockets. Deliberately includes
// NO standard-heavy header (notably nothing JSON): an isolating boundary,
// and the fix for a real GCC 13.2/MinGW toolchain defect on Windows where
// <winsock2.h> in the same TU as the vendored JSON header exhausts the
// compiler's memory. The HTTP transport sees sockets only through this
// interface, which is why the same transport builds on Windows and POSIX CI.
#include <cstdint>
#include <string>

namespace fsqlmcp::net
{
    // Opaque, no-include socket handles (int on POSIX, unsigned int-size
    // descriptor on Windows); kept typeless here so no TU besides the .cpp
    // needs the platform headers.
    using Socket = void*;
    Socket invalidSocket();
    bool isInvalid( Socket s );

    // The underlying OS descriptor (fd on POSIX, SOCKET on Windows) as an
    // intptr_t, exposed ONLY so the optional direct-TLS mode can hand it to
    // OpenSSL's SSL_set_fd(), which takes a plain int either way -- the same
    // narrowing every OpenSSL-on-Windows caller accepts (real socket values
    // never approach INT_MAX in practice). No other caller needs this; the
    // plaintext path never leaves this header's Socket abstraction.
    std::intptr_t rawHandle( Socket s );

    void init();          // WSAStartup on Windows; no-op on POSIX
    void shutdownNet();   // WSACleanup on Windows; no-op on POSIX

    // Returns invalidSocket() + a human-readable reason on failure.
    Socket listenTcp( const std::string& host, int port, std::string& errOut );

    // True when a connection is waiting, false after `ms` with none (or on a
    // signal). A signal handler installed with std::signal restarts a blocked
    // accept(), so the accept loop waits here in short slices instead.
    bool waitForConnection( Socket listenSock, int ms );
    Socket accept( Socket listenSock );     // invalidSocket() when the listener has stopped
    void stopListening( Socket listenSock );// shutdown(both); wakes a blocked accept()
    int  recv( Socket s, char* buf, int len );   // <=0 => closed/error (caller continues)
    int  send( Socket s, const char* buf, int len ); // <=0 => failed
    void close( Socket s );
    // Closes after a refusal reply: half-closes, reads and discards the
    // client's pending request for up to lingerMs, then closes. A plain close
    // with unread data resets the connection, and the reset discards the
    // reply that was just written -- the peer then sees a broken connection
    // instead of the refusal it was owed (seen on Windows).
    void closeAfterReply( Socket s, int lingerMs );
}