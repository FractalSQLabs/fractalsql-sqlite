/* include/fractalsql_sql.h
 *
 * libfractalsql-core — Sovereign-tier C ABI (V1).
 *
 * SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * V1 PIVOT (lands in Phases 1-5 of FRACTALSQL_V1_IMPLEMENTATION_PLAN.txt):
 *
 *   The sovereign tier no longer ships an inline SQLite layer. Instead
 *   it exposes a VFS-injection model: callers supply a
 *   fsql_storage_vfs_t (for persistence) and/or a fsql_reasoning_vfs_t
 *   (for inference) at construction time. Both may be NULL — sovereign
 *   without storage is a search-only tier with the reasoning surface
 *   reserved for plugin attachment via fsql_load_reasoning.
 *
 *   The reference SQLite-backed storage adapter lives in the
 *   standalone wrapper at fsql_sqlite_ledger/ (Phase 3). Customers who
 *   want SQLite persistence link the wrapper's libfsql_sqlite_ledger.a
 *   alongside libfractalsql-community-sovereign-c.so and call
 *   fsql_sqlite_ledger_open(...) → fsql_sqlite_ledger_as_vfs(...) to
 *   get a populated fsql_storage_vfs_t.
 *
 * Symbol contract (5 sovereign-only additions on top of 11 minimal):
 *   fsql_new_sovereign     (constructor with VFS injection)
 *   fsql_dispatch_ai       (inference call through reasoning VFS)
 *   fsql_load_reasoning    (dlopen-based reasoning plugin attach)
 *   fsql_ai_response_free  (Pattern C deallocator for ai_response_t)
 *
 * This header is unconditionally compiled into sovereign-tier .so
 * files (no #ifdef FSQL_SOVEREIGN guard — the .so either exports
 * these symbols or doesn't, controlled by the linker version script).
 *
 * Crypto-neutrality invariant:
 *   Like the rest of the engine, sovereign code performs zero crypto
 *   operations. The reasoning VFS, the storage VFS, and any plugin
 *   loaded through fsql_load_reasoning must respect crypto-neutrality
 *   on the caller's behalf — the engine never sees a license key,
 *   never verifies a signature, never decrypts payloads.
 *
 * Threading contract:
 *   sovereign-tier ctx is NOT thread-safe (same as minimal). One ctx
 *   per thread. The injected VFS callbacks may be called from any
 *   thread that owns the ctx; they must themselves be thread-safe if
 *   the same fsql_storage_vfs_t struct is shared across multiple ctxs.
 */
#ifndef FRACTALSQL_SQL_H
#define FRACTALSQL_SQL_H

#include "fractalsql.h"
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------------------------------------------------------- */
/* Storage VFS                                                      */
/* ---------------------------------------------------------------- */

/* Opaque user context. The VFS implementation owns this; the engine
 * passes it back to every callback unchanged. */
typedef void *fsql_storage_user_ctx;

/* Storage VFS — the engine's persistence boundary. All disk IO,
 * SQLite open/close, file locking, etc. lives in the implementation
 * the caller provides; the engine itself performs no IO.
 *
 * Callbacks:
 *   write_entry(user, kind, payload, len)
 *     Persist `len` bytes of `payload` under tag `kind`. Returns 0
 *     on success, FSQL_ESTORAGE on failure. Tags 1=truth, 2=shadow,
 *     3=shadow_vectors are the v1 semantic slots; the engine emits
 *     these tags but treats the storage as opaque blobs.
 *
 *   read_entry(user, kind, *payload_out, *len_out)
 *     Read the most-recent payload for `kind`. *payload_out is
 *     set to a buffer the implementation owns (engine never frees);
 *     *len_out is set to length. Returns FSQL_OK on hit,
 *     FSQL_ESTORAGE_UNAVAILABLE on miss, FSQL_ESTORAGE_INTEGRITY if
 *     the implementation detects tampering / HMAC mismatch.
 *
 *   seal_ledger(user)
 *     Atomically commit any pending writes + emit the integrity seal
 *     (e.g. HMAC over current state). Called at fsql_free time and
 *     after long search runs. Returns 0 on success.
 *
 *   user_ctx — opaque pointer passed back to every callback.
 *
 * Pass an all-NULL struct (or a NULL pointer) to fsql_new_sovereign
 * to construct a sovereign ctx with NO storage backend — useful for
 * search-only deployments where ledger semantics aren't needed.
 */
typedef struct fsql_storage_vfs {
    fsql_storage_user_ctx user_ctx;

    int (*write_entry)(fsql_storage_user_ctx user,
                       int kind,
                       const void *payload, size_t len);

    int (*read_entry)(fsql_storage_user_ctx user,
                      int kind,
                      const void **payload_out, size_t *len_out);

    int (*seal_ledger)(fsql_storage_user_ctx user);
} fsql_storage_vfs_t;

