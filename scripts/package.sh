#!/usr/bin/env bash
#
# scripts/package.sh — interactive-ready packaging pipeline.
#
# What it does
#   Linux: builds fractalsql.deb + fractalsql.rpm from dist/${arch}/
#          fractalsql.so (already produced by ../build.sh). Install
#          target path is /usr/local/lib/sqlite3/fractalsql.so per
#          the v2.0.0 Community brief. The fractalsql-reasoning-http
#          plugin is shipped alongside when present (sovereign-tier
#          reasoning/embedding support).
#
#   Windows: on a Linux / macOS host the MSI step is skipped with a
#          pointer to scripts/windows/build.bat + build-msi.bat. The
#          MSI is built by the CI's Windows matrix entry, not here.
#
# Usage
#   scripts/package.sh [amd64|arm64]     (default: amd64)
#
# Output
#   dist/packages/sqlite3-fractalsql-<arch>.deb
#   dist/packages/sqlite3-fractalsql-<arch>.rpm
#   dist/packages/fractalsql-sqlite-linux-<arch>.zip
#     (pure artifact for embedders who don't want a system install)

set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="2.0.0"
ITERATION="1"
DIST_DIR="dist/packages"
mkdir -p "${DIST_DIR}"

# PROFILE selector — picks which build.sh artifact to package.
#   modern (default)  → sqlite{3,}-fractalsql,        libc6 >= 2.34, .deb+.rpm+.zip
#   legacy            → sqlite{3,}-fractalsql-legacy, libc6 >= 2.28, .deb+.rpm+.zip
#   musl              → fractalsql-sqlite-musl,       apk + .zip (Alpine)
PROFILE="${PROFILE:-modern}"
case "${PROFILE}" in
    modern) PKG_SUFFIX="" ; BIN_SUFFIX="" ; GLIBC_DEP="2.34" ;;
    legacy) PKG_SUFFIX="-legacy" ; BIN_SUFFIX="-legacy" ; GLIBC_DEP="2.28" ;;
    musl)   PKG_SUFFIX="-musl"   ; BIN_SUFFIX="-musl"   ; GLIBC_DEP="" ;;
    *) echo "unknown profile '${PROFILE}' — expected modern, legacy, or musl" >&2; exit 2 ;;
esac

PKG_ARCH="${1:-amd64}"
case "${PKG_ARCH}" in
    amd64|arm64) ;;
    *)
        echo "unknown arch '${PKG_ARCH}' — expected amd64 or arm64" >&2
        exit 2
        ;;
esac

case "${PKG_ARCH}" in
    amd64) RPM_ARCH="x86_64" ;;
    arm64) RPM_ARCH="aarch64" ;;
esac

SO="dist/${PKG_ARCH}/fractalsql${BIN_SUFFIX}.so"
if [[ ! -f "${SO}" ]]; then
    echo "missing ${SO} — run ./build.sh ${PKG_ARCH} --profile=${PROFILE} first" >&2
    exit 1
fi

# Reasoning plugin (sovereign tier) — shipped when the vendored drop
# provides it for this platform. Optional: a build without it still
# exposes the full non-reasoning surface.
PLUGIN_SRC="include/linux-${RPM_ARCH}/fractalsql-reasoning-http.so"
HAVE_PLUGIN=0
if [[ -f "${PLUGIN_SRC}" ]]; then HAVE_PLUGIN=1; fi

# ---------------------------------------------------------------------
# Zip (embedders, Vercel edge, Turso, Lambda layers, mobile).
# ---------------------------------------------------------------------
ZIP_OUT="${DIST_DIR}/fractalsql-sqlite${PKG_SUFFIX}-linux-${PKG_ARCH}.zip"
STAGE_ZIP="$(mktemp -d)"
trap 'rm -rf "${STAGE_ZIP}"' EXIT
install -Dm0755 "${SO}"                  "${STAGE_ZIP}/fractalsql.so"
if [[ "${HAVE_PLUGIN}" = "1" ]]; then
install -Dm0755 "${PLUGIN_SRC}"          "${STAGE_ZIP}/fractalsql-reasoning-http.so"
fi
install -Dm0644 sql/load_extension.sql   "${STAGE_ZIP}/load_extension.sql"
install -Dm0644 sql/fractalsql--1.0.sql  "${STAGE_ZIP}/fractalsql--1.0.sql"
install -Dm0644 LICENSE                  "${STAGE_ZIP}/LICENSE"
install -Dm0644 THIRD-PARTY-NOTICES.md   "${STAGE_ZIP}/LICENSE-THIRD-PARTY"
cat > "${STAGE_ZIP}/README.txt" <<EOF
fractalsql-sqlite${PKG_SUFFIX} ${VERSION} Community (linux-${PKG_ARCH}, ${PROFILE} profile)

