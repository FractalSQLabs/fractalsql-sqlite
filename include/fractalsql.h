/* include/fractalsql.h
 *
 * libfractalsql-core — public C ABI.
 *
 * SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
 * SPDX-FileCopyrightText: 2014 Hamid Salimi (SFS algorithmic lineage)
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * This header is the contract. Downstream bindings (Go/Rust/Python/
 * Java/.NET/R/Node/Ruby/PHP/C++/WASM/CLI/ADBC) FFI against the stable
 * symbol set below. Removing or changing an existing signature is an
 * ABI break; the v2 surface was added purely ADDITIVELY (no v1 symbol
 * removed or changed), so v1 consumers keep linking unchanged.
 *
 * Minimal tier (this header — 11 symbols, frozen at the v1 baseline):
 *   fsql_new_minimal, fsql_free, fsql_release, fsql_search,
 *   fsql_search_ptr, fsql_last_error, fsql_edition, fsql_storage,
 *   fsql_version, fsql_abi_version, fsql_free_string.
 *
 * Sovereign tier (declared in fractalsql_sql.h — 22 additional symbols):
 *   5 v1 sovereign-only (fsql_new_sovereign + 4 reasoning ABI calls)
 *   + 17 v2 sovereign-only (diversify / entropy / feedback / ledger /
 *   audit). Total exported sovereign surface = 33 (pinned in
 *   tests/release/expected_symbols-*.txt; map in docs/DISCOVERY_V2_API.md).
 *
 * Design invariants, matched to the 9-factory fleet:
 *
 *   1. IN-PROCESS EXECUTION. No network IO during search calls.
 *   2. ZERO-DEPENDENCY BINARY. Only glibc kernel shortlist on Linux.
 *   3. STABLE C ABI. Symbol names below, unmangled.
 *   4. CRYPTO-NEUTRAL. No cryptographic primitives inside the engine.
 *
 * Threading contract:
 *   Contexts (fsql_ctx) are NOT thread-safe and are NOT thread-affine
 *   at this layer. One context per thread, or serialize access at the
 *   caller. Contexts are cheap to build (<1 us) so per-thread
 *   construction is the idiomatic pattern.
 *
 *   The C ABI does NOT enforce thread affinity in production builds.
 *   This is deliberate: pthread is not a portable runtime dependency
 *   (musl, static-linked, embedded targets), and threading idioms
 *   differ enough across host languages (Java's exception model,
 *   Rust's Send/Sync, Go's goroutines, Unity's main-thread rule)
 *   that a one-size-fits-all check would not retire any binding-side
 *   code. Bindings are the right place for the guard.
 *
 *   Bindings SHOULD enforce thread affinity in their idiomatic style.
 *   Reference patterns from the existing bindings:
 *     - fractalsql-java     → FractalSqlConcurrencyException on cross-thread
 *     - fractalsql-unity    → FractalSqlException via owner-thread guard
 *     - fractalsql-unreal   → context pool keyed by FPlatformTLS::GetCurrentThreadId
 *   See docs/BINDING_THREAD_AFFINITY.md for full templates.
 *
 *   For binding-author CI, core supports an opt-in debug build flag
 *   -DFSQL_DEBUG_THREAD_AFFINITY. When set, fsql_new_minimal/sovereign
 *   capture pthread_self() at construction and ctx-bearing entry
 *   points return FSQL_ERR_WRONG_THREAD on cross-thread call. Off by
 *   default; production builds remain pthread-free.
 *
 * Memory ownership:
 *   - Caller owns all input pointers (corpus/query/params_json).
 *   - Library owns the output JSON via a per-context internal buffer.
 *     The returned *result_json is valid until the next fsql_search*
 *     call on the same context, until fsql_release, or until
 *     fsql_free.
 *   - Caller MUST NOT free *result_json.
 *   - fsql_release early-frees the output buffer for memory-sensitive
 *     callers that want to hold a context across long idle periods
 *     without paying the result-buffer cost.
 *
 * ABI versioning:
 *   fsql_abi_version() returns "2.x.y" on the v2 line (was "1.x" on v1).
 *   v2 is purely ADDITIVE: the 11 minimal symbols are byte-for-byte the
 *   v1 contract and the 5 v1 sovereign symbols are unchanged, so an
 *   existing consumer LINKS unchanged and the new sovereign symbols are
 *   opt-in. Bindings compare the MAJOR component only and must accept
 *   major 2; never branch on minor/patch. Removing or changing an
 *   existing symbol is the event that forces the next major break.
 */

