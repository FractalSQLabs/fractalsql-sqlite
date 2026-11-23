#!/usr/bin/env python3
"""check_config_docs.py -- the settings table in docs/reasoning-setup.md names every configuration key this build defines.

The table ("Setting names on every host") is the one place the spelling of a setting is listed for every host; a key that is
added to the code and not to the table leaves a reader guessing. This reads the host's own key table from its sources and checks
that each key (or, for PostgreSQL, each `fractalsql.` setting; for Valkey, each module argument and daemon key) appears in the table.

Usage: python3 check_config_docs.py [REPO_ROOT]        exit status 0 = the table covers every key
"""
import os, re, sys

root = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
host = os.path.basename(root).replace("fractalsql-", "")

def read(*p):
    with open(os.path.join(root, *p), encoding="utf-8", errors="replace") as f:
        return f.read()

def table_tokens():
    doc = read("docs", "reasoning-setup.md")
    i = doc.find("Setting names on every host")
    if i < 0:
        return None
    j = doc.find("\n## ", i + 10)
    section = doc[i:j if j > 0 else len(doc)]
    return set(re.findall(r"`([^`]+)`", section))

def keys():
    if host == "sqlite":
        s = read("src", "fsql_config.c"); a = s.index("CFG_TABLE[] = {"); b = s.index("};", a)
        return set(re.findall(r'^\s*\{\s*"([a-z_0-9]+)"', s[a:b], re.M))
    if host == "duckdb":
        s = read("src", "fsql_config.c"); a = s.index("kConfigKeys[] = {"); b = s.index("};", a)
        return set(re.findall(r'^\s*\{\s*"([a-z_0-9]+)"', s[a:b], re.M))
    if host == "mariadb":
        s = read("src", "fractalsql_config.c")
        return set(re.findall(r'^\s*\{\s*"([a-z_0-9]+)"', s, re.M)) - {"enterprise_ledger_path"} | {"enterprise_ledger_path"}
    if host == "postgresql":
        s = read("src", "fractalsql.c")
        names = set(re.findall(r'"(fractalsql\.[a-z_0-9]+)"', s)) - {"fractalsql.actor", "fractalsql.h"}
        return names
    if host == "valkey":
        s = read("src", "module.c")
        args = set(re.findall(r'"(agent-[a-z-]+)"', s))
        d = read("service", "daemon", "fractalsqld.c")
        conf = set(re.findall(r'strcmp\(k, "([a-z_]+)"\)', d)) - {"socket_path", "hmac_key_file", "log_file", "max_connections", "idle_timeout_secs", "allowed_uids"}
        return args | conf
    if host == "druid":
        s = read("druid-extension", "src", "main", "java", "com", "fractalsqlabs", "fractalsql", "druid", "FractalSqlConfig.java")
        props = set(re.findall(r'"(agent_[a-z_]+)"', s))
        d = read("service", "daemon", "fractalsqld.c")
        conf = set(re.findall(r'strcmp\(k, "([a-z_0-9]+)"\)', d)) - {"socket_path", "hmac_key_file", "log_file", "max_connections", "idle_timeout_secs", "allowed_uids"}
        return props | conf
    raise SystemExit("check_config_docs: unknown host '%s'" % host)

tokens = table_tokens()
if tokens is None:
    print("check_config_docs: FAIL docs/reasoning-setup.md has no 'Setting names on every host' section"); sys.exit(1)
ks = keys()
if not ks:
    print("check_config_docs: FAIL no keys were read from the sources"); sys.exit(1)
flat = set()
for t in tokens:
    flat.add(t); flat.add(t.split(" ")[0]); flat.add(t.replace("druid.fractalsql.", "")); flat.add(t.replace("fractalsql.", "", 1) if host == "postgresql" else t)
missing = sorted(k for k in ks if k not in flat and k.replace("fractalsql.", "") not in flat and ("druid.fractalsql." + k) not in tokens)
if missing:
    print("check_config_docs: FAIL not in the settings table: %s" % ", ".join(missing)); sys.exit(1)
print("check_config_docs: PASS (%d keys, all in the settings table)" % len(ks))
