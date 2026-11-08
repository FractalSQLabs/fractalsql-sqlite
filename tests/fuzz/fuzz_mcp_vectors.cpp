// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
//
// libFuzzer entry point for the MCP server's argument coercion and secret
// redaction: mcp/src/vectors.cpp (vector / int-array / string-array / hex
// coercion) and sanitizeSecrets in mcp/src/errors.cpp. These are the pure
// functions that see client-supplied JSON and engine error text.
//
// The first input byte picks the function; the rest is the payload, parsed
// as JSON where the function takes JSON. A ToolError is the documented
// rejection and is ignored; a crash, hang or sanitizer report is the finding.
//
// Built and run by build_test.sh's MCP fuzz gate. By hand:
//   clang++ -std=c++17 -O1 -g -fsanitize=fuzzer,address -Imcp/src -Imcp/vendor \
//       tests/fuzz/fuzz_mcp_vectors.cpp mcp/src/vectors.cpp mcp/src/errors.cpp \
//       -o fuzz_mcp_vectors
#include "errors.h"
#include "vectors.h"

#include <cstddef>
#include <cstdint>
#include <string>

using namespace fsqlmcp;
using namespace fsqlmcp::vectors;

extern "C" int LLVMFuzzerTestOneInput( const uint8_t* data, size_t size )
{
    if( size == 0 ) return 0;
    const uint8_t which = data[ 0 ] % 8;
    const std::string payload( reinterpret_cast<const char*>( data ) + 1, size - 1 );

    try
    {
        if( which == 0 )
        {
            ( void ) sanitizeSecrets( payload );
            return 0;
        }
        if( which == 1 )
        {
            ( void ) hexToBytes( payload, "fuzz" );
            return 0;
        }
        if( which == 2 )
        {
            ( void ) blobToHex( reinterpret_cast<const uint8_t*>( payload.data() ), payload.size() );
            ( void ) blobToNumbers( reinterpret_cast<const uint8_t*>( payload.data() ), payload.size() );
            return 0;
        }
        // The rest take JSON; unparseable input is not interesting here.
        const Json j = Json::parse( payload, nullptr, false );
        if( j.is_discarded() ) return 0;
        switch( which )
        {
            case 3: ( void ) vectorParamToText( j, "fuzz" ); break;
            case 4: ( void ) intArrayToJsonText( j, "fuzz" ); break;
            case 5: ( void ) stringArrayToJsonText( j, "fuzz" ); break;
            case 6: ( void ) coerceNumber( j ); break;
            default: ( void ) wrapScalar( j ); break;
        }
    }
    catch( const ToolError& ) {}
    catch( const std::exception& ) {}
    return 0;
}
