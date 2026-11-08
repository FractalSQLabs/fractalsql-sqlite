/* src/fsql_sqlite_internal.h
 *
 * fractalsql-sqlite: shared internal contract between the extension's
 * translation units. Not installed; not part of any public ABI.
 *
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * TU map (all pure C11, no libstdc++):
 *
 *   fractalsql_sqlite.c   entry point, state lifecycle, registration
 *                         table, smoke + search/scout surface
 *   fsql_vector.c/.h      fractal_vector BLOB convention + vector math
 *   fsql_config.c         fractalsql_set / fractalsql_get (session config)
 *   fsql_reasoning.c      reasoning VFS attach + fractal_reason family
 *   fsql_t2s.c            fractal_schema_context + fractal_text_to_sql
 *   fsql_vectorizer.c     fractal_vectorizer_* + fractal_embed
 *   fsql_agents.c         agent-tier composition functions
 *   fsql_ledger.c         storage VFS impl + fractal_ledger_* surface
 *   fsql_enterprise.c     dlopen loader for the enterprise core
 *                         (ledger/audit + multimodal portfolio symbols)
 *   fsql_sovereign.c      dimension / portfolio / domain-geometry
 *   fsql_parse.c/.h       shared string-parsing helpers, no external deps
 *   fsql_hmac.h           vendored HMAC-SHA256 implementation
 *
 * Build mode: the Makefile compiles -DFSQL_SQLITE_SOVEREIGN when
 * CORE_VARIANT links a sovereign archive, and EXCLUDES the sovereign
 * -only TUs (reasoning, t2s, vectorizer, agents, domain agents,
 * ledger, sovereign math) from the minimal link: their core symbols
 * only exist in the sovereign archive. The entry TU's one ledger call
 * (fsql_ledger_teardown in fsql_state_destroy) is compiled under the
 * same define. On a minimal build the excluded names surface as
 * SQLite "no such function" errors: the smoke surface
 * (edition/version/search/scout/vector) is byte-compatible either
 * way.
 */
#ifndef FSQL_SQLITE_INTERNAL_H
#define FSQL_SQLITE_INTERNAL_H

#include <stdint.h>
#include <stddef.h>

/* Every TU includes <sqlite3ext.h>; the entry TU uses
 * SQLITE_EXTENSION_INIT1 / INIT2, the rest INIT3. */
#include <sqlite3ext.h>

/* SQLITE_INNOCUOUS arrived in SQLite 3.31.0; older system dev headers
 * (the 3.26-era ones shipped by the RHEL-family 8 dev package) do not
 * define it. Register without the flag there: 0 is simply "flag
 * absent", and hosts predating the flag ignore unknown
 * create_function bits in any case. */
#ifndef SQLITE_INNOCUOUS
#  define SQLITE_INNOCUOUS 0
#endif

/* SQLITE_DIRECTONLY arrived in SQLite 3.30.0, so the same older dev headers lack it too. Unlike the flag above this
 * one is a safety control (it keeps triggers, views and CHECK constraints from calling the config and ledger
 * functions), so it is defined with its real, fixed bit value: a newer host SQLite that loads this extension still
 * enforces it, and a host predating the flag ignores the unknown create_function bit. */
#ifndef SQLITE_DIRECTONLY
#  define SQLITE_DIRECTONLY 0x000080000
#endif

#include "fractalsql.h"
#include "fractalsql_sql.h"

#include <limits.h>

/* sqlite3_value_int() wraps a 64-bit value to 32 bits, so 4294967297 reads as
 * 1 and passes a range check meant to refuse it. fsql_value_int() clamps
 * instead, so an out-of-range value stays out of range. A macro, not a
 * function: sqlite3_value_int64 goes through each TU's own sqlite3_api. */
static inline int fsql_clamp_to_int(sqlite3_int64 n)
{
    return n > INT_MAX ? INT_MAX : (n < INT_MIN ? INT_MIN : (int)n);
}
#define fsql_value_int(v) fsql_clamp_to_int(sqlite3_value_int64(v))

/* ------------------------------------------------------------------ */
/* Constants                                                           */
/* ------------------------------------------------------------------ */

/* Widest SimHash fingerprint fractal_state_fingerprint / fractal_cycle_detect
 * accept: 4 MiB of fingerprint. Past it a single call only burns CPU and
 * memory (2^31 bits took 37 s and 520 MB). The same ceiling as the MariaDB
 * edition, where it follows from the 16 MiB result limit. */
