#!/bin/bash
#
# scripts/package-darwin.sh — macOS dylib build + tarball packaging.
#
# macOS has no native package format for SQLite extensions, so we ship
# a self-contained per-arch tarball: the loadable dylib, the reasoning
# plugin, and the load instructions. easy_install.sh downloads exactly
# this artifact (fractalsql-sqlite-<version>-darwin-<arch>.tar.gz) and
# installs the dylib into /usr/local/lib/sqlite3/.
#
# The extension builds natively with clang against the vendored darwin
# core archive (include/darwin-<arch>/libfractalsql-community-sovereign-c.a),
# statically linked — same posture as the Linux .so and the Windows DLL:
# zero runtime deps beyond libSystem. arm64 builds native; x86_64 can be
# cross-built on an Apple Silicon host via FSQL_DARWIN_ARCH.
#
# Usage:
#   ./scripts/package-darwin.sh
#   FSQL_DARWIN_ARCH=x86_64 ./scripts/package-darwin.sh   # cross build
#
# Env:
#   FSQL_PKG_VERSION  pin the version stamped into the artifact name
#                     (release.yml passes the git tag); otherwise derived
#                     from src/fsql_sqlite_internal.h.
#   SQLITE_PREFIX     Homebrew sqlite prefix (headers for sqlite3ext.h);
#                     default: $(brew --prefix sqlite).

set -euo pipefail

# Same single-source-of-truth pattern as package.sh: derive from
# FSQL_SQLITE_VERSION_STR rather than hardcoding a copy that can drift
# out of sync with what fractalsql_version() actually returns.
VERSION="${FSQL_PKG_VERSION:-$(sed -n 's/^#define FSQL_SQLITE_VERSION_STR   "\(.*\)"$/\1/p' src/fsql_sqlite_internal.h)}"
[[ -n "${VERSION}" ]] || { echo "could not determine VERSION (FSQL_SQLITE_VERSION_STR not found in src/fsql_sqlite_internal.h)" >&2; exit 1; }

ARCH="${FSQL_DARWIN_ARCH:-$(uname -m)}"   # arm64 | x86_64
case "${ARCH}" in
    arm64|x86_64) ;;
    *) echo "unknown arch '${ARCH}' — expected arm64 or x86_64" >&2; exit 2 ;;
esac

FSQL_PLATFORM="darwin-${ARCH}"
CORE_A="include/${FSQL_PLATFORM}/libfractalsql-community-sovereign-c.a"
REASONING_SO="include/${FSQL_PLATFORM}/fractalsql-reasoning-http.so"
for f in src/*.c "${CORE_A}" "${REASONING_SO}" \
         LICENSE THIRD-PARTY-NOTICES.md sql/fractalsql--1.0.sql; do
    [[ -e "${f}" ]] \
        || { echo "missing ${f} — re-run the vendored-artifact deploy step" >&2; exit 1; }
done

if [[ -z "${SQLITE_PREFIX:-}" ]]; then
    SQLITE_PREFIX="$(brew --prefix sqlite 2>/dev/null || echo /usr/local)"
fi
[[ -f "${SQLITE_PREFIX}/include/sqlite3ext.h" ]] \
    || { echo "sqlite3ext.h not found under ${SQLITE_PREFIX}/include (set SQLITE_PREFIX)" >&2; exit 1; }

echo "== building fractalsql.dylib for darwin-${ARCH} (core: community-sovereign-c) =="
# Static archive link: the archive must come after the objects (single
# pass ld). -DFSQL_STATIC matches the vendored-core linkage contract;
# -DFSQL_SQLITE_SOVEREIGN compiles the sovereign surface in, mirroring
# the Makefile. No -fvisibility=hidden — sqlite3_fractalsql_init must
# stay exported for SQLite's loader.
#
# -arch is not optional: both release legs run on the arm64 macos-14
# image, and without it clang targets the host (arm64) even on the
# x86_64 leg — arm64 objects against the x86_64 vendored archive make
# ld silently skip every archive member, so all core symbols go
# undefined ("symbol(s) not found for architecture arm64" in the
# x86_64 job).
clang -std=c11 -O3 -fPIC \
    -arch "${ARCH}" \
    -ffunction-sections -fdata-sections \
    -Wall -Wextra \
    -DFSQL_SQLITE_SOVEREIGN -DFSQL_STATIC \
    -I"${SQLITE_PREFIX}/include" -Iinclude -Isrc \
    -dynamiclib \
    -Wl,-dead_strip \
    -o fractalsql.dylib \
    src/*.c \
    "${CORE_A}" \
    -lm

test -f fractalsql.dylib || { echo "build did not produce fractalsql.dylib" >&2; exit 1; }
# Assert the output really is ${ARCH} — the -arch flag above is what
# makes this true, and a silent host-arch fallback would otherwise only
# surface as undefined symbols (or, for the native leg, not at all).
lipo -info fractalsql.dylib | grep -q "${ARCH}" \
    || { echo "dylib is not ${ARCH}: $(lipo -info fractalsql.dylib)" >&2; exit 1; }

PKG="fractalsql-sqlite-${VERSION}-darwin-${ARCH}"
DIST="dist/packages"
WORK="$(mktemp -d)"
STAGE="${WORK}/${PKG}"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${STAGE}" "${DIST}"

install -m 0755 fractalsql.dylib              "${STAGE}/fractalsql.dylib"
install -m 0755 "${REASONING_SO}"             "${STAGE}/fractalsql-reasoning-http.so"
install -m 0644 LICENSE                       "${STAGE}/LICENSE"
install -m 0644 THIRD-PARTY-NOTICES.md        "${STAGE}/THIRD-PARTY-NOTICES.md"
install -m 0644 sql/fractalsql--1.0.sql       "${STAGE}/fractalsql--1.0.sql"

cat > "${STAGE}/README.txt" <<EOF
FractalSQL for SQLite (Community) ${VERSION} — macOS ${ARCH}

Install:
  mkdir -p /usr/local/lib/sqlite3
  cp fractalsql.dylib /usr/local/lib/sqlite3/
  cp fractalsql-reasoning-http.so /usr/local/lib/sqlite3/

  Unsigned release: clear Gatekeeper quarantine once after extraction
  (required for binaries downloaded from GitHub Releases):
      xattr -d com.apple.quarantine /usr/local/lib/sqlite3/fractalsql.dylib
      xattr -d com.apple.quarantine /usr/local/lib/sqlite3/fractalsql-reasoning-http.so

Load in sqlite3:
  sqlite3 mydb.sqlite
  sqlite> .load /usr/local/lib/sqlite3/fractalsql
  sqlite> SELECT fractalsql_edition(), fractalsql_version();

Reasoning is opt-in. Point fractalsql_set('reasoning_plugin', ...) at
fractalsql-reasoning-http.so and configure an endpoint — see
docs/reasoning-setup.md. See fractalsql--1.0.sql for the full
function-surface reference.
EOF

TARBALL="${DIST}/${PKG}.tar.gz"
tar -C "${WORK}" -czf "${TARBALL}" "${PKG}"

echo "== wrote ${TARBALL} =="
ls -l "${TARBALL}"