/* ---------------------------------------------------------------- */
/* Reasoning VFS                                                    */
/* ---------------------------------------------------------------- */

/* Reasoning VFS — engine's interface to an external inference
 * backend. The engine never instantiates a model itself; callers
 * inject a populated fsql_reasoning_vfs_t (or load one from a .so
 * via fsql_load_reasoning).
 *
 * format_prompt(user, query, context_json, *prompt_out, *prompt_len_out)
 *   Build the inference prompt string from a query + context. The
 *   returned *prompt_out is implementation-owned (engine does not
 *   free); valid until next callback on same user_ctx.
 *
 * generate(user, prompt, prompt_len, *response_out, *response_len_out)
 *   Run inference. Returns 0 on success, non-zero on failure.
 *   *response_out is a heap-allocated string the engine takes
 *   ownership of and frees via fsql_ai_response_free's free_fn.
 *
 * abi_version
 *   Plugin ABI version. Must equal FSQL_REASONING_ABI_VERSION at
 *   load time or fsql_load_reasoning rejects with mismatch.
 */
#define FSQL_REASONING_ABI_VERSION 1

typedef struct fsql_reasoning_vfs {
    void *user_ctx;

    int abi_version;

    int (*format_prompt)(void *user,
                         const char *query, size_t query_len,
                         const char *context_json, size_t context_len,
                         const char **prompt_out, size_t *prompt_len_out);

    int (*generate)(void *user,
                    const char *prompt, size_t prompt_len,
                    char **response_out, size_t *response_len_out,
                    void (**response_free_fn_out)(void *));
} fsql_reasoning_vfs_t;

/* Alias retained for callers using the older "adapter" terminology
 * from the V1 design plan. Functionally identical. */
typedef fsql_reasoning_vfs_t fsql_reasoning_adapter_t;

/* Optional shutdown hook — a plugin MAY additionally export:
 *
 *   void fsql_reasoning_fini(void *user_ctx);
 *
 * looked up via dlsym, NOT a field on fsql_reasoning_vfs_t. That's
 * deliberate: this struct is allocated by the CALLER and handed to the
 * plugin's fsql_reasoning_init to populate, so its size is fixed by
 * whatever header the CALLER was compiled against. A new struct field
 * would let an older-compiled caller loading a newer-compiled plugin
 * end up with the plugin writing past the end of a buffer sized for
 * the old, smaller struct — the abi_version check above only runs
 * after the plugin has already written into the struct, so it can't
 * prevent that. A separately-dlsym'd, independently-named symbol has
 * no such risk: absent it, dlsym just returns NULL, identical to
 * today's behavior for any plugin that predates this convention.
 *
 * If exported, the host calls it with the SAME user_ctx pointer the
 * plugin's own fsql_reasoning_init populated, immediately before
 * dlclose()-ing the plugin (both on final fsql_free teardown and when
 * fsql_load_reasoning replaces an already-attached plugin) — giving
 * the plugin a chance to release resources it holds beyond what a bare
 * dlclose reclaims. Concrete motivating case: a plugin holding a
 * long-lived libcurl easy handle whose threaded DNS resolver spawns a
 * background thread — without an explicit curl_easy_cleanup() before
 * unload, that thread's own code can end up executing from memory
 * dlclose just unmapped. Optional and NULL-safe throughout; a plugin
 * with nothing to release, or one built before this convention
 * existed, simply doesn't export it.
 *
 * The host has no timeout on this call: fsql_free / fsql_load_reasoning
 * block for as long as fini takes to return. There is no safe way to
 * enforce one — running fini on a worker thread and abandoning it past a
 * deadline would race the caller's own dlclose()/free() against a thread
 * still executing inside soon-to-be-unmapped code, a worse failure mode
 * than blocking. Plugin authors: fini MUST NOT block indefinitely. */

/* ---------------------------------------------------------------- */
/* Sovereign constructor                                            */
/* ---------------------------------------------------------------- */

/* Construct a sovereign-tier ctx with optional storage + reasoning
 * VFS injection. Either parameter may be NULL — a sovereign ctx
 * with no storage is search-only; one with no reasoning provides
 * the surface for fsql_load_reasoning to attach later.
 *
 * The structs are copied by value at construction; the caller need
 * not keep them alive after fsql_new_sovereign returns. Callbacks'
 * user_ctx pointers, however, MUST remain valid for the ctx
 * lifetime — they get passed back unchanged on every callback.
 *
 * Returns NULL on allocation failure. fsql_free is the destructor
 * for both minimal and sovereign ctx values.
 */
FSQL_API fsql_ctx *fsql_new_sovereign(
    const fsql_storage_vfs_t   *storage,
    const fsql_reasoning_vfs_t *reasoning);

/* ---------------------------------------------------------------- */
/* Reasoning ABI                                                    */
/* ---------------------------------------------------------------- */

