"""tests/_t2s_common.py — shared helpers for the fractalsql-sqlite test
suite (test_vector_*.py, test_vectorizer.py, test_text_to_sql_*.py).

SQLite configuration is per-connection state (fractalsql_set writes
straight into the extension's FsqlConfig), so it takes effect
immediately. reconnect() just closes and reopens a fresh connection,
which also resets config to defaults — sometimes exactly what a
scenario wants.
"""
import os
import sqlite3
import sys
import tempfile

# Extension binary: FRACTALSQL_EXT overrides; default walks the usual
# build outputs for this platform.
if sys.platform == "win32":
    _DEFAULT_EXT = os.path.join("build", "fractalsql.dll")
elif sys.platform == "darwin":
    _DEFAULT_EXT = os.path.join("build", "fractalsql.dylib")
else:
    _DEFAULT_EXT = os.path.join("build", "fractalsql.so")


def get_ext_path():
    return os.environ.get("FRACTALSQL_EXT", _DEFAULT_EXT)


def get_db_path():
    """SQLite database file. A persistent file (not :memory:) so the
    "fresh connection" scenarios — config reset, WAL recovery, stale
    reclaim — reconnect to the same database instead of a wiped one."""
    return os.environ.get("FRACTALSQL_DB",
                          os.path.join(tempfile.gettempdir(),
                                       "fractalsql_test.db"))


def get_reasoning_plugin_path():
    """Absolute path to the reasoning plugin fixture. Must be absolute —
    fractalsql_set('reasoning_plugin', ...) rejects relative paths
    (traversal hygiene, gate 09)."""
    p = os.environ.get("FRACTALSQL_REASONING_PLUGIN")
    if p:
        return os.path.abspath(p)
    suffix = ".dll" if sys.platform == "win32" else (
        ".dylib" if sys.platform == "darwin" else ".so")
    return os.path.abspath(os.path.join("build", "fractalsql-reasoning-http" + suffix))


def connect_or_skip(_dsn=None):
    """Open the test DB and load the extension. Returns None (SKIP) when
    the extension binary is missing — keeps the suite green before a
    build exists."""
    ext = get_ext_path()
    if not os.path.isfile(ext):
        print(f"SKIP: extension not built at {ext} (set FRACTALSQL_EXT)")
        return None
    try:
        conn = sqlite3.connect(get_db_path())
        conn.enable_load_extension(True)
        conn.load_extension(ext)
        conn.enable_load_extension(False)
    except Exception as e:
        print(f"SKIP: cannot load extension {ext}: {e}")
        try:
            conn.close()
        except Exception:
            pass
        return None
    conn.isolation_level = None          # autocommit; explicit BEGINs below
    return conn


def configure_reasoning(cur, plugin_path, http_url, model=None,
                        use_review=None, max_attempts=None,
                        allowed_statements=None,
                        embed_url=None, embed_model=None):
    """fractalsql_set() the reasoning config keys. Takes effect on this
    connection immediately — no reconnect needed."""
    cur.execute("SELECT fractalsql_set('reasoning_plugin', ?)", (plugin_path,))
    cur.execute("SELECT fractalsql_set('http_url', ?)", (http_url,))
    cur.execute("SELECT fractalsql_set('http_allow_plaintext', 'on')")
    if model is not None:
        cur.execute("SELECT fractalsql_set('http_model', ?)", (model,))
    if use_review is not None:
        cur.execute("SELECT fractalsql_set('text_to_sql_use_review', ?)",
                    ("on" if use_review else "off",))
    if max_attempts is not None:
        cur.execute("SELECT fractalsql_set('text_to_sql_max_attempts', ?)",
                    (str(int(max_attempts)),))
    if allowed_statements is not None:
        cur.execute("SELECT fractalsql_set('text_to_sql_allowed_statements', ?)",
                    (allowed_statements,))
    if embed_url is not None:
        cur.execute("SELECT fractalsql_set('http_embed_url', ?)", (embed_url,))
    if embed_model is not None:
        cur.execute("SELECT fractalsql_set('http_embed_model', ?)", (embed_model,))


def reconnect(conn, _dsn=None):
    """Close and reopen. NOTE: config is per-connection in SQLite, so a
    reconnect RESETS it to defaults — call configure_reasoning again on
    the new connection if the scenario needs it."""
    conn.close()
    return connect_or_skip()


# Re-exported here for other test modules to import directly.
from _mock_llm_server import MockEmbedServer  # noqa: E402