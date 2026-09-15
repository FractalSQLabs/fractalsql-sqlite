#!/bin/bash
#
# scripts/easy_install.sh
#
# The "easy button" for FractalSQL on SQLite. One command gets you from
# a bare Linux or macOS box to a working install with reasoning
# configured.
#
# Usage (fresh machine, nothing installed yet):
#   curl -fsSL https://github.com/FractalSQLabs/fractalsql-sqlite/releases/latest/download/easy_install.sh | bash
#
# Usage (package already installed via apt/dnf/apk/tarball yourself):
#   ./easy_install.sh              # detects it, skips straight to the wizard
#
# Flags (all optional. Anything you omit gets asked interactively):
#   --provider ollama|openai-compatible|skip
#   --url <chat-completions-url>       --model <name>
#   --embed-url <url>                  --embed-model <name>
#   --token <token>            (prefer leaving this to the masked prompt)
#   --think <off|low|medium|high|...>  --think-provider <ollama|openai|...>
#   --yes                      pre-confirm every prompt (needed for CI/non-tty)
#   --no-install               don't offer to install a missing package
#   --dry-run                  print what would happen, change nothing
#   --uninstall                remove the installed files + snippet
#   --version <X.Y.Z>          package version to install (default: this script's own)
#   -h, --help
#
# Env vars:
#   SQLITE3_BIN                sqlite3 binary to target (default: first
#                              sqlite3 on PATH)
#
# Install notes (kept as a contract note — the .ps1 sibling mirrors
# this one):
#   - There is no server. Install = drop the extension .so (+ the
#     reasoning plugin) into /usr/local/lib/sqlite3 and make sure the
#     sqlite3 CLI can find it. No clusters, no ports, no restarts.
#   - Configuration is per-connection via
#     fractalsql_set(), so the wizard writes a load_fractalsql.sql
#     snippet you can either pass to sqlite3 -init / .read on every
#     session, or inline into your own dot-sql bootstrap.
#   - Uninstall = file removal. Nothing is registered anywhere.
#
# No telemetry. This script never reports usage, provider choice, or
# success/failure anywhere. That's deliberate, matching FractalSQL's own
# "sovereign reasoning" positioning: your infra choices stay yours.
#
# Design notes:
#   - Runs fine piped from curl. Every prompt reads from /dev/tty directly,
#     not stdin, since stdin is the pipe's source in `curl ... | bash`.
#   - Re-running the wizard is the normal way to change providers or
#     models. It only overwrites the snippet.

set -euo pipefail

# --- version -----------------------------------------------------------
# Stamped in by release.yml at build time (the placeholder below is
# replaced with the tag version before this file is uploaded as a release
# asset). Falls back to reading src/fsql_sqlite_internal.h directly when
# run from a repo checkout during development, so this script works
# untouched both as a release asset and as a dev/test tool.
FSQL_VERSION="@@FSQL_VERSION@@"
if [[ "${FSQL_VERSION}" == "@@FSQL_VERSION@@" ]]; then
    HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -f "${HERE}/../src/fsql_sqlite_internal.h" ]]; then
        FSQL_VERSION="$(sed -n 's/^#define FSQL_SQLITE_VERSION_STR   "\(.*\)"$/\1/p' "${HERE}/../src/fsql_sqlite_internal.h")"
    fi
fi

REPO="FractalSQLabs/fractalsql-sqlite"
INSTALL_DIR="/usr/local/lib/sqlite3"
SNIPPET="${INSTALL_DIR}/load_fractalsql.sql"

# --- output helpers ------------------------------------------------------
if [[ -t 1 ]]; then G="\033[32m"; R="\033[31m"; Y="\033[33m"; B="\033[1m"; Z="\033[0m"; else G=""; R=""; Y=""; B=""; Z=""; fi
log()  { printf "${B}==>${Z} %s\n" "$1"; }
ok()   { printf "  ${G}✓${Z} %s\n" "$1"; }
warn() { printf "  ${Y}!${Z} %s\n" "$1" >&2; }
err()  { printf "  ${R}✗${Z} %s\n" "$1" >&2; }
die()  { err "$1"; exit 1; }

