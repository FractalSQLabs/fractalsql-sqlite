/* src/fsql_enterprise.c
 *
 * fractalsql-sqlite: enterprise core loader.
 *
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * The Ed25519-gated dlopen of the separately licensed FractalSQL
 * Enterprise core.
 *
 * Why this TU exists
 * ------------------
 * The community sovereign archive does NOT export the ledger/audit
 * surface (fsql_ledger_flush/load/compact/reset_soft/reset_hard/
 * truth_count/shadow_count, fsql_audit_unpack) or the multimodal
 * portfolio surface (fsql_optimize_portfolio_multimodal/
 * _multimodal_pareto; fsql_optimize_portfolio_ex is community and
 * links directly, while the vendor header marks the rest
 * "enterprise-gated, absent from a community-compiled object"). A
 * statically-linked call to any of them cannot resolve at link time:
 * the MSVC link proved it (LNK2001 x10) against include/windows-x86_64/
 * fractalsql-community-sovereign-c.lib, and grep confirms the symbols
 * are absent from the Linux .a drops too. So the enterprise core is
 * dlopen'd at call time from cfg.enterprise_lib and resolved with
 * dlsym/GetProcAddress.
 *
 * Ed25519 signature verification
 * -------------------------------
 * A real Ed25519 verify of the .sig's 64 bytes over the enterprise
 * library's exact bytes against a fixed FractalSQLabs public key --
 * using a small vendored, header-only Ed25519 implementation
 * (src/fsql_ed25519.h, adapted from TweetNaCl, public domain) instead
 * of OpenSSL, so the extension still links no new library (see
 * fsql_ed25519.h's own header comment; the same "vendor it instead of
 * linking OpenSSL" approach fsql_hmac.h already uses for SHA-256/
 * HMAC-SHA256).
 *
 * Effective signature policy
 * --------------------------
 * enterprise_require_signature is a SQL-settable config key, and every
 * principal that can run SQL against the connection can call
 * fractalsql_set() -- a key any statement author can flip to 0 is not
 * an operator control. So the SQL key can only ever STRENGTHEN the
 * check; weakening it requires a process-environment opt-out that no
 * SQL statement can touch:
 *
 *   - FSQL_ENTERPRISE_ALLOW_UNVERIFIED unset (the default): signature
 *     verification is MANDATORY -- the library must carry a .sig that
 *     verifies, or the load is refused, regardless of the SQL key.
 *   - FSQL_ENTERPRISE_ALLOW_UNVERIFIED set to a non-empty value: the
 *     SQL key governs, restoring the original "loading unverified is
 *     the operator's choice" behavior:
 *       - enterprise_require_signature = 0 (default): a missing .sig is
 *         tolerated; a PRESENT .sig is still fully verified -- if it
 *         doesn't check out the load is refused regardless (see
 *         ENT_SIG_INVALID below).
 *       - enterprise_require_signature = 1: a library without a .sig
 *         sidecar is refused. A library WITH a .sig must verify.
 *
 * The library path itself is locked once a library has loaded
 * successfully: the loaded image is the trust anchor, and re-pointing
 * it mid-session would let a SQL principal swap it out from under the
 * already-verified surface. Re-open the connection to re-evaluate.
 *
 * FractalSQLabs signs enterprise releases with a single long-lived
 * key (FSQL_ENTERPRISE_PUBKEY below).
 *
 * Caching
 * -------
 * One attempt per connection: one attempt per FsqlState, success or
 * failure, sticks for the state's life; re-set enterprise_lib and
 * reopen the connection to re-evaluate. A successfully loaded handle
 * is intentionally never closed: dlopen refcounts make the
 * accumulation bounded by the number of distinct enterprise libs.
 */

#include "fsql_sqlite_internal.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
#else
#define _POSIX_C_SOURCE 200809L
#include <dlfcn.h>
#endif

#include "fsql_ed25519.h"

