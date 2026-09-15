/* tests/windows/evil_nonterminating_plugin_win.c
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * Windows port of tests/evil_nonterminating_plugin.c -- same guard-
 * page technique (a response deliberately NOT NUL-terminated, placed
 * flush against an unmapped page so any over-read faults immediately)
 * via VirtualAlloc/VirtualProtect instead of mmap/mprotect. Same
 * trigger-call mechanism (see the Linux file's header comment) so
 * build_test.ps1 can target either GENERATE (trigger=1, default) or
 * REVIEW (trigger=2) with the same binary.
 *
 * UNVERIFIED ON REAL WINDOWS as of writing -- ported by direct
 * translation of the proven Linux/POSIX logic (mmap -> VirtualAlloc,
 * mprotect(PROT_NONE) -> VirtualProtect(PAGE_NOACCESS)), not run on
 * an actual Windows box. First real run (local or CI) is expected to
 * need at least minor fixes, the same way the Linux gates did before
 * they were proven.
 *
 * Build (via build_test.ps1 -- do not invoke directly):
 *   cl /nologo /MT /LD /DFSQL_STATIC /I<repo>\include ^
 *      tests\windows\evil_nonterminating_plugin_win.c ^
 *      /Fe<out>\evil_nonterminating.dll ^
 *      /link /DEF:tests\windows\fractalsql-test-plugin.def
 */
/* MSVC's CRT-deprecation warnings (fopen/fscanf below) are expected in
 * these fixtures -- silenced at the source, not chased file-by-file. */
#define _CRT_SECURE_NO_WARNINGS

#include "fractalsql_sql.h"

#include <Windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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

/* The guard-page region is intentionally leaked (a couple of pages
 * per call, fine for a short test run) -- VirtualFree would need the
 * base address+size, which we don't thread through the opaque arg.
 * A no-op free_fn is a valid Pattern C deallocator for a plugin that
 * manages its own storage. */
static void
ev_free(void *opaque)
{
    (void) opaque;
}

/* free_fn is called as free_fn(resp) with resp the fsql_ai_response_t*
 * struct itself (fsql_ai_response_free, fractalsql-core/src/fsql.c) --
 * NOT resp->summary. Must cast back and free the buffer, not the
 * struct pointer (caller-stack-allocated in fractalsql.c; free()-ing
 * it directly crashes). See fractalsql.c/mock_reasoning_plugin.c for
 * the same contract on the Linux side. */
static void
ev_free_normal(void *opaque)
{
    fsql_ai_response_t *r = (fsql_ai_response_t *) opaque;
    if (r != NULL && r->summary != NULL)
        free(r->summary);
}

static int call_count = 0;

static int
ev_generate(void *u, const char *p, size_t pl,
            char **response_out, size_t *response_len_out,
            void (**response_free_fn_out)(void *))
{
    (void) u; (void) p; (void) pl;
    call_count++;

    int trigger = 1;
    /* Bare relative filename -- see mock_reasoning_plugin_win.c's
     * comment on MOCK_SQL_FILE for why (an absolute C:\Windows\Temp\...
     * path silently never worked). This gate's own "REVIEW path
     * survived" assertion doesn't actually prove trigger=2 was read
     * correctly either way -- if the read fails, trigger stays at its
     * default of 1 and this ends up re-testing GENERATE's protection
     * a second time, which still "passes" for the wrong reason. Only
     * the GENERATE-path assertion's mock_reasoning_plugin_win.c-driven
     * diagnostics conclusively proved the C:\Windows\Temp\ path broken;
     * fixing this one the same way on the strength of that evidence. */
    FILE *tf = fopen("fractalsql_bt_evil_trigger_call.txt", "r");
    if (tf != NULL)
    {
        if (fscanf(tf, "%d", &trigger) != 1)
            trigger = 1;
        fclose(tf);
    }

    char sql[4096] = "SELECT 1";

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
    SYSTEM_INFO sysInfo;
    GetSystemInfo(&sysInfo);
    DWORD ps = sysInfo.dwPageSize;
    if (len == 0 || (DWORD) len > ps)
        return -1;

    /* Two pages: [data page][guard page]. */
    SIZE_T total = (SIZE_T) ps * 2;
    char  *base  = (char *) VirtualAlloc(NULL, total, MEM_COMMIT | MEM_RESERVE,
                                          PAGE_READWRITE);
    if (base == NULL)
        return -1;
    DWORD oldProtect;
    if (!VirtualProtect(base + ps, ps, PAGE_NOACCESS, &oldProtect))
        return -1;

    /* Place `len` bytes flush against the guard page: buf[len] == the
     * first byte of the PAGE_NOACCESS page. So the buffer is NOT
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
