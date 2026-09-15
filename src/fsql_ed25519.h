/* src/fsql_ed25519.h
 *
 * Header-only Ed25519 signature VERIFICATION for the enterprise-core
 * loader's detached-signature check (see fsql_enterprise.c).
 *
 * Why header-only / vendored (not OpenSSL/libcrypto): same reasoning as
 * fsql_hmac.h next to this file -- the extension must link no extra
 * library so it builds identically on MSVC (Windows) and gcc/clang
 * (Linux/macOS) with no Makefile OBJS / build-windows.ps1 source-list
 * change, and does not depend on the host having been built
 * --with-openssl (SQLite has no such concept anyway).
 *
 * Source: TweetNaCl 20140427 (Daniel J. Bernstein, Bernard van Gastel,
 * Wesley Janssen, Tanja Lange, Peter Schwabe, Sjaak Smetsers), public
 * domain, https://tweetnacl.cr.yp.to/20140427/tweetnacl.c -- fetched
 * directly from the canonical site. This header vendors only the
 * dependency closure of crypto_sign_open() (SHA-512, the field/group
 * arithmetic it needs, and mod-L scalar reduction); the unrelated
 * primitives TweetNaCl also implements (Salsa20, Poly1305, X25519,
 * crypto_box/secretbox, key generation) are left out, matching the same
 * "vendor exactly the needed pieces" precedent fsql_hmac.h already set
 * for crypto-algorithms' SHA-256. All symbols are prefixed `fsql_ed_`
 * and `static` so this is #include'd directly into fsql_enterprise.c
 * with no translation unit of its own and no risk of colliding with
 * anything else in the process.
 *
 * The arithmetic below (field ops, group law, mod-L reduction, SHA-512)
 * is transcribed unmodified from the upstream file -- only identifier
 * names changed. It was validated against the RFC 8032 Section 7.1
 * Ed25519 test vectors (TEST 1 and TEST 2: known pubkey/message/
 * signature triples) plus a corrupted-signature rejection check before
 * being wired into fsql_enterprise.c -- see the standalone check kept
 * out of the shipped build.
 *
 * API used by fsql_enterprise.c:
 *   int fsql_ed25519_verify_detached(const unsigned char sig[64],
 *                                     const unsigned char *msg, size_t msglen,
 *                                     const unsigned char pk[32]);
 *   returns 1 if sig is a valid Ed25519 signature by pk over msg, 0 otherwise.
 */
#ifndef FSQL_ED25519_H
#define FSQL_ED25519_H

#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

typedef unsigned char      fsql_ed_u8;
typedef uint32_t           fsql_ed_u32;
typedef uint64_t           fsql_ed_u64;
typedef int64_t            fsql_ed_i64;
typedef fsql_ed_i64        fsql_ed_gf[16];

#define FSQL_ED_FOR(i,n) for (i = 0; i < n; ++i)

/* ---- constants (verbatim from tweetnacl.c) ------------------------- */

static const fsql_ed_gf
    fsql_ed_gf0,
    fsql_ed_gf1 = {1},
    fsql_ed_D  = {0x78a3, 0x1359, 0x4dca, 0x75eb, 0xd8ab, 0x4141, 0x0a4d, 0x0070,
                  0xe898, 0x7779, 0x4079, 0x8cc7, 0xfe73, 0x2b6f, 0x6cee, 0x5203},
    fsql_ed_D2 = {0xf159, 0x26b2, 0x9b94, 0xebd6, 0xb156, 0x8283, 0x149a, 0x00e0,
                  0xd130, 0xeef3, 0x80f2, 0x198e, 0xfce7, 0x56df, 0xd9dc, 0x2406},
    fsql_ed_X  = {0xd51a, 0x8f25, 0x2d60, 0xc956, 0xa7b2, 0x9525, 0xc760, 0x692c,
                  0xdc5c, 0xfdd6, 0xe231, 0xc0a4, 0x53fe, 0xcd6e, 0x36d3, 0x2169},
    fsql_ed_Y  = {0x6658, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666,
                  0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666},
    fsql_ed_I  = {0xa0b0, 0x4a0e, 0x1b27, 0xc4ee, 0xe478, 0xad2f, 0x1806, 0x2f43,
                  0xd7a7, 0x3dfb, 0x0099, 0x2b4d, 0xdf0b, 0x4fc1, 0x2480, 0x2b83};