/* AI response — Pattern C ownership: caller must call
 * fsql_ai_response_free(resp) to release. The plugin-supplied
 * free_fn frees the `summary` string (and any auxiliary buffers
 * the plugin allocated alongside it). The fsql_ai_response_t
 * struct itself is CALLER-owned (typically caller-allocated on
 * the stack or in caller's heap) and must NOT be freed by the
 * plugin.
 *
 * If the plugin allocated `summary` with libc malloc, it may
 * leave free_fn == NULL — the foundry's defensive path in
 * fsql_ai_response_free then calls libc free(resp->summary).
 * This is the easy-out for plugins that don't want a custom
 * deallocator; see fractalsql-reasoning-http for an example. */
typedef struct fsql_ai_response {
    char  *summary;        /* Pattern C: paired-free. */
    size_t summary_len;
    int    rc;             /* 0 on success, non-zero implementation-defined */
    /* Frees the SUMMARY string only (and any plugin-owned auxiliary
     * buffers reachable from it). The opaque argument is the
     * wrapping fsql_ai_response_t * cast to void * — plugins can
     * cast it back to read resp->summary, but the wrapper struct
     * itself is caller-owned and must NOT be freed by this function.
     * The signature is void * (not fsql_ai_response_t *) to keep
     * the type compatible with fsql_reasoning_vfs_t.generate's
     * response_free_fn_out output. NULL is allowed and triggers
     * the foundry's libc-free fallback in fsql_ai_response_free.
     * MUST be invoked via fsql_ai_response_free, not called
     * directly. */
    void (*free_fn)(void *resp);
} fsql_ai_response_t;

/* Run inference on the captured reasoning VFS for a given query +
 * context. Returns FSQL_OK on success with *resp_out populated;
 * non-OK on failure (resp_out left untouched, no allocation made).
 *
 * The returned response is caller-owned (Pattern C). MUST be freed
 * via fsql_ai_response_free or memory will leak.
 */
FSQL_API int fsql_dispatch_ai(
    fsql_ctx           *ctx,
    const char         *query,        size_t query_len,
    const char         *context_json, size_t context_len,
    fsql_ai_response_t *resp_out);

/* Load a reasoning plugin from an absolute path. The plugin .so
 * must export `fsql_reasoning_init` returning a populated
 * fsql_reasoning_vfs_t with abi_version == FSQL_REASONING_ABI_VERSION.
 *
 * Path security — what this function checks, and what it does NOT:
 *
 *   Checked:   abs_path[0] == '/' (rejects "./plugin.so",
 *              "../plugin.so", and any caller-relative form). This
 *              defeats the simplest CWD-shadowing attack — an attacker
 *              dropping a malicious plugin.so in the working dir and
 *              counting on naive integration code passing a bare name.
 *
 *   Also checked (added v1.1.x):
 *     - Lexical traversal segments. "/../", "/./", trailing "/.." or
 *       "/." are rejected before any filesystem call.
 *     - Path canonicalization (POSIX). realpath() resolves the path
 *       and we require the result to equal the input. Defeats
 *       symlink-pivots: /tmp/innocent.so -> /etc/passwd produces a
 *       resolved path that mismatches the input and is rejected.
 *     - Path canonicalization (Windows). _fullpath() resolves "/",
 *       "\", "..", and drive letters but does NOT follow symlinks
 *       (Windows symlinks need admin / Developer Mode anyway). The
 *       symlink-pivot defense is therefore weaker on Windows than
 *       POSIX, but the lexical "/../" rejection above still blocks
 *       the primary attack class.
 *
 *   NOT checked, by design:
 *     - File ownership / mode. The function does NOT verify that the
 *       plugin is owned by root, has 0644 perms, lives on a non-noexec
 *       mount, etc. If your deployment cares about plugin provenance,
 *       enforce that out-of-band (package manager, container image
 *       baking, AppArmor / SELinux policy on the plugin directory).
 *     - Sandboxing. The plugin runs in-process with full host privileges.
 *       FractalSQL deliberately does not sandbox plugins — the sovereign
 *       tier's contract is "you provide the trust boundary".
 *
 * Threat model: the path check protects against accidental loading of
 * the wrong file from the wrong directory. It is NOT a defense against
 * an attacker who can write to a path on the integrator's allowlist —
 * that is the integrator's responsibility (signed plugins, immutable
 * deploy paths, syscall filters, etc.).
 *
 * Returns FSQL_OK on success (plugin attached to ctx, replacing any
 * previously-attached reasoning VFS), FSQL_ERR_INVALID for bad
 * arguments / relative paths, FSQL_ERR_RUNTIME for dlopen / dlsym
 * failures or ABI mismatch.
 *
 * Gated on FSQL_DLOPEN_REASONING_PLUGINS at compile time; not
 * available on platforms / build configurations where dlopen is
 * disallowed (WASM, certain regulated environments).
 */
FSQL_API int fsql_load_reasoning(fsql_ctx *ctx, const char *abs_path);

