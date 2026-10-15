%global extdir /usr/local/lib/sqlite3
%global docdir %{_docdir}/fractalsql-sqlite
%global mcpdocdir %{docdir}/mcp

Name:           fractalsql-sqlite
Version:        2.0.7
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

    fractalsql_edition()          -> 'Community'
    fractalsql_version()          -> '2.0.7'
    fractal_search(vector, query) -> REAL (cosine distance to
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
install -Dm0644 mcp/.mcp-schema-lock \
    %{buildroot}%{mcpdocdir}/.mcp-schema-lock
install -Dm0644 mcp/.mcp-safety-annotations-lock \
    %{buildroot}%{mcpdocdir}/.mcp-safety-annotations-lock
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
%{mcpdocdir}/.mcp-schema-lock
%{mcpdocdir}/.mcp-safety-annotations-lock
%{mcpdocdir}/manifest.json
%if 0%{?ship_reasoning_plugin}
# Set -D"ship_reasoning_plugin 1" when the vendored drop includes the
# plugin for this arch (scripts/package.sh stages it automatically for
# the fpm path).
%{extdir}/fractalsql-reasoning-http.so
%endif

%post
cat <<'EOF'

fractalsql-sqlite Community installed.

Load inside any SQLite session:

    SELECT load_extension('/usr/local/lib/sqlite3/fractalsql');
    SELECT fractalsql_edition();   -- 'Community'
    SELECT fractalsql_version();   -- '2.0.7'

See /usr/share/doc/fractalsql-sqlite/load_extension.sql for examples.

EOF

%changelog
* Wed Oct 15 2026 FractalSQLabs - 2.0.7-1
- Fixed broken .deb install and incorrect Linux package version labels.
* Tue Oct 14 2026 FractalSQLabs - 2.0.6-1
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