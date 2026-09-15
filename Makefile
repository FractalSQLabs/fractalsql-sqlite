# fractalsql-sqlite Makefile — local (non-Docker) development build.
#
# v2: pure-C multi-TU port. The extension statically links the vendored
# core archive at include/<platform>/libfractalsql-community-<variant>.a.
# No runtime LuaJIT dep, no pkg-config probe, no libstdc++.
#
# Refresh include/ from the foundry:
#     cd ../fractalsql-core
#     make validated-drop-native
#     ./scripts/deploy.sh --git fractalsql-sqlite
#
# Build:   make
#          make CORE_VARIANT=community-minimal-c   (degraded surface)
# Install: sudo make install
# Try it:  sqlite3 -cmd ".load ./fractalsql" \
#              -cmd "SELECT fractalsql_edition();"

CC ?= cc

# SQLite headers (sqlite3ext.h). A SQLite extension does NOT link
# against libsqlite3 — the host SQLite passes its API table via the
# sqlite3_api_routines pointer at load time. Headers only.
SQLITE_CFLAGS := $(shell pkg-config --cflags sqlite3 2>/dev/null)
ifeq ($(strip $(SQLITE_CFLAGS)),)
  SQLITE_CFLAGS := -I/usr/include
endif

# On macOS the probe above is a lottery: pkg-config cannot see Homebrew's
# keg-only sqlite, so it falls back to -I/usr/include, which does not
# exist on modern macOS, and the compiler then takes whichever sqlite3ext.h
# the toolchain search order hands it. Whichever header the macOS runners'
# default path resolves was observed to leave the sqlite3_* calls unrouted
# (every call landed in the link as an external reference and ld64 refused
# the dylib), while the release packaging script's explicit brew include
# path builds and loads cleanly on the same runners. So on Darwin pin the
# headers to that proven path; dev Macs without brew keep the generic
# probe's behavior.
ifeq ($(shell uname -s),Darwin)
  BREW_SQLITE_INC := $(shell brew --prefix sqlite 2>/dev/null)/include
  ifneq ($(wildcard $(BREW_SQLITE_INC)/sqlite3ext.h),)
    SQLITE_CFLAGS := -I$(BREW_SQLITE_INC)
  endif
endif

# Vendored core archive selector. Sovereign is the 2.x default — the
# docs/demos/agents surface requires it. `community-minimal-c` stays
# buildable: the sovereign-only TUs are compiled out (see SRCS below)
# and their function names then surface as SQLite "no such function"
# errors; the smoke surface is unaffected.
# Override to `community-minimal-c-musl` / `community-sovereign-c-musl`
# for Alpine (musl) hosts.
CORE_VARIANT ?= community-sovereign-c

# Platform layout: include/<os>-<arch>/ (os = uname -s lower-cased,
# arch = uname -m / arm64 on Apple Silicon).
FSQL_PLATFORM := $(shell uname -s | tr '[:upper:]' '[:lower:]')-$(shell uname -m)
CORE_ARCHIVE  := include/$(FSQL_PLATFORM)/libfractalsql-$(CORE_VARIANT).a

# Sovereign archive -> compile the sovereign surface in.
ifeq ($(findstring sovereign,$(CORE_VARIANT)),sovereign)
  SOVEREIGN_DEFINE := -DFSQL_SQLITE_SOVEREIGN
else
  SOVEREIGN_DEFINE :=
endif

CFLAGS = -std=c11 -O3 -fPIC \
         -ffunction-sections -fdata-sections \
         -Wall -Wextra \
         $(SOVEREIGN_DEFINE) \
         $(SQLITE_CFLAGS) -Iinclude -Isrc

