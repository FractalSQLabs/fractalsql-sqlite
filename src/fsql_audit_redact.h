/* src/fsql_audit_redact.h: redaction of audit-trail text.
 *
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * The audit chain records what the agents were asked and what they
 * produced. That text can carry customer data -- a question quoting a
 * row, generated SQL with literals in it, an analysis paragraph, the
 * result rows themselves -- so an operator can ask for a fingerprint of
 * the text instead of the text:
 *
 *   FSQL_AUDIT_REDACT=none       (default) store the text as it is
 *   FSQL_AUDIT_REDACT=hash       store "sha256:<hex> len=<bytes>"
 *   FSQL_AUDIT_REDACT=truncate   store the first 64 characters
 *
 * Redaction applies to the copy that goes into the audit chain. The
 * values handed back to the caller are never redacted: the agent still
 * answers with the real question, the real SQL and the real analysis;
 * only what is persisted changes.
 *
 * Header-only, like the vendored crypto helpers next to it, so any
 * translation unit can use it without a build change.
 */
#ifndef FRACTALSQL_AUDIT_REDACT_H
#define FRACTALSQL_AUDIT_REDACT_H

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fsql_hmac.h"

#define FSQL_AUDIT_REDACT_NONE     0
#define FSQL_AUDIT_REDACT_HASH     1
#define FSQL_AUDIT_REDACT_TRUNCATE 2

/* Longest redacted value: "sha256:" + 64 hex digits + " len=" + a
 * 20-digit count. Truncation is capped at 64 characters, so the
 * longest output is the hash form. */
#define FSQL_AUDIT_REDACT_MAX 128

/* Longest text kept by the truncate mode. */
#define FSQL_AUDIT_REDACT_TRUNCATE_CHARS 64

static int fsql_str_eq_ci(const char *a, const char *b) {
    if (!a || !b) return a == b;
    for (; *a && *b; a++, b++) {
        int ca = (unsigned char)*a, cb = (unsigned char)*b;
        if (ca >= 'A' && ca <= 'Z') ca += 'a' - 'A';
        if (cb >= 'A' && cb <= 'Z') cb += 'a' - 'A';
        if (ca != cb) return 0;
    }
    return *a == '\0' && *b == '\0';
}

/* The configured mode. An unset or unrecognized value means "none":
 * a typo must not silently drop audit text, it must keep it. */
static int fsql_audit_redact_mode(void) {
    const char *e = getenv("FSQL_AUDIT_REDACT");
    if (!e || !*e) return FSQL_AUDIT_REDACT_NONE;
    if (fsql_str_eq_ci(e, "hash"))     return FSQL_AUDIT_REDACT_HASH;
    if (fsql_str_eq_ci(e, "truncate")) return FSQL_AUDIT_REDACT_TRUNCATE;
    return FSQL_AUDIT_REDACT_NONE;
}

/* Redact `len` bytes of `in` into `out`.
 *
 * Returns 0 on success, -1 when the result does not fit in out_cap
 * bytes (the caller then keeps the text unredacted rather than losing
 * the audit record). */
static int fsql_audit_redact_bytes(const char *in, size_t len, char *out,
                                   size_t out_cap) {
    if (!out || out_cap == 0) return -1;
    const char *s = in ? in : "";
    int mode = fsql_audit_redact_mode();

    if (mode == FSQL_AUDIT_REDACT_TRUNCATE) {
        size_t keep = len > FSQL_AUDIT_REDACT_TRUNCATE_CHARS
                        ? (size_t)FSQL_AUDIT_REDACT_TRUNCATE_CHARS : len;
        if (out_cap < keep + 1) return -1;
        if (keep) memcpy(out, s, keep);
        out[keep] = '\0';
        return 0;
    }
    if (mode == FSQL_AUDIT_REDACT_HASH) {
        uint8_t digest[32];
        char hex[65];
        fsql_sha256((const uint8_t *)s, len, digest);
        for (int i = 0; i < 32; i++)
            snprintf(hex + (size_t)i * 2, 3, "%02x", digest[i]);
        int n = snprintf(out, out_cap, "sha256:%s len=%llu", hex,
                         (unsigned long long)len);
        if (n < 0 || (size_t)n >= out_cap) return -1;
        return 0;
    }
    if (out_cap < len + 1) return -1;
    if (len) memcpy(out, s, len);
    out[len] = '\0';
    return 0;
}

/* Redact a NUL-terminated string into `out`. */
static int fsql_audit_redact_text(const char *in, char *out, size_t out_cap) {
    const char *s = in ? in : "";
    return fsql_audit_redact_bytes(s, strlen(s), out, out_cap);
}

