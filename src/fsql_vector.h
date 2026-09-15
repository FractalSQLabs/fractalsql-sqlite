/* src/fsql_vector.h — fractal_vector BLOB convention + vector math.
 *
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * SQLite has no CREATE TYPE, so fractal_vector is a BLOB CONVENTION,
 * not a type: dimension enforcement happens per call (mismatch ->
 * error).
 *
 * Canonical BLOB layout (little-endian dim so the convention is
 * byte-stable across architectures):
 *
 *   uint16  dim         little-endian; 1..32767
 *   uint16  _reserved   always 0 (quantization-mode flag, reserved)
 *   float   x[dim]      contiguous float32 payload
 *
 * Every operator also accepts TEXT input (CSV or bracketed-JSON,
 * e.g. '1.0,0.5,-0.25' or '[1.0,0.5,-0.25]') and coerces to the
 * canonical form on the fly. Results are always canonical BLOBs, so
 * a column built with the constructors round-trips through any
 * SQLite tooling.
 *
 * The actual math delegates to the vendored core's fsql_vector_*
 * module (include/fractalsql_sql.h), the DB-agnostic float4 ops
 * that header added explicitly to serve this type.
 */
#ifndef FSQL_VECTOR_H
#define FSQL_VECTOR_H

#include "fsql_sqlite_internal.h"

/* Register the fractal_vector SQL surface. Returns SQLITE_OK or the
 * first registration failure. */
int fsql_vector_register(sqlite3 *db, FsqlState *st);

/* Decode one vector argument (canonical BLOB, or TEXT CSV/JSON) into
 * a malloc'd float32 scratch buffer. Sets *out_dim (>=1) and returns
 * 0 on success; returns -1 on malformed input / out of range. The
 * caller frees *out_data. Used by fsql_t2s/fsql_agents for cross-modal
 * composition, so it lives outside the static surface. */
int fsql_vec_decode(sqlite3_value *v, float **out_data, int *out_dim);

#endif /* FSQL_VECTOR_H */