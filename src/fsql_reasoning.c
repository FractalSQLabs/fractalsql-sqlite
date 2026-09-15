/* src/fsql_reasoning.c: reasoning plugin attach (per-tier env) + dispatch.
 *
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * Lazy reasoning-plugin attach and dispatch machinery. This TU
 * registers NO SQL functions of its own. It exists to be called by
 * fsql_t2s.c, fsql_vectorizer.c and fsql_agents.c, which each wrap one
 * of the helpers below in their own SQL entry points.
 *
 * Design: env forwarding per tier (NOT context JSON)
 *
 *   The vendored reasoning plugin (fractalsql-reasoning-http, tag
 *   v1.4.1, the version shipped in include/) reads ALL of its
 *   configuration from the process environment exactly once, inside
 *   its exported fsql_reasoning_init: FSQL_REASONING_HTTP_URL is
 *   required (init fails if unset), and TOKEN / MODEL / AUTH_TYPE /
 *   SYSTEM_PROMPT / CA_BUNDLE / RESPONSE_MODE / SYSTEM_TAG / MODE /
 *   ALLOW_PLAINTEXT / THINK / THINK_PROVIDER / NATIVE_URL / NUM_CTX
 *   plus the timeout/cap variables are read at the same point. The
 *   per-call context_json passed to fsql_dispatch_ai() is NOT parsed
 *   for configuration: build_instruction_and_context() embeds it
 *   VERBATIM into the outbound prompt as data. Any configuration key
 *   placed in the context therefore reaches the LLM as prompt text;
 *   forwarding http_token that way would send the bearer credential to
 *   the model endpoint. (An earlier draft of this TU did exactly that;
 *   its header comment claimed "the plugin contract reads these keys at
 *   request time", which is false for the vendored plugin.)
 *
 *   Each tier applies its OWN setenv block IMMEDIATELY BEFORE that
 *   tier's fsql_load_reasoning() call,
 *   since the plugin's init runs at load and snapshots the environment,
 *   and keeps a separate attached-state record per tier so switching
 *   between chat, text-to-sql and embedding use re-applies the right
 *   env and re-runs the plugin's init (fsql_load_reasoning replaces an
 *   already-attached plugin). A fingerprint of the config fields each
 *   tier forwards is recorded at load time, so a fractalsql_set() of
 *   any of them triggers a re-apply + re-load on the next use in that
 *   tier instead of silently keeping the stale configuration.
 *
 *   The dispatch context handed to fsql_dispatch_ai() is the caller's
 *   context_json verbatim (or "{}" when empty) and NOTHING else. It is
 *   already JSON by contract; re-escaping it would double-encode, and
 *   it must never carry configuration for the leak reason above.
 *
 * Tier blocks:
 *
 *   CHAT   (fractal_reason, agents): URL/TOKEN/MODEL/ALLOW_PLAINTEXT
 *          from config; MODE + SYSTEM_TAG unset; RESPONSE_MODE = the
 *          configured response_mode or unset; think-tier vars
 *          (THINK, THINK_PROVIDER, NATIVE_URL, NUM_CTX) each set or
 *          unset per config (apply_think_env).
 *   T2S    (fractal_text_to_sql's GENERATE + fractal_sql_agent): same
 *          as CHAT but RESPONSE_MODE hard-forced to "code" and
 *          SYSTEM_TAG set to "sqlite"; the forced RESPONSE_MODE is
 *          unset again right after the load.
 *   REVIEW (fractal_text_to_sql's REVIEW step, t2s_review() in
 *          fsql_t2s.c): same surface as CHAT, but RESPONSE_MODE, MODE
 *          and SYSTEM_TAG are hard-unset regardless of cfg
 *          ->response_mode. REVIEW is a plain PASS/FAIL-then-explain
 *          text judgment, parsed with a hardcoded leading-PASS/FAIL
 *          check (critique_pass() in fsql_t2s.c). It must never run
 *          under T2S's forced "code" mode (the code-block extractor
 *          could return a quoted SQL fragment instead of the leading
 *          PASS/FAIL) or under an operator's own configured
 *          response_mode for CHAT (e.g. "json") either.
 *   EMBED  (fractal_embed / vectorizer / agents embedding): URL =
 *          http_embed_url (clear error if unset, no fallback to the
 *          chat http_url); MODEL = http_embed_model or UNSET (never a
 *          fallback to http_model, since a chat model is not an
 *          embedding model); TOKEN + ALLOW_PLAINTEXT as usual; MODE
 *          forced to "embedding"; SYSTEM_TAG, RESPONSE_MODE and all
 *          four think-tier vars unset.
 *
 * Environment is process-global: a SQLite extension loaded into
 * someone else's process mutates it rudely, and two threads applying
 * different tiers' env blocks concurrently could interleave their
 * setenv calls and hand a load the wrong tier's configuration. The
 * env-apply + load + state-record critical section therefore runs
 * under a process-wide sqlite3 mutex (see reasoning_env_lock below).
 *
 * The evil-lying-length guard is fsql_reasoning_guard_response()
 * below, extended with an embedded-NUL check: the reasoning ABI
 * supplies summary_len but does not promise
 * NUL-termination, so a buggy plugin whose self-reported length
 * disagrees with the actual bytes must be rejected before any further
 * read.
 */