/* Pattern C deallocator for fsql_ai_response_t. Calls resp->free_fn
 * with `resp` as argument (the free_fn knows the implementation's
 * allocator) and zeros the struct fields so a stale reuse triggers
 * a clean NULL-deref rather than a use-after-free. NULL-safe. */
FSQL_API void fsql_ai_response_free(fsql_ai_response_t *resp);

/* Convenience composition: run fsql_search_ptr against the
 * configured storage + corpus, then dispatch the result through
 * fsql_dispatch_ai. Returns the final ai_response_t in
 * *resp_out (caller-owned, free with fsql_ai_response_free).
 *
 * Per V1 plan D1 (decided April 2026), this lands in v1.0.0 — not
 * v1.1 — so customers can issue search+reason in one call rather
 * than threading the search result through their own glue code.
 */

/* ================================================================ */
/* v2.0.0 — Discovery Diversification + Truth/Shadow Ledger         */
/* ================================================================ */
/* All symbols below are sovereign-only and exported from the       */
/* sovereign .so / .lib variants only (never from the minimal       */
/* variant). See FRACTALSQL_CORE_V2_PLAN.txt §5 for the design      */
/* rationale and docs/DISCOVERY_V2_API.md for the one-page          */
/* binding-author reference. Headers stay in include/; the engine   */
/* is integrity-neutral (host VFS owns trust per PRD §4).            */

/* ----- Diversity / Inspector ----------------------------------- */

/* Enable the divergence monitor and repulsive post-filter on this
 * ctx. Disabled by default in v2.0 (opt-in). When disabled, ctx
 * behaves bit-for-bit identical to v1.0. */
FSQL_API int fsql_diversify_enable(fsql_ctx *ctx);
FSQL_API int fsql_diversify_disable(fsql_ctx *ctx);

/* Tunables. All have documented defaults (PRD §6); callers may
 * override at any time. Thread-safe; takes effect on the next
 * fsql_search. */
typedef struct fsql_diversify_params {
    uint32_t  window_n;               /* D_q window, default 5, max 32   */
    double    stall_threshold;        /* D_q below this = stall; dflt 0.15*/
    double    repulsion_sigma;        /* Gaussian σ; default = f(dim)    */
    double    repulsion_weight;       /* global scalar on shadow penalty */
    uint32_t  max_shadows_considered; /* per-query; default 64           */
    uint32_t  tail_buffer_cap;        /* Shadow tail before compact;     */
                                      /* required; default 256, max 1024 */
} fsql_diversify_params_t;

FSQL_API int fsql_diversify_set_params(fsql_ctx                      *ctx,
                                       const fsql_diversify_params_t *p);
FSQL_API int fsql_diversify_get_params(const fsql_ctx                *ctx,
                                       fsql_diversify_params_t       *out);

/* Read the most recently computed D_q. Returns NAN if no query has
 * run yet or diversify is disabled. */
FSQL_API double fsql_diversify_current_dq(const fsql_ctx *ctx);

/* Rolling p99 of diversify overhead in microseconds over the last
 * 1000 fsql_search calls. NaN until the buffer fills, NaN if
 * diversify is disabled. Deterministic given fixed hardware; this
 * measures core's own per-query overhead, not total query latency.
 * Application layer reads this plus its own thermal / pressure
 * signals and may call fsql_diversify_disable to fall back to v1.0
 * search. Core itself does NOT adapt to this value; adaptive
 * degradation in core would violate P1 (deterministic core,
 * deterministic tests). */
FSQL_API double fsql_diversify_overhead_p99_us(const fsql_ctx *ctx);

/* ----- Entropy source (Stochastic Spark) ----------------------- */

typedef enum {
    FSQL_ENTROPY_AUTO     = 0,  /* priority chain, the default      */
    FSQL_ENTROPY_HARDWARE = 1,  /* fail-hard if no hw source        */
    FSQL_ENTROPY_OS       = 2,  /* getrandom / BCryptGenRandom      */
    FSQL_ENTROPY_FIXED    = 3,  /* deterministic; Gate 1 / tests    */
} fsql_entropy_source_t;

FSQL_API int fsql_entropy_set_source(fsql_ctx              *ctx,
                                     fsql_entropy_source_t  src,
                                     uint64_t               fixed_seed
                                       /* only used for FIXED */);

/* Report which source the engine actually resolved to. Useful in
 * logs so a WASM deployment can confirm it is on OS CSPRNG and a
 * Linux-x86_64 deployment can confirm it is on RDSEED. */
FSQL_API fsql_entropy_source_t fsql_entropy_active_source(const fsql_ctx *ctx);

/* ----- Engagement / Gumption ----------------------------------- */

typedef enum {
    FSQL_ENGAGE_DWELL     = 0,  /* dwell_ms used; signal ignored    */
    FSQL_ENGAGE_POSITIVE  = 1,  /* explicit reinforcement           */
    FSQL_ENGAGE_NEGATIVE  = 2,  /* explicit rejection               */
} fsql_engagement_kind_t;