#ifndef FRACTALSQL_H
#define FRACTALSQL_H

#include <stddef.h>

/* Public-symbol visibility macro.
 *
 * Three Windows linkage modes:
 *   FSQL_BUILDING_DLL    → dllexport (we are producing libfractalsql-*.dll)
 *   FSQL_STATIC          → empty   (static .lib build or static consumer)
 *   neither              → dllimport (consumer linking against our DLL)
 *
 * Phase 1 of the v1.1.5 Windows track ships static archives only.
 * scripts/build-windows.ps1 defines FSQL_STATIC so the .lib's .obj
 * files get plain externs (not dllexport flagged); downstream
 * consumers static-linking the .lib should also define FSQL_STATIC
 * at compile time. Phase 2 adds DLL builds, which define
 * FSQL_BUILDING_DLL instead.
 *
 * Linux / macOS use GCC visibility attributes the same way they did
 * pre-v1.1.5; this block is unchanged for non-Windows targets.
 */
#if defined(_WIN32) || defined(__CYGWIN__)
#  if defined(FSQL_STATIC)
#    define FSQL_API
#  elif defined(FSQL_BUILDING_DLL)
#    define FSQL_API __declspec(dllexport)
#  else
#    define FSQL_API __declspec(dllimport)
#  endif
#else
#  if defined(__GNUC__) && __GNUC__ >= 4
#    define FSQL_API __attribute__((visibility("default")))
#  else
#    define FSQL_API
#  endif
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------------------------------------------------------- */
/* Error codes                                                      */
/* ---------------------------------------------------------------- */

#define FSQL_OK              0
#define FSQL_ERR_INVALID    -1   /* null ctx, bad arg count, k <= 0 */
#define FSQL_ERR_PARSE      -2   /* corpus/query text did not parse */
#define FSQL_ERR_DIMENSION  -3   /* mixed dims across corpus rows   */
#define FSQL_ERR_OOM        -4   /* allocation failure              */
#define FSQL_ERR_RUNTIME    -5   /* engine-side failure during run  */

/* V1 sovereign-tier error codes. Returned by sovereign-tier paths
 * that touch the storage VFS (fsql_storage_vfs_t) or reasoning VFS
 * (fsql_reasoning_vfs_t). Minimal-tier never produces these. */
#define FSQL_ESTORAGE             -45  /* generic storage VFS failure */
#define FSQL_ESTORAGE_UNAVAILABLE -46  /* VFS callback returned NULL or unimpl */
#define FSQL_ESTORAGE_INTEGRITY   -47  /* host VFS read_entry signalled an    */
                                       /* integrity failure (its own choice  */
                                       /* of mechanism: HMAC envelope, sig,  */
                                       /* sigstore, etc). Core is integrity- */
                                       /* neutral; this code is propagated   */
                                       /* from the host VFS and triggers     */
                                       /* auto-disable-diversify on load.    */

/* Cross-thread call detected. Only emitted by builds compiled with
 * -DFSQL_DEBUG_THREAD_AFFINITY (binding-author CI). Production builds
 * never produce this code. The constant is reserved in the public
 * surface so binding parsers can recognize it across debug/release. */
#define FSQL_ERR_WRONG_THREAD     -48

