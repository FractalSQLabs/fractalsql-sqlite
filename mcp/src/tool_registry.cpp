// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#include "tool_registry.h"

namespace fsqlmcp
{
    // validate -> handler -> classify -> always log (13.3.3). Tool-level errors
    // keep their class and are converted to isError-shaped results by the
    // server layer; engine messages travel verbatim (1.6).
    Json runTool( const ToolSpec& spec, const Json& args, CallCtx& ctx )
    {
        const auto t0 = std::chrono::steady_clock::now();
        const char* errClass = nullptr;
        struct LogGuard
        {
            const ToolSpec& spec; const Json& args; const char*& errClass;
            std::chrono::steady_clock::time_point t0;
            ~LogGuard()
            {
                const double ms = std::chrono::duration<double, std::milli>(
                    std::chrono::steady_clock::now() - t0 ).count();
                logging::toolCall( spec.name, logging::redactAndCap( args ), ms, errClass );
            }
        } guard{ spec, args, errClass, t0 };

        try
        {
            validateArgs( spec, args );
            Json result = spec.handler( args, ctx );
            if( ctx.cancelled )
                throw ToolError( ErrorClass::Cancelled, "call was cancelled by the client" );
            return result;
        }
        catch( const ToolError& e )
        {
            errClass = errorClassName( e.errorClass );
            throw;
        }
        catch( const std::exception& e )
        {
            errClass = errorClassName( ErrorClass::ServerInternal );
            logging::exceptionDetail( spec.name, sanitizeSecrets( e.what() ) );
            throw ToolError( ErrorClass::ServerInternal, "internal error",
                             sanitizeSecrets( e.what() ) );
        }
    }
}