# -fvisibility=hidden is deliberately NOT set — sqlite3_fractalsql_init
# must stay in .dynsym so SQLite's loader can dlsym it. Size pressure
# is handled by --gc-sections + --strip-all + --exclude-libs,ALL.
#
# Link flags are dialect-aware: GNU ld (Linux) and ld64 (Darwin) speak
# different dialects, and `make` runs on both (release/CI builds on
# Linux; build_test.sh's gate 01 on macOS). ld64's equivalent of
# --gc-sections is -dead_strip. -undefined dynamic_lookup restores the
# ELF branch's resolve-at-dlopen semantics: GNU ld permits unresolved
# external references in a shared object (the host's SQLite answers them
# at load time), while ld64 refuses to emit a dylib containing any — and
# one unrouted sqlite3_* call (a header the compile picked up without
# the API-table redirections) would otherwise fail the whole gate on
# exactly that.
ifeq ($(shell uname -s),Darwin)
LDFLAGS  = -dynamiclib \
           -Wl,-dead_strip \
           -Wl,-undefined,dynamic_lookup \
           -lm -ldl -lpthread
else
LDFLAGS  = -shared \
           -Wl,--gc-sections -Wl,--strip-all \
           -Wl,--exclude-libs,ALL \
           -lm -ldl -lpthread
endif

# Sanitizer builds (build_test.sh --asan / --ubsan / --tsan): the flags
# ride into BOTH the compile and the link (the extension is a shared
# object, so the sanitizer runtime is expected at load time — run the
# sanitized artifact with the runtime preloaded, which build_test.sh
# arranges on Linux and Darwin; see its --asan/--ubsan/--tsan note).
# ASAN=1 / UBSAN=1 compose freely; TSAN=1 composes with UBSAN=1 but
# NOT with ASAN=1 -- ASan and TSan instrument memory access and
# synchronization the same way (shadow-memory interceptors) and their
# runtimes cannot coexist in one binary; the compiler rejects it.
SANITIZE =
ifeq ($(ASAN),1)
  SANITIZE += -fsanitize=address
endif
ifeq ($(UBSAN),1)
  SANITIZE += -fsanitize=undefined
endif
ifeq ($(TSAN),1)
  ifeq ($(ASAN),1)
    $(error TSAN=1 cannot be combined with ASAN=1 -- their runtimes cannot link into the same binary; build_test.sh already rejects --asan --tsan before invoking make)
  endif
  SANITIZE += -fsanitize=thread
endif
ifneq ($(strip $(SANITIZE)),)
  CFLAGS  := $(CFLAGS) -O1 -g -fno-omit-frame-pointer $(SANITIZE)
  LDFLAGS := $(LDFLAGS) $(SANITIZE)
endif

# Coverage builds (build_test.sh --coverage): gcov instrumentation on
# both compile and link, profile-guided-optimization-style settings
# (-O1, no LTO, frame pointers kept) so the counters reflect the code
# as written. build_test.sh captures the resulting .gcda with lcov and
# renders coverage_html/. Note this leaves the instrumented
# fractalsql.so in the tree -- it is NOT the artifact you'd want to
# install or ship; `make clean && make` after a coverage run restores
# the normal build. (clean doesn't remove src/*.gcda; build_test.sh
# clears those itself at the start of a coverage run.)
ifdef COVERAGE
  CFLAGS  := $(CFLAGS) -O1 -g --coverage
  LDFLAGS := $(LDFLAGS) --coverage
endif

TARGET = fractalsql.so

# Sovereign-only TUs: compiled out of the minimal link (they reference
# core symbols that only the sovereign archive exports — keeping them in
# would break the minimal build at link time, not degrade gracefully).
# On a minimal build the sovereign names then surface as SQLite
# "no such function" errors; the smoke surface (edition/version/search)
# is unaffected. See the TU map in src/fsql_sqlite_internal.h.
SOVEREIGN_SRCS := src/fsql_reasoning.c src/fsql_t2s.c \
                  src/fsql_vectorizer.c src/fsql_agents.c \
                  src/fsql_domain_agents.c \
                  src/fsql_ledger.c src/fsql_sovereign.c