/* V2 sovereign-tier error codes. Returned by the diversify / entropy /
 * feedback / ledger / audit APIs added in v2.0.0. Minimal-tier never
 * produces these (the v2 sovereign symbols are not exported on the
 * minimal variant). See FRACTALSQL_CORE_V2_PLAN.txt §8. */
#define FSQL_EDIVERSITY        -50   /* diversify call in bad state         */
#define FSQL_EENTROPY          -51   /* no entropy source satisfies mode    */
#define FSQL_ELEDGER_FULL      -52   /* would exceed cap; eviction failed   */
/* -53 reserved (was ELEDGER_UNSEALED in pre-pivot drafts; retired with     */
/*  the host-VFS integrity boundary)                                        */
#define FSQL_ELEDGER_INTEGRITY -54   /* host VFS read_entry signalled       */
                                     /* integrity failure; alias of         */
                                     /* FSQL_ESTORAGE_INTEGRITY (-47)       */
#define FSQL_ELEDGER_IO        -55   /* underlying storage VFS error        */
#define FSQL_EFEEDBACK_HANDLE  -56   /* result_handle unknown / expired     */
#define FSQL_ETRUNCATED        -57   /* caller-allocated out buffer too     */
                                     /* small; *out_cap reports required    */
                                     /* size (audit_unpack, codec probes)   */

/* RETIRED sentinel (historical). During the v2 Phase-1 ABI freeze every
 * v2 entry point returned -99 until its implementation landed; no shipping
 * code path returns this as of v2.0.0. Kept reserved so a binding built
 * against an early-v2 pre-release can still recognize the value. */
#define FSQL_ENOTIMPL          -99

/* ---------------------------------------------------------------- */
/* Opaque context                                                   */
/* ---------------------------------------------------------------- */

typedef struct fsql_ctx fsql_ctx;

/* Construct a new MINIMAL-tier context (RAM-only Diffusion Arena,
 * no persistence, no reasoning ABI). One engine-backend state, one
 * result buffer. Returns NULL on allocation failure. (The shipped
 * library is pure-C; the LuaJIT-backed build is a parity oracle only.)
 *
 * V1 NOTE: this function REPLACES the pre-V1 fsql_new(). Bindings
 * built against the v0.x ABI (single fsql_new() returning either
 * tier) need to call fsql_new_minimal() explicitly going forward;
 * sovereign-tier customers call fsql_new_sovereign() with explicit
 * VFS injection (see fractalsql_sql.h).
 */
FSQL_API fsql_ctx *fsql_new_minimal(void);

/* Tear down a context. Safe on NULL. Works for ctx returned by
 * either fsql_new_minimal or fsql_new_sovereign. */
FSQL_API void fsql_free(fsql_ctx *ctx);

/* ---------------------------------------------------------------- */
/* String deallocator (V1 — Pattern A/B/C contract)                 */
/* ---------------------------------------------------------------- */

/* Free a string allocated by the library on behalf of the caller.
 * The Pattern A/B/C contract documents three ownership models for
 * strings the library returns:
 *
 *   Pattern A — library-owned, ctx-lifetime:
 *     Pointer valid until next call on same ctx OR fsql_free.
 *     Used by: fsql_search* result_json, fsql_last_error.
 *     Caller MUST NOT free.
 *
 *   Pattern B — caller-owned, malloc'd:
 *     Library mallocs, returns pointer; caller frees via fsql_free_string.
 *     Used by: (none in v1.0 minimal — sovereign reasoning paths
 *     use Pattern B / Pattern C).
 *
 *   Pattern C — caller-owned, paired free:
 *     Library returns a struct with a string pointer + a paired
 *     free function. Used by: fsql_ai_response_free (sovereign).
 *
 * fsql_free_string is the Pattern B deallocator. It MUST be the
 * function called for any string the library documents as
 * "caller-owned, free with fsql_free_string". NULL-safe. Calling
 * directly free()-of-libc on a Pattern B string MAY work today
 * but is not guaranteed across releases (the library reserves the
 * right to use a non-libc allocator internally).
 */
