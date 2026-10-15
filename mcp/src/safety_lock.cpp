// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#include "safety_lock.h"
#include <algorithm>
#include <fstream>
#include <sstream>

namespace fsqlmcp
{
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
        if( existing.str() == rendered ) return true;
        if( diffOut ) *diffOut = existing.str();
        return false;
    }

    void writeSafetyAnnotations( const std::string& lockPath, const std::string& rendered )
    {
        std::ofstream out( lockPath, std::ios::trunc );
        out << rendered;
    }
}