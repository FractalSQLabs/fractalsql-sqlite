// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#include "transport_http.h"
#include "transport_socket.h"
#include <openssl/crypto.h>
#include <openssl/err.h>
#include <openssl/rand.h>
#include <openssl/ssl.h>
#include <atomic>
#include <cctype>
#include <chrono>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <map>
#include <mutex>
#include <sstream>
#include <thread>
#include <csignal>

namespace fsqlmcp
{
    // Bearer-token store: opaque token, mtime-hot-reloaded file form,
    // timing-safe compare, NEVER logged.
    class TokenStore
    {
    public:
        explicit TokenStore( const HttpConfig& cfg ) : cfg_( cfg ) { reload( true ); }

        bool matches( const std::string& presented )
        {
            // One lock only: the reload (mtime check) reads token state,
            // so it happens under the same guard as the compare. A
            // same-thread second lock on this non-recursive mutex aborts
            // on MSVC and deadlocks forever on glibc; do not restore the
            // maybeReload-then-lock shape.
            std::lock_guard<std::mutex> lk( mu_ );
            if( !cfg_.authTokenFile.empty() ) reload( false );
            if( token_.empty() ) return false;
            if( presented.size() != token_.size() ) return false;
            return CRYPTO_memcmp( presented.data(), token_.data(), token_.size() ) == 0;   // timing-safe
        }

        // SIGHUP: forced reload, and NOTHING else (13.6's fix; the Python
        // HTTP draft's own handler overcaptured and shut the server down too).
        // Windows has no SIGHUP; the mtime check still reloads per request.
        void forceReloadFromSighup()
        {
#if !defined( _WIN32 )
            reload( true );
#endif
        }

        // 13.3.4's per-client fairness key: the token's own prefix when the
        // deployment uses per-developer static tokens; the session id when one
        // file token serves a team.
        static std::string clientKeyFor( const HttpConfig& cfg, const std::string& bearer,
                                         const std::string& sessionId )
        {
            if( !cfg.authToken.empty() && bearer == cfg.authToken )
                return "token:" + bearer.substr( 0, 8 );
            return "session:" + sessionId;
        }

    private:
        // reload() must run with mu_ held; the mtime hot reload
        // happens whenever matches() is called on the file-token form.
        void reload( bool force )
        {
            if( !cfg_.authTokenFile.empty() )
            {
                mtime_t mt{};
                if( fileMtime( cfg_.authTokenFile, mt ) )
                {
                    if( force || mt != lastMtime_ )
                    {
                        std::ifstream in( cfg_.authTokenFile, std::ios::binary );
                        if( in )
                        {
                            std::string t;
                            std::getline( in, t );
                            while( !t.empty() && ( t.back() == '\r' || t.back() == '\n' ) ) t.pop_back();
                            // An unreadable/empty file never silently disables auth:
                            // token_ is only replaced when the file yields a token.
                            if( !t.empty() ) { token_ = t; lastMtime_ = mt; }
                        }
                    }
                    return;
                }
                return;   // stat failed: keep serving the last known token
            }
            token_ = cfg_.authToken;    // plain env-var form: no hot-reload
        }

        using mtime_t = std::filesystem::file_time_type;
        static bool fileMtime( const std::string& path, mtime_t& out )
        {
            std::error_code ec;
            const auto t = std::filesystem::last_write_time( path, ec );
            if( ec ) return false;
            out = t;
            return true;
        }

        const HttpConfig& cfg_;
        std::mutex mu_;
        std::string token_;
        mtime_t lastMtime_{};
    };

    static std::string opensslLastError()
    {
        const unsigned long code = ERR_get_error();
        if( code == 0 ) return "unknown OpenSSL error";
        char buf[ 256 ];
        ERR_error_string_n( code, buf, sizeof( buf ) );
        return std::string( buf );
    }

