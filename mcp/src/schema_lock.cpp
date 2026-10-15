// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#include "schema_lock.h"
#include <openssl/evp.h>
#include <fstream>
#include <algorithm>

namespace fsqlmcp
{
    static OrderedJson sortKeysRecursive( const Json& v )
    {
        if( v.is_object() )
        {
            std::vector<std::string> keys;
            for( auto it = v.begin(); it != v.end(); ++it ) keys.push_back( it.key() );
            std::sort( keys.begin(), keys.end() );
            OrderedJson out = OrderedJson::object();
            for( const std::string& k : keys )
                out[ k ] = sortKeysRecursive( v.at( k ) );
            return out;
        }
        if( v.is_array() )
        {
            OrderedJson out = OrderedJson::array();
            for( const Json& e : v ) out.push_back( sortKeysRecursive( e ) );
            return out;
        }
        return v;
    }

    static std::string sha256Hex( const std::string& data )
    {
        unsigned char digest[ EVP_MAX_MD_SIZE ]; unsigned int len = 0;
        EVP_MD_CTX* ctx = EVP_MD_CTX_new();
        EVP_DigestInit_ex( ctx, EVP_sha256(), nullptr );
        EVP_DigestUpdate( ctx, data.data(), data.size() );
        EVP_DigestFinal_ex( ctx, digest, &len );
        EVP_MD_CTX_free( ctx );

        static const char* const kHex = "0123456789abcdef";
        std::string hex;
        for( unsigned int i = 0; i < len; ++i )
        {
            hex.push_back( kHex[ digest[ i ] >> 4 ] );
            hex.push_back( kHex[ digest[ i ] & 0xF ] );
        }
        return hex;
    }

    static Json annotationsOf( const ToolSpec& t )
    {
        Json annotations;
        if( t.destructiveHint ) annotations[ "destructiveHint" ] = true;
        if( t.readOnlyHint )    annotations[ "readOnlyHint" ]    = true;
        if( t.idempotentHint )  annotations[ "idempotentHint" ]  = true;   // 15.2
        if( t.openWorldHint )   annotations[ "openWorldHint" ]   = true;   // 15.2
        if( t.secretHint )      annotations[ "secretHint" ]      = true;   // 15.2
        if( t.retryTier )       annotations[ "x-fractalsql-retry-tier" ] = std::string( *t.retryTier );
        return annotations;
    }

    std::string computeSchemaHash( const std::vector<ToolSpec>& tools )
    {
        Json projection = Json::object();
        for( const ToolSpec& t : tools )
        {
            projection[ std::string( t.name ) ] = Json{
                { "category", std::string( t.category ) },
                { "toolClass", t.toolClass == ToolClass::Cheap ? "cheap" : "expensive" },
                { "description", std::string( t.description ) },
                { "annotations", annotationsOf( t ) },
                { "inputSchema", buildInputSchema( t ) }
            };
        }
        const std::string canonical = sortKeysRecursive( projection ).dump( -1 );
        return sha256Hex( canonical );
    }

    LockCheckResult checkSchemaLock( const std::string& lockFilePath, const std::string& computedHash,
                                     std::string* expectedOut )
    {
        std::ifstream in( lockFilePath );
        if( !in )
            return LockCheckResult::Absent;    // dev-mode friendly, not a failure
        std::string expected;
        std::getline( in, expected );
        if( !expected.empty() && expected.back() == '\r' ) expected.pop_back();
        if( expectedOut ) *expectedOut = expected;
        return ( expected == computedHash ) ? LockCheckResult::Ok : LockCheckResult::Warn;
    }

    void writeSchemaLock( const std::string& lockFilePath, const std::string& computedHash )
    {
        std::ofstream out( lockFilePath, std::ios::trunc );
        out << computedHash << '\n';
    }
}