// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#if defined( _WIN32 ) && !defined( NOMINMAX )
// windows.h defines function-like min()/max() macros unless NOMINMAX is set;
// they rewrite std::min/std::max into "std::(...)" and fail to compile (C2589).
// On Windows <openssl/ssl.h> reaches windows.h via e_ostime.h -> winsock2.h,
// so the guard has to be set before the OpenSSL includes below.
#  define NOMINMAX
#endif
#include "transport_http.h"
#include "transport_socket.h"
#include "policy.h"
#include <openssl/crypto.h>
#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/hmac.h>
#include <openssl/rand.h>
#include <openssl/sha.h>
#include <openssl/ssl.h>
#include <atomic>
#include <cctype>
#include <cerrno>
#include <chrono>
#include <cstdio>
#include <ctime>
#include <iostream>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <map>
#include <mutex>
#include <set>
#include <sstream>
#include <thread>
#include <csignal>
#include <algorithm>
#include <cstdlib>
#ifndef _WIN32
  #include <sys/resource.h>
#endif

namespace fsqlmcp
{
    // SIGHUP: a pending forced-reload request, consumed by whichever
    // connection thread next calls TokenStore::matches(). The signal
    // handler itself (onSighup, below) ONLY touches this atomic -- no
    // malloc/new, no iostream, no filesystem calls -- because those are
    // not async-signal-safe: if the signal lands while the interrupted
    // thread is already inside glibc's own (non-reentrant) malloc lock,
    // a signal handler that also calls malloc can deadlock the whole
    // process. TSan's "signal-unsafe call inside of a signal" diagnostic
    // caught the previous version of this (forceReloadFromSighup() ran
    // reload(true) -- ifstream/filesystem::path/string allocation --
    // directly from the handler) the first time any test actually sent
    // a real SIGHUP. A relaxed atomic store/exchange is signal-safe
    // (lock-free bool) and needs no mutex.
    static std::atomic<bool> g_sighupReload{ false };

    // Bearer-token store: opaque token, mtime-hot-reloaded file form,
    // timing-safe compare, NEVER logged.
    //
    // Two credential forms live here:
    //
    //  1. THE DEPLOYMENT TOKEN (FSQL_MCP_AUTH_TOKEN / _FILE). One secret for
    //     the whole deployment; every holder shares one identity.
    //  2. PER-CLIENT CREDENTIALS (FSQL_MCP_TOKEN_POLICY_FILE). A JSON file
    //     naming clients, each with the SHA-256 of its token (so the file
    //     itself holds no secret), an optional expiry and an optional tool
    //     allowlist. A client that presents its own token is that client:
    //     its name is its fairness key and its allowlist bounds what it can
    //     call.
    class TokenStore
    {
    public:
        // What a presented credential turned out to be.
        struct Credential
        {
            bool ok = false;
            bool expired = false;
            std::string clientName;                        // the policy entry's name, or a token-derived key
            std::optional<std::set<std::string>> allow;    // unset = every tool
        };

        explicit TokenStore( const HttpConfig& cfg ) : cfg_( cfg ) { reload( true ); }

        Credential check( const std::string& presented )
        {
            // One lock only: the reload (mtime check) reads token state,
            // so it happens under the same guard as the compare. A
            // same-thread second lock on this non-recursive mutex aborts
            // on MSVC and deadlocks forever on glibc; do not restore the
            // maybeReload-then-lock shape.
            std::lock_guard<std::mutex> lk( mu_ );
#if !defined( _WIN32 )
            // SIGHUP's forced reload: ignores the mtime check entirely,
            // consumed here (on whatever ordinary request thread happens
            // to call check() next) rather than done on the signal
            // handler's own stack -- see g_sighupReload's own comment.
            if( g_sighupReload.exchange( false, std::memory_order_relaxed ) )
                reload( true );
#endif
            if( !cfg_.authTokenFile.empty() ) reload( false );
            if( presented.empty() ) return Credential{};

            if( !token_.empty() && presented.size() == token_.size() &&
                CRYPTO_memcmp( presented.data(), token_.data(), token_.size() ) == 0 )   // timing-safe
            {
                Credential c;
                c.ok = true;
                // The identity of a deployment-token holder: a short digest
                // of the token, never the token itself.
                c.clientName = "token:" + sha256Hex( presented ).substr( 0, 8 );
                return c;
            }

            if( policies_.empty() ) return Credential{};

            // Per-client credentials: the presented token's SHA-256 against
            // every entry. No early exit: the work per attempt stays the
            // same whether or not the hash matches.
            const std::string hex = sha256Hex( presented );
            Credential out;
            bool known = false;
            for( const PolicyEntry& e : policies_ )
            {
                if( e.sha256.size() != hex.size() ) continue;
                if( CRYPTO_memcmp( e.sha256.data(), hex.data(), hex.size() ) != 0 ) continue;
                known = true;
                if( e.expired() ) { out.expired = true; continue; }
                out.ok = true;
                out.clientName = e.name.empty() ? ( "client:" + hex.substr( 0, 8 ) ) : e.name;
                out.allow = e.allTools ? std::nullopt
                                       : std::optional<std::set<std::string>>( e.tools );
            }
            if( !known ) return Credential{};
            return out;
        }

