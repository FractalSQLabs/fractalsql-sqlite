/* tests/evil_nonterminating_plugin.c
 *
 * Adversarial reasoning plugin for the memory-safety evil-test
 * (tests/test_text_to_sql_evil_nonterminating.py). It returns a response
 * whose `summary` is deliberately NOT NUL-terminated and is positioned
 * so that reading byte summary[summary_len] lands on a PROT_NONE guard
 * page -- so ANY read past the length faults immediately (SIGSEGV),
 * rather than silently succeeding off heap slack.
 *
 * This proves the extension honors summary_len and never treats
 * `summary` as a C string. The reasoning ABI supplies summary_len but
 * does NOT promise NUL-termination, and the sovereign tier loads
 * out-of-tree plugins -- so a plugin exactly like this one is a
 * legitimate (if hostile) implementation of the contract. With the
 * length-bounded pnstrdup handling in fractalsql.c, this plugin drives
 * fractal_text_to_sql() to completion; without it, the backend
 * crashes here.
 *
 * The SQL text to return is read from the file named by
 * FSQL_EVIL_SQL_FILE (falls back to "SELECT 1").
 *
 * POSIX-only (mmap/mprotect). Built on the fly by the test with:
 *   cc -shared -fPIC -std=c99 -I<repo>/include \
 *      tests/evil_nonterminating_plugin.c -o <tmp>/evil.so
 */
/* _DEFAULT_SOURCE must come alongside _POSIX_C_SOURCE: on glibc,
 * explicitly defining _POSIX_C_SOURCE suppresses _DEFAULT_SOURCE
 * (feature_test_macros(7)), which is what gates MAP_ANONYMOUS -- a
 * glibc/BSD extension, not strict POSIX. Without it this compiles on
 * some glibc versions by coincidence (e.g. Ubuntu 24.04's host glibc)
 * and fails on others (Debian bookworm's, used by docker/Dockerfile.test).
 * Darwin's libc has the same gating problem with its own macro,
 * _DARWIN_C_SOURCE -- confirmed on real Darwin hardware: _POSIX_C_SOURCE
 * alone hides MAP_ANONYMOUS there too ("use of undeclared identifier"),
 * same failure mode as the glibc case, just needing Darwin's macro
 * instead of glibc's.
 */
#if defined(__APPLE__)
#define _DARWIN_C_SOURCE
#else
#define _DEFAULT_SOURCE
#endif
#define _POSIX_C_SOURCE 200809L

#include "fractalsql_sql.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

static int
ev_format(void *u, const char *q, size_t ql, const char *c, size_t cl,
          const char **prompt_out, size_t *prompt_len_out)
{
    (void) u; (void) q; (void) ql; (void) c; (void) cl;
    static char b[2] = { 'x', '\0' };
    *prompt_out = b;
    *prompt_len_out = 1;
    return 0;
}

/* The response buffer is an mmap region we intentionally leak (a few
 * pages per call, fine for a short test run) -- it cannot be released
 * with libc free(), and munmap would need the base+size which we do not
 * thread through the opaque arg. A no-op free_fn is a valid Pattern C
 * deallocator for a plugin that manages its own storage. */
static void
ev_free(void *opaque)
{
    (void) opaque;
}

/* free_fn is called as free_fn(resp) with resp the fsql_ai_response_t*
 * struct itself (fsql_ai_response_free, fractalsql-core/src/fsql.c) --
 * NOT resp->summary. Must cast back and free the buffer, not the
 * struct pointer (which is caller-stack-allocated in fractalsql.c;
 * free()-ing it directly crashes). Mirrors tests/mock_reasoning_plugin.c's
 * mock_free, which got this right from the start. */
static void
ev_free_normal(void *opaque)
{
    fsql_ai_response_t *r = (fsql_ai_response_t *) opaque;
    if (r != NULL && r->summary != NULL)
        free(r->summary);
}

/* GENERATE and REVIEW are two separate dispatch calls within one
 * fractal_text_to_sql() invocation, going through this same
 * generate() callback. Misbehaving on every call only ever proves the
 * FIRST call site's fix (GENERATE) -- REVIEW's own pnstrdup call site
 * (t2s_run_review, fractalsql.c) never gets reached, since a failing
 * GENERATE never lets the pipeline reach REVIEW. FSQL_EVIL_TRIGGER_CALL
 * (fixed file, defaults to call 1) selects which call misbehaves, so
 * the same binary can target either call site: trigger=1 tests
 * GENERATE (default, existing behavior), trigger=2 tests REVIEW.
 * Every other call returns a normal, safely-owned, NUL-terminated
 * response so the pipeline proceeds normally. */
static int call_count = 0;

static int
ev_generate(void *u, const char *p, size_t pl,
            char **response_out, size_t *response_len_out,
            void (**response_free_fn_out)(void *))
{
    (void) u; (void) p; (void) pl;
    call_count++;

    int trigger = 1;
    FILE *tf = fopen("/tmp/fractalsql_bt_evil_trigger_call.txt", "r");
    if (tf != NULL)
    {
        if (fscanf(tf, "%d", &trigger) != 1)
            trigger = 1;
        fclose(tf);
    }

    char sql[4096] = "SELECT 1";
    const char *path = getenv("FSQL_EVIL_SQL_FILE");
    if (path != NULL)
    {
        FILE *f = fopen(path, "r");
        if (f != NULL)
        {
            size_t n = fread(sql, 1, sizeof(sql) - 1, f);
            sql[n] = '\0';
            /* trim a trailing newline so the returned length is exact */
            while (n > 0 && (sql[n - 1] == '\n' || sql[n - 1] == '\r'))
                sql[--n] = '\0';
            fclose(f);
        }
    }

    if (call_count != trigger)
    {
        /* well-behaved response: normal NUL-terminated heap buffer */
        size_t len = strlen(sql);
        char  *buf = malloc(len + 1);
        if (buf == NULL)
            return -1;
        memcpy(buf, sql, len + 1);
        *response_out          = buf;
        *response_len_out      = len;
        *response_free_fn_out  = ev_free_normal;
        return 0;
    }

    size_t len = strlen(sql);
    long   ps  = sysconf(_SC_PAGESIZE);
    if (ps <= 0 || len == 0 || (size_t) ps < len)
        return -1;

    /* Two pages: [data page][guard page]. */
    size_t total = (size_t) ps * 2;
    char  *base  = mmap(NULL, total, PROT_READ | PROT_WRITE,
                        MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (base == MAP_FAILED)
        return -1;
    if (mprotect(base + ps, (size_t) ps, PROT_NONE) != 0)
        return -1;

    /* Place `len` bytes flush against the guard page: buf[len] == the
     * first byte of the PROT_NONE page. So the buffer is NOT
     * NUL-terminated, and any read of buf[len] or beyond faults. */
    char *buf = base + ps - len;
    memcpy(buf, sql, len);

    *response_out          = buf;
    *response_len_out      = len;
    *response_free_fn_out  = ev_free;
    return 0;
}

int
fsql_reasoning_init(fsql_reasoning_vfs_t *vfs)
{
    vfs->abi_version   = FSQL_REASONING_ABI_VERSION;
    vfs->user_ctx      = NULL;
    vfs->format_prompt = ev_format;
    vfs->generate      = ev_generate;
    return 0;
}