/* setenv/unsetenv are POSIX, not C11: request their declarations under
 * -std=c11 (a no-op on Windows, which uses _putenv_s below). */
#if !defined(_WIN32) && !defined(_POSIX_C_SOURCE)
#  define _POSIX_C_SOURCE 200809L
#endif

#include <sqlite3ext.h>
SQLITE_EXTENSION_INIT3

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
#endif

#include "fsql_sqlite_internal.h"

/* ------------------------------------------------------------------ */
/* Error helpers                                                       */
/* ------------------------------------------------------------------ */

/* err may be NULL (callers without an error buffer); truncation by
 * snprintf is fine — messages are diagnostics, not contracts. */
static void set_err(char *err, size_t err_cap, const char *fmt, ...) {
    if (!err || err_cap == 0) return;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(err, err_cap, fmt, ap);
    va_end(ap);
}

/* Format fsql_last_error() detail as "(no detail)" when the core has
 * nothing to say. Takes the ctx explicitly (not FsqlState) since a
 * reasoning error's detail lives on that tier's own ctx, not st->ctx
 * (see FsqlState.reasoning_ctx in fsql_sqlite_internal.h). */
static const char *core_detail(fsql_ctx *ctx) {
    const char *detail = fsql_last_error(ctx);
    return (detail && *detail) ? detail : "(no detail)";
}

/* ------------------------------------------------------------------ */
/* Env helpers                                                         */
/* ------------------------------------------------------------------ */

/* Reasoning plugins are a public C-ABI surface: a plugin built with a
 * different CRT than this host won't see _putenv_s's update, since that
 * only touches the caller's own CRT-private environment. Pairing it with
 * SetEnvironmentVariableA writes the one OS-level block every CRT resyncs
 * from. */
static void fsql_setenv(const char *name, const char *value) {
#ifdef _WIN32
    _putenv_s(name, value);
    SetEnvironmentVariableA(name, value);
#else
    setenv(name, value, 1 /* overwrite */);
#endif
}

static void fsql_unsetenv(const char *name) {
#ifdef _WIN32
    _putenv_s(name, "");
    SetEnvironmentVariableA(name, NULL);
#else
    unsetenv(name);
#endif
}

/* The variable names the vendored plugin's fsql_reasoning_init reads
 * (reasoning_http.c v1.4.1), once, at load time. */
