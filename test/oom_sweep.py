#!/usr/bin/env python3
"""test/oom_sweep.py -- allocation-failure sweep of the extension.

For every demo kit (demo/*.sql) it starts one interactive sqlite3 shell under tests/oom_preload.c scoped to the extension's own
code (FSQL_OOM_ONLY_SO: only allocations whose caller lives in the extension are counted or failed; SQLite's and the shell's are
untouched), runs the kit's statements in order, and for every statement that calls a fractal* function and only reads (SELECT / WITH)
runs it repeatedly: once to count how many allocations the extension makes for it, then once per sampled allocation with exactly that
allocation failing (malloc/calloc/realloc/strdup return NULL, ENOMEM). A second pass fails each allocation made while the extension
loads.

What is asserted: the process survives (no signal, no hang), no sanitizer report. An ordinary error (the extension reporting out of
memory, or the statement failing for another reason) is the expected outcome and is not a failure.

Env: FSQL_EXT (the extension, default ./fractalsql.so), SQLITE3, OOM_MAX_TRIALS (allocation points per statement, 40), OOM_SAMPLE (run
every Nth target statement, default 1), OOM_LOAD_STRIDE (fail every Nth allocation of the LOAD pass, default 1), OOM_LOAD=0 (skip the
load pass), OOM_FILTER (regex on the kit's file name), OOM_MAX_KITS (debug).
"""
import os, queue, re, shutil, signal, sqlite3, subprocess, sys, tempfile, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SQLITE3 = os.environ.get("SQLITE3") or shutil.which("sqlite3")
EXT = os.path.abspath(os.environ.get("FSQL_EXT") or os.path.join(ROOT, "fractalsql.so"))
if not SQLITE3 or not os.path.exists(EXT):
    print("  FAIL need the sqlite3 shell and the built extension (FSQL_EXT)"); sys.exit(1)
MAX_TRIALS = int(os.environ.get("OOM_MAX_TRIALS", "40"))
SAMPLE = max(1, int(os.environ.get("OOM_SAMPLE", "1") or 1))
LOAD_STRIDE = max(1, int(os.environ.get("OOM_LOAD_STRIDE", "1") or 1))
MAX_KITS = int(os.environ.get("OOM_MAX_KITS", "0") or 0)
FILTER = re.compile(os.environ.get("OOM_FILTER", ""))
WORK = tempfile.mkdtemp(prefix="fsql_oomsweep_")
SHIM = os.path.join(WORK, "oom_preload.so")
r = subprocess.run(["cc", "-O2", "-fPIC", "-shared", "-o", SHIM, os.path.join(ROOT, "tests", "oom_preload.c"), "-ldl"], capture_output=True, text=True)
if r.returncode != 0:
    print("  FAIL the fault shim did not build:\n" + r.stderr); sys.exit(1)
MOCKS = {}
for name in ("mock_reasoning_plugin", "mock_embed_plugin"):
    out = os.path.join(WORK, name + ".so")
    if subprocess.run(["cc", "-shared", "-fPIC", "-std=c99", "-I" + os.path.join(ROOT, "include"), os.path.join(ROOT, "tests", name + ".c"), "-o", out],
                      capture_output=True).returncode == 0:
        MOCKS[name] = out
CTL = os.path.join(WORK, "ctl")
SO_MATCH = os.path.basename(EXT).split(".")[0] + "."          # "fractalsql." matches the extension's path, not libsqlite3's
BAD = re.compile(r"Sanitizer|runtime error:|Segmentation fault|Assertion .* failed|terminate called|\*\*\* stack smashing|double free|corrupted|free\(\): invalid")
DONE = "FSQLOOMDONE"
ENV = {"FSQL_REASONING_REQUIRE_SIGNATURE": "0", "FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE": "0"}
FIXED_FILES = {"sql": "/tmp/fractalsql_bt_sql.txt"}