# --- /dev/tty-aware prompting --------------------------------------------
# `curl ... | bash` makes stdin the pipe, not the terminal. Reading a
# prompt from stdin in that mode either blocks forever or silently
# consumes script bytes as "input." Reading from /dev/tty directly
# sidesteps this (same trick rustup's installer uses).
YES=0
NO_INSTALL=0
DRY_RUN=0
UNINSTALL=0
INSTALL_VERSION="${FSQL_VERSION}"
PROVIDER=""
HTTP_URL=""
HTTP_MODEL=""
HTTP_TOKEN=""
HTTP_EMBED_URL=""
HTTP_EMBED_MODEL=""
HTTP_THINK=""
HTTP_THINK_PROVIDER=""

have_tty() { [[ -e /dev/tty ]]; }

confirm() {  # confirm "question" -> 0=yes 1=no
    local question="$1"
    [[ "${YES}" -eq 1 ]] && { ok "${question} -> yes (--yes)"; return 0; }
    if ! have_tty; then
        die "'${question}' needs an answer but there's no terminal to ask (running non-interactively). Pass --yes, or the specific flag for what you're trying to set."
    fi
    local reply
    read -r -p "${question} [Y/n] " reply < /dev/tty || true
    [[ -z "${reply}" || "${reply}" =~ ^[Yy] ]]
}

prompt() {  # prompt "question" "default" -> echoes the answer
    local question="$1" default="${2:-}" reply
    if ! have_tty; then
        [[ -n "${default}" ]] && { echo "${default}"; return; }
        die "'${question}' needs an answer but there's no terminal to ask (running non-interactively). Pass the corresponding flag."
    fi
    if [[ -n "${default}" ]]; then
        read -r -p "${question} [${default}]: " reply < /dev/tty || true
        echo "${reply:-${default}}"
    else
        read -r -p "${question}: " reply < /dev/tty || true
        echo "${reply}"
    fi
}

prompt_secret() {  # prompt_secret "question" -> echoes the answer, never displayed
    local question="$1" reply
    if ! have_tty; then
        die "'${question}' needs an answer but there's no terminal to ask (running non-interactively). Pass --token."
    fi
    read -r -s -p "${question}: " reply < /dev/tty || true
    echo >&2
    echo "${reply}"
}

# --- arg parsing -----------------------------------------------------------
usage() { sed -n '2,51p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --provider)         PROVIDER="$2"; shift 2 ;;
        --url)              HTTP_URL="$2"; shift 2 ;;
        --model)            HTTP_MODEL="$2"; shift 2 ;;
        --token)            HTTP_TOKEN="$2"; shift 2 ;;
        --embed-url)        HTTP_EMBED_URL="$2"; shift 2 ;;
        --embed-model)      HTTP_EMBED_MODEL="$2"; shift 2 ;;
        --think)            HTTP_THINK="$2"; shift 2 ;;
        --think-provider)   HTTP_THINK_PROVIDER="$2"; shift 2 ;;
        --version)          INSTALL_VERSION="$2"; shift 2 ;;
        --yes)              YES=1; shift ;;
        --no-install)       NO_INSTALL=1; shift ;;
        --dry-run)          DRY_RUN=1; shift ;;
        --uninstall)        UNINSTALL=1; shift ;;
        -h|--help)          usage ;;
        *) die "unknown flag: $1 (see --help)" ;;
    esac
done

[[ -n "${INSTALL_VERSION}" ]] || die "could not determine a version to install. Pass --version X.Y.Z"

# --- OS / sqlite3 detection ---------------------------------------------------
OS_FAMILY=""   # debian | rhel | alpine | darwin
PKG_MGR=""     # dnf | yum | zypper (only set when OS_FAMILY=rhel)
EXT_SUFFIX=""  # dylib on macOS, so on Linux — SQLite's loader accepts
               # either, but the on-disk name is what we install/verify
ARCH_UNAME="$(uname -m)"
case "${ARCH_UNAME}" in
    x86_64|amd64) ARCH_DEB="amd64"; ARCH_DARWIN="x86_64" ;;
    arm64|aarch64) ARCH_DEB="arm64"; ARCH_DARWIN="arm64" ;;
    *) die "unsupported architecture: ${ARCH_UNAME}" ;;
esac

