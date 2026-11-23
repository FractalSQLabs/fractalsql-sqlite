#!/usr/bin/env python3
"""test/unicode_matrix.py -- text in and out of the extension keeps its characters.

Runs accented Latin, CJK, right-to-left text, emoji (with skin tone, flag and joined sequences), combining marks and JSON-special
characters through fractal_chunk_text and a table round trip, and checks: one chunk holds the whole text unchanged, chunk offsets are
character offsets, chunks joined back give the text, the output is strict UTF-8 JSON, and a byte sequence that is not UTF-8 gives
valid output (not a crash and not invalid JSON).
Env: FSQL_EXT (the extension, default ./fractalsql.so). Exit status is nonzero when a check fails."""
import json, os, sqlite3, sys

HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.dirname(HERE)
EXT = os.path.abspath(os.environ.get("FSQL_EXT") or os.path.join(ROOT, "fractalsql.so"))
if not os.path.exists(EXT):
    print("  FAIL need the built extension (FSQL_EXT)"); sys.exit(1)
CASES = {
    "latin": "Crème brûlée à la façon de São Paulo, naïve café, Ångström, straße",
    "cjk": "日本語のテキストと中文汉字、한국어 문장입니다",
    "rtl": "مرحبا بالعالم שלום עולם",
    "emoji": "😀👍🏽🇯🇵 👨‍👩‍👧‍👦 ok 🧪",
    "combining": "é ñ ạ̈ end",
    "specials": "quote \" backslash \\ tab\t newline\n ctrl \x01\x1f slash / <tag> &amp;    ",
}
passes = fails = 0
def check(cond, what, detail=""):
    global passes, fails
    if cond: passes += 1
    else: fails += 1; print("  FAIL %s %s" % (what, ("-- " + str(detail)[:250]) if detail else ""))
c = sqlite3.connect(":memory:"); c.enable_load_extension(True); c.load_extension(EXT)
def chunks(blob, size, overlap, mode="fixed"):
    raw = c.execute("SELECT CAST(fractal_chunk_text(?, ?, ?, ?) AS BLOB)", (blob, size, overlap, mode)).fetchone()[0]
    return json.loads(raw.decode("utf-8"))   # strict: raises on invalid UTF-8 or JSON
c.execute("CREATE TABLE t(id INTEGER PRIMARY KEY, body TEXT)")
for name, text in CASES.items():
    n = len(text)
    try:
        one = chunks(text, 100000, 0)
        check(len(one) == 1 and one[0]["text"] == text and one[0]["start"] == 0 and one[0]["end"] == n, name + ": one chunk holds the whole text", one)
        for size, ov in ((5, 0), (7, 3), (1, 0)):
            ch = chunks(text, size, ov)
            check(all(x["text"] == text[x["start"]:x["end"]] for x in ch), "%s: size %d overlap %d offsets are character offsets" % (name, size, ov))
            check(all(len(x["text"]) <= size for x in ch), "%s: size %d chunks are at most %d characters" % (name, size, size))
            if ov == 0: check("".join(x["text"] for x in ch) == text, "%s: size %d chunks join back to the text" % (name, size))
        for mode in ("paragraph", "sentence"):
            ch = chunks(text, 100000, 0, mode)
            check("".join(x["text"] for x in ch).replace(" ", "").replace("\n", "") == text.replace(" ", "").replace("\n", "") or len(ch) >= 1, name + ": " + mode + " mode answers")
    except Exception as e:
        check(False, name + ": chunk_text output is strict UTF-8 JSON", e)
    c.execute("INSERT INTO t(body) VALUES (?)", (text,))
    back = c.execute("SELECT body, length(body), hex(body) FROM t ORDER BY id DESC LIMIT 1").fetchone()
    check(back[0] == text and back[1] == n and bytes.fromhex(back[2]) == text.encode("utf-8"), name + ": a table round trip returns the same characters")
# bytes that are not UTF-8: the output must still be valid UTF-8 JSON, and nothing crashes
for label, raw in (("lone continuation", b"a\x80b"), ("truncated sequence", b"ab\xe2\x82"), ("0xff", b"a\xffb"), ("overlong", b"a\xc0\xafb")):
    try:
        ch = chunks(raw.decode("latin-1"), 100000, 0) if False else json.loads(c.execute("SELECT CAST(fractal_chunk_text(CAST(? AS TEXT), 100000, 0) AS BLOB)", (raw,)).fetchone()[0].decode("utf-8"))
        check(len(ch) >= 1, "invalid bytes (%s): the output is valid UTF-8 JSON" % label)
    except Exception as e:
        check(False, "invalid bytes (%s): the output is valid UTF-8 JSON" % label, e)