/* ---- little helpers -------------------------------------------------- */

static fsql_ed_u64 fsql_ed_dl64(const fsql_ed_u8 *x)
{
    fsql_ed_u64 i, u = 0;
    FSQL_ED_FOR(i, 8) u = (u << 8) | x[i];
    return u;
}

static void fsql_ed_ts64(fsql_ed_u8 *x, fsql_ed_u64 u)
{
    int i;
    for (i = 7; i >= 0; --i) { x[i] = (fsql_ed_u8)u; u >>= 8; }
}

static int fsql_ed_vn(const fsql_ed_u8 *x, const fsql_ed_u8 *y, int n)
{
    int i;
    fsql_ed_u32 d = 0;
    FSQL_ED_FOR(i, n) d |= x[i] ^ y[i];
    return (1 & ((d - 1) >> 8)) - 1;
}

static int fsql_ed_verify32(const fsql_ed_u8 *x, const fsql_ed_u8 *y)
{
    return fsql_ed_vn(x, y, 32);
}

/* ---- field arithmetic (mod 2^255-19) --------------------------------- */

static void fsql_ed_set25519(fsql_ed_gf r, const fsql_ed_gf a)
{
    int i;
    FSQL_ED_FOR(i, 16) r[i] = a[i];
}

static void fsql_ed_car25519(fsql_ed_gf o)
{
    int i;
    fsql_ed_i64 c;
    FSQL_ED_FOR(i, 16) {
        o[i] += (1LL << 16);
        c = o[i] >> 16;
        o[(i + 1) * (i < 15)] += c - 1 + 37 * (c - 1) * (i == 15);
        /* c can be negative here -- shift the unsigned reinterpretation
         * to avoid UB on left-shifting a negative signed value. */
        o[i] -= (fsql_ed_i64)((uint64_t)c << 16);
    }
}

static void fsql_ed_sel25519(fsql_ed_gf p, fsql_ed_gf q, int b)
{
    fsql_ed_i64 t, i, c = ~(b - 1);
    FSQL_ED_FOR(i, 16) {
        t = c & (p[i] ^ q[i]);
        p[i] ^= t;
        q[i] ^= t;
    }
}

static void fsql_ed_pack25519(fsql_ed_u8 *o, const fsql_ed_gf n)
{
    int i, j, b;
    fsql_ed_gf m, t;
    FSQL_ED_FOR(i, 16) t[i] = n[i];
    fsql_ed_car25519(t);
    fsql_ed_car25519(t);
    fsql_ed_car25519(t);
    FSQL_ED_FOR(j, 2) {
        m[0] = t[0] - 0xffed;
        for (i = 1; i < 15; i++) {
            m[i] = t[i] - 0xffff - ((m[i - 1] >> 16) & 1);
            m[i - 1] &= 0xffff;
        }
        m[15] = t[15] - 0x7fff - ((m[14] >> 16) & 1);
        b = (int)((m[15] >> 16) & 1);
        m[14] &= 0xffff;
        fsql_ed_sel25519(t, m, 1 - b);
    }
    FSQL_ED_FOR(i, 16) {
        o[2 * i] = (fsql_ed_u8)(t[i] & 0xff);
        o[2 * i + 1] = (fsql_ed_u8)(t[i] >> 8);
    }
}

static int fsql_ed_neq25519(const fsql_ed_gf a, const fsql_ed_gf b)
{
    fsql_ed_u8 c[32], d[32];
    fsql_ed_pack25519(c, a);
    fsql_ed_pack25519(d, b);
    return fsql_ed_verify32(c, d);
}

static fsql_ed_u8 fsql_ed_par25519(const fsql_ed_gf a)
{
    fsql_ed_u8 d[32];
    fsql_ed_pack25519(d, a);
    return d[0] & 1;
}

static void fsql_ed_unpack25519(fsql_ed_gf o, const fsql_ed_u8 *n)
{
    int i;
    FSQL_ED_FOR(i, 16) o[i] = n[2 * i] + ((fsql_ed_i64)n[2 * i + 1] << 8);
    o[15] &= 0x7fff;
}

