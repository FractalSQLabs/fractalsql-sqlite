/* tests/oom_inject.c
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * LD_PRELOAD fault-injection shim: makes one specific allocation size,
 * made by one specific shared object, return NULL -- exercising this
 * extension's own sqlite3_result_error_nomem() guard sites, which no
 * other gate can reach (nothing in a normal test run ever runs out of
 * memory on its own).
 *
 * Why size-based, not call-count-based: a naive "fail the Nth malloc"
 * counter is fragile -- it silently breaks (starts failing the wrong
 * call) the moment an unrelated earlier change in this extension adds
 * or removes an allocation ahead of the one under test. Matching on
 * the exact byte count of the allocation under test instead ties the
 * trigger to something the test itself controls directly (its own
 * input size, e.g. a vector dimension), not to how many mallocs
 * happen to run first.
 *
 * Why module-scoped, not global: this process is the sqlite3 CLI
 * itself, and SQLite's own default allocator calls the C library's
 * malloc() directly -- an unscoped "fail the next malloc of size N"
 * would just as happily take out SQLite's own internals the moment
 * their allocation size happens to collide with the target. Every
 * intercepted call is checked with dladdr() against its own return
 * address: only a call whose caller resolves into FSQL_OOM_TARGET_SO
 * is a candidate to fail; everything else (SQLite itself, libc, any
 * other loaded library) always succeeds via the real allocator.
 *
 * Controlled entirely by environment variables, read once and cached
 * (this process's environ never changes after the sqlite3 CLI starts,
 * same reasoning as mock_enterprise_core.c's FSQL_MOCK_ENT_FAIL):
 *   FSQL_OOM_FAIL_SIZE   exact byte size to fail (required; unset or
 *                        empty = shim is a pure passthrough)
 *   FSQL_OOM_TARGET_SO   substring to match against the allocating
 *                        call's own shared object path (required
 *                        alongside FSQL_OOM_FAIL_SIZE)
 *
 * Linux only (dlsym(RTLD_NEXT, ...) + dladdr()). Build:
 *   cc -shared -fPIC -std=c99 tests/oom_inject.c -o <tmp>/oom_inject.so -ldl
 * Use: LD_PRELOAD=<tmp>/oom_inject.so FSQL_OOM_FAIL_SIZE=<n> \
 *      FSQL_OOM_TARGET_SO=fractalsql.so sqlite3 ...
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>

static void *(*real_malloc)(size_t) = NULL;
static void *(*real_calloc)(size_t, size_t) = NULL;
static void *(*real_realloc)(void *, size_t) = NULL;

static long fail_size = -1;        /* -1 = not configured yet */
static int configured = 0;
static char target_so[512];

static void ensure_real(void) {
    if (!real_malloc)  real_malloc  = dlsym(RTLD_NEXT, "malloc");
    if (!real_calloc)  real_calloc  = dlsym(RTLD_NEXT, "calloc");
    if (!real_realloc) real_realloc = dlsym(RTLD_NEXT, "realloc");
}

static void ensure_config(void) {
    if (configured) return;
    configured = 1;
    fail_size = -1;
    target_so[0] = '\0';
    const char *sz = getenv("FSQL_OOM_FAIL_SIZE");
    const char *tgt = getenv("FSQL_OOM_TARGET_SO");
    if (sz && sz[0] && tgt && tgt[0]) {
        fail_size = atol(sz);
        size_t n = strlen(tgt);
        if (n >= sizeof(target_so)) n = sizeof(target_so) - 1;
        memcpy(target_so, tgt, n);
        target_so[n] = '\0';
    }
}

/* Only a call whose own caller lives inside target_so is a candidate
 * to fail -- everything else (SQLite's own allocator, libc, this shim
 * itself) always passes through untouched. */
static int caller_is_target(void *retaddr) {
    Dl_info info;
    if (!dladdr(retaddr, &info) || !info.dli_fname) return 0;
    return strstr(info.dli_fname, target_so) != NULL;
}

void *malloc(size_t n) {
    ensure_real();
    ensure_config();
    if (fail_size >= 0 && (long)n == fail_size &&
        caller_is_target(__builtin_return_address(0)))
        return NULL;
    return real_malloc(n);
}

void *calloc(size_t nmemb, size_t size) {
    ensure_real();
    ensure_config();
    if (fail_size >= 0 && (long)(nmemb * size) == fail_size &&
        caller_is_target(__builtin_return_address(0)))
        return NULL;
    return real_calloc(nmemb, size);
}

void *realloc(void *ptr, size_t n) {
    ensure_real();
    ensure_config();
    if (fail_size >= 0 && (long)n == fail_size &&
        caller_is_target(__builtin_return_address(0)))
        return NULL;
    return real_realloc(ptr, n);
}