    // Owns the server-side SSL_CTX for direct TLS (--https). Loaded once at
    // startup from cfg.tlsCertFile/tlsKeyFile; any failure here (missing
    // file, bad PEM, cert/key mismatch) is a hard startup failure in the
    // caller -- this NEVER falls back to plaintext silently. The resulting
    // SSL_CTX is read-only for the rest of the process's life, which is why
    // sharing one across every connection thread's SSL_new() needs no extra
    // locking (OpenSSL's own documented thread-safety guarantee for a
    // configured, unmodified SSL_CTX).
    class TlsServerContext
    {
    public:
        bool init( const HttpConfig& cfg, std::string& errOut )
        {
            ctx_ = SSL_CTX_new( TLS_server_method() );
            if( !ctx_ ) { errOut = "SSL_CTX_new failed: " + opensslLastError(); return false; }
            SSL_CTX_set_min_proto_version( ctx_, TLS1_2_VERSION );
            if( SSL_CTX_use_certificate_chain_file( ctx_, cfg.tlsCertFile.c_str() ) != 1 )
            {
                errOut = "failed to load TLS cert file '" + cfg.tlsCertFile + "': " + opensslLastError();
                return false;
            }
            if( SSL_CTX_use_PrivateKey_file( ctx_, cfg.tlsKeyFile.c_str(), SSL_FILETYPE_PEM ) != 1 )
            {
                errOut = "failed to load TLS key file '" + cfg.tlsKeyFile + "': " + opensslLastError();
                return false;
            }
            if( SSL_CTX_check_private_key( ctx_ ) != 1 )
            {
                errOut = "TLS certificate and private key do not match: " + opensslLastError();
                return false;
            }
            return true;
        }
        ~TlsServerContext() { if( ctx_ ) SSL_CTX_free( ctx_ ); }
        TlsServerContext( const TlsServerContext& ) = delete;
        TlsServerContext& operator=( const TlsServerContext& ) = delete;
        TlsServerContext() = default;
        SSL_CTX* get() const { return ctx_; }

    private:
        SSL_CTX* ctx_ = nullptr;
    };

    // Thin read/write indirection so the same request-parsing/response-
    // writing code below works unmodified for plaintext (bare net::Socket)
    // and direct-TLS (SSL*) connections; ssl_ is null for the plaintext case.
    class ConnIo
    {
    public:
        ConnIo( net::Socket sock, SSL* ssl ) : sock_( sock ), ssl_( ssl ) {}
        int recv( char* buf, int len ) const
        {
            if( ssl_ ) { const int n = SSL_read( ssl_, buf, len ); return n > 0 ? n : -1; }
            return net::recv( sock_, buf, len );
        }
        int send( const char* buf, int len ) const
        {
            if( ssl_ ) { const int n = SSL_write( ssl_, buf, len ); return n > 0 ? n : -1; }
            return net::send( sock_, buf, len );
        }

    private:
        net::Socket sock_;
        SSL* ssl_;
    };

    static std::string randomSessionId()
    {
        unsigned char rnd[ 16 ] = {};
        if( RAND_bytes( rnd, sizeof( rnd ) ) != 1 )
        {
            RAND_poll();
            (void) RAND_bytes( rnd, sizeof( rnd ) );
        }
        static const char* kHex = "0123456789abcdef";
        std::string out = "sess-";
        for( unsigned char c : rnd )
        {
            out.push_back( kHex[ c >> 4 ] );
            out.push_back( kHex[ c & 0xF ] );
        }
        return out;
    }

    static std::atomic<bool> g_httpSignalled{ false };
    static void onHttpTermSignal( int ) { g_httpSignalled.store( true ); }
#if !defined( _WIN32 )
    static TokenStore* g_tokenStore = nullptr;
    static void onSighup( int ) { if( g_tokenStore ) g_tokenStore->forceReloadFromSighup(); }   // reload ONLY
#endif

    static constexpr std::size_t kMaxHeaderBytes = 64 * 1024;
    static constexpr std::size_t kMaxBodyBytes   = 32 * 1024 * 1024;
    static const char* kSessionHeader = "Mcp-Session-Id";

    struct HttpRequest
    {
        std::string method, target, version;
        std::map<std::string, std::string> headers;   // lower-cased keys
        std::string body;
    };