#define ENV_URL             "FSQL_REASONING_HTTP_URL"
#define ENV_TOKEN           "FSQL_REASONING_HTTP_TOKEN"
#define ENV_MODEL           "FSQL_REASONING_HTTP_MODEL"
#define ENV_ALLOW_PLAINTEXT "FSQL_REASONING_HTTP_ALLOW_PLAINTEXT"
#define ENV_MODE            "FSQL_REASONING_HTTP_MODE"
#define ENV_SYSTEM_TAG      "FSQL_REASONING_HTTP_SYSTEM_TAG"
#define ENV_RESPONSE_MODE   "FSQL_REASONING_HTTP_RESPONSE_MODE"
#define ENV_THINK           "FSQL_REASONING_HTTP_THINK"
#define ENV_THINK_PROVIDER  "FSQL_REASONING_HTTP_THINK_PROVIDER"
#define ENV_NATIVE_URL      "FSQL_REASONING_HTTP_NATIVE_URL"
#define ENV_NUM_CTX         "FSQL_REASONING_HTTP_NUM_CTX"

/* Set or clear one string variable: a NULL/empty `value` unsets (the
 * plugin treats a missing variable as "not configured" for every
 * optional field). */
static void env_apply(const char *name, const char *value) {
    if (value && *value) fsql_setenv(name, value);
    else                 fsql_unsetenv(name);
}

static void env_apply_num_ctx(int num_ctx) {
    if (num_ctx > 0) {
        char buf[32];
        snprintf(buf, sizeof buf, "%d", num_ctx);
        fsql_setenv(ENV_NUM_CTX, buf);
    } else {
        fsql_unsetenv(ENV_NUM_CTX);
    }
}

static void env_apply_plaintext(int allow) {
    if (allow) fsql_setenv(ENV_ALLOW_PLAINTEXT, "1");
    else       fsql_unsetenv(ENV_ALLOW_PLAINTEXT);
}

/* Set or unset each of the four think-tier variables from the
 * config. */
static void apply_think_env(const FsqlConfig *cfg) {
    env_apply(ENV_THINK, cfg->http_think);
    env_apply(ENV_THINK_PROVIDER, cfg->http_think_provider);
    env_apply(ENV_NATIVE_URL, cfg->http_native_url);
    env_apply_num_ctx(cfg->http_num_ctx);
}

static void apply_chat_env(const FsqlConfig *cfg) {
    env_apply(ENV_URL, cfg->http_url);
    env_apply(ENV_TOKEN, cfg->http_token);
    env_apply(ENV_MODEL, cfg->http_model);
    env_apply_plaintext(cfg->http_allow_plaintext);
    fsql_unsetenv(ENV_MODE);          /* chat completions, not embedding */
    fsql_unsetenv(ENV_SYSTEM_TAG);    /* no host tag on the chat tier    */
    env_apply(ENV_RESPONSE_MODE, cfg->response_mode);
    apply_think_env(cfg);
}

static void apply_t2s_env(const FsqlConfig *cfg) {
    /* Same surface as CHAT, but RESPONSE_MODE is hard-forced to "code"
     * and SYSTEM_TAG carries the host tag so the provider can
     * attribute this tier's traffic. */
    env_apply(ENV_URL, cfg->http_url);
    env_apply(ENV_TOKEN, cfg->http_token);
    env_apply(ENV_MODEL, cfg->http_model);
    env_apply_plaintext(cfg->http_allow_plaintext);
    fsql_unsetenv(ENV_MODE);          /* chat completions, not embedding */
    fsql_setenv(ENV_SYSTEM_TAG, "sqlite");
    fsql_setenv(ENV_RESPONSE_MODE, "code");
    apply_think_env(cfg);
}

static void apply_review_env(const FsqlConfig *cfg) {
    /* Same surface as CHAT, but RESPONSE_MODE, MODE and SYSTEM_TAG are
     * hard-unset regardless of cfg->response_mode: t2s_review() needs a
     * raw leading PASS/FAIL, which neither the T2S tier's forced "code"
     * mode nor an operator's own configured chat response_mode (e.g.
     * "json") would reliably produce. */
    env_apply(ENV_URL, cfg->http_url);
    env_apply(ENV_TOKEN, cfg->http_token);
    env_apply(ENV_MODEL, cfg->http_model);
    env_apply_plaintext(cfg->http_allow_plaintext);
    fsql_unsetenv(ENV_MODE);
    fsql_unsetenv(ENV_SYSTEM_TAG);
    fsql_unsetenv(ENV_RESPONSE_MODE);
    apply_think_env(cfg);
}

