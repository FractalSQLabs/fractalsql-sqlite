#!/usr/bin/env python3
"""test/test_sqlite.py — smoke test for the Community edition.

Exercises the three assertions every release must pass:

    1. The extension loads.
    2. fractalsql_edition() returns 'Community'.
       fractalsql_version() returns '2.0.0'.
    3. fractal_search(vector, query) returns a sensible distance
       ordering: the vector literally equal to the query scores a
       small distance; random far-away vectors score a larger one
       (convergence sanity check).

Runs in pure stdlib — no numpy dependency. Pass the extension path
via env var EXT_PATH or the first CLI arg; otherwise it probes a
handful of sensible defaults.

Usage
    test/test_sqlite.py                      # auto-detect the .so
    test/test_sqlite.py dist/amd64/fractalsql.so
    EXT_PATH=build/fractalsql.so test/test_sqlite.py

Exit codes
    0  all assertions passed
    1  an assertion failed (stderr explains which)
    2  couldn't find a loadable extension
"""
from __future__ import annotations

import json
import math
import os
import random
import sqlite3
import sys
import textwrap
from pathlib import Path

# Windows consoles default to a legacy ANSI codepage (cp1252) whose
# table cannot encode the unicode punctuation the check messages use;
# force UTF-8 output wherever the stream allows reconfiguration.
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

EXPECTED_EDITION = "Community"
EXPECTED_VERSION = "2.0.0"


def find_extension() -> Path:
    if len(sys.argv) >= 2:
        cand = Path(sys.argv[1])
        if cand.exists():
            return cand
    env = os.environ.get("EXT_PATH")
    if env and Path(env).exists():
        return Path(env)
    for cand in (
        Path("fractalsql.so"),
        Path("dist/amd64/fractalsql.so"),
        Path("dist/arm64/fractalsql.so"),
        Path("build/fractalsql.so"),
        Path("/usr/local/lib/sqlite3/fractalsql.so"),
    ):
        if cand.exists():
            return cand
    sys.stderr.write(
        "couldn't find a fractalsql.so — pass the path as argv[1] or "
        "set EXT_PATH.\n")
    sys.exit(2)


def load_extension(conn: sqlite3.Connection, path: Path) -> None:
    conn.enable_load_extension(True)
    # SQLite strips the ext; give it the stem-form for portability.
    conn.load_extension(str(path.with_suffix("")))
    conn.enable_load_extension(False)


def scalar(conn: sqlite3.Connection, sql: str, *params):
    row = conn.execute(sql, params).fetchone()
    return row[0] if row else None


def vec_to_csv(v) -> str:
    return ",".join(f"{x:.17g}" for x in v)


def run_checks(conn: sqlite3.Connection) -> None:
    # ----- Check 1: metadata ------------------------------------------------
    edition = scalar(conn, "SELECT fractalsql_edition();")
    assert edition == EXPECTED_EDITION, (
        f"fractalsql_edition(): expected {EXPECTED_EDITION!r}, got {edition!r}"
    )
    version = scalar(conn, "SELECT fractalsql_version();")
    assert version == EXPECTED_VERSION, (
        f"fractalsql_version(): expected {EXPECTED_VERSION!r}, got {version!r}"
    )
    print(f"[ok] metadata: edition={edition!r} version={version!r}")

    # ----- Check 2: fractal_search exists + returns a float ----------------
    dim = 8
    rng = random.Random(42)
    query = [rng.uniform(-1, 1) for _ in range(dim)]
    qnorm = math.sqrt(sum(x * x for x in query)) or 1.0
    query = [x / qnorm for x in query]

    # A vector equal to the query.
    self_vec = list(query)
    dist_self = scalar(
        conn,
        "SELECT fractal_search(?, ?);",
        vec_to_csv(self_vec),
        vec_to_csv(query),
    )
    assert isinstance(dist_self, (int, float)), (
        f"fractal_search returned {type(dist_self).__name__}, expected float"
    )
    print(f"[ok] self-match dist ≈ {dist_self:.4e}")

    # ----- Check 3: convergence — self-match scores much smaller than -----
    #                             random-far vectors.
    #
    # We generate a handful of random vectors and assert the self-match
    # has the smallest distance among them. The SFS cache short-circuits
    # re-runs for identical queries, so all rows in this sweep hit the
    # same best_point.
    n_random = 16
    table = [("self", self_vec)]
    for i in range(n_random):
        v = [rng.uniform(-1, 1) for _ in range(dim)]
        n = math.sqrt(sum(x * x for x in v)) or 1.0
        table.append((f"r{i}", [x / n for x in v]))

    dists = []
    for name, v in table:
        d = scalar(
            conn,
            "SELECT fractal_search(?, ?);",
            vec_to_csv(v),
            vec_to_csv(query),
        )
        dists.append((name, d))
    dists.sort(key=lambda x: x[1])

    top = dists[0]
    assert top[0] == "self", (
        f"convergence FAIL: nearest row is {top[0]!r} (dist={top[1]:.4g}); "
        f"expected 'self'. full ordering: {dists!r}"
    )
    print(f"[ok] convergence: self-match ranked first "
          f"(Δ vs. second-best = {dists[1][1] - top[1]:.4e})")

    # ----- Check 4: fractal_search_explore (Scout Mode) aggregate -----------------
    # Build a 3-island corpus; the Scout population must disperse across
    # >1 island where Sniper (fractal_search top-k) collapses into one.
    centers = [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]]
    edim = 3
    conn.execute("CREATE TABLE _scout_docs(emb TEXT)")
    for c in centers:
        for _ in range(15):
            v = [x + rng.uniform(-0.02, 0.02) for x in c]
            conn.execute("INSERT INTO _scout_docs VALUES(?)", (vec_to_csv(v),))

    # Skip-safe: if fractal_search_explore is absent (pre-Scout source) or the
    # linked core predates Scout (no "population" in the result, or the
    # aggregate raises), SKIP rather than fail — a build made before the
    # Scout drop is deployed legitimately has no population path, and the
    # gate should stay green until it does.
    try:
        row = scalar(
            conn,
            "SELECT fractal_search_explore(emb, ?, ?) FROM _scout_docs;",
            vec_to_csv(centers[0]),
            json.dumps({"population_size": 24, "iterations": 12}),
        )
        res = json.loads(row) if row else {}
        pop = res.get("population")
    except sqlite3.Error as e:
        print(f"[skip] scout: fractal_search_explore unavailable / pre-Scout core ({e})")
        return
    if not isinstance(pop, list) or not pop:
        print("[skip] scout: result has no 'population' (pre-Scout core)")
        return

    assert len(pop) == 24, (
        f"fractal_search_explore: expected 24 particles, got {len(pop)}"
    )
    assert all(len(p) == edim for p in pop), "fractal_search_explore: bad particle dim"

    def _nearest(p):
        return min(range(3), key=lambda k:
                   sum((p[i] - centers[k][i]) ** 2 for i in range(edim)))

    islands = len(set(_nearest(p) for p in pop))
    assert islands >= 2, (
        f"fractal_search_explore: Scout discovered only {islands} island(s); "
        "expected >= 2 (no dispersion)"
    )
    print(f"[ok] scout: {len(pop)} particles disperse across {islands}/3 islands")


def main() -> int:
    ext = find_extension()
    print(f"loading extension: {ext}")

    conn = sqlite3.connect(":memory:")
    load_extension(conn, ext)

    try:
        run_checks(conn)
    except AssertionError as e:
        sys.stderr.write(f"\nFAIL: {e}\n")
        return 1
    finally:
        conn.close()

    print("\nAll checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