    // Reads one HTTP/1.1 request (request line, headers, Content-Length body).
    // Chunked transfer coding is deliberately refused: this is a
    // machine-to-machine JSON-RPC endpoint, not a general web server.
    static bool readHttpRequest( const ConnIo& io, HttpRequest& out )
    {
        std::string raw;
        char buf[ 8192 ];
        std::size_t headerEnd = std::string::npos;

        while( headerEnd == std::string::npos )
        {
            const int n = io.recv( buf, static_cast<int>( sizeof( buf ) ) );
            if( n <= 0 ) return false;
            raw.append( buf, static_cast<std::size_t>( n ) );
            headerEnd = raw.find( "\r\n\r\n" );
            if( raw.size() > kMaxHeaderBytes ) return false;
        }

        std::istringstream head( raw.substr( 0, headerEnd ) );
        std::string line;
        if( !std::getline( head, line ) ) return false;
        while( !line.empty() && ( line.back() == '\r' || line.back() == '\n' ) ) line.pop_back();
        { std::istringstream rl( line ); rl >> out.method >> out.target >> out.version; }

        while( std::getline( head, line ) )
        {
            while( !line.empty() && line.back() == '\r' ) line.pop_back();
            const std::size_t colon = line.find( ':' );
            if( colon == std::string::npos ) continue;
            std::string key = line.substr( 0, colon );
            std::string val = line.substr( colon + 1 );
            for( char& c : key ) c = static_cast<char>( std::tolower( static_cast<unsigned char>( c ) ) );
            std::size_t vb = 0;
            while( vb < val.size() && ( val[ vb ] == ' ' || val[ vb ] == '\t' ) ) ++vb;
            out.headers[ key ] = val.substr( vb );
        }

        if( out.headers.count( "transfer-encoding" ) )
            return false;   // chunked: refused

        std::size_t contentLength = 0;
        auto cl = out.headers.find( "content-length" );
        if( cl != out.headers.end() )
        {
            for( char c : cl->second )
            {
                if( c < '0' || c > '9' ) return false;
                contentLength = contentLength * 10 + static_cast<std::size_t>( c - '0' );
                if( contentLength > kMaxBodyBytes ) return false;
            }
        }

        out.body = raw.substr( headerEnd + 4 );
        while( out.body.size() < contentLength )
        {
            const int n = io.recv( buf,
                static_cast<int>( std::min<std::size_t>( sizeof( buf ), contentLength - out.body.size() ) ) );
            if( n <= 0 ) return false;
            out.body.append( buf, static_cast<std::size_t>( n ) );
        }
        out.body.resize( contentLength );
        return true;
    }

    static void sendAll( const ConnIo& io, const std::string& bytes )
    {
        std::size_t sent = 0;
        while( sent < bytes.size() )
        {
            const int n = io.send( bytes.data() + sent,
                static_cast<int>( std::min<std::size_t>( bytes.size() - sent, std::size_t( 1 ) << 20 ) ) );
            if( n <= 0 ) return;
            sent += static_cast<std::size_t>( n );
        }
    }

    static std::string httpStatusText( int code )
    {
        switch( code )
        {
            case 200: return "OK";
            case 202: return "Accepted";
            case 400: return "Bad Request";
            case 401: return "Unauthorized";
            case 404: return "Not Found";
            case 405: return "Method Not Allowed";
            case 503: return "Service Unavailable";
            default:  return "OK";
        }
    }

    static void sendHttp( const ConnIo& io, int status, const std::string& body, const std::string& mime,
                          const std::map<std::string, std::string>& extra = {} )
    {
        std::ostringstream out;
        out << "HTTP/1.1 " << status << ' ' << httpStatusText( status ) << "\r\n"
            << "Content-Type: " << mime << "\r\n"
            << "Content-Length: " << body.size() << "\r\n"
            << "Connection: close\r\n";
        for( const auto& kv : extra )
            out << kv.first << ": " << kv.second << "\r\n";
        out << "\r\n" << body;
        sendAll( io, out.str() );
    }