static void apply_embed_env(const FsqlConfig *cfg) {
    /* The embed endpoint has NO fallback to the
     * chat http_url, and the embed model has NO fallback to http_model,
     * since a chat model is not an embedding model. MODE is forced to
     * "embedding"; SYSTEM_TAG, RESPONSE_MODE and every think-tier
     * variable are cleared (thinking has no embedding-mode meaning).
     * A NULL/empty http_embed_url is rejected by ensure_attached
     * before this runs. */
    env_apply(ENV_URL, cfg->http_embed_url);
    env_apply(ENV_MODEL, cfg->http_embed_model);
    env_apply(ENV_TOKEN, cfg->http_token);
    env_apply_plaintext(cfg->http_allow_plaintext);
    fsql_setenv(ENV_MODE, "embedding");
    fsql_unsetenv(ENV_SYSTEM_TAG);
    fsql_unsetenv(ENV_RESPONSE_MODE);
    fsql_unsetenv(ENV_THINK);
    fsql_unsetenv(ENV_THINK_PROVIDER);
    fsql_unsetenv(ENV_NATIVE_URL);
    fsql_unsetenv(ENV_NUM_CTX);
}

/* ------------------------------------------------------------------ */
/* Config fingerprint (per tier)                                       */
/* ------------------------------------------------------------------ */

/* FNV-1a over length-prefixed strings (rather than separator-joined
 * text) so no configuration value can collide with a different
 * (field, value) pairing: the length prefix makes the encoding of the
 * field sequence injective. A 64-bit FNV-1a over that encoding is
 * collision-free in practice for change detection. */
static uint64_t fp_byte(uint64_t h, unsigned char c) {
    h ^= c;
    h *= 0x100000001b3ULL;
    return h;
}

static uint64_t fp_str(uint64_t h, const char *s) {
    size_t n = s ? strlen(s) : 0;
    for (int i = 0; i < 8; i++)
        h = fp_byte(h, (unsigned char)((n >> (i * 8)) & 0xff));
    for (size_t i = 0; i < n; i++)
        h = fp_byte(h, (unsigned char)s[i]);
    return h;
}

static uint64_t fp_int(uint64_t h, int v) {
    unsigned uv = (unsigned)v;
    for (size_t i = 0; i < sizeof(uv); i++)
        h = fp_byte(h, (unsigned char)((uv >> (i * 8)) & 0xff));
    return h;
}

/* Digest of exactly the config fields the tier's env block forwards.
 * The plugin path is compared separately (att->plugin_path). CHAT,
 * T2S and REVIEW forward the same fields (T2S's RESPONSE_MODE/
 * SYSTEM_TAG are forced constants, REVIEW's are hard-unset constants;
 * neither actually varies with cfg->response_mode, but folding
 * response_mode into their fingerprint too is harmless, just an
 * occasional redundant reload); EMBED forwards the embed-specific
 * pair. */
static uint64_t tier_fingerprint(const FsqlConfig *cfg, int tier) {
    uint64_t h = 0xcbf29ce484222325ULL; /* FNV offset basis */
    if (tier == FSQL_REASONING_TIER_EMBED) {
        h = fp_str(h, cfg->http_embed_url);
        h = fp_str(h, cfg->http_embed_model);
        h = fp_str(h, cfg->http_token);
        h = fp_int(h, cfg->http_allow_plaintext);
    } else {  /* CHAT, T2S and REVIEW */
        h = fp_str(h, cfg->http_url);
        h = fp_str(h, cfg->http_token);
        h = fp_str(h, cfg->http_model);
        h = fp_str(h, cfg->response_mode);
        h = fp_str(h, cfg->http_think);
        h = fp_str(h, cfg->http_think_provider);
        h = fp_str(h, cfg->http_native_url);
        h = fp_int(h, cfg->http_allow_plaintext);
        h = fp_int(h, cfg->http_num_ctx);
    }
    return h;
}

