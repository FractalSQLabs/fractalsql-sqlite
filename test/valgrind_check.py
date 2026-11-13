#!/usr/bin/env python3
"""test/valgrind_check.py -- verdict helper for test/valgrind_run.sh (build_test.sh --profile).

  valgrind_check.py verdict --ours <substring> [--ours <substring> ...] [--host-fn <prefix> ...] [--intentional-leak <fn> ...]
                            <valgrind.xml> [<valgrind.xml> ...]

Reads valgrind XML logs and decides: FAIL on any memcheck error, or any definite/indirect leak, whose stack has a frame
whose object file path contains one of the --ours substrings; everything else (the host's own noise, possible leaks) is
only counted. Exit 0 = pass, 1 = fail.
  --host-fn P           a frame whose function name starts with P does not count as ours even when its object is (the vendored
                        sqlite3 amalgamation linked into the MCP server is the host's code, not ours)
  --intentional-leak F  a definite/indirect LEAK whose stack contains a function whose name contains F is counted, not failed:
                        for objects the code leaks on purpose (see the comment at the allocation)

(Kept in step with the same file in the other FractalSQL repos: copy fixes across.)
"""
import os, sys, xml.etree.ElementTree as ET

LEAKS_THAT_FAIL = {"Leak_DefinitelyLost", "Leak_IndirectlyLost"}


def verdict(xml_paths, ours, host_fn=(), intentional=()):
    total = ours_n = leaks_n = intent_n = 0
    bad = []
    for xml_path in xml_paths:
        try:
            root = ET.parse(xml_path).getroot()
        except (ET.ParseError, OSError) as e:
            print("  FAIL the valgrind log %s could not be read (%s)" % (os.path.basename(xml_path), e))
            return 1
        for err in root.iter("error"):
            kind = err.findtext("kind") or "?"
            total += 1
            frames = [(f.findtext("obj") or "", f.findtext("fn") or "?", f.findtext("file") or "", f.findtext("line") or "")
                      for f in err.iter("frame")]
            mine = [fr for fr in frames if any(o in fr[0] for o in ours) and not any(fr[1].startswith(h) for h in host_fn)]
            if kind in LEAKS_THAT_FAIL and mine and any(any(i in fr[1] for i in intentional) for fr in frames):
                intent_n += 1
                continue
            if kind in LEAKS_THAT_FAIL or not kind.startswith("Leak_"):
                if mine:
                    ours_n += 1
                    bad.append((os.path.basename(xml_path), kind, err.findtext("what") or err.findtext("xwhat/text") or "", mine[:3]))
            else:
                leaks_n += 1
    print("  valgrind: %d report(s) in all, %d with a frame in our code, %d possible/other leak(s) ignored%s" % (total, ours_n, leaks_n, (", %d intentional" % intent_n) if intent_n else ""))
    for name, kind, what, fr in bad[:12]:
        print("    FAIL [%s] %s %s" % (name, kind, what))
        for obj, fn, f, ln in fr:
            print("         at %s (%s%s)" % (fn, os.path.basename(f) or os.path.basename(obj), (":" + ln) if ln else ""))
    return 1 if bad else 0


if __name__ == "__main__":
    a = sys.argv[1:]
    if not a or a[0] != "verdict":
        sys.exit(__doc__)
    ours, xmls, host_fn, intentional, i = [], [], [], [], 1
    while i < len(a):
        if a[i] == "--ours" and i + 1 < len(a):
            ours.append(a[i + 1]); i += 2
        elif a[i] == "--host-fn" and i + 1 < len(a):
            host_fn.append(a[i + 1]); i += 2
        elif a[i] == "--intentional-leak" and i + 1 < len(a):
            intentional.append(a[i + 1]); i += 2
        else:
            xmls.append(a[i]); i += 1
    if not ours or not xmls:
        sys.exit(__doc__)
    sys.exit(verdict(xmls, ours, host_fn, intentional))