/* -------------------------------------------------------------------
 * OS shims.
 * ------------------------------------------------------------------- */

static void *ent_dlopen(const char *path) {
#ifdef _WIN32
    return (void *)(uintptr_t)LoadLibraryA(path);
#else
    return dlopen(path, RTLD_NOW | RTLD_LOCAL);
#endif
}

static void *ent_dlsym(void *handle, const char *name) {
#ifdef _WIN32
    return (void *)(uintptr_t)GetProcAddress((HMODULE)(uintptr_t)handle, name);
#else
    return dlsym(handle, name);
#endif
}

/* Only the FAILED-load handle is closed (never a live one). */
static void ent_dlclose_failed(void *handle) {
#ifdef _WIN32
    FreeLibrary((HMODULE)(uintptr_t)handle);
#else
    dlclose(handle);
#endif
}

/* -------------------------------------------------------------------
 * Detached Ed25519 signature verification. Optional hardening on top
 * of the 8-symbol dlsym sanity check below: that check only proves
 * "this file has the right function names," which a tampered file
 * with the same names sails through untouched. This verifies a
 * detached Ed25519 signature (a sibling <path>.sig file, exactly 64
 * raw bytes) over the enterprise library's exact bytes, against a
 * fixed FractalSQLabs public key embedded here. New enterprise
 * releases only need a fresh signature from the same long-lived
 * private key -- no change to this extension required.
 *
 * FractalSQLabs's long-lived Ed25519 signing public key
 * (FSQL_ENTERPRISE_PUBKEY). The matching private key is held offline
 * in the enterprise release process, never in this git repo.
 * ------------------------------------------------------------------- */

static const unsigned char FSQL_ENTERPRISE_PUBKEY[32] = {
    0xd5, 0xf6, 0x08, 0xa5, 0x8b, 0x1e, 0xb7, 0xe5, 0x9a, 0xcb, 0x8f, 0xab,
    0x80, 0x35, 0x9d, 0x58, 0x3f, 0x4e, 0xd1, 0xd1, 0xa2, 0x9c, 0x33, 0x6b,
    0xcb, 0x4b, 0x43, 0xcf, 0xf1, 0x07, 0x7f, 0xcb
};

typedef enum {
    ENT_SIG_OK = 0,     /* .sig present and verifies against the pubkey */
    ENT_SIG_MISSING,    /* no .sig file found -- soft unless require=on */
    ENT_SIG_INVALID,    /* .sig present but wrong -- always fatal       */
    ENT_SIG_IOERROR     /* could not read the library file itself      */
} ent_sig_result_t;

static ent_sig_result_t ent_check_signature(const char *lib_path) {
    char sig_path[1024];
    unsigned char sig_bytes[64];
    unsigned char *lib_bytes = NULL;
    long lib_len;
    ent_sig_result_t result;
    FILE *f;

    /* A path too long to even form the sidecar name is not "no .sig
     * found" -- returning MISSING here would silently skip verifying a
     * .sig that may well be present next to the library. Fail closed. */
    if (snprintf(sig_path, sizeof sig_path, "%s.sig", lib_path)
            >= (int)sizeof sig_path)
        return ENT_SIG_INVALID;

    f = fopen(sig_path, "rb");
    if (!f) return ENT_SIG_MISSING;
    {
        size_t n = fread(sig_bytes, 1, sizeof sig_bytes, f);
        /* Confirm the file is EXACTLY 64 bytes, not >=64 -- a longer
         * file silently truncated by fread would otherwise verify
         * against the wrong (partial) signature. */
        int c = fgetc(f);
        fclose(f);
        if (n != sizeof sig_bytes || c != EOF)
            return ENT_SIG_INVALID; /* wrong-sized .sig: corrupt/tampered, not "absent" */
    }

    f = fopen(lib_path, "rb");
    if (!f) return ENT_SIG_IOERROR;
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return ENT_SIG_IOERROR; }
    lib_len = ftell(f);
    if (lib_len < 0 || fseek(f, 0, SEEK_SET) != 0) {
        fclose(f);
        return ENT_SIG_IOERROR;
    }
    lib_bytes = (unsigned char *)malloc((size_t)lib_len);
    if (!lib_bytes) { fclose(f); return ENT_SIG_IOERROR; }
    if (fread(lib_bytes, 1, (size_t)lib_len, f) != (size_t)lib_len) {
        fclose(f);
        free(lib_bytes);
        return ENT_SIG_IOERROR;
    }
    fclose(f);

    result = fsql_ed25519_verify_detached(sig_bytes, lib_bytes,
                                           (size_t)lib_len,
                                           FSQL_ENTERPRISE_PUBKEY)
             ? ENT_SIG_OK : ENT_SIG_INVALID;
    free(lib_bytes);
    return result;
}

