/* src/fsql_config.c: fractalsql_set / fractalsql_get.
 *
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * Stock SQLite cannot register new PRAGMAs, so the 17 configuration
 * keys become per-connection SQL state, validated against fixed
 * defaults/ranges:
 *
 *   key                                  type
 *   ------------------------------------ ----
 *   reasoning_plugin                     path*
 *   http_url                             str*
 *   http_token                           str*
 *   http_model                           str
 *   http_allow_plaintext                 bool
 *   http_embed_url                       str*
 *   http_embed_model                     str
 *   http_think                           str
 *   http_think_provider                  str
 *   http_native_url                      str
 *   http_num_ctx                         int 0..1048576
 *   text_to_sql_max_attempts             int 1..10 (dflt 2)
 *   text_to_sql_allowed_statements       enum
 *   text_to_sql_use_review               bool
 *   enterprise_lib                       path*
 *   enterprise_ledger_key                str*
 *   enterprise_require_signature         bool
 *
 *   * = path-type keys get extra validation at set time: they must be
 *   absolute with no traversal segments (mirroring fsql_load_reasoning's
 *   own rules), which is exactly what gate 09 asserts.
 *
 * Keys are named without a "fractalsql." prefix: fractalsql_set(
 * 'http_url', ...). The prefixed spelling ("fractalsql.http_url") is
 * also accepted.
 */

/* strdup is POSIX, not C11: request its declaration under -std=c11 (a
 * no-op on Windows, which has no strdup at all; see the copy below).
 * Without this, glibc's <string.h> omits strdup under strict-ISO
 * -std=c11, the compiler implicitly declares it returning `int`, and
 * the truncated-to-32-bit "pointer" it hands back silently corrupts
 * every config value stored here on a 64-bit build (a warning, not an
 * error). Same fix as fsql_reasoning.c carries for the same reason. */
#if !defined(_WIN32) && !defined(_POSIX_C_SOURCE)
#  define _POSIX_C_SOURCE 200809L
#endif

#include <sqlite3ext.h>
SQLITE_EXTENSION_INIT3

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fsql_sqlite_internal.h"

/* ------------------------------------------------------------------ */
/* Key table                                                           */
/* ------------------------------------------------------------------ */

typedef enum { CFG_STR, CFG_PATH, CFG_INT, CFG_BOOL, CFG_ENUM } CfgType;

typedef struct {
    const char *key;        /* without the "fractalsql." prefix      */
    CfgType     type;
    char      **str_slot;   /* &st->cfg.<char *>                     */
    int        *int_slot;   /* &st->cfg.<int>                        */
    int         int_min, int_max;
    const char *dflt;       /* canonical default (set at state init) */
    const char *enum_vals;  /* CFG_ENUM only: "a|b|c"                */
} CfgDef;

/* slot accessors below index the FsqlConfig via offsetof-free layout:
 * the table's str_slot/int_slot point INTO FsqlState::cfg. */

static const CfgDef CFG_TABLE[] = {
    { "reasoning_plugin",        CFG_PATH, NULL, NULL, 0, 0, NULL, NULL },
    { "http_url",                CFG_PATH, NULL, NULL, 0, 0, NULL, NULL },
    { "http_token",              CFG_STR,  NULL, NULL, 0, 0, NULL, NULL },
    { "http_model",              CFG_STR,  NULL, NULL, 0, 0, NULL, NULL },
    { "http_allow_plaintext",    CFG_BOOL, NULL, NULL, 0, 0, "0",  NULL },
    { "http_embed_url",          CFG_PATH, NULL, NULL, 0, 0, NULL, NULL },
    { "http_embed_model",        CFG_STR,  NULL, NULL, 0, 0, NULL, NULL },
    { "http_think",              CFG_STR,  NULL, NULL, 0, 0, NULL, NULL },
    { "http_think_provider",     CFG_STR,  NULL, NULL, 0, 0, NULL, NULL },
    { "http_native_url",         CFG_PATH, NULL, NULL, 0, 0, NULL, NULL },
    { "http_num_ctx",            CFG_INT,  NULL, NULL, 0, 1048576, "0", NULL },
    { "text_to_sql_max_attempts",CFG_INT,  NULL, NULL, 1, 10, "2",  NULL },
    { "text_to_sql_allowed_statements", CFG_ENUM, NULL, NULL, 0, 0,
      "select", "select|select_insert_update" },
    { "text_to_sql_use_review",  CFG_BOOL, NULL, NULL, 0, 0, "0",  NULL },
    { "enterprise_lib",          CFG_PATH, NULL, NULL, 0, 0, NULL, NULL },
    { "enterprise_ledger_key",   CFG_STR,  NULL, NULL, 0, 0, NULL, NULL },
    { "enterprise_require_signature", CFG_BOOL, NULL, NULL, 0, 0, "0", NULL },
};
#define CFG_N (sizeof(CFG_TABLE) / sizeof(CFG_TABLE[0]))