/* ------------------------------------------------------------------ */
/* Process-wide env lock                                               */
/* ------------------------------------------------------------------ */

/* Held across env-apply + fsql_load_reasoning + state recording. The
 * environment is process-global and racy: two connections (or two
 * threads on one connection) applying different tiers' env blocks
 * concurrently could interleave their setenv calls and hand a load the
 * wrong tier's configuration. SQLITE_MUTEX_FAST: this critical
 * section never recurses. Lazily allocated, with SQLite's
 * SQLITE_MUTEX_STATIC_MASTER (a static mutex SQLite owns) guarding the
 * one-time creation. The mutex is intentionally NEVER freed: freeing
 * a mutex another thread may be entering is worse than the single
 * allocation leaked at process exit. */
static sqlite3_mutex *g_reasoning_env_mu = NULL;

static void reasoning_env_lock(void) {
    if (!g_reasoning_env_mu) {
        sqlite3_mutex *master =
            sqlite3_mutex_alloc(SQLITE_MUTEX_STATIC_MASTER);
        if (master) {
            sqlite3_mutex_enter(master);
            if (!g_reasoning_env_mu)
                g_reasoning_env_mu = sqlite3_mutex_alloc(SQLITE_MUTEX_FAST);
            sqlite3_mutex_leave(master);
        }
    }
    if (g_reasoning_env_mu)
        sqlite3_mutex_enter(g_reasoning_env_mu);
    /* If even the master mutex could not be allocated the process is
     * in no state to load a plugin anyway; proceeding unlocked is the
     * least-surprising degradation for a diagnostic-only path. */
}

static void reasoning_env_unlock(void) {
    if (g_reasoning_env_mu)
        sqlite3_mutex_leave(g_reasoning_env_mu);
}

/* ------------------------------------------------------------------ */
/* ensure_attached                                                     */
/* ------------------------------------------------------------------ */

