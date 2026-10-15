// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#pragma once
#include <string>
#include <string_view>
#include <stdexcept>
#include "mcp_json.h"

namespace fsqlmcp
{
    // The error taxonomy: five classes (Cancelled extends the standard four).
    enum class ErrorClass
    {
        Schema,         // bad inputSchema match; rejected before any connection touched
        Engine,         // the call reached the engine; its own documented error path fired
        Connectivity,   // DB/daemon/LLM-provider unreachable or timed out; not the caller's fault
        Cancelled,      // client sent $/cancel; result (if any) must never be delivered
        ServerInternal  // adapter-layer bug; full detail logged server-side only
    };

    inline const char* errorClassName( ErrorClass c )
    {
        switch( c )
        {
            case ErrorClass::Schema:         return "schema";
            case ErrorClass::Engine:         return "engine";
            case ErrorClass::Connectivity:   return "connectivity";
            case ErrorClass::Cancelled:      return "cancelled";
            case ErrorClass::ServerInternal: return "server";
        }
        return "server";
    }

    class ToolError : public std::runtime_error
    {
    public:
        ToolError( ErrorClass cls, std::string msg, std::string detail = "" )
            : std::runtime_error( msg ), errorClass( cls ),
              message( std::move( msg ) ), detail( std::move( detail ) )
        {
        }

        // 11.1: ServerInternal never echoes its real message/detail to the client,
        // only errorClassName()+a fixed generic string. Everything else is verbatim.
        Json clientPayload() const
        {
            if( errorClass == ErrorClass::ServerInternal )
            {
                return Json{
                    { "error_class", errorClassName( errorClass ) },
                    { "message", "internal server error (server-side log carries the detail); retry later or alert the operator" }
                };
            }
            return Json{ { "error_class", errorClassName( errorClass ) }, { "message", message } };
        }

        ErrorClass  errorClass;
        std::string message;
        std::string detail;      // server-log-only; never sent to the client
    };

    // 11.3: a single shared sanitizer every adapter's catch-block MUST call before
    // any caught exception's text reaches a log line. Masks user:password@ URI
    // segments (username kept) and KEY=value-shaped credential fragments.
    std::string sanitizeSecrets( std::string_view text );
}