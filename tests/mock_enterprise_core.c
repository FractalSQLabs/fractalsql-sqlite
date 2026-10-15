/* tests/mock_enterprise_core.c
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * Test-only stand-in for the real, licensed enterprise core .so
 * (libfractalsql-enterprise-sovereign-c.so/.dylib), which this public
 * repo does not ship. Built only from the public fractalsql.h, so
 * fsql_ctx is opaque to it; every function below ignores the ctx
 * argument and returns a canned, test-controlled result instead of
 * doing real work.
 *
 * What this exercises: fsql_enterprise.c's own integration code --
 * ensure_enterprise_lib()'s dlopen/dlsym/signature-verification
 * machinery, and every fractal_ledger_ and fractal_optimize_portfolio_
 * multimodal UDF's argument validation, ctx acquire/release, and
 * success/failure branch on the resolved function pointer's return
 * code -- which is untested without something loadable at
 * fractalsql.enterprise_lib. Used by build_test.sh's gate 24.
 *
 * Controlled via one environment variable naming a sentinel file
 * rather than holding a boolean directly: FSQL_MOCK_ENT_FAIL is fixed
 * for a backend's whole process lifetime (plain getenv, read fresh on
 * every call but the process's own environ never changes after fork),
 * so a literal on/off value in it could only be flipped by forking a
 * fresh backend. A sentinel path lets the test instead touch/remove
 * that file between SQL calls: file present -> every call fails
 * (FSQL_ESTORAGE); absent, or the env var itself unset -> every call
 * succeeds. access(2), not a cached fopen: must see every create/unlink
 * the test makes without this library being reloaded.
 *
 * Build: cc -shared -fPIC -std=c99 -I<repo>/include \
 *          tests/mock_enterprise_core.c -o <tmp>/mock_enterprise_core.so
 */
#include "fractalsql.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
/* access()/F_OK are POSIX (<unistd.h>); MSVC's CRT has no unistd.h at
 * all. <io.h>'s _access() is the direct MSVC CRT equivalent; its mode 0
 * means the same "existence only" check POSIX's F_OK does. */
#if defined(_WIN32)
#include <io.h>
#define access _access
#ifndef F_OK
#define F_OK 0
#endif
#else
#include <unistd.h>
#endif

static int mock_should_fail(void) {
    const char *path = getenv("FSQL_MOCK_ENT_FAIL");
    return path != NULL && path[0] != '\0' && access(path, F_OK) == 0;
}

/* Same sentinel-file convention as mock_should_fail: when present, the
 * portfolio_multimodal family returns FSQL_OK with *out_n_found = 0
 * (a legitimate "search ran, found nothing" result) instead of the
 * canned single candidate -- otherwise unreachable through this mock,
 * since it always finds exactly one. */
static int mock_should_find_zero(void) {
    const char *path = getenv("FSQL_MOCK_ENT_ZERO_FOUND");
    return path != NULL && path[0] != '\0' && access(path, F_OK) == 0;
}

/* ---- the 8 required symbols (ensure_enterprise_lib's own check) ---- */

FSQL_API int fsql_ledger_flush(fsql_ctx *ctx) {
    (void) ctx;
    return mock_should_fail() ? FSQL_ESTORAGE : FSQL_OK;
}

FSQL_API int fsql_ledger_load(fsql_ctx *ctx) {
    (void) ctx;
    return mock_should_fail() ? FSQL_ESTORAGE : FSQL_OK;
}

FSQL_API int fsql_ledger_compact(fsql_ctx *ctx) {
    (void) ctx;
    return mock_should_fail() ? FSQL_ESTORAGE : FSQL_OK;
}

FSQL_API int fsql_ledger_reset_soft(fsql_ctx *ctx) {
    (void) ctx;
    return mock_should_fail() ? FSQL_ESTORAGE : FSQL_OK;
}

FSQL_API int fsql_ledger_reset_hard(fsql_ctx *ctx) {
    (void) ctx;
    return mock_should_fail() ? FSQL_ESTORAGE : FSQL_OK;
}

FSQL_API int fsql_ledger_truth_count(const fsql_ctx *ctx, size_t *out) {
    (void) ctx;
    if (mock_should_fail()) return FSQL_ESTORAGE;
    *out = 0;
    return FSQL_OK;
}