static void fsql_ed_A(fsql_ed_gf o, const fsql_ed_gf a, const fsql_ed_gf b)
{
    int i;
    FSQL_ED_FOR(i, 16) o[i] = a[i] + b[i];
}

static void fsql_ed_Z(fsql_ed_gf o, const fsql_ed_gf a, const fsql_ed_gf b)
{
    int i;
    FSQL_ED_FOR(i, 16) o[i] = a[i] - b[i];
}

static void fsql_ed_M(fsql_ed_gf o, const fsql_ed_gf a, const fsql_ed_gf b)
{
    fsql_ed_i64 i, j, t[31];
    FSQL_ED_FOR(i, 31) t[i] = 0;
    FSQL_ED_FOR(i, 16) FSQL_ED_FOR(j, 16) t[i + j] += a[i] * b[j];
    FSQL_ED_FOR(i, 15) t[i] += 38 * t[i + 16];
    FSQL_ED_FOR(i, 16) o[i] = t[i];
    fsql_ed_car25519(o);
    fsql_ed_car25519(o);
}

static void fsql_ed_S(fsql_ed_gf o, const fsql_ed_gf a)
{
    fsql_ed_M(o, a, a);
}

static void fsql_ed_inv25519(fsql_ed_gf o, const fsql_ed_gf i)
{
    fsql_ed_gf c;
    int a;
    FSQL_ED_FOR(a, 16) c[a] = i[a];
    for (a = 253; a >= 0; a--) {
        fsql_ed_S(c, c);
        if (a != 2 && a != 4) fsql_ed_M(c, c, i);
    }
    FSQL_ED_FOR(a, 16) o[a] = c[a];
}

static void fsql_ed_pow2523(fsql_ed_gf o, const fsql_ed_gf i)
{
    fsql_ed_gf c;
    int a;
    FSQL_ED_FOR(a, 16) c[a] = i[a];
    for (a = 250; a >= 0; a--) {
        fsql_ed_S(c, c);
        if (a != 1) fsql_ed_M(c, c, i);
    }
    FSQL_ED_FOR(a, 16) o[a] = c[a];
}

/* ---- SHA-512 (needed for the EdDSA challenge hashes) ------------------ */

static fsql_ed_u64 fsql_ed_sha_R(fsql_ed_u64 x, int c) { return (x >> c) | (x << (64 - c)); }
static fsql_ed_u64 fsql_ed_sha_Ch(fsql_ed_u64 x, fsql_ed_u64 y, fsql_ed_u64 z) { return (x & y) ^ (~x & z); }
static fsql_ed_u64 fsql_ed_sha_Maj(fsql_ed_u64 x, fsql_ed_u64 y, fsql_ed_u64 z) { return (x & y) ^ (x & z) ^ (y & z); }
static fsql_ed_u64 fsql_ed_sha_Sigma0(fsql_ed_u64 x) { return fsql_ed_sha_R(x, 28) ^ fsql_ed_sha_R(x, 34) ^ fsql_ed_sha_R(x, 39); }
static fsql_ed_u64 fsql_ed_sha_Sigma1(fsql_ed_u64 x) { return fsql_ed_sha_R(x, 14) ^ fsql_ed_sha_R(x, 18) ^ fsql_ed_sha_R(x, 41); }
static fsql_ed_u64 fsql_ed_sha_sigma0(fsql_ed_u64 x) { return fsql_ed_sha_R(x, 1) ^ fsql_ed_sha_R(x, 8) ^ (x >> 7); }
static fsql_ed_u64 fsql_ed_sha_sigma1(fsql_ed_u64 x) { return fsql_ed_sha_R(x, 19) ^ fsql_ed_sha_R(x, 61) ^ (x >> 6); }