        static std::string sha256Hex( const std::string& v )
        {
            unsigned char d[ SHA256_DIGEST_LENGTH ];
            SHA256( reinterpret_cast<const unsigned char*>( v.data() ), v.size(), d );
            static const char* const kHex = "0123456789abcdef";
            std::string out;
            for( int i = 0; i < SHA256_DIGEST_LENGTH; ++i )
            { out.push_back( kHex[ d[ i ] >> 4 ] ); out.push_back( kHex[ d[ i ] & 0xF ] ); }
            return out;
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

        // A malformed policy file keeps the last good one and says so; the
        // caller surfaces the message at startup.
        std::string policyError()
        {
            std::lock_guard<std::mutex> lk( mu_ );
            return policyError_;
        }

    private:
        struct PolicyEntry
        {
            std::string name;
            std::string sha256;
            bool allTools = false;
            std::set<std::string> tools;
            std::time_t expiresAt = 0;      // 0 = never expires
            bool expired() const
            {
                if( expiresAt == 0 ) return false;
                return std::time( nullptr ) >= expiresAt;
            }
        };

        // Parses an ISO-8601 expiry: "YYYY-MM-DD" or
        // "YYYY-MM-DDTHH:MM:SSZ". Returns 0 when the text is not a usable
        // expiry, which the caller treats as "no expiry given".
        static std::time_t parseExpiry( const std::string& text )
        {
            if( text.size() < 10 ) return 0;
            std::tm tm{};
            int y = 0, mo = 0, d = 0, h = 0, mi = 0, se = 0;
            if( std::sscanf( text.c_str(), "%d-%d-%dT%d:%d:%d", &y, &mo, &d, &h, &mi, &se ) < 3 &&
                std::sscanf( text.c_str(), "%d-%d-%d", &y, &mo, &d ) < 3 )
                return 0;
            if( y < 1970 || mo < 1 || mo > 12 || d < 1 || d > 31 ) return 0;
            tm.tm_year = y - 1900; tm.tm_mon = mo - 1; tm.tm_mday = d;
            tm.tm_hour = h; tm.tm_min = mi; tm.tm_sec = se;
            return utcToTimeT( tm );
        }

        // UTC calendar time -> time_t. timegm() is POSIX; the MSVC CRT has
        // _mkgmtime() instead.
#if defined( _WIN32 )
        static std::time_t utcToTimeT( std::tm& tm )
        { return static_cast<std::time_t>( _mkgmtime( &tm ) ); }
#else
        static std::time_t utcToTimeT( std::tm& tm )
        { return timegm( &tm ); }
#endif

        void loadPolicyLocked()
        {
            if( cfg_.tokenPolicyFile.empty() ) return;
            std::ifstream in( cfg_.tokenPolicyFile, std::ios::binary );
            if( !in ) { policyError_ = "cannot read " + cfg_.tokenPolicyFile; return; }
            const std::string text( ( std::istreambuf_iterator<char>( in ) ), std::istreambuf_iterator<char>() );
            std::vector<PolicyEntry> next;
            try
            {
                const Json doc = Json::parse( text );
                if( !doc.is_object() || !doc.contains( "tokens" ) || !doc.at( "tokens" ).is_array() )
                    throw std::runtime_error( "expected {\"tokens\":[...]}" );
                for( const Json& t : doc.at( "tokens" ) )
                {
                    PolicyEntry e;
                    if( t.contains( "name" ) && t.at( "name" ).is_string() ) e.name = t.at( "name" ).get<std::string>();
                    e.sha256 = t.at( "sha256" ).get<std::string>();
                    if( e.sha256.size() != 64 ) throw std::runtime_error( "sha256 must be 64 hex digits" );
                    for( char& c : e.sha256 ) c = static_cast<char>( std::tolower( static_cast<unsigned char>( c ) ) );
                    const Json& tools = t.at( "tools" );
                    if( tools.is_string() && tools.get<std::string>() == "*" ) e.allTools = true;
                    else if( tools.is_array() )
                        for( const Json& n : tools ) e.tools.insert( n.get<std::string>() );
                    else throw std::runtime_error( "tools must be \"*\" or an array of tool names" );
                    if( t.contains( "expires" ) && t.at( "expires" ).is_string() )
                    {
                        e.expiresAt = parseExpiry( t.at( "expires" ).get<std::string>() );
                        if( e.expiresAt == 0 )
                            throw std::runtime_error( "expires must be an ISO-8601 date/time (YYYY-MM-DD or YYYY-MM-DDTHH:MM:SSZ)" );
                    }
                    next.push_back( std::move( e ) );
                }
            }
            catch( const std::exception& ex )
            {
                policyError_ = std::string( "FSQL_MCP_TOKEN_POLICY_FILE is not valid: " ) + ex.what();
                return;   // keep the last good policy
            }
            policies_ = std::move( next );
            policyError_.clear();
        }

        // reload() must run with mu_ held; the mtime hot reload
        // happens whenever check() is called on the file-token form.
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
                }
                else
                    return;   // stat failed: keep serving the last known token
            }
            else
                token_ = cfg_.authToken;    // plain env-var form: no hot-reload