FSQL_API int fsql_ledger_shadow_count(const fsql_ctx *ctx, size_t *out) {
    (void) ctx;
    if (mock_should_fail()) return FSQL_ESTORAGE;
    *out = 0;
    return FSQL_OK;
}

/* Pure echo, not real unpacking (see the file header): copies the
 * caller's blob back out verbatim, exercising fractal_audit_unpack's
 * own buffer-growth retry loop (FSQL_ETRUNCATED when it doesn't fit)
 * without claiming to decode anything. */
FSQL_API int fsql_audit_unpack(const void *blob, size_t blob_len,
                               char *json_out, size_t *json_cap) {
    if (mock_should_fail()) return FSQL_ESTORAGE;
    if (blob_len > *json_cap) {
        *json_cap = blob_len;
        return FSQL_ETRUNCATED;
    }
    if (blob_len > 0) memcpy(json_out, blob, blob_len);
    *json_cap = blob_len;
    return FSQL_OK;
}

/* ---- optional symbols (fsql_optimize_portfolio_multimodal family) -- */

/* One canned candidate: uniform weights over the first k assets,
 * everything past asset k-1 left at 0.0. Real diversity/Sharpe search
 * is the proprietary core's job; this just gives the UDF-level JSON
 * assembly loop real, bounded data to walk. */
static void
mock_uniform_weights(double *out_weights, size_t n_assets, size_t k) {
    size_t i;
    double w = (k > 0) ? (1.0 / (double) k) : 0.0;
    for (i = 0; i < n_assets; i++) out_weights[i] = (i < k) ? w : 0.0;
}

FSQL_API int
fsql_optimize_portfolio_multimodal(const double *mu, const double *cov,
                                   size_t n_assets, size_t k,
                                   int n_restarts,
                                   double overlap_threshold,
                                   double quality_frac,
                                   uint64_t seed,
                                   double *out_weights,
                                   double *out_sharpes,
                                   int *out_n_found) {
    (void) mu; (void) cov; (void) n_restarts;
    (void) overlap_threshold; (void) quality_frac; (void) seed;
    if (mock_should_fail()) return FSQL_ESTORAGE;
    if (mock_should_find_zero()) { *out_n_found = 0; return FSQL_OK; }
    mock_uniform_weights(out_weights, n_assets, k);
    out_sharpes[0] = 0.5;
    *out_n_found = 1;
    return FSQL_OK;
}

FSQL_API int
fsql_optimize_portfolio_multimodal_ex(const double *mu, const double *cov,
                                      size_t n_assets, size_t k,
                                      int n_restarts,
                                      double overlap_threshold,
                                      double quality_frac,
                                      uint64_t seed,
                                      int use_obl, int diffusion_mode,
                                      double *out_weights,
                                      double *out_sharpes,
                                      int *out_n_found) {
    (void) mu; (void) cov; (void) n_restarts;
    (void) overlap_threshold; (void) quality_frac; (void) seed;
    (void) use_obl; (void) diffusion_mode;
    if (mock_should_fail()) return FSQL_ESTORAGE;
    if (mock_should_find_zero()) { *out_n_found = 0; return FSQL_OK; }
    mock_uniform_weights(out_weights, n_assets, k);
    out_sharpes[0] = 0.5;
    *out_n_found = 1;
    return FSQL_OK;
}

FSQL_API int
fsql_optimize_portfolio_multimodal_pareto(const double *mu, const double *cov,
                                          size_t n_assets, size_t k,
                                          int n_restarts, int max_front,
                                          uint64_t seed,
                                          int use_obl, int diffusion_mode,
                                          double *out_weights,
                                          double *out_returns,
                                          double *out_risks,
                                          int *out_n_found) {
    (void) mu; (void) cov; (void) n_restarts; (void) max_front;
    (void) seed; (void) use_obl; (void) diffusion_mode;
    if (mock_should_fail()) return FSQL_ESTORAGE;
    if (mock_should_find_zero()) { *out_n_found = 0; return FSQL_OK; }
    mock_uniform_weights(out_weights, n_assets, k);
    out_returns[0] = 0.1;
    out_risks[0]   = 0.05;
    *out_n_found   = 1;
    return FSQL_OK;
}