static const fsql_ed_u64 fsql_ed_sha_K[80] = {
    0x428a2f98d728ae22ULL, 0x7137449123ef65cdULL, 0xb5c0fbcfec4d3b2fULL, 0xe9b5dba58189dbbcULL,
    0x3956c25bf348b538ULL, 0x59f111f1b605d019ULL, 0x923f82a4af194f9bULL, 0xab1c5ed5da6d8118ULL,
    0xd807aa98a3030242ULL, 0x12835b0145706fbeULL, 0x243185be4ee4b28cULL, 0x550c7dc3d5ffb4e2ULL,
    0x72be5d74f27b896fULL, 0x80deb1fe3b1696b1ULL, 0x9bdc06a725c71235ULL, 0xc19bf174cf692694ULL,
    0xe49b69c19ef14ad2ULL, 0xefbe4786384f25e3ULL, 0x0fc19dc68b8cd5b5ULL, 0x240ca1cc77ac9c65ULL,
    0x2de92c6f592b0275ULL, 0x4a7484aa6ea6e483ULL, 0x5cb0a9dcbd41fbd4ULL, 0x76f988da831153b5ULL,
    0x983e5152ee66dfabULL, 0xa831c66d2db43210ULL, 0xb00327c898fb213fULL, 0xbf597fc7beef0ee4ULL,
    0xc6e00bf33da88fc2ULL, 0xd5a79147930aa725ULL, 0x06ca6351e003826fULL, 0x142929670a0e6e70ULL,
    0x27b70a8546d22ffcULL, 0x2e1b21385c26c926ULL, 0x4d2c6dfc5ac42aedULL, 0x53380d139d95b3dfULL,
    0x650a73548baf63deULL, 0x766a0abb3c77b2a8ULL, 0x81c2c92e47edaee6ULL, 0x92722c851482353bULL,
    0xa2bfe8a14cf10364ULL, 0xa81a664bbc423001ULL, 0xc24b8b70d0f89791ULL, 0xc76c51a30654be30ULL,
    0xd192e819d6ef5218ULL, 0xd69906245565a910ULL, 0xf40e35855771202aULL, 0x106aa07032bbd1b8ULL,
    0x19a4c116b8d2d0c8ULL, 0x1e376c085141ab53ULL, 0x2748774cdf8eeb99ULL, 0x34b0bcb5e19b48a8ULL,
    0x391c0cb3c5c95a63ULL, 0x4ed8aa4ae3418acbULL, 0x5b9cca4f7763e373ULL, 0x682e6ff3d6b2b8a3ULL,
    0x748f82ee5defb2fcULL, 0x78a5636f43172f60ULL, 0x84c87814a1f0ab72ULL, 0x8cc702081a6439ecULL,
    0x90befffa23631e28ULL, 0xa4506cebde82bde9ULL, 0xbef9a3f7b2c67915ULL, 0xc67178f2e372532bULL,
    0xca273eceea26619cULL, 0xd186b8c721c0c207ULL, 0xeada7dd6cde0eb1eULL, 0xf57d4f7fee6ed178ULL,
    0x06f067aa72176fbaULL, 0x0a637dc5a2c898a6ULL, 0x113f9804bef90daeULL, 0x1b710b35131c471bULL,
    0x28db77f523047d84ULL, 0x32caab7b40c72493ULL, 0x3c9ebe0a15c9bebcULL, 0x431d67c49c100d4cULL,
    0x4cc5d4becb3e42b6ULL, 0x597f299cfc657e2aULL, 0x5fcb6fab3ad6faecULL, 0x6c44198c4a475817ULL
};

/* returns bytes-remaining (< 128), matching upstream crypto_hashblocks(). */
static int fsql_ed_sha512_blocks(fsql_ed_u8 *x, const fsql_ed_u8 *m, fsql_ed_u64 n)
{
    fsql_ed_u64 z[8], b[8], a[8], w[16], t;
    int i, j;

    FSQL_ED_FOR(i, 8) z[i] = a[i] = fsql_ed_dl64(x + 8 * i);

    while (n >= 128) {
        FSQL_ED_FOR(i, 16) w[i] = fsql_ed_dl64(m + 8 * i);

        FSQL_ED_FOR(i, 80) {
            FSQL_ED_FOR(j, 8) b[j] = a[j];
            t = a[7] + fsql_ed_sha_Sigma1(a[4]) + fsql_ed_sha_Ch(a[4], a[5], a[6]) +
                fsql_ed_sha_K[i] + w[i % 16];
            b[7] = t + fsql_ed_sha_Sigma0(a[0]) + fsql_ed_sha_Maj(a[0], a[1], a[2]);
            b[3] += t;
            FSQL_ED_FOR(j, 8) a[(j + 1) % 8] = b[j];
            if (i % 16 == 15)
                FSQL_ED_FOR(j, 16)
                    w[j] += w[(j + 9) % 16] + fsql_ed_sha_sigma0(w[(j + 1) % 16]) +
                            fsql_ed_sha_sigma1(w[(j + 14) % 16]);
        }

        FSQL_ED_FOR(i, 8) { a[i] += z[i]; z[i] = a[i]; }

        m += 128;
        n -= 128;
    }

    FSQL_ED_FOR(i, 8) fsql_ed_ts64(x + 8 * i, z[i]);

    return (int)n;
}