/* ------------------------------------------------------------------ */
/* Redacting a JSON document by key name                                */
/* ------------------------------------------------------------------ */

/* The audit entries are JSON documents, so redaction works on the
 * document: the string (or object, or array) under a sensitive key is
 * replaced by the redacted form of its text, and everything else --
 * identifiers, counts, statuses, the envelope's own fields -- is left
 * exactly as it was. Nested documents are walked, so a sensitive key
 * inside a nested object is redacted too.
 *
 * The sensitive keys are the ones that carry free text or row data:
 * the question an agent was asked, the SQL it generated, the analysis
 * it wrote, the reason it gave, and the rows it read.
 */

typedef struct {
    char  *buf;
    size_t len;
    size_t cap;
    int    oom;
} fsql_audit_buf;

static void fsql_ab_putn(fsql_audit_buf *b, const char *s, size_t n) {
    if (b->oom) return;
    if (b->len + n + 1 > b->cap) {
        size_t cap = b->cap ? b->cap : 256;
        while (cap < b->len + n + 1) cap *= 2;
        char *nb = (char *)realloc(b->buf, cap);
        if (!nb) { b->oom = 1; return; }
        b->buf = nb;
        b->cap = cap;
    }
    if (n) memcpy(b->buf + b->len, s, n);
    b->len += n;
    b->buf[b->len] = '\0';
}

static void fsql_ab_puts(fsql_audit_buf *b, const char *s) {
    fsql_ab_putn(b, s, strlen(s));
}

static void fsql_ab_putc(fsql_audit_buf *b, char c) {
    fsql_ab_putn(b, &c, 1);
}

static const char *fsql_json_skip_ws(const char *p) {
    while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p++;
    return p;
}

/* The content of the string starting at p (without its quotes) and the
 * position past the closing quote. NULL when p is not a string or the
 * string is unterminated. */
static const char *fsql_json_string_span(const char *p, const char **start,
                                         size_t *len) {
    if (*p != '"') return NULL;
    p++;
    const char *s = p;
    while (*p) {
        if (*p == '\\') {
            if (!p[1]) return NULL;
            p += 2;
            continue;
        }
        if (*p == '"') {
            *start = s;
            *len = (size_t)(p - s);
            return p + 1;
        }
        p++;
    }
    return NULL;
}

/* The raw span of the value starting at p: the first character of the
 * value and the position past it. For a string the span includes the
 * quotes. NULL when the value is malformed. */
static const char *fsql_json_value_span(const char *p, const char **start,
                                        size_t *len, int *is_string) {
    p = fsql_json_skip_ws(p);
    *start = p;
    if (*p == '"') {
        const char *s;
        size_t l;
        const char *end = fsql_json_string_span(p, &s, &l);
        if (!end) return NULL;
        *len = (size_t)(end - p);
        *is_string = 1;
        return end;
    }
    if (*p == '{' || *p == '[') {
        char open = *p;
        char close = (open == '{') ? '}' : ']';
        int depth = 0;
        while (*p) {
            if (*p == '"') {
                const char *s;
                size_t l;
                const char *end = fsql_json_string_span(p, &s, &l);
                if (!end) return NULL;
                p = end;
                continue;
            }
            if (*p == open) depth++;
            else if (*p == close) {
                depth--;
                if (depth == 0) {
                    *len = (size_t)(p + 1 - *start);
                    *is_string = 0;
                    return p + 1;
                }
            }
            p++;
        }
        return NULL;
    }
    if (!strncmp(p, "true", 4) || !strncmp(p, "null", 4)) {
        *len = 4;
        *is_string = 0;
        return p + 4;
    }
    if (!strncmp(p, "false", 5)) {
        *len = 5;
        *is_string = 0;
        return p + 5;
    }
    if (*p == '-' || (*p >= '0' && *p <= '9')) {
        const char *q = p;
        while (*q && (strchr("+-.eE", *q) || (*q >= '0' && *q <= '9'))) q++;
        *len = (size_t)(q - p);
        *is_string = 0;
        return q;
    }
    return NULL;
}

static int fsql_json_key_is_sensitive(const char *key, size_t klen) {
    static const char *const keys[] = {
        "question", "questions", "generated_sql", "sql", "analysis",
        "reason", "rationale", "explanation", "answer", "result",
        "results", "result_json", "rows", "row", "value", "text",
        "note", "notes", "summary", "content", "prompt", "context",
        "objective", "payload", "data", NULL
    };
    for (int i = 0; keys[i]; i++) {
        if (strlen(keys[i]) == klen && memcmp(keys[i], key, klen) == 0)
            return 1;
    }
    return 0;
}