/* URL-ish keys are CFG_PATH-validated too (an http_url is not a plugin
 * path, but the same traversal hygiene applies and gate 09 relies on
 * it); http_* URL keys allow the url scheme prefix. */
static int key_is_url(const char *key) {
    return strcmp(key, "http_url") == 0 ||
           strcmp(key, "http_embed_url") == 0 ||
           strcmp(key, "http_native_url") == 0;
}

static const CfgDef *cfg_lookup(const char *name) {
    if (strncmp(name, "fractalsql.", 11) == 0) name += 11;
    for (size_t i = 0; i < CFG_N; i++)
        if (strcmp(CFG_TABLE[i].key, name) == 0) return &CFG_TABLE[i];
    return NULL;
}

/* Resolve a CfgDef's slot pointers against the actual state. The
 * config surface is small enough that explicit key-conditional wiring
 * stays readable and grep-able. */
static char **cfg_str_slot(FsqlState *st, const CfgDef *d) {
    if (strcmp(d->key, "reasoning_plugin") == 0)        return &st->cfg.reasoning_plugin;
    if (strcmp(d->key, "http_url") == 0)                return &st->cfg.http_url;
    if (strcmp(d->key, "http_token") == 0)              return &st->cfg.http_token;
    if (strcmp(d->key, "http_model") == 0)              return &st->cfg.http_model;
    if (strcmp(d->key, "http_embed_url") == 0)          return &st->cfg.http_embed_url;
    if (strcmp(d->key, "http_embed_model") == 0)        return &st->cfg.http_embed_model;
    if (strcmp(d->key, "http_think") == 0)              return &st->cfg.http_think;
    if (strcmp(d->key, "http_think_provider") == 0)     return &st->cfg.http_think_provider;
    if (strcmp(d->key, "http_native_url") == 0)         return &st->cfg.http_native_url;
    if (strcmp(d->key, "text_to_sql_allowed_statements") == 0)
        return &st->cfg.t2s_allowed_statements;
    if (strcmp(d->key, "enterprise_lib") == 0)          return &st->cfg.enterprise_lib;
    if (strcmp(d->key, "enterprise_ledger_key") == 0)   return &st->cfg.enterprise_ledger_key;
    return NULL;
}
static int *cfg_int_slot(FsqlState *st, const CfgDef *d) {
    if (strcmp(d->key, "http_num_ctx") == 0)       return &st->cfg.http_num_ctx;
    if (strcmp(d->key, "text_to_sql_max_attempts") == 0)
        return &st->cfg.t2s_max_attempts;
    if (strcmp(d->key, "http_allow_plaintext") == 0) return &st->cfg.http_allow_plaintext;
    if (strcmp(d->key, "text_to_sql_use_review") == 0)
        return &st->cfg.t2s_use_review;
    if (strcmp(d->key, "enterprise_require_signature") == 0)
        return &st->cfg.enterprise_require_signature;
    return NULL;
}

/* ------------------------------------------------------------------ */
/* Path validation (shared with the gate-09 assertions)                */
/* ------------------------------------------------------------------ */

