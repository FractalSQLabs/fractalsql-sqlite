<p align="center">
  <img src="../../FractalSQLforSQLite.jpg" alt="FractalSQL for SQLite" width="720">
</p>

# tests/fuzz/

libFuzzer drivers for this extension's three hand-rolled
string parsers (`src/fractalsql_parse.c`). Run via `build_test.sh
--fuzz` (gate 21) -- see that script's own header comment for the full
gate description. Do not invoke the compile lines in these files by
hand for anything other than local iteration; the gate is the source
of truth for flags.

## Why only three targets, and why a separate translation unit

Most of this extension's functions require a live SQLite connection
(`sqlite3_context`, prepared statements) to run at all, which rules
out a standalone libFuzzer binary for most of the codebase.

The three functions fuzzed here are the exception: they are pure C99
with no SQLite dependency, taking a `const char *` and a fixed-size
output buffer. They live in `src/fractalsql_parse.c`/`.h` specifically
so a fuzz driver can link against them directly.

| Target | Function | Input trust |
| --- | --- | --- |
| `fuzz_parse_embedding_array.c` | `fsql_parse_embedding_array()` | **Externally adversarial.** Parses `fractal_embed()`'s raw response from whatever endpoint `fractalsql.http_embed_url` points at -- a malicious or merely buggy third-party HTTP provider fully controls these bytes. |
| `fuzz_extract_best_point.c` | `fsql_extract_best_point()` | Parses the vendored core's own `fsql_search_ptr` result JSON. Lower risk, included as defense-in-depth. |
| `fuzz_extract_population.c` | `fsql_extract_population()` | Same trust tier as above; the most structurally complex of the three (nested-array + dim-stride bookkeeping), the likeliest to have an edge case the other two don't share. |

## Corpus

`corpus_<target>/` holds a handful of valid-shaped seed files per
target -- enough for libFuzzer to bootstrap coverage-guided mutation
from a real starting point rather than cold. Not meant to be
exhaustive; the fuzzer's own mutation is what finds the interesting
cases.

## Running a real campaign (not just the pre-push smoke)

Gate 21 runs each target for `FSQL_FUZZ_TIME` seconds (default 30) --
enough to catch a regression, not enough to claim thorough coverage.
For a real campaign, build the same binaries by hand and give them
hours, not seconds:

```
clang-18 -std=c99 -O1 -g -fsanitize=fuzzer,address -fno-sanitize-recover=address \
    -Isrc src/fractalsql_parse.c tests/fuzz/fuzz_parse_embedding_array.c \
    -o /tmp/fuzz_parse_embedding_array
ASAN_OPTIONS=detect_leaks=0 /tmp/fuzz_parse_embedding_array \
    -max_total_time=3600 tests/fuzz/corpus_parse_embedding_array/
```

A crash reproduces directly against the same binary:
`/tmp/fuzz_parse_embedding_array <crash-file>`.
