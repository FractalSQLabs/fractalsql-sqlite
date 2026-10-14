# syntax=docker/dockerfile:1.7
#
# fractalsql-sqlite Factory build — pure-C multi-TU, vendored core drop.
#
# v2 layout: the vendored core lives in include/<os>-<arch>/ (deployed
# from core's `./scripts/deploy.sh --git fractalsql-sqlite`). This
# Dockerfile compiles every src/*.c translation unit against the
# platform archive. No LuaJIT stage, no source-from-git build, no
# libstdc++ — the extension is pure C11.
#
# Architecture: include/ ships linux-x86_64/ and linux-aarch64/ drops,
# so both buildx platforms build natively from the same context.
#
# SQLite itself provides its API via the sqlite3_api_routines pointer
# at load time, so there's no libsqlite3 linkage. Only sqlite3ext.h
# is needed at compile time.
#
# Usage:
#   DOCKER_BUILDKIT=1 docker buildx build \
#     --platform linux/amd64 \
#     --target export \
#     --output type=local,dest=./dist/amd64 \
#     -f docker/Dockerfile .

ARG BASE_IMAGE=rockylinux:9
ARG OUTPUT_SUFFIX=
ARG SIZE_CEILING_BYTES=3145728
ARG CORE_VARIANT=community-sovereign-c

# --------------------------------------------------------------------
# Stage: builder. SQLite headers + the vendored core archive only.
# --------------------------------------------------------------------
FROM ${BASE_IMAGE} AS builder
# Dispatch by package manager so the same Dockerfile builds against
# rockylinux:9 (modern), manylinux_2_28 (legacy), or alpine:3.20 (musl).
# Alpine's sqlite dev headers are in `sqlite-dev`; RHEL-family ships
# them as `sqlite-devel`. python3 powers the in-image smoke gate.
# g++ + openssl-dev/-devel build the bundled MCP server (mcp/Makefile)
# against each profile's OWN base image/glibc — not the packaging
# host's. That per-profile correctness is the entire reason the mcp
# build lives here rather than in scripts/package.sh: a host-built
# binary would carry the packaging runner's (newer) glibc floor
# regardless of which profile's package it ended up in, silently
# breaking the legacy profile's whole reason to exist.
#
# rockylinux:9 (dnf branch): the upstream rockylinux:9 image tag is a
# frozen snapshot (its baked-in glibc runtime predates current dnf
# mirrors). Rocky's mirror network can momentarily serve baseos and
# appstream repodata from two mirrors that aren't perfectly in sync —
# reproduced directly against this exact image across many builds
# here: the same install sometimes lands glibc (baseos) and
# glibc-devel (appstream) at two different point releases. When it
# does, g++ ends up emitting calls to glibc's ISO-C23 strtol symbol
# aliases (__isoc23_strtoull etc., real as of glibc 2.38+, and
# apparently present in SOME but not all glibc-devel point builds this
# repo's mirrors have served) that the mismatched libc.so.6 doesn't
# export — an "undefined reference" at link time for every
# nlohmann::json/strtol call site. `dnf update` first, then install,
# both with --allowerasing (this repo's existing remedy for the
# libcurl-minimal/libcurl conflict on EL images) narrows the window but
# does not close it outright — a self-test + `dnf distro-sync` retry
# loop below catches the rare case that still slips through, rather
# than hoping a particular dnf incantation never hits it again.
RUN if command -v apk >/dev/null 2>&1; then \
        apk add --no-cache build-base musl-dev binutils file \
            sqlite-dev python3 openssl-dev ; \
    elif command -v dnf >/dev/null 2>&1; then \
        dnf update -y --setopt=install_weak_deps=False --allowerasing --nobest \
        && dnf install -y --setopt=install_weak_deps=False --allowerasing --nobest \
            gcc gcc-c++ make binutils file sqlite-devel python3 openssl-devel \
        && dnf clean all \
        && for attempt in 1 2 3; do \
               printf '#include <cstdlib>\nint main(){ return (int)strtoull("1",0,10); }\n' > /tmp/glibc_check.cpp; \
               if g++ -std=c++17 -O2 -o /tmp/glibc_check /tmp/glibc_check.cpp 2>/tmp/glibc_check.err; then \
                   rm -f /tmp/glibc_check /tmp/glibc_check.cpp /tmp/glibc_check.err; \
                   break; \
               fi; \
               if [ "${attempt}" = "3" ]; then \
                   echo "ERROR: glibc/glibc-devel self-test still fails after ${attempt} dnf distro-sync attempts:" >&2; \
                   cat /tmp/glibc_check.err >&2; \
                   exit 1; \
               fi; \
               echo "glibc/glibc-devel mismatch detected (attempt ${attempt}); forcing dnf distro-sync and retrying" >&2; \
               dnf distro-sync -y --allowerasing --nobest glibc glibc-common glibc-devel glibc-headers; \
           done ; \
    else \
        yum update -y && yum install -y gcc gcc-c++ make binutils file sqlite-devel python3 openssl-devel ; \
    fi