Static pure-C FractalSQL core linked in; the .so needs only
glibc (or musl) / libm / libdl / libpthread.

Quick start:
  sqlite3 mydb.sqlite \\
      -cmd ".load ./fractalsql" \\
      -cmd "SELECT fractalsql_edition();"      -- 'Community'
  sqlite3 mydb.sqlite \\
      -cmd ".load ./fractalsql" \\
      -cmd "SELECT fractalsql_version();"      -- '2.0.0'

SQL surface (2.0):
  fractalsql_edition()               TEXT
  fractalsql_version()               TEXT
  fractal_search(vector, query)      REAL  (cosine distance to SFS-refined query)
  fractal_search_explore(emb, query)        TEXT  (Scout-mode SFS aggregate)
  fractal_vector + 15 vector-math functions (canonical BLOB type)
  fractalsql_set / fractalsql_get    per-connection configuration
  Sovereign tier (with fractalsql-reasoning-http configured):
    fractal_reason, fractal_text_to_sql, fractal_schema_context,
    fractal_embed, fractal_vectorizer_*, agent + telemetry surface,
    fractal_dimension_*, fractal_optimize_portfolio*, fractal_ledger_*
  See fractalsql--1.0.sql in this archive for the full reference.
EOF
( cd "${STAGE_ZIP}" && zip -9 -r "${OLDPWD}/${ZIP_OUT}" . > /dev/null )
rm -rf "${STAGE_ZIP}"; trap - EXIT
echo "built ${ZIP_OUT}"

# ---------------------------------------------------------------------
# .deb — installs to /usr/local/lib/sqlite3/fractalsql.so per brief.
# Skipped for the musl profile (libc6 dep doesn't apply on Alpine).
# ---------------------------------------------------------------------
DEB_NAME="sqlite3-fractalsql${PKG_SUFFIX}"
DEB_OUT="${DIST_DIR}/${DEB_NAME}-${PKG_ARCH}.deb"

if [[ "${PROFILE}" != "musl" ]]; then
DEB_ARGS=(
    ./dist/${PKG_ARCH}/fractalsql${BIN_SUFFIX}.so=/usr/local/lib/sqlite3/fractalsql.so
    ./sql/load_extension.sql=/usr/share/doc/${DEB_NAME}/load_extension.sql
    ./sql/fractalsql--1.0.sql=/usr/share/doc/${DEB_NAME}/fractalsql--1.0.sql
    ./LICENSE=/usr/share/doc/${DEB_NAME}/LICENSE
    ./THIRD-PARTY-NOTICES.md=/usr/share/doc/${DEB_NAME}/LICENSE-THIRD-PARTY
)
if [[ "${HAVE_PLUGIN}" = "1" ]]; then
    DEB_ARGS+=(./${PLUGIN_SRC}=/usr/local/lib/sqlite3/fractalsql-reasoning-http.so)
fi
fpm -s dir -t deb \
    -n "${DEB_NAME}" \
    -v "${VERSION}" \
    -a "${PKG_ARCH}" \
    --iteration "${ITERATION}" \
    --description "FractalSQL SQLite extension, Community Edition" \
    --depends "libc6 (>= ${GLIBC_DEP})" \
    --after-install packaging/debian/postinst \
    -p "${DEB_OUT}" \
    "${DEB_ARGS[@]}"
echo "built ${DEB_OUT}"
fi

