// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#pragma once
#include <algorithm>
#include <string>
#include <string_view>
#include "mcp_json.h"
#include "errors.h"

namespace fsqlmcp
{
    struct RowLimitConfig
    {
        int maxRowsCeiling = 1000;   // FSQL_MCP_MAX_ROWS_CEILING (10.7/1.5)
    };

    // The process-wide ceiling config. Tool-table handlers capture this by
    // reference at build time, so it must outlive tool construction: it is a
    // static local on purpose (a buildAllTools() local would die with tool
    // construction, leaving handlers with garbage ceilings at call time).
    inline RowLimitConfig& sharedRowLimitConfig()
    {
        static RowLimitConfig cfg;
        return cfg;
    }

    struct BoundedCount
    {
        int  passed;          // what the adapter should actually pass to the SQL call
        int  ceiling;
        bool truncated;       // requested > passed
        int  requested;       // echoed back for total_scanned bookkeeping
    };

    // Ports rows.py::bounded_count 1:1 (1.5). countKey names the tool's own
    // "how many results" argument (e.g. "k", "population_size"); its JSON
    // default is defaultCount when the argument was omitted.
    inline BoundedCount boundedCount( const Json& args, std::string_view countKey,
                                      int defaultCount, const RowLimitConfig& cfg )
    {
        int requested = defaultCount;
        if( args.contains( countKey ) && !args.at( std::string( countKey ) ).is_null() )
        {
            const Json& v = args.at( std::string( countKey ) );
            if( !v.is_number_integer() || v.is_boolean() )
                throw ToolError( ErrorClass::Schema, std::string( countKey ) + " must be an integer" );
            requested = v.get<int>();
        }
        if( requested < 1 || requested >= 1'000'000 )
            throw ToolError( ErrorClass::Schema, std::string( countKey ) + " out of range [1, 1000000)" );

        int limit = 100;
        if( args.contains( "limit" ) && !args.at( "limit" ).is_null() )
        {
            const Json& v = args.at( "limit" );
            if( !v.is_number_integer() || v.is_boolean() || v.get<int>() < 1 )
                throw ToolError( ErrorClass::Schema, "limit must be a positive integer" );
            limit = v.get<int>();
        }

        const int ceiling = std::min( limit, cfg.maxRowsCeiling );
        const int passed  = std::min( requested, ceiling );
        return BoundedCount{ passed, ceiling, requested > passed, requested };
    }

    // ONE shared annotator. rowsJson must be a JSON array;
    // mutates it in place by wrapping into {"rows":..., "truncated":...,
    // "total_scanned":...} only when truncation actually happened, and
    // otherwise returns the array unwrapped (the "truncated"/
    // "total_scanned" flag pair appears only when the ceiling was hit,
    // not always).
    inline Json annotateRows( Json rowsJson, const BoundedCount& bc )
    {
        if( !bc.truncated )
            return rowsJson;
        Json out;
        out[ "rows" ]          = std::move( rowsJson );
        out[ "truncated" ]     = true;
        out[ "total_scanned" ] = bc.requested;
        return out;
    }
}