static const fsql_ed_u8 fsql_ed_sha_iv[64] = {
    0x6a,0x09,0xe6,0x67,0xf3,0xbc,0xc9,0x08, 0xbb,0x67,0xae,0x85,0x84,0xca,0xa7,0x3b,
    0x3c,0x6e,0xf3,0x72,0xfe,0x94,0xf8,0x2b, 0xa5,0x4f,0xf5,0x3a,0x5f,0x1d,0x36,0xf1,
    0x51,0x0e,0x52,0x7f,0xad,0xe6,0x82,0xd1, 0x9b,0x05,0x68,0x8c,0x2b,0x3e,0x6c,0x1f,
    0x1f,0x83,0xd9,0xab,0xfb,0x41,0xbd,0x6b, 0x5b,0xe0,0xcd,0x19,0x13,0x7e,0x21,0x79
};

/* 64-byte SHA-512 digest of m[0..n) into out[64]. */
static void fsql_ed_sha512(fsql_ed_u8 *out, const fsql_ed_u8 *m, fsql_ed_u64 n)
{
    fsql_ed_u8 h[64], x[256];
    fsql_ed_u64 i, b = n;

    FSQL_ED_FOR(i, 64) h[i] = fsql_ed_sha_iv[i];

    fsql_ed_sha512_blocks(h, m, n);
    m += n;
    n &= 127;
    m -= n;

    FSQL_ED_FOR(i, 256) x[i] = 0;
    FSQL_ED_FOR(i, n) x[i] = m[i];
    x[n] = 128;

    n = 256 - 128 * (n < 112);
    x[n - 9] = (fsql_ed_u8)(b >> 61);
    fsql_ed_ts64(x + n - 8, b << 3);
    fsql_ed_sha512_blocks(h, x, n);

    FSQL_ED_FOR(i, 64) out[i] = h[i];
}

/* ---- Edwards curve group law ------------------------------------------ */

static void fsql_ed_padd(fsql_ed_gf p[4], fsql_ed_gf q[4])
{
    fsql_ed_gf a, b, c, d, t, e, f, g, h;

    fsql_ed_Z(a, p[1], p[0]);
    fsql_ed_Z(t, q[1], q[0]);
    fsql_ed_M(a, a, t);
    fsql_ed_A(b, p[0], p[1]);
    fsql_ed_A(t, q[0], q[1]);
    fsql_ed_M(b, b, t);
    fsql_ed_M(c, p[3], q[3]);
    fsql_ed_M(c, c, fsql_ed_D2);
    fsql_ed_M(d, p[2], q[2]);
    fsql_ed_A(d, d, d);
    fsql_ed_Z(e, b, a);
    fsql_ed_Z(f, d, c);
    fsql_ed_A(g, d, c);
    fsql_ed_A(h, b, a);

    fsql_ed_M(p[0], e, f);
    fsql_ed_M(p[1], h, g);
    fsql_ed_M(p[2], g, f);
    fsql_ed_M(p[3], e, h);
}

static void fsql_ed_cswap(fsql_ed_gf p[4], fsql_ed_gf q[4], fsql_ed_u8 b)
{
    int i;
    FSQL_ED_FOR(i, 4) fsql_ed_sel25519(p[i], q[i], b);
}