detect_os() {
    case "$(uname -s)" in
        Darwin)
            OS_FAMILY="darwin"
            EXT_SUFFIX="dylib" ;;
        Linux)
            EXT_SUFFIX="so"
            if command -v apt-get >/dev/null 2>&1; then OS_FAMILY="debian"
            elif command -v dnf >/dev/null 2>&1; then OS_FAMILY="rhel"; PKG_MGR="dnf"
            elif command -v yum >/dev/null 2>&1; then OS_FAMILY="rhel"; PKG_MGR="yum"
            elif command -v zypper >/dev/null 2>&1; then OS_FAMILY="rhel"; PKG_MGR="zypper"
            elif command -v apk >/dev/null 2>&1; then OS_FAMILY="alpine"
            else
                die "unsupported Linux distro (need apt-get, dnf, yum, zypper, or apk)"
            fi
            ;;
        *) die "unsupported OS: $(uname -s). This script covers Linux and macOS. See easy_install.ps1 for Windows." ;;
    esac
}

# The one thing that must exist is a sqlite3 CLI (any recent version —
# the extension needs 3.25+ for function keywords in DDL and 3.31+ is
# what we test against). SQLITE3_BIN overrides.
SQLITE3_BIN="${SQLITE3_BIN:-}"
detect_sqlite3() {
    if [[ -z "${SQLITE3_BIN}" ]]; then
        command -v sqlite3 >/dev/null 2>&1 \
            || die "no sqlite3 CLI found on PATH. Install it (apt/dnf/brew install sqlite) and re-run."
        SQLITE3_BIN="sqlite3"
    else
        [[ -x "${SQLITE3_BIN}" ]] || die "SQLITE3_BIN is set to '${SQLITE3_BIN}' but it isn't executable"
    fi
    local ver
    ver="$("${SQLITE3_BIN}" --version | awk '{print $1}')"
    log "Found sqlite3 CLI ${ver} (${SQLITE3_BIN})"
}

is_installed() {
    [[ -f "${INSTALL_DIR}/fractalsql.${EXT_SUFFIX}" ]]
}

# --- Phase B: install the package (default-on, confirmed) ------------------
phase_b_install() {
    if is_installed; then return; fi
    if [[ "${NO_INSTALL}" -eq 1 ]]; then
        die "FractalSQL isn't installed yet. Grab the matching package from https://github.com/${REPO}/releases and install it, then re-run this script (or drop --no-install)."
    fi
    confirm "FractalSQL isn't installed yet. Install it now?" \
        || die "Nothing to do without installing the package first. Re-run without --no-install, or install it yourself from https://github.com/${REPO}/releases."

    local asset_base="https://github.com/${REPO}/releases/download/v${INSTALL_VERSION}"
    # Global, not local: an EXIT trap runs after set -e has already
    # unwound out of this function on a failing command below, at which
    # point a `local` variable here would no longer exist and `set -u`
    # would reject the trap's own reference to it as unbound.
    TMP_DIR="$(mktemp -d)"
    trap 'rm -rf "${TMP_DIR}"' EXIT

    case "${OS_FAMILY}" in
        debian)
            local asset="sqlite3-fractalsql-${ARCH_DEB}.deb"
            log "Downloading ${asset}..."
            curl -fsSL "${asset_base}/${asset}" -o "${TMP_DIR}/${asset}"
            log "sudo apt-get install -y ${TMP_DIR}/${asset}"
            [[ "${DRY_RUN}" -eq 1 ]] || sudo apt-get install -y "${TMP_DIR}/${asset}"
            ;;
        rhel)
            local asset="fractalsql-sqlite-${ARCH_DEB}.rpm"
            log "Downloading ${asset}..."
            curl -fsSL "${asset_base}/${asset}" -o "${TMP_DIR}/${asset}"
            if [[ "${PKG_MGR}" == "zypper" ]]; then
                # zypper enforces signature checks by default, even for a
                # locally-supplied file; dnf/yum don't.
                log "sudo zypper --non-interactive --no-gpg-checks install ${TMP_DIR}/${asset}"
                [[ "${DRY_RUN}" -eq 1 ]] || sudo zypper --non-interactive --no-gpg-checks install "${TMP_DIR}/${asset}"
            else
                log "sudo ${PKG_MGR} install -y ${TMP_DIR}/${asset}"
                [[ "${DRY_RUN}" -eq 1 ]] || sudo "${PKG_MGR}" install -y "${TMP_DIR}/${asset}"
            fi
            ;;
        alpine)
            local asset="fractalsql-sqlite-musl-${ARCH_DEB}.apk"
            log "Downloading ${asset}..."
            curl -fsSL "${asset_base}/${asset}" -o "${TMP_DIR}/${asset}"
            # apk enforces signature checks for locally-supplied files
            # (like zypper), and the community packages are unsigned --
            # hence --allow-untrusted.
            log "sudo apk add --allow-untrusted ${TMP_DIR}/${asset}"
            [[ "${DRY_RUN}" -eq 1 ]] || sudo apk add --allow-untrusted "${TMP_DIR}/${asset}"
            ;;
        darwin)
            local asset="fractalsql-sqlite-${INSTALL_VERSION}-darwin-${ARCH_DARWIN}.tar.gz"
            log "Downloading ${asset}..."
            curl -fsSL "${asset_base}/${asset}" -o "${TMP_DIR}/${asset}"
            tar xzf "${TMP_DIR}/${asset}" -C "${TMP_DIR}"
            log "Installing into ${INSTALL_DIR} (sudo)..."
            [[ "${DRY_RUN}" -eq 1 ]] || sudo mkdir -p "${INSTALL_DIR}"
            # Both the extension and the reasoning plugin, mirroring what
            # the .deb/.rpm payloads put in place on Linux.
            [[ "${DRY_RUN}" -eq 1 ]] || sudo install -m0755 \
                "${TMP_DIR}/${asset%.tar.gz}/fractalsql.dylib" "${INSTALL_DIR}/"
            [[ "${DRY_RUN}" -eq 1 ]] || sudo install -m0755 \
                "${TMP_DIR}/${asset%.tar.gz}/fractalsql-reasoning-http.so" "${INSTALL_DIR}/"
            ;;
    esac
    ok "Package installed."
}

