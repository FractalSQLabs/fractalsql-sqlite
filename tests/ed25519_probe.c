/* tests/ed25519_probe.c
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * Standalone unit test for src/fsql_ed25519.h's one public entry point,
 * fsql_ed25519_verify_detached(). That header's own comment says this
 * exact check ("validated against the RFC 8032 Section 7.1 test
 * vectors... plus a corrupted-signature rejection check") was done once
 * during development and "kept out of the shipped build" -- this file
 * is that check, finally committed, built by build_test.sh's gate 35.
 *
 * Why this needs its own translation unit rather than a SQL-level
 * test: fsql_ed25519_verify_detached() is reachable from SQL only
 * through fsql_enterprise.c's dlopen'd-library signature check, which
 * verifies against a hardcoded production public key -- the matching
 * private key is held offline and never in CI (see fsql_enterprise.c's
 * own FSQL_ENTERPRISE_PUBKEY comment). That's a correct security
 * boundary, not a gap: it means the "a real FractalSQLabs-signed
 * library loads" integration path can never be exercised here, by
 * design. But the verify primitive itself takes the public key as a
 * plain parameter, so it's fully unit-testable with throwaway keys --
 * this file does exactly that, independent of the real key entirely.
 *
 * Build (matches the Makefile's COVERAGE recipe exactly, so the
 * resulting .gcda merges with the main build's: -O1 -g --coverage,
 * same -Isrc the real build resolves "fsql_ed25519.h" through, run
 * from the repo root so the recorded source path matches):
 *   cc -std=c11 -O1 -g --coverage -Isrc -c tests/ed25519_probe.c \
 *      -o src/_ed25519_probe.o
 *   cc --coverage src/_ed25519_probe.o -o <tmp>/ed25519_probe
 */
#include "fsql_ed25519.h"

#include <stdio.h>
#include <string.h>

static int failed = 0;

static void check(const char *label, int cond) {
    if (cond) {
        printf("OK: %s\n", label);
    } else {
        failed = 1;
        printf("FAIL: %s\n", label);
    }
}

static int hex_nibble(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static void hex_decode(const char *hex, unsigned char *out, size_t outlen) {
    for (size_t i = 0; i < outlen; i++) {
        out[i] = (unsigned char)((hex_nibble(hex[2 * i]) << 4) |
                                  hex_nibble(hex[2 * i + 1]));
    }
}

int main(void) {
    /* RFC 8032 Section 7.1, TEST 1: empty message. */
    {
        unsigned char pk[32];
        unsigned char sig[64];
        hex_decode("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
                   pk, 32);
        hex_decode(
            "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155"
            "5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b",
            sig, 64);
        check("RFC 8032 TEST 1 (empty message) verifies",
              fsql_ed25519_verify_detached(sig, (const unsigned char *)"", 0, pk) == 1);
    }

    /* RFC 8032 Section 7.1, TEST 2: 1-byte message 0x72. */
    {
        unsigned char pk[32];
        unsigned char sig[64];
        unsigned char msg[1] = { 0x72 };
        hex_decode("3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c",
                   pk, 32);
        hex_decode(
            "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da"
            "085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00",
            sig, 64);
        check("RFC 8032 TEST 2 (1-byte message) verifies",
              fsql_ed25519_verify_detached(sig, msg, 1, pk) == 1);
    }

    /* A throwaway (openssl genpkey -algorithm ed25519) keypair signing
     * an arbitrary message, to prove this isn't somehow special-cased
     * to only the two RFC constants above. */
    {
        unsigned char pk[32];
        unsigned char sig[64];
        const unsigned char msg[] = "fractalsql ed25519 probe test message";
        hex_decode("6039fdbde399bd5c9cdc64ee81d808c71271261d1be4c4e8bceecc2bd53bcd02",
                   pk, 32);
        hex_decode("28fd59dd343355a09a6f17a742c48607f4c626d3f612b4aef2f9d6b8ff176bc876fc87f4baaad353f8747d4ea8f327caf386caf416cd4b7fb56d51a649f2fb06",
                   sig, 64);
        check("throwaway-key signature verifies",
              fsql_ed25519_verify_detached(sig, msg, sizeof(msg) - 1, pk) == 1);

        /* Tampered message: same sig/pk, one byte of the message flipped. */
        unsigned char bad_msg[sizeof(msg)];
        memcpy(bad_msg, msg, sizeof(msg));
        bad_msg[0] ^= 0x01;
        check("tampered message is rejected",
              fsql_ed25519_verify_detached(sig, bad_msg, sizeof(msg) - 1, pk) == 0);

        /* Wrong public key: same sig/message, one byte of pk flipped. */
        unsigned char bad_pk[32];
        memcpy(bad_pk, pk, 32);
        bad_pk[0] ^= 0x01;
        check("mismatched public key is rejected",
              fsql_ed25519_verify_detached(sig, msg, sizeof(msg) - 1, bad_pk) == 0);

        /* Corrupted signature: same message/pk, one byte of sig flipped. */
        unsigned char bad_sig[64];
        memcpy(bad_sig, sig, 64);
        bad_sig[0] ^= 0x01;
        check("corrupted signature is rejected",
              fsql_ed25519_verify_detached(bad_sig, msg, sizeof(msg) - 1, pk) == 0);
    }

    return failed ? 1 : 0;
}