ARG TARGETARCH
WORKDIR /build
COPY src/     /build/src/
COPY include/ /build/include/

ARG OUTPUT_SUFFIX
ARG SIZE_CEILING_BYTES
ARG CORE_VARIANT

# buildx TARGETARCH (amd64/arm64) -> vendored drop dir (x86_64/aarch64).
RUN case "${TARGETARCH}" in \
        amd64) echo linux-x86_64  > /platform.txt ;; \
        arm64) echo linux-aarch64 > /platform.txt ;; \
        *) echo "ERROR: unsupported TARGETARCH '${TARGETARCH}'" >&2; exit 1 ;; \
    esac

RUN test -f /build/include/$(cat /platform.txt)/libfractalsql-${CORE_VARIANT}.a \
    || (echo "ERROR: vendored core archive missing for $(cat /platform.txt): libfractalsql-${CORE_VARIANT}.a" >&2 \
        && echo "  Refresh from foundry:" >&2 \
        && echo "    cd ../fractalsql-core && make validated-drop-native && ./scripts/deploy.sh --git fractalsql-sqlite" >&2 \
        && exit 1)

# Sovereign variant -> compile the sovereign surface in (mirrors the
# Makefile). Minimal variants compile the sovereign-only TUs OUT — they
# reference core symbols only the sovereign archive exports (see the
# Makefile's SOVEREIGN_SRCS); the degraded surface surfaces those names
# as "no such function". grep -vxFf matches per line, so the exclude
# list must be one file per line, never space-separated.
RUN case "${CORE_VARIANT}" in \
        *sovereign*) echo "-DFSQL_SQLITE_SOVEREIGN" > /sovereign.txt; \
                     echo "src/*.c" > /src-glob.txt ;; \
        *)           echo "" > /sovereign.txt; \
                     printf '%s\n' \
                         src/fsql_reasoning.c src/fsql_t2s.c \
                         src/fsql_vectorizer.c src/fsql_agents.c \
                         src/fsql_domain_agents.c \
                         src/fsql_ledger.c src/fsql_sovereign.c \
                     > /src-exclude.txt ;; \
    esac