# --- Phase C: the wizard -----------------------------------------------
# Doubles any single quote in a value before it goes inside a SQL string
# literal. Values here come from user input (a URL, a model name, a
# token), and a literal quote in one of them would otherwise break the
# fractalsql_set() call's syntax in the snippet.
sqlq() { printf '%s' "${1//\'/\'\'}"; }

# Emit one fractalsql_set line into the snippet DRAFT. Called with the
# key and the (already quoted) value. The draft is installed into place
# by install_snippet() at the end of the wizard.
cfg_line() {
    echo "SELECT fractalsql_set('$1', $2);" >> "${SNIPPET_DRAFT}"
}

write_snippet_header() {
    cat > "${SNIPPET_DRAFT}" <<EOF
-- load_fractalsql.sql — generated by easy_install.sh ${INSTALL_VERSION}
--
-- Per-session bootstrap for FractalSQL on SQLite. Run it with:
--     sqlite3 -init ${SNIPPET} mydb.sqlite
-- or from inside a session:
--     .read ${SNIPPET}
--
-- Configuration is per-connection (there are no GUCs to persist), so
-- this snippet runs on every session that wants the reasoning tier.
-- Search-only usage needs just the .load line below.

.load ${INSTALL_DIR}/fractalsql
EOF
}

# Install the finished draft as the real snippet. ${INSTALL_DIR}
# (/usr/local/lib/sqlite3) is root-owned on a standard install, so a
# non-root run can't write there directly -- cfg_line appending
# straight into place (the old design) failed with EACCES for everyone
# but root, and a root run's partial writes could leave a broken,
# headerless snippet behind. sudo only when the direct write can't
# happen, mode 0644 on that path: a root-owned 0600 would leave the
# invoking user unable to READ their own bootstrap file. When the
# directory IS writable by us, 0600 -- the draft may carry a token.
install_snippet() {
    if [[ -w "${INSTALL_DIR}" ]]; then
        install -m 0600 "${SNIPPET_DRAFT}" "${SNIPPET}"
    else
        if ! command -v sudo >/dev/null 2>&1 && [[ "$(id -u)" -ne 0 ]]; then
            die "this needs root privileges but 'sudo' isn't installed and you're not root. Install sudo, or re-run as root."
        fi
        sudo install -m 0644 "${SNIPPET_DRAFT}" "${SNIPPET}"
    fi
}