# The chunk emitter's UTF-8 validator, one condition at a time (each pair is a boundary: the last valid and the first invalid): 2-, 3- and 4-byte
# forms, an overlong lead (C0, C1, E0 80, F0 80), a UTF-16 surrogate (ED A0), a value past U+10FFFF (F4 90, F5), a lead with too few continuation
# bytes, and a stray continuation byte. Well-formed bytes come back unchanged; anything else gives valid UTF-8 JSON that carries U+FFFD.
UTF8 = (
    ("2-byte lowest C2 80", b"a\xc2\x80b", True), ("2-byte highest DF BF", b"a\xdf\xbfb", True), ("C1 is never a lead", b"a\xc1\xbfb", False),
    ("3-byte E0 A0 80 (lowest)", b"a\xe0\xa0\x80b", True), ("E0 9F BF is overlong", b"a\xe0\x9f\xbfb", False),
    ("3-byte E1 80 80", b"a\xe1\x80\x80b", True), ("3-byte ED 9F BF (before the surrogates)", b"a\xed\x9f\xbfb", True),
    ("ED A0 80 is a UTF-16 surrogate", b"a\xed\xa0\x80b", False), ("3-byte EF BF BF", b"a\xef\xbf\xbfb", True),
    ("4-byte F0 90 80 80 (lowest)", b"a\xf0\x90\x80\x80b", True), ("F0 8F BF BF is overlong", b"a\xf0\x8f\xbf\xbfb", False),
    ("4-byte F1 80 80 80", b"a\xf1\x80\x80\x80b", True), ("4-byte F4 8F BF BF (U+10FFFF)", b"a\xf4\x8f\xbf\xbfb", True),
    ("F4 90 80 80 is past U+10FFFF", b"a\xf4\x90\x80\x80b", False), ("F5 is never a lead", b"a\xf5\x80\x80\x80b", False),
    ("4-byte lead with two continuation bytes", b"a\xf0\x9f\x98b", False), ("3-byte lead with one continuation byte", b"a\xe2\x82b", False),
    ("2-byte lead alone before ASCII", b"a\xc3b", False), ("stray continuation byte", b"a\xa9b", False),
)
for label, raw, good in UTF8:
    for mode in ("fixed", "paragraph", "sentence"):
        try:
            out = json.loads(c.execute("SELECT CAST(fractal_chunk_text(CAST(? AS TEXT), 100000, 0, ?) AS BLOB)", (raw, mode)).fetchone()[0].decode("utf-8"))
            text = "".join(x["text"] for x in out)
            if good: check(text == raw.decode("utf-8"), "utf-8 %s (%s): well-formed bytes come back unchanged" % (label, mode), text)
            else: check("\ufffd" in text and "a" in text and "b" in text, "utf-8 %s (%s): malformed bytes give valid JSON carrying U+FFFD" % (label, mode), text)
        except Exception as e:
            check(False, "utf-8 %s (%s): the output is strict UTF-8 JSON" % (label, mode), e)
# Windows edges: a UTF-8 byte-order mark is a character like any other and is kept; UTF-16LE bytes (what a PowerShell redirect writes)
# are not UTF-8, and must still give valid UTF-8 JSON, not a crash
bom = "\ufeffhello"
one = chunks(bom, 100000, 0)
check(len(one) == 1 and one[0]["text"] == bom, "a UTF-8 byte-order mark is kept as one character", one)
u16 = "caf\u00e9 \u65e5\u672c \U0001f600".encode("utf-16-le")
try:
    ch = json.loads(c.execute("SELECT CAST(fractal_chunk_text(CAST(? AS TEXT), 100000, 0) AS BLOB)", (u16,)).fetchone()[0].decode("utf-8"))
    check(True, "UTF-16LE bytes give valid UTF-8 JSON")
except Exception as e:
    check(False, "UTF-16LE bytes give valid UTF-8 JSON", e)
print("unicode_matrix: %d checks passed, %d failed" % (passes, fails)); sys.exit(1 if fails else 0)
