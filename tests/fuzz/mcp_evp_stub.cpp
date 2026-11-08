// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
//
// Stand-in for the six OpenSSL EVP digest calls mcp/src/logging.cpp makes to
// shorten a value for its log line. The Windows fuzz build links this instead
// of the MSVC-built static OpenSSL; the digest is not SHA-256 and is not
// meant to be.
#include <openssl/evp.h>
#include <cstdint>

namespace
{
    struct Ctx { std::uint64_t h; };
}

extern "C"
{
    EVP_MD_CTX* EVP_MD_CTX_new( void ) { return reinterpret_cast<EVP_MD_CTX*>( new Ctx{ 1469598103934665603ull } ); }
    void EVP_MD_CTX_free( EVP_MD_CTX* c ) { delete reinterpret_cast<Ctx*>( c ); }
    const EVP_MD* EVP_sha256( void ) { static const char tag = 0; return reinterpret_cast<const EVP_MD*>( &tag ); }
    int EVP_DigestInit_ex( EVP_MD_CTX*, const EVP_MD*, ENGINE* ) { return 1; }

    int EVP_DigestUpdate( EVP_MD_CTX* c, const void* d, size_t n )
    {
        auto* x = reinterpret_cast<Ctx*>( c );
        const auto* p = static_cast<const unsigned char*>( d );
        for( size_t i = 0; i < n; ++i ) x->h = ( x->h ^ p[ i ] ) * 1099511628211ull;
        return 1;
    }

    int EVP_DigestFinal_ex( EVP_MD_CTX* c, unsigned char* out, unsigned int* len )
    {
        const auto h = reinterpret_cast<Ctx*>( c )->h;
        for( int i = 0; i < 8; ++i ) out[ i ] = static_cast<unsigned char>( h >> ( 8 * i ) );
        if( len ) *len = 8;
        return 1;
    }
}