FSQL_API int fsql_feedback_report(fsql_ctx               *ctx,
                                  uint64_t                result_handle,
                                  fsql_engagement_kind_t  kind,
                                  uint32_t                dwell_ms);

/* ----- Ledger management --------------------------------------- */

/* Persist ledgers via the storage VTable captured at
 * fsql_new_sovereign() time. Encode QTL → write_entry; host wraps
 * the blob as configured. One QTL BLOB per (kind, epoch) tuple is
 * encoded and handed to ctx->storage->write_entry. Returns
 * FSQL_ESTORAGE if write_entry returns negative,
 * FSQL_ESTORAGE_UNAVAILABLE if the VFS slot is NULL. */
FSQL_API int fsql_ledger_flush(fsql_ctx *ctx);

/* Load ledgers via ctx->storage->read_entry → decode. If host
 * returned ELEDGER_INTEGRITY (= FSQL_ESTORAGE_INTEGRITY), auto-
 * disable diversify and return that code to the caller; the ctx
 * is LEFT with empty ledgers (not half-loaded), so the next
 * fsql_search returns v1.0 bit-perfect results. The caller decides
 * whether to repair and re-enable. */
FSQL_API int fsql_ledger_load(fsql_ctx *ctx);

/* Force a Healing GC pass now. Normally runs lazily on flush; this
 * is here for tests and for callers who want a predictable pause. */
FSQL_API int fsql_ledger_compact(fsql_ctx *ctx);

/* Soft reset: clears the Shadow Ledger only. Truth Ledger and the
 * current epoch are preserved; the diversify state is reseeded.
 * Use when the deployment context changes in a way that
 * invalidates negative learnings but not positive ones. */
FSQL_API int fsql_ledger_reset_soft(fsql_ctx *ctx);

/* Hard reset: clears Truth + Shadow tables and resets the epoch
 * counter to 1. No key rotation (core holds no keys; the host VFS
 * owns any key material it uses to wrap blobs). */
FSQL_API int fsql_ledger_reset_hard(fsql_ctx *ctx);

/* Read-only inspection. */
FSQL_API int fsql_ledger_truth_count(const fsql_ctx *ctx,  size_t *out);
FSQL_API int fsql_ledger_shadow_count(const fsql_ctx *ctx, size_t *out);

/* ----- CISO auditability --------------------------------------- */

/* Unpack a QTL BLOB into human-readable JSON.
 *
 * Input:  a QTL BLOB previously produced by core (typically read
 *         out-of-band by an admin via the host's storage backend
 *         — Postgres SELECT, Redis GETRANGE, etc — and passed in
 *         as a contiguous buffer + length).
 *
 * Output: caller-allocated JSON buffer (Pattern A per V1 plan §5.1).
 *         One JSON object per ledger entry with fields:
 *           {"epoch": <u64>, "doc_id": <u64>,
 *            "signal": "truth" | "shadow" | "neutral"}
 *         The full output is a top-level JSON array.
 *
 * json_cap is in/out: caller writes capacity, core writes actual
 * length on success. Returns FSQL_OK on success, -FSQL_ETRUNCATED
 * if json_cap was too small (in which case *json_cap reports the
 * required size), -FSQL_ESTORAGE_INTEGRITY if the BLOB header is
 * malformed or the version magic does not match.
 *
 * Caller-allocated by design — no allocator-mismatch risk between
 * core's malloc and the host's allocator (palloc / enif_alloc /
 * JNI types / V8 heap). */
FSQL_API int fsql_audit_unpack(const void *blob, size_t blob_len,
                               char *json_out, size_t *json_cap);

/* ----- Fractal Dimension Analysis -------------------------------
 *
 * Genuinely different from Sniper/Scout retrieval: these characterize
 * DATA (a time series, a spatial point cloud) rather than searching
 * a corpus. A net-new capability, not a replacement for anything --
 * see src/fractal_dim/. Sovereign-tier for now (see the dfa.c /
 * boxcount.c Makefile wiring comment); the minimal-tier question is
 * an open licensing/tiering decision, not settled here.
 */

/* Detrended Fluctuation Analysis scaling exponent (Peng et al. 1994)
 * for a numeric, time-ordered series. alpha ~= 0.5 uncorrelated,
 * ~= 1.0 1/f "pink" noise, ~= 1.5 Brownian motion / random walk,
 * < 0.5 anti-correlated. Requires n >= 16.
 *
 * Returns FSQL_OK on success (writes *out_alpha), FSQL_ERR_INVALID
 * on a NULL/too-short series, FSQL_ERR_OOM on allocation failure. */
FSQL_API int fsql_dimension_dfa(const double *series, size_t n,
                                double *out_alpha);

