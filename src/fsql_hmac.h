/* src/fractalsql_hmac.h
 *
 * Header-only SHA-256 + HMAC-SHA256 for the QTL ledger's MAC envelope.
 *
 * Why header-only / vendored (not OpenSSL/libcrypto): the extension must link
 * no extra library so it builds identically on MSVC (Windows) and gcc/clang
 * (Linux/macOS) with no Makefile OBJS / build-windows.ps1 source-list change,
 * and does not depend on the server having been built --with-openssl. This
 * is the public-domain SHA-256 from Brad Conte's crypto-algorithms
 * (https://github.com/B-Con/crypto-algorithms), prefixed `fsql_` and made
 * `static` so it is #include'd directly into fractalsql.c with no translation
 * unit of its own.
 *
 * Used only when the GUC fractalsql.enterprise_ledger_key is non-empty. When
 * that GUC is empty none of this is called and the ledger is validated
 * structurally only (the historical behavior).
 */
#ifndef FRACTALSQL_HMAC_H
#define FRACTALSQL_HMAC_H

#include <stdint.h>
#include <string.h>

typedef struct {
    uint8_t  data[64];
    uint32_t datalen;
    uint64_t bitlen;
    uint32_t state[8];
} fsql_sha256_ctx;

#define FSQL_SHA256_ROTR(a, b) (((a) >> (b)) | ((a) << (32 - (b))))
#define FSQL_SHA256_EP0(x)    (FSQL_SHA256_ROTR(x, 2)  ^ FSQL_SHA256_ROTR(x, 13) ^ FSQL_SHA256_ROTR(x, 22))
#define FSQL_SHA256_EP1(x)    (FSQL_SHA256_ROTR(x, 6)  ^ FSQL_SHA256_ROTR(x, 11) ^ FSQL_SHA256_ROTR(x, 25))
#define FSQL_SHA256_SIG0(x)   (FSQL_SHA256_ROTR(x, 7)  ^ FSQL_SHA256_ROTR(x, 18) ^ ((x) >> 3))
#define FSQL_SHA256_SIG1(x)   (FSQL_SHA256_ROTR(x, 17) ^ FSQL_SHA256_ROTR(x, 19) ^ ((x) >> 10))
#define FSQL_SHA256_CH(x,y,z)  (((x) & (y)) ^ (~(x) & (z)))
#define FSQL_SHA256_MAJ(x,y,z) (((x) & (y)) ^ ((x) & (z)) ^ ((y) & (z)))

static const uint32_t fsql_sha256_k[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
};

static void
fsql_sha256_transform(fsql_sha256_ctx *ctx, const uint8_t data[])
{
    uint32_t a;
    uint32_t b;
    uint32_t c;
    uint32_t d;
    uint32_t e;
    uint32_t f;
    uint32_t g;
    uint32_t h;
    uint32_t t1;
    uint32_t t2;
    uint32_t m[64];
    uint32_t i;
    uint32_t j;

    for (i = 0, j = 0; i < 16; ++i, j += 4)
        m[i] = ((uint32_t)data[j] << 24) | ((uint32_t)data[j + 1] << 16) |
               ((uint32_t)data[j + 2] << 8) | (uint32_t)data[j + 3];
    for (; i < 64; ++i)
        m[i] = FSQL_SHA256_SIG1(m[i - 2]) + m[i - 7] +
               FSQL_SHA256_SIG0(m[i - 15]) + m[i - 16];

    a = ctx->state[0]; b = ctx->state[1]; c = ctx->state[2]; d = ctx->state[3];
    e = ctx->state[4]; f = ctx->state[5]; g = ctx->state[6]; h = ctx->state[7];

    for (i = 0; i < 64; ++i)
    {
        t1 = h + FSQL_SHA256_EP1(e) + FSQL_SHA256_CH(e, f, g) +
             fsql_sha256_k[i] + m[i];
        t2 = FSQL_SHA256_EP0(a) + FSQL_SHA256_MAJ(a, b, c);
        h = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
    }
    ctx->state[0] += a; ctx->state[1] += b; ctx->state[2] += c; ctx->state[3] += d;
    ctx->state[4] += e; ctx->state[5] += f; ctx->state[6] += g; ctx->state[7] += h;
}

static void
fsql_sha256_init(fsql_sha256_ctx *ctx)
{
    ctx->datalen = 0;
    ctx->bitlen  = 0;
    ctx->state[0] = 0x6a09e667; ctx->state[1] = 0xbb67ae85;
    ctx->state[2] = 0x3c6ef372; ctx->state[3] = 0xa54ff53a;
    ctx->state[4] = 0x510e527f; ctx->state[5] = 0x9b05688c;
    ctx->state[6] = 0x1f83d9ab; ctx->state[7] = 0x5be0cd19;
}

static void
fsql_sha256_update(fsql_sha256_ctx *ctx, const uint8_t *data, size_t len)
{
    for (uint32_t i = 0; i < len; ++i)
    {
        ctx->data[ctx->datalen++] = data[i];
        if (ctx->datalen == 64)
        {
            fsql_sha256_transform(ctx, ctx->data);
            ctx->bitlen += 512;
            ctx->datalen = 0;
        }
    }
}