static void fsql_ed_ppack(fsql_ed_u8 *r, fsql_ed_gf p[4])
{
    fsql_ed_gf tx, ty, zi;
    fsql_ed_inv25519(zi, p[2]);
    fsql_ed_M(tx, p[0], zi);
    fsql_ed_M(ty, p[1], zi);
    fsql_ed_pack25519(r, ty);
    r[31] ^= fsql_ed_par25519(tx) << 7;
}

static void fsql_ed_scalarmult(fsql_ed_gf p[4], fsql_ed_gf q[4], const fsql_ed_u8 *s)
{
    int i;
    fsql_ed_set25519(p[0], fsql_ed_gf0);
    fsql_ed_set25519(p[1], fsql_ed_gf1);
    fsql_ed_set25519(p[2], fsql_ed_gf1);
    fsql_ed_set25519(p[3], fsql_ed_gf0);
    for (i = 255; i >= 0; --i) {
        fsql_ed_u8 b = (fsql_ed_u8)((s[i / 8] >> (i & 7)) & 1);
        fsql_ed_cswap(p, q, b);
        fsql_ed_padd(q, p);
        fsql_ed_padd(p, p);
        fsql_ed_cswap(p, q, b);
    }
}

static void fsql_ed_scalarbase(fsql_ed_gf p[4], const fsql_ed_u8 *s)
{
    fsql_ed_gf q[4];
    fsql_ed_set25519(q[0], fsql_ed_X);
    fsql_ed_set25519(q[1], fsql_ed_Y);
    fsql_ed_set25519(q[2], fsql_ed_gf1);
    fsql_ed_M(q[3], fsql_ed_X, fsql_ed_Y);
    fsql_ed_scalarmult(p, q, s);
}

/* ---- scalar mod L reduction -------------------------------------------- */

static const fsql_ed_u64 fsql_ed_L[32] = {
    0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58, 0xd6, 0x9c, 0xf7, 0xa2,
    0xde, 0xf9, 0xde, 0x14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x10
};

static void fsql_ed_modL(fsql_ed_u8 *r, fsql_ed_i64 x[64])
{
    fsql_ed_i64 carry, i, j;
    for (i = 63; i >= 32; --i) {
        carry = 0;
        for (j = i - 32; j < i - 12; ++j) {
            x[j] += carry - 16 * x[i] * fsql_ed_L[j - (i - 32)];
            carry = (x[j] + 128) >> 8;
            /* carry can be negative -- shift the unsigned reinterpretation
             * to avoid UB on left-shifting a negative signed value. */
            x[j] -= (fsql_ed_i64)((uint64_t)carry << 8);
        }
        x[j] += carry;
        x[i] = 0;
    }
    carry = 0;
    FSQL_ED_FOR(j, 32) {
        x[j] += carry - (x[31] >> 4) * fsql_ed_L[j];
        carry = x[j] >> 8;
        x[j] &= 255;
    }
    FSQL_ED_FOR(j, 32) x[j] -= carry * fsql_ed_L[j];
    FSQL_ED_FOR(i, 32) {
        x[i + 1] += x[i] >> 8;
        r[i] = (fsql_ed_u8)(x[i] & 255);
    }
}

static void fsql_ed_reduce(fsql_ed_u8 *r)
{
    fsql_ed_i64 x[64], i;
    FSQL_ED_FOR(i, 64) x[i] = (fsql_ed_u64)r[i];
    FSQL_ED_FOR(i, 64) r[i] = 0;
    fsql_ed_modL(r, x);
}

/* ---- public-key point decompression ------------------------------------ */

static int fsql_ed_unpackneg(fsql_ed_gf r[4], const fsql_ed_u8 p[32])
{
    fsql_ed_gf t, chk, num, den, den2, den4, den6;
    fsql_ed_set25519(r[2], fsql_ed_gf1);
    fsql_ed_unpack25519(r[1], p);
    fsql_ed_S(num, r[1]);
    fsql_ed_M(den, num, fsql_ed_D);
    fsql_ed_Z(num, num, r[2]);
    fsql_ed_A(den, r[2], den);

    fsql_ed_S(den2, den);
    fsql_ed_S(den4, den2);
    fsql_ed_M(den6, den4, den2);
    fsql_ed_M(t, den6, num);
    fsql_ed_M(t, t, den);

    fsql_ed_pow2523(t, t);
    fsql_ed_M(t, t, num);
    fsql_ed_M(t, t, den);
    fsql_ed_M(t, t, den);
    fsql_ed_M(r[0], t, den);

    fsql_ed_S(chk, r[0]);
    fsql_ed_M(chk, chk, den);
    if (fsql_ed_neq25519(chk, num)) fsql_ed_M(r[0], r[0], fsql_ed_I);

    fsql_ed_S(chk, r[0]);
    fsql_ed_M(chk, chk, den);
    if (fsql_ed_neq25519(chk, num)) return -1;

    if (fsql_ed_par25519(r[0]) == (p[31] >> 7)) fsql_ed_Z(r[0], fsql_ed_gf0, r[0]);

    fsql_ed_M(r[3], r[0], r[1]);
    return 0;
}