/* Monitoring companion: DFA drift between a series' recent `window`
 * points and everything before them. Positive = increasing
 * complexity/irregularity, negative = decreasing (approaching a more
 * ordered/critical state). Requires n >= window + 16, window >= 16.
 *
 * Returns FSQL_OK on success (writes *out_drift, *out_recent_alpha,
 * *out_baseline_alpha), FSQL_ERR_INVALID on invalid/too-short input. */
FSQL_API int fsql_dimension_drift(const double *series, size_t n, size_t window,
                                  double *out_drift, double *out_recent_alpha,
                                  double *out_baseline_alpha);

/* Box-counting (Minkowski-Bouligand) fractal dimension over a point
 * cloud in `dim` dimensions -- occupied-space markers such as voxel
 * centers of a binary mask, or a vessel/nerve-fiber skeleton's
 * points. points: n_points x dim, row-major. Requires n_points >= 8
 * and a non-degenerate bounding box.
 *
 * Returns FSQL_OK on success (writes *out_dimension), FSQL_ERR_INVALID
 * on invalid/degenerate input, FSQL_ERR_OOM on allocation failure. */
FSQL_API int fsql_dimension_boxcount(const double *points, size_t n_points,
                                     size_t dim, double *out_dimension);

/* ----- Portfolio Optimization -------------------------------------
 *
 * Cardinality-constrained Sharpe-ratio maximization: "at most k of
 * n_assets nonzero weight" is a hard combinatorial constraint,
 * unsolvable by convex/QP methods -- exactly the black-box,
 * non-convex problem class the SFS engine has real, validated
 * standing on (~28x faster than scipy's differential evolution
 * baseline for near-equal quality). A hardcoded objective
 * template, not a general callback API (see src/optimize/portfolio.h
 * for why). Sovereign-tier for now, same open tiering question as
 * the fractal dimension functions above.
 *
 * mu:  n_assets expected returns. cov: n_assets x n_assets covariance
 * matrix, row-major. k: cardinality constraint, 1 <= k <= n_assets.
 * seed: RNG seed for the underlying SFS run (deterministic for a
 * given seed).
 *
 * On success (FSQL_OK), *out_weights (caller-owned, n_assets doubles)
 * holds the best portfolio found -- at most k nonzero entries,
 * non-negative, summing to 1.0 -- and *out_sharpe its Sharpe ratio.
 *
 * Returns FSQL_ERR_INVALID on invalid input (including k == 0 or
 * k > n_assets), FSQL_ERR_OOM on allocation failure. */
FSQL_API int fsql_optimize_portfolio(const double *mu, const double *cov,
                                     size_t n_assets, size_t k, uint64_t seed,
                                     double *out_weights, double *out_sharpe);

/* Sibling of fsql_optimize_portfolio carrying the OBL (Opposition-
 * Based Learning) / Lévy-flight diffusion knobs -- new symbol rather
 * than new parameters on fsql_optimize_portfolio itself, so an older
 * caller's existing call sites are never at risk of an ABI mismatch.
 *
 * use_obl: 0 (default behavior, byte-identical to fsql_optimize_portfolio)
 *   or 1 to also evaluate each SFS trial candidate's bound-reflected
 *   opposite and keep whichever fits better.
 * diffusion_mode: FSQL_SFS_DIFFUSE_GAUSSIAN (0, default) or
 *   FSQL_SFS_DIFFUSE_LEVY (1, heavy-tailed Mantegna steps) -- see
 *   include/sfs_core_c.h.
 *
 * Same mu/cov/n_assets/k/seed/out_weights/out_sharpe contract and error
 * codes as fsql_optimize_portfolio. */
FSQL_API int fsql_optimize_portfolio_ex(const double *mu, const double *cov,
                                        size_t n_assets, size_t k, uint64_t seed,
                                        int use_obl, int diffusion_mode,
                                        double *out_weights, double *out_sharpe);

/* Multimodal variant -- enterprise-gated, same convention as
 * fsql_ledger_flush (absent from a community-compiled object, see
 * fsql.c). Calls fsql_optimize_portfolio's search n_restarts times with
 * different derived seeds, then greedy diverse-selects the results.
 *
 * mu/cov/n_assets/k: same as fsql_optimize_portfolio.
 * n_restarts: how many independent single-best runs to attempt, 1-64.
 * overlap_threshold: max allowed selected-asset overlap (0.0-1.0,
 *   Jaccard-style) between any two returned candidates.
 * quality_frac: a candidate must reach at least quality_frac * the best
 *   Sharpe found (0.0 exclusive - 1.0) to be considered at all.
 * seed: seeds the whole multi-restart batch deterministically; each
 *   restart derives its own seed from this one.
 *
 * On success (FSQL_OK): *out_weights (caller-owned, n_restarts *
 * n_assets doubles; row r is candidate r's weights) and *out_sharpes
 * (caller-owned, n_restarts doubles) are filled for rows/entries
 * 0..*out_n_found-1 (Sharpe descending); *out_n_found holds how many
 * distinct candidates were actually found, 1..n_restarts.
 *
 * Returns FSQL_ERR_INVALID on invalid input, FSQL_ERR_OOM on allocation
 * failure. */
