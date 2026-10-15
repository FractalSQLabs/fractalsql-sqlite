# mcp/Makefile mirrors the repo's own top-level Makefile conventions
# (plain Makefile, no CMake; one binary; vendored sources; no package
# manager). The binary links the repo's own vendored
# sqlite3 amalgamation (deps/sqlite/sqlite3.c), OpenSSL for the schema-lock
# SHA-256 + the optional HTTP transport's token store, and pthreads.
#
# NOTE: this repo's C extension does NOT link libsqlite3 (the host SQLite
# supplies its API table at load time); the MCP server is the opposite shape
# an ordinary process embedding libsqlite3, so it compiles the vendored
# amalgamation in directly, which is exactly how the engine's own binaries
# avoid a runtime sqlite3 dependency.
#
# Build:    make            (Linux/macOS; g++ or clang >= 11. On Windows,
#                            build through scripts\windows\build.bat with
#                            MSVC + vcpkg OpenSSL: MinGW GCC 13.x can
#                            exhaust memory compiling the vendored sqlite3
#                            amalgamation and the winsock2+json TUs.)
# Try it:   ./fractalsql-sqlite-mcp --list-tools
# Regenerate locks (after any tool-table change):
#   ./fractalsql-sqlite-mcp --write-schema-lock
#   ./fractalsql-sqlite-mcp --write-safety-annotations-lock
#   ./fractalsql-sqlite-mcp --write-manifest

CXX      ?= g++
CC       ?= gcc
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wextra
# Empty by default; a cross-arch build (e.g. package-darwin.sh building
# x86_64 on an Apple Silicon runner) passes CFLAGS="-arch x86_64" so the
# one plain-C translation unit (sqlite3.o) matches the C++ objects'
# -arch instead of silently compiling for the host architecture.
CFLAGS   ?=
DEFS     := -DFSQL_MCP_VERSION="\"2.0.6\""

# Coverage builds (build_test.sh --coverage): same posture as the
# top-level Makefile's own COVERAGE block: gcov instrumentation on
# both compile and link, appended (not replacing the caller's own
# -arch etc.) to both the C++ and C flags since the final link reuses
# CXXFLAGS directly and sqlite3.o is its own TU compiled with CFLAGS.
ifdef COVERAGE
  CXXFLAGS := $(CXXFLAGS) -O1 -g --coverage
  CFLAGS   := $(CFLAGS) -O1 -g --coverage
endif

SQLITE_DIR    := ../deps/sqlite
SQLITE_SRC    := $(SQLITE_DIR)/sqlite3.c
SQLITE_INC    := -I$(SQLITE_DIR)
SQLITE_CFLAGS := -DSQLITE_ENABLE_LOAD_EXTENSION=1 -DSQLITE_THREADSAFE=1 \
                 -DSQLITE_ENABLE_COLUMN_METADATA=1

SRC  := $(wildcard src/*.cpp) $(wildcard src/adapters/*.cpp)
# _WIN32-only TU; harmless to build on POSIX (the whole file is #if'd out)
# and simpler than conditional-compile plumbing in the Makefile.
OBJ  := $(SRC:.cpp=.o) sqlite3.o
# -ldl: sqlite3.c's own dlopen/dlclose/dlsym calls (extension loading).
# Harmless-but-required explicit link: glibc >= 2.34 (e.g. the modern
# profile's rockylinux:9) folds libdl into libc so this is a no-op
# there, but older glibc (e.g. the legacy profile's manylinux_2_28,
# glibc 2.28) still ships dlclose et al. in a separate libdl.so, and
# omitting -ldl there is an "undefined reference to dlclose" link
# failure, reproduced directly against that exact image.
LIBS := -lssl -lcrypto -lpthread -ldl
# Windows: the optional HTTP transport's socket layer. POSIX make/CI adds
# none of these and the code behind _WIN32 never references ws2_32.
ifeq ($(OS),Windows_NT)
  LIBS += -lws2_32
endif

BIN := fractalsql-sqlite-mcp

all: $(BIN)

$(BIN): $(OBJ)
	$(CXX) $(CXXFLAGS) -o $@ $(OBJ) $(LIBS)

%.o: %.cpp
	$(CXX) $(CXXFLAGS) $(DEFS) $(SQLITE_INC) -Ivendor -Isrc -MMD -MP -c $< -o $@

sqlite3.o: $(SQLITE_SRC)
	$(CC) -std=c99 -O2 -fPIC $(CFLAGS) $(SQLITE_CFLAGS) -MMD -MP -c $< -o $@

# Header dependency tracking: without this, a plain `make` after editing a
# header-only change (e.g. bumping kMcpPluginVersion in db.h, with no .cpp
# file's own mtime touched) silently relinks NOTHING -- the rule above only
# lists the .cpp as $(OBJ)'s prerequisite, so make sees every .o as already
# up to date and the existing (now-stale) binary is never rebuilt. The
# -MMD/-MP flags above emit a per-TU .d file recording its actual #include
# graph; pulling those in here is what makes a header edit alone correctly
# trigger a rebuild of every TU that includes it.
-include $(OBJ:.o=.d)

clean:
	rm -f src/*.o src/*.d src/adapters/*.o src/adapters/*.d deps/sqlite/sqlite3.o sqlite3.o sqlite3.d $(BIN)

.PHONY: all clean