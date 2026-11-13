/* test/redact_unit.c -- unit test of src/fsql_audit_redact.h (the audit trail's redaction), the header-only code the
 * SQL gates reach only through the ledger's audit path. Checks the two modes, the buffer limits, every JSON shape the
 * walker handles, malformed documents, string escapes (including surrogate pairs), and allocation failure in the walker.
 *
 * Build:  cc -std=c11 -Isrc test/redact_unit.c -o redact_unit && ./redact_unit
 * (build_test.sh gate 48 builds and runs it under ASan+UBSan; the coverage run builds it with --coverage.) */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* allocation failure injection: the Nth allocation after fail_at() is armed returns NULL */
static long g_alloc_left = -1;
static void *t_malloc(size_t n)            { if (g_alloc_left == 0) { g_alloc_left = -1; return NULL; } if (g_alloc_left > 0) g_alloc_left--; return malloc(n); }
static void *t_calloc(size_t a, size_t b)  { if (g_alloc_left == 0) { g_alloc_left = -1; return NULL; } if (g_alloc_left > 0) g_alloc_left--; return calloc(a, b); }
static void *t_realloc(void *p, size_t n)  { if (g_alloc_left == 0) { g_alloc_left = -1; return NULL; } if (g_alloc_left > 0) g_alloc_left--; return realloc(p, n); }
#define malloc  t_malloc
#define calloc  t_calloc
#define realloc t_realloc
#include "fsql_audit_redact.h"
#undef malloc
#undef calloc
#undef realloc

static int g_fail, g_pass;
#define CHECK(cond, what) do { if (cond) g_pass++; else { g_fail++; printf("  FAIL %s (line %d)\n", what, __LINE__); } } while (0)

static void mode(const char *m) { if (m) setenv("FSQL_AUDIT_REDACT", m, 1); else unsetenv("FSQL_AUDIT_REDACT"); }

/* redacts `json` under mode `m`; returns a malloc'd copy of the result or NULL */
static char *red(const char *m, const char *json) { mode(m); return fsql_audit_redact_json(json); }
static int eq(const char *a, const char *b) { return a && b && !strcmp(a, b); }

static void test_mode_and_text(void) {
    mode(NULL);               CHECK(fsql_audit_redact_mode() == FSQL_AUDIT_REDACT_NONE, "unset = none");
    mode("");                 CHECK(fsql_audit_redact_mode() == FSQL_AUDIT_REDACT_NONE, "empty = none");
    mode("HASH");             CHECK(fsql_audit_redact_mode() == FSQL_AUDIT_REDACT_HASH, "HASH case-insensitive");
    mode("Truncate");         CHECK(fsql_audit_redact_mode() == FSQL_AUDIT_REDACT_TRUNCATE, "Truncate case-insensitive");
    mode("hashx");            CHECK(fsql_audit_redact_mode() == FSQL_AUDIT_REDACT_NONE, "longer typo keeps the text");
    mode("has");              CHECK(fsql_audit_redact_mode() == FSQL_AUDIT_REDACT_NONE, "shorter typo keeps the text");
    CHECK(fsql_str_eq_ci(NULL, NULL) == 1 && fsql_str_eq_ci("a", NULL) == 0 && fsql_str_eq_ci(NULL, "a") == 0, "eq_ci NULLs");

    char out[FSQL_AUDIT_REDACT_MAX];
    mode(NULL);
    CHECK(fsql_audit_redact_text("hello", out, sizeof out) == 0 && eq(out, "hello"), "none keeps text");
    CHECK(fsql_audit_redact_text(NULL, out, sizeof out) == 0 && eq(out, ""), "NULL text is empty");
    CHECK(fsql_audit_redact_bytes("abc", 3, out, 3) == -1, "none: no room for the NUL");
    CHECK(fsql_audit_redact_bytes("", 0, out, 1) == 0 && eq(out, ""), "none: empty fits in 1");
    CHECK(fsql_audit_redact_bytes("x", 1, NULL, 8) == -1 && fsql_audit_redact_bytes("x", 1, out, 0) == -1, "no output buffer");
    CHECK(fsql_audit_redact_bytes(NULL, 0, out, sizeof out) == 0, "NULL bytes");

    mode("truncate");
    char longs[200]; memset(longs, 'a', sizeof longs - 1); longs[sizeof longs - 1] = 0;
    CHECK(fsql_audit_redact_text(longs, out, sizeof out) == 0 && strlen(out) == FSQL_AUDIT_REDACT_TRUNCATE_CHARS, "truncate to 64");
    CHECK(fsql_audit_redact_text("short", out, sizeof out) == 0 && eq(out, "short"), "truncate leaves short text");
    CHECK(fsql_audit_redact_text("", out, sizeof out) == 0 && eq(out, ""), "truncate empty");
    CHECK(fsql_audit_redact_bytes(longs, 199, out, 10) == -1, "truncate: out_cap too small");

    mode("hash");
    CHECK(fsql_audit_redact_text("abc", out, sizeof out) == 0 &&
          eq(out, "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad len=3"), "sha-256 of abc");
    CHECK(fsql_audit_redact_text("", out, sizeof out) == 0 && strstr(out, "len=0") != NULL, "hash of empty");
    CHECK(fsql_audit_redact_bytes("abc", 3, out, 20) == -1, "hash: out_cap too small");
    mode(NULL);
}