FSQL_API void fsql_free_string(char *s);

/* ---------------------------------------------------------------- */
/* Search — text corpus + text query (CSV / bracketed-JSON)         */
/* ---------------------------------------------------------------- */

/*
 * corpus      : '' or 'v11,v12,...;v21,v22,...;...'
 *               or '[[v11,v12,...],[v21,v22,...],...]'
 * corpus_len  : length in bytes (not bytes-plus-NUL)
 * query       : single vector in the same formats as one corpus row
 * query_len   : length in bytes
 * k           : 1..1,000,000 — number of top matches to return.
 *               If k exceeds the corpus row count, k is silently
 *               clamped to n_rows.
 * params_json : '{}' or a subset of:
 *                 {"iterations":30,
 *                  "population_size":50,
 *                  "diffusion_factor":2,
 *                  "walk":0.5,
 *                  "seed":0,
 *                  "debug":false,
 *                  "return_population":false}
 *               Pass NULL with params_len=0 to use defaults.
 *
 *               "return_population" (default false) selects SCOUT
 *               (discovery) mode: instead of converging on a single
 *               best point (Sniper), the search returns its FINAL
 *               population of "population_size" particles. When a
 *               corpus is supplied, the fitness is min-distance-to-any-
 *               stored-vector, so with no cross-particle best-pull the
 *               particles settle into DISTINCT data basins — the
 *               diversity/discovery workload (many clusters per query,
 *               vs Sniper top-k which collapses to one basin). Scout
 *               defaults "walk" to 0.0 unless the caller sets it.
 *               Scout is a MODE of this call — no new ABI symbol; the
 *               minimal surface stays at its frozen 11. It is the
 *               expensive mode (O(rows * iterations * population) per
 *               query): use it on small or pre-filtered corpora.
 *
 *               "seed" is a JSON number (double-typed, matching
 *               LuaJIT's math.randomseed(d); integer seeds with
 *               |seed| < 2^53 round-trip losslessly). It is the
 *               ONLY control over the SFS walk's stochasticity:
 *
 *                 - Omitted or 0  → the engine synthesizes a
 *                   non-deterministic per-context default (mix of
 *                   wall clock + monotonic clock + ctx pointer).
 *                   Two calls — even same ctx, same inputs — take
 *                   different SFS trajectories and may return
 *                   different best_point / ranking.
 *                 - Any non-zero value → the walk is deterministic
 *                   and byte-stable: identical inputs + identical
 *                   seed produce a byte-equal *result_json across
 *                   calls, across independent contexts, across
 *                   threads, on the same build (regression-locked
 *                   by the seed-determinism golden gate, and
 *                   byte-equal to the LuaJIT parity oracle).
 *
 *               SECURITY: a caller that routes on this output and
 *               cannot tolerate an attacker re-rolling the result
 *               by simply re-issuing the query (a retry/reroll
 *               oracle — e.g. probing past a classifier or guard)
 *               MUST pin "seed" to a value derived deterministically
 *               from the query (plus any tenant/policy salt for
 *               cross-call-stable per-tenant isolation). The default
 *               is intentionally non-deterministic and is NOT a
 *               safe choice for security-sensitive routing.
 * result_json : library-owned pointer, valid until the next
 *               fsql_search* / fsql_release / fsql_free on this ctx.
 * result_len  : length in bytes of *result_json (no trailing NUL).
 *
 * Returns FSQL_OK on success, or a negative FSQL_ERR_* code on
 * failure. On error, fsql_last_error(ctx) returns a human-readable
 * diagnostic string.
 *
 * Output JSON shape:
 *   { "dim": <int>, "n_corpus": <int>,
 *     "best_fit": <double>, "best_point": [d1, ...],
 *     "top_k": [{"idx": <int>, "dist": <double>}, ...],
 *     "population": [[d1, ...], ...],   -- only when return_population
 *     "population_fits": [f1, ...],     -- only when return_population
 *     "trace": { ... }          -- only when params.debug = true
 *   }
 *   "population" holds population_size particles (particle-major);
 *   "population_fits" is the matching per-particle fitness. Both are
 *   absent unless "return_population" is set, so existing top_k /
 *   best_point consumers are unaffected.
 */