int fsql_reasoning_ensure_attached(FsqlState *st, int tier,
                                   char *err, size_t err_cap) {
    if (!st || !st->ctx) {
        set_err(err, err_cap, "fractalsql: not initialized");
        return -1;
    }
    if (tier < FSQL_REASONING_TIER_CHAT ||
        tier >= FSQL_REASONING_TIER_COUNT) {
        set_err(err, err_cap, "fractalsql: unknown reasoning tier %d", tier);
        return -1;
    }

    /* No plugin configured: a search-only operation. Not an error —
     * the callers turn this into their own "no reasoning plugin"
     * message only when the operation actually needs inference. */
    const char *path = st->cfg.reasoning_plugin;
    if (!path || !*path) return 0;

    /* Embed tier: the endpoint must be configured. Rejected here so
     * the clear error fires before any env mutation. No fallback to
     * the chat http_url: a chat model is not
     * a substitute for a purpose-trained embedding model, and the two
     * live on different endpoint paths even on the same provider. */
    if (tier == FSQL_REASONING_TIER_EMBED &&
        (!st->cfg.http_embed_url || !*st->cfg.http_embed_url)) {
        set_err(err, err_cap,
                "fractal_embed: http_embed_url is not configured (set "
                "fractalsql_set('http_embed_url', "
                "'https://.../v1/embeddings'))");
        return -1;
    }

    /* Already attached for this tier, from this path, with this
     * configuration? A fractalsql_set() of any forwarded field (or of
     * the plugin path itself) changes the fingerprint and forces a
     * re-apply + re-load on the next use: fsql_load_reasoning
     * replaces the attached plugin and re-runs its init, so the fresh
     * environment is actually read. Safe to trust this cache purely
     * per-tier because each tier has its OWN ctx below -- another
     * tier's reload can never invalidate this one's. */
    FsqlReasoningAttach *att = &st->reasoning_attach[tier];
    uint64_t fp = tier_fingerprint(&st->cfg, tier);
    if (att->attached && att->plugin_path &&
        strcmp(att->plugin_path, path) == 0 && att->cfg_fp == fp)
        return 0;

    /* Lazily allocate this tier's own ctx on first use. No storage/
     * ledger VFS needed here -- it exists purely to host this tier's
     * independently loaded reasoning plugin instance, separate from
     * st->ctx (search/ledger) and from every other tier's ctx. */
    if (!st->reasoning_ctx[tier]) {
        st->reasoning_ctx[tier] = fsql_new_sovereign(NULL, NULL);
        if (!st->reasoning_ctx[tier]) {
            set_err(err, err_cap,
                    "fractalsql: reasoning ctx allocation failed (OOM?)");
            return -1;
        }
    }
    fsql_ctx *tier_ctx = st->reasoning_ctx[tier];

    reasoning_env_lock();

    switch (tier) {
    case FSQL_REASONING_TIER_CHAT:
        apply_chat_env(&st->cfg);
        break;
    case FSQL_REASONING_TIER_T2S:
        apply_t2s_env(&st->cfg);
        break;
    case FSQL_REASONING_TIER_EMBED:
        apply_embed_env(&st->cfg);
        break;
    case FSQL_REASONING_TIER_REVIEW:
        apply_review_env(&st->cfg);
        break;
    default:
        reasoning_env_unlock();
        set_err(err, err_cap, "fractalsql: unknown reasoning tier %d", tier);
        return -1;
    }

    int rc = fsql_load_reasoning(tier_ctx, path);

    if (tier == FSQL_REASONING_TIER_T2S) {
        /* RESPONSE_MODE is unset right after the t2s load so the
         * hard-forced "code" does not outlive this tier's init (the
         * plugin only reads the env at init, so the next t2s load
         * re-sets it first). */
        fsql_unsetenv(ENV_RESPONSE_MODE);
    }

    if (rc != 0) {
        reasoning_env_unlock();
        /* A failed load raises an error with the core's last_error
         * detail but does NOT tear down the ctx; here the caller just
         * gets -1 and the next attempt retries the load (the attached
         * flag is only recorded on success, so the retry actually
         * happens). */
        set_err(err, err_cap,
                "fractalsql: failed to load reasoning plugin \"%s\" "
                "(rc=%d): %s",
                path, rc, core_detail(tier_ctx));
        return -1;
    }

    char *copy = strdup(path);
    if (!copy) {
        reasoning_env_unlock();
        set_err(err, err_cap,
                "fractalsql: out of memory recording attached plugin path");
        return -1;
    }
    free(att->plugin_path);
    att->plugin_path = copy;
    att->cfg_fp = fp;
    att->attached = 1;

    reasoning_env_unlock();
    return 0;
}

/* ------------------------------------------------------------------ */
/* generate                                                            */
/* ------------------------------------------------------------------ */

