%global extdir /usr/local/lib/sqlite3
%global docdir %{_docdir}/fractalsql-sqlite
%global mcpdocdir %{docdir}/mcp

Name:           fractalsql-sqlite
Version:        2.0.15
Release:        1%{?dist}
Summary:        Stochastic Fractal Search SQLite loadable extension (Community)

License:        Apache-2.0 AND BSD-2-Clause
URL:            https://github.com/FractalSQLabs/fractalsql-sqlite
Source0:        %{name}-%{version}.tar.gz

# gcc-c++ + openssl-devel build the bundled MCP server (mcp/Makefile):
# plain C++17 against the vendored sqlite3 amalgamation + OpenSSL, no
# per-arch vendored core archive involved (unlike fractalsql.so itself).
BuildRequires:  gcc, gcc-c++, make, sqlite-devel, openssl-devel, python3
Requires:       sqlite
Requires:       openssl-libs

BuildArch:      %{_arch}

%description
fractalsql-sqlite is a SQLite loadable extension exposing the full
FractalSQL 2.0 surface:

    fractal_edition()          -> 'Community'
    fractal_version()          -> '2.0.15'
    fractal_sfs_converge(vector, query) -> REAL (cosine distance to
                                          SFS-refined projection
                                          of the query vector)
    fractal_search_explore(emb, query)   -> TEXT (Scout-mode SFS aggregate)
    fractal_vector + 15 vector-math functions
    fractal_reason / fractal_text_to_sql / fractal_embed (sovereign,
        with the fractalsql-reasoning-http plugin configured)
    fractal_dimension_* / fractal_optimize_portfolio* (sovereign math)
    fractal_ledger_* / fractal_audit_* (QTL ledger)

Community Edition implements canonical Stochastic Fractal Search
(Salimi 2014) with Gaussian diffusion and greedy sniper selection.
Zero runtime dependencies beyond glibc: the vendored pure-C core
archive is statically linked (no LuaJIT, no libstdc++).

Load in any SQLite session:

    SELECT load_extension('/usr/local/lib/sqlite3/fractalsql');

Suitable for edge / serverless deployments (Vercel, AWS Lambda),
Turso / libSQL, Cloudflare D1 (where extensions are permitted),
React Native / Flutter mobile apps, and desktop SQLite usage.

%prep
%setup -q

%build
# The per-arch .so is produced out-of-band by build.sh on a Docker
# builder; this spec just stages it into the RPM.
test -f dist/%{_arch}/fractalsql.so
# The MCP server builds right here: it isn't cross-built per arch
# (no vendored core archive involved), just plain C++17 + the
# in-tree vendored sqlite3 amalgamation + this host's OpenSSL.
make -C mcp

%install
# /usr/local/lib/sqlite3 is not owned by any base package on RPM
# distros, so we create it and claim %dir ownership below.
install -d -m 0755 %{buildroot}%{extdir}
install -Dm0755 dist/%{_arch}/fractalsql.so \
    %{buildroot}%{extdir}/fractalsql.so
# Reasoning plugin ships when the vendored drop provides it for this
# platform (sovereign-tier reasoning/embedding support). Set
# -D"ship_reasoning_plugin 1" to match the %files conditional.
for plugin in include/linux-%{_arch}/fractalsql-reasoning-http.so ; do
    if [ -f "${plugin}" ]; then
        install -Dm0755 "${plugin}" \
            %{buildroot}%{extdir}/fractalsql-reasoning-http.so
        # The detached signature must sit beside the plugin or the host refuses it.
        install -Dm0644 "${plugin}.sig" \
            %{buildroot}%{extdir}/fractalsql-reasoning-http.so.sig
    fi
done
install -Dm0644 sql/load_extension.sql \
    %{buildroot}%{docdir}/load_extension.sql
install -Dm0644 sql/fractalsql--1.0.sql \
    %{buildroot}%{docdir}/fractalsql--1.0.sql
install -Dm0755 mcp/fractalsql-sqlite-mcp \
    %{buildroot}%{_bindir}/fractalsql-sqlite-mcp
install -Dm0644 mcp/README.md \
    %{buildroot}%{mcpdocdir}/README.md
install -Dm0644 mcp/RUN.txt \
    %{buildroot}%{mcpdocdir}/RUN.txt
install -Dm0644 mcp/.mcp-schema-lock \
    %{buildroot}%{_bindir}/.mcp-schema-lock
