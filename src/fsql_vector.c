/* src/fsql_vector.c — fractal_vector BLOB convention + vector math.
 *
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * See fsql_vector.h for the BLOB layout and the TEXT-coercion rule.
 * All arithmetic delegates to the vendored core's fsql_vector_* module
 * (available in every tier — pure C99 math, no VFS dependency).
 * Degenerate zero-norm inputs return distance=1.0 / similarity=0.0
 * (the core's documented convention) rather than NaN.
 */

#include <sqlite3ext.h>
SQLITE_EXTENSION_INIT3

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fsql_vector.h"

/* ------------------------------------------------------------------
 * Encode / decode
 * ------------------------------------------------------------------ */

static void le16_put(uint8_t *p, uint16_t v) {
    p[0] = (uint8_t)(v & 0xff);
    p[1] = (uint8_t)(v >> 8);
}

static uint16_t le16_get(const uint8_t *p) {
    return (uint16_t)(p[0] | ((uint16_t)p[1] << 8));
}

/* Canonical BLOB -> malloc'd float32 scratch. Returns 0 on success. */
static int decode_canonical_blob(const uint8_t *bytes, int nbytes,
                                 float **out_data, int *out_dim) {
    if (nbytes < FSQL_VEC_HDRSZ) return -1;
    int dim = le16_get(bytes);
    if (dim < 1 || dim > FSQL_VEC_MAX_DIM) return -1;
    if (le16_get(bytes + 2) != 0) return -1;      /* reserved must be 0 */
    if (nbytes != FSQL_VEC_HDRSZ + dim * 4) return -1;
    float *data = (float *)malloc((size_t)dim * sizeof(float));
    if (!data) return -1;
    memcpy(data, bytes + FSQL_VEC_HDRSZ, (size_t)dim * 4);
    *out_data = data;
    *out_dim = dim;
    return 0;
}

int fsql_vec_decode(sqlite3_value *v, float **out_data, int *out_dim) {
    *out_data = NULL;
    *out_dim = 0;

    int type = sqlite3_value_type(v);
    if (type == SQLITE_BLOB) {
        return decode_canonical_blob((const uint8_t *)sqlite3_value_blob(v),
                                     sqlite3_value_bytes(v),
                                     out_data, out_dim);
    }
    if (type != SQLITE_TEXT) return -1;

    /* TEXT CSV / bracketed-JSON -> doubles -> float32. Uses the shared
     * 4 MiB-capped parser from the entry TU. */
    int slen = sqlite3_value_bytes(v);
    if (slen <= 0 || (size_t)slen > FSQL_MAX_INPUT_BYTES) return -1;
    const char *s = (const char *)sqlite3_value_text(v);

    /* Count elements first (worst case: n commas + 1). */
    int cap = 1;
    for (int i = 0; i < slen; i++)
        if (s[i] == ',') cap++;
    if (cap > FSQL_VEC_MAX_DIM) return -1;

    double *tmp = (double *)malloc((size_t)cap * sizeof(double));
    if (!tmp) return -1;
    int n = fsql_parse_text_vector(s, slen, tmp, cap);
    if (n < 1) { free(tmp); return -1; }

    float *data = (float *)malloc((size_t)n * sizeof(float));
    if (!data) { free(tmp); return -1; }
    for (int i = 0; i < n; i++) data[i] = (float)tmp[i];
    free(tmp);

    *out_data = data;
    *out_dim = n;
    return 0;
}

/* float32 scratch -> canonical BLOB result (SQLite-owned). */
static void result_canonical_blob(sqlite3_context *ctx,
                                  const float *data, int dim) {
    int nbytes = FSQL_VEC_HDRSZ + dim * 4;
    uint8_t *blob = (uint8_t *)sqlite3_malloc(nbytes);
    if (!blob) { sqlite3_result_error_nomem(ctx); return; }
    le16_put(blob, (uint16_t)dim);
    le16_put(blob + 2, 0);
    memcpy(blob + FSQL_VEC_HDRSZ, data, (size_t)dim * 4);
    sqlite3_result_blob(ctx, blob, nbytes, sqlite3_free);
}

static int decode_pair(sqlite3_value *a, sqlite3_value *b,
                       float **pa, int *da, float **pb, int *db) {
    if (fsql_vec_decode(a, pa, da) != 0) return -1;
    if (fsql_vec_decode(b, pb, db) != 0) { free(*pa); *pa = NULL; return -1; }
    if (*da != *db) {
        free(*pa); free(*pb); *pa = NULL; *pb = NULL;
        return -2;                                  /* dim mismatch */
    }
    return 0;
}