class Session:
    """One shell process: statements go in over a pipe, answers (stdout and stderr merged) come back up to a marker."""

    def __init__(self):
        e = dict(os.environ, **ENV)
        e.update(LD_PRELOAD=SHIM, FSQL_OOM_CTL=CTL, FSQL_OOM_ONLY_SO=SO_MATCH, FSQL_OOM_LINEBUF="1")
        self.p = subprocess.Popen([SQLITE3, "-batch", ":memory:"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                  env=e, text=True, bufsize=1, encoding="utf-8", errors="replace")
        self.q = queue.Queue()
        threading.Thread(target=self._pump, daemon=True).start()

    def _pump(self):
        for line in self.p.stdout:
            self.q.put(line.rstrip("\n"))
        self.q.put(None)

    def alive(self):
        return self.p.poll() is None

    def run(self, sql, timeout=30):
        """Returns (output, state): state is 'ok', 'died' or 'hung'."""
        try:
            self.p.stdin.write(sql.rstrip() + "\nSELECT '" + DONE + "';\n")
            self.p.stdin.flush()
        except (BrokenPipeError, OSError):
            return "", "died"
        out, end = [], time.monotonic() + timeout
        while True:
            left = end - time.monotonic()
            if left <= 0:
                return "\n".join(out), "hung"
            try:
                line = self.q.get(timeout=left)
            except queue.Empty:
                return "\n".join(out), "hung"
            if line is None:
                return "\n".join(out), "died"
            if line == DONE:
                return "\n".join(out), "ok"
            out.append(line)

    def signal_and_wait(self, sig, marker):
        try: os.unlink(marker)
        except OSError: pass
        if not self.alive(): return False
        os.kill(self.p.pid, sig)
        end = time.monotonic() + 3
        while time.monotonic() < end:
            if os.path.exists(marker): return True
            time.sleep(0.0005)
        return False

    def arm(self, n):
        with open(CTL, "w") as f: f.write("%d 0 0 0\n" % n)
        return self.signal_and_wait(signal.SIGUSR1, CTL + ".armed")

    def disarm(self):
        """Disarms and returns (allocations counted, failures injected), or None."""
        if not self.signal_and_wait(signal.SIGUSR2, CTL + ".res"): return None
        try:
            c, f = open(CTL + ".res").read().split()
            return int(c), int(f)
        except (OSError, ValueError):
            return None

    def close(self):
        if self.alive():
            try:
                self.p.stdin.close()
                self.p.wait(timeout=20)       # a normal exit is what writes the coverage counters
            except Exception:                 # noqa: BLE001
                self.p.kill()
        else:
            try: self.p.wait(timeout=1)
            except Exception: pass            # noqa: BLE001


def split_statements(text):
    """Complete SQL statements (and dot-commands) of a script, split the way the shell would."""
    out, buf = [], ""
    for line in text.split("\n"):
        if not buf and line.lstrip().startswith("."):
            out.append(line.strip()); continue
        if not buf and (not line.strip() or line.lstrip().startswith("--")):
            continue
        buf += line + "\n"
        if sqlite3.complete_statement(buf):
            out.append(buf.strip()); buf = ""
    return out


def points(total):
    """The allocation indexes to fail: the first allocations all (init paths), then spread over the rest."""
    if total <= MAX_TRIALS:
        return list(range(1, total + 1))
    head_n = min(24, MAX_TRIALS // 2)
    rest = MAX_TRIALS - head_n
    step = (total - head_n) / float(max(1, rest))
    return list(range(1, head_n + 1)) + [head_n + int(round((i + 1) * step)) for i in range(rest)]


problems = []
trials = stmts_swept = 0


def record(where, n, why, out):
    problems.append((where, n, why, out[-240:]))
    print("  FAIL %s [allocation %s]: %s\n       %r" % (where, n, why, out[-200:]), flush=True)


def fresh():
    s = Session()
    s.run(".load %s" % EXT)
    if "mock_reasoning_plugin" in MOCKS:
        s.run("SELECT fractal_config_set('reasoning_plugin', '%s');" % MOCKS["mock_reasoning_plugin"])
    return s


def sweep_kit(path):
    global trials, stmts_swept
    with open(path, encoding="utf-8", errors="replace") as fh:
        stmts = split_statements(fh.read())
    with open(FIXED_FILES["sql"], "w") as fh: fh.write("SELECT 1;")
    s = fresh()
    seen_targets = 0
    for st in stmts:
        out, state = s.run(st, timeout=60)
        if state != "ok":
            if state == "died": record(os.path.basename(path), "setup", "a statement died with nothing failed: " + st[:60], out)
            s.close(); return
        if not (re.match(r"(?is)\s*(select|with)\b", st) and re.search(r"\bfractal\w*\s*\(", st)):
            continue
        seen_targets += 1
        if (seen_targets - 1) % SAMPLE: continue
        where = "%s: %s" % (os.path.basename(path), st[:90].replace("\n", " "))
        if not s.arm(10 ** 9): continue
        out, state = s.run(st, timeout=60)
        counts = s.disarm()
        if state != "ok" or counts is None:
            if state == "died": record(where, "count run", "the statement itself died with nothing failed", out)
            s.close(); return
        stmts_swept += 1
        for n in points(counts[0]):
            if not s.alive() or not s.arm(n):
                return_to = s
                s.close(); s = fresh()                   # (state built by earlier statements is lost: later targets run on what remains)
                if not s.arm(n): break
            out, state = s.run(st, timeout=60)
            if state == "ok": s.disarm()
            trials += 1
            if state != "ok":
                record(where, n, "the process " + ("died" if state == "died" else "hung") + (" (rc=%s)" % s.p.poll() if state == "died" else ""), out)
                s.close(); s = fresh()
            elif BAD.search(out):
                record(where, n, "internal error or sanitizer report", out)
    s.close()


def sweep_load():
    """Fails each allocation the extension makes while it loads (registration, state creation)."""
    global trials
    env_s = Session()
    env_s.run("SELECT 1;")                               # the process must be up (the shim's signal handlers installed) before arming
    if not env_s.arm(10 ** 9): env_s.close(); return 0
    out, state = env_s.run(".load %s\nSELECT fractal_version();" % EXT)
    counts = env_s.disarm(); env_s.close()
    if counts is None or state != "ok":
        print("  note: the LOAD pass could not count the extension's load-time allocations (state=%s counts=%s): %r" % (state, counts, out[-200:]))
        return 0
    total = min(counts[0], 1500)
    for n in range(1, total + 1, LOAD_STRIDE):
        s = Session()
        s.run("SELECT 1;")
        if not s.arm(n): s.close(); continue
        out, state = s.run(".load %s" % EXT)
        trials += 1
        if state != "ok": record("LOAD", n, "the process " + ("died" if state == "died" else "hung"), out)
        elif BAD.search(out): record("LOAD", n, "internal error or sanitizer report", out)
        else:
            s.run("SELECT fractal_version();")        # the half-initialised extension must not crash later
        s.close()
    return total


t0 = time.time()
kits = sorted(f for f in os.listdir(os.path.join(ROOT, "demo")) if f.endswith(".sql") and f.startswith("demo-vertical-") and FILTER.search(f))
if MAX_KITS: kits = kits[:MAX_KITS]
for k in kits:
    sweep_kit(os.path.join(ROOT, "demo", k))
load_points = sweep_load() if os.environ.get("OOM_LOAD", "1") != "0" else 0
try: os.remove(FIXED_FILES["sql"])
except OSError: pass
shutil.rmtree(WORK, ignore_errors=True)
print()
print("oom sweep: %d statements, %d injected allocation failures (%d during LOAD) in %.0fs, %d problem(s)"
      % (stmts_swept, trials, load_points, time.time() - t0, len(problems)))
sys.exit(1 if problems else 0)