#define FSQL_FINGERPRINT_MAX_BITS 33554424

/* Work bounds, the same as the core's. A single call cannot be interrupted,
 * and each cost is a product no individual limit controls:
 *   search:    iterations x population_size x diffusion_factor x dim (about
 *              30 ns a unit, so 2^31 is roughly a minute);
 *   subset:    items x k (about 3 us a unit, 2^24 is roughly a minute);
 *   periodogram: series length, an FFT (2^20 is a few seconds). */
#define FSQL_SEARCH_MAX_WORK        2147483648ULL
#define FSQL_SUBSET_MAX_WORK        16777216ULL
#define FSQL_PERIODOGRAM_MAX_SAMPLES 1048576

/* Most random draws one fingerprint (n_bits x vector length) may cost: about
 * 4 ns each, so 2^28 is roughly a second, and the loop cannot be interrupted.
 * Applied to a whole state log by fractal_agent_detect_loop. The same bound
 * as the core's. */
#define FSQL_FINGERPRINT_MAX_WORK 268435456

/* Extension version. Single source of truth for fractalsql_version()
 * and the smoke gate; bumped in lockstep with packaging scripts. */
#define FSQL_SQLITE_VERSION_STR   "2.0.12"
#define FSQL_SQLITE_EDITION_STR   "Community"

/* SFS tuning: same values the pre-2.x path used. */
#define FSQL_SFS_PARAMS_JSON \
    "{\"max_generation\":30," \
    "\"population_size\":50," \
    "\"maximum_diffusion\":2," \
    "\"walk\":0.5," \
    "\"bound_clipping\":true}"

/* Input-side DoS guards, carried over from the 1.x bridge. */
#define FSQL_ARENA_MAX_DIM     4096
/* Cap on any single input or plugin response (4 MiB, matching the cap
 * used across the other integrations): the reasoning plugin is invoked
 * with the caller's text verbatim, and an unbounded input turns one SQL
 * call into an unbounded HTTP body. 4 MiB is far above any real
 * embedding input (embedding models cap out at ~8k tokens) -- a clean
 * rejection, never a silent truncation. */
#define FSQL_MAX_INPUT_BYTES   (4 * 1024 * 1024)   /* 4 MiB */

/* SFS hyperparameter ceilings, shared by the agent tier's validation
 * and the Scout explore path's clamping (both feed the same core
 * arena). */
#define FSQL_AGENTS_MAX_ITERATIONS   10000
#define FSQL_AGENTS_MAX_POPULATION   10000   /* the core's own ceiling */
#define FSQL_AGENTS_MAX_DIFFUSION    32

/* fractal_vector BLOB-convention limits. */
#define FSQL_VEC_MAX_DIM       32767
#define FSQL_VEC_HDRSZ         4    /* u16 dim LE + u16 reserved */

/* fractal_schema_context table cap. */
#define FSQL_T2S_MAX_TABLES    512

/* ------------------------------------------------------------------ */
/* Reasoning tiers                                                     */
/* ------------------------------------------------------------------ */

/* The vendored reasoning plugin (fractalsql-reasoning-http v1.4.1)
 * reads its ENTIRE configuration from the process environment once,
 * inside its exported fsql_reasoning_init (FSQL_REASONING_HTTP_URL
 * required; init fails if unset), and the per-call context JSON is
 * embedded verbatim into the outbound prompt as data, never parsed
 * for config. Each tier therefore applies its OWN env block
 * immediately before that tier's fsql_load_reasoning() call.
 * Reasoning runs through four INDEPENDENT tiers, not one shared one:
 * T2S's REVIEW step used to share the T2S tier (RESPONSE_MODE
 * hard-forced to "code" there, wrong for a plain PASS/FAIL text
 * judgment) until it got its own REVIEW tier. See fsql_reasoning.c
 * for the per-tier env blocks. */
typedef enum FsqlReasoningTier {
    FSQL_REASONING_TIER_CHAT   = 0,  /* fractal_reason / agent chat calls */
    FSQL_REASONING_TIER_T2S    = 1,  /* text-to-sql GENERATE only         */
    FSQL_REASONING_TIER_EMBED  = 2,  /* fractal_embed / vectorizer        */
    FSQL_REASONING_TIER_REVIEW = 3,  /* text-to-sql REVIEW only           */
    FSQL_REASONING_TIER_COUNT  = 4
} FsqlReasoningTier;

