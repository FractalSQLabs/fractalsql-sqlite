/* SPDX-License-Identifier: Apache-2.0 */
/* fsql_plugin_verify.h -- authenticity gate for the reasoning plugin.
 *
 * The reasoning plugin is a native shared object loaded into the server
 * process: loading it is arbitrary code execution. This header applies the
 * same trust rule the enterprise core already uses before the plugin is
 * mapped:
 *
 *   1. FSQL_REASONING_REQUIRE_SIGNATURE=0 in the process environment is
 *      the operator's opt-out: a plugin with no .sig still loads (a
 *      one-line warning goes to stderr). A .sig that is present is always
 *      checked, and a wrong one is always refused.
 *   2. Otherwise (the default) a detached Ed25519 signature, <plugin>.sig (exactly 64
 *      bytes) over the plugin's exact bytes, must verify against the
 *      FractalSQLabs reasoning-plugin signing public key below (a
 *      different key from the one that signs the enterprise core).
 *
 * Anything else is refused. fsql_plugin_gate() is called before the load and
 * again after it (fsql_plugin_gate_after_load), so a file swapped between
 * the check and the dlopen is caught.
 */
#ifndef FSQL_PLUGIN_VERIFY_H
#define FSQL_PLUGIN_VERIFY_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "fsql_ed25519.h"
#include "fsql_hmac.h"

/* The FractalSQLabs reasoning-plugin signing public key. A plugin release is
 * signed with the matching private key; its detached <plugin>.sig (64 raw
 * bytes) must verify against this key before the plugin is loaded. It is a
 * different key from the enterprise-core key. Compiled in; no setting can
 * replace it. */
static const unsigned char FSQL_PLUGIN_SIGNING_PUBKEY[32] = {
    0xbb, 0x24, 0x79, 0x25, 0x84, 0xe8, 0x9b, 0x1d, 0x1b, 0x48, 0x49, 0xba,
    0x70, 0x1d, 0xa1, 0x71, 0xa3, 0x4f, 0x8a, 0x29, 0x47, 0x83, 0xd1, 0xd4,
    0x74, 0xdf, 0x9b, 0x07, 0x44, 0xc5, 0x94, 0x53
};

/* Returns 0 = trusted, -1 = refused (err filled). */
static int fsql_plugin_gate(const char *path, char *err, size_t err_cap) {
    /* A signature is required unless the process environment says FSQL_REASONING_REQUIRE_SIGNATURE=0.
     * With it off, a plugin that has no .sig still loads (with a one-time warning); a .sig that is
     * present is always checked, and a wrong one is always refused. */
    const char *rq = getenv("FSQL_REASONING_REQUIRE_SIGNATURE");
    const int require = !(rq && rq[0] == '0');

    FILE *f = fopen(path, "rb");
    if (!f) {
        if (!require) return 0;     /* the loader reports an unreadable plugin itself */
        snprintf(err, err_cap, "reasoning plugin \"%s\" cannot be read for verification", path);
        return -1;
    }
    unsigned char *bytes = NULL;
    long len = -1;
    if (fseek(f, 0, SEEK_END) == 0) len = ftell(f);
    if (len < 0 || fseek(f, 0, SEEK_SET) != 0) { fclose(f); snprintf(err, err_cap, "reasoning plugin \"%s\" cannot be read for verification", path); return -1; }
    bytes = (unsigned char *)malloc((size_t)len ? (size_t)len : 1);
    if (!bytes || fread(bytes, 1, (size_t)len, f) != (size_t)len) {
        fclose(f); free(bytes);
        snprintf(err, err_cap, "reasoning plugin \"%s\" cannot be read for verification", path);
        return -1;
    }
    fclose(f);

    char sig_path[1024];
    unsigned char sig[64];
    if (snprintf(sig_path, sizeof sig_path, "%s.sig", path) >= (int)sizeof sig_path) {
        free(bytes);
        snprintf(err, err_cap, "reasoning plugin path is too long to locate its .sig");
        return -1;
    }
    f = fopen(sig_path, "rb");
    if (!f) {
        free(bytes);
        if (!require) {
            static int warned = 0;
            if (!warned) {
                warned = 1;
                fprintf(stderr, "fractalsql: loading reasoning plugin \"%s\" without a signature "
                                "(FSQL_REASONING_REQUIRE_SIGNATURE=0)\n", path);
            }
            return 0;
        }
        snprintf(err, err_cap,
                 "no signature found for reasoning plugin \"%s\" (expected \"%s.sig\"); place the .sig "
                 "beside the plugin, or set FSQL_REASONING_REQUIRE_SIGNATURE=0 to load an unsigned plugin", path, path);
        return -1;
    }
    size_t n = fread(sig, 1, sizeof sig, f);
    int extra = fgetc(f);
    fclose(f);
    if (n != sizeof sig || extra != EOF ||
        !fsql_ed25519_verify_detached(sig, bytes, (size_t)len, FSQL_PLUGIN_SIGNING_PUBKEY)) {
        free(bytes);
        snprintf(err, err_cap,
                 "reasoning plugin \"%s\" failed signature verification -- refusing to load (the plugin or its "
                 ".sig is corrupt or not from FractalSQLabs)", path);
        return -1;
    }
    free(bytes);
    return 0;
}

#endif /* FSQL_PLUGIN_VERIFY_H */