/* ------------------------------------------------------------------
 * SQL functions
 * ------------------------------------------------------------------ */

/* fractal_vector(dim) — zero vector with canonical header. */
static void fv_construct_fn(sqlite3_context *ctx, int argc,
                            sqlite3_value **argv) {
    (void)argc;
    if (sqlite3_value_type(argv[0]) == SQLITE_NULL) {
        sqlite3_result_null(ctx); return;
    }
    int dim = sqlite3_value_int(argv[0]);
    if (dim < 1 || dim > FSQL_VEC_MAX_DIM) {
        char buf[96];
        snprintf(buf, sizeof buf,
                 "fractal_vector: dim must be 1..%d, got %d",
                 FSQL_VEC_MAX_DIM, dim);
        sqlite3_result_error(ctx, buf, -1);
        return;
    }
    float *zeros = (float *)calloc((size_t)dim, sizeof(float));
    if (!zeros) { sqlite3_result_error_nomem(ctx); return; }
    result_canonical_blob(ctx, zeros, dim);
    free(zeros);
}

/* fractal_vector_from_text(TEXT) -> canonical BLOB. */
static void fv_from_text_fn(sqlite3_context *ctx, int argc,
                            sqlite3_value **argv) {
    (void)argc;
    float *data = NULL; int dim = 0;
    if (sqlite3_value_type(argv[0]) == SQLITE_NULL) {
        sqlite3_result_null(ctx); return;
    }
    if (fsql_vec_decode(argv[0], &data, &dim) != 0) {
        sqlite3_result_error(ctx,
            "fractal_vector_from_text: malformed vector "
            "(expect CSV/JSON text or canonical BLOB)", -1);
        return;
    }
    result_canonical_blob(ctx, data, dim);
    free(data);
}

/* fractal_vector_to_json(vec) -> TEXT JSON array. */
static void fv_to_json_fn(sqlite3_context *ctx, int argc,
                          sqlite3_value **argv) {
    (void)argc;
    if (sqlite3_value_type(argv[0]) == SQLITE_NULL) {
        sqlite3_result_null(ctx); return;
    }
    float *data = NULL; int dim = 0;
    if (fsql_vec_decode(argv[0], &data, &dim) != 0) {
        sqlite3_result_error(ctx, "fractal_vector_to_json: malformed vector", -1);
        return;
    }
    /* ~32 chars per element is the same worst-case budget the 1.x
     * bridge used for CSV encoding. */
    size_t cap = 16 + (size_t)dim * 32 + 4;
    char *json = (char *)malloc(cap);
    if (!json) { free(data); sqlite3_result_error_nomem(ctx); return; }
    char *p = json + (size_t)snprintf(json, cap, "[");
    for (int i = 0; i < dim; i++) {
        p += (size_t)snprintf(p, (size_t)(json + cap - p), "%s%.9g",
                              i ? "," : "", (double)data[i]);
    }
    snprintf(p, (size_t)(json + cap - p), "]");
    sqlite3_result_text(ctx, json, -1, SQLITE_TRANSIENT);
    free(json);
    free(data);
}

/* fractal_vector_dims(vec) -> INTEGER. */
static void fv_dims_fn(sqlite3_context *ctx, int argc, sqlite3_value **argv) {
    (void)argc;
    if (sqlite3_value_type(argv[0]) == SQLITE_NULL) {
        sqlite3_result_null(ctx); return;
    }
    float *data = NULL; int dim = 0;
    if (fsql_vec_decode(argv[0], &data, &dim) != 0) {
        sqlite3_result_error(ctx, "fractal_vector_dims: malformed vector", -1);
        return;
    }
    free(data);
    sqlite3_result_int(ctx, dim);
}

