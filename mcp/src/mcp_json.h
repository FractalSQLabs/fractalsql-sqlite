// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#pragma once
// Thin include boundary: every other translation unit includes THIS file,
// never vendor/json.hpp directly, so a future swap of the JSON library is
// a one-file change.
#include "../vendor/json.hpp"

#include <string>

namespace fsqlmcp
{
    using Json = nlohmann::json;
    using OrderedJson = nlohmann::ordered_json;

    // JSON-Schema-ish primitive kinds used by ToolParam::type (tool_registry.h).
    enum class JsonType
    {
        String, Integer, Number, Boolean, Object, Array, Null
    };

    inline bool jsonTypeMatches( JsonType t, const Json& v )
    {
        switch( t )
        {
            case JsonType::String:  return v.is_string();
            case JsonType::Integer: return v.is_number_integer();
            // Number accepts integer- or float-valued JSON; a bool is not a
            // number in JSON-Schema terms and is never silently coerced (1.4).
            case JsonType::Number:  return v.is_number() && !v.is_boolean();
            case JsonType::Boolean: return v.is_boolean();
            case JsonType::Object:  return v.is_object();
            case JsonType::Array:   return v.is_array();
            case JsonType::Null:    return v.is_null();
        }
        return false;
    }

    inline const char* jsonTypeName( JsonType t )
    {
        switch( t )
        {
            case JsonType::String:  return "string";
            case JsonType::Integer: return "integer";
            case JsonType::Number:  return "number";
            case JsonType::Boolean: return "boolean";
            case JsonType::Object:  return "object";
            case JsonType::Array:   return "array";
            case JsonType::Null:    return "null";
        }
        return "unknown";
    }
}