    static void sendHttpJson( const ConnIo& io, int status, const Json& body,
                              const std::map<std::string, std::string>& extra = {} )
    {
        sendHttp( io, status, body.dump(), "application/json", extra );
    }

    int runHttpTransport( JsonRpcServer& server, const HttpConfig& cfg,
                          std::function<bool()> readinessProbe,
                          std::function<void( const std::string& sessionId )> closeSession )
    {
        net::init();
        TokenStore tokens( cfg );
#if !defined( _WIN32 )
        g_tokenStore = &tokens;
        std::signal( SIGHUP, onSighup );   // 13.6: forces reload, never shutdown
#endif
        std::signal( SIGTERM, onHttpTermSignal );
        std::signal( SIGINT,  onHttpTermSignal );

        // Direct TLS, when requested, is validated BEFORE the port is even
        // opened: a bad cert/key is a startup failure, never a silent
        // plaintext fallback or a listener that accepts connections it can't
        // actually serve.
        TlsServerContext tls;
        if( cfg.tlsEnabled )
        {
            std::string tlsErr;
            if( !tls.init( cfg, tlsErr ) )
            {
                logging::exceptionDetail( "https_tls_init", tlsErr );
                net::shutdownNet();
                return 1;
            }
        }
        SSL_CTX* sslCtx = tls.get();   // null when !cfg.tlsEnabled

        std::string listenErr;
        net::Socket listenSock = net::listenTcp( cfg.host, cfg.port, listenErr );
        if( net::isInvalid( listenSock ) )
        {
            logging::exceptionDetail( "http_listen", listenErr );
            net::shutdownNet();
            return 1;
        }

        logging::event( "http_transport_listening", Json{
            { "host", cfg.host }, { "port", cfg.port }, { "path", cfg.path },
            { "tls", cfg.tlsEnabled },
            { "note", cfg.tlsEnabled
                  ? "direct TLS terminates in this process (--https)"
                  : "TLS must terminate in front of this server; "
                    "this process speaks plaintext HTTP only behind that proxy" } } );

        std::mutex sessionsMu;
        std::map<std::string, std::string> sessions;   // sessionId -> its fairness/dispatch client key
        std::atomic<int> liveConnections{ 0 };         // for the bounded post-drain grace below

        while( !g_httpSignalled.load() )
        {
            net::Socket conn = net::accept( listenSock );
            if( net::isInvalid( conn ) )
            {
                if( g_httpSignalled.load() ) break;
                continue;   // accept hiccup; listen loop continues
            }

            // One thread per connection; concurrency is bounded by the
            // ConcurrencyManager caps, not by thread count (13.3.4/10.7). The
            // long Cognition/Agency call runs on this thread, and the HTTP
            // response simply waits (the contract's "joined before the response
            // is written"). Deliberately detached: every response is written
            // with Connection: close, so each thread is short-lived and ends
            // right after its write; the accept loop keeps accepting.
            liveConnections.fetch_add( 1 );
            std::thread( [ conn, &server, &tokens, cfg, &sessionsMu, &sessions,
                           &liveConnections, readinessProbe, closeSession, sslCtx ]
            {
                SSL* ssl = nullptr;
                auto closeConn = [ &ssl, conn ]()
                {
                    if( ssl ) { SSL_shutdown( ssl ); SSL_free( ssl ); ssl = nullptr; }
                    net::close( conn );
                };
                // An exception escaping a thread function is std::terminate
                // and aborts the whole server; one bad connection must
                // degrade to a logged error and a closed socket instead.
                try
                {
                if( cfg.tlsEnabled )
                {
                    ssl = SSL_new( sslCtx );
                    SSL_set_fd( ssl, static_cast<int>( net::rawHandle( conn ) ) );
                    if( SSL_accept( ssl ) <= 0 )
                    {
                        logging::exceptionDetail( "https_handshake", opensslLastError() );
                        closeConn();
                        liveConnections.fetch_sub( 1 );
                        return;
                    }
                }
                const ConnIo io( conn, ssl );

                HttpRequest req;
                while( !g_httpSignalled.load() && readHttpRequest( io, req ) )
                {
                    const std::string path = req.target.substr( 0, req.target.find( '?' ) );
                    auto authIt = req.headers.find( "authorization" );
                    const std::string authHeader = authIt == req.headers.end() ? std::string() : authIt->second;
                    std::string presented;
                    if( authHeader.rfind( "Bearer ", 0 ) == 0 ) presented = authHeader.substr( 7 );

                    const bool authenticated = !presented.empty() && tokens.matches( presented );

                    if( req.method == "GET" )
                    {
                        // The ONLY two unauthenticated paths (10.3).
                        if( path == "/healthz" ) { sendHttpJson( io, 200, Json{ { "ok", true } } ); break; }
                        if( path == "/readyz" )
                        {
                            const bool ready = readinessProbe ? readinessProbe() : false;
                            sendHttpJson( io, ready ? 200 : 503,
                                          Json{ { "ok", ready }, { "probe", "engine version query" } } );
                            break;
                        }
                    }

                    if( !authenticated )
                    {
                        // 401 BEFORE the request reaches the adapter layer
                        // never log the presented value.
                        sendHttpJson( io, 401, Json{ { "error",
                            presented.empty() ? "missing bearer token" : "invalid bearer token" } } );
                        break;
                    }

                    if( req.method == "GET" )
                    {
                        if( path == cfg.path )
                            sendHttpJson( io, 405, Json{ { "error",
                                "GET /mcp is not used by this server; POST JSON-RPC 2.0 messages" } } );
                        else
                            sendHttpJson( io, 404, Json{ { "error", "not found" } } );
                        break;
                    }

                    auto sidIt = req.headers.find( "mcp-session-id" );
                    const std::string sessionId = sidIt == req.headers.end() ? std::string() : sidIt->second;

                    Json bodyJson = Json::parse( req.body, nullptr, false );
                    const bool parsed = !bodyJson.is_discarded() && bodyJson.is_object();
                    const std::string method = parsed ? bodyJson.value( "method", "" ) : "";
                    const bool isRequest = parsed && bodyJson.contains( "id" );
                    const bool isInitialize = method == "initialize";
                    const bool isCancel = ( method == "notifications/cancelled" || method == "$/cancel" );

                    if( req.method == "DELETE" )
                    {
                        if( path == cfg.path && !sessionId.empty() )
                        {
                            std::string storedKey;
                            {
                                std::lock_guard<std::mutex> lk( sessionsMu );
                                auto sit = sessions.find( sessionId );
                                if( sit != sessions.end() ) { storedKey = sit->second; sessions.erase( sit ); }
                            }
                            if( closeSession ) closeSession( storedKey.empty() ? sessionId : storedKey );
                            sendHttpJson( io, 200, Json{ { "ok", true } } );
                        }
                        else
                            sendHttpJson( io, 404, Json{ { "error", "not found" } } );
                        break;
                    }

                    if( req.method != "POST" || path != cfg.path )
                    {
                        sendHttpJson( io, req.method == "POST" ? 404 : 405,
                                      Json{ { "error", req.method == "POST" ? "not found" : "method not allowed" } } );
                        break;
                    }

                    if( server.isShuttingDown() )
                    {
                        sendHttpJson( io, 503, Json{ { "error", "server shutting down (retry after restart)" } } );
                        break;
                    }

                    if( !parsed || req.body.empty() || req.body.size() > kMaxBodyBytes )
                    {
                        sendHttpJson( io, 400,
                                      Json{ { "error", "body is not valid JSON or missing/oversized" } } );
                        break;
                    }

                    // Session isolation: initialize mints the session id
                    // (and must not arrive with one); every other request
                    // presents a valid one (400 missing, 404 unknown).
                    std::string clientKey;
                    if( isInitialize )
                    {
                        if( !sessionId.empty() )
                        {
                            sendHttpJson( io, 400, Json{ { "error", "initialize must not carry a session id" } } );
                            break;
                        }
                        const std::string minted = randomSessionId();
                        clientKey = TokenStore::clientKeyFor( cfg, presented, minted );
                        { std::lock_guard<std::mutex> lk( sessionsMu ); sessions[ minted ] = clientKey; }
                        auto resp = server.handleLine( req.body, clientKey );
                        std::map<std::string, std::string> extra;
                        extra[ kSessionHeader ] = minted;
                        if( resp ) sendHttp( io, 200, *resp, "application/json", extra );
                        else sendHttp( io, 202, "", "text/plain", extra );
                        break;
                    }

                    if( isCancel && !isRequest )
                    {
                        // Cancel notifications ride the authenticated session.
                        if( sessionId.empty() )
                        {
                            sendHttpJson( io, 400, Json{ { "error", "missing Mcp-Session-Id (initialize first)" } } );
                            break;
                        }
                        {
                            std::lock_guard<std::mutex> lk( sessionsMu );
                            auto sit = sessions.find( sessionId );
                            if( sit == sessions.end() )
                            {
                                sendHttpJson( io, 404, Json{ { "error", "unknown session (deleted or never initialized)" } } );
                                break;
                            }
                            clientKey = sit->second;
                        }
                        server.handleLine( req.body, clientKey );   // notification: nullopt by design
                        sendHttp( io, 202, "", "text/plain" );
                        break;
                    }

                    if( sessionId.empty() )
                    {
                        sendHttpJson( io, 400, Json{ { "error", "missing Mcp-Session-Id (initialize first)" } } );
                        break;
                    }
                    {
                        std::lock_guard<std::mutex> lk( sessionsMu );
                        auto sit = sessions.find( sessionId );
                        if( sit == sessions.end() )
                        {
                            sendHttpJson( io, 404, Json{ { "error", "unknown session (deleted or never initialized)" } } );
                            break;
                        }
                        clientKey = sit->second;
                    }
                    auto resp = server.handleLine( req.body, clientKey );
                    if( resp )
                        sendHttp( io, 200, *resp, "application/json" );
                    else
                        // notification, or a cancelled request whose result is
                        // discarded: per 1.1, nothing of substance is delivered.
                        sendHttp( io, isRequest ? 200 : 202, "", "text/plain" );
                    break;
                }
                closeConn();
                liveConnections.fetch_sub( 1 );
                }
                catch( const std::exception& e )
                {
                    logging::exceptionDetail( "http_conn_thread", sanitizeSecrets( e.what() ) );
                    closeConn();
                    liveConnections.fetch_sub( 1 );
                }
                catch( ... )
                {
                    logging::exceptionDetail( "http_conn_thread", "unknown exception" );
                    closeConn();
                    liveConnections.fetch_sub( 1 );
                }
            } ).detach();
        }

        // Termination (SIGTERM/SIGINT/accept-stop): begin the drain, then
        // close every session's dedicated DB connection (11.2).
        server.beginShutdown();
        net::stopListening( listenSock );
        net::close( listenSock );
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds( cfg.shutdownDrainMs );
        while( server.activeRequestCount() > 0 && std::chrono::steady_clock::now() < deadline )
            std::this_thread::sleep_for( std::chrono::milliseconds( 20 ) );

        // Sessions close via the engine's own hook (13.4.3). Every response is
        // written with Connection: close, so detached connection threads end
        // right after their write; give them ONE bounded grace period to
        // finish writing before returning (this function returning ends
        // main() and the process).
        {
            const auto graceDeadline = std::chrono::steady_clock::now() + std::chrono::milliseconds( 2000 );
            while( liveConnections.load() > 0 && std::chrono::steady_clock::now() < graceDeadline )
                std::this_thread::sleep_for( std::chrono::milliseconds( 20 ) );
        }
        std::vector<std::string> keys;
        { std::lock_guard<std::mutex> lk( sessionsMu );
          for( const auto& kv : sessions ) keys.push_back( kv.second ); }
        for( const std::string& key : keys )
            if( closeSession ) closeSession( key );

        net::shutdownNet();
        logging::event( "shutdown_complete", Json{ { "transport", "http" } } );
        return 0;
    }
}