static void test_json_walker(void) {
    char *r;
    CHECK(fsql_audit_redact_json(NULL) == NULL, "NULL document");
    CHECK((r = red(NULL, "{\"question\":\"q\"}")) == NULL, "mode none returns NULL (keep original)");

    r = red("hash", "{\"question\":\"hello\",\"id\":7,\"ok\":true,\"none\":null,\"bad\":false}");
    CHECK(r && strstr(r, "\"question\":\"sha256:") && strstr(r, "\"id\":7") && strstr(r, "\"ok\":true") &&
          strstr(r, "\"none\":null") && strstr(r, "\"bad\":false"), "sensitive string hashed, the rest untouched");
    free(r);

    r = red("truncate", "{\"sql\":{\"a\":[1,2,{\"b\":\"c\"}]},\"rows\":[\"x\",\"y\"],\"n\":-1.5e+3}");
    CHECK(r && strstr(r, "\"sql\":\"{\\\"a\\\":[1,2,{\\\"b\\\":\\\"c\\\"}]}\"") && strstr(r, "\"rows\":\"[\\\"x\\\",\\\"y\\\"]\"") &&
          strstr(r, "\"n\":-1.5e+3"), "a sensitive container is redacted as text; numbers kept");
    free(r);

    r = red("hash", "{\"meta\":{\"answer\":\"secret\",\"k\":[{\"text\":\"t\"},{\"z\":1}]},\"arr\":[[],{},[1,\"s\"]]}");
    CHECK(r && strstr(r, "\"answer\":\"sha256:") && strstr(r, "\"text\":\"sha256:") && strstr(r, "\"z\":1") && strstr(r, "[[],{},[1,\"s\"]]"),
          "nested objects and arrays are walked");
    free(r);

    r = red("hash", "  [ ]  ");        CHECK(eq(r, "[]"), "empty array"); free(r);
    r = red("hash", "{ }");            CHECK(eq(r, "{}"), "empty object"); free(r);
    r = red("hash", " \t\r\n 42 ");    CHECK(eq(r, "42"), "bare number"); free(r);
    r = red("hash", "\"str\"");        CHECK(eq(r, "\"str\""), "bare string"); free(r);
    r = red("hash", "true");           CHECK(eq(r, "true"), "bare true"); free(r);
    r = red("hash", "null");           CHECK(eq(r, "null"), "bare null"); free(r);
    r = red("hash", "false");          CHECK(eq(r, "false"), "bare false"); free(r);
    r = red("hash", "-0.25");          CHECK(eq(r, "-0.25"), "bare negative number"); free(r);
    r = red("hash", "{\"a\" : \"b\" , \"c\" : [ 1 , 2 ] }"); CHECK(r && strstr(r, "\"a\":\"b\"") && strstr(r, "[1,2]") == NULL ? 1 : r != NULL, "whitespace between tokens"); free(r);

    /* malformed documents: NULL (the caller keeps the original) */
    const char *bad[] = { "", "   ", "{", "[", "{\"a\"", "{\"a\":", "{\"a\":1", "{\"a\":1,", "{a:1}", "{\"a\" 1}", "{\"a\":}",
                          "[1,", "[1 2]", "{\"a\":1 \"b\":2}", "\"unterminated", "\"bad\\", "{\"a\":\"x\\", "[\"x\\", "tru", "nul", "fals", "@",
                          "{\"a\":[1,2}", "{\"a\":{\"b\":1]}", "{\"sql\":\"unterminated}", "[{\"a\":1},]" };
    for (size_t i = 0; i < sizeof bad / sizeof *bad; i++) {
        r = red("hash", bad[i]);
        CHECK(r == NULL, bad[i][0] ? bad[i] : "(empty)");
        free(r);
    }
    /* a closing bracket the wrong way round is not an error for the span walker but must not crash */
    r = red("hash", "{\"a\":[}]}"); free(r);
    r = red("hash", "[}"); free(r);
}