ifeq ($(findstring sovereign,$(CORE_VARIANT)),sovereign)
  SRCS   = $(wildcard src/*.c)
else
  SRCS   = $(filter-out $(SOVEREIGN_SRCS),$(wildcard src/*.c))
endif
OBJS   = $(SRCS:.c=.o)

all: verify-vendor $(TARGET)

# Verify vendored archive present BEFORE compile — clearer failure than
# a confusing linker error.
$(CORE_ARCHIVE):
	@echo "ERROR: $(CORE_ARCHIVE) missing." >&2
	@echo "  Refresh from foundry:" >&2
	@echo "    cd ../fractalsql-core && make validated-drop-native && ./scripts/deploy.sh --git fractalsql-sqlite" >&2
	@exit 1


# Supply-chain verification (B5). The vendored archive is dropped
# from fractalsql-core's deploy.sh together with `.artifacts.sha256`
# (sha256sum of every shipped .h/.a/.so). Verify it matches the
# bytes on disk before linking — catches a tampered .a in this
# repo's include/ at build time, both in `make` and in CI.
# GNU coreutils' sha256sum when present, macOS's Perl shasum
# otherwise; both consume the same "hash  ./path" manifest format.
.PHONY: verify-vendor
verify-vendor:
	@if [ ! -f include/.artifacts.sha256 ]; then \
		echo "ERROR: include/.artifacts.sha256 missing — re-deploy from core" >&2; \
		echo "  cd ../fractalsql-core && make validated-drop-native && ./scripts/deploy.sh --git fractalsql-sqlite" >&2; \
		exit 1; \
	fi
	@cd include && { \
		if command -v sha256sum >/dev/null 2>&1; then \
			sha256sum --quiet --check .artifacts.sha256; \
		else \
			shasum -a 256 -c .artifacts.sha256 >/dev/null; \
		fi; \
	} || { \
		echo "ERROR: vendored artifact checksum mismatch in include/." >&2; \
		echo "  Possible causes: tampered .a/.so, partial deploy, stale .sha256," >&2; \
		echo "  or no sha256 tool on PATH (needs coreutils sha256sum or shasum)." >&2; \
		echo "  Re-deploy from core to recover." >&2; \
		exit 1; \
	}

$(TARGET): $(OBJS) $(CORE_ARCHIVE) verify-vendor
	$(CC) -o $@ $(OBJS) $(CORE_ARCHIVE) $(LDFLAGS)

%.o: %.c include/fractalsql.h include/fractalsql_sql.h src/fsql_sqlite_internal.h
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	rm -f $(OBJS) $(TARGET) tsan_ledger_runner

install: $(TARGET)
	install -Dm0755 $(TARGET) /usr/local/lib/sqlite3/fractalsql.so

# bench/ needs `pip install -r bench/requirements.txt` first (numpy +
# sqlite-vec). See bench/README.md.
bench: $(TARGET)
	python3 bench/data_gen.py
	python3 bench/head_to_head.py

bench-vector: $(TARGET)
	python3 bench/data_gen.py --with-fractal-vector
	python3 bench/vector_type_head_to_head.py

# build_test.sh --tsan gate 33 driver. Always -fsanitize=thread,
# unconditionally -- this binary has exactly one purpose (see its own
# header comment for why it links libsqlite3 + dlopens fractalsql.so
# directly, instead of the LD_PRELOAD/DYLD_INSERT_LIBRARIES approach
# the other gates use). Portable across Linux and Darwin unmodified:
# both have -lsqlite3 + pthreads, and -fsanitize=thread needs no
# preload trick when it's compiled into the binary from the start.
tsan-ledger-runner: tsan_ledger_runner

tsan_ledger_runner: tests/tsan_ledger_runner.c
	$(CC) -std=c11 -O1 -g -fno-omit-frame-pointer -fsanitize=thread \
	      $(SQLITE_CFLAGS) -Iinclude -Isrc \
	      -o tsan_ledger_runner tests/tsan_ledger_runner.c \
	      -lsqlite3 -ldl -lpthread

.PHONY: all clean install verify-vendor tsan-ledger-runner bench bench-vector