/* Per-tier attachment record (FsqlState.reasoning_attach): the plugin
 * may be loaded separately for each tier, each with that tier's env
 * snapshot baked in at init. */
typedef struct FsqlReasoningAttach {
    int      attached;      /* plugin loaded with this tier's env     */
    char    *plugin_path;   /* strdup of the path it was loaded from  */
    uint64_t cfg_fp;        /* FNV-1a of the tier's forwarded config  */
} FsqlReasoningAttach;

/* ------------------------------------------------------------------ */
/* Enterprise core loader (fsql_enterprise.c)                          */
/* ------------------------------------------------------------------ */

/* The community sovereign archive does not export the ledger/audit or
 * multimodal-portfolio symbols (fsql_enterprise.c header explains the
 * link proof). These are resolved from cfg.enterprise_lib at call
 * time instead. */
typedef int (*fsql_ent_ledger_fn)(fsql_ctx *);
typedef int (*fsql_ent_count_fn)(const fsql_ctx *, size_t *);
typedef int (*fsql_ent_audit_unpack_fn)(const void *blob, size_t blob_len,
                                        char *json, size_t *json_cap);
typedef int (*fsql_ent_portfolio_mm_fn)(const double *mu, const double *cov,
                                        size_t n_assets, size_t k,
                                        int n_restarts, double overlap_threshold,
                                        double quality_frac, uint64_t seed,
                                        double *out_weights, double *out_sharpes,
                                        int *out_n_found);
typedef int (*fsql_ent_portfolio_mm_ex_fn)(const double *mu, const double *cov,
                                           size_t n_assets, size_t k,
                                           int n_restarts,
                                           double overlap_threshold,
                                           double quality_frac, uint64_t seed,
                                           int use_obl, int diffusion_mode,
                                           double *out_weights,
                                           double *out_sharpes, int *out_n_found);
typedef int (*fsql_ent_portfolio_pareto_fn)(const double *mu, const double *cov,
                                            size_t n_assets, size_t k,
                                            int n_restarts, int max_front,
                                            uint64_t seed, int use_obl,
                                            int diffusion_mode,
                                            double *out_weights,
                                            double *out_returns,
                                            double *out_risks, int *out_n_found);

typedef struct FsqlEnterpriseApi {
    fsql_ent_ledger_fn         ledger_flush;
    fsql_ent_ledger_fn         ledger_load;
    fsql_ent_ledger_fn         ledger_compact;
    fsql_ent_ledger_fn         ledger_reset_soft;
    fsql_ent_ledger_fn         ledger_reset_hard;
    fsql_ent_count_fn          ledger_truth_count;
    fsql_ent_count_fn          ledger_shadow_count;
    fsql_ent_audit_unpack_fn   audit_unpack;
    /* Optional (tolerant-absence) symbols. */
    fsql_ent_portfolio_mm_fn     optimize_portfolio_multimodal;
    fsql_ent_portfolio_pareto_fn optimize_portfolio_multimodal_pareto;
    fsql_ent_portfolio_mm_ex_fn  optimize_portfolio_multimodal_ex;
} FsqlEnterpriseApi;

/* ------------------------------------------------------------------ */
/* Per-connection state                                                */
/* ------------------------------------------------------------------ */

/* Config keys. Stock SQLite cannot register PRAGMAs, so configuration
 * is per-connection SQL state via fractalsql_set()/fractalsql_get().
 *
 * Path keys are validated strictly at set time: they must be
 * absolute with no traversal segments (mirroring fsql_load_reasoning's
 * own rules) so an untrusted SQL caller cannot aim the extension at a
 * plugin of their choosing. */