# ---------------------------------------------------------------------
# .rpm — same install path for consistency with the brief.
# ---------------------------------------------------------------------
RPM_NAME="fractalsql-sqlite${PKG_SUFFIX}"
RPM_OUT="${DIST_DIR}/${RPM_NAME}-${PKG_ARCH}.rpm"
APK_OUT="${DIST_DIR}/${RPM_NAME}-${PKG_ARCH}.apk"

STAGE_PKG="$(mktemp -d)"
trap 'rm -rf "${STAGE_PKG}"' EXIT
install -Dm0755 "${SO}" \
    "${STAGE_PKG}/usr/local/lib/sqlite3/fractalsql.so"
if [[ "${HAVE_PLUGIN}" = "1" ]]; then
install -Dm0755 "${PLUGIN_SRC}" \
    "${STAGE_PKG}/usr/local/lib/sqlite3/fractalsql-reasoning-http.so"
fi
install -Dm0644 sql/load_extension.sql \
    "${STAGE_PKG}/usr/share/doc/${RPM_NAME}/load_extension.sql"
install -Dm0644 sql/fractalsql--1.0.sql \
    "${STAGE_PKG}/usr/share/doc/${RPM_NAME}/fractalsql--1.0.sql"
install -Dm0644 LICENSE \
    "${STAGE_PKG}/usr/share/doc/${RPM_NAME}/LICENSE"
install -Dm0644 THIRD-PARTY-NOTICES.md \
    "${STAGE_PKG}/usr/share/doc/${RPM_NAME}/LICENSE-THIRD-PARTY"

if [[ "${PROFILE}" != "musl" ]]; then
fpm -s dir -t rpm \
    -n "${RPM_NAME}" \
    -v "${VERSION}" \
    -a "${RPM_ARCH}" \
    --iteration "${ITERATION}" \
    --description "FractalSQL SQLite extension, Community Edition" \
    --depends "sqlite" \
    --directories /usr/local/lib/sqlite3 \
    --after-install /dev/stdin \
    -p "${RPM_OUT}" \
    -C "${STAGE_PKG}" \
    usr \
    <<'POSTIN'
cat <<'EOF'

fractalsql-sqlite Community installed at:
    /usr/local/lib/sqlite3/fractalsql.so

Load with:
    sqlite3 mydb.sqlite \
        -cmd ".load /usr/local/lib/sqlite3/fractalsql" \
        -cmd "SELECT fractalsql_edition();"

EOF
POSTIN
echo "built ${RPM_OUT}"
fi

# ---------------------------------------------------------------------
# Alpine .apk — only built for the musl profile. Same install path as
# the rpm/deb (Alpine accepts /usr/local/lib/ since it's not a managed
# tree). Initial release is unsigned.
# ---------------------------------------------------------------------
if [[ "${PROFILE}" = "musl" ]]; then
fpm -s dir -t apk \
    -n "${RPM_NAME}" \
    -v "${VERSION}" \
    -a "${PKG_ARCH}" \
    --iteration "${ITERATION}" \
    --description "FractalSQL SQLite extension, Community Edition" \
    --depends "sqlite" \
    -p "${APK_OUT}" \
    -C "${STAGE_PKG}" \
    usr
echo "built ${APK_OUT}"
fi

rm -rf "${STAGE_PKG}"; trap - EXIT

# ---------------------------------------------------------------------
# Windows MSI — hand-off note (built by the Windows matrix entry in
# CI, not from this Linux-native script).
# ---------------------------------------------------------------------
cat <<EOF

Windows MSI is built separately via:
    scripts\\windows\\build.bat        (cl.exe with /MT /GL)
    scripts\\windows\\build-msi.bat    (WiX candle + light)

WiX source: scripts/windows/fractalsql.wxs
    * WixUI_InstallDir for interactive install-folder selection
    * Default install: C:\\Program Files\\FractalSQL
    * ADDTOPATH checkbox (default ON) — appends install dir to %PATH%
    * Uninstall removes files AND the PATH entry

EOF

echo
echo "Done. Packages in ${DIST_DIR}:"
ls -l "${DIST_DIR}"