phase_c_wizard() {
    # The wizard always assembles the snippet into a temp draft first
    # and installs it into ${SNIPPET} at the end (--dry-run prints it
    # instead of installing). This is what keeps a dry run from
    # touching anything.
    SNIPPET_DRAFT="$(mktemp "${TMPDIR:-/tmp}/fsql_snippet.XXXXXX")"
    write_snippet_header

    if [[ -z "${PROVIDER}" ]]; then
        log "Reasoning provider:"
        echo "  1) Local Ollama"
        echo "  2) Cloud / OpenAI-compatible endpoint"
        echo "  3) Skip: search-only install, configure reasoning later"
        local choice; choice="$(prompt "Choice" "1")"
        case "${choice}" in
            1) PROVIDER="ollama" ;;
            2) PROVIDER="openai-compatible" ;;
            *) PROVIDER="skip" ;;
        esac
    fi

    local plugin_so="${INSTALL_DIR}/fractalsql-reasoning-http.so"

    case "${PROVIDER}" in
        ollama)
            HTTP_URL="${HTTP_URL:-$(prompt "Ollama chat URL" "http://localhost:11434/v1/chat/completions")}"
            HTTP_MODEL="${HTTP_MODEL:-$(prompt "Model" "gpt-oss:20b")}"
            HTTP_EMBED_URL="${HTTP_EMBED_URL:-$(prompt "Ollama embeddings URL" "http://localhost:11434/v1/embeddings")}"
            HTTP_EMBED_MODEL="${HTTP_EMBED_MODEL:-$(prompt "Embedding model" "nomic-embed-text")}"
            HTTP_THINK="${HTTP_THINK:-off}"
            HTTP_THINK_PROVIDER="${HTTP_THINK_PROVIDER:-ollama}"
            cfg_line reasoning_plugin "'$(sqlq "${plugin_so}")'"
            cfg_line http_url "'$(sqlq "${HTTP_URL}")'"
            cfg_line http_allow_plaintext "'on'"
            cfg_line http_model "'$(sqlq "${HTTP_MODEL}")'"
            cfg_line http_embed_url "'$(sqlq "${HTTP_EMBED_URL}")'"
            cfg_line http_embed_model "'$(sqlq "${HTTP_EMBED_MODEL}")'"
            cfg_line http_think "'$(sqlq "${HTTP_THINK}")'"
            cfg_line http_think_provider "'$(sqlq "${HTTP_THINK_PROVIDER}")'"
            ;;
        openai-compatible)
            HTTP_URL="${HTTP_URL:-$(prompt "Chat completions URL" "")}"
            [[ -n "${HTTP_URL}" ]] || die "a URL is required for a cloud/OpenAI-compatible endpoint"
            HTTP_MODEL="${HTTP_MODEL:-$(prompt "Model" "gpt-4o-mini")}"
            [[ -n "${HTTP_TOKEN}" ]] || HTTP_TOKEN="$(prompt_secret "API token (masked, never logged)")"
            cfg_line reasoning_plugin "'$(sqlq "${plugin_so}")'"
            cfg_line http_url "'$(sqlq "${HTTP_URL}")'"
            cfg_line http_token "'$(sqlq "${HTTP_TOKEN}")'"
            cfg_line http_model "'$(sqlq "${HTTP_MODEL}")'"
            if [[ "${HTTP_URL}" != https://* ]]; then
                warn "That URL isn't https://. That's fine for localhost or a private LAN, but risky for anything else. Not blocking, just flagging it."
            fi
            ;;
        skip)
            log "Skipping reasoning config. Search functions like fractal_search and fractal_search_explore work with no model."
            ;;
        *) die "unknown --provider '${PROVIDER}' (expected ollama, openai-compatible, or skip)" ;;
    esac

    if [[ "${PROVIDER}" != "skip" ]]; then
        if [[ "${DRY_RUN}" -eq 1 ]]; then
            log "(--dry-run: snippet not written; this is what would have been written to ${SNIPPET}:)"
            sed 's/^/    /' "${SNIPPET_DRAFT}"
            rm -f "${SNIPPET_DRAFT}"
        else
            install_snippet
            ok "Reasoning configured in ${SNIPPET}."
            if grep -q "http_token" "${SNIPPET_DRAFT}"; then
                warn "Snippet contains your http_token in plain text — protect it like a credential (it was written 0600; sudo-installed snippets are 0644, root-owned)."
            fi
            rm -f "${SNIPPET_DRAFT}"
        fi
    fi

    if [[ "${DRY_RUN}" -ne 1 ]]; then
        local ed ver
        ed="$("${SQLITE3_BIN}" ":memory:" "SELECT load_extension('${INSTALL_DIR}/fractalsql'); SELECT fractalsql_edition();" 2>/dev/null | tail -1)"
        ver="$("${SQLITE3_BIN}" ":memory:" "SELECT load_extension('${INSTALL_DIR}/fractalsql'); SELECT fractalsql_version();" 2>/dev/null | tail -1)"
        ok "fractalsql_edition() = ${ed}, fractalsql_version() = ${ver}"
        if [[ "${ver}" != "${INSTALL_VERSION}" ]]; then
            warn "That's not ${INSTALL_VERSION}, the version this script expected. The installed files themselves are out of date. Reinstall the current package from https://github.com/${REPO}/releases, then re-run this script."
        fi
        if [[ "${PROVIDER}" != "skip" ]] && confirm "Run a live reasoning smoke test (SELECT fractal_reason('say ok'))? A cloud endpoint may incur cost, and a cold local model can take several minutes the first time."; then
            local reply
            reply="$("${SQLITE3_BIN}" ":memory:" \
                ".read ${SNIPPET}" \
                "SELECT fractal_reason('say ok');" 2>&1 || true)"
            echo "  ${reply}" | head -5
            if [[ "${reply}" == *Error* || "${reply}" == *error* ]]; then
                warn "That failed. If it looks like a timeout on a slow/cold local model, give the model a minute and retry, or raise the plugin's wait ceiling first (FSQL_REASONING_HTTP_TIMEOUT_MS / FSQL_REASONING_HTTP_LOW_SPEED_SECS in the shell before starting sqlite3), or see docs/reasoning-setup.md's 'Handling Constrained Hardware' section."
            fi
        fi
    fi

    printf "\n${G}You're set up.${Z} Where next:\n"
    cat <<EOF
  - Pass the snippet to every session: sqlite3 -init ${SNIPPET} mydb.sqlite
  - Cold Ollama models can take minutes on the first call; the reasoning
    plugin's FSQL_REASONING_HTTP_TIMEOUT_MS env var raises the wait.
  - docs/starter-kits.md: industry-specific runnable examples
  - docs/api-agency.md: the built-in agents, full reference
  - docs/composition-guide.md: build your own agent
  - Re-run this script anytime to switch providers or models. It's
    safe, it just rewrites ${SNIPPET}.