typedef struct FsqlConfig {
    char *reasoning_plugin;          /* abs path to reasoning plugin   */
    char *http_url;                  /* chat completions endpoint      */
    char *http_token;                /* bearer token                   */
    char *http_model;                /* model name                     */
    int   http_allow_plaintext;      /* bool: allow http:// endpoints  */
    char *http_embed_url;            /* embeddings endpoint            */
    char *http_embed_model;          /* embedding model                */
    char *http_think;                /* thinking-effort control        */
    char *http_think_provider;       /* openai/ollama/anthropic/vllm/grok */
    char *http_native_url;           /* native-shape endpoint override */
    int   http_num_ctx;              /* ollama options.num_ctx, 0=unset*/
    int   t2s_max_attempts;          /* default 2, range 1..10         */
    char *t2s_allowed_statements;    /* "select"|"select_insert_update"*/
    int   t2s_use_review;            /* bool: extra LLM review pass    */
    char *enterprise_lib;            /* enterprise core .so/.dll path  */
    char *enterprise_ledger_key;     /* HMAC key for ledger blobs      */
    int   enterprise_require_signature; /* bool                        */
    int   agent_partial_reasoning_fail; /* bool: agent returns the
                                         * computed data half plus
                                         * reasoning_step_failed instead
                                         * of raising on a reasoning
                                         * endpoint failure (partial-
                                         * result honesty; MCP sets it
                                         * on at connect) */
    char *response_mode;             /* from FSQL_REASONING_HTTP_RESPONSE_MODE */
} FsqlConfig;

typedef struct FsqlState {
    fsql_ctx    *ctx;                /* sovereign (or minimal) core ctx*/
    FsqlConfig   cfg;
    sqlite3     *db;                 /* owning connection              */

    /* Non-zero while fractal_sql_agent runs model-generated SQL. Functions
     * that change configuration, write, or call out refuse to run then
     * (FSQL_REFUSE_IN_GENERATED_SQL), so a prompt-injected statement cannot
     * use them. Counted, not a flag, so it nests. */
    int          generated_sql_depth;

    /* Ledger storage VFS (fsql_ledger.c). fsql_new_sovereign copies
     * the struct by value at construction, so it is populated BEFORE
     * ctx creation; ledger_ctx backs the callbacks and is valid for
     * the state lifetime. Writes are buffered in ledger_ctx and only
     * materialize into the fractalsql_ledger table from top-level
     * fractal_ledger_flush/load/compact calls, never re-entrant into
     * SQLite mid-statement. */
    fsql_storage_vfs_t storage_vfs;
    void               *ledger_ctx;

    /* Lazy reasoning-plugin attachment, per tier (fsql_reasoning.c).
     * Each tier records whether the plugin was loaded with THAT tier's
     * env block applied, the path it was loaded from, and a
     * fingerprint of the config fields that tier forwards: a
     * fractalsql_set() of any of them makes the next call in the tier
     * re-apply the env and re-run the plugin's init (fsql_load_reasoning
     * replaces an attached plugin, re-running fsql_reasoning_init, so
     * the fresh environment is actually read). */
    FsqlReasoningAttach reasoning_attach[FSQL_REASONING_TIER_COUNT];

    /* One SEPARATE core ctx per reasoning tier (lazily allocated by
     * fsql_new_sovereign(NULL, NULL) in fsql_reasoning.c), distinct
     * from the main st->ctx used for search/ledger. Mirrors the fix
     * already shipped in the PostgreSQL and MariaDB editions
     * (ensure_reasoning_tier_ctx there): the vendored plugin reads its
     * whole configuration from the process environment once, at
     * fsql_load_reasoning() time, and a single shared ctx reloaded in
     * place for whichever tier last ran would leave every OTHER tier's
     * "already attached" cache pointing at a plugin instance actually
     * configured for a different tier's endpoint/mode -- e.g. an EMBED
     * call silently dispatching through a CHAT-configured instance and
     * getting a chat-completion response back where an embedding array
     * was expected. Giving each tier its own ctx (and therefore its
     * own independently loaded plugin instance) makes that impossible:
     * loading tier B's ctx cannot touch tier A's already-loaded one. */
    fsql_ctx *reasoning_ctx[FSQL_REASONING_TIER_COUNT];

    /* Vestigial: fsql_config.c's fractalsql_set clears this on every
     * config change (the 1.x detach signal). Re-attach is now driven
     * by the per-tier records above; the reasoning layer no longer
     * reads or writes this field, which is kept only so fsql_config.c
     * needs no ownership change. */
    char        *attached_plugin;    /* unused; see comment above      */

    /* Enterprise core (fsql_enterprise.c). One attempt per connection;
     * the handle is kept open for the process's life. */
    FsqlEnterpriseApi ent;           /* resolved symbols (zeroed when
                                      * not loaded)                   */
    void        *ent_handle;         /* dlopen/LoadLibrary handle      */
    int          ent_attempted;      /* sticky single-attempt flag     */
    int          ent_loaded;         /* 1 = enterprise surface live    */

    /* One-way latch set by fractal_lock_destructive() (fsql_ledger.c).
     * Once set, the destructive ledger functions (flush / compact /
     * reset_soft / reset_hard) refuse on this connection; nothing clears
     * it, so SQL run later on the connection (including SQL a reasoning
     * agent generated) cannot undo it. The MCP server sets it on its own
     * connections when FSQL_MCP_READ_ONLY=true. */
    int          destructive_locked;

    /* Per-chain-kind high-water mark of the audit rows this process has
     * appended or verified (index = kind, 0..16). The chain lives in an
     * ordinary table that plain SQL can DROP or DELETE FROM, and
     * ledger_ensure_table() quietly recreates it empty -- so without this a
     * wiped chain verified as {"ok":true,"rows_verified":0}.
     * fractal_ledger_verify now reports a chain that is shorter than this
     * as FAILED. In-process only: it cannot see a wipe that happened
     * before this connection first touched the chain. */
    long long    ledger_watermark[17];

    /* Client label stamped into audit-chain entries. Set by the
     * MCP server per call via fractal_set_actor(); empty when unset. A label
     * only: SQLite has no authenticated principal to attest it. */
    char         actor[96];

    /* Whether the Diversify/Repulsion layer is on for THIS connection.
     * The core keeps the setting on its per-connection context but exposes
     * no getter for it, so the flag is mirrored here: the enable and
     * disable functions set it and fractal_explain_result() reports it.
     * Deriving the report from the params getter instead would always say
     * "enabled", because that getter succeeds on a connection that never
     * asked for it. */
    int          diversify_enabled;

    /* Diffusion arena for fractal_search memoization (see the entry TU). */
    double       query[FSQL_ARENA_MAX_DIM];
    double       best_point[FSQL_ARENA_MAX_DIM];
    double       trial[FSQL_ARENA_MAX_DIM];
    int          arena_dim;
    int          best_valid;
    uint64_t     best_hash;          /* FNV-1a of the cached query     */
} FsqlState;