int fsql_reasoning_generate(FsqlState *st, int tier, const char *query,
                            const char *context_json,
                            char **out_resp, char *err, size_t err_cap) {
    if (out_resp) *out_resp = NULL;

    if (!st || !st->ctx) {
        set_err(err, err_cap, "fractalsql: not initialized");
        return -1;
    }
    if (!query) {
        set_err(err, err_cap,
                "fractalsql: reasoning query must not be NULL");
        return -1;
    }
    if (tier < FSQL_REASONING_TIER_CHAT ||
        tier >= FSQL_REASONING_TIER_COUNT) {
        set_err(err, err_cap, "fractalsql: unknown reasoning tier %d", tier);
        return -1;
    }

    if (fsql_reasoning_ensure_attached(st, tier, err, err_cap) != 0)
        return -1;

    /* ensure_attached returns 0 for both "attached" and "nothing
     * configured"; only the former may proceed to dispatch. */
    if (!st->cfg.reasoning_plugin || !*st->cfg.reasoning_plugin) {
        set_err(err, err_cap,
                "fractalsql: no reasoning plugin configured (set "
                "fractalsql_set('reasoning_plugin', '/absolute/path.so'))");
        return -1;
    }

    /* Dispatch context = the caller's context_json, verbatim (or "{}"
     * when empty). NO configuration keys here: the plugin embeds this
     * JSON into the outbound prompt as data (build_instruction_and_
     * context), so anything added here, http_token included, would be
     * sent to the LLM endpoint as prompt text. Configuration reaches
     * the plugin through the tier env block in ensure_attached
     * instead. The caller context is already JSON by contract;
     * re-escaping it would double-encode, and validating it here would
     * duplicate the plugin's own parser for no benefit. */
    const char *ctx_json = (context_json && *context_json)
                         ? context_json : "{}";

    /* Dispatch through THIS TIER's own ctx (populated above by
     * ensure_attached), not the shared st->ctx -- see FsqlState.
     * reasoning_ctx's comment in fsql_sqlite_internal.h. */
    fsql_ctx *tier_ctx = st->reasoning_ctx[tier];

    fsql_ai_response_t resp;
    memset(&resp, 0, sizeof(resp));

    int rc = fsql_dispatch_ai(tier_ctx,
                              query,    strlen(query),
                              ctx_json, strlen(ctx_json),
                              &resp);
    if (rc != 0 || resp.rc != 0) {
        int err_rc = (rc != 0) ? rc : resp.rc;
        set_err(err, err_cap,
                "fractalsql: reasoning dispatch failed (rc=%d): %s",
                err_rc, core_detail(tier_ctx));
        fsql_ai_response_free(&resp);
        return -1;
    }

    /* Evil-lying-length guard, before any further read of the
     * response: reject a self-reported length over the input-side cap
     * (a buggy plugin's uninitialized length would otherwise drive an
     * unbounded read/allocation) and reject embedded NULs (the ABI
     * supplies summary_len but does not promise NUL-termination, so a
     * length longer than the real payload would copy garbage). */
    if (fsql_reasoning_guard_response(resp.summary, resp.summary_len,
                                      FSQL_MAX_INPUT_BYTES) != 0) {
        set_err(err, err_cap,
                "fractalsql: reasoning plugin reported an implausible "
                "response length or embedded NUL (%zu bytes, limit %zu) "
                "-- likely a plugin bug",
                resp.summary_len, (size_t)FSQL_MAX_INPUT_BYTES);
        fsql_ai_response_free(&resp);
        return -1;
    }

    /* Length-bounded copy with explicit NUL termination for the SQL
     * layer: resp.summary itself is only valid until
     * fsql_ai_response_free and may not be NUL-terminated. */
    char *copy = (char *)malloc(resp.summary_len + 1);
    if (!copy) {
        set_err(err, err_cap,
                "fractalsql: out of memory copying reasoning response");
        fsql_ai_response_free(&resp);
        return -1;
    }
    /* memcpy(dst, NULL, 0) is technically UB even at length 0, and a
     * zero-length response legitimately arrives with summary == NULL. */
    if (resp.summary && resp.summary_len)
        memcpy(copy, resp.summary, resp.summary_len);
    copy[resp.summary_len] = '\0';

    fsql_ai_response_free(&resp);

    *out_resp = copy;
    return 0;
}

/* ------------------------------------------------------------------ */
/* Response guard                                                      */
/* ------------------------------------------------------------------ */

int fsql_reasoning_guard_response(const char *resp, size_t resp_len,
                                  size_t max_bytes) {
    if (!resp && resp_len > 0) return -1;   /* lying length, no buffer */
    if (resp_len > max_bytes)  return -1;   /* implausible length       */
    if (resp && memchr(resp, '\0', resp_len) != NULL)
        return -1;                          /* embedded NUL             */
    return 0;
}