<p align="center">
  <img src="../FractalSQLforSQLite.jpg" alt="FractalSQL for SQLite" width="720">
</p>

# FractalSQL benchmark: sqlite-vec vs Scout Mode

Head-to-head comparison of [sqlite-vec](https://github.com/asg017/sqlite-vec)'s
`vec0` virtual table against FractalSQL's `fractal_search_explore` (Scout
Mode, `walk=0`). Measures search latency and island recall on a synthetic
Gaussian-cluster dataset.

sqlite-vec is the closest thing SQLite has to pgvector, but as of this
writing its `vec0` table does EXACT brute-force KNN (SIMD-accelerated),
not an approximate index like HNSW — see
[asg017/sqlite-vec#25](https://github.com/asg017/sqlite-vec/issues/25).
The fast/single-cluster vs. slow/diverse story below still holds: exact
top-k by distance collapses to whichever one cluster is geometrically
closest to the query, the same qualitative outcome an approximate index
would produce, just without approximation error. Labeled "vec" below,
not "HNSW".

## Prerequisites

- The `fractalsql` extension built (`make` from the repo root)
- Python 3.9+
- Write access to the repo directory (the bench scripts create a plain
  SQLite file, `bench/fractalsql_bench.db` by default — no server, no
  superuser)

## Setup

```bash
pip install -r bench/requirements.txt
make          # builds ./fractalsql.so, if not already built
```

## Run the benchmark

```bash
make bench                               # data_gen + head_to_head
```

Or manually:

```bash
python3 bench/data_gen.py                # ~30-60s to populate 100k rows
python3 bench/head_to_head.py            # ~1-3 min for 5 queries
```

## What you should see

The output is a per-query table followed by an average. This example is
from an actual run, not a hand-written estimate:

```
Benchmark: 100000 stored vectors, 50 clusters, dim=128
  vec: sqlite-vec brute-force KNN, k=50
  Scout: population=50, iterations=8, mdn=2, walk=0.0 (brute-force relevance scan + MMR), col=emb_arr

qi  anchor      |        vec ms    vec recall     |     Scout ms   Scout recall
-------------------------------------------------------------------------------
 0  cluster  23 |     1641.5      1 / 50     |     1632.2      5 / 50
 1  cluster  25 |      122.7      1 / 50     |     2091.5      8 / 50
 2  cluster  37 |       46.5      1 / 50     |     2141.3      4 / 50
 3  cluster  47 |       47.0      1 / 50     |     2139.0      7 / 50
 4  cluster   1 |       48.7      1 / 50     |     2082.4      7 / 50

Averages over 5 queries:
  vec:      381.3 ms   recall  1.0 / 50
  Scout:   2017.3 ms   recall  6.2 / 50
  Scout is 5.3x slower and discovers 6.2x more distinct clusters
```

qi=0's `vec` latency is a one-time cold-start cost (page cache / vec0's
first-query setup) that the other four queries in the same process don't
pay; excluding it, `vec` settles around 50-120ms here. The shape of the
result will vary run to run, but the pattern is robust: `vec` converges on
1 cluster; Scout Mode finds 4-8 clusters, at a real latency cost. This is
the intended comparison: different algorithms solving different problems.

The head-to-head above runs at `data_gen.py`'s own default, `d=128`. The
Scaling notes table below uses `d=768` instead (a common real embedding
width), which is most of why its per-query times are ~6-7x higher at the
same N (Scout's cost is O(N × D)).

## Scaling notes

The SFS fitness is `min over stored_set of ||candidate - v||²`, evaluated
brute-force. Per-fitness cost is O(N × D), and SFS makes ~2500 evaluations
in a population=50, iterations=8 run. That scales roughly linearly with the
stored-set size; the first two rows below are measured directly. The third
is a linear extrapolation, not measured, so treat it as a rough order of
magnitude, not a promise:

| N (stored vectors) | Approx per-query Scout time at d=768 |
| ------------------- | ------------------------------------- |
| 10 000              | ~0.85 seconds (measured)              |
| 100 000 (default)   | ~10 seconds (measured)                |
| 1 000 000           | ~100 seconds (extrapolated)           |

sqlite-vec's brute-force scan is approximately N-independent in
per-query latency *relative to Scout's cost class* only in the sense
that both are O(N × D) — sqlite-vec's SIMD-accelerated inner loop is
simply a much smaller constant factor. For production use beyond
~100k vectors, a future version of `fractal_search_explore` could use
an approximate-NN index internally for fitness lookups. For now, Scout
Mode is best applied to curated sub-corpora where diversity matters
more than scan throughput.

## Tuning

`head_to_head.py` exposes a few knobs:

```
--n-queries        number of queries to average (default 5)
--top-k            #results per method, also SFS population_size (50)
--sfs-iter         SFS generations (default 8)
--sfs-mdn          diffusion factor (default 2)
--seed             query-selection RNG seed
```

`data_gen.py` exposes the dataset shape:

```
--n        total points (default 100000)
--dim      vector dimension (default 128)
--clusters number of Gaussian islands (default 50)
--sigma    intra-cluster std (default 0.05)
```

## fractal_vector vs JSON TEXT at scale

A second, unrelated benchmark: `fractal_vector` BLOB vs plain JSON TEXT
storage size, bulk-insert throughput, and search latency, at
`data_gen.py`'s real scale rather than a hand-picked single row.
Distinct from the vec-vs-Scout comparison above.

```bash
make bench-vector
```

Or manually:

```bash
python3 bench/data_gen.py --with-fractal-vector   # adds bench_vectors.emb_fv
python3 bench/vector_type_head_to_head.py
```

Reports four numbers: on-disk size per row (JSON TEXT vs fractal_vector),
bulk insert throughput for both column types, `fractal_search_trajectory`
latency old (JSON TEXT) vs new (fractal_vector) overload, and this
process's own RSS delta during a full-corpus `fractal_vector` scan (a
regression tripwire for the corpus-scan loop actually freeing each
decoded row rather than accumulating them — meaningful because the
extension runs in-process with the Python client, unlike a client/server
database where this would need inspecting a separate backend's memory).

The storage-size ratio depends on how compressible your actual embedding
values are and how many significant digits the JSON encoding keeps:
`fractal_vector` stores raw float32 (4 bytes/coordinate plus a 4-byte
header) with no compression attempt, while JSON TEXT stores ASCII
decimal digits (more bytes per coordinate, and it grows with precision).
Measure on your own data before treating either number as a promise.

**On sub-benchmark (c)'s absolute numbers**: `fractal_search_trajectory`
runs a full SFS population search internally (`population_size=50`, a
fixed `max_generation`), the same cost class as `fractal_search_explore`/
Scout mode above — it is not a cheap distance-sort top-k. The "Scaling
notes" table above (~10s at N=100k, d=768, Scout Mode) is the right
intuition for sub-benchmark (c) too, and the absolute latency you see is
dominated by that SFS cost, not by the JSON-parse-vs-BLOB-decode
difference this arm is actually trying to isolate. Judge fractal_vector's
contribution from the relative gap between the two rows, not either row's
absolute value.

`vector_type_head_to_head.py`'s own knobs:

```
--insert-n         row count for the insert-throughput sub-benchmark
                   (default 20000 -- smaller than the full corpus,
                   this arm is O(n) by design so a subset is
                   representative)
--search-queries   queries to average for the latency sub-benchmark
                   (default 10)
```