/* Append `s` as a JSON string, escaping what has to be escaped. */
static void fsql_ab_put_json_string(fsql_audit_buf *out, const char *s,
                                    size_t len) {
    fsql_ab_putc(out, '"');
    for (size_t i = 0; i < len; i++) {
        unsigned char c = (unsigned char)s[i];
        switch (c) {
        case '"':  fsql_ab_puts(out, "\\\""); break;
        case '\\': fsql_ab_puts(out, "\\\\"); break;
        case '\b': fsql_ab_puts(out, "\\b");  break;
        case '\f': fsql_ab_puts(out, "\\f");  break;
        case '\n': fsql_ab_puts(out, "\\n");  break;
        case '\r': fsql_ab_puts(out, "\\r");  break;
        case '\t': fsql_ab_puts(out, "\\t");  break;
        default:
            if (c < 0x20) {
                char esc[8];
                snprintf(esc, sizeof esc, "\\u%04x", c);
                fsql_ab_puts(out, esc);
            } else {
                fsql_ab_putc(out, (char)c);
            }
        }
    }
    fsql_ab_putc(out, '"');
}

/* The text of a JSON string with its escapes resolved. Returns a
 * newly allocated string, or NULL when the text is malformed or the
 * allocation failed. */
static char *fsql_json_unescape_dup(const char *src, size_t len) {
    char *out = (char *)malloc(len + 1);
    if (!out) return NULL;
    size_t o = 0;
    for (size_t i = 0; i < len; ) {
        char c = src[i];
        if (c != '\\') { out[o++] = c; i++; continue; }
        if (i + 1 >= len) { free(out); return NULL; }
        char e = src[++i];
        i++;
        switch (e) {
        case '"':  out[o++] = '"';  break;
        case '\\': out[o++] = '\\'; break;
        case '/':  out[o++] = '/';  break;
        case 'b':  out[o++] = '\b'; break;
        case 'f':  out[o++] = '\f'; break;
        case 'n':  out[o++] = '\n'; break;
        case 'r':  out[o++] = '\r'; break;
        case 't':  out[o++] = '\t'; break;
        case 'u': {
            if (i + 4 > len) { free(out); return NULL; }
            unsigned cp = 0;
            for (int k = 0; k < 4; k++) {
                char h = src[i + (size_t)k];
                int v;
                if (h >= '0' && h <= '9') v = h - '0';
                else if (h >= 'a' && h <= 'f') v = h - 'a' + 10;
                else if (h >= 'A' && h <= 'F') v = h - 'A' + 10;
                else { free(out); return NULL; }
                cp = (cp << 4) | (unsigned)v;
            }
            i += 4;
            if (cp >= 0xD800 && cp <= 0xDBFF && i + 6 <= len &&
                src[i] == '\\' && src[i + 1] == 'u') {
                unsigned lo = 0;
                int ok = 1;
                for (int k = 0; k < 4; k++) {
                    char h = src[i + 2 + (size_t)k];
                    int v;
                    if (h >= '0' && h <= '9') v = h - '0';
                    else if (h >= 'a' && h <= 'f') v = h - 'a' + 10;
                    else if (h >= 'A' && h <= 'F') v = h - 'A' + 10;
                    else { ok = 0; break; }
                    lo = (lo << 4) | (unsigned)v;
                }
                if (ok && lo >= 0xDC00 && lo <= 0xDFFF) {
                    cp = 0x10000u + ((cp - 0xD800u) << 10) + (lo - 0xDC00u);
                    i += 6;
                }
            }
            if (cp < 0x80) {
                out[o++] = (char)cp;
            } else if (cp < 0x800) {
                out[o++] = (char)(0xC0 | (cp >> 6));
                out[o++] = (char)(0x80 | (cp & 0x3F));
            } else if (cp < 0x10000) {
                out[o++] = (char)(0xE0 | (cp >> 12));
                out[o++] = (char)(0x80 | ((cp >> 6) & 0x3F));
                out[o++] = (char)(0x80 | (cp & 0x3F));
            } else {
                out[o++] = (char)(0xF0 | (cp >> 18));
                out[o++] = (char)(0x80 | ((cp >> 12) & 0x3F));
                out[o++] = (char)(0x80 | ((cp >> 6) & 0x3F));
                out[o++] = (char)(0x80 | (cp & 0x3F));
            }
            break;
        }
        default:
            free(out);
            return NULL;
        }
    }
    out[o] = '\0';
    return out;
}