/* ---- top-level Ed25519 "combined" verify (upstream crypto_sign_open) --- */

/* sm points at a 64-byte signature immediately followed by n-64 bytes of
 * message (the TweetNaCl "signed message" layout); pk is the 32-byte
 * public key. Returns 0 and recovers the message into m on success, -1
 * on any failure (bad point, bad signature). m must have room for n
 * bytes (only the leading n-64 are meaningful on success). */
static int fsql_ed_sign_open(fsql_ed_u8 *m, fsql_ed_u64 *mlen,
                              const fsql_ed_u8 *sm, fsql_ed_u64 n,
                              const fsql_ed_u8 *pk)
{
    fsql_ed_u64 i;
    fsql_ed_u8 t[32], h[64];
    fsql_ed_gf p[4], q[4];

    *mlen = (fsql_ed_u64)-1;
    if (n < 64) return -1;

    if (fsql_ed_unpackneg(q, pk)) return -1;

    FSQL_ED_FOR(i, n) m[i] = sm[i];
    FSQL_ED_FOR(i, 32) m[i + 32] = pk[i];
    fsql_ed_sha512(h, m, n);
    fsql_ed_reduce(h);
    fsql_ed_scalarmult(p, q, h);

    fsql_ed_scalarbase(q, sm + 32);
    fsql_ed_padd(p, q);
    fsql_ed_ppack(t, p);

    n -= 64;
    if (fsql_ed_verify32(sm, t)) {
        FSQL_ED_FOR(i, n) m[i] = 0;
        return -1;
    }

    FSQL_ED_FOR(i, n) m[i] = sm[i + 64];
    *mlen = n;
    return 0;
}

/* ---- public API --------------------------------------------------------
 *
 * Detached-signature verify: sig[64] is a signature by the holder of the
 * private key matching pk[32] over msg[0..msglen). Returns 1 if valid,
 * 0 otherwise (bad point, wrong key, tampered message, malformed sig).
 *
 * TweetNaCl only exposes the "combined" crypto_sign_open (signature
 * concatenated with the message it covers, recovering the message on
 * success), not a detached-signature API. This adapts that: build a
 * scratch buffer of sig || msg, hand it to fsql_ed_sign_open, and treat
 * a 0 return (successful recovery of exactly msglen message bytes) as
 * valid. The scratch buffer is heap-allocated since msg here is an
 * entire enterprise .so file (can be several MB).
 */
static int fsql_ed25519_verify_detached(const unsigned char sig[64],
                                         const unsigned char *msg, size_t msglen,
                                         const unsigned char pk[32])
{
    unsigned char *sm, *out;
    fsql_ed_u64 smlen, outlen;
    int rc;

    if (msglen > (size_t)-1 - 64) return 0;   /* overflow guard */

    smlen = (fsql_ed_u64)(msglen + 64);
    sm = (unsigned char *)malloc((size_t)smlen);
    out = (unsigned char *)malloc((size_t)smlen);
    if (!sm || !out) {
        free(sm);
        free(out);
        return 0;
    }

    memcpy(sm, sig, 64);
    if (msglen) memcpy(sm + 64, msg, msglen);

    rc = fsql_ed_sign_open(out, &outlen, sm, smlen, pk);

    free(sm);
    free(out);

    return (rc == 0 && outlen == (fsql_ed_u64)msglen) ? 1 : 0;
}

#endif /* FSQL_ED25519_H */
