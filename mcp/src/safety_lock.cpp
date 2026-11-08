// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#include "safety_lock.h"
#include <algorithm>
#include <fstream>
#include <sstream>

namespace fsqlmcp
{
    // "abc\r\ndef" -> "abc\ndef": the CRLF-tolerant comparison helper every
    // lock read goes through (see checkSafetyAnnotations).
    static std::string normalizeCrlf( const std::string& s )
    {
        std::string out; out.reserve( s.size() );
        for( char c : s )
            if( c != '\r' ) out.push_back( c );
        return out;
    }

    std::string renderSafetyAnnotations( const std::vector<ToolSpec>& tools )
    {
        std::vector<const ToolSpec*> sorted;
        for( const ToolSpec& t : tools ) sorted.push_back( &t );
        std::sort( sorted.begin(), sorted.end(),
                   []( const ToolSpec* a, const ToolSpec* b ) { return a->name < b->name; } );
        std::ostringstream out;
        for( const ToolSpec* t : sorted )
            out << t->name << " destructive=" << ( t->destructiveHint ? 1 : 0 )
                << " readOnly=" << ( t->readOnlyHint ? 1 : 0 )
                << " idempotent=" << ( t->idempotentHint ? 1 : 0 )
                << " openWorld=" << ( t->openWorldHint ? 1 : 0 )
                << " secret=" << ( t->secretHint ? 1 : 0 ) << "\n";
        return out.str();   // 15.3's base shape extended with 15.2's newer hints
    }

    bool checkSafetyAnnotations( const std::string& lockPath, const std::string& rendered,
                                 std::string* diffOut )
    {
        std::ifstream in( lockPath );
        if( !in ) return true;             // absent: dev-mode friendly, same stance as schema_lock
        std::ostringstream existing; existing << in.rdbuf();
        // Ignore CR so a lock file written with CRLF on Windows still matches.
        if( normalizeCrlf( existing.str() ) == rendered ) return true;
        if( diffOut ) *diffOut = existing.str();
        return false;
    }

    void writeSafetyAnnotations( const std::string& lockPath, const std::string& rendered )
    {
        // BINARY mode: the rendered '\n's stay '\n' on every platform — a
        // text-mode stream would write CRLF on Windows and make the
        // artifact differ from the Linux copy (the pin's whole point is
        // byte-identical cross-platform content).
        std::ofstream out( lockPath, std::ios::trunc | std::ios::binary );
        out << rendered;
    }
}