/* Refuses the calling SQL function while the agent runs model-generated SQL.
 * `name` must be a string literal. A macro, not a function: it returns from
 * the caller and reports through that TU's own sqlite3_api. */
#define FSQL_REFUSE_IN_GENERATED_SQL(ctx, st, name)                          \
    do {                                                                     \
        if ((st)->generated_sql_depth > 0) {                                 \
            sqlite3_result_error((ctx),                                      \
                name " is not permitted from model-generated SQL", -1);      \
            return;                                                          \
        }                                                                    \
    } while (0)

/* --- lifecycle (fractalsql_sqlite.c) -------------------------------- */

FsqlState *fsql_state_create(sqlite3 *db, char **pzErrMsg);
void       fsql_state_destroy(void *p);

/* One attempt per connection. Returns 1 when the enterprise surface is
 * live and st->ent is populated; 0 otherwise with the operator-facing
 * reason in `err`. On success the handle is kept open for the
 * process's life. */
int fsql_enterprise_ensure(FsqlState *st, char *err, size_t err_cap);

/* --- ledger storage VFS (fsql_ledger.c) ------------------------------ */

/* Populate st->storage_vfs + st->ledger_ctx before fsql_new_sovereign
 * is called. Sovereign builds only. Returns 0 on success. */
int fsql_ledger_vfs_setup(FsqlState *st);

/* Release the ledger context and every occupied slot payload.
 * fsql_state_destroy calls this in place of a plain free(); it must
 * run after fsql_free(st->ctx), which may re-enter seal_ledger. */
void fsql_ledger_teardown(FsqlState *st);

/* --- vector input decoding (fractalsql_sqlite.c) -------------------- */

/* Decode a TEXT (CSV / bracketed-JSON) or float32-BLOB value into up
 * to `cap` doubles. Returns the element count, or -1 on malformed
 * input / over-cap / over-size. */
int fsql_parse_value_to_doubles(sqlite3_value *v, double *out, int cap);
int fsql_parse_text_vector(const char *src, int slen, double *out, int cap);
int fsql_parse_blob_vector(const void *src, int nbytes, double *out, int cap);