install -Dm0644 mcp/.mcp-safety-annotations-lock \
    %{buildroot}%{_bindir}/.mcp-safety-annotations-lock
install -Dm0644 mcp/manifest.json \
    %{buildroot}%{mcpdocdir}/manifest.json

%files
%license LICENSE
%license THIRD-PARTY-NOTICES.md
%dir %{extdir}
%{extdir}/fractalsql.so
%{docdir}/load_extension.sql
%{docdir}/fractalsql--1.0.sql
%{_bindir}/fractalsql-sqlite-mcp
%{mcpdocdir}/README.md
%{mcpdocdir}/RUN.txt
%{_bindir}/.mcp-schema-lock
%{_bindir}/.mcp-safety-annotations-lock
%{mcpdocdir}/manifest.json
%if 0%{?ship_reasoning_plugin}
# Set -D"ship_reasoning_plugin 1" when the vendored drop includes the
# plugin for this arch (scripts/package.sh stages it automatically for
# the fpm path).
%{extdir}/fractalsql-reasoning-http.so
%{extdir}/fractalsql-reasoning-http.so.sig
%endif

%post
cat <<'EOF'

fractalsql-sqlite Community installed.

Load inside any SQLite session:

    SELECT load_extension('/usr/local/lib/sqlite3/fractalsql');
    SELECT fractal_edition();   -- 'Community'
    SELECT fractal_version();   -- '2.0.15'

See /usr/share/doc/fractalsql-sqlite/load_extension.sql for examples.

EOF

%changelog
* Tue Nov 24 2026 FractalSQLabs - 2.0.15-1
- MCP server: 14 new vector tools, all in the existing Analytics tier -- the canonical vector type (fractal_vector, fractal_vector_from_text, fractal_vector_to_json) and the algebra (fractal_vector_add, _sub, _scale, _normalize, _norm, _dims, _cosine_distance, _cosine_similarity, _l2_distance, _l2_squared, _negative_inner_product).
- The MCP catalog is now 108 tools. Every vector tool is read-only, so an agent can call them without a write gate.
- Documentation: the indexed-search section explains what the index does and does not do, and the tool catalog and the demo's tool counts now match the shipped server.
- The SQLite extension itself is unchanged in this release.

* Sun Nov 22 2026 FractalSQLabs - 2.0.14-1
- Indexed vector search: fractal_index_create, _info, _list, _refresh, _rebuild, _drop, _ensure and _candidates build and maintain an IVF index (INT8, INT4, FP16 or FP32), and fractal_search(table, column, query, k) answers from it with exact, verified distances.
- Agents can search through the index: the agent_use_index setting (off, on or auto, with agent_index_min_rows) and a meta_filter option limit what the retrieval agents scan.
- Agent results now report source_row_ids, used_index and context_cut, and agent_context_row_bytes caps how much of each row reaches the model; the earlier source_doc_ids field is removed.
- Breaking: the two-argument fractal_search(vector, query) is now fractal_sfs_converge (its trace is fractal_sfs_converge_debug); the old call is refused with a message naming the new one.
- Long text: fractal_chunk_text splits text into character-offset chunks (fixed, paragraph or sentence), and a vectorizer can chunk and embed with chunk_size, chunk_overlap and chunk_mode.
- Distances (cosine, L2, inner product, norm) are bit-identical to a sequential double-precision reference across the scan, the index and the text round trip.
- With agent_partial_reasoning_fail on, an agent whose reasoning step fails returns the data it computed plus reasoning_step_failed instead of raising.
- Enterprise: the library's signature is now verified by default (set FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE=0 in the environment to opt out), and ledger_retention chooses fade (the default) or exact.
- MCP server: tools for the index tier and chunking, a stricter HTTP transport (lookalike origins and repeated headers refused, the /readyz probe cached), and a new mcp/RUN.txt quick-start.
- New demos (demo-chunking.sql, demo-fractal-index.sql), new benchmarks (index_head_to_head.py, precision_agreement.py) and an architecture diagram.
- The bundled FractalSQL core and reasoning plugin are refreshed for Linux, macOS and Windows.

* Fri Nov 13 2026 FractalSQLabs - 2.0.13-1
- Version bump to 2.0.13.