/* Replace a value by the redacted form of its text. `text` is the raw
 * text of the value: for a string, the content without its quotes; for
 * anything else, the value as written. */
static void fsql_json_emit_redacted(fsql_audit_buf *out, const char *text,
                                     size_t len, int is_string) {
    char *decoded = NULL;
    const char *t = text;
    size_t l = len;
    if (is_string) {
        decoded = fsql_json_unescape_dup(text, len);
        if (decoded) {
            t = decoded;
            l = strlen(decoded);
        }
    }
    char red[FSQL_AUDIT_REDACT_MAX];
    int n = fsql_audit_redact_bytes(t, l, red, sizeof red);
    if (n == 0) fsql_ab_put_json_string(out, red, strlen(red));
    else         fsql_ab_put_json_string(out, t, l);
    free(decoded);
}

static int fsql_json_redact_value(const char *p, fsql_audit_buf *out);

/* Copy one value, redacting the members of an object or array whose
 * key is sensitive. */
static int fsql_json_redact_container(const char *p, fsql_audit_buf *out) {
    char open = *p;
    char close = (open == '{') ? '}' : ']';
    fsql_ab_putc(out, open);
    p = fsql_json_skip_ws(p + 1);
    if (*p == close) {
        fsql_ab_putc(out, close);
        return 1;
    }
    for (;;) {
        p = fsql_json_skip_ws(p);
        if (open == '{') {
            const char *key;
            size_t klen;
            const char *after = fsql_json_string_span(p, &key, &klen);
            if (!after) return 0;
            fsql_ab_putc(out, '"');
            fsql_ab_putn(out, key, klen);
            fsql_ab_putc(out, '"');
            p = fsql_json_skip_ws(after);
            if (*p != ':') return 0;
            fsql_ab_putc(out, ':');
            p++;
            const char *vs;
            size_t vlen;
            int is_string;
            const char *vend = fsql_json_value_span(p, &vs, &vlen, &is_string);
            if (!vend) return 0;
            if (fsql_json_key_is_sensitive(key, klen)) {
                if (is_string)
                    fsql_json_emit_redacted(out, vs + 1, vlen - 2, 1);
                else if (*vs == '{' || *vs == '[')
                    fsql_json_emit_redacted(out, vs, vlen, 0);
                else
                    fsql_ab_putn(out, vs, vlen);   /* a number, a flag, null */
            } else if (!is_string && (*vs == '{' || *vs == '[')) {
                if (!fsql_json_redact_container(vs, out)) return 0;
            } else {
                fsql_ab_putn(out, vs, vlen);
            }
            p = vend;
        } else {
            const char *vs;
            size_t vlen;
            int is_string;
            const char *vend = fsql_json_value_span(p, &vs, &vlen, &is_string);
            if (!vend) return 0;
            if (!is_string && (*vs == '{' || *vs == '[')) {
                if (!fsql_json_redact_container(vs, out)) return 0;
            } else {
                fsql_ab_putn(out, vs, vlen);
            }
            p = vend;
        }
        p = fsql_json_skip_ws(p);
        if (*p == ',') {
            fsql_ab_putc(out, ',');
            p++;
            continue;
        }
        if (*p == close) {
            fsql_ab_putc(out, close);
            return 1;
        }
        return 0;
    }
}

static int fsql_json_redact_value(const char *p, fsql_audit_buf *out) {
    p = fsql_json_skip_ws(p);
    if (*p == '{' || *p == '[')
        return fsql_json_redact_container(p, out);
    const char *vs;
    size_t vlen;
    int is_string;
    const char *vend = fsql_json_value_span(p, &vs, &vlen, &is_string);
    if (!vend) return 0;
    fsql_ab_putn(out, vs, vlen);
    return 1;
}

/* Redact a JSON document. Returns a newly allocated string the caller
 * frees, or NULL when the document is malformed or the allocation
 * failed (the caller then keeps the original text). */
static char *fsql_audit_redact_json(const char *json) {
    if (!json) return NULL;
    if (fsql_audit_redact_mode() == FSQL_AUDIT_REDACT_NONE) return NULL;
    fsql_audit_buf out;
    out.buf = NULL;
    out.len = 0;
    out.cap = 0;
    out.oom = 0;
    if (!fsql_json_redact_value(json, &out) || out.oom) {
        free(out.buf);
        return NULL;
    }
    if (!out.buf) {
        out.buf = (char *)calloc(1, 1);
        if (!out.buf) return NULL;
    }
    return out.buf;
}

#endif /* FRACTALSQL_AUDIT_REDACT_H */