FSQL_API int fsql_optimize_portfolio_multimodal(const double *mu, const double *cov,
                                                size_t n_assets, size_t k,
                                                int n_restarts,
                                                double overlap_threshold,
                                                double quality_frac,
                                                uint64_t seed,
                                                double *out_weights,
                                                double *out_sharpes,
                                                int *out_n_found);

/* Sibling of fsql_optimize_portfolio_multimodal carrying the OBL/
 * Lévy-flight knobs (see fsql_optimize_portfolio_ex above), applied
 * uniformly to every restart's SFS search -- new symbol, same
 * enterprise gating as fsql_optimize_portfolio_multimodal. */
FSQL_API int fsql_optimize_portfolio_multimodal_ex(const double *mu, const double *cov,
                                                   size_t n_assets, size_t k,
                                                   int n_restarts,
                                                   double overlap_threshold,
                                                   double quality_frac,
                                                   uint64_t seed,
                                                   int use_obl, int diffusion_mode,
                                                   double *out_weights,
                                                   double *out_sharpes,
                                                   int *out_n_found);

/* Pareto-front variant -- enterprise-gated, same convention as
 * fsql_optimize_portfolio_multimodal above. Scores each restart by
 * decomposed (return, risk) instead of scalar Sharpe and reduces the
 * n_restarts candidates to a genuine non-dominated Pareto front
 * (NSGA-II crowding-distance truncation if the front exceeds
 * max_front), rather than the sharpe-threshold + asset-overlap greedy
 * selection the scalar-Sharpe variant above uses. Additive: does not
 * change fsql_optimize_portfolio_multimodal's own selection semantics.
 *
 * mu/cov/n_assets/k/n_restarts/seed: same as
 * fsql_optimize_portfolio_multimodal.
 * max_front: cap on returned front size, 1 <= max_front <= n_restarts.
 * use_obl/diffusion_mode: same OBL/Lévy-flight knobs as
 *   fsql_optimize_portfolio_ex, applied uniformly to every restart.
 *
 * On success (FSQL_OK): *out_weights (caller-owned, max_front *
 * n_assets doubles), *out_returns and *out_risks (caller-owned,
 * max_front doubles each) are filled for rows/entries
 * 0..*out_n_found-1; *out_n_found holds how many front members were
 * actually returned, 1..max_front. sharpe (if wanted) =
 * out_returns[i] / out_risks[i].
 *
 * Returns FSQL_ERR_INVALID on invalid input, FSQL_ERR_OOM on allocation
 * failure. */
FSQL_API int fsql_optimize_portfolio_multimodal_pareto(const double *mu, const double *cov,
                                                        size_t n_assets, size_t k,
                                                        int n_restarts, int max_front,
                                                        uint64_t seed,
                                                        int use_obl, int diffusion_mode,
                                                        double *out_weights,
                                                        double *out_returns,
                                                        double *out_risks,
                                                        int *out_n_found);

/* ----- Domain-specific geometric/topological metrics ---------------
 *
 * Full real implementations over PRE-EXTRACTED geometry (vessel
 * graphs, meshes, skeleton graphs, point-cloud masks) -- not raw
 * medical imaging data. Segmentation/extraction from raw imaging is a
 * categorically different, much larger problem, explicitly out of
 * scope (comparable to a dedicated pipeline like FreeSurfer). Same
 * sovereign-tier gating as the rest of this section.
 */

/* Vessel-network tortuosity/branch-density/dimension. node_coords:
 * n_nodes * 3 (x,y,z). edges: n_edges * 2 node indices. edge_arc_length:
 * n_edges true centerline arc lengths (from an upstream centerline
 * trace, e.g. VMTK). See src/fractal_dim/vascular.h for full details.
 *
 * Returns FSQL_OK on success (writes *out_mean_tortuosity,
 * *out_branch_density, *out_fractal_dimension), FSQL_ERR_INVALID on
 * invalid/degenerate input, FSQL_ERR_OOM on allocation failure. */
FSQL_API int fsql_vascular_network(const double *node_coords, size_t n_nodes,
                                   const size_t *edges, const double *edge_arc_length,
                                   size_t n_edges,
                                   double *out_mean_tortuosity, double *out_branch_density,
                                   double *out_fractal_dimension);

/* Gyrification Index (Zilles et al. 1988): mesh surface area / convex
 * hull surface area. vertices: n_vertices * 3. faces: n_faces * 3
 * vertex indices (triangles). See src/fractal_dim/cortical.h.
 *
 * Returns FSQL_OK on success (writes *out_mesh_area, *out_hull_area,
 * *out_gyrification_index), FSQL_ERR_INVALID on invalid/degenerate
 * input, FSQL_ERR_OOM on allocation failure. */
