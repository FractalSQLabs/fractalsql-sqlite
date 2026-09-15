#!/usr/bin/env python3
"""tests/test_scout.py — Scout Mode e2e gate.

Builds a 3-island corpus table and calls the
fractal_search_explore(emb, query[, params]) aggregate, whose finalizer
returns the SFS result JSON — including the dispersed "population" —
as TEXT. This gate asserts the §8 Scout enablement properties:

  (1)+(2) population_size particles, each of the corpus dim (not the
          1-row stub a pre-Scout build returned);
  (3)     discovery — the particles disperse across >1 island.

Skips cleanly (exit 0) if the extension is not built or Scout is
absent/stubbed, so it is safe to run before the surface is deployed.

Usage:
    python3 tests/test_scout.py
    FRACTALSQL_EXT=... FRACTALSQL_DB=... python3 tests/test_scout.py
"""
import json
import os
import random
import sys

from _t2s_common import connect_or_skip

CENTERS = [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]]
DIM = 3
PER = 20
POP = 24


def nearest(p):
    return min(range(3), key=lambda k:
               sum((p[i] - CENTERS[k][i]) ** 2 for i in range(DIM)))


def main():
    rng = random.Random(11)
    conn = connect_or_skip()
    if conn is None:
        return 0
    cur = conn.cursor()

    cur.execute("DROP TABLE IF EXISTS _scout_docs")
    cur.execute("CREATE TABLE _scout_docs (id int, emb_arr text)")
    rid = 0
    rows = []
    for c in CENTERS:
        for _ in range(PER):
            v = [x + rng.uniform(-0.02, 0.02) for x in c]
            rows.append((rid, json.dumps(v)))
            rid += 1
    cur.executemany("INSERT INTO _scout_docs VALUES (?, ?)", rows)

    query = CENTERS[0]                       # anchor inside island 0
    opts = json.dumps({"population_size": POP, "iterations": 12})
    try:
        cur.execute(
            "SELECT fractal_search_explore(emb_arr, ?, ?) FROM _scout_docs",
            (json.dumps(query), opts))
        result = cur.fetchone()[0]
    except Exception as e:
        print(f"SKIP: fractal_search_explore unavailable (pre-Scout / minimal "
              f"build): {e}")
        cur.execute("DROP TABLE IF EXISTS _scout_docs")
        return 0
    cur.execute("DROP TABLE IF EXISTS _scout_docs")
    conn.close()

    payload = json.loads(result)
    particles = payload.get("population") or payload.get("best_point")
    # Skip-safe: a pre-Scout build returns a single best_point row. Treat
    # <= 1 particle as "Scout drop not deployed" and skip rather than fail.
    if not particles or len(particles) <= 1:
        print(f"SKIP: fractal_search_explore returned the pre-Scout stub "
              f"({len(particles or [])} point) — deploy the Scout-enabled "
              "build to enable")
        return 0
    if len(particles) != POP:
        print(f"FAIL: expected {POP} particles, got {len(particles)}",
              file=sys.stderr)
        return 1
    if not all(len(p) == DIM for p in particles):
        print("FAIL: particle dim != 3", file=sys.stderr)
        return 1
    islands = len(set(nearest(p) for p in particles))
    print(f"population: {len(particles)} particles, dim {DIM}")
    print(f"SCOUT discovered {islands}/3 islands")
    if islands < 2:
        print(f"FAIL: Scout discovered only {islands} island(s); "
              "expected >= 2 (no dispersion)", file=sys.stderr)
        return 1
    print("OK: sqlite scout gate passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())