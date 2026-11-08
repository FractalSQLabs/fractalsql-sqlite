// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#pragma once
#include <string>
#include <vector>
#include <functional>
#include "jsonrpc_server.h"

namespace fsqlmcp
{
    struct HttpConfig
    {
        std::string host = "127.0.0.1";   // FSQL_MCP_HTTP_HOST
        int port = 8765;                  // FSQL_MCP_HTTP_PORT / --http
        std::string path = "/mcp";        // FSQL_MCP_HTTP_PATH
        std::string authToken;            // FSQL_MCP_AUTH_TOKEN
        std::string authTokenFile;        // FSQL_MCP_AUTH_TOKEN_FILE (hot-reloaded, 10.3)
        // Per-client credentials (FSQL_MCP_TOKEN_POLICY_FILE): a JSON file
        // naming clients, each with the SHA-256 of its token, an optional
        // expiry and an optional tool allowlist. The file holds no secret.
        std::string tokenPolicyFile;
        // Browser origins allowed to call this server (FSQL_MCP_ALLOWED_ORIGINS),
        // comma-separated. Loopback origins are always allowed.
        std::vector<std::string> allowedOrigins;
        int shutdownDrainMs = 5000;
        // Direct TLS (--https / FSQL_MCP_HTTPS) is optional and OFF by
        // default: the documented, zero-config posture from 10.3 remains
        // TLS terminating in FRONT of this server (reverse proxy or LB),
        // this process speaking plaintext HTTP only behind that proxy. When
        // tlsEnabled is set, this process terminates TLS itself using the
        // given PEM cert/key, via the OpenSSL this binary already links for
        // the schema-lock hashing; both modes authenticate with the same
        // Bearer-token check either way, so TLS is never a substitute for
        // the token.
        bool tlsEnabled = false;      // --https / FSQL_MCP_HTTPS
        std::string tlsCertFile;      // --tls-cert / FSQL_MCP_TLS_CERT_FILE (PEM, chain OK)
        std::string tlsKeyFile;       // --tls-key / FSQL_MCP_TLS_KEY_FILE (PEM, unencrypted)
    };

    // Minimal threaded HTTP/1.1 listener (no Boost.Asio/libuv, per 7.0). Every
    // path except GET /healthz and GET /readyz requires a valid Bearer token
    // (10.3). One dedicated DB session per Mcp-Session-Id (1.1's per-client
    // isolation requirement). closeSession is the factory hook into the
    // engine's db layer (14.1's "session creation plugs into db.h via a
    // factory the caller supplies"); readinessProbe backs /readyz;
    // selectSession binds the calling thread to the engine connection that
    // serves this request (the legacy era's session id, the modern era's
    // context handle, or the caller's own connection).
    int runHttpTransport( JsonRpcServer& server, const HttpConfig& cfg,
                          std::function<bool()> readinessProbe,
                          std::function<void( const std::string& sessionId )> closeSession,
                          std::function<void( const std::string& connKey )> selectSession );

    // The startup check for the per-client credential file: an empty string
    // means the file is absent or valid; a non-empty one says what is wrong
    // with it. A credential file that cannot be read or parsed is a startup
    // failure, never a silent "no authentication".
    std::string tokenPolicyError( const HttpConfig& cfg );
}