/* Binary scalar-result operators via the core's fsql_vector_*. */
static void fv_binary_real_fn(sqlite3_context *ctx, int argc,
                              sqlite3_value **argv) {
    (void)argc;
    if (sqlite3_value_type(argv[0]) == SQLITE_NULL ||
        sqlite3_value_type(argv[1]) == SQLITE_NULL) {
        sqlite3_result_null(ctx); return;
    }
    float *pa = NULL, *pb = NULL; int da = 0, db = 0;
    int drc = decode_pair(argv[0], argv[1], &pa, &da, &pb, &db);
    if (drc == -2) {
        sqlite3_result_error(ctx, "fractalsql: vector dim mismatch", -1);
        return;
    }
    if (drc != 0) {
        sqlite3_result_error(ctx, "fractalsql: malformed vector", -1);
        return;
    }

    float out = 0.0f;
    sqlite3_destructor_type unused = SQLITE_TRANSIENT; (void)unused;

    /* Dispatch on the registered user-data tag. */
    int op = (int)(intptr_t)sqlite3_user_data(ctx);
    int rc = FSQL_ERR_INVALID;
    switch (op) {
    case 1: rc = fsql_vector_l2(pa, pb, (size_t)da, &out);          break;
    case 2: rc = fsql_vector_l2_sq(pa, pb, (size_t)da, &out);       break;
    case 3: rc = fsql_vector_cosine_distance(pa, pb, (size_t)da, &out); break;
    case 4: rc = fsql_vector_cosine_similarity(pa, pb, (size_t)da, &out); break;
    case 5: rc = fsql_vector_dot(pa, pb, (size_t)da, &out);
            if (rc == FSQL_OK) out = -out;   /* negative inner product */
            break;
    default: break;
    }
    free(pa); free(pb);
    if (rc != FSQL_OK) {
        sqlite3_result_error(ctx, "fractalsql: vector op failed", -1);
        return;
    }
    sqlite3_result_double(ctx, (double)out);
}

/* Binary vector-result operators (add/sub). */
static void fv_binary_vec_fn(sqlite3_context *ctx, int argc,
                             sqlite3_value **argv) {
    (void)argc;
    if (sqlite3_value_type(argv[0]) == SQLITE_NULL ||
        sqlite3_value_type(argv[1]) == SQLITE_NULL) {
        sqlite3_result_null(ctx); return;
    }
    float *pa = NULL, *pb = NULL; int da = 0, db = 0;
    int drc = decode_pair(argv[0], argv[1], &pa, &da, &pb, &db);
    if (drc == -2) {
        sqlite3_result_error(ctx, "fractalsql: vector dim mismatch", -1);
        return;
    }
    if (drc != 0) {
        sqlite3_result_error(ctx, "fractalsql: malformed vector", -1);
        return;
    }
    float *out = (float *)malloc((size_t)da * sizeof(float));
    if (!out) { free(pa); free(pb); sqlite3_result_error_nomem(ctx); return; }

    int op = (int)(intptr_t)sqlite3_user_data(ctx);
    int rc = (op == 1) ? fsql_vector_add(pa, pb, (size_t)da, out)
                       : fsql_vector_sub(pa, pb, (size_t)da, out);
    free(pa); free(pb);
    if (rc != FSQL_OK) { free(out);
        sqlite3_result_error(ctx, "fractalsql: vector op failed", -1); return; }
    result_canonical_blob(ctx, out, da);
    free(out);
}

/* fractal_vector_scale(vec, scalar). */
static void fv_scale_fn(sqlite3_context *ctx, int argc, sqlite3_value **argv) {
    (void)argc;
    if (sqlite3_value_type(argv[0]) == SQLITE_NULL ||
        sqlite3_value_type(argv[1]) == SQLITE_NULL) {
        sqlite3_result_null(ctx); return;
    }
    float *pa = NULL; int da = 0;
    if (fsql_vec_decode(argv[0], &pa, &da) != 0) {
        sqlite3_result_error(ctx, "fractalsql: malformed vector", -1);
        return;
    }
    float scalar = (float)sqlite3_value_double(argv[1]);
    float *out = (float *)malloc((size_t)da * sizeof(float));
    if (!out) { free(pa); sqlite3_result_error_nomem(ctx); return; }
    int rc = fsql_vector_scale(pa, (size_t)da, scalar, out);
    free(pa);
    if (rc != FSQL_OK) { free(out);
        sqlite3_result_error(ctx, "fractalsql: vector op failed", -1); return; }
    result_canonical_blob(ctx, out, da);
    free(out);
}

/* fractal_vector_norm(vec) -> REAL. */
static void fv_norm_fn(sqlite3_context *ctx, int argc, sqlite3_value **argv) {
    (void)argc;
    if (sqlite3_value_type(argv[0]) == SQLITE_NULL) {
        sqlite3_result_null(ctx); return;
    }
    float *pa = NULL; int da = 0;
    if (fsql_vec_decode(argv[0], &pa, &da) != 0) {
        sqlite3_result_error(ctx, "fractalsql: malformed vector", -1);
        return;
    }
    float out = 0.0f;
    int rc = fsql_vector_norm(pa, (size_t)da, &out);
    free(pa);
    if (rc != FSQL_OK) {
        sqlite3_result_error(ctx, "fractalsql: vector op failed", -1);
        return;
    }
    sqlite3_result_double(ctx, (double)out);
}