* Fri Nov 06 2026 FractalSQLabs - 2.0.12-1
- Text-to-SQL agents: generated SQL is only run when the caller asks
  (auto_execute is 0 by default). With it off the statement is generated
  and validated and returned in generated_sql; with it on it runs
  read-only, and the functions that change configuration, write to a
  table or call the reasoning endpoint refuse to run meanwhile.
- Safety: a reasoning plugin is verified (its detached signature)
  before it is loaded and again after; the plugin's bearer token is
  removed from the process environment once the load is over; retrieved
  rows are labelled as untrusted data when handed to the reasoner; the
  diversify/feedback functions are no longer marked innocuous, so views,
  triggers and CHECK constraints cannot call them; the audit text of an
  agent's question can be hashed or truncated (FSQL_AUDIT_REDACT).
- Work limits: long-running calls are bounded by the size of the job
  requested and return a clear error past it; integer arguments are
  clamped instead of wrapping to 32 bits; geometry functions refuse
  non-finite coordinates; the periodogram uses an FFT for long series;
  SimHash fingerprints are capped at 4 MiB.
- Audit ledger: the chain is capped by size (FSQL_LEDGER_MAX_ROWS) and its
  head can be published to a log outside the chain; each connection starts
  from the documented configuration defaults.
- MCP: authentication with a deployment token or a per-client token policy
  file; a missing schema or safety lock now stops startup; the HTTP
  transport refuses a non-loopback bind without TLS; config writes default
  to the safe set; new conformance and fuzz tests and Windows ASan/UBSan
  build scripts; the MCP documentation is rewritten with a settings
  reference.
- Release: SHA256SUMS is published for every release asset and
  easy_install.sh refuses a download whose checksum does not match; the
  Docker demo image is updated.

* Mon Oct 26 2026 FractalSQLabs - 2.0.11-1
- MCP: every tool now sends all four safety hints explicitly; read-only
  mode also latches the engine (fractal_lock_destructive). Destructive
  ledger functions are DIRECTONLY. 42 starter kits.

* Fri Oct 23 2026 FractalSQLabs - 2.0.10-1
- MCP safety annotations: fractal_agent_plan_explore is now marked
  open-world and fractal_agent_detect_loop read-only. Documentation
  correction for FSQL_MCP_READ_ONLY (blocks only the destructive tools).

* Thu Oct 15 2026 FractalSQLabs - 2.0.8-1
- Security and correctness hardening: fixed a ledger hash-chain bounds
  check, an uninitialized agent error buffer, a null-pointer path in
  reasoning dispatch, and injection/path-traversal hardening in the
  benchmark and demo CLI scripts.
- Fixed a broken .deb postinst script and TLS enforcement gaps across
  CI and install scripts (carried forward from 2.0.7's packaging fix).
- Internal refactor reducing code complexity across the engine and MCP
  server; no functional changes, verified against the full test suite.
* Thu Oct 15 2026 FractalSQLabs - 2.0.7-1
- Fixed broken .deb install and incorrect Linux package version labels.
* Wed Oct 14 2026 FractalSQLabs - 2.0.6-1
- MCP demo verified end to end: the four pinned demo tools round-trip
  against a live OpenAI-compatible endpoint; bootstrap snippet parsing
  fixed for dot-command-headed snippets; version assertions moved to 2.0.6.
* Tue Oct 13 2026 FractalSQLabs - 2.0.5-1
- Bundles the fractalsql-sqlite-mcp MCP server (stdio/HTTP JSON-RPC
  tool surface) alongside the extension, built from source against
  this host's OpenSSL.
* Mon Oct 12 2026 FractalSQLabs - 2.0.5-1
- Expanded test coverage: 12 domain agents, 9 vector-ops functions,
  enterprise mock, OOM injection, and a standalone Ed25519 unit test.
* Wed Sep 09 2026 FractalSQLabs - 2.0.4-1
- 2.x: pure-C multi-TU port on the vendored FractalSQL core drop;
  fractal_vector BLOB type, Scout-mode aggregate, sovereign-tier
  agents/dimension/portfolio/ledger surface (optional reasoning-http
  plugin), 27-gate validation harness. No LuaJIT, no libstdc++.
* Sun Apr 19 2026 FractalSQLabs - 1.0.0-1
- Community Edition: canonical SFS, static LuaJIT + libgcc +
  libstdc++. Legacy gcc4 C++ ABI for universal glibc compatibility.
  Install path moved to /usr/local/lib/sqlite3/. Verified on AMD64
  and ARM64.