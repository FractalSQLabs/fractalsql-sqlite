%global extdir /usr/local/lib/sqlite3
%global docdir %{_docdir}/fractalsql-sqlite

Name:           fractalsql-sqlite
Version:        2.0.0
Release:        1%{?dist}
Summary:        Stochastic Fractal Search SQLite loadable extension (Community)

License:        Apache-2.0 AND BSD-2-Clause
URL:            https://github.com/FractalSQLabs/fractalsql-sqlite
Source0:        %{name}-%{version}.tar.gz

BuildRequires:  gcc, make, sqlite-devel, python3
Requires:       sqlite

BuildArch:      %{_arch}

%description
fractalsql-sqlite is a SQLite loadable extension exposing the full
FractalSQL 2.0 surface:

    fractalsql_edition()          -> 'Community'
    fractalsql_version()          -> '2.0.0'
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

%files
%license LICENSE
%license THIRD-PARTY-NOTICES.md
%dir %{extdir}
%{extdir}/fractalsql.so
%{docdir}/load_extension.sql
%{docdir}/fractalsql--1.0.sql
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
    SELECT fractalsql_version();   -- '2.0.0'

See /usr/share/doc/fractalsql-sqlite/load_extension.sql for examples.

EOF

%changelog
* Wed Sep 09 2026 FractalSQLabs - 2.0.0-1
- 2.x: pure-C multi-TU port on the vendored FractalSQL core drop;
  fractal_vector BLOB type, Scout-mode aggregate, sovereign-tier
  agents/dimension/portfolio/ledger surface (optional reasoning-http
  plugin), 27-gate validation harness. No LuaJIT, no libstdc++.
* Sun Apr 19 2026 FractalSQLabs - 1.0.0-1
- Community Edition: canonical SFS, static LuaJIT + libgcc +
  libstdc++. Legacy gcc4 C++ ABI for universal glibc compatibility.
  Install path moved to /usr/local/lib/sqlite3/. Verified on AMD64
  and ARM64.