/* fractal_vector_normalize(vec) -> canonical BLOB. */
static void fv_normalize_fn(sqlite3_context *ctx, int argc,
                            sqlite3_value **argv) {
    (void)argc;
    if (sqlite3_value_type(argv[0]) == SQLITE_NULL) {
        sqlite3_result_null(ctx); return;
    }
    float *pa = NULL; int da = 0;
    if (fsql_vec_decode(argv[0], &pa, &da) != 0) {
        sqlite3_result_error(ctx, "fractalsql: malformed vector", -1);
        return;
    }
    float *out = (float *)malloc((size_t)da * sizeof(float));
    if (!out) { free(pa); sqlite3_result_error_nomem(ctx); return; }
    int rc = fsql_vector_normalize(pa, (size_t)da, out);
    free(pa);
    if (rc != FSQL_OK) { free(out);
        sqlite3_result_error(ctx, "fractalsql: vector op failed", -1); return; }
    result_canonical_blob(ctx, out, da);
    free(out);
}

/* ------------------------------------------------------------------
 * Registration
 * ------------------------------------------------------------------ */

/* Pure math — DETERMINISTIC | INNOCUOUS everywhere. user_data carries
 * a small int tag for the shared-binary dispatchers. */
int fsql_vector_register(sqlite3 *db, FsqlState *st) {
    (void)st;
    static const int flags = SQLITE_UTF8 | SQLITE_DETERMINISTIC
                           | SQLITE_INNOCUOUS;
    int rc;

    struct { const char *name; int narg; void *fn; intptr_t tag; } scalars[] = {
        { "fractal_vector_l2_distance",           2, (void *)fv_binary_real_fn, 1 },
        { "fractal_vector_l2_squared",            2, (void *)fv_binary_real_fn, 2 },
        { "fractal_vector_cosine_distance",       2, (void *)fv_binary_real_fn, 3 },
        { "fractal_vector_cosine_similarity",     2, (void *)fv_binary_real_fn, 4 },
        { "fractal_vector_negative_inner_product",2, (void *)fv_binary_real_fn, 5 },
    };
    for (size_t i = 0; i < sizeof(scalars)/sizeof(scalars[0]); i++) {
        rc = sqlite3_create_function_v2(db, scalars[i].name, scalars[i].narg,
                                        flags, (void *)scalars[i].tag,
                                        (void (*)(sqlite3_context*, int,
                                                  sqlite3_value**))scalars[i].fn,
                                        NULL, NULL, NULL);
        if (rc != SQLITE_OK) return rc;
    }

    struct { const char *name; int narg; void *fn; intptr_t tag; } vecs[] = {
        { "fractal_vector_add",  2, (void *)fv_binary_vec_fn, 1 },
        { "fractal_vector_sub",  2, (void *)fv_binary_vec_fn, 2 },
    };
    for (size_t i = 0; i < sizeof(vecs)/sizeof(vecs[0]); i++) {
        rc = sqlite3_create_function_v2(db, vecs[i].name, vecs[i].narg,
                                        flags, (void *)vecs[i].tag,
                                        (void (*)(sqlite3_context*, int,
                                                  sqlite3_value**))vecs[i].fn,
                                        NULL, NULL, NULL);
        if (rc != SQLITE_OK) return rc;
    }

    struct { const char *name; int narg; void *fn; } plain[] = {
        { "fractal_vector",            1, (void *)fv_construct_fn  },
        { "fractal_vector_from_text",  1, (void *)fv_from_text_fn  },
        { "fractal_vector_to_json",    1, (void *)fv_to_json_fn    },
        { "fractal_vector_dims",       1, (void *)fv_dims_fn       },
        { "fractal_vector_scale",      2, (void *)fv_scale_fn      },
        { "fractal_vector_norm",       1, (void *)fv_norm_fn       },
        { "fractal_vector_normalize",  1, (void *)fv_normalize_fn  },
    };
    for (size_t i = 0; i < sizeof(plain)/sizeof(plain[0]); i++) {
        rc = sqlite3_create_function_v2(db, plain[i].name, plain[i].narg,
                                        flags, NULL,
                                        (void (*)(sqlite3_context*, int,
                                                  sqlite3_value**))plain[i].fn,
                                        NULL, NULL, NULL);
        if (rc != SQLITE_OK) return rc;
    }

    return SQLITE_OK;
}