FSQL_API int fsql_search(
    fsql_ctx    *ctx,
    const char  *corpus, size_t corpus_len,
    const char  *query,  size_t query_len,
    int          k,
    const char  *params_json, size_t params_len,
    const char **result_json, size_t *result_len);

/*
 * Zero-copy variant. Corpus is a flat row-major double array of
 * n_rows * dim elements; query is query_dim elements. The library
 * does not take ownership of these buffers — they must remain valid
 * for the duration of the call.
 *
 * All other semantics match fsql_search. In particular the output
 * *result_json is the same JSON shape.
 */
FSQL_API int fsql_search_ptr(
    fsql_ctx    *ctx,
    const double *corpus, size_t n_rows, size_t dim,
    const double *query,  size_t query_dim,
    int           k,
    const char   *params_json, size_t params_len,
    const char  **result_json, size_t *result_len);

/* Early-free the internal result buffer on a ctx. Any previously
 * returned *result_json pointer is invalidated. The ctx itself
 * remains usable for further fsql_search* calls (which will lazily
 * re-grow the buffer). Safe on NULL. */
FSQL_API void fsql_release(fsql_ctx *ctx);

/* ---------------------------------------------------------------- */
/* Diagnostics / introspection                                       */
/* ---------------------------------------------------------------- */

/* Human-readable diagnostic for the last failed call on ctx. Returns
 * a pointer to a ctx-owned static-like buffer; valid until the next
 * call on the same ctx. Returns an empty string if ctx is NULL or
 * the last call succeeded. */
FSQL_API const char *fsql_last_error(fsql_ctx *ctx);

/* Returns "Community" or "Enterprise". Reflects the ALGORITHMIC TIER
 * baked in at build time (Community SFS vs. the ENT stack: Sobol QRFS
 * + dFDB V6 + Chaotic + AFDB). Tier is NOT runtime-switchable. */
FSQL_API const char *fsql_edition(void);

/* Returns "Minimal" or "Sovereign". Reflects the STORAGE TIER baked
 * in at build time. Minimal = RAM-only arena, 11-symbol surface
 * (~22 KB stripped on linux-x86_64), no persistence, no reasoning ABI.
 * Sovereign = Minimal + the v2 discovery surface (diversify / feedback
 * ledger / audit) and the reasoning ABI (~55 KB stripped). The core has
 * NO embedded SQL engine: ledger persistence is DELEGATED to the host
 * through the fsql_storage_vfs_t callbacks (the pre-pivot SQLite-
 * amalgamated sovereign was retired). Storage tier is NOT runtime-
 * switchable.
 *
 * Callers who want to probe which Sovereign-only symbols are safe to
 * call (the 22 entry points declared in fractalsql_sql.h) should check
 * this first; those symbols are present in the .dynsym only when
 * storage == "Sovereign".
 */
FSQL_API const char *fsql_storage(void);

/* Returns the library semver baseline, e.g. "2.0.0". (As on the v1
 * line, this tracks the MAJOR.0.0 baseline, not the patch tag; the
 * exact release tag lives in the drop VERSION file / tarball name.) */
FSQL_API const char *fsql_version(void);

/* Returns the ABI-compatibility version, e.g. "2.0.0". Bindings may
 * log this or compare it during initialization; bindings MUST NOT
 * branch on minor/patch, only on major. */
FSQL_API const char *fsql_abi_version(void);

#ifdef __cplusplus
}  /* extern "C" */
#endif

#endif  /* FRACTALSQL_H */