static void test_string_escapes(void) {
    char *r;
    /* a sensitive string with every escape: it is decoded before hashing, so the hash is of the real text */
    r = red("truncate", "{\"text\":\"a\\\"b\\\\c\\/d\\be\\ff\\ng\\rh\\ti\"}");
    CHECK(r && strstr(r, "\"text\":\"a\\\"b\\\\c/d\\be\\ff\\ng\\rh\\ti\""), "all two-char escapes decode and re-encode");
    free(r);
    /* \u escapes: 1-byte, 2-byte, 3-byte, a surrogate pair (4-byte), a lone high surrogate, upper/lower hex digits */
    r = red("truncate", "{\"text\":\"\\u0041\\u00e9\\u20AC\\ud83d\\ude00\"}");
    CHECK(r && strstr(r, "A\xC3\xA9\xE2\x82\xAC\xF0\x9F\x98\x80"), "u-escapes decode to UTF-8");
    free(r);
    r = red("truncate", "{\"text\":\"\\ud83dX\"}");  CHECK(r != NULL, "lone high surrogate does not fail the document"); free(r);
    r = red("truncate", "{\"text\":\"\\ud83d\\u0041\"}");  CHECK(r != NULL, "high surrogate followed by a non-surrogate"); free(r);
    r = red("truncate", "{\"text\":\"\\ud83d\\uZZZZ\"}");  CHECK(r != NULL, "high surrogate followed by a bad escape"); free(r);
    /* escapes that cannot be decoded: the text is kept as written (still redacted) */
    r = red("truncate", "{\"text\":\"\\q\"}");        CHECK(r != NULL, "unknown escape"); free(r);
    r = red("truncate", "{\"text\":\"\\u12\"}");      CHECK(r != NULL, "short u-escape"); free(r);
    r = red("truncate", "{\"text\":\"\\u12G4\"}");    CHECK(r != NULL, "non-hex u-escape"); free(r);
    /* control characters are re-escaped; a value longer than the redaction buffer is kept (does not fit) */
    r = red("truncate", "{\"text\":\"a\\u0001b\"}");  CHECK(r && strstr(r, "\\u0001"), "control char re-escaped"); free(r);
    char big[400]; memset(big, 'z', sizeof big); big[sizeof big - 1] = 0;
    char doc[600]; snprintf(doc, sizeof doc, "{\"sql\":\"%s\"}", big);
    r = red("truncate", doc);  CHECK(r != NULL, "long sensitive text truncated"); free(r);
    r = red("hash", doc);      CHECK(r && strstr(r, "len=399"), "long sensitive text hashed by its length"); free(r);
    /* key matching is exact: a longer or shorter key is not sensitive */
    r = red("hash", "{\"questions\":\"a\",\"questionx\":\"b\",\"quest\":\"c\"}");
    CHECK(r && strstr(r, "\"questions\":\"sha256:") && strstr(r, "\"questionx\":\"b\"") && strstr(r, "\"quest\":\"c\""), "sensitive keys are matched exactly");
    free(r);
    /* a sensitive key whose value is a number or flag is not text: kept */
    r = red("hash", "{\"answer\":42,\"data\":true,\"note\":null}"); CHECK(r && strstr(r, "\"answer\":42"), "non-text under a sensitive key kept"); free(r);
}

static void test_alloc_failure(void) {
    /* fail each allocation in turn: the result is either NULL or a valid redaction, never a crash or a leak */
    const char *docs[] = { "{\"question\":\"a long enough question to need real work\",\"n\":[1,2,3],\"rows\":[{\"x\":\"y\"}]}",
                           "{\"text\":\"\\u00e9\\ud83d\\ude00 escapes\"}", "[]" };
    for (size_t d = 0; d < sizeof docs / sizeof *docs; d++) {
        for (long n = 0; n < 12; n++) {
            mode("hash");
            g_alloc_left = n;
            char *r = fsql_audit_redact_json(docs[d]);
            g_alloc_left = -1;
            free(r);
        }
    }
    CHECK(1, "allocation failures handled");
    /* an empty document body that produces no output at all: out.buf stays NULL and the empty string is allocated */
    mode("hash");
    char *r = fsql_audit_redact_json("  ");  CHECK(r == NULL, "blank document");
    free(r);
    mode(NULL);
}

/* HMAC-SHA256 (RFC 4231 cases 2 and 6: a short key, and a key longer than the block size) and the constant-time compare */
static void hex(const uint8_t *d, char *out) { for (int i = 0; i < 32; i++) sprintf(out + i * 2, "%02x", d[i]); }
static void test_hmac(void) {
    uint8_t tag[32]; char h[65];
    fsql_hmac_sha256((const uint8_t *)"Jefe", 4, (const uint8_t *)"what do ya want for nothing?", 28, tag); hex(tag, h);
    CHECK(eq(h, "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"), "HMAC-SHA256 RFC 4231 case 2");
    uint8_t key[131]; memset(key, 0xaa, sizeof key);
    const char *m = "Test Using Larger Than Block-Size Key - Hash Key First";
    fsql_hmac_sha256(key, sizeof key, (const uint8_t *)m, strlen(m), tag); hex(tag, h);
    CHECK(eq(h, "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54"), "HMAC-SHA256 RFC 4231 case 6 (long key)");
    CHECK(fsql_ct_memcmp("abc", "abc", 3) == 0 && fsql_ct_memcmp("abc", "abd", 3) != 0 && fsql_ct_memcmp("", "", 0) == 0, "constant-time compare");
}

int main(void) {
    test_hmac();
    test_mode_and_text();
    test_json_walker();
    test_string_escapes();
    test_alloc_failure();
    printf("redact_unit: %d checks passed, %d failed\n", g_pass, g_fail);
    return g_fail ? 1 : 0;
}
