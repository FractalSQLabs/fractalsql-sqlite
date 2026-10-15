// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#pragma once
#include <string>
#include <string_view>
#include <vector>
#include <functional>
#include <optional>
#include <chrono>
#include "mcp_json.h"
#include "errors.h"
#include "logging.h"

namespace fsqlmcp
{
    enum class ToolClass { Cheap, Expensive };

    inline const char* toolClassName( ToolClass c )
    { return c == ToolClass::Cheap ? "cheap" : "expensive"; }

    struct ToolParam
    {
        std::string_view name;
        JsonType         type;
        bool             required;
        Json             defaultValue = nullptr;   // used when !required and absent
        std::string_view description;
        bool             nullable = false;          // JSON-Schema anyOf [type, "null"]
    };

    struct ToolSpec;
    struct CallCtx
    {
        std::string clientKey;     // "stdio" or a per-session/per-token key (concurrency.h, 13.3.4)
        bool        cancelled = false;
    };

    struct ToolSpec
    {
        std::string_view name, category;
        ToolClass         toolClass;
        std::vector<ToolParam> params;
        std::optional<std::string_view> retryTier;   // retry-tier editions only; unset => omitted from tools/list
        bool destructiveHint = false;
        bool readOnlyHint    = false;
        std::function<Json( const Json& args, CallCtx& )> handler;  // tables pass it positionally 8th
        // 15.2's expanded annotation set, present from the first write, not
        // retro-patched; omitted from JSON when false so an unannotated tool
        // still emits no annotations key at all.
        bool idempotentHint  = false;
        bool openWorldHint   = false;
        bool secretHint      = false;
        // Member order below follows the tool tables' positional initializers
        // (resolved once, so a table entry compiles as written). Long
        // descriptions are built by string concatenation, so this member is
        // std::string and assigned post-hoc (`t.back().description = ...`),
        // never std::string_view of a temporary.
        std::string description;
    };

    // Non-recursive validity check. Null is skipped for non-required
    // arguments (an explicit JSON null counts as "absent" rather than
    // failing a type check), except for nullable params, which consume
    // it deliberately.
    inline void validateArgs( const ToolSpec& spec, const Json& args )
    {
        if( !args.is_object() )
            throw ToolError( ErrorClass::Schema, "arguments must be a JSON object" );

        for( const ToolParam& p : spec.params )
        {
            const std::string key( p.name );
            if( !args.contains( key ) )
            {
                if( p.required )
                    throw ToolError( ErrorClass::Schema, "missing required argument: " + key );
                continue;    // handler applies p.defaultValue itself
            }
            const Json& v = args.at( key );
            if( v.is_null() )
            {
                if( p.required )
                    throw ToolError( ErrorClass::Schema, "missing required argument: " + key );
                if( p.nullable )
                    continue;    // explicitly-null consumes the nullable slot
                continue;        // non-required null falls back to the handler's default
            }
            if( !jsonTypeMatches( p.type, v ) )
                throw ToolError( ErrorClass::Schema,
                                 key + " has the wrong type (expected " + jsonTypeName( p.type ) + ")" );
        }
    }

    inline Json buildInputSchema( const ToolSpec& spec )
    {
        Json props = Json::object();
        std::vector<std::string> required;
        for( const ToolParam& p : spec.params )
        {
            Json prop;
            switch( p.type )
            {
                case JsonType::String:  prop[ "type" ] = "string";  break;
                case JsonType::Integer: prop[ "type" ] = "integer"; break;
                case JsonType::Number:  prop[ "type" ] = "number";  break;
                case JsonType::Boolean: prop[ "type" ] = "boolean"; break;
                case JsonType::Object:  prop[ "type" ] = "object";  break;
                // Array == the vector convention: array of numbers. The two
                // integer/string-array params declare themselves Array and have
                // their element type enforced at call time by the vectors helpers.
                case JsonType::Array:   prop[ "type" ] = "array";   prop[ "items" ][ "type" ] = "number"; break;
                case JsonType::Null:    prop[ "type" ] = "null";    break;
            }
            if( p.nullable )
                prop[ "type" ] = Json::array( { prop[ "type" ], "null" } );
            prop[ "description" ] = std::string( p.description );
            if( !p.required && !p.defaultValue.is_null() )
                prop[ "default" ] = p.defaultValue;
            props[ std::string( p.name ) ] = prop;
            if( p.required )
                required.push_back( std::string( p.name ) );
        }
        Json schema{ { "type", "object" }, { "properties", props }, { "additionalProperties", false } };
        if( !required.empty() )
            schema[ "required" ] = required;
        // The accessibility invariant: even a zero-argument tool documents
        // THAT honestly via the marker.
        if( props.empty() )
            schema[ "x-fractalsql-no-arguments" ] = true;
        return schema;
    }

    // validate -> handler -> classify -> always log. The RAII pattern below is
    // C++'s "finally": logging happens on every exit path via the destructor.
    Json runTool( const ToolSpec& spec, const Json& args, CallCtx& ctx );
}