/* -------------------------------------------------------------------
 * ensure: 1 = enterprise surface live, 0 = not (reason in err).
 * ------------------------------------------------------------------- */

int fsql_enterprise_ensure(FsqlState *st, char *err, size_t err_cap) {
    if (!st) {
        if (err) snprintf(err, err_cap,
            "fractalsql: extension not initialized");
        return 0;
    }
    if (st->ent_loaded) return 1;
    if (st->ent_attempted) {
        if (err) snprintf(err, err_cap,
            "fractalsql: enterprise tier not loaded (an earlier attempt "
            "failed -- set enterprise_lib and reopen the connection)");
        return 0;
    }
    st->ent_attempted = 1;

    /* Effective signature policy (see the header comment): mandatory
     * unless the operator opted out via the environment. The SQL key
     * can raise the bar, never lower it below the env-decided default. */
    int require = st->cfg.enterprise_require_signature;
    const char *allow_unverified = getenv("FSQL_ENTERPRISE_ALLOW_UNVERIFIED");
    if (!allow_unverified || !allow_unverified[0]) require = 1;

    const char *lib = st->cfg.enterprise_lib;
    if (!lib || !lib[0]) {
        if (err) snprintf(err, err_cap,
            "fractalsql: enterprise tier not loaded (install FractalSQL "
            "Enterprise and set enterprise_lib to its path)");
        return 0;
    }

    ent_sig_result_t sig = ent_check_signature(lib);
    if (sig == ENT_SIG_INVALID) {
        /* A present-but-wrong .sig is always fatal, regardless of
         * enterprise_require_signature -- a corrupt/tampered file must
         * never load silently just because verification is optional. */
        if (err) snprintf(err, err_cap,
            "fractalsql: enterprise library failed signature "
            "verification -- refusing to load (the library or its "
            ".sig does not match the expected FractalSQLabs signing "
            "key; the file may be corrupt or tampered)");
        return 0;
    }
    if (sig == ENT_SIG_MISSING && require) {
        if (err) snprintf(err, err_cap,
            "fractalsql: no signature found for enterprise library "
            "(expected a .sig sidecar) -- signature verification is "
            "mandatory unless FSQL_ENTERPRISE_ALLOW_UNVERIFIED is set "
            "in the process environment");
        return 0;
    }
    if (sig == ENT_SIG_IOERROR && require) {
        /* Mandatory mode fails closed: if the library's bytes cannot
         * even be read for verification, it does not load. (In
         * operator-opted-out mode this stays permissive, falling
         * through to the dlopen attempt below, which fails cleanly on
         * a genuinely unreadable/absent file.) */
        if (err) snprintf(err, err_cap,
            "fractalsql: could not read enterprise library for "
            "signature verification -- refusing to load");
        return 0;
    }
    /* ENT_SIG_OK, ENT_SIG_MISSING+require=off, and ENT_SIG_IOERROR
     * (operator opt-out only) all proceed to the dlopen attempt below,
     * which will itself fail cleanly if the library file is genuinely
     * unreadable/absent. */

    void *h = ent_dlopen(lib);
    if (!h) {
        if (err) snprintf(err, err_cap,
            "fractalsql: could not load enterprise library");
        return 0;
    }

    /* TOCTOU narrowing: the bytes verified above and the image the
     * loader just mapped are bound together only by the pathname, so a
     * writer with access to the library's directory can swap the file
     * between verification and load. Re-verify the on-disk bytes now
     * that the load has happened and apply the same acceptance rule:
     * a swap is caught here and the handle is discarded unused.
     * Residual risk, documented rather than hidden: constructors of a
     * swapped-in file still ran at load time -- closing that needs an
     * exclusive-open handoff to the loader, which has no portable
     * dlopen/LoadLibrary form. */
    {
        ent_sig_result_t sig2 = ent_check_signature(lib);
        int ok2 = (sig2 == ENT_SIG_OK) ||
                  (sig2 == ENT_SIG_MISSING && !require) ||
                  (sig2 == ENT_SIG_IOERROR && !require);
        if (!ok2) {
            if (err) snprintf(err, err_cap,
                "fractalsql: enterprise library changed between "
                "signature verification and load -- refusing to use it "
                "(the file was swapped or modified; retry with a "
                "stable library file)");
            ent_dlclose_failed(h);
            memset(&st->ent, 0, sizeof st->ent);
            return 0;
        }
    }

    memset(&st->ent, 0, sizeof st->ent);
    st->ent.ledger_flush = (fsql_ent_ledger_fn)ent_dlsym(h, "fsql_ledger_flush");
    st->ent.ledger_load = (fsql_ent_ledger_fn)ent_dlsym(h, "fsql_ledger_load");
    st->ent.ledger_compact = (fsql_ent_ledger_fn)ent_dlsym(h, "fsql_ledger_compact");
    st->ent.ledger_reset_soft = (fsql_ent_ledger_fn)ent_dlsym(h, "fsql_ledger_reset_soft");
    st->ent.ledger_reset_hard = (fsql_ent_ledger_fn)ent_dlsym(h, "fsql_ledger_reset_hard");
    st->ent.ledger_truth_count = (fsql_ent_count_fn)ent_dlsym(h, "fsql_ledger_truth_count");
    st->ent.ledger_shadow_count = (fsql_ent_count_fn)ent_dlsym(h, "fsql_ledger_shadow_count");
    st->ent.audit_unpack = (fsql_ent_audit_unpack_fn)ent_dlsym(h, "fsql_audit_unpack");

    if (!st->ent.ledger_flush || !st->ent.ledger_load ||
        !st->ent.ledger_compact || !st->ent.ledger_reset_soft ||
        !st->ent.ledger_reset_hard || !st->ent.ledger_truth_count ||
        !st->ent.ledger_shadow_count || !st->ent.audit_unpack) {
        if (err) snprintf(err, err_cap,
            "fractalsql: library is missing expected enterprise symbols "
            "(fsql_ledger_*/fsql_audit_unpack) -- not a FractalSQL "
            "Enterprise core library?");
        ent_dlclose_failed(h);
        memset(&st->ent, 0, sizeof st->ent);
        return 0;
    }

    /* Optional symbols, tolerant-absence convention. Call sites check
     * for NULL and report the upgrade hint. */
    st->ent.optimize_portfolio_multimodal =
        (fsql_ent_portfolio_mm_fn)ent_dlsym(h, "fsql_optimize_portfolio_multimodal");
    st->ent.optimize_portfolio_multimodal_pareto =
        (fsql_ent_portfolio_pareto_fn)ent_dlsym(h, "fsql_optimize_portfolio_multimodal_pareto");
    st->ent.optimize_portfolio_multimodal_ex =
        (fsql_ent_portfolio_mm_ex_fn)ent_dlsym(h, "fsql_optimize_portfolio_multimodal_ex");

    st->ent_handle = h;
    st->ent_loaded = 1;
    return 1;
}