/* --- config (fsql_config.c) ----------------------------------------- */

/* Copy `value` into the config slot `name` after validation. Returns
 * 0 on success; on failure writes a human-readable reason into
 * `err` (may be NULL). Never takes ownership of `value`. */
int  fsql_config_set(FsqlState *st, const char *name,
                     const char *value, char *err, size_t err_cap);

/* Read-only access to the current value; NULL if unset. The pointer is
 * owned by the state and valid until the next fsql_config_set on the
 * same key. */
const char *fsql_config_get(const FsqlState *st, const char *name);

/* Apply the documented default of every key that has one. Called once
 * per connection, when the state is created, so a session that never
 * calls fractalsql_set() still starts from the documented values. */
void fsql_config_apply_defaults(FsqlState *st);

/* Path validation shared by config and the configuration tests: accepts
 * absolute POSIX paths, Windows drive-letter paths, and UNC; rejects empty,
 * relative, and traversal-containing ("..", "/./") paths. Returns 0 if
 * valid. */
int fsql_config_validate_plugin_path(const char *path);

/* --- reasoning attach + dispatch (fsql_reasoning.c) ------------------ */

/* Ensure the plugin configured at cfg.reasoning_plugin is attached to
 * st->ctx FOR THE GIVEN TIER: if the tier's attach record is missing,
 * stale (path changed), or its config fingerprint is stale, the
 * tier's env block is applied and fsql_load_reasoning is (re)run under
 * the process-wide env lock (the environment is process-global and
 * racy). A no-op when no plugin is configured (returns 0). Returns -1
 * on error with a message in `err`, including the EMBED tier's clear
 * "http_embed_url is not configured" when that endpoint is unset.
 * Implemented by fsql_reasoning.c, used by t2s / vectorizer / agents. */
int fsql_reasoning_ensure_attached(FsqlState *st, int tier,
                                   char *err, size_t err_cap);

/* One-shot reasoning call: ensure-attach for `tier` (applying that
 * tier's FSQL_REASONING_HTTP_* env block before the plugin's init
 * runs: the plugin reads its config from the environment ONCE and
 * never from the per-call context), then fsql_dispatch_ai with the
 * caller's context_json passed through VERBATIM (never augmented with
 * config keys: the plugin embeds the context as prompt data, so a
 * key like http_token would leak the credential into the prompt) and
 * the Pattern-C response contract (including the evil-lying-length
 * guard: a response whose self-reported length disagrees with its
 * actual bytes is rejected before any further read). On success
 * returns 0 and sets *out_resp to a malloc'd NUL-terminated copy the
 * caller frees; on failure returns -1 with a message in `err`. */
int fsql_reasoning_generate(FsqlState *st, int tier, const char *query,
                            const char *context_json,
                            char **out_resp, char *err, size_t err_cap);

/* Guard helper shared by the evil-input gates: returns -1 if the
 * plugin response's byte length exceeds `max_bytes` or embeds NULs. */
int fsql_reasoning_guard_response(const char *resp, size_t resp_len,
                                  size_t max_bytes);

/* --- module registration (each TU exposes one) ---------------------- */

/* Each register() installs that module's SQL functions. They receive
 * the shared per-connection state as user_data. Registrations that
 * need an xDestroy pass it themselves; exactly one registration in
 * fractalsql_sqlite.c owns fsql_state_destroy. */
int fsql_vector_register(sqlite3 *db, FsqlState *st);
#ifdef FSQL_SQLITE_SOVEREIGN
int fsql_config_register(sqlite3 *db, FsqlState *st);
/* fsql_reasoning.c registers no SQL functions of its own: it is the
 * helpers-only TU behind the reasoning calls (fsql_reasoning_generate
 * above); its other two functions are declared with the helpers. */
int fsql_t2s_register(sqlite3 *db, FsqlState *st);
int fsql_vectorizer_register(sqlite3 *db, FsqlState *st);
int fsql_agents_register(sqlite3 *db, FsqlState *st);
int fsql_domain_agents_register(sqlite3 *db, FsqlState *st);
int fsql_ledger_register(sqlite3 *db, FsqlState *st);
int fsql_sovereign_register(sqlite3 *db, FsqlState *st);
#endif

#endif /* FSQL_SQLITE_INTERNAL_H */