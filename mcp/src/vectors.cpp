// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#include "vectors.h"
#include <charconv>
#include <cmath>
#include <cstdlib>
#include <cerrno>
#include <cstring>
#include <sstream>
#include <array>

namespace fsqlmcp::vectors
{
    Json coerceNumber( const Json& element )
    {
        if( element.is_boolean() )
            return element;                 // bools are NEVER coerced
        if( element.is_number() )
            return element;
        if( element.is_string() )
        {
            const std::string& s = element.get_ref<const std::string&>();
            char* end = nullptr;
            errno = 0;
            const double v = std::strtod( s.c_str(), &end );
            const bool wholeStringConsumed = end != nullptr && *end == '\0' && end != s.c_str();
            if( wholeStringConsumed && errno == 0 && std::isfinite( v ) )
                return Json( v );
        }
        return element;                      // left alone; validation catches it later
    }

    static std::string formatDouble( double v )
    {
        // Shortest round-trippable form, load-bearing for 1.4's byte-identical
        // normalization promise. std::to_chars (C++17, <charconv>) gives the
        // shortest string that round-trips exactly, unlike "%g"/"%f".
        std::array<char, 64> buf{};
        auto res = std::to_chars( buf.data(), buf.data() + buf.size(), v );
        return std::string( buf.data(), res.ptr );
    }

    std::string vectorParamToText( const Json& value, std::string_view paramName )
    {
        if( value.is_null() )
            throw ToolError( ErrorClass::Schema, std::string( paramName ) + " must not be null" );
        if( !value.is_array() )
            throw ToolError( ErrorClass::Schema, std::string( paramName ) + " must be a JSON array of numbers" );
        if( value.empty() )
            throw ToolError( ErrorClass::Schema, std::string( paramName ) + " must not be an empty array" );

        std::vector<std::string> bad;
        std::ostringstream out;
        bool first = true;
        for( const Json& rawElem : value )
        {
            const Json elem = coerceNumber( rawElem );
            if( !elem.is_number() || elem.is_boolean() || !std::isfinite( elem.get<double>() ) )
            {
                if( bad.size() < 3 )
                    bad.push_back( rawElem.dump() );
                continue;
            }
            if( !first )
                out << ',';
            first = false;
            out << formatDouble( elem.get<double>() );
        }
        if( !bad.empty() )
        {
            std::string msg = std::string( paramName ) + " contains non-numeric element(s): ";
            for( std::size_t i = 0; i < bad.size(); ++i )
                msg += ( i ? ", " : "" ) + bad[ i ];
            throw ToolError( ErrorClass::Schema, msg );
        }
        return out.str();
    }

    std::string intArrayToJsonText( const Json& value, std::string_view paramName )
    {
        if( !value.is_array() )
            throw ToolError( ErrorClass::Schema, std::string( paramName ) + " must be a JSON array of integers" );
        Json out = Json::array();
        for( const Json& e : value )
        {
            if( !e.is_number_integer() || e.is_boolean() )
                throw ToolError( ErrorClass::Schema, std::string( paramName ) + " elements must be integers (no lenient coercion here)" );
            out.push_back( e );
        }
        return out.dump();
    }

    std::string stringArrayToJsonText( const Json& value, std::string_view paramName )
    {
        if( !value.is_array() )
            throw ToolError( ErrorClass::Schema, std::string( paramName ) + " must be a JSON array of strings" );
        for( const Json& e : value )
            if( !e.is_string() )
                throw ToolError( ErrorClass::Schema, std::string( paramName ) + " elements must be strings" );
        return value.dump();
    }

    Json blobToNumbers( const std::uint8_t* data, std::size_t len )
    {
        if( len < 4 )
            throw ToolError( ErrorClass::ServerInternal, "fractal_vector BLOB shorter than its own header" );
        const std::uint16_t dim = static_cast<std::uint16_t>( data[ 0 ] | ( data[ 1 ] << 8 ) );
        // data[2..3] = reserved, ignored.
        const std::size_t need = 4u + static_cast<std::size_t>( dim ) * 4u;
        if( len < need )
            throw ToolError( ErrorClass::ServerInternal, "fractal_vector BLOB shorter than its declared dimension" );

        Json out = Json::array();
        for( std::uint16_t i = 0; i < dim; ++i )
        {
            float f;
            std::memcpy( &f, data + 4 + i * 4, 4 );               // float32 LE
            const double rounded = std::round( static_cast<double>( f ) * 1e14 ) / 1e14;
            out.push_back( rounded );
        }
        return out;
    }

    std::string blobToHex( const std::uint8_t* data, std::size_t len )
    {
        static const char* kHex = "0123456789abcdef";
        std::string out;
        out.reserve( len * 2 );
        for( std::size_t i = 0; i < len; ++i )
        {
            out.push_back( kHex[ data[ i ] >> 4 ] );
            out.push_back( kHex[ data[ i ] & 0xF ] );
        }
        return out;
    }

    std::vector<std::uint8_t> hexToBytes( const std::string& hex, std::string_view paramName )
    {
        if( hex.size() % 2 != 0 )
            throw ToolError( ErrorClass::Schema, std::string( paramName ) + " must be an even-length hex string" );
        std::vector<std::uint8_t> out;
        out.reserve( hex.size() / 2 );
        for( std::size_t i = 0; i + 1 < hex.size(); i += 2 )
        {
            char pair[3] = { hex[ i ], hex[ i + 1 ], '\0' };
            char* end = nullptr;
            const long v = std::strtol( pair, &end, 16 );
            if( end != pair + 2 )
                throw ToolError( ErrorClass::Schema, std::string( paramName ) + " contains a non-hex character" );
            out.push_back( static_cast<std::uint8_t>( v ) );
        }
        return out;
    }

    Json wrapScalar( const Json& value )
    {
        if( value.is_null() )
            return Json{ { "value", nullptr } };
        if( value.is_number() && !value.is_boolean() )
        {
            const double d = value.get<double>();
            if( !std::isfinite( d ) )
                return Json{ { "value", nullptr } };
        }
        return Json{ { "value", value } };
    }
}