            // The policy file is re-read whenever the token file changed or
            // on a forced reload (SIGHUP): it is small and holds no secret.
            if( force || !policyLoaded_ ) { loadPolicyLocked(); policyLoaded_ = true; }
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
        std::vector<PolicyEntry> policies_;
        std::string policyError_;
        bool policyLoaded_ = false;
    };

    // The startup check for the per-client credential file.
    std::string tokenPolicyError( const HttpConfig& cfg )
    {
        TokenStore store( cfg );
        return store.policyError();
    }

    static std::string opensslLastError()    {
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
        static const char* const kHex = "0123456789abcdef";
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

    // Most connections served at once. Each one holds a thread and a
    // descriptor before it has authenticated, so the count is bounded:
    // FSQL_MCP_MAX_CONNECTIONS overrides the default of 256, and on POSIX
    // the result never exceeds half the process's descriptor limit.
    static std::size_t maxConnections()
    {
        long n = 256;
        if( const char* v = std::getenv( "FSQL_MCP_MAX_CONNECTIONS" ) )
        {
            const long x = std::strtol( v, nullptr, 10 );
            if( x > 0 ) n = x;
        }
#ifndef _WIN32
        rlimit rl{};
        if( getrlimit( RLIMIT_NOFILE, &rl ) == 0 && rl.rlim_cur != RLIM_INFINITY && rl.rlim_cur > 8 )
            n = std::min<long>( n, static_cast<long>( rl.rlim_cur / 2 ) );
#endif
        return static_cast<std::size_t>( n );
    }

    // A refused connection is closed only after the peer's request has been
    // read and discarded, so the refusal itself is not lost. The window is
    // long enough for a client that is slow to write its request, and short
    // enough that a refused connection does not hold anything for long.
    static constexpr int kRefusalLingerMs = 1000;

    // How many refusals may be delivering themselves at once. A flood of
    // connections past the limit must not turn into a flood of threads.
    static constexpr int kMaxRefusalsInFlight = 64;
#if !defined( _WIN32 )
    // 13.6: forces a reload, and NOTHING else (the Python HTTP draft's own
    // handler overcaptured and shut the server down too) -- just the
    // atomic store, consumed by TokenStore::matches() on an ordinary
    // request thread; see g_sighupReload's own comment for why.
    static void onSighup( int ) { g_sighupReload.store( true, std::memory_order_relaxed ); }
#endif

    static constexpr std::size_t kMaxHeaderBytes = 64 * 1024;
    static constexpr std::size_t kMaxBodyBytes   = 32 * 1024 * 1024;
    static const char* const kSessionHeader = "Mcp-Session-Id";

    struct HttpRequest
    {
        std::string method, target, version;
        std::map<std::string, std::string> headers;   // lower-cased keys
        // Header names that arrived more than once. The map above keeps the
        // last value, but a header sent twice is ambiguous framing, so the
        // names are remembered and the framing check refuses them.
        std::set<std::string> repeated;
        std::string body;
    };

    static std::string lowerCopy( std::string s )
    {
        std::transform( s.begin(), s.end(), s.begin(),
                        []( unsigned char c ) { return static_cast<char>( std::tolower( c ) ); } );
        return s;
    }

    static std::string trimCopy( const std::string& s )
    {
        const std::size_t b = s.find_first_not_of( " \t\r\n" );
        if( b == std::string::npos ) return "";
        const std::size_t e = s.find_last_not_of( " \t\r\n" );
        return s.substr( b, e - b + 1 );
    }

    // The outcome of reading one request. The distinction matters to the
    // client: a chunked body is answered with 411 (send a Content-Length),
    // an ambiguous framing with 400, an over-limit body with 413, while a
    // closed connection gets no answer at all.
    enum class ReadStatus { Ok, Closed, Chunked, BadFraming, TooLarge };

    // Reads one HTTP/1.1 request (request line, headers, Content-Length body).
    // Chunked transfer coding is deliberately refused: this is a
    // machine-to-machine JSON-RPC endpoint, not a general web server.
    static ReadStatus readHttpRequest( const ConnIo& io, HttpRequest& out )
    {
        std::string raw;
        char buf[ 8192 ];
        std::size_t headerEnd = std::string::npos;

        // The read timeout applies to each recv, so a client sending a byte
        // a minute would hold the thread; the head as a whole gets a deadline.
        const auto headDeadline = std::chrono::steady_clock::now() + std::chrono::seconds( 30 );

        while( headerEnd == std::string::npos )
        {
            const int n = io.recv( buf, static_cast<int>( sizeof( buf ) ) );
            if( n <= 0 ) return ReadStatus::Closed;
            if( std::chrono::steady_clock::now() > headDeadline ) return ReadStatus::Closed;
            raw.append( buf, static_cast<std::size_t>( n ) );
            headerEnd = raw.find( "\r\n\r\n" );
            if( raw.size() > kMaxHeaderBytes ) return ReadStatus::BadFraming;
        }

        std::istringstream head( raw.substr( 0, headerEnd ) );
        std::string line;
        if( !std::getline( head, line ) ) return ReadStatus::BadFraming;
        while( !line.empty() && ( line.back() == '\r' || line.back() == '\n' ) ) line.pop_back();
        { std::istringstream rl( line ); rl >> out.method >> out.target >> out.version; }

        while( std::getline( head, line ) )
        {
            while( !line.empty() && line.back() == '\r' ) line.pop_back();
            const std::size_t colon = line.find( ':' );
            if( colon == std::string::npos ) continue;
            std::string key = line.substr( 0, colon );
            std::string val = line.substr( colon + 1 );
            key = trimCopy( key );
            for( char& c : key ) c = static_cast<char>( std::tolower( static_cast<unsigned char>( c ) ) );
            // A repeated Content-Length is ambiguous framing, not "the last one wins".
            if( key == "content-length" && out.headers.count( key ) ) return ReadStatus::BadFraming;
            // Same idea for every other header name: remember that it arrived
            // twice, so a request whose framing is ambiguous can be refused
            // rather than served with one of the two values.
            if( out.headers.count( key ) ) out.repeated.insert( key );
            std::size_t vb = 0;
            while( vb < val.size() && ( val[ vb ] == ' ' || val[ vb ] == '\t' ) ) ++vb;
            out.headers[ key ] = val.substr( vb );
        }

        const bool hasTransferEncoding = out.headers.count( "transfer-encoding" ) > 0;
        const bool hasContentLength = out.headers.count( "content-length" ) > 0;
        // Both framings at once is a request-smuggling shape: refuse it
        // rather than pick one.
        if( hasTransferEncoding && hasContentLength ) return ReadStatus::BadFraming;
        if( hasTransferEncoding ) return ReadStatus::Chunked;

        std::size_t contentLength = 0;
        if( hasContentLength )
        {
            const std::string& clText = out.headers.find( "content-length" )->second;
            for( char c : clText )
            {
                if( c < '0' || c > '9' ) return ReadStatus::BadFraming;
                contentLength = contentLength * 10 + static_cast<std::size_t>( c - '0' );
                if( contentLength > kMaxBodyBytes ) return ReadStatus::TooLarge;
            }
        }

        out.body = raw.substr( headerEnd + 4 );
        while( out.body.size() < contentLength )
        {
            const int n = io.recv( buf,
                static_cast<int>( std::min<std::size_t>( sizeof( buf ), contentLength - out.body.size() ) ) );
            if( n <= 0 ) return ReadStatus::Closed;
            out.body.append( buf, static_cast<std::size_t>( n ) );
        }
        out.body.resize( contentLength );
        return ReadStatus::Ok;
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
            case 403: return "Forbidden";
            case 404: return "Not Found";
            case 405: return "Method Not Allowed";
            case 411: return "Length Required";
            case 413: return "Content Too Large";
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

    // GET /healthz and /readyz are the ONLY two routes served without
    // authentication (10.3). Returns true iff the request was fully
    // handled (i.e. the caller must not do anything else with it).
    static bool handleUnauthenticatedGet( const ConnIo& io, const std::string& method, const std::string& path,
                                          const std::function<bool()>& readinessProbe )
    {
        if( method != "GET" ) return false;
        if( path == "/healthz" ) { sendHttpJson( io, 200, Json{ { "ok", true } } ); return true; }
        if( path == "/readyz" )
        {
            const bool ready = readinessProbe ? readinessProbe() : false;
            sendHttpJson( io, ready ? 200 : 503,
                          Json{ { "ok", ready }, { "probe", "engine version query" } } );
            return true;
        }
        return false;
    }

    // The RFC 6750 challenge a 401 carries. No scope and no
    // resource_metadata: this server authenticates one bearer token (or a
    // per-client credential from the policy file) and does not implement
    // the OAuth 2.1 resource-server flow.
    static const char* const kAuthRealm = "Bearer realm=\"fractalsql-mcp\"";

    // A JSON-RPC error body for a refusal that happened before the request
    // reached the dispatch core. There is no id to correlate it with, so
    // the body carries none.
    static std::string rpcErrorBody( int code, const std::string& message, const Json& data = Json() )
    {
        Json err{ { "code", code }, { "message", message } };
        if( !data.is_null() ) err[ "data" ] = data;
        return Json{ { "jsonrpc", "2.0" }, { "error", err } }.dump();
    }

    // Extracts the bearer credential from the Authorization header and
    // checks it against the token store (the timing-safe compare lives in
    // TokenStore::check). The presented value is returned via presentedOut
    // but is NEVER logged by any caller.
    //
    // The header is the ONLY place a credential is read from: a token in
    // the URL's query string is not a credential, and the spec forbids
    // putting one there (it ends up in proxy logs and browser history).
    static TokenStore::Credential authenticate( const HttpRequest& req, TokenStore& tokens,
                                               std::string& presentedOut )
    {
        presentedOut.clear();
        auto authIt = req.headers.find( "authorization" );
        const std::string authHeader = authIt == req.headers.end() ? std::string() : authIt->second;
        if( authHeader.rfind( "Bearer ", 0 ) == 0 ) presentedOut = trimCopy( authHeader.substr( 7 ) );
        if( presentedOut.empty() ) return TokenStore::Credential{};
        return tokens.check( presentedOut );
    }

    // True when the origin names a loopback host. The host part is what
    // matters: a page served from http://127.0.0.1:3000 is a loopback
    // origin whatever its port.
    static bool originIsLoopback( const std::string& origin )
    {
        const std::size_t sep = origin.find( "://" );
        if( sep == std::string::npos ) return false;
        std::string host = origin.substr( sep + 3 );
        const std::size_t slash = host.find( '/' );
        if( slash != std::string::npos ) host = host.substr( 0, slash );
        if( !host.empty() && host.front() == '[' )
        {
            const std::size_t close = host.find( ']' );
            if( close == std::string::npos ) return false;
            const std::string inner = host.substr( 1, close - 1 );
            return inner == "::1";
        }
        const std::size_t colon = host.rfind( ':' );
        if( colon != std::string::npos ) host = host.substr( 0, colon );
        if( host == "localhost" ) return true;
        if( host.rfind( "127.", 0 ) == 0 ) return true;
        return false;
    }

    // An Origin header, when present, must be one this deployment allows:
    // a loopback origin by default, plus whatever FSQL_MCP_ALLOWED_ORIGINS
    // lists (browser tools such as the MCP Inspector need their origin
    // there). A request with no Origin header is not a browser request and
    // is allowed through.
    static bool originAllowed( const std::string& origin, const HttpConfig& cfg )
    {
        if( origin.empty() ) return true;
        if( originIsLoopback( origin ) ) return true;
        const std::string o = lowerCopy( trimCopy( origin ) );
        for( const std::string& allowed : cfg.allowedOrigins )
            if( lowerCopy( trimCopy( allowed ) ) == o ) return true;
        return false;
    }

    // base64url decode, for the Mcp-Name header's "=?base64?...?=" form.
    static std::string base64Decode( const std::string& in )
    {
        if( in.empty() ) return std::string();
        // The decoder counts the padding characters as decoded bytes, so the
        // value's length is the decoded length less the padding.
        std::size_t pad = 0;
        while( pad < in.size() && in[ in.size() - 1 - pad ] == '=' ) ++pad;
        std::string out( ( in.size() / 4 + 1 ) * 3 + 3, '\0' );
        const int n = EVP_DecodeBlock( reinterpret_cast<unsigned char*>( &out[ 0 ] ),
                                       reinterpret_cast<const unsigned char*>( in.data() ),
                                       static_cast<int>( in.size() ) );
        if( n < 0 ) return std::string();
        std::size_t len = static_cast<std::size_t>( n );
        if( len >= pad ) len -= pad;   // the padding is not part of the value
        out.resize( len );
        return out;
    }

    // The Mcp-Name header may carry the name in the base64 form the spec
    // allows. Decoded, it is the same string; a value that is not in that
    // form is taken literally.
    static std::string decodeMcpName( const std::string& raw )
    {
        static const std::string kPrefix = "=?base64?";
        const std::string v = trimCopy( raw );
        if( v.rfind( kPrefix, 0 ) != 0 ) return v;
        const std::size_t end = v.rfind( "?=" );
        if( end == std::string::npos || end < kPrefix.size() ) return std::string();
        std::string b64 = v.substr( kPrefix.size(), end - kPrefix.size() );
        for( char& c : b64 ) { if( c == '-' ) c = '+'; else if( c == '_' ) c = '/'; }
        while( b64.size() % 4 != 0 ) b64.push_back( '=' );
        return base64Decode( b64 );
    }

    // The modern era's per-request protocol version, carried in the body's
    // _meta. The spec names it
    // _meta.io.modelcontextprotocol/protocolVersion; the nested spelling is
    // accepted too, because a client that builds _meta as a tree rather
    // than as a namespaced key produces that.
    static std::string modernMetaVersion( const Json& body )
    {
        if( !body.is_object() ) return std::string();
        auto meta = body.find( "_meta" );
        if( meta == body.end() || !meta->is_object() ) return std::string();
        auto it = meta->find( "io.modelcontextprotocol/protocolVersion" );
        if( it != meta->end() && it->is_string() ) return it->get<std::string>();
        auto ns = meta->find( "io.modelcontextprotocol" );
        if( ns != meta->end() && ns->is_object() )
        {
            auto v = ns->find( "protocolVersion" );
            if( v != ns->end() && v->is_string() ) return v->get<std::string>();
        }
        return std::string();
    }

    // A string field of the request's params, or "" when it is absent or
    // not a string. Never throws on a wrongly typed params object.
    static std::string paramsString( const Json& body, const std::string& key )
    {
        auto p = body.find( "params" );
        if( p == body.end() || !p->is_object() ) return std::string();
        auto v = p->find( key );
        if( v == p->end() || !v->is_string() ) return std::string();
        return v->get<std::string>();
    }

    // The revisions the modern protocol era covers. A modern request must
    // name one of them.
    static const std::vector<std::string>& modernProtocolVersions()
    {
        static const std::vector<std::string> v{ "2025-11-25", "2026-07-28" };
        return v;
    }

    // The JSON-RPC methods this server answers. A modern request naming
    // anything else is answered with 404 and -32601; a legacy request keeps
    // the legacy behaviour (the dispatch core answers -32601).
    static bool isKnownRpcMethod( const std::string& m )
    {
        static const char* const kMethods[] = {
            "initialize", "ping", "tools/list", "tools/call",
            "resources/list", "resources/read", "resources/templates/list",
            "prompts/list", "prompts/get", "server/discover", "logging/setLevel",
            "notifications/initialized", "notifications/cancelled", "$/cancel"
        };
        for( const char* k : kMethods ) if( m == k ) return true;
        return false;
    }

    // The outcome of validating a modern-era request's headers against its
    // body.
    struct ModernCheck
    {
        bool ok = true;
        int httpStatus = 200;
        int code = 0;                 // the JSON-RPC error code, 0 = no error
        std::string message;
        Json data = Json();           // the error's data, when it carries any
    };

    // A modern protocol era request must carry MCP-Protocol-Version,
    // Mcp-Method and, where the method addresses something by name,
    // Mcp-Name; and the headers must agree with the body. A disagreement
    // is -32020 (HeaderMismatch), an unsupported revision is -32022
    // (UnsupportedProtocolVersionError).
    static ModernCheck validateModernRequest( const HttpRequest& req, const Json& body,
                                               const std::string& bodyMethod )
    {
        ModernCheck out;

        auto pv = req.headers.find( "mcp-protocol-version" );
        if( pv == req.headers.end() )
        {
            out.ok = false; out.httpStatus = 400; out.code = -32020;
            out.message = "missing MCP-Protocol-Version header: a modern protocol era request "
                          "must name the revision it speaks";
            return out;
        }
        const std::string headerVersion = trimCopy( pv->second );
        const auto& versions = modernProtocolVersions();
        if( std::find( versions.begin(), versions.end(), headerVersion ) == versions.end() )
        {
            out.ok = false; out.httpStatus = 400; out.code = -32022;
            out.message = "unsupported protocol version: " + headerVersion;
            Json supported = Json::array();
            for( const std::string& v : versions ) supported.push_back( v );
            out.data = Json{ { "supported", supported }, { "requested", headerVersion } };
            return out;
        }

        const std::string bodyVersion = modernMetaVersion( body );
        if( bodyVersion.empty() )
        {
            out.ok = false; out.httpStatus = 400; out.code = -32020;
            out.message = "missing _meta.io.modelcontextprotocol/protocolVersion: a modern protocol "
                          "era request carries its revision in the body as well as in the header";
            return out;
        }
        if( bodyVersion != headerVersion )
        {
            out.ok = false; out.httpStatus = 400; out.code = -32020;
            out.message = "header and body disagree about the protocol version: header says "
                          + headerVersion + ", body says " + bodyVersion;
            return out;
        }

        auto mm = req.headers.find( "mcp-method" );
        if( mm == req.headers.end() )
        {
            out.ok = false; out.httpStatus = 400; out.code = -32020;
            out.message = "missing Mcp-Method header: a modern protocol era request must name its method";
            return out;
        }
        if( trimCopy( mm->second ) != bodyMethod )
        {
            out.ok = false; out.httpStatus = 400; out.code = -32020;
            out.message = "header and body disagree about the method: header says '"
                          + trimCopy( mm->second ) + "', body says '" + bodyMethod + "'";
            return out;
        }

        // Mcp-Name, for the methods that address something by name.
        std::string expectedName;
        bool nameRequired = false;
        if( bodyMethod == "tools/call" || bodyMethod == "prompts/get" )
        {
            expectedName = paramsString( body, "name" );
            nameRequired = true;
        }
        else if( bodyMethod == "resources/read" )
        {
            expectedName = paramsString( body, "uri" );
            nameRequired = true;
        }
        if( nameRequired )
        {
            auto mn = req.headers.find( "mcp-name" );
            if( mn == req.headers.end() )
            {
                out.ok = false; out.httpStatus = 400; out.code = -32020;
                out.message = "missing Mcp-Name header: " + bodyMethod + " must name what it addresses";
                return out;
            }
            const std::string headerName = decodeMcpName( mn->second );
            if( headerName != expectedName )
            {
                out.ok = false; out.httpStatus = 400; out.code = -32020;
                out.message = "header and body disagree about the name: header says '" + headerName
                              + "', body says '" + expectedName + "'";
                return out;
            }
        }
        return out;
    }

    // GET requests other than /healthz,/readyz, reached only once the
    // caller has already authenticated: cfg.path replies 405 (GET is not
    // how this server is used), anything else is 404.
    static void handleAuthenticatedGet( const ConnIo& io, const std::string& path, const HttpConfig& cfg )
    {
        if( path == cfg.path )
            sendHttpJson( io, 405, Json{ { "error",
                "GET /mcp is not used by this server; POST JSON-RPC 2.0 messages" } } );
        else
            sendHttpJson( io, 404, Json{ { "error", "not found" } } );
    }

    // The per-client state registry. Two kinds of entry live here:
    //
    //  - a protocol session (the legacy era's Mcp-Session-Id), which owns a
    //    fairness key and an engine context;
    //  - an engine context (the modern era's explicit context_id handle),
    //    which owns a dedicated engine connection.
    //
    // Both are capped (FSQL_MCP_MAX_SESSIONS, default 64) and expire when
    // idle (FSQL_MCP_SESSION_TTL_SECS, default 3600), so the map -- and the
    // SQLite connections behind it -- cannot grow without bound. Every
    // context is bound to the fingerprint of the credential that created
    // it: another token is told the handle does not exist, so a client can
    // neither use nor probe for a handle it does not own.
    class ClientState
    {
    public:
        struct Session
        {
            std::string clientKey;    // the fairness key
            std::string contextId;    // the engine context this session owns
            std::chrono::steady_clock::time_point lastUse;
        };
        struct Context
        {
            std::string connKey;      // the engine connection key
            std::string ownerFp;      // the fingerprint of the creating credential
            std::chrono::steady_clock::time_point lastUse;
        };

        std::mutex mu;
        std::map<std::string, Session> sessions;
        std::map<std::string, Context> contexts;
    };

    // How long an idle session or context survives, and how many may exist
    // at once. Both default to the values the design documents.
    static long sessionTtlSeconds()
    {
        const char* v = std::getenv( "FSQL_MCP_SESSION_TTL_SECS" );
        const long n = ( v && *v ) ? std::atol( v ) : 3600;
        return n > 0 ? n : 3600;
    }
    static std::size_t maxSessions()
    {
        const char* v = std::getenv( "FSQL_MCP_MAX_SESSIONS" );
        const long n = ( v && *v ) ? std::atol( v ) : 64;
        return static_cast<std::size_t>( n > 0 ? n : 64 );
    }

    // A context handle: 128 bits of randomness, hex.
    static std::string mintContextId()
    {
        unsigned char rnd[ 16 ] = {};
        if( RAND_bytes( rnd, sizeof( rnd ) ) != 1 )
        {
            RAND_poll();
            ( void ) RAND_bytes( rnd, sizeof( rnd ) );
        }
        static const char* const kHex = "0123456789abcdef";
        std::string out;
        for( unsigned char c : rnd )
        {
            out.push_back( kHex[ c >> 4 ] );
            out.push_back( kHex[ c & 0xF ] );
        }
        return out;
    }

    // Drops the idle sessions and contexts and reports the connections the
    // caller has to close. The caller closes them outside the lock.
    static void expireLocked( ClientState& state, std::vector<std::string>& expiredConnKeys )
    {
        const auto now = std::chrono::steady_clock::now();
        const auto ttl = std::chrono::seconds( sessionTtlSeconds() );
        for( auto it = state.sessions.begin(); it != state.sessions.end(); )
        {
            if( now - it->second.lastUse > ttl ) it = state.sessions.erase( it );
            else ++it;
        }
        for( auto it = state.contexts.begin(); it != state.contexts.end(); )
        {
            if( now - it->second.lastUse > ttl )
            {
                expiredConnKeys.push_back( it->second.connKey );
                it = state.contexts.erase( it );
            }
            else ++it;
        }
    }

    // Finds the context a request names, or mints one when it names none.
    // Returns false when the handle does not exist or belongs to another
    // credential: the caller answers "not found" either way.
    static bool resolveContext( ClientState& state, const std::string& requested, const std::string& ownerFp,
                                std::string& contextIdOut, std::string& connKeyOut,
                                std::vector<std::string>& expiredConnKeys )
    {
        std::lock_guard<std::mutex> lk( state.mu );
        expireLocked( state, expiredConnKeys );
        const auto now = std::chrono::steady_clock::now();
        if( !requested.empty() )
        {
            auto it = state.contexts.find( requested );
            if( it == state.contexts.end() || it->second.ownerFp != ownerFp ) return false;
            it->second.lastUse = now;
            contextIdOut = requested;
            connKeyOut = it->second.connKey;
            return true;
        }
        const std::string id = mintContextId();
        // The connection key is derived from the handle, so two contexts
        // never share a connection.
        const std::string connKey = "ctx:" + id;
        state.contexts[ id ] = ClientState::Context{ connKey, ownerFp, now };
        contextIdOut = id;
        connKeyOut = connKey;
        return true;
    }

    // Failed-auth backoff: each failure stalls its own connection thread for a growing interval (capped at 2 s),
    // which throttles online token guessing without a lockout an attacker could turn against legitimate clients.
    // A success pays one failure back.
    static std::atomic<int>& authFailureCounter() { static std::atomic<int> n{ 0 }; return n; }
    static void authFailed()
    {
        const int fails = std::min( authFailureCounter().fetch_add( 1 ) + 1, 20 );
        std::this_thread::sleep_for( std::chrono::milliseconds( fails * 100 ) );
    }
    static void authOk()
    {
        int f = authFailureCounter().load();
        while( f > 0 && !authFailureCounter().compare_exchange_weak( f, f - 1 ) ) {}
    }

    // A session belongs to the credential that created it: the fingerprint
    // of the token presenting the CURRENT request (set by the connection
    // thread right after authentication) is compared with the fingerprint
    // stored with the session and with the fingerprint stored with its
    // context. Another token can neither adopt nor close a session, and
    // cannot use another token's context handle.
    static thread_local std::string t_callerFp;
    static std::string tokenFingerprint( const std::string& bearer )
    {
        unsigned char d[ SHA256_DIGEST_LENGTH ];
        SHA256( reinterpret_cast<const unsigned char*>( bearer.data() ), bearer.size(), d );
        static const char* const kHex = "0123456789abcdef";
        std::string out;
        for( int i = 0; i < 16; ++i ) { out.push_back( kHex[ d[ i ] >> 4 ] ); out.push_back( kHex[ d[ i ] & 0xF ] ); }
        return out;
    }

    // DELETE cfg.path with a known Mcp-Session-Id tears the session down
    // (11.2's closeSession hook) and acks 200; anything else is 404.
    static void handleDelete( const ConnIo& io, const std::string& path, const std::string& sessionId,
                              const HttpConfig& cfg, ClientState& state,
                              const std::function<void( const std::string& )>& closeSession )
    {
        if( path == cfg.path && !sessionId.empty() )
        {
            std::string connKey;
            bool owned = false;
            {
                std::lock_guard<std::mutex> lk( state.mu );
                auto sit = state.sessions.find( sessionId );
                if( sit != state.sessions.end() )
                {
                    auto cit = state.contexts.find( sit->second.contextId );
                    if( cit != state.contexts.end() && cit->second.ownerFp == t_callerFp )
                    {
                        connKey = cit->second.connKey;
                        owned = true;
                        state.contexts.erase( cit );
                        state.sessions.erase( sit );
                    }
                }
            }
            if( owned )
            {
                if( closeSession ) closeSession( connKey );
                sendHttpJson( io, 200, Json{ { "ok", true } } );
            }
            else
                sendHttpJson( io, 404, Json{ { "error", "not found" } } );
        }
        else
            sendHttpJson( io, 404, Json{ { "error", "not found" } } );
    }

    // Looks up sessionId's fairness client key and the engine context it
    // owns. Sends 400 when the header is missing, 404 when it names an
    // unknown session or one that belongs to another credential, and
    // returns false in both cases so the caller returns without dispatching.
    static bool resolveSession( const ConnIo& io, ClientState& state, const std::string& sessionId,
                                std::string& clientKeyOut, std::string& contextIdOut, std::string& connKeyOut )
    {
        if( sessionId.empty() )
        {
            sendHttpJson( io, 400, Json{ { "error", "missing Mcp-Session-Id (initialize first)" } } );
            return false;
        }
        std::lock_guard<std::mutex> lk( state.mu );
        auto sit = state.sessions.find( sessionId );
        if( sit == state.sessions.end() )
        {
            sendHttpJson( io, 404, Json{ { "error", "unknown session (deleted or never initialized)" } } );
            return false;
        }
        auto cit = state.contexts.find( sit->second.contextId );
        if( cit == state.contexts.end() || cit->second.ownerFp != t_callerFp )
        {
            // The session exists but belongs to another credential: it is
            // reported as unknown, so a client cannot tell the difference.
            sendHttpJson( io, 404, Json{ { "error", "unknown session (deleted or never initialized)" } } );
            return false;
        }
        const auto now = std::chrono::steady_clock::now();
        sit->second.lastUse = now;
        cit->second.lastUse = now;
        clientKeyOut = sit->second.clientKey;
        contextIdOut = sit->second.contextId;
        connKeyOut = cit->second.connKey;
        return true;
    }

    // initialize must not carry a session id; mints one, registers its
    // fairness/dispatch client key and its engine context, and dispatches.
    // 200 w/ Mcp-Session-Id header + body on a substantive response, 202
    // (same header) otherwise.
    static void handleInitialize( const ConnIo& io, const HttpRequest& req, const std::string& sessionId,
                                  const std::string& presented, const HttpConfig& cfg, JsonRpcServer& server,
                                  ClientState& state,
                                  const std::function<void( const std::string& )>& closeSession,
                                  const std::function<void( const std::string& )>& selectSession,
                                  const TokenStore::Credential& cred )
    {
        if( !sessionId.empty() )
        {
            sendHttpJson( io, 400, Json{ { "error", "initialize must not carry a session id" } } );
            return;
        }
        const std::string minted = randomSessionId();
        const std::string clientKey = TokenStore::clientKeyFor( cfg, presented, minted );
        std::vector<std::string> expiredConnKeys;
        std::string contextId;
        {
            std::lock_guard<std::mutex> lk( state.mu );
            expireLocked( state, expiredConnKeys );
            if( state.contexts.size() >= maxSessions() )
            {
                for( const std::string& k : expiredConnKeys ) if( closeSession ) closeSession( k );
                sendHttpJson( io, 503, Json{ { "error", "too many open MCP sessions" } } );
                return;
            }
            contextId = mintContextId();
            state.contexts[ contextId ] = ClientState::Context{ "ctx:" + contextId, t_callerFp,
                                                                std::chrono::steady_clock::now() };
            state.sessions[ minted ] = ClientState::Session{ clientKey, contextId,
                                                              std::chrono::steady_clock::now() };
        }
        for( const std::string& k : expiredConnKeys ) if( closeSession ) closeSession( k );
        if( selectSession ) selectSession( "ctx:" + contextId );
        CallOptions opts;
        opts.era = ProtocolEra::Legacy;
        opts.toolAllow = cred.allow;
        auto resp = server.handleLine( req.body, clientKey, opts );
        std::map<std::string, std::string> extra;
        extra[ kSessionHeader ] = minted;
        if( resp ) sendHttp( io, 200, *resp, "application/json", extra );
        else sendHttp( io, 202, "", "text/plain", extra );
    }

    // Cancel notifications ride the already-authenticated session and
    // never produce a substantive response (202 ack only), per 1.1.
    static void handleCancelNotification( const ConnIo& io, const HttpRequest& req, const std::string& sessionId,
                                          JsonRpcServer& server, ClientState& state,
                                          const std::function<void( const std::string& )>& selectSession )
    {
        std::string clientKey, contextId, connKey;
        if( !resolveSession( io, state, sessionId, clientKey, contextId, connKey ) ) return;
        if( selectSession ) selectSession( connKey );
        server.handleLine( req.body, clientKey );   // notification: nullopt by design
        sendHttp( io, 202, "", "text/plain" );
    }

    // Ordinary JSON-RPC call/notification on an already-initialized session.
    static void handleDispatch( const ConnIo& io, const HttpRequest& req, const std::string& sessionId,
                               bool isRequest, JsonRpcServer& server, ClientState& state,
                               const std::function<void( const std::string& )>& selectSession,
                               const TokenStore::Credential& cred )
    {
        std::string clientKey, contextId, connKey;
        if( !resolveSession( io, state, sessionId, clientKey, contextId, connKey ) ) return;
        if( selectSession ) selectSession( connKey );
        CallOptions opts;
        opts.era = ProtocolEra::Legacy;
        opts.toolAllow = cred.allow;
        auto resp = server.handleLine( req.body, clientKey, opts );
        if( resp )
            sendHttp( io, 200, *resp, "application/json" );
        else
            // notification, or a cancelled request whose result is
            // discarded: per 1.1, nothing of substance is delivered.
            sendHttp( io, isRequest ? 200 : 202, "", "text/plain" );
    }

    // A modern era request: stateless, no protocol session. The engine
    // context comes from the request's own context_id argument when the
    // call addresses a stateful tool; otherwise the call runs on the
    // credential's own connection.
    static void handleModernDispatch( const ConnIo& io, const HttpRequest& req, const Json& body,
                                      const std::string& bodyMethod, bool isRequest,
                                      JsonRpcServer& server, ClientState& state,
                                      const std::function<void( const std::string& )>& selectSession,
                                      const std::function<void( const std::string& )>& closeSession,
                                      const TokenStore::Credential& cred )
    {
        const ModernCheck check = validateModernRequest( req, body, bodyMethod );
        if( !check.ok )
        {
            sendHttp( io, check.httpStatus, rpcErrorBody( check.code, check.message, check.data ),
                      "application/json" );
            return;
        }
        if( !isKnownRpcMethod( bodyMethod ) )
        {
            sendHttp( io, 404, rpcErrorBody( -32601, "method not found: " + bodyMethod ),
                      "application/json" );
            return;
        }

        // The engine context: the request's own handle when it names one
        // and the tool is stateful, otherwise a fresh handle, and the
        // credential's own connection for a tool that keeps no state.
        const std::string toolName = ( bodyMethod == "tools/call" ) ? paramsString( body, "name" ) : std::string();
        const bool stateful = !toolName.empty() && isContextScopedTool( toolName );
        std::string requestedContext;
        if( stateful )
        {
            auto p = body.find( "params" );
            if( p != body.end() && p->is_object() )
            {
                auto a = p->find( "arguments" );
                if( a != p->end() && a->is_object() )
                {
                    auto c = a->find( "context_id" );
                    if( c != a->end() && c->is_string() ) requestedContext = c->get<std::string>();
                }
            }
        }

        std::string contextId, connKey;
        std::vector<std::string> expiredConnKeys;
        if( stateful )
        {
            if( !resolveContext( state, requestedContext, t_callerFp, contextId, connKey, expiredConnKeys ) )
            {
                for( const std::string& k : expiredConnKeys ) if( closeSession ) closeSession( k );
                sendHttpJson( io, 404, Json{ { "error",
                    "unknown context handle: it does not exist, or it belongs to another credential" } } );
                return;
            }
        }
        else
            connKey = "cred:" + cred.clientName;
        for( const std::string& k : expiredConnKeys ) if( closeSession ) closeSession( k );

        if( selectSession ) selectSession( connKey );
        CallOptions opts;
        opts.era = ProtocolEra::Modern;
        opts.contextId = stateful ? contextId : std::string();
        opts.toolAllow = cred.allow;
        auto resp = server.handleLine( req.body, cred.clientName, opts );
        if( resp )
            sendHttp( io, 200, *resp, "application/json" );
        else
            // a notification: 202 and nothing of substance.
            sendHttp( io, isRequest ? 200 : 202, "", "text/plain" );
    }

    int runHttpTransport( JsonRpcServer& server, const HttpConfig& cfg,
                          std::function<bool()> readinessProbe,
                          std::function<void( const std::string& sessionId )> closeSession,
                          std::function<void( const std::string& connKey )> selectSession )
    {
        net::init();
        // Detached connection threads capture these by reference and may
        // outlive the bounded drain/grace waits below (a slow in-flight
        // call), so they must never be destroyed while the process lives:
        // intentionally leaked, reclaimed by process exit.
        TokenStore& tokens = *new TokenStore( cfg );
#if !defined( _WIN32 )
        std::signal( SIGHUP, onSighup );   // 13.6: forces reload, never shutdown
        // A write to a peer that has already gone raises SIGPIPE, whose default action ends the process
        // without a word: one impatient client would take every other connection down with it. The write
        // error is handled where it happens (net::send also passes MSG_NOSIGNAL; this covers TLS writes).
        std::signal( SIGPIPE, SIG_IGN );
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

        if( !sslCtx && !( cfg.host.empty() || cfg.host == "localhost" || cfg.host == "::1" || cfg.host.rfind( "127.", 0 ) == 0 ) )
        {
            std::cerr << "WARNING: the HTTP transport is bound to non-loopback address '" << cfg.host
                      << "' WITHOUT TLS; the bearer token and all results travel in clear text (set FSQL_MCP_HTTPS=true)\n";
            const char* allowPlain = std::getenv( "FSQL_MCP_ALLOW_PLAINTEXT_NONLOOPBACK" );
            if( !( allowPlain && *allowPlain && std::string( allowPlain ) != "0" && std::string( allowPlain ) != "false" ) )
            {
                std::cerr << "refusing a non-loopback HTTP bind without TLS (set FSQL_MCP_HTTPS=true, or FSQL_MCP_ALLOW_PLAINTEXT_NONLOOPBACK=true to accept the risk)\n";
                net::shutdownNet();
                return 1;
            }
        }
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

        ClientState& state = *new ClientState;   // the per-client sessions and engine contexts
        std::atomic<int>& liveConnections = *new std::atomic<int>{ 0 };   // for the bounded post-drain grace below
        std::atomic<int>& refusalsInFlight = *new std::atomic<int>{ 0 };  // refusals still delivering themselves

        const std::size_t connLimit = maxConnections();
        logging::event( "http_max_connections", Json{ { "limit", connLimit } } );

        while( !g_httpSignalled.load() )
        {
            if( !net::waitForConnection( listenSock, 250 ) ) continue;
            net::Socket conn = net::accept( listenSock );
            if( net::isInvalid( conn ) )
            {
                if( g_httpSignalled.load() ) break;
                // Out of descriptors, an aborted connection: keep serving,
                // without spinning while the listener stays readable.
                std::this_thread::sleep_for( std::chrono::milliseconds( 10 ) );
                continue;
            }

            if( static_cast<std::size_t>( liveConnections.load() ) >= connLimit )
            {
                // Over the limit: refuse before spending a thread on it. A TLS
                // client cannot read a plaintext reply, so it just sees the close.
                if( !cfg.tlsEnabled )
                {
                    static const char kBusy[] = "HTTP/1.1 503 Service Unavailable\r\nRetry-After: 1\r\n"
                                                "Content-Length: 0\r\nConnection: close\r\n\r\n";
                    net::send( conn, kBusy, static_cast<int>( sizeof( kBusy ) - 1 ) );
                    // The refusal is finished on its own short-lived thread:
                    // draining the peer's request takes a moment, and the
                    // accept loop must keep accepting while it does.
                    if( refusalsInFlight.fetch_add( 1 ) < kMaxRefusalsInFlight )
                    {
                        std::thread( [ conn, &refusalsInFlight ] {
                            net::closeAfterReply( conn, kRefusalLingerMs );
                            refusalsInFlight.fetch_sub( 1 );
                        } ).detach();
                    }
                    else
                    {
                        refusalsInFlight.fetch_sub( 1 );
                        net::close( conn );
                    }
                }
                else
                    net::close( conn );
                continue;
            }

            // One thread per connection; concurrency is bounded by the
            // ConcurrencyManager caps, not by thread count (13.3.4/10.7). The
            // long Cognition/Agency call runs on this thread, and the HTTP
            // response simply waits (the contract's "joined before the response
            // is written"). Deliberately detached: every response is written
            // with Connection: close, so each thread is short-lived and ends
            // right after its write; the accept loop keeps accepting.
            liveConnections.fetch_add( 1 );
            std::thread( [ conn, &server, &tokens, cfg, &state,
                           &liveConnections, readinessProbe, closeSession, selectSession, sslCtx ]
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

                // One request per connection: every response below is sent
                // with "Connection: close" and the socket closes right
                // after the handler, so the request body runs at most once
                // per connection — an if, not a loop. The body lives in a
                // lambda so its per-path early exits (return) keep the
                // shape of the loop this used to be.
                HttpRequest req;
                auto handleRequest = [ & ]() -> void
                {
                    const std::string path = req.target.substr( 0, req.target.find( '?' ) );
                    std::string presented;
                    const TokenStore::Credential cred = authenticate( req, tokens, presented );

                    // The ONLY two unauthenticated paths (10.3).
                    if( handleUnauthenticatedGet( io, req.method, path, readinessProbe ) ) return;

                    // Origin validation: a browser origin that this
                    // deployment does not allow is refused before the request
                    // is looked at any further.
                    const auto originIt = req.headers.find( "origin" );
                    const std::string origin = originIt == req.headers.end() ? std::string() : trimCopy( originIt->second );
                    if( !originAllowed( origin, cfg ) )
                    {
                        sendHttp( io, 403, rpcErrorBody( -32000,
                            "origin not allowed: " + origin + " is not a loopback origin and is not "
                            "listed in FSQL_MCP_ALLOWED_ORIGINS" ), "application/json" );
                        return;
                    }

                    if( !cred.ok )
                    {
                        // 401 BEFORE the request reaches the adapter layer.
                        // The presented value is never logged. The challenge
                        // names the realm; a token that WAS presented but is
                        // wrong or expired also says why.
                        authFailed();
                        std::map<std::string, std::string> extra;
                        extra[ "WWW-Authenticate" ] = std::string( kAuthRealm ) +
                            ( presented.empty() ? "" : ", error=\"invalid_token\"" );
                        sendHttpJson( io, 401, Json{ { "error",
                            presented.empty() ? "missing bearer token" : "invalid bearer token" } }, extra );
                        return;
                    }

                    authOk();
                    t_callerFp = tokenFingerprint( presented );

                    auto sidIt = req.headers.find( "mcp-session-id" );
                    const std::string sessionId = sidIt == req.headers.end() ? std::string() : sidIt->second;

                    // A modern era request carries the modern protocol
                    // version header (and the matching _meta in its body).
                    // The legacy era has neither.
                    const bool modernByHeader = req.headers.count( "mcp-protocol-version" ) > 0;

                    if( req.method == "GET" || req.method == "DELETE" )
                    {
                        // The modern era has no GET stream and no session
                        // teardown, so both are refused for a modern request.
                        if( modernByHeader || modernEraOnly() )
                        {
                            sendHttpJson( io, 405, Json{ { "error",
                                req.method == "GET"
                                    ? "GET is not used by the modern protocol era; POST JSON-RPC 2.0 messages"
                                    : "DELETE is not used by the modern protocol era; it has no protocol session to tear down" } } );
                            return;
                        }
                        if( req.method == "GET" ) { handleAuthenticatedGet( io, path, cfg ); return; }
                        handleDelete( io, path, sessionId, cfg, state, closeSession );
                        return;
                    }

                    if( req.method != "POST" || path != cfg.path )
                    {
                        sendHttpJson( io, req.method == "POST" ? 404 : 405,
                                      Json{ { "error", req.method == "POST" ? "not found" : "method not allowed" } } );
                        return;
                    }

                    if( server.isShuttingDown() )
                    {
                        sendHttpJson( io, 503, Json{ { "error", "server shutting down (retry after restart)" } } );
                        return;
                    }

                    Json bodyJson = jsonNestsTooDeep( req.body )
                        ? Json( Json::value_t::discarded )
                        : Json::parse( req.body, nullptr, false );
                    const bool parsed = !bodyJson.is_discarded() && bodyJson.is_object();
                    // value() throws type_error.302 on a non-string "method"; on this
                    // connection thread that is std::terminate for the whole server.
                    const std::string method = ( parsed && bodyJson.contains( "method" ) && bodyJson[ "method" ].is_string() )
                        ? bodyJson[ "method" ].get<std::string>() : std::string();
                    const bool isRequest = parsed && bodyJson.contains( "id" );
                    const bool isInitialize = method == "initialize";
                    const bool isCancel = ( method == "notifications/cancelled" || method == "$/cancel" );

                    if( !parsed || req.body.empty() || req.body.size() > kMaxBodyBytes )
                    {
                        // A body that is not a JSON-RPC message is a parse
                        // error, and the JSON-RPC error object says so.
                        sendHttp( io, 400, rpcErrorBody( -32700,
                            "parse error: the request body is not a JSON-RPC 2.0 message" ),
                            "application/json" );
                        return;
                    }

                    // The era of this request. "initialize" is the legacy
                    // handshake and always selects the legacy flow; anything
                    // else is modern when it carries the modern metadata or
                    // the modern version header.
                    const bool isModern = !isInitialize &&
                        ( modernByHeader || !modernMetaVersion( bodyJson ).empty() );

                    if( modernEraOnly() && !isModern )
                    {
                        // A modern-only server refuses the legacy era
                        // outright, and says which revisions it speaks.
                        sendHttp( io, 400, rpcErrorBody( -32000,
                            "this server speaks the modern protocol era only (FSQL_MCP_PROTOCOL_ERA=modern); "
                            "the legacy initialize handshake and the legacy session headers are refused. "
                            "Supported versions: 2025-11-25, 2026-07-28" ), "application/json" );
                        return;
                    }

                    if( isModern )
                    {
                        handleModernDispatch( io, req, bodyJson, method, isRequest, server, state,
                                              selectSession, closeSession, cred );
                        return;
                    }

                    // Session isolation: initialize mints the session id
                    // (and must not arrive with one); every other request
                    // presents a valid one (400 missing, 404 unknown).
                    if( isInitialize )
                    {
                        handleInitialize( io, req, sessionId, presented, cfg, server, state,
                                          closeSession, selectSession, cred );
                        return;
                    }

                    if( isCancel && !isRequest )
                    {
                        handleCancelNotification( io, req, sessionId, server, state, selectSession );
                        return;
                    }

                    handleDispatch( io, req, sessionId, isRequest, server, state, selectSession, cred );
                };
                // A request refused before its body was read leaves that body on the socket. Closing a socket
                // with unread data makes the kernel reset the connection, and the reset discards the reply that
                // was just written: the client sees a broken connection instead of the 4xx it was owed. Those
                // replies are followed by a lingering close, which half-closes, then reads and drops the rest.
                bool refusedUnread = false;
                if( !g_httpSignalled.load() )
                {
                    const ReadStatus status = readHttpRequest( io, req );
                    switch( status )
                    {
                        case ReadStatus::Ok:
                            handleRequest();
                            break;
                        case ReadStatus::Chunked:
                            refusedUnread = true;
                            // The body has no length: the client has to send
                            // a Content-Length.
                            sendHttpJson( io, 411, Json{ { "error",
                                "a chunked request body is not accepted; send Content-Length" } } );
                            break;
                        case ReadStatus::TooLarge:
                            refusedUnread = true;
                            sendHttpJson( io, 413, Json{ { "error", "request body too large" } } );
                            break;
                        case ReadStatus::BadFraming:
                            refusedUnread = true;
                            sendHttpJson( io, 400, Json{ { "error",
                                "ambiguous request framing (repeated or malformed Content-Length)" } } );
                            break;
                        case ReadStatus::Closed:
                            break;   // the client went away: nothing to answer
                    }
                }
                if( refusedUnread && !ssl ) net::closeAfterReply( conn, kRefusalLingerMs );   // closes the socket
                else closeConn();
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
            while( ( liveConnections.load() > 0 || refusalsInFlight.load() > 0 )
                   && std::chrono::steady_clock::now() < graceDeadline )
                std::this_thread::sleep_for( std::chrono::milliseconds( 20 ) );
        }
        std::vector<std::string> keys;
        { std::lock_guard<std::mutex> lk( state.mu );
          for( const auto& kv : state.contexts ) keys.push_back( kv.second.connKey ); }
        for( const std::string& key : keys )
            if( closeSession ) closeSession( key );

        net::shutdownNet();
        logging::event( "shutdown_complete", Json{ { "transport", "http" } } );
        return 0;
    }
}