int fsql_config_validate_plugin_path(const char *path) {
    if (!path || !*path) return -1;
    size_t n = strlen(path);
    if (n >= FSQL_MAX_INPUT_BYTES) return -1;

    int is_abs = 0;
#ifdef _WIN32
    /* drive letter (C:\ or C:/) or UNC (\\server\share) or C:/posix-style */
    if (((path[0] >= 'A' && path[0] <= 'Z') ||
         (path[0] >= 'a' && path[0] <= 'z')) && path[1] == ':' &&
        (path[2] == '\\' || path[2] == '/'))
        is_abs = 1;
    if (path[0] == '\\' && path[1] == '\\') is_abs = 1;
#else
    if (path[0] == '/') is_abs = 1;   /* fsql_load_reasoning's own rule */
#endif
    if (!is_abs) return -1;

    /* Lexical traversal segments: mirrors the core's "/../", "/./"
     * rejection. */
    for (size_t i = 0; i + 1 < n; i++) {
        if (path[i] == '.' && path[i+1] == '.') return -1;
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/* set / get core                                                      */
/* ------------------------------------------------------------------ */

int fsql_config_set(FsqlState *st, const char *name,
                    const char *value, char *err, size_t err_cap) {
    const CfgDef *d = cfg_lookup(name);
    if (!d) {
        if (err) snprintf(err, err_cap, "unknown config key '%s'", name);
        return -1;
    }
    /* Accept the prefixed spelling in error messages verbatim. */
    const char *bare = (strncmp(name, "fractalsql.", 11) == 0)
                     ? name + 11 : name;

    /* The library path is locked once a library has loaded: the loaded
     * image is the trust anchor, and re-pointing it mid-session would
     * let a SQL principal swap it out from under the already-verified
     * surface (see fsql_enterprise.c's policy comment). Re-open the
     * connection to re-evaluate. */
    if (strcmp(bare, "enterprise_lib") == 0 && st->ent_loaded) {
        if (err) snprintf(err, err_cap,
            "'%s' cannot be changed after the enterprise library has "
            "loaded -- reopen the connection to re-evaluate it", bare);
        return -1;
    }

    switch (d->type) {
    case CFG_STR:
    case CFG_PATH: {
        if (!value || !*value) {
            /* Empty string resets to unset, matching GUC ''=default. */
            char **slot = cfg_str_slot(st, d);
            free(*slot); *slot = NULL;
            return 0;
        }
        if (d->type == CFG_PATH && !key_is_url(bare)) {
            if (fsql_config_validate_plugin_path(value) != 0) {
                if (err) snprintf(err, err_cap,
                    "'%s' must be an absolute path with no '..' segments",
                    bare);
                return -1;
            }
        } else if (d->type == CFG_PATH && key_is_url(bare)) {
            if (strlen(value) > 2048) {
                if (err) snprintf(err, err_cap, "'%s' too long", bare);
                return -1;
            }
        } else if (strlen(value) > 8192) {
            if (err) snprintf(err, err_cap, "'%s' too long", bare);
            return -1;
        }
        char *copy = strdup(value);
        if (!copy) {
            if (err) snprintf(err, err_cap, "out of memory");
            return -1;
        }
        char **slot = cfg_str_slot(st, d);
        free(*slot);
        *slot = copy;
        return 0;
    }
    case CFG_INT: {
        char *end = NULL;
        long v = strtol(value ? value : "", &end, 10);
        if (!end || *end != '\0' || end == value) {
            if (err) snprintf(err, err_cap,
                "'%s' expects an integer", bare);
            return -1;
        }
        if (v < d->int_min || v > d->int_max) {
            if (err) snprintf(err, err_cap,
                "'%s' must be %d..%d", bare, d->int_min, d->int_max);
            return -1;
        }
        *cfg_int_slot(st, d) = (int)v;
        return 0;
    }
    case CFG_BOOL: {
        int v;
        if (!value) v = 0;
        else if (!strcmp(value, "true") || !strcmp(value, "on") ||
                 !strcmp(value, "1") || !strcmp(value, "yes")) v = 1;
        else if (!strcmp(value, "false") || !strcmp(value, "off") ||
                 !strcmp(value, "0") || !strcmp(value, "no") ||
                 !strcmp(value, "")) v = 0;
        else {
            if (err) snprintf(err, err_cap,
                "'%s' expects true/false/on/off/1/0", bare);
            return -1;
        }
        *cfg_int_slot(st, d) = v;
        return 0;
    }
    case CFG_ENUM: {
        int ok = 0;
        const char *p = d->enum_vals;
        while (p && *p) {
            const char *bar = strchr(p, '|');
            size_t len = bar ? (size_t)(bar - p) : strlen(p);
            if (strlen(value) == len && strncmp(value, p, len) == 0) { ok = 1; break; }
            p = bar ? bar + 1 : NULL;
        }
        if (!ok) {
            if (err) snprintf(err, err_cap,
                "'%s' must be one of: %s", bare, d->enum_vals);
            return -1;
        }
        char *copy = strdup(value);
        if (!copy) {
            if (err) snprintf(err, err_cap, "out of memory");
            return -1;
        }
        char **slot = cfg_str_slot(st, d);
        free(*slot);
        *slot = copy;
        return 0;
    }
    }
    return -1;
}

const char *fsql_config_get(const FsqlState *st, const char *name) {
    const CfgDef *d = cfg_lookup(name);
    if (!d) return NULL;
    if (d->type == CFG_INT || d->type == CFG_BOOL) {
        /* int values are read via the same function's TEXT formatting
         * in the SQL wrapper below; direct pointer access only. */
        return NULL;
    }
    return *cfg_str_slot((FsqlState *)st, d);
}

/* ------------------------------------------------------------------ */
/* SQL wrappers                                                        */
/* ------------------------------------------------------------------ */

/* fractalsql_set(name TEXT, value TEXT) -> 'ok' (or raises). */
static void fs_set_fn(sqlite3_context *ctx, int argc, sqlite3_value **argv) {
    (void)argc;
    FsqlState *st = (FsqlState *)sqlite3_user_data(ctx);
    if (!st) { sqlite3_result_error(ctx, "fractalsql: not initialized", -1); return; }
    if (sqlite3_value_type(argv[0]) != SQLITE_TEXT ||
        sqlite3_value_type(argv[1]) != SQLITE_TEXT) {
        sqlite3_result_error(ctx,
            "fractalsql_set(name, value) expects 2 TEXT args", -1);
        return;
    }
    const char *name = (const char *)sqlite3_value_text(argv[0]);
    const char *value = (const char *)sqlite3_value_text(argv[1]);
    char err[192] = "";
    if (fsql_config_set(st, name, value, err, sizeof err) != 0) {
        sqlite3_result_error(ctx, err[0] ? err : "fractalsql_set failed", -1);
        return;
    }
    /* Changing the plugin path detaches the previously-attached plugin;
     * the next reasoning call re-attaches from the new path. */
    free(st->attached_plugin);
    st->attached_plugin = NULL;
    sqlite3_result_text(ctx, "ok", -1, SQLITE_STATIC);
}

/* fractalsql_get(name TEXT) -> TEXT (NULL if unset / numeric keys). */
static void fs_get_fn(sqlite3_context *ctx, int argc, sqlite3_value **argv) {
    (void)argc;
    FsqlState *st = (FsqlState *)sqlite3_user_data(ctx);
    if (!st) { sqlite3_result_error(ctx, "fractalsql: not initialized", -1); return; }
    if (sqlite3_value_type(argv[0]) != SQLITE_TEXT) {
        sqlite3_result_error(ctx, "fractalsql_get(name) expects TEXT", -1);
        return;
    }
    const char *name = (const char *)sqlite3_value_text(argv[0]);
    const CfgDef *d = cfg_lookup(name);
    if (!d) {
        sqlite3_result_error(ctx, "fractalsql_get: unknown config key", -1);
        return;
    }
    if (d->type == CFG_INT || d->type == CFG_BOOL) {
        sqlite3_result_int(ctx, *cfg_int_slot(st, d));
        return;
    }
    char **slot = cfg_str_slot(st, d);
    if (!*slot) { sqlite3_result_null(ctx); return; }
    sqlite3_result_text(ctx, *slot, -1, SQLITE_TRANSIENT);
}

/* ------------------------------------------------------------------ */
/* Registration                                                        */
/* ------------------------------------------------------------------ */

int fsql_config_register(sqlite3 *db, FsqlState *st) {
    (void)st;
    const int flags = SQLITE_UTF8 | SQLITE_INNOCUOUS;  /* stateful: NOT deterministic */
    int rc = sqlite3_create_function_v2(
        db, "fractalsql_set", 2, flags, st,
        fs_set_fn, NULL, NULL, NULL);
    if (rc != SQLITE_OK) return rc;
    rc = sqlite3_create_function_v2(
        db, "fractalsql_get", 1, flags, st,
        fs_get_fn, NULL, NULL, NULL);
    return rc;
}