EOF
}

# --- --uninstall ---------------------------------------------------------
uninstall_flow() {
    log "This will remove the FractalSQL extension files and the generated snippet."
    if confirm "Remove ${INSTALL_DIR}/fractalsql.${EXT_SUFFIX}, the reasoning plugin, and ${SNIPPET}?"; then
        if [[ "${DRY_RUN}" -eq 1 ]]; then
            log "(--dry-run: not actually removing)"
        else
            sudo rm -f "${INSTALL_DIR}/fractalsql.${EXT_SUFFIX}" \
                       "${INSTALL_DIR}/fractalsql-reasoning-http.so" \
                       "${SNIPPET}"
            ok "Files removed. Nothing was registered anywhere else — SQLite extensions leave no other trace."
        fi
    fi
    # The file removal above uninstalls a tarball install completely,
    # but an apt/dnf/zypper/apk-installed package still has a package
    # record (and package ownership of the same files) -- point at the
    # right removal command per family.
    case "${OS_FAMILY}" in
        debian) echo "  To remove the package: sudo apt remove sqlite3-fractalsql" ;;
        rhel)
            if [[ "${PKG_MGR}" == "zypper" ]]; then
                echo "  To remove the package: sudo zypper remove fractalsql-sqlite"
            else
                echo "  To remove the package: sudo ${PKG_MGR} remove fractalsql-sqlite"
            fi ;;
        alpine) echo "  To remove the package: sudo apk del fractalsql-sqlite-musl" ;;
        darwin) : ;;  # tarball install: the file removal above is the whole uninstall
    esac
}

# --- main ------------------------------------------------------------------
main() {
    detect_os
    detect_sqlite3
    log "Targeting sqlite3 CLI: ${SQLITE3_BIN} (install dir: ${INSTALL_DIR})"

    if [[ "${UNINSTALL}" -eq 1 ]]; then
        uninstall_flow
        exit 0
    fi

    phase_b_install
    phase_c_wizard
}

main "$@"