static void
fsql_sha256_final(fsql_sha256_ctx *ctx, uint8_t hash[])
{
    uint32_t i = ctx->datalen;

    ctx->data[i++] = 0x80;                       /* append the bit '1' */
    if (ctx->datalen < 56)
    {
        while (i < 56) ctx->data[i++] = 0x00;    /* pad with zeros */
    }
    else
    {
        while (i < 64) ctx->data[i++] = 0x00;
        fsql_sha256_transform(ctx, ctx->data);
        memset(ctx->data, 0, 56);
    }
    ctx->bitlen += (uint64_t)ctx->datalen * 8;   /* append the length */
    ctx->data[63] = (uint8_t)(ctx->bitlen);
    ctx->data[62] = (uint8_t)(ctx->bitlen >> 8);
    ctx->data[61] = (uint8_t)(ctx->bitlen >> 16);
    ctx->data[60] = (uint8_t)(ctx->bitlen >> 24);
    ctx->data[59] = (uint8_t)(ctx->bitlen >> 32);
    ctx->data[58] = (uint8_t)(ctx->bitlen >> 40);
    ctx->data[57] = (uint8_t)(ctx->bitlen >> 48);
    ctx->data[56] = (uint8_t)(ctx->bitlen >> 56);
    fsql_sha256_transform(ctx, ctx->data);

    for (i = 0; i < 4; ++i)                       /* big-endian output */
    {
        hash[i]      = (uint8_t)((ctx->state[0] >> (24 - i * 8)) & 0xff);
        hash[i + 4]  = (uint8_t)((ctx->state[1] >> (24 - i * 8)) & 0xff);
        hash[i + 8]  = (uint8_t)((ctx->state[2] >> (24 - i * 8)) & 0xff);
        hash[i + 12] = (uint8_t)((ctx->state[3] >> (24 - i * 8)) & 0xff);
        hash[i + 16] = (uint8_t)((ctx->state[4] >> (24 - i * 8)) & 0xff);
        hash[i + 20] = (uint8_t)((ctx->state[5] >> (24 - i * 8)) & 0xff);
        hash[i + 24] = (uint8_t)((ctx->state[6] >> (24 - i * 8)) & 0xff);
        hash[i + 28] = (uint8_t)((ctx->state[7] >> (24 - i * 8)) & 0xff);
    }
}

/*
 * Plain SHA-256 over msg (msglen bytes); 32-byte digest written to out[32].
 * Used by the QTL append-only chain (entry_hash = SHA256(prev_hash || blob
 * || mac)) -- unlike the HMAC below, this needs no key and is always
 * computed, even when fractalsql.enterprise_ledger_key is unset, so the
 * chain link itself is structurally verifiable independent of the MAC.
 */
static void
fsql_sha256(const uint8_t *msg, size_t msglen, uint8_t out[32])
{
    fsql_sha256_ctx ctx;
    fsql_sha256_init(&ctx);
    fsql_sha256_update(&ctx, msg, msglen);
    fsql_sha256_final(&ctx, out);
}

/*
 * HMAC-SHA256 over msg (msglen bytes) with key (keylen bytes); 32-byte tag
 * written to out[32]. Keys longer than 64 bytes are hashed first (RFC 2104).
 */
static void
fsql_hmac_sha256(const uint8_t *key, size_t keylen,
                 const uint8_t *msg, size_t msglen,
                 uint8_t out[32])
{
    uint8_t k_ipad[64];
    uint8_t k_opad[64];
    uint8_t tk[32];
    uint8_t inner[32];
    fsql_sha256_ctx ctx;

    if (keylen > 64)
    {
        fsql_sha256_init(&ctx);
        fsql_sha256_update(&ctx, key, keylen);
        fsql_sha256_final(&ctx, tk);
        key = tk;
        keylen = 32;
    }

    memset(k_ipad, 0, 64);
    memset(k_opad, 0, 64);
    memcpy(k_ipad, key, keylen);
    memcpy(k_opad, key, keylen);
    for (size_t i = 0; i < 64; ++i)
    {
        k_ipad[i] ^= 0x36;
        k_opad[i] ^= 0x5c;
    }

    fsql_sha256_init(&ctx);                       /* inner = H(k_ipad || msg) */
    fsql_sha256_update(&ctx, k_ipad, 64);
    fsql_sha256_update(&ctx, msg, msglen);
    fsql_sha256_final(&ctx, inner);

    fsql_sha256_init(&ctx);                       /* out = H(k_opad || inner) */
    fsql_sha256_update(&ctx, k_opad, 64);
    fsql_sha256_update(&ctx, inner, 32);
    fsql_sha256_final(&ctx, out);
}

/*
 * Constant-time byte compare: 0 when equal, nonzero otherwise. For
 * comparing a freshly computed tag against stored bytes an attacker
 * may position -- early-exit memcmp leaks how long the matching prefix
 * ran through timing. The compare never branches on the data.
 */
static int
fsql_ct_memcmp(const void *a, const void *b, size_t n)
{
    const uint8_t *pa = (const uint8_t *)a;
    const uint8_t *pb = (const uint8_t *)b;
    uint8_t diff = 0;
    for (size_t i = 0; i < n; ++i)
        diff |= (uint8_t)(pa[i] ^ pb[i]);
    return (int)diff;
}

#endif /* FRACTALSQL_HMAC_H */