FSQL_API int fsql_cortical_folding(const double *vertices, size_t n_vertices,
                                   const size_t *faces, size_t n_faces,
                                   double *out_mesh_area, double *out_hull_area,
                                   double *out_gyrification_index);

/* Nerve fiber plexus metrics (corneal confocal microscopy convention --
 * fiber length density, branch density, fractal dimension). node_coords:
 * n_nodes * dim (dim typically 2). edges: n_edges * 2 node indices.
 * See src/fractal_dim/nerve.h.
 *
 * Returns FSQL_OK on success (writes *out_fiber_length_density,
 * *out_branch_density, *out_fractal_dimension), FSQL_ERR_INVALID on
 * invalid/degenerate input, FSQL_ERR_OOM on allocation failure. */
FSQL_API int fsql_nerve_plexus_metric(const double *node_coords, size_t n_nodes, size_t dim,
                                      const size_t *edges, size_t n_edges,
                                      double *out_fiber_length_density,
                                      double *out_branch_density,
                                      double *out_fractal_dimension);

/* Morphological complexity of a pre-segmented mask: box-counting
 * dimension + fixed-grid lacunarity. points: n_points * dim occupied
 * mask points. See src/fractal_dim/morphology.h.
 *
 * Returns FSQL_OK on success (writes *out_dimension, *out_lacunarity),
 * FSQL_ERR_INVALID on invalid/degenerate input, FSQL_ERR_OOM on
 * allocation failure. */
FSQL_API int fsql_morphological_complexity(const double *points, size_t n_points, size_t dim,
                                           double *out_dimension, double *out_lacunarity);

/* ----- Vector Arithmetic --------------------------------------------
 *
 * Simple O(dim) float32 vector ops, added to serve fractal_vector's
 * float4 varlena storage format (fractalsql-postgresql) and any future
 * DB-agnostic float4 vector type (fractalsql-sqlite) directly, with no
 * float<->double conversion at the call site. Deliberately NOT used by
 * and NOT a replacement for the double-precision vector math already
 * private to src/index/hnsw.c, src/sfs/, src/diversify/ -- those
 * remain byte-for-byte unchanged, protected by gate 19 (shadow Lua/C
 * parity) and gate 77 (algo Lua parity). Callers needing this module's
 * output to feed the existing double-precision search path
 * (fsql_search_ptr) widen float->double themselves at the boundary,
 * same as they already do today for a float8[] column.
 *
 * Convention: on a degenerate zero-norm input to cosine_distance/
 * cosine_similarity, returns distance=1.0f / similarity=0.0f rather
 * than NaN -- deliberate, so a Postgres float8 result column never has
 * to special-case NaN. (Existing double-precision sites in this
 * codebase are NOT consistent with each other on this point --
 * src/fsql.c's cosine_distance returns 1.0 on zero norm,
 * src/diversify/dq.c's cosine_sim returns NaN -- this module picks one
 * convention on purpose rather than inheriting either.)
 *
 * Available in every tier (minimal, sovereign, enterprise) -- pure
 * C99 math with no VFS/storage dependency, unlike the fractal-
 * dimension/portfolio/domain-geometry functions above, which are
 * sovereign-gated for a licensing reason that doesn't apply here.
 *
 * Every function takes caller-allocated output buffers -- no internal
 * scratch allocation, no VLAs. Returns FSQL_OK on success,
 * FSQL_ERR_INVALID on NULL/dim==0 input.
 */

FSQL_API int fsql_vector_dot(const float *a, const float *b, size_t dim,
                             float *out_dot);
FSQL_API int fsql_vector_l2_sq(const float *a, const float *b, size_t dim,
                               float *out_sq_dist);
FSQL_API int fsql_vector_l2(const float *a, const float *b, size_t dim,
                            float *out_dist);
FSQL_API int fsql_vector_cosine_distance(const float *a, const float *b, size_t dim,
                                         float *out_dist);
FSQL_API int fsql_vector_cosine_similarity(const float *a, const float *b, size_t dim,
                                           float *out_sim);
FSQL_API int fsql_vector_norm(const float *v, size_t dim, float *out_norm);
FSQL_API int fsql_vector_normalize(const float *src, size_t dim, float *out_dst);
FSQL_API int fsql_vector_add(const float *a, const float *b, size_t dim, float *out);
FSQL_API int fsql_vector_sub(const float *a, const float *b, size_t dim, float *out);
FSQL_API int fsql_vector_scale(const float *v, size_t dim, float scalar, float *out);

/* out has length dim_a + dim_b. Powers fractal_cross_modal_search's
 * [morphology_vector*alpha, clinical_vector*(1-alpha)] shape. out must
 * not alias a or b. */
FSQL_API int fsql_vector_weighted_concat(const float *a, size_t dim_a, float alpha,
                                         const float *b, size_t dim_b, float beta,
                                         float *out);

#ifdef __cplusplus
}  /* extern "C" */
#endif

#endif  /* FRACTALSQL_SQL_H */