RUN set -eux; \
    if [ -f /src-exclude.txt ]; then \
        SRC=$(ls src/*.c | grep -vxFf /src-exclude.txt || true); \
    else \
        SRC=$(ls src/*.c); \
    fi; \
    test -n "${SRC}" || (echo "ERROR: no sources selected" >&2; exit 1); \
    gcc -std=c11 -Wall -Wextra -O3 -fPIC \
        -ffunction-sections -fdata-sections \
        -Iinclude -Isrc \
        $(cat /sovereign.txt) \
        -shared -o /fractalsql${OUTPUT_SUFFIX}.so \
        ${SRC} \
        /build/include/$(cat /platform.txt)/libfractalsql-${CORE_VARIANT}.a \
        -lm -ldl -lpthread \
        -Wl,--gc-sections -Wl,--strip-all -Wl,--exclude-libs,ALL; \
    SIZE=$(stat -c%s /fractalsql${OUTPUT_SUFFIX}.so); \
    if [ "${SIZE}" -gt "${SIZE_CEILING_BYTES}" ]; then \
        echo "ERROR: .so is ${SIZE} bytes, ceiling is ${SIZE_CEILING_BYTES}" >&2; \
        exit 1; \
    fi; \
    file /fractalsql${OUTPUT_SUFFIX}.so

# In-image smoke gate: load the freshly built extension into this
# image's Python sqlite3 and exercise the smoke surface. Replaces the
# v1 assert_so.sh binary-inspection pass with a live load. The load
# goes through a suffix-free copy: with no explicit entry point,
# SQLite derives one from the file name ("fractalsql-musl.so" would
# yield the wrong "sqlite3_fractalsqlmusl_init"), while "fractalsql"
# in any directory yields the real "sqlite3_fractalsql_init".
# (Unquoted heredoc so the shell expands OUTPUT_SUFFIX for the copy.)
RUN set -eux; \
    mkdir -p /smoke; \
    cp /fractalsql${OUTPUT_SUFFIX}.so /smoke/fractalsql.so; \
    python3 - <<EOF
import ctypes
import sqlite3
# Diagnose dlopen directly first: when sqlite3_load_extension fails,
# SQLite retries with ".so" appended and reports only that second
# failure ("fractalsql.so.so not found"), masking the real reason the
# original load failed. ctypes raises the loader's own error text.
try:
    ctypes.CDLL("/smoke/fractalsql.so")
except OSError as e:
    raise SystemExit("dlopen failed (real loader error): %s" % e)
conn = sqlite3.connect(":memory:")
conn.enable_load_extension(True)
conn.load_extension("/smoke/fractalsql.so")
conn.enable_load_extension(False)
cur = conn.cursor()
assert cur.execute("SELECT fractalsql_edition()").fetchone()[0] == "Community"
ver = cur.execute("SELECT fractalsql_version()").fetchone()[0]
assert ver.count(".") == 2, ver
d = cur.execute("SELECT fractal_search('0.6,0.8,0.0,0.0','0.6,0.8,0.0,0.0')").fetchone()[0]
assert abs(d) < 1e-6, d
print("smoke OK: Community %s, self-search dist=%r" % (ver, d))
EOF

# MCP server (mcp/fractalsql-sqlite-mcp) — built here, against this
# SAME profile's base image, so its glibc floor matches the .so above
# (rockylinux:9/glibc 2.34 for modern, manylinux_2_28/glibc 2.28 for
# legacy, alpine/musl for musl) rather than whatever the packaging
# host happens to run. One binary per profile, same as the .so.
# The amalgamation HEADER copies too (not just sqlite3.c): the
# minimal-profile demo stage installs no sqlite-devel, so without
# deps/sqlite/sqlite3.h the mcp Makefile's #include <sqlite3.h>
# resolves nowhere below (reproduced on the demo target).
COPY deps/sqlite/sqlite3.c /build/deps/sqlite/sqlite3.c
COPY deps/sqlite/sqlite3.h /build/deps/sqlite/sqlite3.h
COPY mcp/Makefile          /build/mcp/Makefile
COPY mcp/vendor/json.hpp   /build/mcp/vendor/json.hpp
COPY mcp/src/              /build/mcp/src/
# Belt-and-suspenders against .dockerignore not being honored for
# whatever reason (stale COPY cache, a build client that ignores it):
# a locally make'd .o — built against the HOST's glibc, not this
# image's — looks "already up to date" to `make` and gets linked in
# as-is rather than rebuilt, which is exactly how this reproduced
# "undefined reference to __isoc23_*" link failures in development
# (a host-built mcp/src/*.o riding along into a Rocky 9 build). Strip
# any object/binary that COPY might have carried over before building.
RUN find /build/mcp -name '*.o' -delete
RUN set -eux; \
    make -C /build/mcp; \
    strip /build/mcp/fractalsql-sqlite-mcp; \
    /build/mcp/fractalsql-sqlite-mcp --version; \
    mv /build/mcp/fractalsql-sqlite-mcp /fractalsql-sqlite-mcp${OUTPUT_SUFFIX}

# --------------------------------------------------------------------
# Export stage — scratch, so `buildx --output=local` drops the .so
# and the MCP server binary. OUTPUT_SUFFIX on BOTH filenames: modern/
# legacy/musl builds all land in the same dist/${arch}/ directory
# (install-test.yml and scripts/package.sh build every profile there
# in sequence), and a bare "fractalsql-sqlite-mcp" name would let a
# later profile's build silently overwrite an earlier profile's
# differently-glibc-targeted binary under the same filename.
# --------------------------------------------------------------------
FROM scratch AS export
ARG OUTPUT_SUFFIX
COPY --from=builder /fractalsql${OUTPUT_SUFFIX}.so /fractalsql${OUTPUT_SUFFIX}.so
COPY --from=builder /fractalsql-sqlite-mcp${OUTPUT_SUFFIX} /fractalsql-sqlite-mcp${OUTPUT_SUFFIX}

# --------------------------------------------------------------------
# Demo stage — a RUNNABLE sqlite3 CLI environment with the extension
# already staged and reasoning pre-configured, for docker-compose.yml.
# Every stage above this line only ever hands raw .so files to the host
# (buildx --output=local); this is the first stage in this file you can
# actually `docker run`.
#
# Same base image as the builder (rockylinux:9), so the extension .so's
# glibc is the image's own — no host extraction step at all, unlike the
# export path. Turnkey end-state for `docker compose up -d` (no flags):
#   * A long-lived container with sqlite3 + the fractalsql extension at
#     /usr/local/lib/sqlite3/fractalsql.so and the bundled reasoning
#     plugin beside it (vendored prebuilt .so from include/, selected by
#     uname -m).
#   * A demo database at /work/fractalsql_demo.sqlite (WAL mode,
#     persisted via the compose demo_data volume).
#   * The per-session bootstrap snippet (the easy_install.sh
#     load_fractalsql.sql equivalent: .load + fractalsql_set() lines)
#     written by demo-entrypoint.sh from FRACTALSQL_* env vars,
#     defaulting to the compose network's `ollama` service.
#   * Every demo in /demo/ and the bench/ head-to-head in /bench/ (with
#     its Python deps in /bench/.venv), runnable on demand. Demos are
#     NOT run at init: reasoning is inert until a model is pulled, and
#     the demos are re-runnable.
# The ollama compose service is up by default with NO model pulled
# (model download is user-initiated via the `pull-model` profile).
# Nothing calls the reasoning plugin unless a demo's cognition sections
# do, so a model-not-pulled state is a clear model-not-found error, not
# a broken install.
# --------------------------------------------------------------------
FROM ${BASE_IMAGE} AS demo
ARG OUTPUT_SUFFIX
# sqlite: the CLI the demos run in (distro builds ship .load-enabled).
# python3 + python3-pip: the bench/ head-to-head runs in-container via a
# venv (ensurepip ships with python3-pip, so the venv gets its own pip).
# libcurl: runtime dependency of the bundled reasoning plugin (dynamic
# link). Not needed for Sniper/Scout search on its own, but required
# once reasoning_plugin is set — and the bootstrap snippet sets it
# unconditionally. --allowerasing: the rockylinux:9 base image
# preinstalls libcurl-minimal, which conflicts with full libcurl; this
# swaps it for the full package (the dnf-documented remedy for exactly
# this conflict).
# gcc gcc-c++ make: the sqlite3-shell build below (the amalgamation
# needs a compiler and make; curl fetches it) and the MCP server binary
# build further down.
# openssl-devel: the MCP server binary links libssl/libcrypto — the
# schema-lock SHA-256 (10.5) and the optional HTTP transport (10.3) —
# and drags in the runtime openssl-libs half with it. The engine .so
# itself never links OpenSSL.
RUN dnf install -y --setopt=install_weak_deps=False --allowerasing \
        gcc gcc-c++ make curl sqlite python3 python3-pip libcurl \
        openssl-devel \
 && dnf clean all
# Rocky 9's `sqlite` package is 3.34.1 — too old for two things the demo
# corpus uses, and neither is fixable from an extension:
#   * the built-in math functions the fixtures call directly
#     (SQLITE_ENABLE_MATH_FUNCTIONS, SQLite >= 3.35),
#   * ORDER BY inside an aggregate (group_concat(x ORDER BY ...),
#     SQLite >= 3.44 — used throughout the demo fixtures and text-to-sql
#     spool patterns).
# (The extension itself registers only sin/sqrt/cos — see
# fractalsql_sqlite.c — so the demo fixtures stay self-contained on
# those hosts; a parser feature like aggregate ORDER BY is beyond that
# mechanism.) Build a current shell from the sqlite.org amalgamation
# into /usr/local/bin, which precedes /usr/bin in PATH. This also puts
# sqlite3_stmt_readonly()'s data-modifying-CTE handling (>= 3.35) in
# place for the text-to-sql allowlist demos. The extension .so is
# unaffected: it takes its SQLite API through the sqlite3_api_routines
# pointer of whatever host it loads into.
RUN set -eux; \
    SQLITE_VER=3450100; \
    curl -fsSL "https://www.sqlite.org/2024/sqlite-autoconf-${SQLITE_VER}.tar.gz" \
        -o /tmp/sqlite-autoconf.tgz; \
    tar -xzf /tmp/sqlite-autoconf.tgz -C /tmp; \
    cd "/tmp/sqlite-autoconf-${SQLITE_VER}"; \
    ./configure --prefix=/usr/local --disable-readline --disable-editline \
        CFLAGS="-O2 -DSQLITE_ENABLE_MATH_FUNCTIONS -DSQLITE_ENABLE_FTS5"; \
    make -j"$(nproc)" sqlite3; \
    cp sqlite3 /usr/local/bin/sqlite3; \
    /usr/local/bin/sqlite3 --version; \
    /usr/local/bin/sqlite3 ":memory:" \
        "SELECT cos(0), sin(0), sqrt(4);"; \
    /usr/local/bin/sqlite3 ":memory:" \
        "SELECT group_concat(v ORDER BY v) FROM (SELECT 2 AS v UNION SELECT 1);"; \
    rm -rf /tmp/sqlite-autoconf*

# MCP server binary (spec 14.7's demo simplification): the demo runs the
# PRODUCTION server — the same binary mcp/ builds, --tool-filtered by
# demo/mcp/call-tool.sh to the four pinned demo tools (9.3) — not a
# second, drifting demo implementation. Compiled here from the same
# sources the in-repo build uses (mcp/vendor/json.hpp + the vendored
# amalgamation), installed into /usr/local/bin (ahead of /usr/bin in
# PATH), build tree cleaned up so the image carries only binaries.
COPY deps/sqlite/sqlite3.c /mcpbuild/deps/sqlite/sqlite3.c
COPY deps/sqlite/sqlite3.h /mcpbuild/deps/sqlite/sqlite3.h
COPY mcp/Makefile          /mcpbuild/mcp/Makefile
COPY mcp/vendor/json.hpp   /mcpbuild/mcp/vendor/json.hpp
COPY mcp/src/              /mcpbuild/mcp/src/
# See the builder stage's identical step for why: a locally make'd .o
# riding along in the COPY looks up to date to `make` and gets linked
# in unrebuilt, mixing the host's glibc into this image's binary.
RUN find /mcpbuild/mcp -name '*.o' -delete
RUN set -eux; \
    make -C /mcpbuild/mcp; \
    strip /mcpbuild/mcp/fractalsql-sqlite-mcp; \
    mv /mcpbuild/mcp/fractalsql-sqlite-mcp /usr/local/bin/; \
    rm -rf /mcpbuild; \
    /usr/local/bin/fractalsql-sqlite-mcp --version
COPY --from=builder /fractalsql${OUTPUT_SUFFIX}.so /usr/local/lib/sqlite3/fractalsql.so
# Bundled reasoning plugin (vendored prebuilt .so from include/). include/
# carries the plugin for every supported platform (linux-x86_64,
# linux-aarch64, darwin-arm64, darwin-x86_64; windows-x86_64 ships a .dll
# via the MSI path, not used here). COPY both linux variants and select at
# build time — `uname -m` yields x86_64 / aarch64, matching the dir suffixes.
COPY include/linux-x86_64/fractalsql-reasoning-http.so  /usr/local/lib/sqlite3/fractalsql-reasoning-http.x86_64.so
COPY include/linux-aarch64/fractalsql-reasoning-http.so /usr/local/lib/sqlite3/fractalsql-reasoning-http.aarch64.so
RUN set -e \
 && ARCH=$(uname -m) \
 && mv "/usr/local/lib/sqlite3/fractalsql-reasoning-http.${ARCH}.so" \
        /usr/local/lib/sqlite3/fractalsql-reasoning-http.so \
 && rm -f /usr/local/lib/sqlite3/fractalsql-reasoning-http.*.so
# bench/ head-to-head benchmarks (sqlite-vec vs Scout). requirements.txt is
# COPYd first so the slow pip install layer-caches independently of bench
# source. The scripts take --ext/--db, so in-container runs point --ext at
# the staged .so and --db at a path under the persisted volume.
COPY bench/requirements.txt /bench/requirements.txt
RUN python3 -m venv /bench/.venv \
 && /bench/.venv/bin/pip install --quiet --upgrade pip \
 && /bench/.venv/bin/pip install --quiet -r /bench/requirements.txt \
 && rm -rf /root/.cache
COPY bench/ /bench/
# Every demo, runnable on demand via `sqlite3 -init demo_init.sql
# ".read /demo/<demo>.sql"`. Not run at init: reasoning is inert without
# a model, and the demos are re-runnable.
COPY demo/ /demo/
# Turnkey boot. demo-entrypoint.sh writes the per-session bootstrap
# snippet from FRACTALSQL_* env, creates the demo DB in WAL mode, prints
# the quick-start banner, then execs the service command (compose sets
# `sleep infinity` so the container stays up for `docker compose exec`).
COPY docker/demo-entrypoint.sh /usr/local/bin/demo-entrypoint.sh
RUN chmod +x /usr/local/bin/demo-entrypoint.sh
ENTRYPOINT ["/usr/local/bin/demo-entrypoint.sh"]